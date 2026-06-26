#!/usr/bin/env bash
# =============================================================================
# EXTENDRIX — sync-overrides.sh
# Sincroniza docker-compose.override.yml con projects-registry.conf.
#
# Para cada proyecto del registry que NO tenga aún su entrada en
# docker-compose.override.yml, agrega un bloque por defecto con:
#   • entrypoint wrapper que instala requirements.txt de shared-addons
#   • addons-path incluyendo EXTENDRIX_extra_addons/tools
#   • workers/limites estándar (4 / 2GB-2.5GB)
#
# USO:
#   ./scripts/sync-overrides.sh                          # dry-run (lista lo que faltaría)
#   ./scripts/sync-overrides.sh --apply                  # aplica a TODOS los faltantes
#   ./scripts/sync-overrides.sh --apply <proyecto>       # solo un proyecto (entorno=sta)
#   ./scripts/sync-overrides.sh --apply <proyecto> <ent> # un proyecto + entorno
#   ./scripts/sync-overrides.sh --force <proyecto>       # sobrescribe entrada existente
#
# OPCIONES:
#   --apply        Ejecuta los cambios (sin esto es dry-run).
#   --force        Si el proyecto ya tiene entrada en el override, la reemplaza.
#   --recreate     Después de aplicar, fuerza recreate del/los contenedor(es).
# =============================================================================

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
title() { echo -e "\n${BLUE}${BOLD}══ $* ══${NC}\n"; }
step()  { echo -e "${CYAN}  →${NC} $*"; }

OVERRIDE_FILE="docker-compose.override.yml"
REGISTRY="projects-registry.conf"

# ── Parseo de argumentos ─────────────────────────────────────────────────────
DRY_RUN=true
FORCE=false
RECREATE=false
TARGET_PROJECT=""
TARGET_ENTORNO=""

for arg in "$@"; do
    case "$arg" in
        --apply)    DRY_RUN=false ;;
        --force)    FORCE=true ;;
        --recreate) RECREATE=true ;;
        --help|-h)  sed -n '2,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; exit 0 ;;
        --*)        error "Opción desconocida: $arg" ;;
        *)
            if [[ -z "$TARGET_PROJECT" ]]; then TARGET_PROJECT="$arg"
            elif [[ -z "$TARGET_ENTORNO" ]]; then TARGET_ENTORNO="$arg"
            else error "Argumento posicional inesperado: $arg"
            fi
            ;;
    esac
done

[[ ! -f "$REGISTRY" ]] && error "No existe $REGISTRY"

# ── Helper: ¿el override ya tiene este servicio? ─────────────────────────────
override_has_service() {
    local svc="$1"
    [[ -f "$OVERRIDE_FILE" ]] || return 1
    grep -qE "^[[:space:]]+${svc}:[[:space:]]*$" "$OVERRIDE_FILE"
}

# ── Helper: asegurar que el override existe con header `services:` ───────────
ensure_override_file() {
    if [[ ! -f "$OVERRIDE_FILE" ]]; then
        cat > "$OVERRIDE_FILE" <<HEADER
# =============================================================================
# EXTENDRIX — docker-compose.override.yml
# Override específico de este servidor — NO commitear al repo.
#
# Cada bloque se genera por sync-overrides.sh con valores por defecto.
# Editá manualmente cualquier proyecto para agregar paths shared-addons
# adicionales (mercadolibre, account, etc.), PYTHONPATH, recursos, etc.
# =============================================================================
services:
HEADER
        info "Creado $OVERRIDE_FILE con header."
    fi
    # Asegurar que tenga "services:" como root key
    if ! grep -qE "^services:[[:space:]]*$" "$OVERRIDE_FILE"; then
        echo "services:" >> "$OVERRIDE_FILE"
    fi
}

# ── Helper: detecta la indentación dominante de los servicios en el override ─
# (algunos overrides legacy usan 4 espacios; los nuevos usamos 2. Para mantener
#  YAML válido al agregar bloques, replicamos la indentación existente.)
detect_indent() {
    [[ ! -f "$OVERRIDE_FILE" ]] && { echo "  "; return; }
    local first_svc_line
    first_svc_line=$(grep -m1 -E "^[ ]+odoo[0-9]+_[a-z0-9_]+_[a-z]+:[[:space:]]*$" "$OVERRIDE_FILE" || true)
    if [[ -z "$first_svc_line" ]]; then
        echo "  "    # default: 2 espacios
    else
        # Extraer los espacios iniciales
        echo "$first_svc_line" | sed -E 's/^( +).*/\1/'
    fi
}

# ── Helper: bloque por defecto para un servicio ──────────────────────────────
# Genera el bloque YAML usando LISTA para `command:` (cada flag en su propia
# línea) en vez de `>` (folded). Ventaja: legible, cada flag visible al
# inspeccionar el override, y se pueden agregar/quitar flags sin tocar la
# concatenación con espacios.
#
# Defaults pensados para staging compartido (4 proyectos sobre ~8GB RAM):
#   • workers=2          → 2 workers HTTP por instancia (4 inst × 2 = 8 totales)
#   • max-cron-threads=1 → reduce paralelismo de cron (compartimos postgres)
#   • limit-time-cpu=600 → 10 min CPU por request (default Odoo: 60s, mata wizards)
#   • limit-time-real=1200 → 20 min wallclock (default Odoo: 120s, mata imports)
#   • limit-time-real-cron=3600 → 1h para crons largos
#   • db_maxconn=8       → controla pool de conexiones por worker
#   • proxy-mode         → confía en X-Forwarded-* de nginx (URLs https correctas)
#   • db-filter          → restringe selector de DBs al proyecto (UI)
#
# Logging — verlo todo (INFO + WARNING + ERROR + CRITICAL) con menos ruido:
#   • log-level=info                  → muestra INFO, WARNING, ERROR, CRITICAL
#   • log-handler=:INFO               → fuerza root logger a INFO (override odoo.conf)
#   • log-handler odoo.sql_db:WARNING → oculta queries SQL ruidosas (queda en warn)
#   • log-handler werkzeug:WARNING    → oculta cada hit HTTP (queda en warn)
#   • log-handler ir_cron:ERROR       → silencia "Skipping database X as its base
#     version is not Y" que aparece cuando el cron worker encuentra DBs de otras
#     versiones en postgres compartido. db-filter NO afecta al cron worker
#     (usa force=True), por eso silenciamos el logger específico. Errores reales
#     del cron (ERROR/CRITICAL) siguen visibles.
generate_block() {
    local container="$1"
    local project="$2"
    local entorno="$3"
    local svc_indent
    svc_indent=$(detect_indent)
    # Indentación de claves internas (2 espacios extra) y de items de lista (4 extra)
    local key_indent="${svc_indent}  "
    local item_indent="${svc_indent}    "
    cat <<YAMLBLOCK

${svc_indent}${container}:
${key_indent}entrypoint: ["/bin/sh", "/odoo-entrypoint.sh"]
${key_indent}volumes:
${item_indent}- ./scripts/odoo-entrypoint.sh:/odoo-entrypoint.sh:ro
${key_indent}command:
${item_indent}- odoo
${item_indent}- --config=/etc/odoo/odoo.conf
${item_indent}- --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons/EXTENDRIX_extra_addons/tools,/mnt/extra-addons
${item_indent}- --db-filter=^${project}_${entorno}_.*\$
${item_indent}- --workers=2
${item_indent}- --max-cron-threads=1
${item_indent}- --limit-memory-soft=2147483648
${item_indent}- --limit-memory-hard=2684354560
${item_indent}- --limit-time-cpu=600
${item_indent}- --limit-time-real=1200
${item_indent}- --limit-time-real-cron=3600
${item_indent}- --db_maxconn=8
${item_indent}- --proxy-mode
${item_indent}- --log-level=info
${item_indent}- --log-handler=:INFO
${item_indent}- --log-handler=odoo.sql_db:WARNING
${item_indent}- --log-handler=werkzeug:WARNING
${item_indent}- --log-handler=odoo.addons.base.models.ir_cron:ERROR
YAMLBLOCK
}

# ── Helper: eliminar bloque existente (para --force) ─────────────────────────
remove_existing_block() {
    local svc="$1"
    [[ -f "$OVERRIDE_FILE" ]] || return 0
    SVC="$svc" OVERRIDE_FILE="$OVERRIDE_FILE" python3 <<'PYEOF'
import os, pathlib, re
path = pathlib.Path(os.environ["OVERRIDE_FILE"])
svc  = os.environ["SVC"]
lines = path.read_text().splitlines()
out, i = [], 0
service_re = re.compile(rf"^  {re.escape(svc)}:\s*$")
# Una clave hermana de servicio en el mismo nivel: "  <otro_servicio>:"
# (2 espacios exactos, termina en ":" sin más indentación)
sibling_re = re.compile(r"^  [A-Za-z0-9_-]+:\s*$")
while i < len(lines):
    if service_re.match(lines[i]):
        i += 1
        while i < len(lines):
            # Fin del bloque: otra clave de servicio o sección root
            if sibling_re.match(lines[i]):
                break
            if lines[i] and not lines[i].startswith(" "):
                break
            i += 1
        continue
    out.append(lines[i])
    i += 1
text = "\n".join(out)
text = re.sub(r"\n{3,}", "\n\n", text)
path.write_text(text if text.endswith("\n") else text + "\n")
PYEOF
}

# ── Cargar proyectos del registry ────────────────────────────────────────────
declare -a PROJECTS=()
while IFS=: read -r P V E D PH; do
    [[ "$P" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${P// /}" ]] && continue
    # Filtrar por target si se especificó
    if [[ -n "$TARGET_PROJECT" ]]; then
        [[ "$P" != "$TARGET_PROJECT" ]] && continue
        [[ -n "$TARGET_ENTORNO" && "$E" != "$TARGET_ENTORNO" ]] && continue
    fi
    PROJECTS+=("$P:$V:$E")
done < "$REGISTRY"

[[ ${#PROJECTS[@]} -eq 0 ]] && error "No se encontraron proyectos en el registry${TARGET_PROJECT:+ (filtro: $TARGET_PROJECT)}"

# ── Procesar ─────────────────────────────────────────────────────────────────
title "Sync overrides"
echo "  Override file: $OVERRIDE_FILE"
echo "  Proyectos del registry: ${#PROJECTS[@]}"
echo "  Modo: $($DRY_RUN && echo 'DRY-RUN' || echo 'APLICAR')$($FORCE && echo ' --force')"
echo ""

ADDED=0
SKIPPED=0
RECREATED=()

for entry in "${PROJECTS[@]}"; do
    IFS=: read -r P V E <<< "$entry"
    CONTAINER="odoo${V}_${P}_${E}"
    printf "  %-40s " "$CONTAINER"

    if override_has_service "$CONTAINER"; then
        if $FORCE; then
            if $DRY_RUN; then
                echo -e "${YELLOW}sobrescribiría${NC} (--force)"
            else
                remove_existing_block "$CONTAINER"
                generate_block "$CONTAINER" "$P" "$E" >> "$OVERRIDE_FILE"
                echo -e "${GREEN}reemplazado${NC}"
                ADDED=$((ADDED + 1))
                RECREATED+=("$CONTAINER")
            fi
        else
            echo -e "${CYAN}ya tiene override${NC} (omitido)"
            SKIPPED=$((SKIPPED + 1))
        fi
    else
        if $DRY_RUN; then
            echo -e "${YELLOW}FALTA override${NC} — usá --apply para agregarlo"
        else
            ensure_override_file
            generate_block "$CONTAINER" "$P" "$E" >> "$OVERRIDE_FILE"
            echo -e "${GREEN}agregado${NC}"
            ADDED=$((ADDED + 1))
            RECREATED+=("$CONTAINER")
        fi
    fi
done

echo ""
if $DRY_RUN; then
    echo -e "  ${YELLOW}Dry-run terminado.${NC} Ejecutá con ${BOLD}--apply${NC} para aplicar."
    exit 0
fi

echo -e "  ${GREEN}✓ Agregados: ${ADDED}${NC}   ${CYAN}~ Existentes: ${SKIPPED}${NC}"

# ── Recreate opcional ────────────────────────────────────────────────────────
if [[ ${#RECREATED[@]} -gt 0 ]]; then
    echo ""
    if $RECREATE; then
        title "Recreando contenedores con la nueva config"
        for c in "${RECREATED[@]}"; do
            step "docker compose up -d --force-recreate $c"
            docker compose up -d --force-recreate "$c"
        done

        # Recargar nginx: cada container recreado obtiene IP nueva. Sin reload,
        # nginx mantiene la IP vieja cacheada → 502 hasta el próximo reload.
        if docker compose ps --format '{{.Name}}' 2>/dev/null | grep -q '^odoo_nginx$'; then
            step "Recargando nginx (los containers recreados tienen IPs nuevas)..."
            docker compose exec -T nginx nginx -s reload 2>/dev/null && \
                info "Nginx recargado." || \
                warn "No se pudo recargar nginx. Hacelo manual: ./scripts/ops.sh nginx-reload"
        fi
    else
        warn "Para que los cambios surtan efecto, recreá los contenedores afectados:"
        for c in "${RECREATED[@]}"; do
            echo "    docker compose up -d --force-recreate $c"
        done
        echo "  O ejecutá: ./scripts/sync-overrides.sh --apply --recreate"
    fi
fi
