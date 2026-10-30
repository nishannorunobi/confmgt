#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# wait_until_answering.sh — wait until the ansible-agent answers; if it cannot, say WHY (its last [agent] ERROR line)
#
# What for    "The container started" is not "Ansible is ready": the agent first needs kms (login, the SSH key's secret).
#             start.sh and host_start.sh call this, so they never say "up" while the agent is crashing.
#
# Who         start.sh · ansible-agent/host_start.sh — or you.
#
# How         bash ansible-agent/wait_until_answering.sh
#
# Steps       1. asks the agent's /health every second, up to WAIT_SECONDS (default 60)
#             2. answers → [  OK  ], exit 0
#             3. the container stopped or is restarting → its last [agent] ERROR line at once, exit 1
#                (compose keeps restarting it: once the reason is fixed, it comes up by itself)
#             4. still no answer after WAIT_SECONDS → the last [agent] line, exit 1
#
# Output      [  OK  ] ansible-agent answers on http://127.0.0.1:8897 (SSH key ready)
#             [ERROR]  the ansible-agent does not answer — why: kms's master_password is empty — put your kms password …
#
# Note        settings: dockerspace/.env AGENT_PORT · overrides (tests): ANSIBLE_AGENT_URL, CONFMGT_CONTAINER, WAIT_SECONDS
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in -h|--help) awk 'NR==1{next} /^# ─/{n++; if(n==2) exit; next} n==1{ sub(/^# ?/,""); if(!t){printf "\033[1m%s\033[0m\n",$0; t=1; next} l=substr($0,1,12); if(l ~ /^[A-Z][A-Za-z ]+$/){c=(l ~ /^Errors/)?"\033[33m":"\033[36m"; printf "%s%s\033[0m%s\n",c,l,substr($0,13)} else print }' "$0"; exit 0 ;; esac
set -uo pipefail
# ── Mirror logging ─────────────────────────────────────────────────────────────
_WS_ROOT="$(d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ ! -d "$d/mountspace" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done; echo "$d")"
if [ -f "$_WS_ROOT/ccc/scripts/lib/create_logging_path.sh" ]; then source "$_WS_ROOT/ccc/scripts/lib/create_logging_path.sh"; setup_logging; fi
# ──────────────────────────────────────────────────────────────────────────────
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="$(grep -E '^AGENT_PORT=' "$HERE/../dockerspace/.env" 2>/dev/null | cut -d= -f2)"
URL="${ANSIBLE_AGENT_URL:-http://127.0.0.1:${PORT:-8897}}"
C="${CONFMGT_CONTAINER:-confmgt-ansible}"
WAIT="${WAIT_SECONDS:-60}"; [[ "$WAIT" =~ ^[0-9]+$ ]] || WAIT=60
why() {   # the agent's last ERROR line (else its last line) — the reason, in its own words
    local l
    l="$(docker logs --tail 200 "$C" 2>&1 | grep '\[agent\] ERROR' | tail -1)"
    [ -n "$l" ] || l="$(docker logs --tail 200 "$C" 2>&1 | grep '\[agent\]' | tail -1)"
    printf '%s' "${l#\[agent\] }" | sed 's/^ERROR: //'
}
RC0="$(docker inspect -f '{{.RestartCount}}' "$C" 2>/dev/null)"        # restarts BEFORE this wait do not count
for _ in $(seq 1 "$WAIT"); do
    h="$(curl -fsS --max-time 2 "$URL/health" 2>/dev/null)"
    if [ -n "$h" ]; then
        grep -q '"ssh_key":true' <<< "$h" && k="SSH key ready" || k="SSH key MISSING"
        echo -e "\033[32m[  OK  ]\033[0m ansible-agent answers on $URL ($k)"; exit 0
    fi
    st="$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$C" 2>/dev/null)"
    case "$st" in
        "") echo -e "\033[31m[ERROR]\033[0m  the container $C does not exist — start it: bash $(dirname "$HERE")/start.sh"; exit 1 ;;
        exited*|dead*|restarting*|"running "*)
            [ "${st%% *}" = running ] && [ "${st#* }" = "${RC0:-0}" ] && { sleep 1; continue; }   # running, no new restart: wait on
            echo -e "\033[31m[ERROR]\033[0m  the ansible-agent does not answer — why: $(why)"
            echo "         it keeps retrying by itself; once the reason is fixed it comes up — see: docker logs $C"; exit 1 ;;
    esac
    sleep 1
done
echo -e "\033[31m[ERROR]\033[0m  the ansible-agent did not answer within ${WAIT} s — last: $(why)"; exit 1
