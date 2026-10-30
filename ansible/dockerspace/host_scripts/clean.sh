#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# clean.sh — ⚠ stop confmgt's Ansible container AND delete its data volume (full reset)
#
# What for    Start over: known_hosts (the machines Ansible trusts) is forgotten. The image is kept (offline).
#
# Who         You only, on purpose.
#
# How         bash dockerspace/host_scripts/clean.sh
#
# Steps       1. asks you to confirm
#             2. docker compose down -v — container + data volume removed
#
# Note        The SSH key's secret in kms and the Ansible project (ansible_project/) are not touched.
#
# Next        bash start.sh   (in confmgt/ansible)
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in -h|--help) awk 'NR==1{next} /^# ─/{n++; if(n==2) exit; next} n==1{ sub(/^# ?/,""); if(!t){printf "\033[1m%s\033[0m\n",$0; t=1; next} l=substr($0,1,12); if(l ~ /^[A-Z][A-Za-z ]+$/){c=(l ~ /^Errors/)?"\033[33m":"\033[36m"; printf "%s%s\033[0m%s\n",c,l,substr($0,13)} else print }' "$0"; exit 0 ;; esac

set -euo pipefail

# ── Mirror logging ─────────────────────────────────────────────────────────────
_WS_ROOT="$(d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ ! -d "$d/mountspace" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done; echo "$d")"
if [ -f "$_WS_ROOT/ccc/scripts/lib/create_logging_path.sh" ]; then
    source "$_WS_ROOT/ccc/scripts/lib/create_logging_path.sh"
    setup_logging
fi
# ──────────────────────────────────────────────────────────────────────────────

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"       # dockerspace/

RED="\033[31m"; YELLOW="\033[33m"; BOLD="\033[1m"; RESET="\033[0m"

echo -e "${RED}${BOLD}WARNING: This forgets every machine Ansible trusts (known_hosts).${RESET}"
read -r -p "Type 'yes' to confirm: " confirm

if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo -e "${YELLOW}==> Stopping and removing the Ansible container + its volume...${RESET}"
docker compose down -v --remove-orphans
echo -e "${RED}    known_hosts deleted.${RESET}"
echo -e "    Run ${BOLD}bash start.sh${RESET} (in confmgt/ansible) to start fresh."
