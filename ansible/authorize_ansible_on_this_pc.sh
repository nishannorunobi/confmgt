#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# authorize_ansible_on_this_pc.sh — let Ansible (confmgt) log in to THIS PC: its public key → ~/.ssh/authorized_keys
#
# What for    Ansible configures this PC over SSH (inventory dev). It may log in only when its public key is in your
#             ~/.ssh/authorized_keys. One command instead of copy-pasting the key.
#
# Who         You, once per machine — and again after ANSIBLE_SSH_KEY_SECRET changed in kms (a new key).
#
# How         bash authorize_ansible_on_this_pc.sh
#
# Steps       1. asks the running ansible-agent for the public key (the private key never leaves its RAM)
#             2. ~/.ssh (700) and authorized_keys (600) — created if missing
#             3. the key is added only when it is not there yet (safe to run again)
#
# Output      [  OK  ] Ansible's key added to /home/nishan/.ssh/authorized_keys   (or: already there)
#
# Errors      the agent does not answer → bash start.sh
#
# Next        bash check_playbook.sh  → mycache · dev  (dry run: changed=0)
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
AK="${AUTHORIZED_KEYS_FILE:-$HOME/.ssh/authorized_keys}"                    # tests point elsewhere
KEY="$(curl -fsS --max-time 5 "$URL/public-key" 2>/dev/null | head -1)"
[[ "$KEY" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+\ confmgt-ansible$ ]] \
    || { echo -e "\033[31m[ERROR]\033[0m  the ansible-agent does not answer on $URL — start it: bash $HERE/start.sh"; exit 1; }
mkdir -p "$(dirname "$AK")" && chmod 700 "$(dirname "$AK")"
touch "$AK" && chmod 600 "$AK"
if grep -qxF -- "$KEY" "$AK"; then
    echo -e "\033[32m[  OK  ]\033[0m Ansible's key is already in $AK"
else
    printf '%s\n' "$KEY" >> "$AK"
    echo -e "\033[32m[  OK  ]\033[0m Ansible's key added to $AK"
fi
echo "         next: bash $HERE/check_playbook.sh   → playbook mycache · inventory dev (dry run)"
