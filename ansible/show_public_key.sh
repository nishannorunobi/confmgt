#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# show_public_key.sh — Ansible's PUBLIC SSH key (safe to show) and how to put it on a machine
#
# What for    A machine lets Ansible in only when this key is in its ~/.ssh/authorized_keys. The private key never
#             leaves the container's RAM; it is made from ANSIBLE_SSH_KEY_SECRET in kms.
#
# Who         You — once per machine, and again after the secret changed in kms.
#
# How         bash show_public_key.sh
#
# Output      ssh-ed25519 AAAA… confmgt-ansible
#             + the one command to add it on the machine (for the test VM: from the PC, via test_server)
#
# Errors      the agent does not answer → bash start.sh
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in -h|--help) awk 'NR==1{next} /^# ─/{n++; if(n==2) exit; next} n==1{ sub(/^# ?/,""); if(!t){printf "\033[1m%s\033[0m\n",$0; t=1; next} l=substr($0,1,12); if(l ~ /^[A-Z][A-Za-z ]+$/){c=(l ~ /^Errors/)?"\033[33m":"\033[36m"; printf "%s%s\033[0m%s\n",c,l,substr($0,13)} else print }' "$0"; exit 0 ;; esac
set -uo pipefail
# ── Mirror logging ─────────────────────────────────────────────────────────────
_WS_ROOT="$(d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ ! -d "$d/mountspace" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done; echo "$d")"
if [ -f "$_WS_ROOT/ccc/scripts/lib/create_logging_path.sh" ]; then
    source "$_WS_ROOT/ccc/scripts/lib/create_logging_path.sh"
    setup_logging
fi
# ──────────────────────────────────────────────────────────────────────────────
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="$(grep -E '^AGENT_PORT=' "$HERE/dockerspace/.env" 2>/dev/null | cut -d= -f2)"; URL="${ANSIBLE_AGENT_URL:-http://127.0.0.1:${PORT:-8897}}"
KEY="$(curl -fsS --max-time 5 "$URL/public-key" 2>/dev/null)" \
    || { echo -e "\033[31m[ERROR]\033[0m  the ansible-agent does not answer on $URL — start it: bash $HERE/start.sh"; exit 1; }
echo -e "\033[1m==> Ansible's public key\033[0m"
echo "$KEY"
echo ""
echo -e "\033[1m==> Put it on a machine\033[0m (once; it is added only when not there yet)"
echo "    on the machine itself:"
echo "      grep -qxF '$KEY' ~/.ssh/authorized_keys 2>/dev/null || echo '$KEY' >> ~/.ssh/authorized_keys"
echo "    the test VM, from this PC:"
echo "      ssh -p 2222 nishan@127.0.0.1 \"grep -qxF '$KEY' ~/.ssh/authorized_keys || echo '$KEY' >> ~/.ssh/authorized_keys\""
