#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# stop_on_this_pc.sh — Ansible takes the workspace's projects DOWN on THIS PC: playbook stop, inventory dev (CONFMGT [6.14])
#
# What for    The first step of ccc/shutdown.sh (stop-plan target deploy-dev): the projects Ansible started go down in
#             reverse start order. Whatever is still running after it, stop_all stops itself with its own script.
#
# Who         ccc/shutdown.sh (ccc/scripts/svcmgt/stop_all.sh, target deploy-dev) · or you.
#
# How         bash stop_on_this_pc.sh            (safe to run again — all down → changed=0)
#
# Steps       1. the ansible-agent answers (else: nothing done, exit 1 — a shutdown never STARTS confmgt; stop_all
#                then stops the projects itself)
#             2. apply stop on dev → the output, OK / FAILED, the full log · the result kept for deploy_on_this_pc.sh --state
#
# Errors      the agent is down → stop_all's fallback stops each project with its own stop script
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in -h|--help) awk 'NR==1{next} /^# ─/{n++; if(n==2) exit; next} n==1{ sub(/^# ?/,""); if(!t){printf "\033[1m%s\033[0m\n",$0; t=1; next} l=substr($0,1,12); if(l ~ /^[A-Z][A-Za-z ]+$/){c=(l ~ /^Errors/)?"\033[33m":"\033[36m"; printf "%s%s\033[0m%s\n",c,l,substr($0,13)} else print }' "$0"; exit 0 ;; esac
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WS_ROOT="$(d="$HERE"; while [ ! -d "$d/mountspace" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done; echo "$d")"
STATE_FILE="${DEPLOY_STATE_FILE:-$_WS_ROOT/mountspace/data/myworkspace/ccc/infra/ansible/deploy_on_this_pc.state}"
# ── Mirror logging ─────────────────────────────────────────────────────────────
if [ -f "$_WS_ROOT/ccc/scripts/lib/create_logging_path.sh" ]; then
    source "$_WS_ROOT/ccc/scripts/lib/create_logging_path.sh"
    setup_logging --no-stamp                                      # the scripts it runs stamp their own lines
fi
# ──────────────────────────────────────────────────────────────────────────────
CCC="$(cd "$HERE/../.." && pwd)"                                   # ccc/ — the CCC's container + agent (CLAUDEWORK-270)
export CCC_CALLER="${CCC_CALLER:-svcmgt}"                          # svcmgt's deploy-dev / shutdown = the known caller svcmgt
PORT="$(grep -E '^AGENT_PORT=' "$CCC/container/.env" 2>/dev/null | cut -d= -f2)"; URL="${ANSIBLE_AGENT_URL:-http://127.0.0.1:${PORT:-8897}}"
mkdir -p "$(dirname "$STATE_FILE")"
result() { echo "$1 $(date '+%Y-%m-%d %H:%M:%S')" > "$STATE_FILE"; }

# 1. the agent — never started here
if ! curl -fsS --max-time 5 "$URL/health" >/dev/null 2>&1; then
    result failed-stop
    echo -e "\033[33m[ WARN ]\033[0m the CCC agent does not answer on $URL — nothing stopped by Ansible; stop_all stops the projects itself"
    exit 1
fi

# 2. stop on dev
source "$HERE/lib_run_playbook.sh"
if run_playbook apply stop dev; then result stopped; else result failed-stop; exit 1; fi
