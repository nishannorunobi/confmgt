#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# start.sh — (Docker only) bring the confmgt-ansible container up: the shared network, then docker compose up
#
# What for    Layer 1 = Docker logic only. The project's own ../../start.sh (the one you run) checks kms first and
#             waits for the agent; this one only starts the container.
#
# Who         ../../start.sh — or you, when you only want Docker.
#
# How         bash dockerspace/host_scripts/start.sh            from the EXISTING image (built once, then offline)
#             bash dockerspace/host_scripts/start.sh --build    rebuild first (a version / requirements change)
#
# Steps       1. my_docker_network — created if missing (same name + subnet the workspace uses), so confmgt runs alone
#             2. docker compose up -d (dockerspace/docker-compose.yml)
#
# Output      Container confmgt-ansible  Started
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in -h|--help) awk 'NR==1{next} /^# ─/{n++; if(n==2) exit; next} n==1{ sub(/^# ?/,""); if(!t){printf "\033[1m%s\033[0m\n",$0; t=1; next} l=substr($0,1,12); if(l ~ /^[A-Z][A-Za-z ]+$/){c=(l ~ /^Errors/)?"\033[33m":"\033[36m"; printf "%s%s\033[0m%s\n",c,l,substr($0,13)} else print }' "$0"; exit 0 ;; esac
set -euo pipefail
# ── Mirror logging ─────────────────────────────────────────────────────────────
_WS_ROOT="$(d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ ! -d "$d/mountspace" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done; echo "$d")"
if [ -f "$_WS_ROOT/init/create_logging_path.sh" ]; then
    source "$_WS_ROOT/init/create_logging_path.sh"
    setup_logging
fi
# ──────────────────────────────────────────────────────────────────────────────
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"       # dockerspace/
docker network inspect my_docker_network >/dev/null 2>&1 \
    || docker network create --subnet=172.28.0.0/16 my_docker_network >/dev/null
if [ "${1:-}" = --build ]; then docker compose up -d --build; else docker compose up -d; fi
