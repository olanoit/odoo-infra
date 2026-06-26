#!/bin/sh
# =============================================================================
# EXTENDRIX — odoo-entrypoint.sh
# Wrapper del entrypoint de Odoo: instala requirements.txt de los módulos
# en shared-addons antes de pasar el control al entrypoint oficial.
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
            echo "[startup] addons-path: omito '${_sap_p}' (sin módulos; Odoo 14 lo rechazaría)" >&2
        fi
    done
    IFS="$_sap_oifs"
    printf '%s' "$_sap_out"
}

# Instalar dependencias Python de cualquier módulo en shared-addons que
# tenga requirements.txt (máx 2 niveles de profundidad)
find /mnt/shared-addons -maxdepth 2 -name requirements.txt 2>/dev/null | while read req; do
    echo "[startup] Instalando dependencias: $req"
    tmp_dir=$(mktemp -d)
    cp -r "$(dirname "$req")/." "$tmp_dir/"
    # Quitar el flag -e (editable): pip instalaría apuntando al tmp_dir que luego
    # se borra, dejando el import roto. Sin -e, pip copia los archivos a site-packages.
    sed 's/^-e //' "$tmp_dir/requirements.txt" > "$tmp_dir/requirements_fixed.txt"
    (cd "$tmp_dir" && pip install --quiet --no-warn-script-location --no-cache-dir --break-system-packages -r requirements_fixed.txt)
    rm -rf "$tmp_dir"
done

# ── Inyectar el master password (admin_passwd) en un config de runtime ────────
# Odoo NO acepta --admin-passwd por línea de comandos en todas las versiones
# (Odoo 14 falla con "no such option: --admin-passwd"), y el secreto no se
# versiona en el odoo.conf. Si ODOO_MASTER_PASSWD está definido, generamos un
# config efectivo en el data_dir (escribible) con admin_passwd inyectado, y
# reescribimos los argumentos para usarlo en lugar del odoo.conf montado :ro.
if [ -n "${ODOO_MASTER_PASSWD:-}" ]; then
    SRC_CONF=/etc/odoo/odoo.conf
    RT_CONF=/var/lib/odoo/.odoo-runtime.conf
    if [ -f "$SRC_CONF" ]; then
        # Copiar el conf quitando cualquier admin_passwd previo, y anexar el real.
        grep -v '^[[:space:]]*admin_passwd' "$SRC_CONF" > "$RT_CONF" 2>/dev/null || cp "$SRC_CONF" "$RT_CONF"
    else
        printf '[options]\n' > "$RT_CONF"
    fi
    printf 'admin_passwd = %s\n' "${ODOO_MASTER_PASSWD}" >> "$RT_CONF"

    # Sanear el addons_path del conf (descartar dirs vacíos para Odoo 14).
    if grep -q '^[[:space:]]*addons_path' "$RT_CONF"; then
        _ap_cur=$(grep -m1 '^[[:space:]]*addons_path' "$RT_CONF" | sed 's/^[[:space:]]*addons_path[[:space:]]*=[[:space:]]*//')
        _ap_san=$(_sanitize_addons_path "$_ap_cur")
        grep -v '^[[:space:]]*addons_path' "$RT_CONF" > "${RT_CONF}.tmp" && mv "${RT_CONF}.tmp" "$RT_CONF"
        printf 'addons_path = %s\n' "$_ap_san" >> "$RT_CONF"
    fi
    chmod 600 "$RT_CONF" 2>/dev/null || true

    # Reescribir argumentos: quitar --admin-passwd=* (no soportado en Odoo 14),
    # repuntar --config al config de runtime y sanear --addons-path=* (dirs vacíos).
    for arg do
        shift
        case "$arg" in
            --admin-passwd=*|--admin_passwd=*) continue ;;
            --config=*|-c=*) set -- "$@" "--config=$RT_CONF" ;;
            --addons-path=*) set -- "$@" "--addons-path=$(_sanitize_addons_path "${arg#--addons-path=}")" ;;
            *) set -- "$@" "$arg" ;;
        esac
    done
fi

# Pasar control al entrypoint oficial de Odoo con todos los argumentos
exec /entrypoint.sh "$@"
