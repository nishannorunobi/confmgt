#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# apply_playbook.sh — RUN a playbook for real: the machines are changed
#
# What for    Apply the configuration (ansible-playbook, run by the ansible-agent). Check first: check_playbook.sh.
#
# Who         You.
#
# How         bash apply_playbook.sh                       asks: playbook [ping] · inventory [test] · machines [all]
#             bash apply_playbook.sh ping test             the same without questions
#
# Output      changed: [test-vm] … · [  OK  ] apply ping on test: exit 0 after 2.3 s · full log: …/runs/…log
#
# Errors      no terminal and no names → only the plan is shown (exit 3): nothing is applied unseen
#             UNREACHABLE → the machine lacks the public key (bash show_public_key.sh) or is off
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
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_run_playbook.sh"
run_playbook apply "$@"
