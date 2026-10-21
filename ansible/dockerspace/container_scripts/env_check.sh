#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# env_check.sh — runs INSIDE confmgt-ansible: is everything Ansible needs there?
#
# What for    After logging in (host_scripts/confmgt_ansible_container_login.sh) — one command that says what works.
#
# Who         You, inside the container.
#
# How         bash /container_scripts/env_check.sh
#
# Checks      ansible-playbook present (its version) · the SSH key in RAM (/run/ansible-ssh, 600) · the Ansible project
#             mounted READ-ONLY (/ansible_project) · its playbooks + inventories · the agent answers (:8897) ·
#             known_hosts folder writable (/data)
#
# Output      [  OK  ] ansible-playbook [core 2.21.5] … then one line per check · exit 0 = all fine, 1 = something is wrong
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in -h|--help) awk 'NR==1{next} /^# ─/{n++; if(n==2) exit; next} n==1{ sub(/^# ?/,""); if(!t){printf "\033[1m%s\033[0m\n",$0; t=1; next} l=substr($0,1,12); if(l ~ /^[A-Z][A-Za-z ]+$/){c=(l ~ /^Errors/)?"\033[33m":"\033[36m"; printf "%s%s\033[0m%s\n",c,l,substr($0,13)} else print }' "$0"; exit 0 ;; esac
set -uo pipefail
F=0
ok()  { echo -e "\033[32m[  OK  ]\033[0m $*"; }
bad() { echo -e "\033[31m[ERROR]\033[0m  $*"; F=1; }
P="${ANSIBLE_PROJECT_DIR:-/ansible_project}"; K="${ANSIBLE_SSH_DIR:-/run/ansible-ssh}"
v="$(ansible-playbook --version 2>/dev/null | head -1)"; [ -n "$v" ] && ok "$v" || bad "ansible-playbook not found"
[ -f "$K/id_ed25519" ] && [ "$(stat -c %a "$K/id_ed25519")" = 600 ] && ok "SSH key in RAM ($K, 600)" || bad "no SSH key in $K — docker logs confmgt-ansible says why"
[ -d "$P" ] && ! touch "$P/.w" 2>/dev/null && ok "Ansible project mounted read-only ($P)" || { rm -f "$P/.w" 2>/dev/null; bad "$P missing or writable"; }
n="$(ls "$P"/playbooks/*.y*ml 2>/dev/null | wc -l)"; i="$(ls -d "$P"/inventories/*/ 2>/dev/null | wc -l)"
[ "$n" -gt 0 ] && ok "$n playbook(s) · $i inventory folder(s)" || bad "no playbooks in $P/playbooks"
wget -q -O /dev/null "http://127.0.0.1:${PORT:-8897}/health" 2>/dev/null && ok "the agent answers on :${PORT:-8897}" || bad "the agent does not answer on :${PORT:-8897}"
[ -w "${ANSIBLE_DATA_DIR:-/data}" ] && ok "known_hosts folder writable (${ANSIBLE_DATA_DIR:-/data})" || bad "${ANSIBLE_DATA_DIR:-/data} not writable"
exit $F
