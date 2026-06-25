#!/usr/bin/env bash
# =============================================================================
# OLANOIT — setup-ssl.sh
# Emisión inicial de certificados SSL para todos los dominios configurados.
# Ejecutar UNA VEZ durante el setup inicial del servidor.
# =============================================================================

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()  { echo -e "${CYAN}  →${NC} $*"; }

[[ ! -f .env ]] && error ".env no encontrado. Copia .env.example a .env y completa las variables."
source .env

[[ -z "${CERTBOT_EMAIL:-}" ]] && error "CERTBOT_EMAIL no configurado en .env"

# Recopilar todos los dominios del .env
DOMAINS=()
for var in $(compgen -v | grep '^DOMAIN_'); do
    val="${!var}"
    [[ -n "$val" ]] && DOMAINS+=("$val")
done

[[ ${#DOMAINS[@]} -eq 0 ]] && error "No se encontraron dominios configurados en .env (variables DOMAIN_*)"

echo ""
echo "══ OLANOIT — Setup SSL ══"
echo ""
echo "Dominios a certificar:"
for d in "${DOMAINS[@]}"; do echo "  - $d"; done
echo ""

# Crear directorios
mkdir -p nginx/certbot/www nginx/certbot/conf

# Verificar DNS de cada dominio
SERVER_IP=$(curl -sf https://api.ipify.org || echo "desconocido")
echo "IP de este servidor: $SERVER_IP"
echo ""

for domain in "${DOMAINS[@]}"; do
    resolved=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]' | head -1 || echo "no resuelve")
    if [[ "$resolved" == "$SERVER_IP" ]]; then
        info "DNS OK: $domain → $resolved"
    else
        warn "DNS puede estar mal: $domain → $resolved (esperado: $SERVER_IP)"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# Nginx mínimo para ACME challenge
#
# Los upstreams en 00-upstreams.conf referencian contenedores Odoo que no
# están corriendo aún. Nginx falla al resolver esos hostnames y no abre
# el puerto 80. Se usa una config temporal sin upstreams para el challenge.
# ---------------------------------------------------------------------------
ACME_CONF="nginx/conf.d/00-setup-acme.conf"
VHOSTS_CONF="nginx/conf.d/vhosts-projects.conf"
UPSTREAMS_CONF="nginx/conf.d/00-upstreams.conf"

restore_nginx_conf() {
    [[ -f "${VHOSTS_CONF}.setup"    ]] && mv "${VHOSTS_CONF}.setup"    "$VHOSTS_CONF"
    [[ -f "${UPSTREAMS_CONF}.setup" ]] && mv "${UPSTREAMS_CONF}.setup" "$UPSTREAMS_CONF"
    [[ -f "$ACME_CONF"              ]] && rm -f "$ACME_CONF"
}
trap restore_nginx_conf EXIT

cat > "$ACME_CONF" << 'NGINXEOF'
server {
    listen 80 default_server;
    server_name _;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 200 "setup\n"; }
}
NGINXEOF

# Ocultar vhosts y upstreams (contienen refs a Odoo que no está corriendo)
[[ -f "$VHOSTS_CONF"    ]] && mv "$VHOSTS_CONF"    "${VHOSTS_CONF}.setup"
[[ -f "$UPSTREAMS_CONF" ]] && mv "$UPSTREAMS_CONF" "${UPSTREAMS_CONF}.setup"

step "Levantando Nginx para challenge ACME (config mínima)..."
docker compose up -d --force-recreate nginx
sleep 3

# Emitir cert para cada dominio
for domain in "${DOMAINS[@]}"; do
    step "Emitiendo certificado para: $domain"
    # Limpiar artefactos de intentos previos (certs dummy o fallidos)
    docker compose run --rm --entrypoint sh certbot -c \
        "rm -rf /etc/letsencrypt/live/${domain} \
                 /etc/letsencrypt/archive/${domain} \
                 /etc/letsencrypt/renewal/${domain}.conf" 2>/dev/null || true
    docker compose run --rm --entrypoint certbot certbot certonly \
        --webroot \
        --webroot-path=/var/www/certbot \
        --email "$CERTBOT_EMAIL" \
        --agree-tos \
        --no-eff-email \
        -d "$domain" && \
        info "Certificado emitido: $domain" || \
        warn "Falló la emisión para $domain"
done

# Restaurar config completa y recargar nginx
restore_nginx_conf
trap - EXIT

step "Recargando Nginx con config completa y SSL activo..."
docker compose up -d --force-recreate nginx

info "Setup SSL completado. Ejecuta: ./scripts/ops.sh start"
