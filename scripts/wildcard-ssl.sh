#!/usr/bin/env bash
# =============================================================================
# EXTENDRIX — wildcard-ssl.sh
#
# Reutiliza un certificado SSL *wildcard* (ej: *.odoo-rideco.mx) para un
# subdominio concreto, en lugar de emitir un certificado individual con
# certbot. Como el wildcard ya cubre el subdominio, el cert es válido tal cual.
#
# Dos modos:
#   - SYMLINK (recomendado): apunta live/<subdominio> → live/<wildcard> dentro
#     del volumen de certbot. Cero duplicación y renovación automática: cuando
#     el wildcard se renueva, el subdominio toma el cert nuevo sin tocar nada.
#   - COPIA: copia fullchain/privkey/chain desde un origen externo (otro
#     servidor, backup, ruta del host) hacia live/<subdominio>. Es un snapshot:
#     al renovar el wildcard hay que volver a copiar.
#
# El vhost generado por sync-projects.sh ya referencia
# /etc/letsencrypt/live/<subdominio>/{fullchain,privkey,chain}.pem, por lo que
# poblar ese directorio es suficiente; no hay que editar nginx.
#
# USO:
#   # Symlink al wildcard local (autodetecta el lineage que cubre el subdominio):
#   ./scripts/wildcard-ssl.sh merida.odoo-rideco.mx
#
#   # Symlink indicando explícitamente el lineage wildcard:
#   ./scripts/wildcard-ssl.sh merida.odoo-rideco.mx --wildcard odoo-rideco.mx
#
#   # Copia desde un directorio externo con fullchain.pem/privkey.pem/chain.pem:
#   ./scripts/wildcard-ssl.sh merida.odoo-rideco.mx --from /ruta/al/wildcard
#
#   # Copia indicando archivos sueltos:
#   ./scripts/wildcard-ssl.sh merida.odoo-rideco.mx \
#       --fullchain /ruta/fullchain.pem --privkey /ruta/privkey.pem
#
# OPCIONES:
#   --wildcard <lineage>  Nombre del lineage wildcard en el volumen certbot
#                         (carpeta bajo live/). Si se omite, se autodetecta.
#   --from <dir>          Modo copia: directorio con {fullchain,privkey,chain}.pem
#   --fullchain <f>       Modo copia: ruta al fullchain.pem
#   --privkey <k>         Modo copia: ruta al privkey.pem
#   --chain <c>           Modo copia: ruta al chain.pem (opcional)
#   --link                Forzar modo symlink (al wildcard local)
#   --copy                Forzar modo copia (del wildcard local, sin symlink)
#   --no-reload           No recargar nginx al terminar
#   --auto                Modo no-interactivo para sync-projects.sh: si no hay
#                         wildcard que cubra el subdominio, sale con código 3
#                         (señal de "emití un cert individual") sin ruido.
#   --quiet               Menos verboso
#
# CÓDIGOS DE SALIDA:
#   0  OK (symlink/copia realizada o ya estaba correcta)
#   2  Error (argumentos, wildcard inexistente, copia fallida)
#   3  Sólo en --auto: ningún wildcard cubre el subdominio
# =============================================================================

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
QUIET=false
info()  { $QUIET || echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*" >&2; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; exit 2; }
step()  { $QUIET || echo -e "${CYAN}  →${NC} $*"; }

# ── Parseo de argumentos ──────────────────────────────────────────────────────
SUBDOMAIN=""
WILDCARD_LINEAGE=""
FROM_DIR=""
SRC_FULLCHAIN=""; SRC_PRIVKEY=""; SRC_CHAIN=""
MODE=""              # link | copy   (se infiere si no se fuerza)
RELOAD=true
AUTO=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wildcard)  WILDCARD_LINEAGE="${2:-}"; shift 2 ;;
        --from)      FROM_DIR="${2:-}"; shift 2 ;;
        --fullchain) SRC_FULLCHAIN="${2:-}"; shift 2 ;;
        --privkey)   SRC_PRIVKEY="${2:-}"; shift 2 ;;
        --chain)     SRC_CHAIN="${2:-}"; shift 2 ;;
        --link)      MODE="link"; shift ;;
        --copy)      MODE="copy"; shift ;;
        --no-reload) RELOAD=false; shift ;;
        --auto)      AUTO=true; shift ;;
        --quiet)     QUIET=true; shift ;;
        --help|-h)
            sed -n '2,60p' "$0"; exit 0 ;;
        -*)          error "Opción desconocida: $1" ;;
        *)
            [[ -z "$SUBDOMAIN" ]] && SUBDOMAIN="$1" || error "Argumento extra: $1"
            shift ;;
    esac
done

[[ -z "$SUBDOMAIN" ]] && error "Falta el subdominio (ej: merida.odoo-rideco.mx)"

# Validación básica del subdominio
[[ "$SUBDOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || error "Subdominio inválido: $SUBDOMAIN"

LIVE="/etc/letsencrypt/live"          # ruta dentro del contenedor certbot
HOST_LIVE="./nginx/certbot/conf/live" # mismo dir, lado host (bind mount)

# Helper: ejecutar sh dentro del contenedor certbot (consistente con el resto
# de la infra; evita problemas de permisos root sobre el volumen de certbot).
cb() { docker compose run --rm -T --entrypoint sh certbot -c "$1"; }

command -v docker >/dev/null 2>&1 || error "docker no está disponible"

# ── Determinar modo si no se forzó ────────────────────────────────────────────
if [[ -z "$MODE" ]]; then
    if [[ -n "$FROM_DIR" || -n "$SRC_FULLCHAIN" ]]; then
        MODE="copy"
    else
        MODE="link"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# MODO COPIA DESDE ORIGEN EXTERNO
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "copy" && ( -n "$FROM_DIR" || -n "$SRC_FULLCHAIN" ) ]]; then
    if [[ -n "$FROM_DIR" ]]; then
        [[ -d "$FROM_DIR" ]] || error "No existe el directorio de origen: $FROM_DIR"
        SRC_FULLCHAIN="${SRC_FULLCHAIN:-$FROM_DIR/fullchain.pem}"
        SRC_PRIVKEY="${SRC_PRIVKEY:-$FROM_DIR/privkey.pem}"
        [[ -f "$FROM_DIR/chain.pem" ]] && SRC_CHAIN="${SRC_CHAIN:-$FROM_DIR/chain.pem}"
    fi
    [[ -f "$SRC_FULLCHAIN" ]] || error "No existe fullchain de origen: $SRC_FULLCHAIN"
    [[ -f "$SRC_PRIVKEY"   ]] || error "No existe privkey de origen: $SRC_PRIVKEY"

    # Verificar que el cert de origen realmente cubre el subdominio (SAN).
    SRC_SAN="$(openssl x509 -in "$SRC_FULLCHAIN" -noout -ext subjectAltName 2>/dev/null || true)"
    if ! { echo "$SRC_SAN" | grep -qiF "DNS:*.${SUBDOMAIN#*.}" \
        || echo "$SRC_SAN" | grep -qiF "DNS:${SUBDOMAIN}"; }; then
        warn "El cert de origen no parece cubrir ${SUBDOMAIN} (revisá el SAN)."
        warn "  SAN del origen: $(echo "$SRC_SAN" | tail -1 | sed 's/^ *//')"
        warn "  Continuando igualmente (forzaste copia)."
    fi

    step "Copiando cert hacia ${LIVE}/${SUBDOMAIN}/ (modo copia)..."
    cb "rm -rf '${LIVE}/${SUBDOMAIN}' && mkdir -p '${LIVE}/${SUBDOMAIN}'"
    cb "cat > '${LIVE}/${SUBDOMAIN}/fullchain.pem'" < "$SRC_FULLCHAIN"
    cb "cat > '${LIVE}/${SUBDOMAIN}/privkey.pem' && chmod 600 '${LIVE}/${SUBDOMAIN}/privkey.pem'" < "$SRC_PRIVKEY"
    if [[ -n "$SRC_CHAIN" && -f "$SRC_CHAIN" ]]; then
        cb "cat > '${LIVE}/${SUBDOMAIN}/chain.pem'" < "$SRC_CHAIN"
    else
        # nginx referencia chain.pem (ssl_trusted_certificate). Si el origen no
        # lo trae, usamos fullchain como sustituto (OCSP stapling está off).
        warn "Sin chain.pem de origen: uso fullchain.pem como chain (OCSP stapling deshabilitado)."
        cb "cp '${LIVE}/${SUBDOMAIN}/fullchain.pem' '${LIVE}/${SUBDOMAIN}/chain.pem'"
    fi
    info "Cert copiado para ${SUBDOMAIN}."
    DID="copia"

else
    # ─────────────────────────────────────────────────────────────────────────
    # MODO LOCAL: el wildcard ya vive en el volumen certbot de este servidor
    # ─────────────────────────────────────────────────────────────────────────

    # Autodetectar el lineage wildcard que cubre el subdominio si no se indicó.
    PARENT="${SUBDOMAIN#*.}"
    if [[ -z "$WILDCARD_LINEAGE" ]]; then
        step "Buscando un wildcard que cubra ${SUBDOMAIN} (*.${PARENT})..."
        # Un único sh dentro del contenedor recorre los lineages y devuelve el
        # primero cuyo SAN contenga *.<parent>.
        WILDCARD_LINEAGE="$(cb "
            for d in ${LIVE}/*/; do
                [ -f \"\$d/fullchain.pem\" ] || continue
                name=\$(basename \"\$d\")
                san=\$(openssl x509 -in \"\$d/fullchain.pem\" -noout -ext subjectAltName 2>/dev/null)
                if echo \"\$san\" | grep -qiF \"DNS:*.${PARENT}\"; then
                    echo \"\$name\"; break
                fi
            done
        " 2>/dev/null | tr -d '[:space:]' || true)"

        if [[ -z "$WILDCARD_LINEAGE" ]]; then
            if $AUTO; then
                exit 3   # señal para sync: no hay wildcard, que emita cert individual
            fi
            error "No se encontró ningún wildcard que cubra *.${PARENT} en ${HOST_LIVE}/.
       Emití primero el wildcard (certbot dns-01) o usá --from para copiar desde un origen externo."
        fi
        info "Wildcard detectado: ${WILDCARD_LINEAGE} (cubre *.${PARENT})."
    else
        # Verificar que el lineage indicado existe y cubre el subdominio.
        if ! cb "[ -f '${LIVE}/${WILDCARD_LINEAGE}/fullchain.pem' ]" >/dev/null 2>&1; then
            error "El lineage wildcard '${WILDCARD_LINEAGE}' no existe en ${HOST_LIVE}/."
        fi
        if ! cb "san=\$(openssl x509 -in '${LIVE}/${WILDCARD_LINEAGE}/fullchain.pem' -noout -ext subjectAltName 2>/dev/null); echo \"\$san\" | grep -qiF \"DNS:*.${PARENT}\" || echo \"\$san\" | grep -qiF \"DNS:${SUBDOMAIN}\"" >/dev/null 2>&1; then
            warn "El lineage '${WILDCARD_LINEAGE}' no parece cubrir ${SUBDOMAIN}; continúo porque lo indicaste explícitamente."
        fi
    fi

    [[ "$WILDCARD_LINEAGE" == "$SUBDOMAIN" ]] && error "El lineage wildcard y el subdominio no pueden ser el mismo."

    if [[ "$MODE" == "copy" ]]; then
        step "Copiando cert del wildcard ${WILDCARD_LINEAGE} → ${SUBDOMAIN} (modo copia local)..."
        cb "rm -rf '${LIVE}/${SUBDOMAIN}' && mkdir -p '${LIVE}/${SUBDOMAIN}' && \
            for f in fullchain privkey chain cert; do \
                [ -f '${LIVE}/${WILDCARD_LINEAGE}/'\$f'.pem' ] && \
                cp -L '${LIVE}/${WILDCARD_LINEAGE}/'\$f'.pem' '${LIVE}/${SUBDOMAIN}/'\$f'.pem'; \
            done && chmod 600 '${LIVE}/${SUBDOMAIN}/privkey.pem'"
        info "Cert del wildcard copiado para ${SUBDOMAIN}."
        DID="copia local"
    else
        # SYMLINK relativo dentro de live/ (live/<sub> → <wildcard_lineage>).
        # Idempotente: si ya apunta bien, no hace nada.
        if cb "[ -L '${LIVE}/${SUBDOMAIN}' ] && [ \"\$(readlink '${LIVE}/${SUBDOMAIN}')\" = '${WILDCARD_LINEAGE}' ]" >/dev/null 2>&1; then
            info "${SUBDOMAIN} ya está enlazado al wildcard ${WILDCARD_LINEAGE} — sin cambios."
            DID="symlink (ya existía)"
        else
            step "Enlazando ${SUBDOMAIN} → ${WILDCARD_LINEAGE} (symlink, renovación automática)..."
            # Eliminar cualquier cert provisional/auto-firmado previo y symlinkear.
            cb "rm -rf '${LIVE}/${SUBDOMAIN}' && ln -s '${WILDCARD_LINEAGE}' '${LIVE}/${SUBDOMAIN}'"
            info "${SUBDOMAIN} enlazado al wildcard ${WILDCARD_LINEAGE}."
            DID="symlink"
        fi
    fi
fi

# ── Aviso si el subdominio aún no tiene vhost ────────────────────────────────
VHOSTS="nginx/conf.d/vhosts-projects.conf"
if [[ -f "$VHOSTS" ]] && ! grep -q "live/${SUBDOMAIN}/" "$VHOSTS" 2>/dev/null; then
    warn "No encontré un vhost que use live/${SUBDOMAIN}/ en ${VHOSTS}."
    warn "  Asegurate de que el proyecto/dominio esté en projects-registry.conf y corré:"
    warn "    ./scripts/sync-projects.sh --apply"
fi

# ── Validar que el fullchain destino sea un certificado legible ───────────────
# Red de seguridad: si el origen vino corrupto/vacío, abortamos ANTES de tocar
# nginx para no dejar la config rota (nginx no carga un fullchain inválido).
if ! cb "openssl x509 -in '${LIVE}/${SUBDOMAIN}/fullchain.pem' -noout" >/dev/null 2>&1; then
    error "El fullchain de ${SUBDOMAIN} no es un certificado legible (origen corrupto/vacío).
       No toco nginx. Revisá el cert de origen y reintentá."
fi

# ── Recargar nginx ────────────────────────────────────────────────────────────
if $RELOAD; then
    if docker compose ps --format '{{.Status}}' nginx 2>/dev/null | grep -qi '^up'; then
        step "Validando y recargando nginx..."
        if docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
            docker compose exec -T nginx nginx -s reload >/dev/null 2>&1 \
                && info "Nginx recargado." \
                || warn "No se pudo recargar nginx; hacelo manual: docker compose exec nginx nginx -s reload"
        else
            warn "nginx -t falló; no recargo para no tirar el server. Revisá: docker compose exec nginx nginx -t"
        fi
    else
        warn "Nginx no está activo; recargá cuando lo levantes: docker compose exec nginx nginx -s reload"
    fi
fi

$QUIET || echo ""
info "Listo (${DID}): ${SUBDOMAIN} usa el cert wildcard."
exit 0
