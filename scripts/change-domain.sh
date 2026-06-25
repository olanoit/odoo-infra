#!/usr/bin/env bash
# =============================================================================
# OLANOIT — change-domain.sh
# Cambia el dominio de un proyecto existente, o le agrega un dominio alias.
#
# USO:
#   ./scripts/change-domain.sh <proyecto> <dominio-nuevo> [<entorno>] [opciones]
#
# MODOS:
#   (por defecto)     REEMPLAZA el dominio actual por <dominio-nuevo>.
#                     Actualiza vhost + registry + .env, emite cert del nuevo
#                     dominio y elimina el cert viejo.
#   --add             AGREGA <dominio-nuevo> como alias (el proyecto responde a
#                     ambos). Suma el dominio al server_name y expande el cert
#                     existente a SAN (un solo cert con ambos dominios).
#                     No toca registry ni .env (el dominio canónico no cambia).
#
# OPCIONES:
#   --dry-run         No ejecuta nada; solo muestra el resumen.
#   --no-ssl          No emite/expande certificado SSL (hazlo aparte).
#   --keep-old-cert   (modo reemplazo) Conserva el cert del dominio viejo.
#   --staging         Usa el servidor de pruebas de Let's Encrypt (sin rate limits).
#   --force           Salta la confirmación interactiva.
#
# REQUISITO PREVIO:
#   El <dominio-nuevo> debe resolver públicamente a la IP de este servidor
#   ANTES de emitir SSL (o estar cubierto por un wildcard). Si no resuelve,
#   el challenge ACME fallará y el cert no se emitirá.
# =============================================================================

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
[[ -f .env ]] && source .env

# Colores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
title() { echo -e "\n${BLUE}${BOLD}══ $* ══${NC}\n"; }
step()  { echo -e "${CYAN}  →${NC} $*"; }

show_help() {
    sed -n '2,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
}

# ── Parseo de argumentos ─────────────────────────────────────────────────────
PROYECTO=""
NEW_DOMINIO=""
ENTORNO="sta"
MODE="replace"
DRY_RUN=false
WITH_SSL=true
KEEP_OLD_CERT=false
WITH_STAGING=false
FORCE=false
POS=()

for arg in "$@"; do
    case "$arg" in
        --add)           MODE="add" ;;
        --dry-run)       DRY_RUN=true ;;
        --no-ssl)        WITH_SSL=false ;;
        --keep-old-cert) KEEP_OLD_CERT=true ;;
        --staging)       WITH_STAGING=true ;;
        --force)         FORCE=true ;;
        -h|--help)       show_help; exit 0 ;;
        --*)             error "Opción desconocida: $arg" ;;
        *)               POS+=("$arg") ;;
    esac
done

# Posicionales: <proyecto> <dominio-nuevo> [<entorno>]
# El dominio se reconoce por contener un punto; el resto es proyecto/entorno.
for p in "${POS[@]:-}"; do
    [[ -z "$p" ]] && continue
    if [[ "$p" == *.* && -z "$NEW_DOMINIO" ]]; then
        NEW_DOMINIO="$p"
    elif [[ -z "$PROYECTO" ]]; then
        PROYECTO="$p"
    else
        ENTORNO="$p"
    fi
done

[[ -z "$PROYECTO" || -z "$NEW_DOMINIO" ]] && { show_help; echo; error "Faltan argumentos: <proyecto> y <dominio-nuevo> son obligatorios."; }

# Validar formato del dominio
[[ "$NEW_DOMINIO" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]] \
    || error "Dominio inválido: '${NEW_DOMINIO}'"

# ── Detección del proyecto (igual que delete-project.sh) ─────────────────────
CONTAINER_NAME=$(docker compose config --services 2>/dev/null \
    | grep -E "^odoo[0-9]+_${PROYECTO}_${ENTORNO}$" | head -1 || true)
if [[ -z "$CONTAINER_NAME" ]]; then
    CONTAINER_NAME=$(docker ps -a --format '{{.Names}}' \
        | grep -E "^odoo[0-9]+_${PROYECTO}_${ENTORNO}$" | head -1 || true)
fi
[[ -z "$CONTAINER_NAME" ]] && \
    error "No encontré servicio o contenedor 'odoo*_${PROYECTO}_${ENTORNO}'. ¿Proyecto o entorno mal escrito?"

VERSION=$(echo "$CONTAINER_NAME" | sed -E 's/^odoo([0-9]+)_.*/\1/')
PROY_UC=$(echo "$PROYECTO" | tr '[:lower:]' '[:upper:]')
ENT_UC=$(echo "$ENTORNO"  | tr '[:lower:]' '[:upper:]')
VHOSTS="nginx/conf.d/vhosts-projects.conf"
[[ -f "$VHOSTS" ]] || error "No se encontró $VHOSTS"

# ── Detectar dominio actual desde el vhost (fuente de verdad) ────────────────
OLD_DOMINIO=$(
    MODE="$MODE" PROY_UC="$PROY_UC" ENT_UC="$ENT_UC" VHOSTS="$VHOSTS" \
    python3 - <<'PYEOF'
import os, re, pathlib
PROY_UC, ENT_UC = os.environ["PROY_UC"], os.environ["ENT_UC"]
lines = pathlib.Path(os.environ["VHOSTS"]).read_text().splitlines()
HEADER_RE = re.compile(rf"^\s*#\s*ODOO\s+\d+\s*\|\s*{re.escape(PROY_UC)}\s*\|\s*{re.escape(ENT_UC)}\s*$")
stop_re   = re.compile(r"^# (=+|__SYNC_VHOSTS_INSERT__|PLANTILLA)")
i = 0
while i < len(lines):
    if HEADER_RE.match(lines[i]):
        seen_server = False
        j = i + 1
        while j < len(lines):
            ln = lines[j]
            if "server {" in ln or "server{" in ln:
                seen_server = True
            if seen_server and stop_re.match(ln):
                break
            m = re.match(r"\s*server_name\s+(.+?);", ln)
            if m:
                print(m.group(1).split()[0])  # primer dominio del server_name
                raise SystemExit(0)
            j += 1
    i += 1
raise SystemExit(0)
PYEOF
)
[[ -z "$OLD_DOMINIO" ]] && error "No encontré el bloque vhost de ${PROY_UC}/${ENT_UC} en $VHOSTS"

# Dominio registrado (puede diferir del vhost si quedó desincronizado)
REG_DOMINIO=$(grep -E "^${PROYECTO}:${VERSION}:${ENTORNO}:" projects-registry.conf 2>/dev/null \
              | head -1 | cut -d: -f4 || true)

# ── Validaciones de coherencia ───────────────────────────────────────────────
if [[ "$MODE" == "replace" ]]; then
    [[ "$OLD_DOMINIO" == "$NEW_DOMINIO" ]] && error "El dominio ya es '${NEW_DOMINIO}'. Nada que cambiar."
else
    grep -qE "server_name[^;]*\b${NEW_DOMINIO//./\\.}\b" "$VHOSTS" \
        && error "El dominio '${NEW_DOMINIO}' ya está en el server_name. Nada que agregar."
fi

# ── Resumen ──────────────────────────────────────────────────────────────────
title "Cambio de dominio — ${PROYECTO} (${ENTORNO})"
printf "  %-22s %s\n" "Proyecto:"        "${CONTAINER_NAME} (Odoo ${VERSION})"
printf "  %-22s %s\n" "Modo:"            "$([[ "$MODE" == add ]] && echo 'AGREGAR alias (cert SAN)' || echo 'REEMPLAZAR dominio')"
printf "  %-22s %s\n" "Dominio actual:"  "${OLD_DOMINIO}"
printf "  %-22s %s\n" "Dominio nuevo:"   "${NEW_DOMINIO}"
echo ""
echo "  Se modificará:"
if [[ "$MODE" == "replace" ]]; then
    echo "    • vhost: server_name + rutas ssl_certificate → ${NEW_DOMINIO}"
    echo "    • projects-registry.conf y .env → ${NEW_DOMINIO}"
    $WITH_SSL && echo "    • SSL: emitir cert para ${NEW_DOMINIO}"
    $WITH_SSL && { $KEEP_OLD_CERT && echo "    • cert viejo (${OLD_DOMINIO}): ${GREEN}conservar${NC} (--keep-old-cert)" \
                   || echo "    • cert viejo (${OLD_DOMINIO}): eliminar"; }
else
    echo "    • vhost: server_name → ${OLD_DOMINIO} ${NEW_DOMINIO} (ambos)"
    $WITH_SSL && echo "    • SSL: expandir cert '${OLD_DOMINIO}' a SAN [${OLD_DOMINIO}, ${NEW_DOMINIO}]"
    echo "    • registry/.env: sin cambios (dominio canónico = ${OLD_DOMINIO})"
fi
[[ "$REG_DOMINIO" != "" && "$REG_DOMINIO" != "$OLD_DOMINIO" ]] && \
    warn "registry tiene '${REG_DOMINIO}' pero el vhost usa '${OLD_DOMINIO}' (desincronizado)."
echo ""

if $DRY_RUN; then
    warn "DRY-RUN — no se ejecuta nada. Quita --dry-run para aplicar."
    exit 0
fi

# ── Confirmación ─────────────────────────────────────────────────────────────
if ! $FORCE; then
    read -rp "$(echo -e "${YELLOW}¿Continuar? [y/N]:${NC} ")" ans
    [[ "$ans" =~ ^[yY]$ ]] || { warn "Cancelado."; exit 0; }
fi

# ── Helper: emitir/expandir certificado (basado en sync-projects.sh) ─────────
emit_cert() {
    local cert_name="$1"; shift
    local domains=("$@")
    local extra=""
    $WITH_STAGING && extra="--staging"
    [[ "$MODE" == "add" ]] && extra="$extra --expand"

    [[ -z "${CERTBOT_EMAIL:-}" ]] && { warn "CERTBOT_EMAIL no configurado en .env — omito SSL."; return 1; }

    # Verificar DNS + challenge HTTP de cada dominio antes de molestar a certbot
    local SERVER_IP; SERVER_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    local d resolved code
    for d in "${domains[@]}"; do
        resolved=$(dig +short "$d" 2>/dev/null | grep -E '^[0-9]' | head -1 || echo "")
        if [[ -z "$resolved" ]]; then
            warn "${d}: DNS no resuelve. Crea el registro y reintenta el SSL aparte. SSL omitido."; return 1
        fi
        if [[ -n "$SERVER_IP" && "$resolved" != "$SERVER_IP" ]]; then
            warn "${d}: DNS apunta a ${resolved}, no a este servidor (${SERVER_IP}). SSL omitido."; return 1
        fi
        mkdir -p ./nginx/certbot/www/.well-known/acme-challenge
        echo ok > "./nginx/certbot/www/.well-known/acme-challenge/.test-${d}"
        code=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
            "http://${d}/.well-known/acme-challenge/.test-${d}" 2>/dev/null || echo 000)
        rm -f "./nginx/certbot/www/.well-known/acme-challenge/.test-${d}"
        [[ "$code" != "200" ]] && { warn "${d}: challenge ACME no accesible (HTTP ${code}). SSL omitido."; return 1; }
    done

    # El contenedor de renovación retiene el lock global de certbot: pausarlo.
    step "Pausando renovación y limpiando locks de certbot..."
    docker compose stop certbot >/dev/null 2>&1 || true
    docker ps -a --filter "name=certbot-run" -q 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
    rm -f ./nginx/certbot/conf/.certbot.lock 2>/dev/null || true
    trap 'docker compose up -d certbot >/dev/null 2>&1 || true' RETURN

    local dflags=() out exit_code
    for d in "${domains[@]}"; do dflags+=(-d "$d"); done

    step "Emitiendo certificado (${cert_name}): ${domains[*]}..."
    out=$(timeout 120s docker compose run --rm --entrypoint certbot certbot certonly \
        --webroot --webroot-path=/var/www/certbot \
        --email "${CERTBOT_EMAIL}" --agree-tos --no-eff-email --non-interactive \
        --cert-name "${cert_name}" ${extra} "${dflags[@]}" 2>&1) && exit_code=0 || exit_code=$?
    echo "$out"

    if [[ $exit_code -eq 0 ]]; then
        info "Certificado emitido: ${cert_name}"
        return 0
    elif [[ $exit_code -eq 124 ]]; then
        warn "Certbot se colgó >120s (lock residual, red, o rate-limit silencioso)."
    elif echo "$out" | grep -qi "rateLimited\|too many"; then
        warn "Rate limit de Let's Encrypt. Espera ~1h o usa --staging para probar."
    else
        warn "Error al emitir el cert. Revisa el output anterior."
    fi
    return 1
}

# ── 1. Reescribir el vhost ───────────────────────────────────────────────────
title "Aplicando cambios"
step "Actualizando vhost ${VHOSTS}..."
MODE="$MODE" PROY_UC="$PROY_UC" ENT_UC="$ENT_UC" VHOSTS="$VHOSTS" \
OLD="$OLD_DOMINIO" NEW="$NEW_DOMINIO" \
python3 - <<'PYEOF'
import os, re, pathlib
PROY_UC, ENT_UC = os.environ["PROY_UC"], os.environ["ENT_UC"]
MODE, OLD, NEW = os.environ["MODE"], os.environ["OLD"], os.environ["NEW"]
path = pathlib.Path(os.environ["VHOSTS"])
lines = path.read_text().splitlines()
HEADER_RE = re.compile(rf"^\s*#\s*ODOO\s+\d+\s*\|\s*{re.escape(PROY_UC)}\s*\|\s*{re.escape(ENT_UC)}\s*$")
stop_re   = re.compile(r"^# (=+|__SYNC_VHOSTS_INSERT__|PLANTILLA)")
i = 0
while i < len(lines):
    if HEADER_RE.match(lines[i]):
        # delimitar el bloque [i, j)
        seen_server, j = False, i + 1
        while j < len(lines):
            if "server {" in lines[j] or "server{" in lines[j]:
                seen_server = True
            if seen_server and stop_re.match(lines[j]):
                break
            j += 1
        for k in range(i, j):
            if MODE == "replace":
                lines[k] = lines[k].replace(OLD, NEW)
            else:  # add: solo extender server_name
                m = re.match(r"(\s*server_name\s+)(.+?);", lines[k])
                if m and NEW not in m.group(2).split():
                    lines[k] = f"{m.group(1)}{m.group(2)} {NEW};"
        break
    i += 1
path.write_text("\n".join(lines) + "\n")
print("ok")
PYEOF
info "Vhost actualizado."

# ── 2. registry + .env (solo en modo reemplazo) ──────────────────────────────
if [[ "$MODE" == "replace" ]]; then
    if [[ -f projects-registry.conf ]] && grep -qE "^${PROYECTO}:${VERSION}:${ENTORNO}:" projects-registry.conf; then
        step "Actualizando projects-registry.conf..."
        sed -i -E "s|^(${PROYECTO}:${VERSION}:${ENTORNO}:)[^:]*(:.*)$|\1${NEW_DOMINIO}\2|" projects-registry.conf
        info "Registry actualizado."
    fi
    if [[ -f .env ]] && grep -qE "^DOMAIN_${PROY_UC}_${ENT_UC}=" .env; then
        step "Actualizando .env (DOMAIN_${PROY_UC}_${ENT_UC})..."
        sed -i -E "s|^(DOMAIN_${PROY_UC}_${ENT_UC}=).*$|\1${NEW_DOMINIO}|" .env
        info ".env actualizado."
    fi
fi

# ── 3. Cert provisional para el dominio nuevo (modo reemplazo) ────────────────
# El bloque 443 ya apunta a live/<nuevo>/. Sin un cert ahí, nginx -t falla y no
# recarga, por lo que el challenge ACME del nuevo dominio nunca se serviría.
if [[ "$MODE" == "replace" ]]; then
    if ! docker compose run --rm --entrypoint sh certbot -c \
        "[ -f /etc/letsencrypt/live/${NEW_DOMINIO}/fullchain.pem ]" 2>/dev/null; then
        step "Creando certificado provisional para ${NEW_DOMINIO}..."
        docker compose run --rm --entrypoint sh certbot -c \
            "mkdir -p /etc/letsencrypt/live/${NEW_DOMINIO} && \
             openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
                 -keyout /etc/letsencrypt/live/${NEW_DOMINIO}/privkey.pem \
                 -out    /etc/letsencrypt/live/${NEW_DOMINIO}/fullchain.pem \
                 -subj '/CN=${NEW_DOMINIO}' 2>/dev/null && \
             cp /etc/letsencrypt/live/${NEW_DOMINIO}/fullchain.pem \
                /etc/letsencrypt/live/${NEW_DOMINIO}/chain.pem" >/dev/null 2>&1
        info "Certificado provisional creado."
    fi
fi

# ── 4. Validar y recargar nginx (activa el bloque + sirve el challenge) ──────
step "Validando y recargando nginx..."
if docker compose exec -T nginx nginx -t 2>&1 | grep -q "successful"; then
    docker compose exec -T nginx nginx -s reload 2>/dev/null && info "Nginx recargado." \
        || warn "Nginx no respondió al reload."
else
    error "Config de nginx con errores tras editar el vhost. Revisa: docker compose exec nginx nginx -t"
fi

# ── 5. Emitir / expandir certificado real ────────────────────────────────────
SSL_OK=true
if $WITH_SSL; then
    title "SSL"
    if [[ "$MODE" == "replace" ]]; then
        emit_cert "$NEW_DOMINIO" "$NEW_DOMINIO" || SSL_OK=false
    else
        emit_cert "$OLD_DOMINIO" "$OLD_DOMINIO" "$NEW_DOMINIO" || SSL_OK=false
    fi
    if $SSL_OK; then
        docker compose exec -T nginx nginx -s reload 2>/dev/null && info "Nginx recargado con el cert real." || true
    fi
else
    warn "SSL omitido (--no-ssl). Emite el cert aparte cuando el DNS esté listo."
fi

# ── 6. Eliminar cert viejo (modo reemplazo) ──────────────────────────────────
if [[ "$MODE" == "replace" ]] && $WITH_SSL && $SSL_OK && ! $KEEP_OLD_CERT; then
    step "Eliminando certificado viejo (${OLD_DOMINIO})..."
    docker compose run --rm --entrypoint sh certbot -c \
        "rm -rf /etc/letsencrypt/live/${OLD_DOMINIO} \
                 /etc/letsencrypt/archive/${OLD_DOMINIO} \
                 /etc/letsencrypt/renewal/${OLD_DOMINIO}.conf" >/dev/null 2>&1 || true
    info "Cert viejo eliminado."
fi

# ── Resumen ──────────────────────────────────────────────────────────────────
title "Resumen final"
if [[ "$MODE" == "replace" ]]; then
    info "Dominio cambiado: ${OLD_DOMINIO} → ${NEW_DOMINIO}"
else
    info "Alias agregado: ${PROYECTO} responde a ${OLD_DOMINIO} y ${NEW_DOMINIO}"
fi
if $WITH_SSL && ! $SSL_OK; then
    warn "El SSL no se completó. El vhost ya usa el dominio nuevo (con cert provisional)."
    warn "Cuando el DNS resuelva, emite el cert con:  ./scripts/sync-projects.sh --ssl"
fi
echo ""
