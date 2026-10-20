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
#             (agent down: "agent: not answering on … — last error: <the agent's own reason>")
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
URL="${ANSIBLE_AGENT_URL:-http://127.0.0.1:$PORT}"; C="${CONFMGT_CONTAINER:-confmgt-ansible}"   # overrides: tests

echo -e "${BOLD}==> Ansible (confmgt) container status${RESET}"
docker compose ps
H="$(curl -fsS --max-time 5 "$URL/health" 2>/dev/null)"      # read first: no answer → one plain line, never a traceback
if [ -n "$H" ]; then
    printf '%s' "$H" | python3 -c '
import json, sys
h = json.load(sys.stdin)
key = "ready" if h["ssh_key"] else "MISSING"
run = "a run is going on" if h["running"] else "no run going on"
print("agent: %s · %s · SSH key %s · %s" % (h["status"], h["ansible"], key, run))'
else
    why="$(docker logs --tail 200 "$C" 2>&1 | grep '\[agent\] ERROR' | tail -1 | sed 's/^\[agent\] ERROR: //')"
    echo "agent: not answering on $URL${why:+ — last error: $why}"
fi
