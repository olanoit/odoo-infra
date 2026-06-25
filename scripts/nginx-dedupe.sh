#!/usr/bin/env bash
# =============================================================================
# OLANOIT — nginx-dedupe.sh
#
# Limpia bloques duplicados en nginx/conf.d/*.conf que pueden quedar tras
# correr sync-projects.sh varias veces (por ejemplo, después de un reset
# del docker-compose.yml seguido de re-inserción de proyectos).
#
# Deduplica:
#   • Bloques `upstream <nombre> { ... }` en 00-upstreams.conf
#   • Bloques `server { ... }` en vhosts-projects.conf (por listen + server_name)
#
# Crea .bak por cada archivo antes de modificar. Idempotente.
#
# USO:
#   ./scripts/nginx-dedupe.sh           # aplica
#   ./scripts/nginx-dedupe.sh --dry-run # solo muestra qué removería
# =============================================================================

set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()  { echo -e "${CYAN}  →${NC} $*"; }
title() { echo -e "\n${BLUE}${BOLD}══ $* ══${NC}\n"; }

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) error "Opción desconocida: $arg" ;;
    esac
done

UPSTREAMS="nginx/conf.d/00-upstreams.conf"
VHOSTS="nginx/conf.d/vhosts-projects.conf"

title "Dedupe nginx confs"

if $DRY_RUN; then
    warn "DRY-RUN — solo muestra qué removería, no escribe nada."
fi

# ── Dedupe upstreams ─────────────────────────────────────────────────────────
if [[ -f "$UPSTREAMS" ]]; then
    step "Inspeccionando $UPSTREAMS..."
    DRY_RUN="$DRY_RUN" UPSTREAMS="$UPSTREAMS" python3 - <<'PYEOF'
import os, re, pathlib
p = pathlib.Path(os.environ["UPSTREAMS"])
dry = os.environ["DRY_RUN"] == "true"
txt = p.read_text()
seen = set(); removed = []
def kf(m):
    name = m.group(1)
    if name in seen:
        removed.append(name)
        return ""
    seen.add(name)
    return m.group(0)
out = re.sub(r"upstream (\S+)\s*\{[^}]*\}\s*", kf, txt)
out = re.sub(r"\n{3,}", "\n\n", out)
if removed:
    print(f"  Duplicados a remover ({len(removed)}): " + ", ".join(removed))
    if not dry:
        p.with_suffix(".conf.bak").write_text(txt)
        p.write_text(out)
        print(f"  → Escrito. Backup en {p.with_suffix('.conf.bak')}")
else:
    print("  Sin duplicados.")
PYEOF
else
    warn "$UPSTREAMS no existe, saltando."
fi

# ── Dedupe vhosts ────────────────────────────────────────────────────────────
if [[ -f "$VHOSTS" ]]; then
    step "Inspeccionando $VHOSTS..."
    DRY_RUN="$DRY_RUN" VHOSTS="$VHOSTS" python3 - <<'PYEOF'
import os, re, pathlib
p = pathlib.Path(os.environ["VHOSTS"])
dry = os.environ["DRY_RUN"] == "true"
txt = p.read_text()
seen = set(); removed = []
def kf(m):
    block = m.group(0)
    sn = re.search(r"server_name\s+([^\s;]+)", block)
    li = re.search(r"listen\s+([^;]+)", block)
    key = ((sn.group(1) if sn else "?"), (li.group(1).strip() if li else "?"))
    if key in seen:
        removed.append(f"{key[0]}:{key[1]}")
        return ""
    seen.add(key)
    return block
out = re.sub(r"server\s*\{(?:[^{}]|\{[^{}]*\})*\}", kf, txt, flags=re.DOTALL)
out = re.sub(r"\n{3,}", "\n\n", out)
if removed:
    print(f"  Duplicados a remover ({len(removed)}):")
    for r in removed:
        print(f"    - {r}")
    if not dry:
        p.with_suffix(".conf.bak").write_text(txt)
        p.write_text(out)
        print(f"  → Escrito. Backup en {p.with_suffix('.conf.bak')}")
else:
    print("  Sin duplicados.")
PYEOF
else
    warn "$VHOSTS no existe, saltando."
fi

echo ""
if $DRY_RUN; then
    info "Dry-run terminado. Ejecutá sin --dry-run para aplicar."
else
    info "Dedupe terminado. Recargá nginx: ./scripts/ops.sh nginx-reload"
fi
