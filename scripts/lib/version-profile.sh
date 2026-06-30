#!/usr/bin/env bash
# =============================================================================
# EXTENDRIX — scripts/lib/version-profile.sh
# Resolver ÚNICO de perfiles por versión de Odoo.
#
# Fuente de verdad de todo lo que varía por versión: imagen base, estilo de
# puerto de tiempo real (gevent/longpolling), websockets y los quirks que hoy
# están dispersos/duplicados en sync-projects.sh, new-project.sh y
# odoo-entrypoint.sh.
#
# USO (como librería — recomendado):
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/version-profile.sh"
#   load_version_profile 18
#   echo "$ODOO_BASE_IMAGE $PORT_STYLE $VP_LP_PORT_LINE"
#
# USO (standalone — para inspeccionar un perfil):
#   ./scripts/lib/version-profile.sh 18
#
# Precedencia (de menor a mayor):
#   1. Defaults derivados del número de versión (comportamiento histórico).
#   2. config/infra.conf            (globales: Postgres, registry, subnet).
#   3. config/versions/<V>.conf     (perfil específico de la versión).
#
# IMPORTANTE: este archivo NO cambia el comportamiento de los scripts existentes
# hasta que estos lo consuman (Fase 3). Por ahora es una capa autónoma.
# =============================================================================

# Raíz del repo, resuelta de forma robusta respecto a este archivo
# (scripts/lib/version-profile.sh → ../.. = raíz).
_VP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VP_PROJECT_DIR="$(cd "${_VP_LIB_DIR}/../.." && pwd)"

# ─── load_version_profile <VERSION> ──────────────────────────────────────────
# Tras llamar, exporta las variables del perfil resuelto.
load_version_profile() {
    local v="${1:-}"

    if ! printf '%s' "$v" | grep -qE '^[0-9]+$'; then
        echo "[version-profile] versión inválida: '${v}' (se espera un entero, ej: 14, 18)" >&2
        return 1
    fi

    # ── 1) Defaults globales (sobreescribibles por config/infra.conf) ─────────
    # Solo lo que consumen los scripts. La imagen/tuning de Postgres y la subnet
    # los lee docker-compose.yml desde .env (no desde acá).
    IMAGE_REGISTRY=""
    IMAGE_TAG_PREFIX="extendrix"

    local infra="${VP_PROJECT_DIR}/config/infra.conf"
    # shellcheck disable=SC1090
    [ -f "$infra" ] && . "$infra"

    # ── 2) Defaults derivados de la versión (comportamiento histórico) ───────
    ODOO_VERSION="$v"
    ODOO_BASE_IMAGE="odoo:${v}.0"
    DOCKERFILE="build/Dockerfile"

    # Odoo 16+ usa gevent_port y expone websockets; ≤15 usa longpolling.
    if [ "$v" -ge 16 ]; then
        PORT_STYLE="gevent";       HAS_WEBSOCKETS="true"
    else
        PORT_STYLE="longpolling";  HAS_WEBSOCKETS="false"
    fi

    # Odoo 14 no acepta --admin-passwd por CLI (se inyecta admin_passwd).
    if [ "$v" -ge 15 ]; then
        SUPPORTS_ADMIN_PASSWD_CLI="true"
    else
        SUPPORTS_ADMIN_PASSWD_CLI="false"
    fi

    # Odoo ≤15 rechaza un addons-path con directorios vacíos; 16+ es permisivo.
    if [ "$v" -ge 16 ]; then
        NEEDS_ADDONS_SANITIZE="false"
    else
        NEEDS_ADDONS_SANITIZE="true"
    fi

    PG_RECOMMENDED="13"

    # ── 3) Perfil específico de la versión (override) ────────────────────────
    local prof="${VP_PROJECT_DIR}/config/versions/${v}.conf"
    # shellcheck disable=SC1090
    [ -f "$prof" ] && . "$prof"

    # ── 4) Valores computados a partir de lo resuelto ────────────────────────
    # Tag de la imagen buildeada (reutilizable entre instancias de la versión).
    if [ -n "$IMAGE_REGISTRY" ]; then
        ODOO_IMAGE_TAG="${IMAGE_REGISTRY}/${IMAGE_TAG_PREFIX}-odoo:${v}"
    else
        ODOO_IMAGE_TAG="${IMAGE_TAG_PREFIX}/odoo:${v}"
    fi

    # Línea de puerto de tiempo real lista para inyectar en odoo.conf.
    if [ "$PORT_STYLE" = "gevent" ]; then
        VP_LP_PORT_LINE="gevent_port    = 8072"
    else
        VP_LP_PORT_LINE="longpolling_port = 8072"
    fi

    export ODOO_VERSION ODOO_BASE_IMAGE DOCKERFILE \
           PORT_STYLE HAS_WEBSOCKETS \
           SUPPORTS_ADMIN_PASSWD_CLI NEEDS_ADDONS_SANITIZE PG_RECOMMENDED \
           IMAGE_REGISTRY IMAGE_TAG_PREFIX \
           ODOO_IMAGE_TAG VP_LP_PORT_LINE
}

# ─── print_version_profile <VERSION> ─────────────────────────────────────────
# Imprime el perfil resuelto (para depurar/inspeccionar).
print_version_profile() {
    load_version_profile "$1" || return 1
    cat <<EOF
Perfil resuelto para Odoo ${ODOO_VERSION}
  ODOO_BASE_IMAGE            = ${ODOO_BASE_IMAGE}
  DOCKERFILE                 = ${DOCKERFILE}
  ODOO_IMAGE_TAG             = ${ODOO_IMAGE_TAG}
  PORT_STYLE                 = ${PORT_STYLE}
  HAS_WEBSOCKETS             = ${HAS_WEBSOCKETS}
  VP_LP_PORT_LINE            = ${VP_LP_PORT_LINE}
  SUPPORTS_ADMIN_PASSWD_CLI  = ${SUPPORTS_ADMIN_PASSWD_CLI}
  NEEDS_ADDONS_SANITIZE      = ${NEEDS_ADDONS_SANITIZE}
  PG_RECOMMENDED             = ${PG_RECOMMENDED}  (informativo; la imagen PG va en .env)
  IMAGE_REGISTRY             = ${IMAGE_REGISTRY:-(local)}
  IMAGE_TAG_PREFIX           = ${IMAGE_TAG_PREFIX}
EOF
}

# Si se ejecuta directamente (no sourceado), imprimir el perfil pedido.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ -z "${1:-}" ]; then
        echo "Uso: $0 <version_odoo>   (ej: $0 18)" >&2
        exit 1
    fi
    print_version_profile "$1"
fi
