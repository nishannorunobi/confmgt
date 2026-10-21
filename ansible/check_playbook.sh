#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# check_playbook.sh — DRY RUN a playbook: what WOULD change on the machines (nothing is changed)
#
# What for    See the differences before applying (ansible-playbook --check --diff, run by the ansible-agent).
#
# Who         You.
#
# How         bash check_playbook.sh                       asks: playbook [ping] · inventory [dev] · machines [all]
#             bash check_playbook.sh mycache dev             the same without questions
#
# Output      ok: [dev-pc] … changed=0 · [  OK  ] check mycache on dev: exit 0 after 2.1 s · full log: …/runs/…log
#
# Errors      the agent does not answer → bash start.sh · UNREACHABLE → the machine lacks the public key
#             (bash show_public_key.sh) or is off
#
# Next        bash apply_playbook.sh
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in -h|--help) awk 'NR==1{next} /^# ─/{n++; if(n==2) exit; next} n==1{ sub(/^# ?/,""); if(!t){printf "\033[1m%s\033[0m\n",$0; t=1; next} l=substr($0,1,12); if(l ~ /^[A-Z][A-Za-z ]+$/){c=(l ~ /^Errors/)?"\033[33m":"\033[36m"; printf "%s%s\033[0m%s\n",c,l,substr($0,13)} else print }' "$0"; exit 0 ;; esac
set -uo pipefail
# ── Mirror logging ─────────────────────────────────────────────────────────────
_WS_ROOT="$(d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ ! -d "$d/mountspace" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done; echo "$d")"
if [ -f "$_WS_ROOT/init/create_logging_path.sh" ]; then
    source "$_WS_ROOT/init/create_logging_path.sh"
    setup_logging
fi
# ──────────────────────────────────────────────────────────────────────────────
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dockerspace/host_scripts/lib_run_playbook.sh"
run_playbook check "$@"
