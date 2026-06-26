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

# Pasar control al entrypoint oficial de Odoo con todos los argumentos
exec /entrypoint.sh "$@"
