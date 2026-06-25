#!/usr/bin/env bash
# =============================================================================
# EXTENDRIX — new-project.sh
# Crea la estructura de directorios y archivos base para un nuevo proyecto.
#
# USO:
#   ./scripts/new-project.sh <proyecto> <version_odoo> <entorno> <puerto_base>
#
# EJEMPLOS:
#   ./scripts/new-project.sh clientenuevo 19 prod 19010
#   ./scripts/new-project.sh honordev 18 dev 18030
#   ./scripts/new-project.sh mapesa 17 prod 17020
# =============================================================================

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# Cargar .env para resolver POSTGRES_USER en el template del odoo.conf
[[ -f .env ]] && set -a && source .env && set +a

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()  { echo -e "${CYAN}  →${NC} $*"; }

PROYECTO="${1:-}"
VERSION="${2:-}"
ENTORNO="${3:-}"
PUERTO_BASE="${4:-}"

[[ -z "$PROYECTO"    ]] && error "Falta: nombre del proyecto (ej: clientenuevo)"
[[ -z "$VERSION"     ]] && error "Falta: versión de Odoo (ej: 17, 18, 19)"
[[ -z "$ENTORNO"     ]] && error "Falta: entorno (dev | sta | prod)"
[[ -z "$PUERTO_BASE" ]] && error "Falta: puerto base del host (ej: 19010)"

CONTAINER_NAME="odoo${VERSION}_${PROYECTO}_${ENTORNO}"
PUERTO_LP=$((PUERTO_BASE + 1))
VOLUME_NAME="odoo${VERSION}_${PROYECTO}_${ENTORNO}_data"
DB_PREFIX="${PROYECTO}_${ENTORNO}"

echo ""
echo -e "${BOLD}══ EXTENDRIX — Nuevo Proyecto ══${NC}"
echo ""
echo -e "  Proyecto    : ${CYAN}$PROYECTO${NC}"
echo -e "  Odoo        : ${CYAN}$VERSION${NC}"
echo -e "  Entorno     : ${CYAN}$ENTORNO${NC}"
echo -e "  Contenedor  : ${CYAN}$CONTAINER_NAME${NC}"
echo -e "  Puerto HTTP : ${CYAN}127.0.0.1:${PUERTO_BASE}:8069${NC}"
echo -e "  Puerto LP   : ${CYAN}127.0.0.1:${PUERTO_LP}:8072${NC}"
echo -e "  Volumen     : ${CYAN}$VOLUME_NAME${NC}"
echo -e "  DB prefix   : ${CYAN}${DB_PREFIX}_*${NC}"
echo ""

# ─── 1. Crear estructura de directorios ───────────────────────────────────────
step "Creando directorios..."
mkdir -p "projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/config"
mkdir -p "projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/addons"
# Volumen central de backups: ./backups/<proyecto>/{db,filestore}
mkdir -p "backups/${PROYECTO}/db"
mkdir -p "backups/${PROYECTO}/filestore"
info "Directorios creados."

# ─── 2. Crear odoo.conf ───────────────────────────────────────────────────────
CONF_FILE="projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/config/odoo.conf"

# Determinar workers y logging según entorno
if [[ "$ENTORNO" == "prod" || "$ENTORNO" == "sta" ]]; then
    WORKERS=4; LOG_LEVEL="warn"; MEM_SOFT=2147483648; MEM_HARD=2684354560
    ADMIN_PASSWD="Staging@3xt3ndr1x"
else
    WORKERS=2; LOG_LEVEL="info"; MEM_SOFT=1073741824; MEM_HARD=1610612736
    ADMIN_PASSWD="Testing@3xt3ndr1x"
fi

cat > "$CONF_FILE" << EOF
# =============================================================================
# EXTENDRIX — Odoo ${VERSION} | Proyecto: ${PROYECTO} | Entorno: ${ENTORNO^^}
# Contenedor: ${CONTAINER_NAME}
# Generado por: new-project.sh
# =============================================================================

[options]

# Conexión a PostgreSQL.
# db_password se inyecta por el entrypoint oficial desde la env var PASSWORD,
# así que NO se commitea acá. db_host/port/user sí están baked-in para que
# operaciones como \`docker exec ... odoo --update\` (que bypassean el entrypoint)
# puedan resolver la conexión sin depender de env vars.
db_host  = db
db_port  = 5432
db_user  = ${POSTGRES_USER:-odoo}

dbfilter    = ^${DB_PREFIX}_.*\$

data_dir    = /var/lib/odoo
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/enterprise,/mnt/shared-addons,/mnt/extra-addons

http_port      = 8069
gevent_port    = 8072
http_interface =
proxy_mode     = True

workers            = ${WORKERS}
limit_memory_soft  = ${MEM_SOFT}
limit_memory_hard  = ${MEM_HARD}
limit_request      = 2048
limit_time_cpu     = 60
limit_time_real    = 120
db_maxconn         = 24

log_level   = ${LOG_LEVEL}
log_handler = :WARNING,werkzeug:CRITICAL

list_db      = True
admin_passwd = ${ADMIN_PASSWD}

max_cron_threads = 2
unaccent         = True

websocket_keep_alive_timeout = 3600
websocket_rate_limit_burst   = 10
websocket_rate_limit_delay   = 0.2
EOF
info "odoo.conf creado: $CONF_FILE"

# ─── 3. Mostrar bloque para docker-compose.yml ───────────────────────────────
echo ""
warn "PASO MANUAL 1 — Agrega esto a docker-compose.yml (sección services:)"
echo ""
cat << EOF
  # ═══════════════════════════════════════════════════════
  # PROYECTO: ${PROYECTO^^} — Odoo ${VERSION} ${ENTORNO^^}
  # Contenedor: ${CONTAINER_NAME}
  # ═══════════════════════════════════════════════════════
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
    volumes:
      - ${VOLUME_NAME}:/var/lib/odoo
      - ./projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/config/odoo.conf:/etc/odoo/odoo.conf:ro
      - ./projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/addons:/mnt/extra-addons
      - ./shared-addons/${VERSION}:/mnt/shared-addons:ro
      - ./enterprise/odoo${VERSION}:/mnt/enterprise:ro
      - ./backups:/backups
    ports:
      - "127.0.0.1:${PUERTO_BASE}:8069"
      - "127.0.0.1:${PUERTO_LP}:8072"
    networks:
      - odoo_net
    command: odoo --config=/etc/odoo/odoo.conf
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8069/web/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    logging:
      driver: "json-file"
      options: { max-size: "100m", max-file: "5" }
EOF

echo ""
warn "PASO MANUAL 2 — Agrega esto a la sección volumes: de docker-compose.yml"
echo ""
cat << EOF
  ${VOLUME_NAME}:
    name: ${VOLUME_NAME}
EOF

echo ""
warn "PASO MANUAL 3 — Agrega esto a nginx/conf.d/00-upstreams.conf"
echo ""
cat << EOF
upstream up_${PROYECTO}_${ENTORNO}_http {
    server ${CONTAINER_NAME}:8069 weight=1 max_fails=3 fail_timeout=30s;
    keepalive 16;
}
upstream up_${PROYECTO}_${ENTORNO}_lp {
    server ${CONTAINER_NAME}:8072 weight=1 max_fails=3 fail_timeout=30s;
    keepalive 8;
}
EOF

echo ""
warn "PASO MANUAL 4 — Crea el vhost en nginx/conf.d/vhosts-projects.conf"
echo "  Copia un bloque existente y reemplaza el dominio y los upstream names."
echo ""
warn "PASO MANUAL 5 — Certificado SSL (primero el temporal para que nginx arranque, luego el real):"
echo "  # 5a. Crear cert auto-firmado temporal (necesario para que nginx cargue el vhost HTTPS):"
echo "  DOMAIN=tu-nuevo-dominio.com"
echo "  mkdir -p ./nginx/certbot/conf/live/\$DOMAIN"
echo "  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \\"
echo "    -keyout ./nginx/certbot/conf/live/\$DOMAIN/privkey.pem \\"
echo "    -out    ./nginx/certbot/conf/live/\$DOMAIN/fullchain.pem \\"
echo "    -subj \"/CN=\$DOMAIN\" 2>/dev/null"
echo "  cp ./nginx/certbot/conf/live/\$DOMAIN/fullchain.pem ./nginx/certbot/conf/live/\$DOMAIN/chain.pem"
echo "  docker compose exec nginx nginx -s reload"
echo ""
echo "  # 5b. Emitir cert real con Let's Encrypt:"
echo "  docker compose run --rm certbot certonly --webroot -w /var/www/certbot \\"
echo "    --email \$(grep CERTBOT_EMAIL .env | cut -d= -f2) --agree-tos --no-eff-email -d \$DOMAIN"
echo "  docker compose exec nginx nginx -s reload"
echo ""
warn "PASO MANUAL 6 — Levanta el nuevo contenedor:"
echo "  docker compose up -d ${CONTAINER_NAME}"
echo "  ./scripts/ops.sh logs ${CONTAINER_NAME} 50"
echo ""

# ─── 4. Crear README del proyecto ────────────────────────────────────────────
cat > "projects/${PROYECTO}/README.md" << EOF
# Proyecto: ${PROYECTO^^}

**Versión Odoo:** ${VERSION}.0  
**Entorno:** ${ENTORNO}  
**Contenedor:** \`${CONTAINER_NAME}\`  
**DB prefix:** \`${DB_PREFIX}_*\`  

## Addons personalizados

Colocar los módulos en:
\`\`\`
projects/${PROYECTO}/odoo${VERSION}/${ENTORNO}/addons/
\`\`\`

## Comandos rápidos

\`\`\`bash
# Ver logs
./scripts/ops.sh logs ${CONTAINER_NAME} 200

# Actualizar un módulo
./scripts/ops.sh module ${CONTAINER_NAME} ${DB_PREFIX}_principal mi_modulo update

# Backup (DB + filestore → ./backups/${PROYECTO}/)
./scripts/ops.sh backup ${PROYECTO} ${CONTAINER_NAME} ${DB_PREFIX}_principal

# Listar backups disponibles
./scripts/ops.sh list-backups ${PROYECTO}

# Restaurar (auto-detecta filestore por timestamp)
./scripts/ops.sh restore ${CONTAINER_NAME} ${DB_PREFIX}_copia \\
  ${PROYECTO}/db/<TIMESTAMP>_${DB_PREFIX}_principal.sql.gz

# Reiniciar
docker compose restart ${CONTAINER_NAME}
\`\`\`
EOF
info "README.md del proyecto creado."

echo ""
info "Estructura del proyecto '${PROYECTO}' creada exitosamente."
info "Sigue los pasos manuales indicados arriba para completar la integración."
