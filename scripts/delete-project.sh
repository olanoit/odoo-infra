#!/usr/bin/env bash
# =============================================================================
# OLANOIT — delete-project.sh
# Detiene y elimina por completo un proyecto staging.
#
# USO:
#   ./scripts/delete-project.sh <proyecto> [<entorno>] [opciones]
#
# OPCIONES:
#   --dry-run         No ejecuta nada; solo muestra el resumen.
#   --keep-db         Conserva las bases de datos PostgreSQL del proyecto.
#   --keep-backups    Conserva el directorio ./backups/<proyecto>/.
#   --force           Salta la confirmación interactiva (USO CON CUIDADO).
#
# QUÉ ELIMINA (por defecto):
#   • Contenedor + volumen Docker (filestore + sessions Odoo).
#   • Todas las DBs que matcheen <proyecto>_<entorno>_*.
#   • Backups en ./backups/<proyecto>/.
#   • Certificado SSL (Let's Encrypt: live + archive + renewal).
#   • Bloques en docker-compose.yml, docker-compose.override.yml,
#     nginx upstreams y vhosts.
#   • Línea en projects-registry.conf y variable DOMAIN_* en .env.
#   • Directorio projects/<proyecto>/odoo<ver>/<entorno>/.
# =============================================================================

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
[[ -f .env ]] && source .env

# Colores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
title()   { echo -e "\n${BLUE}${BOLD}══ $* ══${NC}\n"; }
step()    { echo -e "${CYAN}  →${NC} $*"; }

show_help() {
    sed -n '2,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
}

# ── Parseo de argumentos ─────────────────────────────────────────────────────
PROYECTO=""
ENTORNO="sta"
DRY_RUN=false
KEEP_DB=false
KEEP_BACKUPS=false
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)       DRY_RUN=true ;;
        --keep-db)       KEEP_DB=true ;;
        --keep-backups)  KEEP_BACKUPS=true ;;
        --force)         FORCE=true ;;
        -h|--help)       show_help; exit 0 ;;
        --*)             error "Opción desconocida: $arg" ;;
        *)
            if [[ -z "$PROYECTO" ]]; then
                PROYECTO="$arg"
            else
                ENTORNO="$arg"
            fi
            ;;
    esac
done

[[ -z "$PROYECTO" ]] && { show_help; exit 1; }

# ── Detección del proyecto ───────────────────────────────────────────────────
CONTAINER_NAME=$(docker compose config --services 2>/dev/null \
    | grep -E "^odoo[0-9]+_${PROYECTO}_${ENTORNO}$" | head -1 || true)

if [[ -z "$CONTAINER_NAME" ]]; then
    # Fallback: buscar el contenedor por nombre real (puede que esté en compose
    # pero no se pueda parsear, o que se haya quedado sin compose).
    CONTAINER_NAME=$(docker ps -a --format '{{.Names}}' \
        | grep -E "^odoo[0-9]+_${PROYECTO}_${ENTORNO}$" | head -1 || true)
fi

[[ -z "$CONTAINER_NAME" ]] && \
    error "No encontré servicio o contenedor 'odoo*_${PROYECTO}_${ENTORNO}'. ¿Proyecto o entorno mal escrito?"

VERSION=$(echo "$CONTAINER_NAME" | sed -E 's/^odoo([0-9]+)_.*/\1/')
VOLUME_NAME="${CONTAINER_NAME}_data"
DB_PREFIX="${PROYECTO}_${ENTORNO}"
PROY_UC=$(echo "$PROYECTO" | tr '[:lower:]' '[:upper:]')
ENT_UC=$(echo "$ENTORNO"  | tr '[:lower:]' '[:upper:]')

# Dominio: primero de projects-registry.conf, luego de DOMAIN_* en .env
DOMINIO=""
if [[ -f projects-registry.conf ]]; then
    DOMINIO=$(grep -E "^${PROYECTO}:${VERSION}:${ENTORNO}:" projects-registry.conf \
              | head -1 | cut -d: -f4 || true)
fi
if [[ -z "$DOMINIO" ]]; then
    DOMINIO_VAR="DOMAIN_${PROY_UC}_${ENT_UC}"
    DOMINIO="${!DOMINIO_VAR:-}"
fi

# DBs del prefix
DBS=""
if docker ps --format '{{.Names}}' | grep -q '^odoo_postgres$'; then
    DBS=$(docker exec odoo_postgres psql -U "${POSTGRES_USER:-odoo}" -t -c \
        "SELECT datname FROM pg_database WHERE datname LIKE '${DB_PREFIX}_%' ORDER BY datname;" \
        2>/dev/null | tr -d ' ' | grep -v '^$' || true)
fi

# Tamaño de backups
BACKUPS_SIZE="-"
[[ -d "backups/${PROYECTO}" ]] && \
    BACKUPS_SIZE=$(du -sh "backups/${PROYECTO}" 2>/dev/null | cut -f1 || echo "-")

# Tamaño del volumen Docker (si existe)
VOL_SIZE="-"
if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
    VOL_PATH=$(docker volume inspect "$VOLUME_NAME" --format '{{.Mountpoint}}' 2>/dev/null || echo "")
    [[ -n "$VOL_PATH" && -d "$VOL_PATH" ]] && \
        VOL_SIZE=$(sudo du -sh "$VOL_PATH" 2>/dev/null | cut -f1 || echo "-")
fi

# ── Resumen ──────────────────────────────────────────────────────────────────
title "Eliminar proyecto: ${PROYECTO} (entorno: ${ENTORNO})"
printf "  %-25s %s\n" "Contenedor:"        "${CONTAINER_NAME}"
printf "  %-25s %s\n" "Volumen Docker:"    "${VOLUME_NAME} (${VOL_SIZE})"
printf "  %-25s %s\n" "Versión Odoo:"      "${VERSION}.0"
printf "  %-25s %s\n" "Dominio:"           "${DOMINIO:-(no detectado)}"
echo ""

echo "  Bases de datos (${DB_PREFIX}_*):"
if [[ -z "$DBS" ]]; then
    echo "    (ninguna)"
else
    while IFS= read -r db; do
        [[ -z "$db" ]] && continue
        local_size=$(docker exec odoo_postgres psql -U "${POSTGRES_USER:-odoo}" -tA -c \
            "SELECT pg_size_pretty(pg_database_size('$db'));" 2>/dev/null || echo "?")
        printf "    • %-40s %s\n" "$db" "$local_size"
    done <<< "$DBS"
fi
echo ""

printf "  %-25s %s\n" "Backups:"           "backups/${PROYECTO}/ (${BACKUPS_SIZE})"
printf "  %-25s %s\n" "Cert SSL:"          "${DOMINIO:+nginx/certbot/conf/{live,archive,renewal}/${DOMINIO}}"
printf "  %-25s %s\n" "Directorio:"        "projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/"
echo ""

# Acciones que se ejecutarán
echo -e "${BOLD}Acciones:${NC}"
echo "  ✗ Detener y eliminar contenedor"
echo "  ✗ Eliminar volumen Docker (filestore + sessions)"
$KEEP_DB        && echo "  ✓ ${GREEN}Conservar${NC} bases de datos (--keep-db)" \
                 || echo "  ✗ Eliminar bases de datos PostgreSQL"
$KEEP_BACKUPS   && echo "  ✓ ${GREEN}Conservar${NC} backups (--keep-backups)" \
                 || echo "  ✗ Eliminar backups (./backups/${PROYECTO}/)"
echo "  ✗ Eliminar certificado SSL (Let's Encrypt)"
echo "  ✗ Quitar bloques de docker-compose.yml, docker-compose.override.yml, nginx upstreams y vhosts"
echo "  ✗ Quitar entrada de projects-registry.conf y DOMAIN_* de .env"
echo "  ✗ Eliminar directorio projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/"
echo ""

if $DRY_RUN; then
    warn "DRY-RUN — no se ejecuta nada. Quitá --dry-run para aplicar."
    exit 0
fi

# ── Confirmación ─────────────────────────────────────────────────────────────
CONFIRM_TOKEN="BORRAR ${PROYECTO}_${ENTORNO}"
if ! $FORCE; then
    echo -e "${YELLOW}Esta operación es ${BOLD}IRREVERSIBLE${NC}${YELLOW} (excepto lo conservado con --keep-*).${NC}"
    echo ""
    echo -e "Para confirmar, escribí literalmente:  ${BOLD}${CONFIRM_TOKEN}${NC}"
    read -r -p "> " input
    [[ "$input" != "$CONFIRM_TOKEN" ]] && error "Confirmación incorrecta. Cancelado."
fi

# ── Ejecución ────────────────────────────────────────────────────────────────
title "Eliminando ${PROYECTO}_${ENTORNO}"

# 1. Detener y eliminar contenedor
step "Deteniendo contenedor ${CONTAINER_NAME}..."
docker compose stop "$CONTAINER_NAME" 2>/dev/null || true
docker compose rm -f "$CONTAINER_NAME" 2>/dev/null || \
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
info "Contenedor eliminado."

# 2. Eliminar bases de datos
if ! $KEEP_DB && [[ -n "$DBS" ]]; then
    step "Eliminando bases de datos..."
    while IFS= read -r db; do
        [[ -z "$db" ]] && continue
        if docker exec odoo_postgres dropdb -U "${POSTGRES_USER:-odoo}" --force --if-exists "$db" 2>/dev/null; then
            info "DB eliminada: $db"
        else
            warn "No se pudo eliminar DB: $db (¿hay conexiones residuales?)"
        fi
    done <<< "$DBS"
fi

# 3. Eliminar volumen Docker (filestore + sessions Odoo)
step "Eliminando volumen Docker ${VOLUME_NAME}..."
if docker volume rm "$VOLUME_NAME" 2>/dev/null; then
    info "Volumen Docker eliminado."
else
    warn "Volumen ${VOLUME_NAME} no existía o estaba en uso."
fi

# 4. Eliminar backups del volumen central
if ! $KEEP_BACKUPS && [[ -d "backups/${PROYECTO}" ]]; then
    step "Eliminando backups/${PROYECTO}/..."
    rm -rf "backups/${PROYECTO}"
    info "Backups eliminados."
fi

# 5. Eliminar certificado SSL
if [[ -n "$DOMINIO" ]]; then
    step "Eliminando certificado SSL de ${DOMINIO}..."
    docker compose run --rm --entrypoint sh certbot -c \
        "rm -rf /etc/letsencrypt/live/${DOMINIO} \
                 /etc/letsencrypt/archive/${DOMINIO} \
                 /etc/letsencrypt/renewal/${DOMINIO}.conf" 2>/dev/null || true
    info "Cert SSL eliminado."
fi

# 6+7+8. Quitar bloques en docker-compose.yml + nginx (Python: más robusto que awk
#        para esos archivos con headers multi-línea y delimitadores ambiguos).
step "Quitando entradas de docker-compose.yml y nginx..."

PROYECTO="$PROYECTO" ENTORNO="$ENTORNO" PROY_UC="$PROY_UC" ENT_UC="$ENT_UC" \
VOLUME_NAME="$VOLUME_NAME" CONTAINER_NAME="$CONTAINER_NAME" \
python3 - <<'PYEOF'
import os, re, pathlib

PROY_UC = os.environ["PROY_UC"]
ENT_UC  = os.environ["ENT_UC"]
VOLUME  = os.environ["VOLUME_NAME"]
CONT    = os.environ["CONTAINER_NAME"]
HEADER_RE = re.compile(rf"^\s*#\s*ODOO\s+\d+\s*\|\s*{re.escape(PROY_UC)}\s*\|\s*{re.escape(ENT_UC)}\s*$")

# ── docker-compose.yml ──────────────────────────────────────────────────────
# Bloque del servicio: comienza con "  # ---" 5 líneas antes del header,
# termina en la línea en blanco después del bloque YAML. Para evitar contar
# líneas: detectamos el header y descartamos hacia atrás hasta el primer
# "  # ---" inmediato, y hacia adelante hasta la primera línea en blanco
# que NO esté dentro de una clave YAML indentada.
path = pathlib.Path("docker-compose.yml")
lines = path.read_text().splitlines()
out, i = [], 0
while i < len(lines):
    if HEADER_RE.match(lines[i]):
        # Retroceder: quitar de out las líneas que pertenecen al header
        # (líneas con "  # " contiguas hasta y including el primer "  # ---")
        while out and out[-1].startswith("  #"):
            out.pop()
        # Avanzar i: saltar header + servicio hasta una línea en blanco
        # exterior al bloque (las líneas del servicio están indentadas con
        # al menos 4 espacios).
        while i < len(lines):
            ln = lines[i]
            if ln.strip() == "":
                i += 1
                break
            i += 1
        continue
    out.append(lines[i])
    i += 1

# Quitar el volumen declarado en la sección volumes:
text = "\n".join(out)
vol_block = re.compile(rf"^  {re.escape(VOLUME)}:\n    name: {re.escape(VOLUME)}\n?", re.M)
text = vol_block.sub("", text)

# Normalizar líneas en blanco consecutivas (máximo 1)
text = re.sub(r"\n{3,}", "\n\n", text)
path.write_text(text if text.endswith("\n") else text + "\n")


# ── nginx/conf.d/00-upstreams.conf ──────────────────────────────────────────
# Bloque upstream: empieza con "# --- ODOO X | PROY | ENT ---" y termina
# en la primera línea en blanco después del segundo "}" del bloque.
up_path = pathlib.Path("nginx/conf.d/00-upstreams.conf")
up_lines = up_path.read_text().splitlines()
out, i = [], 0
up_header = re.compile(rf"^# --- ODOO \d+ \| {re.escape(PROY_UC)} \| {re.escape(ENT_UC)} ---\s*$")
while i < len(up_lines):
    if up_header.match(up_lines[i]):
        # Skip hasta encontrar la primera línea en blanco después
        while i < len(up_lines) and up_lines[i].strip() != "":
            i += 1
        # Saltar también la línea en blanco
        if i < len(up_lines) and up_lines[i].strip() == "":
            i += 1
        continue
    out.append(up_lines[i])
    i += 1
text = "\n".join(out)
text = re.sub(r"\n{3,}", "\n\n", text)
up_path.write_text(text if text.endswith("\n") else text + "\n")


# ── nginx/conf.d/vhosts-projects.conf ───────────────────────────────────────
# Bloque vhost: header
#   # =====
#   # ODOO X | PROY | ENT
#   # Subdominio: ...
#   # =====
#   server { ... }
#   server { ... }
#
# Estrategia: detectar la línea con HEADER_RE, retroceder eliminando líneas
# del header (`#` o `=`) hasta el primer `# =====` previo (inclusive), y
# avanzar saltando líneas hasta encontrar la siguiente "# =====" o
# "# __SYNC_VHOSTS_INSERT__" o "# PLANTILLA".
vh_path = pathlib.Path("nginx/conf.d/vhosts-projects.conf")
vh_lines = vh_path.read_text().splitlines()
out, i = [], 0
sep_re   = re.compile(r"^# =+\s*$")
stop_re  = re.compile(r"^# (=+|__SYNC_VHOSTS_INSERT__|PLANTILLA)")
while i < len(vh_lines):
    if HEADER_RE.match(vh_lines[i]):
        # Retroceder: quitar el header previo
        while out and out[-1].startswith("#"):
            out.pop()
        # Avanzar: saltar header del bloque + dos server { } hasta encontrar
        # un stop_re (otra ==== o marcador). Pero hay que ignorar el segundo
        # ==== del propio header.
        j = i + 1
        seen_server = False
        while j < len(vh_lines):
            ln = vh_lines[j]
            if "server {" in ln or "server{" in ln:
                seen_server = True
            # Solo cortar en stop_re después de haber visto al menos un server
            if seen_server and stop_re.match(ln):
                break
            # También cortar antes si hay 2 líneas en blanco consecutivas
            j += 1
        i = j
        # Quitar líneas en blanco redundantes que quedaron antes del próximo bloque
        while out and out[-1].strip() == "":
            out.pop()
        out.append("")    # una sola línea en blanco de separación
        out.append("")    # bloque siguiente arranca con "# ====" tras 2 blanks
        continue
    out.append(vh_lines[i])
    i += 1

text = "\n".join(out)
text = re.sub(r"\n{4,}", "\n\n\n", text)
vh_path.write_text(text if text.endswith("\n") else text + "\n")

print(f"  · docker-compose.yml: removido servicio {CONT} + volumen {VOLUME}")
print(f"  · 00-upstreams.conf:  removido upstream {PROY_UC}/{ENT_UC}")
print(f"  · vhosts-projects.conf: removido vhost {PROY_UC}/{ENT_UC}")

# ── docker-compose.override.yml ─────────────────────────────────────────────
# Si existe, quitar el bloque del servicio. El YAML del override puede usar
# 2 o 4 espacios de indentación; aceptamos cualquiera.
ov_path = pathlib.Path("docker-compose.override.yml")
if ov_path.exists():
    ov_lines = ov_path.read_text().splitlines()
    out, i = [], 0
    svc_re = re.compile(rf"^(\s+){re.escape(CONT)}:\s*$")
    while i < len(ov_lines):
        m = svc_re.match(ov_lines[i])
        if m:
            base_indent = len(m.group(1))
            i += 1
            # Saltar líneas indentadas (parte del bloque) hasta otra clave al
            # mismo nivel o menos, o fin de archivo.
            while i < len(ov_lines):
                ln = ov_lines[i]
                if ln.strip() == "":
                    i += 1
                    continue
                cur_indent = len(ln) - len(ln.lstrip(" "))
                if cur_indent <= base_indent and ln.strip() != "":
                    break
                i += 1
            continue
        out.append(ov_lines[i])
        i += 1
    text = "\n".join(out)
    text = re.sub(r"\n{3,}", "\n\n", text)
    ov_path.write_text(text if text.endswith("\n") else text + "\n")
    print(f"  · docker-compose.override.yml: removido servicio {CONT} (si existía)")
PYEOF
info "Archivos del repo actualizados."

# 9. Quitar línea de projects-registry.conf
if [[ -f projects-registry.conf ]]; then
    step "Quitando línea de projects-registry.conf..."
    sed -i "/^${PROYECTO}:${VERSION}:${ENTORNO}:/d" projects-registry.conf
    info "Registry actualizado."
fi

# 10. Quitar DOMAIN_<PROY>_<ENT> de .env
if [[ -f .env ]]; then
    step "Quitando DOMAIN_${PROY_UC}_${ENT_UC} de .env..."
    sed -i "/^DOMAIN_${PROY_UC}_${ENT_UC}=/d" .env
    info ".env actualizado."
fi

# 11. Eliminar directorio del proyecto
PROJ_DIR_PATH="projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}"
if [[ -d "$PROJ_DIR_PATH" ]]; then
    step "Eliminando ${PROJ_DIR_PATH}..."
    rm -rf "$PROJ_DIR_PATH"
    # Limpiar parents si quedan vacíos
    rmdir "projects/${PROYECTO}/odoo${VERSION}" 2>/dev/null || true
    rmdir "projects/${PROYECTO}"                  2>/dev/null || true
    info "Directorio eliminado."
fi

# 12. Validar y recargar nginx
step "Validando nginx y recargando..."
if docker compose exec -T nginx nginx -t 2>&1 | tail -2 | grep -q "successful"; then
    docker compose exec -T nginx nginx -s reload 2>/dev/null \
        && info "Nginx recargado." \
        || warn "Nginx no respondió al reload. Reiniciá manual: docker compose restart nginx"
else
    warn "Config de nginx tiene errores tras el borrado. Revisá: docker compose exec nginx nginx -t"
fi

echo ""
title "Resumen final"
info "Proyecto ${PROYECTO} (${ENTORNO}) eliminado."
$KEEP_DB      && info "Bases de datos CONSERVADAS (--keep-db)."
$KEEP_BACKUPS && info "Backups CONSERVADOS en backups/${PROYECTO}/."
echo ""
echo "Estado actual:"
docker compose ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null || true
