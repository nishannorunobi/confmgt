#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy_on_this_pc.sh — Ansible deploys the workspace on THIS PC: playbook deploy, inventory dev (CONFMGT [6])
#
# What for    The last step of startup.sh (start-plan target deploy-dev): Ansible brings this PC to what
#             inventories/dev says. Each project joins in its own story ([6.3]…); until then it only checks the
#             workspace is there — git and Docker are left alone here (dev: ws_manage_git / ws_manage_docker false).
#
# Who         startup.sh (svcmgt/start_all.sh, target deploy-dev) · or you.
#
# How         bash deploy_on_this_pc.sh            (safe to run again — nothing new → changed=0)
#             bash deploy_on_this_pc.sh --state    one word for start_all: running (last deploy OK) · partial · stopped
#
# Steps       1. the ansible-agent answers (else confmgt's own start.sh)
#             2. Ansible may log in to this PC: its public key in ~/.ssh/authorized_keys (authorize_ansible_on_this_pc.sh
#                — only when missing, and it says so)
#             3. apply deploy on dev → the output, OK / FAILED, the full log · the result kept for --state
#
# Errors      UNREACHABLE → this PC's SSH server is off (port 22) · FAILED → the task named in the output says why
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in -h|--help) awk 'NR==1{next} /^# ─/{n++; if(n==2) exit; next} n==1{ sub(/^# ?/,""); if(!t){printf "\033[1m%s\033[0m\n",$0; t=1; next} l=substr($0,1,12); if(l ~ /^[A-Z][A-Za-z ]+$/){c=(l ~ /^Errors/)?"\033[33m":"\033[36m"; printf "%s%s\033[0m%s\n",c,l,substr($0,13)} else print }' "$0"; exit 0 ;; esac
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WS_ROOT="$(d="$HERE"; while [ ! -d "$d/mountspace" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done; echo "$d")"
STATE_FILE="${DEPLOY_STATE_FILE:-$_WS_ROOT/mountspace/data/myworkspace/projectspace/confmgt/ansible/deploy_on_this_pc.state}"
if [ "${1:-}" = --state ]; then                                   # start_all: the last deploy OK → running · failed → partial
    case "$(cat "$STATE_FILE" 2>/dev/null)" in ok*) echo running ;; failed*) echo partial ;; *) echo stopped ;; esac; exit 0
fi
# ── Mirror logging ─────────────────────────────────────────────────────────────
if [ -f "$_WS_ROOT/init/create_logging_path.sh" ]; then
    source "$_WS_ROOT/init/create_logging_path.sh"
    setup_logging --no-stamp                                      # the scripts it runs stamp their own lines
fi
# ──────────────────────────────────────────────────────────────────────────────
PORT="$(grep -E '^AGENT_PORT=' "$HERE/dockerspace/.env" 2>/dev/null | cut -d= -f2)"; URL="${ANSIBLE_AGENT_URL:-http://127.0.0.1:${PORT:-8897}}"
mkdir -p "$(dirname "$STATE_FILE")"
result() { echo "$1 $(date '+%Y-%m-%d %H:%M:%S')" > "$STATE_FILE"; }

# 1. the agent
if ! curl -fsS --max-time 5 "$URL/health" >/dev/null 2>&1; then
    echo -e "\033[36m[ INFO ]\033[0m the ansible-agent does not answer on $URL — starting confmgt"
    bash "$HERE/start.sh" || { result failed; echo -e "\033[31m[ERROR]\033[0m  confmgt did not start — see above"; exit 1; }
fi

# 2. Ansible may log in to this PC
bash "$HERE/authorize_ansible_on_this_pc.sh" | grep -v "next:" || { result failed; exit 1; }

# 3. deploy on dev
source "$HERE/dockerspace/host_scripts/lib_run_playbook.sh"
if run_playbook apply deploy dev; then result ok; else result failed; exit 1; fi
