#!/bin/sh
# =============================================================================
# EXTENDRIX — odoo-entrypoint.sh
# Wrapper del entrypoint de Odoo: instala requirements.txt de los módulos
# en shared-addons antes de pasar el control al entrypoint oficial.
# =============================================================================
set -e

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
    chmod 600 "$RT_CONF" 2>/dev/null || true

    # Reescribir argumentos: quitar --admin-passwd=* (no soportado en Odoo 14) y
    # repuntar --config al config de runtime con el admin_passwd inyectado.
    for arg do
        shift
        case "$arg" in
            --admin-passwd=*|--admin_passwd=*) continue ;;
            --config=*|-c=*) set -- "$@" "--config=$RT_CONF" ;;
            *) set -- "$@" "$arg" ;;
        esac
    done
fi

# Pasar control al entrypoint oficial de Odoo con todos los argumentos
exec /entrypoint.sh "$@"
