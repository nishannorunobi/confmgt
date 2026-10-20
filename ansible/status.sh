#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# status.sh — show confmgt's Ansible container and what its agent says (human view)
#
# What for    See whether it runs, its port, the Ansible version and whether the SSH key is ready.
#
# Who         You.
#
# How         bash status.sh
#
# Output      NAME              STATUS                 PORTS
#             confmgt-ansible   Up 2 hours (healthy)   127.0.0.1:8897->8897/tcp
#             agent: ok · ansible [core 2.21.5] · SSH key ready · no run going on
#
# Next        For scripts: bash state.sh (one word)
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in -h|--help) awk 'NR==1{next} /^# ─/{n++; if(n==2) exit; next} n==1{ sub(/^# ?/,""); if(!t){printf "\033[1m%s\033[0m\n",$0; t=1; next} l=substr($0,1,12); if(l ~ /^[A-Z][A-Za-z ]+$/){c=(l ~ /^Errors/)?"\033[33m":"\033[36m"; printf "%s%s\033[0m%s\n",c,l,substr($0,13)} else print }' "$0"; exit 0 ;; esac

# ── Mirror logging ─────────────────────────────────────────────────────────────
_WS_ROOT="$(d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ ! -d "$d/mountspace" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done; echo "$d")"
if [ -f "$_WS_ROOT/init/create_logging_path.sh" ]; then
    source "$_WS_ROOT/init/create_logging_path.sh"
    setup_logging
fi
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BOLD="\033[1m"; RESET="\033[0m"
PORT="$(grep -E '^AGENT_PORT=' .env | cut -d= -f2)"; PORT="${PORT:-8897}"

echo -e "${BOLD}==> Ansible (confmgt) container status${RESET}"
docker compose ps
curl -fsS --max-time 5 "http://127.0.0.1:$PORT/health" 2>/dev/null | python3 -c '
import json, sys
h = json.load(sys.stdin)
print(f"agent: {h[\"status\"]} · {h[\"ansible\"]} · SSH key {\"ready\" if h[\"ssh_key\"] else \"MISSING\"} · "
      f"{\"a run is going on\" if h[\"running\"] else \"no run going on\"}")' || echo "agent: not answering on :$PORT"
