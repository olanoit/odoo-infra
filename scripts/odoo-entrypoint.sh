#!/bin/sh
# =============================================================================
# EXTENDRIX — odoo-entrypoint.sh
# Wrapper del entrypoint de Odoo: instala los requirements.txt de los módulos
# (shared-addons, addons del proyecto y enterprise) antes de pasar el control al
# entrypoint oficial.
# =============================================================================
set -e

# ── Helpers para sanear el addons-path (compatibilidad Odoo 14) ───────────────
# Odoo 14 rechaza un addons-path con directorios "vacíos": exige que cada ruta
# contenga al menos un módulo (subdir con __manifest__.py / __openerp__.py), si
# no falla con "the path '...' is not a valid addons directory". Versiones 16+
# son más permisivas. Para arrancar con enterprise/shared-addons/extra-addons
# todavía vacíos, filtramos del path los dirs sin módulos (conservando el core).
_is_addons_dir() {
    _iad_d="$1"
    [ -d "$_iad_d" ] || return 1
    for _iad_sub in "$_iad_d"/*/; do
        [ -d "$_iad_sub" ] || continue
        if [ -f "${_iad_sub}__manifest__.py" ] || [ -f "${_iad_sub}__openerp__.py" ]; then
            return 0
        fi
    done
    return 1
}

# Filtra una lista coma-separada de addons-path: conserva el core de Odoo y los
# dirs con módulos; descarta los vacíos. Emite avisos por stderr (no contaminan
# la salida capturada por $(...)).
_sanitize_addons_path() {
    _sap_out=""
    _sap_oifs="$IFS"
    IFS=','
    for _sap_p in $1; do
        case "$_sap_p" in
            */dist-packages/odoo/addons|*/odoo/addons) _sap_keep=1 ;;
            *) if _is_addons_dir "$_sap_p"; then _sap_keep=1; else _sap_keep=0; fi ;;
        esac
        if [ "$_sap_keep" = 1 ]; then
            if [ -z "$_sap_out" ]; then _sap_out="$_sap_p"; else _sap_out="${_sap_out},${_sap_p}"; fi
        else
            echo "[startup] addons-path: omito '${_sap_p}' (sin módulos; versiones antiguas lo rechazarían)" >&2
        fi
    done
    IFS="$_sap_oifs"
    printf '%s' "$_sap_out"
}

# Instalar dependencias Python de cualquier módulo que tenga requirements.txt,
# en shared-addons, en los addons del proyecto (extra-addons) y en enterprise
# (máx 2 niveles de profundidad: <dir>/<modulo>/requirements.txt).
#
# Detección robusta del comando pip (la imagen odoo:14.0 / Debian Buster trae
# 'pip3', no 'pip'; las imágenes 17/18/19 traen 'pip'). Y de los flags:
#   --break-system-packages → solo si el pip lo soporta (PEP 668, Odoo 16+).
#   --user                  → si el contenedor no corre como root (instala en
#                             el HOME del usuario odoo, que es el volumen data_dir).
if command -v pip3 >/dev/null 2>&1; then PIP="pip3"
elif command -v pip >/dev/null 2>&1; then PIP="pip"
else PIP="python3 -m pip"; fi
PIP_FLAGS="--quiet --no-warn-script-location --no-cache-dir"
[ "$(id -u)" != "0" ] && PIP_FLAGS="$PIP_FLAGS --user"
if $PIP install --help 2>/dev/null | grep -q -- '--break-system-packages'; then
    PIP_FLAGS="$PIP_FLAGS --break-system-packages"
fi

for ADDONS_BASE in /mnt/shared-addons /mnt/extra-addons /mnt/enterprise; do
    [ -d "$ADDONS_BASE" ] || continue
    find "$ADDONS_BASE" -maxdepth 2 -name requirements.txt 2>/dev/null | while read req; do
        echo "[startup] Instalando dependencias ($PIP): $req"
        tmp_dir=$(mktemp -d)
        cp -r "$(dirname "$req")/." "$tmp_dir/"
        # Quitar el flag -e (editable): pip instalaría apuntando al tmp_dir que luego
        # se borra, dejando el import roto. Sin -e, pip copia los archivos a site-packages.
        sed 's/^-e //' "$tmp_dir/requirements.txt" > "$tmp_dir/requirements_fixed.txt"
        # El '|| echo' evita que un fallo de pip aborte el wrapper (set -e) y deje
        # el contenedor en restart loop: Odoo arranca igual y queda el aviso.
        (cd "$tmp_dir" && $PIP install $PIP_FLAGS -r requirements_fixed.txt) \
            || echo "[startup] AVISO: no se pudieron instalar dependencias de $req"
        rm -rf "$tmp_dir"
    done
done

# ── Flags del perfil de la versión (inyectados por el servicio en docker-compose) ──
# Defaults retro-compatibles: las instancias creadas antes de la capa de perfiles
# no pasan estas vars → se asume el comportamiento conservador de Odoo ≤14.
#   SUPPORTS_ADMIN_PASSWD_CLI=false → quitar --admin-passwd del CLI (Odoo 14 crashea).
#   NEEDS_ADDONS_SANITIZE=true      → filtrar del addons-path los dirs sin módulos.
SUPPORTS_ADMIN_PASSWD_CLI="${ODOO_SUPPORTS_ADMIN_PASSWD_CLI:-false}"
NEEDS_ADDONS_SANITIZE="${ODOO_NEEDS_ADDONS_SANITIZE:-true}"

# ── Config de runtime: admin_passwd + addons-path saneado ─────────────────────
# Generamos SIEMPRE un config efectivo en el data_dir (escribible) para:
#   1. Sanear el addons-path si NEEDS_ADDONS_SANITIZE=true.
#   2. Repuntar --config a este conf (el montado en /etc/odoo es :ro).
# La inyección de admin_passwd solo ocurre si ODOO_MASTER_PASSWD está definido
# (el secreto no se versiona); aplica a todas las versiones.
SRC_CONF=/etc/odoo/odoo.conf
RT_CONF=/var/lib/odoo/.odoo-runtime.conf
if [ -f "$SRC_CONF" ]; then
    cp "$SRC_CONF" "$RT_CONF"
else
    printf '[options]\n' > "$RT_CONF"
fi

# Inyectar admin_passwd si está disponible (quitando cualquiera previo).
if [ -n "${ODOO_MASTER_PASSWD:-}" ]; then
    grep -v '^[[:space:]]*admin_passwd' "$RT_CONF" > "${RT_CONF}.tmp" && mv "${RT_CONF}.tmp" "$RT_CONF"
    printf 'admin_passwd = %s\n' "${ODOO_MASTER_PASSWD}" >> "$RT_CONF"
fi

# Sanear el addons_path del conf (descartar dirs vacíos) si el perfil lo pide.
if [ "$NEEDS_ADDONS_SANITIZE" = "true" ] && grep -q '^[[:space:]]*addons_path' "$RT_CONF"; then
    _ap_cur=$(grep -m1 '^[[:space:]]*addons_path' "$RT_CONF" | sed 's/^[[:space:]]*addons_path[[:space:]]*=[[:space:]]*//')
    _ap_san=$(_sanitize_addons_path "$_ap_cur")
    grep -v '^[[:space:]]*addons_path' "$RT_CONF" > "${RT_CONF}.tmp" && mv "${RT_CONF}.tmp" "$RT_CONF"
    printf 'addons_path = %s\n' "$_ap_san" >> "$RT_CONF"
fi
chmod 600 "$RT_CONF" 2>/dev/null || true

# Reescribir argumentos: repuntar --config al config de runtime; quitar
# --admin-passwd=* solo si la versión no lo soporta por CLI (Odoo 14 crashea);
# sanear --addons-path=* solo si el perfil lo pide.
for arg do
    shift
    case "$arg" in
        --admin-passwd=*|--admin_passwd=*)
            if [ "$SUPPORTS_ADMIN_PASSWD_CLI" = "true" ]; then set -- "$@" "$arg"; fi
            ;;
        --config=*|-c=*) set -- "$@" "--config=$RT_CONF" ;;
        --addons-path=*)
            if [ "$NEEDS_ADDONS_SANITIZE" = "true" ]; then
                set -- "$@" "--addons-path=$(_sanitize_addons_path "${arg#--addons-path=}")"
            else
                set -- "$@" "$arg"
            fi
            ;;
        *) set -- "$@" "$arg" ;;
    esac
done

# Pasar control al entrypoint oficial de Odoo con todos los argumentos
exec /entrypoint.sh "$@"
