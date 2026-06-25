#!/usr/bin/env bash
# =============================================================================
# OLANOIT — backup-cron.sh
# Backup automático no interactivo de TODAS las bases de datos + retención.
# Pensado para ejecutarse desde cron (ver más abajo).
#
# Hace:
#   1. ops.sh backup-all  → DB dumps + filestore en ./backups/<proyecto>/
#   2. Borra los backups (.sql.gz / .tar.gz) más viejos que RETENTION_DAYS.
#   3. Registra todo en ./backups/_cron/backup-<fecha>.log
#
# USO MANUAL:
#   ./scripts/backup-cron.sh
#
# VARIABLES (opcionales, exportar antes o editar acá):
#   RETENTION_DAYS   Días a conservar (default: 14). 0 = no borrar nada.
#
# INSTALAR EN CRON (todos los días a las 02:30):
#   crontab -e
#   30 2 * * *  /ruta/al/repo/scripts/backup-cron.sh >/dev/null 2>&1
#
# Sugerencia: copiar los backups a almacenamiento externo (S3, rsync a otro
# host, etc.) DESPUÉS de este paso — un backup en el mismo disco no protege
# ante fallo del disco. Ver docs/05-backups.md.
# =============================================================================

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

RETENTION_DAYS="${RETENTION_DAYS:-14}"
BACKUPS_DIR="$PROJECT_DIR/backups"
LOG_DIR="$BACKUPS_DIR/_cron"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup-$(date +%Y%m%d_%H%M%S).log"

# Redirigir toda la salida (stdout + stderr) al log y a la consola.
exec > >(tee -a "$LOG_FILE") 2>&1

echo "═══════════════════════════════════════════════════════════════"
echo "OLANOIT backup-cron — $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Repo            : $PROJECT_DIR"
echo "  Retención (días): $RETENTION_DAYS"
echo "═══════════════════════════════════════════════════════════════"

# ─── 1. Backup de todas las bases ────────────────────────────────────────────
echo "[1/2] Ejecutando ops.sh backup-all..."
if ./scripts/ops.sh backup-all; then
    echo "[✓] backup-all completado."
else
    echo "[✗] backup-all falló (código $?). Revisa el log: $LOG_FILE"
    exit 1
fi

# ─── 2. Retención ────────────────────────────────────────────────────────────
if [[ "$RETENTION_DAYS" -gt 0 ]]; then
    echo "[2/2] Aplicando retención: borrando backups con más de ${RETENTION_DAYS} días..."
    deleted=0
    while IFS= read -r f; do
        echo "    borrando: ${f#$BACKUPS_DIR/}"
        rm -f "$f"
        deleted=$((deleted + 1))
    done < <(find "$BACKUPS_DIR" -type f \( -name '*.sql.gz' -o -name '*_filestore.tar.gz' \) \
                 -mtime +"$RETENTION_DAYS" 2>/dev/null)
    echo "[✓] Retención aplicada: ${deleted} archivo(s) borrado(s)."
else
    echo "[2/2] RETENTION_DAYS=0 → no se borra ningún backup."
fi

# ─── Retención de los propios logs de cron (mantener ~60 días) ───────────────
find "$LOG_DIR" -type f -name 'backup-*.log' -mtime +60 -delete 2>/dev/null || true

echo "─────────────────────────────────────────────────────────────"
echo "Backup-cron finalizado — $(date '+%Y-%m-%d %H:%M:%S')"
echo "Tamaño total del volumen de backups: $(du -sh "$BACKUPS_DIR" 2>/dev/null | cut -f1)"
