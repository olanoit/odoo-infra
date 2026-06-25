#!/usr/bin/env bash
# =============================================================================
# OLANOIT — clean-logs.sh
# Vacía (trunca a 0 bytes) los archivos de log de Docker de un proyecto o de
# todos los proyectos Odoo. Los logs son los del driver json-file de cada
# contenedor (/var/lib/docker/.../<id>-json.log), que es de donde leen
# `docker logs` y `ops.sh logs`.
#
# Truncar (en vez de borrar) mantiene el contenedor escribiendo en el mismo
# archivo sin reiniciarlo — no hace falta `docker compose restart`.
#
# USO:
#   ./scripts/clean-logs.sh <contenedor>        # un proyecto
#   ./scripts/clean-logs.sh --all               # todos los proyectos Odoo
#   ./scripts/clean-logs.sh --all --infra       # + nginx, postgres, certbot
#   ./scripts/clean-logs.sh --all --dry-run     # solo muestra tamaños, no toca nada
#   ./scripts/clean-logs.sh --all --yes         # sin confirmación (para cron)
#
# NOTA: el log vive en /var/lib/docker (propiedad de root), por lo que el script
# usa `sudo` para truncarlo si no se ejecuta como root.
# =============================================================================

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()  { echo -e "${CYAN}  →${NC} $*"; }
title() { echo -e "\n${BOLD}══ $* ══${NC}\n"; }

command -v docker >/dev/null 2>&1 || error "docker no está disponible"

# ── Parseo de argumentos ─────────────────────────────────────────────────────
ALL=false; INFRA=false; DRY=false; YES=false; TARGET=""
for arg in "$@"; do
    case "$arg" in
        --all)      ALL=true ;;
        --infra)    INFRA=true ;;
        --dry-run)  DRY=true ;;
        --yes|-y)   YES=true ;;
        --help|-h)
            sed -n '2,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
            exit 0 ;;
        --*)        error "Opción desconocida: $arg" ;;
        *)
            [[ -n "$TARGET" ]] && error "Solo se admite un contenedor. Para varios usá --all."
            TARGET="$arg" ;;
    esac
done

$ALL || [[ -n "$TARGET" ]] || error "Indicá un <contenedor> o usá --all. Ver: $0 --help"
$ALL && [[ -n "$TARGET" ]] && error "Usá un <contenedor> O --all, no ambos."

# sudo solo si no somos root (el LogPath está bajo /var/lib/docker, propiedad de root)
SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

# ── Helpers ──────────────────────────────────────────────────────────────────
human() { # bytes → humano
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB",u," "); i=1;
        while (b>=1024 && i<5){ b/=1024; i++ }
        printf((b==int(b))?"%d %s":"%.1f %s", b, u[i])
    }'
}

logpath_of() { docker inspect --format='{{.LogPath}}' "$1" 2>/dev/null || true; }
size_of()    { $SUDO stat -c%s "$1" 2>/dev/null || echo 0; }

TOTAL_FREED=0
clean_one() {
    local name="$1"
    local lp; lp="$(logpath_of "$name")"
    if [[ -z "$lp" ]]; then
        warn "$name: no existe o no tiene log — omitido."
        return
    fi
    if ! $SUDO test -f "$lp" 2>/dev/null; then
        warn "$name: archivo de log no encontrado ($lp) — omitido."
        return
    fi
    local sz; sz="$(size_of "$lp")"
    printf "  %-34s %10s" "$name" "$(human "$sz")"
    if $DRY; then
        echo -e "   ${YELLOW}(dry-run)${NC}"
        TOTAL_FREED=$((TOTAL_FREED + sz))
        return
    fi
    if $SUDO truncate -s 0 "$lp" 2>/dev/null; then
        echo -e "   ${GREEN}→ vaciado${NC}"
        TOTAL_FREED=$((TOTAL_FREED + sz))
    else
        echo -e "   ${RED}→ error (¿permisos? probá con sudo)${NC}"
    fi
}

# ── Construir la lista de contenedores objetivo ──────────────────────────────
declare -a TARGETS=()
if $ALL; then
    while IFS= read -r name; do
        [[ -n "$name" ]] && TARGETS+=("$name")
    done < <(docker compose ps -a --format '{{.Name}}' 2>/dev/null | grep -E '^odoo[0-9]' || true)

    if $INFRA; then
        for svc in odoo_postgres odoo_nginx odoo_certbot; do
            docker inspect "$svc" >/dev/null 2>&1 && TARGETS+=("$svc")
        done
    fi

    [[ ${#TARGETS[@]} -eq 0 ]] && error "No se encontraron contenedores de proyecto (odoo*) en este compose."
else
    TARGETS+=("$TARGET")
fi

# ── Ejecutar ─────────────────────────────────────────────────────────────────
title "Limpieza de logs Docker$($DRY && echo ' (dry-run)')"
echo "  Contenedores objetivo: ${#TARGETS[@]}"
$INFRA && echo "  Incluye infraestructura (nginx/postgres/certbot)"
echo ""

if ! $DRY && ! $YES; then
    warn "Se vaciarán los logs de: ${TARGETS[*]}"
    read -rp "¿Confirmar? (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && { warn "Cancelado."; exit 0; }
    echo ""
fi

for c in "${TARGETS[@]}"; do
    clean_one "$c"
done

echo ""
if $DRY; then
    info "Total que se liberaría: $(human "$TOTAL_FREED") (dry-run — no se modificó nada)."
else
    info "Total liberado: $(human "$TOTAL_FREED")."
fi
