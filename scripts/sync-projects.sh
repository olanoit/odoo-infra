#!/usr/bin/env bash
# =============================================================================
# EXTENDRIX — sync-projects.sh
#
# Lee projects-registry.conf y aplica automáticamente los proyectos nuevos.
# Los proyectos ya desplegados son detectados y omitidos automáticamente.
#
# USO:
#   ./scripts/sync-projects.sh                        # Dry-run
#   ./scripts/sync-projects.sh --apply                # Aplica cambios pendientes
#   ./scripts/sync-projects.sh --apply --ssl          # Aplica + emite SSL
#   ./scripts/sync-projects.sh --apply --ssl --start  # Aplica + SSL + levanta
#   ./scripts/sync-projects.sh --validate             # Valida estado actual
#   ./scripts/sync-projects.sh --apply --start --validate  # Todo + validación
# =============================================================================

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()  { echo -e "${CYAN}  →${NC} $*"; }
dryrun(){ echo -e "${YELLOW}[dry-run]${NC} $*"; }

APPLY=false
WITH_SSL=false
WITH_START=false
WITH_VALIDATE=false
WITH_STAGING=false
WILDCARD_REUSE=true
REGISTRY="projects-registry.conf"

for arg in "$@"; do
    case "$arg" in
        --apply)        APPLY=true ;;
        --ssl)          WITH_SSL=true ;;
        --start)        WITH_START=true ;;
        --validate)     WITH_VALIDATE=true ;;
        --staging)      WITH_STAGING=true ;;
        --no-wildcard)  WILDCARD_REUSE=false ;;
        --help|-h)
            echo "Uso: $0 [--apply] [--ssl] [--start] [--validate] [--staging] [--no-wildcard]"
            echo "  --apply        Aplica los cambios (sin este flag: dry-run)"
            echo "  --ssl          Emite certificados SSL para los proyectos nuevos"
            echo "  --start        Levanta los contenedores nuevos tras aplicar"
            echo "  --validate     Verifica el estado de todos los proyectos registrados"
            echo "  --staging      Usa el servidor de pruebas de Let's Encrypt (sin rate limits)"
            echo "  --no-wildcard  No reutilizar certs wildcard; emitir siempre cert individual"
            exit 0
            ;;
        *) warn "Argumento desconocido: $arg" ;;
    esac
done

[[ -f "$REGISTRY" ]] || error "No se encontró $REGISTRY en $PROJECT_DIR"
command -v python3 >/dev/null 2>&1 || error "python3 no está disponible"

# Leer email de certbot desde .env o .env.example
CERTBOT_EMAIL=$(
    { grep -m1 '^CERTBOT_EMAIL=' .env 2>/dev/null || grep -m1 '^CERTBOT_EMAIL=' .env.example; } \
    | cut -d= -f2 || true
)
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
[[ -z "$CERTBOT_EMAIL" ]] && error "CERTBOT_EMAIL no configurado. Agrégalo en .env: CERTBOT_EMAIL=support@extendrix.com"

# ─── Helper: insertar bloque antes de un marcador en un archivo ──────────────
insert_before_marker() {
    local target_file="$1"
    local marker="$2"
    local block_file="$3"

    grep -qF "$marker" "$target_file" || error "Marcador '$marker' no encontrado en $target_file"

    python3 - "$target_file" "$block_file" "$marker" << 'PYEOF'
import sys
target, block_file, marker = sys.argv[1], sys.argv[2], sys.argv[3]
with open(target) as f: content = f.read()
with open(block_file) as f: block = f.read()
if marker not in content:
    sys.exit(f"ERROR: marker not found: {marker}")
result = content.replace(marker, block + '\n' + marker, 1)
with open(target, 'w') as f: f.write(result)
PYEOF
}

# ─── Validación del estado de todos los proyectos ────────────────────────────
validate_all_projects() {
    echo ""
    echo -e "${BOLD}══ Validación del despliegue ══${NC}"
    echo ""

    local PASS=0 FAIL=0 WARN_COUNT=0

    while IFS=: read -r PROYECTO VERSION ENTORNO DOMINIO PUERTO_HTTP; do
        [[ "$PROYECTO" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${PROYECTO// /}" ]] && continue

        PROYECTO="${PROYECTO// /}"; VERSION="${VERSION// /}"; ENTORNO="${ENTORNO// /}"
        DOMINIO="${DOMINIO// /}"; PUERTO_HTTP="${PUERTO_HTTP// /}"
        local NAME="odoo${VERSION}_${PROYECTO}_${ENTORNO}"

        printf "  %-45s" "${NAME}"

        if ! grep -qF "container_name: ${NAME}" docker-compose.yml 2>/dev/null; then
            echo -e "${RED}[✗] No definido en docker-compose.yml${NC}"
            FAIL=$((FAIL + 1)); continue
        fi

        local STATUS HEALTH
        STATUS=$(docker compose ps --format '{{.Status}}' "${NAME}" 2>/dev/null || echo "")
        HEALTH=$(docker compose ps --format '{{.Health}}' "${NAME}" 2>/dev/null || echo "")

        if [[ -z "$STATUS" || "$STATUS" == *"Exit"* || "$STATUS" == *"Exited"* ]]; then
            echo -e "${RED}[✗] Detenido — ejecuta: docker compose up -d ${NAME}${NC}"
            FAIL=$((FAIL + 1))
        elif echo "$STATUS" | grep -qi "restarting"; then
            echo -e "${RED}[✗] Restarting (crash loop) — revisa: docker compose logs ${NAME}${NC}"
            FAIL=$((FAIL + 1))
        elif [[ "$HEALTH" == "healthy" ]]; then
            echo -e "${GREEN}[✓] Running · healthy${NC}"
            PASS=$((PASS + 1))
        elif [[ "$HEALTH" == "starting" ]]; then
            echo -e "${YELLOW}[~] Running · healthcheck iniciando${NC}"
            WARN_COUNT=$((WARN_COUNT + 1))
        elif [[ "$HEALTH" == "unhealthy" ]]; then
            echo -e "${RED}[✗] Running · unhealthy — revisa: docker compose logs ${NAME}${NC}"
            FAIL=$((FAIL + 1))
        else
            echo -e "${GREEN}[✓] Running${NC}"
            PASS=$((PASS + 1))
        fi

    done < <(grep -v '^[[:space:]]*#' "$REGISTRY" | grep -v '^[[:space:]]*$')

    # ── Nginx ──────────────────────────────────────────────────────────────────
    printf "  %-45s" "nginx"
    # docker compose ps --format '{{.Status}}' devuelve "Up X minutes" (sin healthcheck)
    # o "Up X (healthy/unhealthy)" (con healthcheck). Nginx no tiene healthcheck,
    # así que grep "running" fallaba siempre.
    local NGINX_STATUS
    NGINX_STATUS=$(docker compose ps --format '{{.Status}}' nginx 2>/dev/null || echo "")
    if echo "$NGINX_STATUS" | grep -qi "restarting"; then
        echo -e "${RED}[✗] Restarting (crash loop) — revisa: docker compose logs nginx${NC}"
        FAIL=$((FAIL + 1))
    elif echo "$NGINX_STATUS" | grep -qE "^Up|running"; then
        local NGINX_TEST
        NGINX_TEST=$(docker compose exec nginx nginx -t 2>&1 || true)
        if echo "$NGINX_TEST" | grep -qi "successful"; then
            echo -e "${GREEN}[✓] Running · config OK${NC}"
            PASS=$((PASS + 1))
        else
            echo -e "${YELLOW}[!] Running · errores en config — revisa nginx -t${NC}"
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    else
        echo -e "${RED}[✗] No está corriendo${NC}"
        FAIL=$((FAIL + 1))
    fi

    # ── Resumen ────────────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${GREEN}✓ OK: ${PASS}${NC}   ${YELLOW}~ Iniciando: ${WARN_COUNT}${NC}   ${RED}✗ Errores: ${FAIL}${NC}"
    echo ""

    if [[ $FAIL -gt 0 ]]; then
        warn "Hay contenedores con problemas. Revisa los logs:"
        echo "    ./scripts/ops.sh logs <contenedor> 50"
    fi
    if [[ $WARN_COUNT -gt 0 ]]; then
        warn "Contenedores aún iniciando. Vuelve a validar en ~60s:"
        echo "    ./scripts/sync-projects.sh --validate"
    fi
    if [[ $FAIL -eq 0 && $WARN_COUNT -eq 0 ]]; then
        info "Todos los proyectos están operativos."
    fi
}

# ─── Contador de proyectos nuevos ─────────────────────────────────────────────
NEW_PROJECTS=0
APPLIED_NAMES=()

echo ""
echo -e "${BOLD}══ EXTENDRIX — Sync Projects ══${NC}"
$APPLY && echo -e "  Modo: ${GREEN}APLICAR${NC}" || echo -e "  Modo: ${YELLOW}DRY-RUN${NC} (usa --apply para aplicar cambios)"
echo ""

# ─── Leer registry ────────────────────────────────────────────────────────────
while IFS=: read -r PROYECTO VERSION ENTORNO DOMINIO PUERTO_HTTP; do
    # Ignorar comentarios y líneas vacías
    [[ "$PROYECTO" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${PROYECTO// /}" ]] && continue

    # Limpiar espacios
    PROYECTO="${PROYECTO// /}"; VERSION="${VERSION// /}"; ENTORNO="${ENTORNO// /}"
    DOMINIO="${DOMINIO// /}"; PUERTO_HTTP="${PUERTO_HTTP// /}"

    CONTAINER_NAME="odoo${VERSION}_${PROYECTO}_${ENTORNO}"
    PUERTO_LP=$((PUERTO_HTTP + 1))
    VOLUME_NAME="odoo${VERSION}_${PROYECTO}_${ENTORNO}_data"
    DB_PREFIX="${PROYECTO}_${ENTORNO}"

    # ¿Ya existe este contenedor?
    if grep -qF "container_name: ${CONTAINER_NAME}" docker-compose.yml 2>/dev/null; then
        continue
    fi

    NEW_PROJECTS=$((NEW_PROJECTS + 1))
    echo -e "${CYAN}Nuevo proyecto detectado:${NC} ${CONTAINER_NAME}"
    echo -e "  Dominio    : ${DOMINIO}"
    echo -e "  Puerto HTTP: 127.0.0.1:${PUERTO_HTTP}:8069"
    echo -e "  Puerto LP  : 127.0.0.1:${PUERTO_LP}:8072"
    echo ""

    if ! $APPLY; then
        dryrun "Crearía: projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/"
        dryrun "Generaría: odoo.conf para ${CONTAINER_NAME}"
        dryrun "Insertaría servicio en docker-compose.yml"
        dryrun "Insertaría volumen en docker-compose.yml"
        dryrun "Insertaría upstream en nginx/conf.d/00-upstreams.conf"
        dryrun "Insertaría vhost en nginx/conf.d/vhosts-projects.conf"
        $WITH_SSL  && dryrun "SSL para ${DOMINIO}: reutilizaría wildcard si lo cubre, si no emitiría cert individual"
        $WITH_START && dryrun "Levantaría contenedor ${CONTAINER_NAME}"
        echo ""
        continue
    fi

    # ── Parámetros según entorno ─────────────────────────────────────────────
    if [[ "$ENTORNO" == "prod" || "$ENTORNO" == "sta" ]]; then
        WORKERS=4; LOG_LEVEL="warn"
        MEM_SOFT=2147483648; MEM_HARD=2684354560
        LIMIT_CPU=60;  LIMIT_REAL=120; DB_MAXCONN=24
        CRON_THREADS=2; WS_BURST=10;  WS_DELAY=0.2
        CACHE_CTRL="public, immutable"; EXPIRES="30d"; LOGIN_BURST=3
        SSL_CACHE_SIZE="10m"; MEM_LIMIT="3g"; CPUS="2.0"
    else
        WORKERS=2; LOG_LEVEL="info"
        MEM_SOFT=1073741824; MEM_HARD=1610612736
        LIMIT_CPU=120; LIMIT_REAL=240; DB_MAXCONN=16
        CRON_THREADS=1; WS_BURST=20;  WS_DELAY=0.1
        CACHE_CTRL="public"; EXPIRES="7d"; LOGIN_BURST=5
        SSL_CACHE_SIZE="5m"; MEM_LIMIT="2g"; CPUS="1.0"
    fi

    # ── Opciones dependientes de la versión de Odoo ──────────────────────────
    # Odoo 16+ usa gevent_port y opciones websocket_*; Odoo ≤15 usa
    # longpolling_port y no tiene websockets.
    if (( VERSION >= 16 )); then
        LP_PORT_LINE="gevent_port    = 8072"
        WS_BLOCK=$'\nwebsocket_keep_alive_timeout = 3600\nwebsocket_rate_limit_burst   = '"${WS_BURST}"$'\nwebsocket_rate_limit_delay   = '"${WS_DELAY}"
    else
        LP_PORT_LINE="longpolling_port = 8072"
        WS_BLOCK=""
    fi

    TMP=$(mktemp -d)

    # ── 1. Directorios ────────────────────────────────────────────────────────
    step "Creando directorios..."
    mkdir -p "projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/config"
    mkdir -p "projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/addons"
    # Volumen central de backups: ./backups/<proyecto>/{db,filestore}
    mkdir -p "backups/${PROYECTO}/db"
    mkdir -p "backups/${PROYECTO}/filestore"

    # ── 2. odoo.conf ─────────────────────────────────────────────────────────
    step "Generando odoo.conf..."
    CONF_FILE="projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/config/odoo.conf"
    cat > "$CONF_FILE" << ODOOCONF
# =============================================================================
# EXTENDRIX — Odoo ${VERSION} | Proyecto: ${PROYECTO} | Entorno: ${ENTORNO^^}
# Contenedor: ${CONTAINER_NAME}
# Generado por: sync-projects.sh
# =============================================================================

[options]

# db_host/port/user/password provistos por variables de entorno del contenedor
dbfilter = ^${DB_PREFIX}_.*\$

data_dir    = /var/lib/odoo
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons,/mnt/extra-addons

http_port      = 8069
${LP_PORT_LINE}
http_interface =
proxy_mode     = True

workers            = ${WORKERS}
limit_memory_soft  = ${MEM_SOFT}
limit_memory_hard  = ${MEM_HARD}
limit_request      = 2048
limit_time_cpu     = ${LIMIT_CPU}
limit_time_real    = ${LIMIT_REAL}
db_maxconn         = ${DB_MAXCONN}

log_level   = ${LOG_LEVEL}
log_handler = :WARNING,werkzeug:CRITICAL

# list_db=False: oculta el listado de bases de datos en el gestor web.
# admin_passwd NO se escribe acá (sería un secreto versionado); lo inyecta el
# wrapper odoo-entrypoint.sh en un config de runtime desde \${ODOO_MASTER_PASSWD}.
list_db      = False

max_cron_threads = ${CRON_THREADS}
unaccent         = True
${WS_BLOCK}
ODOOCONF
    info "odoo.conf generado: $CONF_FILE"

    # ── 3. Servicio en docker-compose.yml ─────────────────────────────────────
    step "Insertando servicio en docker-compose.yml..."
    cat > "${TMP}/service.yml" << SVCBLOCK
  # ---------------------------------------------------------------------------
  # ODOO ${VERSION} | ${PROYECTO^^} | ${ENTORNO^^}
  # Contenedor : ${CONTAINER_NAME}
  # Subdominio : ${DOMINIO}
  # DB prefix  : ${DB_PREFIX}_
  # ---------------------------------------------------------------------------
  ${CONTAINER_NAME}:
    image: odoo:${VERSION}.0
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      HOST: db
      PORT: 5432
      USER: \${POSTGRES_USER:-odoo}
      PASSWORD: \${POSTGRES_PASSWORD}
      ODOO_MASTER_PASSWD: \${ODOO_MASTER_PASSWD:?falta_ODOO_MASTER_PASSWD_en_.env}
    # El wrapper inyecta admin_passwd (Odoo 14 no soporta --admin-passwd por CLI)
    # e instala los requirements.txt de los módulos (shared/extra/enterprise) al arrancar.
    entrypoint: ["/bin/sh", "/odoo-entrypoint.sh"]
    volumes:
      - ${VOLUME_NAME}:/var/lib/odoo
      - ./scripts/odoo-entrypoint.sh:/odoo-entrypoint.sh:ro
      - ./projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/config/odoo.conf:/etc/odoo/odoo.conf:ro
      - ./projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/addons:/mnt/extra-addons
      - ./shared-addons/${VERSION}:/mnt/shared-addons:ro
      - ./enterprise/odoo${VERSION}:/mnt/enterprise:ro
      - ./backups:/backups
    ports:
      - "127.0.0.1:${PUERTO_HTTP}:8069"
      - "127.0.0.1:${PUERTO_LP}:8072"
    networks:
      - odoo_net
    command: ["odoo", "--config=/etc/odoo/odoo.conf"]
    # Límites de recursos: evitan que una instancia agote la RAM/CPU del host
    # y afecte al resto de proyectos del servidor compartido.
    mem_limit: ${MEM_LIMIT}
    cpus: ${CPUS}
    healthcheck:
      test: ["CMD-SHELL", "curl -s -o /dev/null -w '%{http_code}' http://localhost:8069/ | grep -qE '^[23]'"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    logging:
      driver: "json-file"
      options: { max-size: "100m", max-file: "5" }

SVCBLOCK
    insert_before_marker "docker-compose.yml" "  # __SYNC_SERVICES_INSERT__" "${TMP}/service.yml"
    info "Servicio insertado en docker-compose.yml"

    # ── 4. Volumen en docker-compose.yml ──────────────────────────────────────
    step "Insertando volumen en docker-compose.yml..."
    cat > "${TMP}/volume.yml" << VOLBLOCK
  ${VOLUME_NAME}:
    name: ${VOLUME_NAME}

VOLBLOCK
    insert_before_marker "docker-compose.yml" "  # __SYNC_VOLUMES_INSERT__" "${TMP}/volume.yml"
    info "Volumen insertado en docker-compose.yml"

    # ── 5. Upstream en nginx ──────────────────────────────────────────────────
    step "Insertando upstream en nginx/conf.d/00-upstreams.conf..."
    cat > "${TMP}/upstream.conf" << UPBLOCK
# --- ODOO ${VERSION} | ${PROYECTO^^} | ${ENTORNO^^} ---
upstream up_${PROYECTO}_${ENTORNO}_http {
    server ${CONTAINER_NAME}:8069 weight=1 max_fails=3 fail_timeout=30s;
    keepalive 16;
}
upstream up_${PROYECTO}_${ENTORNO}_lp {
    server ${CONTAINER_NAME}:8072 weight=1 max_fails=3 fail_timeout=30s;
    keepalive 8;
}

UPBLOCK
    insert_before_marker "nginx/conf.d/00-upstreams.conf" "# __SYNC_UPSTREAMS_INSERT__" "${TMP}/upstream.conf"
    info "Upstream insertado en 00-upstreams.conf"

    # ── 5.5. Certificado auto-firmado temporal ────────────────────────────────
    # Permite que nginx arranque con el bloque HTTPS antes de emitir el cert real.
    # Certbot lo reemplaza automáticamente cuando se ejecuta con --ssl.
    # Cert auto-firmado temporal: se crea dentro del container certbot para evitar
    # problemas de permisos (el volumen /etc/letsencrypt es propiedad de root/Docker).
    if ! docker compose run --rm --entrypoint sh certbot -c \
        "[ -f /etc/letsencrypt/live/${DOMINIO}/fullchain.pem ]" 2>/dev/null; then
        step "Creando certificado provisional para ${DOMINIO}..."
        docker compose run --rm --entrypoint sh certbot -c \
            "mkdir -p /etc/letsencrypt/live/${DOMINIO} && \
             openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
                 -keyout /etc/letsencrypt/live/${DOMINIO}/privkey.pem \
                 -out    /etc/letsencrypt/live/${DOMINIO}/fullchain.pem \
                 -subj '/CN=${DOMINIO}' 2>/dev/null && \
             cp /etc/letsencrypt/live/${DOMINIO}/fullchain.pem \
                /etc/letsencrypt/live/${DOMINIO}/chain.pem"
        info "Certificado auto-firmado temporal creado. Usa --ssl para el real."
    fi

    # ── 6. Vhost en nginx ─────────────────────────────────────────────────────
    step "Insertando vhost en nginx/conf.d/vhosts-projects.conf..."
    cat > "${TMP}/vhost.conf" << VHOSTBLOCK

# =============================================================================
# ODOO ${VERSION} | ${PROYECTO^^} | ${ENTORNO^^}
# Subdominio: ${DOMINIO}
# =============================================================================
server {
    listen 80;
    server_name ${DOMINIO};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl; http2 on;
    server_name ${DOMINIO};

    ssl_certificate     /etc/letsencrypt/live/${DOMINIO}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMINIO}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${DOMINIO}/chain.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL_${PROYECTO}_${ENTORNO}:${SSL_CACHE_SIZE};
    ssl_session_timeout 1d; ssl_session_tickets off;
    add_header Strict-Transport-Security "max-age=63072000" always;
    # ssl_stapling deshabilitado: Let's Encrypt ya no embebe OCSP responder URL.
    resolver 8.8.8.8 valid=300s; resolver_timeout 5s;
    client_max_body_size 200m;

    location ~* /web/login {
        limit_req zone=odoo_login burst=${LOGIN_BURST} nodelay;
        proxy_pass http://up_${PROYECTO}_${ENTORNO}_http;
        include /etc/nginx/conf.d/odoo-proxy-params.conf;
    }
    location /websocket {
        proxy_pass http://up_${PROYECTO}_${ENTORNO}_lp;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 28800s; proxy_send_timeout 28800s;
    }
    location /longpolling {
        proxy_pass http://up_${PROYECTO}_${ENTORNO}_lp;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Connection        "";
        proxy_redirect off;
        proxy_next_upstream off;
        proxy_read_timeout 28800s;
        proxy_send_timeout 28800s;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)\$ {
        proxy_pass http://up_${PROYECTO}_${ENTORNO}_http;
        include /etc/nginx/conf.d/odoo-proxy-params.conf;
        expires ${EXPIRES}; add_header Cache-Control "${CACHE_CTRL}"; access_log off;
    }
    # Gestor de bases de datos deshabilitado de cara a internet.
    # Redundante con list_db=False, pero bloquea también crear/borrar/restaurar
    # vía web. Para operar el manager, hazlo desde la red interna o con un túnel.
    location /web/database {
        return 404;
    }
    location / {
        proxy_pass http://up_${PROYECTO}_${ENTORNO}_http;
        include /etc/nginx/conf.d/odoo-proxy-params.conf;
    }
}

VHOSTBLOCK
    insert_before_marker "nginx/conf.d/vhosts-projects.conf" "# __SYNC_VHOSTS_INSERT__" "${TMP}/vhost.conf"
    info "Vhost ${DOMINIO} insertado en vhosts-projects.conf"

    rm -rf "$TMP"
    APPLIED_NAMES+=("$CONTAINER_NAME")

    # ── 7. Agregar bloque por defecto a docker-compose.override.yml ───────────
    # entrypoint + addons-path con shared-addons/EXTENDRIX_extra_addons/tools.
    # Idempotente: si ya existe, se omite. Editá manualmente el override después
    # para agregar mercadolibre, account u otros shared-addons.
    if [[ -x ./scripts/sync-overrides.sh ]]; then
        step "Agregando bloque al docker-compose.override.yml..."
        ./scripts/sync-overrides.sh --apply "$PROYECTO" "$ENTORNO" 2>&1 \
            | grep -E "\[✓\]|\[!\]|agregado|ya tiene|FALTA" | sed 's/^/    /' || true
    fi

    # ── 8. Levantar contenedor (opcional) ─────────────────────────────────────
    if $WITH_START; then
        step "Levantando contenedor ${CONTAINER_NAME}..."
        docker compose up -d "${CONTAINER_NAME}"
        info "Contenedor ${CONTAINER_NAME} levantado."

        # Recargar nginx: refresca DNS del nuevo container (Docker asigna IPs
        # dinámicas) y activa el nuevo upstream + vhost que insertamos antes.
        # Sin este reload: el dominio devuelve 502 porque nginx tiene cacheada
        # una resolución vieja o no conoce el nuevo upstream.
        if docker compose ps --format '{{.Name}}' 2>/dev/null | grep -q '^odoo_nginx$'; then
            step "Recargando nginx para activar el nuevo proyecto..."
            docker compose exec -T nginx nginx -s reload 2>/dev/null && \
                info "Nginx recargado." || \
                warn "No se pudo recargar nginx (¿está corriendo?). Hacelo manual: ./scripts/ops.sh nginx-reload"
        fi
    fi

    info "Proyecto '${CONTAINER_NAME}' aplicado. Para SSL: ./scripts/sync-projects.sh --ssl"
    echo ""

done < <(grep -v '^[[:space:]]*#' "$REGISTRY" | grep -v '^[[:space:]]*$')

# ─── SSL independiente — se ejecuta siempre que se pase --ssl ─────────────────
if $WITH_SSL; then
    echo ""
    echo -e "${BOLD}══ SSL — Emisión de certificados ══${NC}"
    echo ""

    CERTBOT_EXTRA_FLAGS=""
    if $WITH_STAGING; then
        CERTBOT_EXTRA_FLAGS="--staging"
        warn "Modo STAGING activo — Let's Encrypt emitirá certs de prueba (no válidos para producción)."
        warn "Usar staging para probar sin consumir intentos reales. Luego: --ssl sin --staging."
        echo ""
    fi

    # Nginx resuelve los hostnames de los upstreams al arrancar via DNS interno de Docker.
    # Si los contenedores Odoo no existen, Docker DNS falla y nginx crashea.
    # Solución: levantar todos los servicios primero (docker compose respeta depends_on).
    step "Arrancando todos los servicios (nginx necesita resolver los upstreams de Odoo)..."
    docker compose up -d
    local_wait=0
    while true; do
        NGINX_STATUS=$(docker compose ps --format '{{.Status}}' nginx 2>/dev/null || echo "")
        if echo "$NGINX_STATUS" | grep -qi "^up"; then
            break
        elif echo "$NGINX_STATUS" | grep -qi "restarting"; then
            error "Nginx está en crash loop. Revisa: docker compose logs nginx"
        fi
        sleep 2; local_wait=$((local_wait + 2))
        [[ $local_wait -ge 60 ]] && error "Nginx no arrancó en 60s. Revisa: docker compose logs nginx"
    done
    sleep 2
    info "Nginx activo."

    # ── Preparar entorno para Certbot ────────────────────────────────────────
    # El contenedor de renovación (odoo_certbot) puede tener tomado el lock
    # global /etc/letsencrypt/.certbot.lock. Si está vivo cuando lanzamos
    # `docker compose run certbot certonly`, el nuevo proceso se cuelga
    # indefinidamente esperando el lock.
    step "Pausando contenedor de renovación y limpiando locks de certbot..."
    docker compose stop certbot >/dev/null 2>&1 || true
    docker ps -a --filter "name=certbot-run" -q 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1 || true
    rm -f ./nginx/certbot/conf/.certbot.lock 2>/dev/null || true
    # Garantizar que al salir (incluso por error o Ctrl+C) levantamos el certbot
    # de renovación de vuelta.
    trap 'docker compose up -d certbot >/dev/null 2>&1 || true' EXIT
    info "Lock liberado."
    echo ""

    local_issued=0; local_skipped=0; local_failed=0

    while IFS=: read -r P_SSL V_SSL E_SSL D_SSL PH_SSL; do
        [[ "$P_SSL" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${P_SSL// /}" ]] && continue
        D_SSL="${D_SSL// /}"

        # Ya enlazado a un wildcard (live/<dominio> es symlink) → nada que hacer.
        if [[ -L "./nginx/certbot/conf/live/${D_SSL}" ]]; then
            info "${D_SSL}: ya usa un cert wildcard (symlink) — omitido."
            local_skipped=$((local_skipped + 1))
            continue
        fi

        # Cert real = certbot gestiona el archive dir (distinto del auto-firmado en live/)
        if [[ -d "./nginx/certbot/conf/archive/${D_SSL}" ]]; then
            info "${D_SSL}: certificado Let's Encrypt activo — omitido."
            local_skipped=$((local_skipped + 1))
            continue
        fi

        # Reutilización de wildcard: si existe un cert *.<parent> en el volumen
        # que cubre este subdominio, lo enlazamos en vez de emitir cert individual
        # (ahorra rate-limits y la validación ACME http-01). --auto sale con 3 si
        # no hay wildcard que cubra, y entonces seguimos con la emisión normal.
        if $WILDCARD_REUSE; then
            WC_RC=0
            ./scripts/wildcard-ssl.sh "${D_SSL}" --link --no-reload --auto --quiet || WC_RC=$?
            if [[ $WC_RC -eq 0 ]]; then
                info "${D_SSL}: reutilizado cert wildcard (sin emitir cert individual)."
                local_issued=$((local_issued + 1)); continue
            elif [[ $WC_RC -ne 3 ]]; then
                warn "${D_SSL}: fallo al reutilizar wildcard (código ${WC_RC}); intento emisión individual."
            fi
        fi

        step "Verificando DNS para ${D_SSL}..."
        SERVER_IP_SSL=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
        RESOLVED_IP=$(dig +short "${D_SSL}" 2>/dev/null | grep -E '^[0-9]' | head -1 || echo "")

        if [[ -z "$RESOLVED_IP" ]]; then
            warn "${D_SSL}: DNS no resuelve — omitido. Reintenta cuando el DNS esté activo."
            local_failed=$((local_failed + 1)); continue
        fi

        if [[ -n "$SERVER_IP_SSL" && "$RESOLVED_IP" != "$SERVER_IP_SSL" ]]; then
            warn "${D_SSL}: DNS apunta a ${RESOLVED_IP} pero este servidor es ${SERVER_IP_SSL}."
            warn "  El challenge ACME fallará si el tráfico HTTP no llega a este servidor."
            warn "  Corrige el DNS o el routing antes de continuar."
            local_failed=$((local_failed + 1)); continue
        fi

        # Verificar que nginx sirve el webroot antes de llamar a certbot
        step "Verificando que nginx sirve el challenge ACME para ${D_SSL}..."
        TEST_FILE="./nginx/certbot/www/.well-known/acme-challenge/.test-${D_SSL}"
        mkdir -p "./nginx/certbot/www/.well-known/acme-challenge"
        echo "ok" > "$TEST_FILE"
        HTTP_CODE=$(curl -sf --max-time 5 -o /dev/null -w "%{http_code}" \
            "http://${D_SSL}/.well-known/acme-challenge/.test-${D_SSL}" 2>/dev/null || echo "000")
        rm -f "$TEST_FILE"

        if [[ "$HTTP_CODE" != "200" ]]; then
            warn "${D_SSL}: Challenge ACME no accesible vía HTTP (código: ${HTTP_CODE})."
            warn "  Asegúrate de que:"
            warn "    1. El DNS del dominio apunta a este servidor (IP: ${SERVER_IP_SSL:-desconocida})"
            warn "    2. El puerto 80 del servidor es accesible desde internet"
            warn "    3. No hay otro servicio (proxy, CDN, Apache) interceptando el puerto 80"
            local_failed=$((local_failed + 1)); continue
        fi
        info "Challenge ACME accesible vía HTTP."

        # Limpiar artefactos previos del mismo dominio (intentos fallidos dejan
        # live/archive/renewal a medias y pueden hacer fallar el siguiente).
        docker compose run --rm --entrypoint sh certbot -c \
            "rm -rf /etc/letsencrypt/live/${D_SSL} \
                     /etc/letsencrypt/archive/${D_SSL} \
                     /etc/letsencrypt/renewal/${D_SSL}.conf" 2>/dev/null || true

        step "Emitiendo certificado para ${D_SSL}..."
        # timeout 120s: si certbot se cuelga (lock, red, Akamai), no esperamos
        # una hora — fallamos rápido y dejamos diagnóstico claro.
        CERTBOT_OUT=$(timeout 120s docker compose run --rm --entrypoint certbot certbot certonly \
            --webroot --webroot-path=/var/www/certbot \
            --email "${CERTBOT_EMAIL}" --agree-tos --no-eff-email --non-interactive \
            ${CERTBOT_EXTRA_FLAGS} \
            -d "${D_SSL}" 2>&1) && CERTBOT_EXIT=0 || CERTBOT_EXIT=$?

        echo "$CERTBOT_OUT"

        if [[ $CERTBOT_EXIT -eq 0 ]]; then
            info "Certificado emitido: ${D_SSL}"
            local_issued=$((local_issued + 1))
        elif [[ $CERTBOT_EXIT -eq 124 ]]; then
            warn "Certbot se colgó >120s para ${D_SSL} (timeout)."
            warn "  Posibles causas: lock residual, outbound HTTPS bloqueado, o rate-limit silencioso."
            warn "  → Verifica con:  docker compose run --rm --entrypoint sh certbot -c 'wget -qO- https://acme-v02.api.letsencrypt.org/directory | head -3'"
            local_failed=$((local_failed + 1))
        else
            if echo "$CERTBOT_OUT" | grep -qi "rateLimited\|too many.*failed\|too many requests"; then
                warn "Rate limit de Let's Encrypt alcanzado para ${D_SSL}."
                warn "  → Espera ~1 hora y reintenta: ./scripts/sync-projects.sh --ssl"
                warn "  → Para probar sin rate limits usa: ./scripts/sync-projects.sh --ssl --staging"
            else
                warn "Error al emitir cert para ${D_SSL}. Revisa el output anterior."
            fi
            local_failed=$((local_failed + 1))
        fi
    done < <(grep -v '^[[:space:]]*#' "$REGISTRY" | grep -v '^[[:space:]]*$')

    if [[ $local_issued -gt 0 ]]; then
        step "Recargando nginx con los nuevos certificados..."
        docker compose exec nginx nginx -s reload 2>/dev/null \
            && info "Nginx recargado." \
            || warn "Nginx no responde. Recárgalo cuando esté activo."
    fi

    # Restaurar el contenedor de renovación automática
    step "Restaurando contenedor de renovación automática (odoo_certbot)..."
    docker compose up -d certbot >/dev/null 2>&1 || warn "No se pudo relevantar odoo_certbot; hacelo manual: docker compose up -d certbot"
    trap - EXIT

    echo -e "  ${GREEN}✓ Emitidos: ${local_issued}${NC}   ${YELLOW}~ Ya activos: ${local_skipped}${NC}   ${RED}✗ Fallidos: ${local_failed}${NC}"
    echo ""
fi

# ─── Resumen ──────────────────────────────────────────────────────────────────
if [[ $NEW_PROJECTS -eq 0 ]]; then
    info "Todos los proyectos en ${REGISTRY} ya están desplegados."
    $WITH_VALIDATE && validate_all_projects
    exit 0
fi

if ! $APPLY; then
    echo ""
    warn "${NEW_PROJECTS} proyecto(s) nuevo(s) detectado(s). Ejecuta con --apply para aplicar:"
    echo "  # 1. Desplegar contenedores:"
    echo "       ./scripts/sync-projects.sh --apply --start"
    echo "  # 2. Emitir SSL (después de que el DNS esté activo):"
    echo "       ./scripts/sync-projects.sh --ssl"
    exit 0
fi

echo ""
info "${#APPLIED_NAMES[@]} proyecto(s) aplicado(s): ${APPLIED_NAMES[*]}"

if ! $WITH_START; then
    echo ""
    warn "Contenedores pendientes de levantar:"
    for name in "${APPLIED_NAMES[@]}"; do
        echo "    docker compose up -d ${name}"
    done
fi
if ! $WITH_SSL; then
    echo ""
    warn "SSL pendiente. Cuando el DNS esté activo:"
    echo "    ./scripts/sync-projects.sh --ssl"
fi

if $WITH_VALIDATE; then
    if $WITH_START && [[ ${#APPLIED_NAMES[@]} -gt 0 ]]; then
        echo ""
        step "Esperando 15s para que los contenedores inicien antes de validar..."
        sleep 15
    fi
    validate_all_projects
fi
