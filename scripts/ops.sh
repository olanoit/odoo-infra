#!/usr/bin/env bash
# =============================================================================
# EXTENDRIX — ops.sh | Script central de operaciones
# Uso: ./scripts/ops.sh <comando> [opciones]
# Ver ayuda: ./scripts/ops.sh help
# =============================================================================

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# Cargar .env si existe
[[ -f .env ]] && source .env

# Colores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
title()   { echo -e "\n${BLUE}${BOLD}══ $* ══${NC}\n"; }
step()    { echo -e "${CYAN}  →${NC} $*"; }

CMD="${1:-help}"

# =============================================================================
# start — Inicia todos los servicios en orden correcto
# =============================================================================
cmd_start() {
    title "Iniciando entorno Odoo"

    step "Base de datos PostgreSQL..."
    docker compose up -d db
    step "Esperando healthcheck de PostgreSQL..."
    local retries=30
    until docker compose exec -T db pg_isready -U "${POSTGRES_USER:-odoo}" &>/dev/null; do
        retries=$((retries - 1))
        [[ $retries -eq 0 ]] && error "PostgreSQL no levantó en 30 intentos"
        sleep 2
    done
    info "PostgreSQL listo."

    step "Instancias Odoo..."
    # Levantar Odoo ANTES que nginx para que el DNS interno resuelva los upstreams
    local odoo_services
    odoo_services=$(docker compose config --services | grep '^odoo' | tr '\n' ' ')
    if [[ -n "$odoo_services" ]]; then
        # shellcheck disable=SC2086
        docker compose up -d $odoo_services
    fi

    step "Nginx y Certbot..."
    docker compose up -d nginx certbot
    sleep 3

    echo ""
    info "Entorno iniciado."
    cmd_health
}

# =============================================================================
# stop — Detiene todos los servicios
# =============================================================================
cmd_stop() {
    title "Deteniendo entorno"
    docker compose down
    info "Todos los servicios detenidos (datos conservados)."
}

# =============================================================================
# restart — Reinicia uno o todos los servicios
# ./scripts/ops.sh restart [nombre_contenedor]
# =============================================================================
cmd_restart() {
    local service="${2:-}"
    if [[ -n "$service" ]]; then
        title "Reiniciando: $service"
        docker compose restart "$service"
        info "$service reiniciado."
    else
        title "Reiniciando todos los servicios"
        docker compose restart
        info "Todos los servicios reiniciados."
    fi
}

# =============================================================================
# logs — Ver logs de un contenedor
# ./scripts/ops.sh logs <contenedor> [N_lineas] [--raw]
#
# Por defecto filtra el ruido de cron entre proyectos:
#   "Skipping database X as its base version is not Y"
# Esto pasa porque postgres es compartido entre todos los Odoo y cada cron
# enumera todas las DBs; al ver una de otra versión, loguea un WARNING.
#
# Usá --raw para ver el log sin filtro (debugging del propio cron, etc).
# =============================================================================
cmd_logs() {
    # Parseo de args ignorando posición de --raw
    local service="" lines=200
    local raw=false
    shift   # consumir 'logs'
    for arg in "$@"; do
        case "$arg" in
            --raw) raw=true ;;
            [0-9]*) lines="$arg" ;;
            *) [[ -z "$service" ]] && service="$arg" ;;
        esac
    done

    # Patrón de ruido de cron entre proyectos (Odoo 17/18/19)
    local noise_pattern='Skipping database .* as its base version is not'

    if [[ -z "$service" ]]; then
        if $raw; then
            docker compose logs -f --tail=50
        else
            docker compose logs -f --tail=50 \
                | grep --line-buffered -vE "$noise_pattern"
        fi
    else
        if $raw; then
            docker compose logs -f --tail="$lines" "$service"
        else
            docker compose logs -f --tail="$lines" "$service" \
                | grep --line-buffered -vE "$noise_pattern"
        fi
    fi
}

# =============================================================================
# health — Estado de todos los contenedores
# =============================================================================
cmd_health() {
    title "Estado del entorno"
    printf "${BOLD}%-30s %-12s %-10s %-20s${NC}\n" "CONTENEDOR" "ESTADO" "SALUD" "IMAGEN"
    printf "%-30s %-12s %-10s %-20s\n" "──────────────────────────────" "────────────" "──────────" "────────────────────"

    while IFS= read -r container; do
        local status health image
        status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "no existe")
        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$container" 2>/dev/null || echo "n/a")
        image=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null || echo "?")

        local color="$NC"
        [[ "$status" == "running" && ("$health" == "healthy" || "$health" == "n/a") ]] && color="$GREEN"
        [[ "$status" != "running" ]] && color="$RED"
        [[ "$health" == "unhealthy" ]] && color="$YELLOW"

        printf "${color}%-30s %-12s %-10s %-20s${NC}\n" "$container" "$status" "$health" "$image"
    done < <(docker compose ps --format '{{.Name}}' 2>/dev/null)

    echo ""
    local domain_vars
    domain_vars=$(compgen -v 2>/dev/null | grep '^DOMAIN_' || true)
    if [[ -n "$domain_vars" ]]; then
        info "Dominios configurados:"
        while IFS= read -r key; do
            val="${!key:-}"
            [[ -n "$val" ]] && echo "    https://$val"
        done <<< "$domain_vars"
    else
        warn "No hay variables DOMAIN_* en .env — agrega una por cada instancia"
    fi
}

# =============================================================================
# module — Instalar/actualizar/desinstalar un módulo Odoo
# ./scripts/ops.sh module <contenedor> <db> <modulo> <install|update|uninstall>
# =============================================================================
cmd_module() {
    local container="${2:-}"
    local database="${3:-}"
    local module="${4:-}"
    local action="${5:-update}"

    [[ -z "$container" ]] && error "Falta: contenedor. Uso: ops.sh module <contenedor> <db> <modulo> <accion>"
    [[ -z "$database" ]] && error "Falta: base de datos."
    [[ -z "$module"    ]] && error "Falta: nombre del módulo."

    title "Módulo Odoo: $action → $module"
    step "Contenedor : $container"
    step "Base datos : $database"
    step "Módulo     : $module"
    step "Acción     : $action"
    echo ""

    local flag
    case "$action" in
        install)    flag="--init=$module" ;;
        update)     flag="--update=$module" ;;
        uninstall)
            warn "Desinstalar un módulo puede dejar datos huérfanos en la DB."
            read -rp "¿Confirmar desinstalación de '$module'? (yes/no): " confirm
            [[ "$confirm" != "yes" ]] && { warn "Cancelado."; return; }
            # La desinstalación se hace vía Python RPC, no por CLI
            docker exec -it "$container" python3 -c "
import xmlrpc.client
url = 'http://localhost:8069'
uid = xmlrpc.client.ServerProxy(url + '/xmlrpc/2/common').authenticate('$database', 'admin', '', {})
xmlrpc.client.ServerProxy(url + '/xmlrpc/2/object').execute_kw(
    '$database', uid, '',
    'ir.module.module', 'button_uninstall',
    [[xmlrpc.client.ServerProxy(url + '/xmlrpc/2/object').execute_kw(
        '$database', uid, '', 'ir.module.module', 'search',
        [[['name', '=', '$module']]]
    )[0]]],
)
print('Desinstalación iniciada. Revisa la interfaz Odoo.')
" 2>&1 || warn "Error en desinstalación por RPC. Intenta desde la interfaz."
            return
            ;;
        *)  error "Acción no válida. Usa: install | update | uninstall" ;;
    esac

    warn "Odoo se detendrá brevemente para aplicar el cambio..."

    # `docker exec` BYPASSEA el entrypoint del contenedor — por eso pasamos
    # explícitamente db_host/port/user/password (que normalmente la imagen
    # oficial inyecta desde las env vars HOST/PORT/USER/PASSWORD).
    [[ -z "${POSTGRES_PASSWORD:-}" ]] && error "POSTGRES_PASSWORD no está definido en .env"
    # --no-http: el contenedor ya tiene el Odoo principal escuchando en 8069/8072;
    # sin esta flag, el segundo proceso intenta bindear el mismo puerto y falla
    # con "Address already in use".
    docker exec "$container" odoo \
        --config=/etc/odoo/odoo.conf \
        --db_host=db \
        --db_port=5432 \
        --db_user="${POSTGRES_USER:-odoo}" \
        --db_password="${POSTGRES_PASSWORD}" \
        --database="$database" \
        "$flag" \
        --no-http \
        --stop-after-init \
        2>&1 | grep -v "^$" | tail -80

    info "Operación completada. Reiniciando servicio..."
    docker compose restart "$container"
    info "Listo. Módulo '$module' — $action aplicado en '$database'."
}

# =============================================================================
# Volumen central de backups (bind-mount ./backups → /backups en contenedores)
# Estructura: ./backups/<proyecto>/db/    y    ./backups/<proyecto>/filestore/
# =============================================================================
BACKUPS_HOST_DIR="$PROJECT_DIR/backups"

# Resuelve el path /backups/<proyecto>/<sub> dentro de los contenedores.
_backup_path_in_container() {
    local project="$1" sub="$2"   # sub = db | filestore
    echo "/backups/${project}/${sub}"
}

# Resuelve el path equivalente en el host.
_backup_path_on_host() {
    local project="$1" sub="$2"
    echo "${BACKUPS_HOST_DIR}/${project}/${sub}"
}

# =============================================================================
# backup — Backup de una DB de staging + su filestore en el volumen central
# ./scripts/ops.sh backup <proyecto> <contenedor> <base_de_datos>
#
# Genera:
#   ./backups/<proyecto>/db/<TS>_<db>.sql.gz
#   ./backups/<proyecto>/filestore/<TS>_<db>_filestore.tar.gz
# =============================================================================
cmd_backup() {
    local project="${2:-}"
    local container="${3:-}"
    local database="${4:-}"

    [[ -z "$project"   ]] && error "Uso: ops.sh backup <proyecto> <contenedor> <base_de_datos>"
    [[ -z "$container" ]] && error "Falta: contenedor"
    [[ -z "$database"  ]] && error "Falta: base de datos"

    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local db_host_dir;        db_host_dir=$(_backup_path_on_host "$project" "db")
    local fs_host_dir;        fs_host_dir=$(_backup_path_on_host "$project" "filestore")
    local db_in_container;    db_in_container=$(_backup_path_in_container "$project" "db")
    local fs_in_container;    fs_in_container=$(_backup_path_in_container "$project" "filestore")
    local db_filename="${ts}_${database}.sql.gz"
    local fs_filename="${ts}_${database}_filestore.tar.gz"

    mkdir -p "$db_host_dir" "$fs_host_dir"

    title "Backup: $database → $project"
    step "Volumen   : $BACKUPS_HOST_DIR (→ /backups en contenedores)"
    step "DB        : $db_host_dir/$db_filename"
    step "Filestore : $fs_host_dir/$fs_filename"

    # Verificar que la DB existe
    docker exec odoo_postgres psql -U "${POSTGRES_USER:-odoo}" -lqt | \
        cut -d\| -f1 | grep -qw "$database" || \
        error "La base de datos '$database' no existe."

    # ── DB dump (pg_dump dentro de postgres, escribe directo al volumen) ──────
    step "Dump de PostgreSQL..."
    docker exec odoo_postgres sh -c "mkdir -p '$db_in_container' && \
        pg_dump -U '${POSTGRES_USER:-odoo}' --no-owner --no-acl --format=plain '$database' \
        | gzip > '$db_in_container/$db_filename'"

    local size; size=$(du -sh "$db_host_dir/$db_filename" | cut -f1)
    info "DB: $db_filename ($size)"

    # ── Filestore (tar dentro del contenedor odoo, lee del volumen Odoo) ──────
    # Usamos --user root porque la imagen oficial fija USER odoo y ese UID
    # no tiene permisos para escribir en /backups (creado por root en el host).
    step "Backup filestore..."
    if docker exec -u root "$container" sh -c "[ -d '/var/lib/odoo/filestore/$database' ]" 2>/dev/null; then
        docker exec -u root "$container" sh -c "mkdir -p '$fs_in_container' && \
            tar czf '$fs_in_container/$fs_filename' -C /var/lib/odoo 'filestore/$database'"
        local fs_size; fs_size=$(du -sh "$fs_host_dir/$fs_filename" | cut -f1)
        info "Filestore: $fs_filename ($fs_size)"
    else
        warn "Filestore no encontrado en $container:/var/lib/odoo/filestore/$database (DB sin adjuntos aún)."
    fi
}

# =============================================================================
# backup-all — Backup de todas las DBs de staging detectadas en PostgreSQL
# =============================================================================
cmd_backup_all() {
    title "Backup completo — todas las DBs de staging"

    local all_dbs
    all_dbs=$(docker exec odoo_postgres psql -U "${POSTGRES_USER:-odoo}" -t -c \
        "SELECT datname FROM pg_database WHERE datistemplate=false AND datname!='postgres' ORDER BY datname;" \
        | tr -d ' ' | grep -v '^$')

    local count=0
    while IFS= read -r db; do
        [[ -z "$db" ]] && continue

        # Convención: <proyecto>_sta_<sufijo>  →  proyecto = primer segmento
        local project
        project=$(echo "$db" | cut -d_ -f1)

        # Buscar el contenedor cuyo dbfilter haga match con esta DB
        local container=""
        while IFS= read -r svc; do
            local svc_proyecto svc_entorno
            svc_proyecto=$(echo "$svc" | awk -F_ '{print $2}')
            svc_entorno=$(echo  "$svc" | awk -F_ '{print $3}')
            if [[ "$db" =~ ^${svc_proyecto}_${svc_entorno}_ ]]; then
                container="$svc"
                break
            fi
        done < <(docker compose ps --format '{{.Name}}' 2>/dev/null | grep "^odoo[0-9]")

        if [[ -z "$container" ]]; then
            warn "No encontré contenedor para '$db' — omitiendo filestore."
            container="odoo_postgres"   # fallback: solo DB
        fi

        step "Respaldando: $db (proyecto=$project, contenedor=$container)"
        cmd_backup "" "$project" "$container" "$db" 2>&1 | grep -E "\[✓\]|\[!\]|\[✗\]" || true
        count=$((count + 1))
    done <<< "$all_dbs"

    info "Backup completado: $count bases de datos respaldadas."
}

# =============================================================================
# list-backups — Listar backups disponibles en el volumen central
# ./scripts/ops.sh list-backups [<proyecto>]
# =============================================================================
cmd_list_backups() {
    local project="${2:-}"
    title "Backups en $BACKUPS_HOST_DIR"

    if [[ ! -d "$BACKUPS_HOST_DIR" ]]; then
        warn "No existe el directorio $BACKUPS_HOST_DIR (todavía no se ha hecho ningún backup)."
        return
    fi

    local glob
    if [[ -n "$project" ]]; then
        glob="$BACKUPS_HOST_DIR/$project"
        [[ ! -d "$glob" ]] && { warn "Sin backups para el proyecto '$project'."; return; }
    else
        glob="$BACKUPS_HOST_DIR"
    fi

    for proj_dir in "$glob"/*/; do
        [[ -d "$proj_dir" ]] || continue
        local proj; proj=$(basename "$proj_dir")
        # Si filtramos por proyecto, $proj_dir ya es el de db/filestore
        if [[ -n "$project" && "$proj" =~ ^(db|filestore)$ ]]; then
            proj="$project"
            proj_dir="$glob"
        fi

        echo -e "${BOLD}── $proj ──${NC}"
        if [[ -d "$proj_dir/db" ]]; then
            echo "  DB:"
            ls -1tr "$proj_dir/db" 2>/dev/null | sed 's/^/    /' || true
        fi
        if [[ -d "$proj_dir/filestore" ]]; then
            echo "  Filestore:"
            ls -1tr "$proj_dir/filestore" 2>/dev/null | sed 's/^/    /' || true
        fi
        echo ""
        [[ -n "$project" ]] && break
    done
}

# =============================================================================
# restore — Restaurar DB + (opcional) filestore desde el volumen central
# ./scripts/ops.sh restore <contenedor> <db_destino> <db_backup> [<filestore_backup>]
#
# - <db_backup> / <filestore_backup>: rutas en el HOST o rutas relativas a ./backups/
# - Si se omite el filestore, se intenta auto-detectar uno con el mismo timestamp.
# - Si la DB destino ya existe, se aborta (usa dropdb para sobrescribir).
# =============================================================================
cmd_restore() {
    local container="${2:-}"
    local target_db="${3:-}"
    local backup_file="${4:-}"
    local filestore_arg="${5:-}"

    [[ -z "$container"   ]] && error "Uso: ops.sh restore <contenedor> <db_destino> <db_backup> [<filestore_backup>]"
    [[ -z "$target_db"   ]] && error "Falta: nombre de DB destino"
    [[ -z "$backup_file" ]] && error "Falta: archivo de backup de DB"

    # Resolver rutas relativas a ./backups/ si no son absolutas
    if [[ "$backup_file" != /* && ! -f "$backup_file" ]]; then
        [[ -f "$BACKUPS_HOST_DIR/$backup_file" ]] && backup_file="$BACKUPS_HOST_DIR/$backup_file"
    fi
    [[ ! -f "$backup_file" ]] && error "Archivo de DB no encontrado: $backup_file"

    # Validar dbfilter del contenedor de staging
    local svc_proyecto svc_entorno
    svc_proyecto=$(echo "$container" | awk -F_ '{print $2}')
    svc_entorno=$(echo  "$container" | awk -F_ '{print $3}')
    if [[ -n "$svc_proyecto" && -n "$svc_entorno" && ! "$target_db" =~ ^${svc_proyecto}_${svc_entorno}_ ]]; then
        warn "El nombre '$target_db' no coincide con el dbfilter ${svc_proyecto}_${svc_entorno}_*"
        warn "Odoo no la mostrará en el selector hasta que cumpla esa convención."
    fi

    # Auto-detección del filestore por timestamp si no se especificó
    if [[ -z "$filestore_arg" ]]; then
        local base_ts ts_match
        base_ts=$(basename "$backup_file" | grep -oE '^[0-9]{8}_[0-9]{6}' || true)
        if [[ -n "$base_ts" ]]; then
            ts_match=$(find "$BACKUPS_HOST_DIR" -name "${base_ts}_*_filestore.tar.gz" 2>/dev/null | head -1)
            [[ -n "$ts_match" ]] && filestore_arg="$ts_match"
        fi
    fi
    if [[ -n "$filestore_arg" ]]; then
        if [[ "$filestore_arg" != /* && ! -f "$filestore_arg" ]]; then
            [[ -f "$BACKUPS_HOST_DIR/$filestore_arg" ]] && filestore_arg="$BACKUPS_HOST_DIR/$filestore_arg"
        fi
        [[ ! -f "$filestore_arg" ]] && error "Archivo de filestore no encontrado: $filestore_arg"
    fi

    title "Restaurar backup"
    step "Contenedor : $container"
    step "DB destino : $target_db"
    step "DB backup  : $backup_file"
    if [[ -n "$filestore_arg" ]]; then
        step "Filestore  : $filestore_arg"
    else
        step "Filestore  : (no se restaurará — no se encontró archivo)"
    fi
    echo ""

    # Comprobar que la DB destino no existe
    if docker exec odoo_postgres psql -U "${POSTGRES_USER:-odoo}" -lqt | cut -d\| -f1 | grep -qw "$target_db"; then
        error "La DB '$target_db' ya existe. Bórrala primero con: docker exec odoo_postgres dropdb -U ${POSTGRES_USER:-odoo} $target_db"
    fi

    warn "Se creará la DB '$target_db' y se restaurarán datos + filestore."
    read -rp "¿Confirmar restauración? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { warn "Cancelado."; return; }

    # ── DB ────────────────────────────────────────────────────────────────────
    step "Creando DB vacía..."
    docker exec odoo_postgres createdb -U "${POSTGRES_USER:-odoo}" "$target_db"

    step "Restaurando datos SQL..."
    zcat "$backup_file" | docker exec -i odoo_postgres \
        psql -U "${POSTGRES_USER:-odoo}" -d "$target_db" -q -v ON_ERROR_STOP=1 > /dev/null

    # ── Filestore ─────────────────────────────────────────────────────────────
    if [[ -n "$filestore_arg" ]]; then
        step "Restaurando filestore..."
        local fs_basename; fs_basename=$(basename "$filestore_arg")
        local in_container_path="/backups/_restore_tmp/$fs_basename"

        # Copiar el tar al volumen /backups si no está ya allí
        if [[ "$filestore_arg" != "$BACKUPS_HOST_DIR/"* ]]; then
            mkdir -p "$BACKUPS_HOST_DIR/_restore_tmp"
            cp "$filestore_arg" "$BACKUPS_HOST_DIR/_restore_tmp/$fs_basename"
        else
            in_container_path="${filestore_arg/$BACKUPS_HOST_DIR/\/backups}"
        fi

        # Extraer dentro de odoo:/var/lib/odoo/ y renombrar al nombre de la DB destino.
        # --user root: necesario para escribir en /backups y para chown final al usuario odoo.
        docker exec -u root "$container" sh -c "
            set -e
            rm -rf /tmp/_restore_fs && mkdir -p /tmp/_restore_fs
            tar xzf '$in_container_path' -C /tmp/_restore_fs
            src=\$(ls -d /tmp/_restore_fs/filestore/*/ | head -1)
            mkdir -p /var/lib/odoo/filestore
            rm -rf '/var/lib/odoo/filestore/$target_db'
            mv \"\$src\" '/var/lib/odoo/filestore/$target_db'
            chown -R odoo:odoo '/var/lib/odoo/filestore/$target_db' 2>/dev/null || true
            rm -rf /tmp/_restore_fs
        "
        # Limpiar copia temporal en /backups si la hicimos nosotros
        [[ -d "$BACKUPS_HOST_DIR/_restore_tmp" ]] && rm -rf "$BACKUPS_HOST_DIR/_restore_tmp"
        info "Filestore restaurado en /var/lib/odoo/filestore/$target_db"
    fi

    info "Restauración completada. DB: $target_db"
    info "Reiniciando $container para que detecte la nueva DB..."
    docker compose restart "$container"
}

# =============================================================================
# restore-external — Restaurar backup proveniente de OTRO servidor
# ./scripts/ops.sh restore-external <contenedor> <db_destino> <archivo>
#
# Formatos soportados (auto-detectados por extensión):
#   .tar.gz / .tgz   archivo con dump.sql (o dump.sql.gz) + (opcional) filestore/
#   .zip             formato nativo de Odoo (dump.sql + filestore/ + manifest.json)
#   .sql.gz          SQL plano comprimido (sin filestore)
#   .sql             SQL plano (sin filestore)
#
# Diferencias vs. `restore`:
#   - Acepta cualquier ruta absoluta (no exige ./backups/)
#   - Remapea OWNER de objetos al rol 'odoo' del staging
#   - Neutraliza líneas \connect y CREATE DATABASE del dump
#   - Carga con ON_ERROR_STOP=0 (los errores menores no abortan)
#   - El filestore puede venir en formato Odoo nativo (filestore/ con hash dirs)
# =============================================================================
cmd_restore_external() {
    local container="${2:-}"
    local target_db="${3:-}"
    local archive="${4:-}"

    [[ -z "$container" ]] && error "Uso: ops.sh restore-external <contenedor> <db_destino> <archivo>"
    [[ -z "$target_db" ]] && error "Falta: nombre de DB destino"
    [[ -z "$archive"   ]] && error "Falta: ruta al archivo de backup"
    [[ ! -f "$archive" ]] && error "Archivo no encontrado: $archive"

    # Validar dbfilter (advertencia, no error)
    local svc_proyecto svc_entorno
    svc_proyecto=$(echo "$container" | awk -F_ '{print $2}')
    svc_entorno=$(echo  "$container" | awk -F_ '{print $3}')
    if [[ -n "$svc_proyecto" && -n "$svc_entorno" && ! "$target_db" =~ ^${svc_proyecto}_${svc_entorno}_ ]]; then
        warn "El nombre '$target_db' no coincide con el dbfilter ${svc_proyecto}_${svc_entorno}_*"
        warn "Odoo no la mostrará en el selector hasta que respete esa convención."
    fi

    # Detectar formato
    local fmt=""
    case "$archive" in
        *.tar.gz|*.tgz) fmt="tar" ;;
        *.zip)          fmt="zip" ;;
        *.sql.gz)       fmt="sql_gz" ;;
        *.sql)          fmt="sql" ;;
        *) error "Extensión no soportada: $archive (use .tar.gz, .tgz, .zip, .sql.gz o .sql)" ;;
    esac

    title "Restaurar backup externo"
    step "Archivo    : $archive ($(du -h "$archive" | cut -f1))"
    step "Formato    : $fmt"
    step "Contenedor : $container"
    step "DB destino : $target_db"

    local owner="${POSTGRES_USER:-odoo}"

    # ── Inspección STREAMING del archivo (sin extraer 31 GB a disco) ─────────
    # Buscamos las entradas SQL y filestore a CUALQUIER profundidad.
    # Importante: deshabilitamos set -e temporalmente porque los `grep` que no
    # encuentran coincidencias salen con código 1 y con `pipefail` matarían
    # el script silenciosamente dentro del `$(...)`.
    local listing="" sql_entry="" sql_compressed=false
    local fs_entry="" fs_type=""   # "tar" (.tar.gz anidado) | "dir" (filestore/)

    set +e
    if [[ "$fmt" == "tar" ]]; then
        step "Inspeccionando contenido del archivo (tar -tzf)..."
        listing=$(tar -tzf "$archive" 2>/dev/null | head -5000)
        if [[ -z "$listing" ]]; then
            set -e
            error "No se pudo listar el contenido del tar.gz (¿archivo corrupto o no es un tar.gz?)"
        fi

        # Dump SQL (prefiere nombres con 'dump' o '_db_')
        sql_entry=$(echo "$listing" | grep -E '\.sql\.gz$' | grep -iE 'dump|_db_' | head -1)
        [[ -z "$sql_entry" ]] && sql_entry=$(echo "$listing" | grep -E '\.sql$' | grep -iE 'dump|_db_' | head -1)
        [[ -z "$sql_entry" ]] && sql_entry=$(echo "$listing" | grep -E '\.sql\.gz$' | head -1)
        [[ -z "$sql_entry" ]] && sql_entry=$(echo "$listing" | grep -E '\.sql$' | head -1)

        # Filestore: prefiere tar.gz anidado, fallback a directorio
        fs_entry=$(echo "$listing" | grep -iE 'filestore[^/]*\.(tar\.gz|tgz)$' | head -1)
        if [[ -n "$fs_entry" ]]; then
            fs_type="tar"
        else
            # Buscar la entrada de directorio "filestore/"; si no existe
            # (algunos tar no la incluyen), derivar el prefijo desde la ruta de
            # cualquier archivo bajo .../filestore/ (ej: "filestore/74/abc..." → "filestore/").
            fs_entry=$(echo "$listing" | grep -E '(^|/)filestore/$' | head -1)
            if [[ -z "$fs_entry" ]]; then
                fs_entry=$(echo "$listing" | grep -E '(^|/)filestore/.' | head -1 \
                    | sed -E 's#(.*/)?(filestore/).*#\1\2#')
            fi
            [[ -n "$fs_entry" ]] && fs_type="dir"
        fi

    elif [[ "$fmt" == "zip" ]]; then
        set -e
        command -v unzip >/dev/null 2>&1 || error "Se requiere 'unzip' (apt install unzip)"
        set +e
        step "Inspeccionando contenido del archivo (unzip -Z1)..."
        listing=$(unzip -Z1 "$archive" 2>/dev/null)
        if [[ -z "$listing" ]]; then
            set -e
            error "No se pudo listar el contenido del zip"
        fi

        sql_entry=$(echo "$listing" | grep -E '\.sql\.gz$' | grep -iE 'dump|_db_' | head -1)
        [[ -z "$sql_entry" ]] && sql_entry=$(echo "$listing" | grep -E '\.sql$' | grep -iE 'dump|_db_' | head -1)
        [[ -z "$sql_entry" ]] && sql_entry=$(echo "$listing" | grep -E '\.sql\.gz$' | head -1)
        [[ -z "$sql_entry" ]] && sql_entry=$(echo "$listing" | grep -E '\.sql$' | head -1)

        fs_entry=$(echo "$listing" | grep -iE 'filestore[^/]*\.(tar\.gz|tgz)$' | head -1)
        if [[ -n "$fs_entry" ]]; then
            fs_type="tar"
        else
            # Los .zip nativos de Odoo NO incluyen la entrada de directorio
            # "filestore/", solo los archivos sueltos "filestore/<XX>/<sha>".
            # Buscamos primero la entrada de dir y, si no existe, derivamos el
            # prefijo desde la ruta de cualquier archivo del filestore.
            fs_entry=$(echo "$listing" | grep -E '^([^/]+/)*filestore/$' | head -1)
            if [[ -z "$fs_entry" ]]; then
                fs_entry=$(echo "$listing" | grep -E '(^|/)filestore/.' | head -1 \
                    | sed -E 's#(.*/)?(filestore/).*#\1\2#')
            fi
            [[ -n "$fs_entry" ]] && fs_type="dir"
        fi
    fi
    set -e

    # Validaciones
    if [[ "$fmt" == "tar" || "$fmt" == "zip" ]]; then
        [[ -z "$sql_entry" ]] && error "No se encontró ningún dump SQL (.sql o .sql.gz) dentro de $archive"
        [[ "$sql_entry" == *.gz ]] && sql_compressed=true
    fi

    # Resumen de lo encontrado
    if [[ "$fmt" == "tar" || "$fmt" == "zip" ]]; then
        step "SQL hallado     : $sql_entry$([ "$sql_compressed" = "true" ] && echo ' (comprimido)')"
        if [[ -n "$fs_entry" ]]; then
            step "Filestore hallado: $fs_entry (tipo: $fs_type)"
        else
            step "Filestore hallado: (ninguno — la DB no tendrá adjuntos)"
        fi
    fi
    echo ""

    # Verificar estado de la DB destino
    local db_exists=false db_empty=false
    if docker exec odoo_postgres psql -U "$owner" -lqt | cut -d\| -f1 | grep -qw "$target_db"; then
        db_exists=true
        local tbl_count
        tbl_count=$(docker exec odoo_postgres psql -U "$owner" -d "$target_db" -tAc \
            "SELECT count(*) FROM pg_tables WHERE schemaname='public'" 2>/dev/null | tr -d ' ')
        tbl_count=${tbl_count:-0}
        if [[ "$tbl_count" == "0" ]]; then
            db_empty=true
            warn "La DB '$target_db' EXISTE pero está vacía (intento previo abortado)."
            warn "Se descartará y volveremos a crearla."
        else
            error "La DB '$target_db' ya existe y tiene $tbl_count tablas. Sobrescribí con:
    docker exec odoo_postgres dropdb -U $owner --force $target_db"
        fi
    fi

    warn "Se creará la DB '$target_db' y se cargará el backup externo (streaming)."
    warn "Owner de todos los objetos será remapeado al rol '$owner'."
    if [[ "$fmt" == "tar" && -n "$fs_entry" ]]; then
        warn "Archivo de 31 GB → la lectura se hace en DOS pases: 1) SQL  2) filestore."
    fi
    read -rp "¿Confirmar restauración? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { warn "Cancelado."; return; }

    # ── Crear DB vacía ───────────────────────────────────────────────────────
    if $db_empty; then
        step "Eliminando DB vacía previa '$target_db'..."
        docker exec odoo_postgres dropdb -U "$owner" --force "$target_db"
    fi
    step "Creando DB vacía '$target_db'..."
    docker exec odoo_postgres createdb -U "$owner" "$target_db"

    # ── Stream SQL → sed (remap) → psql ──────────────────────────────────────
    step "Pase 1/2 — Cargando dump SQL (remapeando OWNER → $owner)..."
    local err_log; err_log=$(mktemp)
    local sed_filter="s/(OWNER TO )\"?[A-Za-z0-9_]+\"?/\1$owner/g; s/^(SET ROLE [^;]+;)/-- \1/g; s/^(CREATE DATABASE )/-- \1/g; s/^(\\\\connect )/-- \1/g"

    set +e
    case "$fmt" in
        sql)
            sed -E "$sed_filter" "$archive" \
                | docker exec -i odoo_postgres psql -U "$owner" -d "$target_db" -q -v ON_ERROR_STOP=0 \
                    >/dev/null 2>"$err_log"
            ;;
        sql_gz)
            zcat "$archive" | sed -E "$sed_filter" \
                | docker exec -i odoo_postgres psql -U "$owner" -d "$target_db" -q -v ON_ERROR_STOP=0 \
                    >/dev/null 2>"$err_log"
            ;;
        tar)
            if $sql_compressed; then
                tar -xzOf "$archive" "$sql_entry" | zcat | sed -E "$sed_filter" \
                    | docker exec -i odoo_postgres psql -U "$owner" -d "$target_db" -q -v ON_ERROR_STOP=0 \
                        >/dev/null 2>"$err_log"
            else
                tar -xzOf "$archive" "$sql_entry" | sed -E "$sed_filter" \
                    | docker exec -i odoo_postgres psql -U "$owner" -d "$target_db" -q -v ON_ERROR_STOP=0 \
                        >/dev/null 2>"$err_log"
            fi
            ;;
        zip)
            if $sql_compressed; then
                unzip -p "$archive" "$sql_entry" | zcat | sed -E "$sed_filter" \
                    | docker exec -i odoo_postgres psql -U "$owner" -d "$target_db" -q -v ON_ERROR_STOP=0 \
                        >/dev/null 2>"$err_log"
            else
                unzip -p "$archive" "$sql_entry" | sed -E "$sed_filter" \
                    | docker exec -i odoo_postgres psql -U "$owner" -d "$target_db" -q -v ON_ERROR_STOP=0 \
                        >/dev/null 2>"$err_log"
            fi
            ;;
    esac
    set -e

    local err_count
    err_count=$(grep -c "^ERROR" "$err_log" 2>/dev/null || true)
    err_count=${err_count:-0}
    if [[ "$err_count" -gt 0 ]]; then
        warn "Se reportaron $err_count errores de PostgreSQL durante la carga."
        warn "Primeros 10:"
        grep "^ERROR" "$err_log" | head -10 | sed 's/^/    /'
        warn "Log completo: $err_log"
    else
        rm -f "$err_log"
    fi

    # Sanity check
    if ! docker exec odoo_postgres psql -U "$owner" -d "$target_db" -tAc \
            "SELECT to_regclass('res_users') IS NOT NULL" 2>/dev/null | grep -q '^t$'; then
        warn "La tabla res_users no existe en '$target_db' — la carga falló."
        warn "Considerá: docker exec odoo_postgres dropdb -U $owner --force $target_db   y reintentar."
        return 1
    fi
    info "SQL cargado en '$target_db'."

    # ── Stream filestore → docker exec tar dentro del contenedor ─────────────
    if [[ -n "$fs_entry" ]]; then
        step "Pase 2/2 — Restaurando filestore (streaming, sin extraer a disco host)..."

        # Preparar directorio destino dentro del contenedor.
        # Usamos /var/lib/odoo/_ext_restore_<ts>/ (misma partición que filestore)
        # para que el mv final sea atómico (rename, no copy).
        local stage_dir="/var/lib/odoo/_ext_restore_$(date +%s)"
        docker exec -u root "$container" sh -c "
            rm -rf /var/lib/odoo/filestore/$target_db
            mkdir -p $stage_dir
        "

        if [[ "$fs_type" == "tar" ]]; then
            # Filestore es un tar.gz anidado: stream outer → docker tar -xzf -
            case "$fmt" in
                tar)
                    tar -xzOf "$archive" "$fs_entry" \
                        | docker exec -i -u root "$container" tar -xzf - -C "$stage_dir"
                    ;;
                zip)
                    unzip -p "$archive" "$fs_entry" \
                        | docker exec -i -u root "$container" tar -xzf - -C "$stage_dir"
                    ;;
            esac
        elif [[ "$fs_type" == "dir" ]]; then
            # Filestore es un directorio dentro del archivo: extraer el subárbol al stage.
            # Para tar usamos --wildcards y -C; para zip usamos unzip al stage.
            local fs_prefix="${fs_entry%/}"
            case "$fmt" in
                tar)
                    docker exec -i -u root "$container" sh -c "mkdir -p $stage_dir && tar -xzf - -C $stage_dir --strip-components=0 '$fs_prefix'/* 2>/dev/null || tar -xzf - -C $stage_dir '$fs_prefix'" < "$archive"
                    ;;
                zip)
                    # No hay streaming práctico para zip multi-entrada → extraer al stage en el host
                    local tmpzip; tmpzip=$(mktemp -d)
                    unzip -q "$archive" "$fs_prefix/*" -d "$tmpzip"
                    docker cp "$tmpzip/$fs_prefix/." "$container:$stage_dir/"
                    rm -rf "$tmpzip"
                    ;;
            esac
        fi

        # Localizar el root real del filestore con un SCORING ROBUSTO.
        #
        # Idea: un dir "shape filestore" tiene ≥3 subdirectorios cuyo nombre es
        # hex de 2 caracteres (la convención de Odoo: filestore/<XX>/<sha1>).
        # Buscamos TODOS los candidatos hasta 5 niveles dentro del stage y nos
        # quedamos con el que tiene MÁS archivos dentro de sus hash-dirs.
        #
        # Esto resuelve el caso producción donde el tar incluye:
        #   STAGE/01/ STAGE/04/ ... ← hash-dirs huérfanos al top (pocos archivos)
        #   STAGE/<dbname>/01/  ... ← el filestore real (muchos archivos)
        # → el <dbname>/ gana por mayor file_count y se mueve correctamente.
        docker exec -u root "$container" sh -c '
            set -e
            STAGE="'"$stage_dir"'"
            TARGET="/var/lib/odoo/filestore/'"$target_db"'"

            # Generar tabla "file_count<TAB>dir" para cada candidato, ordenar
            # descendente por file_count y quedarnos con el ganador.
            best_line=$(
                find "$STAGE" -maxdepth 5 -type d 2>/dev/null | while IFS= read -r d; do
                    hex_count=$(ls -1 "$d" 2>/dev/null | grep -E "^[0-9a-f]{2}$" | wc -l)
                    [ "$hex_count" -lt 3 ] && continue
                    file_count=0
                    for h in "$d"/[0-9a-f][0-9a-f]; do
                        [ -d "$h" ] || continue
                        n=$(ls -1U "$h" 2>/dev/null | wc -l)
                        file_count=$((file_count + n))
                    done
                    printf "%d\t%s\n" "$file_count" "$d"
                done | sort -rn | head -1
            )

            fs_root=""
            fs_count=0
            if [ -n "$best_line" ]; then
                fs_count=$(echo "$best_line" | cut -f1)
                fs_root=$(echo "$best_line" | cut -f2-)
            fi

            # Fallback si NO encontramos ningún dir con ≥3 hash-dirs
            # (filestore vacío o muy pequeño): primer subdir del stage o stage mismo.
            if [ -z "$fs_root" ] || [ ! -d "$fs_root" ]; then
                echo "[!] No se detectó un dir con shape filestore (≥3 hash-dirs)." >&2
                echo "    Fallback: primer subdir del stage." >&2
                fs_root=$(find "$STAGE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
                [ -z "$fs_root" ] && fs_root="$STAGE"
            fi

            if [ -z "$fs_root" ] || [ ! -d "$fs_root" ]; then
                echo "[!] No se pudo localizar el root del filestore. Contenido del stage:" >&2
                find "$STAGE" -maxdepth 3 -type d >&2
                exit 1
            fi

            echo "[FS] Detectado: $fs_root ($fs_count archivos en hash-dirs)"

            mkdir -p "$(dirname "$TARGET")"
            rm -rf "$TARGET"
            mv "$fs_root" "$TARGET"
            chown -R odoo:odoo "$TARGET" 2>/dev/null || true
            rm -rf "$STAGE"
        '

        local fs_count
        fs_count=$(docker exec -u root "$container" sh -c "find /var/lib/odoo/filestore/$target_db -type f 2>/dev/null | wc -l" || echo "?")
        info "Filestore restaurado: /var/lib/odoo/filestore/$target_db ($fs_count archivos)"
    else
        warn "Sin filestore: los adjuntos NO estarán disponibles en Odoo."
    fi

    # ── Reiniciar contenedor ─────────────────────────────────────────────────
    info "Reiniciando $container para que detecte la nueva DB..."
    docker compose restart "$container"

    echo ""
    info "Restauración externa completada. DB: $target_db"
    echo ""
    warn "Recomendaciones post-restauración (DB venía de producción):"
    echo "    1. Neutralizar para apagar cron/mail/pagos:"
    echo "         ./scripts/ops.sh neutralize $container $target_db"
    echo "    2. Si el origen es una versión menor, ejecutar update:"
    echo "         ./scripts/ops.sh module $container $target_db base update"
    echo "    3. Revisar contraseñas administrativas y API keys de integraciones."
}

# =============================================================================
# neutralize — Neutralizar una DB restaurada de producción
# ./scripts/ops.sh neutralize <contenedor> <db>
#
# Aplica cambios para que una DB importada de producción no genere efectos
# en sistemas externos (correo, cron, pagos, webhooks, etc).
# =============================================================================
cmd_neutralize() {
    local container="${2:-}"
    local database="${3:-}"

    [[ -z "$container" ]] && error "Uso: ops.sh neutralize <contenedor> <db>"
    [[ -z "$database"  ]] && error "Falta: base de datos"

    title "Neutralizar DB de producción: $database"
    warn "Esto desactivará: cron jobs, mail servers, payment providers, webhooks."
    warn "Y reseteará: web.base.url, fetchmail_server activos."
    read -rp "¿Confirmar neutralización de '$database'? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { warn "Cancelado."; return; }

    local owner="${POSTGRES_USER:-odoo}"

    step "Desactivando ir.cron (acciones planificadas)..."
    docker exec odoo_postgres psql -U "$owner" -d "$database" -q -c \
        "UPDATE ir_cron SET active = false;" 2>/dev/null || warn "  tabla ir_cron no encontrada"

    step "Desactivando servidores de correo saliente (ir.mail_server)..."
    docker exec odoo_postgres psql -U "$owner" -d "$database" -q -c \
        "UPDATE ir_mail_server SET active = false;" 2>/dev/null || warn "  tabla ir_mail_server no encontrada"

    step "Desactivando servidores fetchmail (entrante)..."
    docker exec odoo_postgres psql -U "$owner" -d "$database" -q -c \
        "UPDATE fetchmail_server SET active = false;" 2>/dev/null || warn "  tabla fetchmail_server no encontrada (módulo no instalado)"

    step "Desactivando proveedores de pago (payment.provider)..."
    docker exec odoo_postgres psql -U "$owner" -d "$database" -q -c \
        "UPDATE payment_provider SET state='disabled';" 2>/dev/null || \
    docker exec odoo_postgres psql -U "$owner" -d "$database" -q -c \
        "UPDATE payment_acquirer SET state='disabled';" 2>/dev/null || warn "  payment.provider/acquirer no encontrado"

    step "Limpiando web.base.url para que Odoo la regenere..."
    docker exec odoo_postgres psql -U "$owner" -d "$database" -q -c \
        "DELETE FROM ir_config_parameter WHERE key IN ('web.base.url','web.base.url.freeze');" 2>/dev/null || true

    step "Reiniciando $container..."
    docker compose restart "$container" >/dev/null 2>&1

    info "DB '$database' neutralizada."
    echo ""
    echo "  Verificá manualmente:"
    echo "    - Cuentas bancarias / API keys integraciones"
    echo "    - Usuarios con permisos elevados"
    echo "    - Cualquier integración (Stripe, MercadoLibre, etc.)"
}

# =============================================================================
# db-query — Ejecutar una query SQL en una DB de proyecto
# ./scripts/ops.sh db-query <contenedor> <db> "<sql>"
# =============================================================================
cmd_db_query() {
    local _container="${2:-}"  # no usamos el contenedor directamente, siempre va a postgres
    local database="${3:-}"
    local query="${4:-}"

    [[ -z "$database" ]] && error "Uso: ops.sh db-query <contenedor> <db> \"<sql>\""
    [[ -z "$query"    ]] && error "Falta: query SQL"

    docker exec odoo_postgres psql \
        -U "${POSTGRES_USER:-odoo}" \
        -d "$database" \
        -c "$query"
}

# =============================================================================
# update-image — Actualizar imagen Docker de un servicio
# ./scripts/ops.sh update-image <servicio>
# =============================================================================
cmd_update_image() {
    local service="${2:-}"
    if [[ -n "$service" ]]; then
        title "Actualizando imagen: $service"
        docker compose pull "$service"
        docker compose up -d "$service"
    else
        title "Actualizando todas las imágenes"
        docker compose pull
        docker compose up -d --remove-orphans
    fi
    step "Limpiando imágenes obsoletas..."
    docker image prune -f
    info "Actualización completada."
}

# =============================================================================
# nginx-reload — Recargar config de nginx (refresca DNS de upstreams)
#
# Útil cuando se recrea un container Odoo: el nuevo container tiene IP nueva
# pero nginx mantiene la vieja cacheada → 502 Bad Gateway. Reload re-resuelve.
# =============================================================================
cmd_nginx_reload() {
    title "Recargando nginx"
    if ! docker compose ps --format '{{.Name}}' 2>/dev/null | grep -q '^odoo_nginx$'; then
        error "nginx no está corriendo. Levantalo con: docker compose up -d nginx"
    fi

    if docker compose exec -T nginx nginx -t 2>&1 | grep -q "successful"; then
        docker compose exec -T nginx nginx -s reload
        info "Nginx recargado. Upstreams re-resueltos."
    else
        error "Config de nginx tiene errores. Ejecutá: docker compose exec nginx nginx -t"
    fi
}

# =============================================================================
# ssl-renew — Renovar certificados SSL
# =============================================================================
cmd_ssl_renew() {
    title "Renovación SSL"
    docker compose run --rm certbot renew --webroot -w /var/www/certbot
    docker compose exec nginx nginx -s reload
    info "Certificados renovados y Nginx recargado."
}

# =============================================================================
# help — Mostrar ayuda
# =============================================================================
cmd_help() {
    echo ""
    echo -e "${BOLD}EXTENDRIX — ops.sh | Gestión de entorno Odoo 14${NC}"
    echo ""
    echo -e "${CYAN}Comandos disponibles:${NC}"
    echo ""
    printf "  ${GREEN}%-40s${NC} %s\n" "start" "Inicia todos los servicios en orden correcto"
    printf "  ${GREEN}%-40s${NC} %s\n" "stop" "Detiene todos los servicios (conserva datos)"
    printf "  ${GREEN}%-40s${NC} %s\n" "restart [contenedor]" "Reinicia uno o todos los servicios"
    printf "  ${GREEN}%-40s${NC} %s\n" "logs <contenedor> [N] [--raw]" "Ver logs (filtra ruido cross-DB; --raw para sin filtro)"
    printf "  ${GREEN}%-40s${NC} %s\n" "health" "Estado de todos los contenedores"
    echo ""
    printf "  ${CYAN}%-40s${NC} %s\n" "module <ctr> <db> <mod> <acción>" "Instalar/actualizar módulo Odoo"
    printf "  ${CYAN}%-40s${NC} %s\n" "" "  Acciones: install | update | uninstall"
    echo ""
    printf "  ${YELLOW}%-40s${NC} %s\n" "backup <proyecto> <ctr> <db>" "Backup DB + filestore en ./backups/<proyecto>/"
    printf "  ${YELLOW}%-40s${NC} %s\n" "backup-all" "Backup de todas las DBs (staging) al volumen central"
    printf "  ${YELLOW}%-40s${NC} %s\n" "list-backups [<proyecto>]" "Listar backups del volumen central"
    printf "  ${YELLOW}%-40s${NC} %s\n" "restore <ctr> <db_dest> <db.gz> [fs.tgz]" "Restaurar DB + filestore del volumen central"
    printf "  ${YELLOW}%-40s${NC} %s\n" "restore-external <ctr> <db_dest> <archivo>" "Restaurar backup externo (.tar.gz/.zip/.sql.gz/.sql)"
    printf "  ${YELLOW}%-40s${NC} %s\n" "neutralize <ctr> <db>" "Desactivar cron/mail/pago tras importar de producción"
    echo ""
    printf "  ${BLUE}%-40s${NC} %s\n" "db-query <ctr> <db> \"<sql>\"" "Ejecutar query SQL"
    printf "  ${BLUE}%-40s${NC} %s\n" "update-image [servicio]" "Actualizar imagen Docker"
    printf "  ${BLUE}%-40s${NC} %s\n" "nginx-reload" "Recargar nginx (fix 502 tras recreate de container)"
    printf "  ${BLUE}%-40s${NC} %s\n" "ssl-renew" "Renovar certificados SSL"
    echo ""
    echo -e "${CYAN}Ejemplos:${NC}"
    echo "  ./scripts/ops.sh start"
    echo "  ./scripts/ops.sh logs odoo14_merida_prod 500"
    echo "  ./scripts/ops.sh module odoo14_merida_prod merida_prod_principal mi_modulo update"
    echo "  ./scripts/ops.sh backup merida odoo14_merida_prod merida_prod_principal"
    echo "  ./scripts/ops.sh list-backups merida"
    echo "  ./scripts/ops.sh restore odoo14_merida_prod merida_prod_copia \\"
    echo "      merida/db/20260511_020000_merida_prod_principal.sql.gz"
    echo "  ./scripts/ops.sh restore-external odoo14_merida_prod merida_prod_principal \\"
    echo "      /opt/backups_odoo/conexion_prod_FULL_2026-05-12.tar.gz"
    echo "  ./scripts/ops.sh neutralize odoo14_merida_prod merida_prod_principal"
    echo "  ./scripts/ops.sh db-query odoo14_merida_prod merida_prod_principal \"SELECT count(*) FROM res_users;\""
    echo ""
}

# =============================================================================
# DISPATCH
# =============================================================================
case "$CMD" in
    start)        cmd_start "$@" ;;
    stop)         cmd_stop "$@" ;;
    restart)      cmd_restart "$@" ;;
    logs)         cmd_logs "$@" ;;
    health)       cmd_health ;;
    module)       cmd_module "$@" ;;
    backup)       cmd_backup "$@" ;;
    backup-all)   cmd_backup_all ;;
    list-backups) cmd_list_backups "$@" ;;
    restore)      cmd_restore "$@" ;;
    restore-external) cmd_restore_external "$@" ;;
    neutralize)   cmd_neutralize "$@" ;;
    db-query)     cmd_db_query "$@" ;;
    update-image) cmd_update_image "$@" ;;
    nginx-reload) cmd_nginx_reload ;;
    ssl-renew)    cmd_ssl_renew ;;
    help|*)       cmd_help ;;
esac
