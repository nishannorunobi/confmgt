#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# ansible_container_login.sh — a shell INSIDE confmgt's Ansible container, to look around (CONFMGT)
#
# What for    One command instead of remembering: docker exec -it confmgt-ansible bash. A container has no SSH and no
#             login prompt — this is the way in. Type exit to come back; the container keeps running.
# Steps       1. checks it runs (else: how to start it)
#             2. a short reminder, then the shell (bash)
# How         bash ~/myworkspace/projectspace/confmgt/ansible/ansible_container_login.sh
# Careful     the SSH key in /run/ansible-ssh opens the machines — look, do not copy it out.
# See also    the Ansible project inside: /ansible_project (read-only) · run by hand: ansible-playbook -i
#             /ansible_project/inventories/test /ansible_project/playbooks/ping.yml --private-key /run/ansible-ssh/id_ed25519
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in -h|--help) sed -n '3,/^# ─/{/^# ─/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;; esac
set -uo pipefail
# ── Mirror logging ─────────────────────────────────────────────────────────────
_WS_ROOT="$(d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ ! -d "$d/mountspace" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done; echo "$d")"
if [ -f "$_WS_ROOT/init/create_logging_path.sh" ]; then source "$_WS_ROOT/init/create_logging_path.sh"; setup_logging; fi
# ──────────────────────────────────────────────────────────────────────────────
ok()   { echo -e "\033[32m[  OK  ]\033[0m $*"; }
info() { echo -e "\033[36m[ INFO ]\033[0m $*"; }
die()  { echo -e "\033[31m[ERROR]\033[0m  $*"; exit 1; }
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/." && pwd)"
C=confmgt-ansible
docker info >/dev/null 2>&1 || die "Docker is not running (or this login is not in the docker group yet)"
[ -n "$(docker ps -q -f "name=^$C\$")" ] || die "$C is not running — start it: bash $PROJECT_DIR/ensure_running.sh"
{ : </dev/tty; } 2>/dev/null || die "this needs a terminal (run it yourself, not from another script)"
ok "entering $C (bash) — exit = back here, the container keeps running"
info "careful: /run/ansible-ssh holds the SSH key that opens the machines"
# The session itself is NOT mirror-logged: the log pipe is not a terminal (no prompt, no keys) and would record
# everything typed — the shell gets the real terminal back.
exec </dev/tty >/dev/tty 2>&1
exec docker exec -it "$C" bash
