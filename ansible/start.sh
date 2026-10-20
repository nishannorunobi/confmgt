#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# start.sh — start confmgt's Ansible container (the ansible-agent is its entry point, API on :8897)
#
# What for    Start Ansible's container. The ansible-agent is the entry point: it gets the SSH key's secret from kms
#             (ansible-agent/agent.conf = kms address), makes the key in RAM and serves its API on :8897.
#             Ansible itself runs only when asked (check_playbook.sh · apply_playbook.sh).
#
# Who         You, or the workspace startup (via ensure_running.sh).
#
# How         bash start.sh
#
# Steps       1. first time only: the ansible-agent signs itself up with kms as it starts (your kms password from
#                kms's master_password, .env KMS_MASTER_PASSWORD_DIR) — file empty → asks here, by hand only
#             2. docker compose up -d — builds the image once (internet once), then:
#                inside: ansible-agent/supervisor.py → kms → the SSH key in RAM → the agent API
#             3. waits until the agent answers (ansible-agent/wait_until_answering.sh) — else its reason, exit 1
#
# Output      [  OK  ] ansible-agent answers on http://127.0.0.1:8897 (SSH key ready)
#             ==> Ansible (confmgt) is up
#                 Agent     : http://127.0.0.1:8897
#
# Errors      kms is SEALED          → unseal kms — the container retries by itself
#                                     (see why: docker logs confmgt-ansible)
#             not signed up, master_password empty → put your kms password there, or run bash start.sh by hand once
#
# Next        bash show_public_key.sh (put the key on the machines) · bash check_playbook.sh · bash status.sh
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
GREEN="\033[32m"; BOLD="\033[1m"; RESET="\033[0m"
[ -f ".env" ] || { echo -e "\033[31m[ERROR]${RESET} .env not found."; exit 1; }
source .env      # image versions, port — no secret
# The ansible-agent fetches its secret inside the container (its connect_external/kms/) — and signs itself up with kms
# when it has no login yet: with the owner's kms password from kms's master_password folder (.env
# KMS_MASTER_PASSWORD_DIR), mounted read-only. Before the start, this script only checks that the agent CAN sign up —
# else the container would stop and be restarted again and again. Started by hand in a terminal with the file
# empty → it signs up here and asks your kms password.
MASTER_PW_DIR="${KMS_MASTER_PASSWORD_DIR:-}"
[ -n "$MASTER_PW_DIR" ] && [ "${MASTER_PW_DIR#/}" = "$MASTER_PW_DIR" ] && MASTER_PW_DIR="$SCRIPT_DIR/$MASTER_PW_DIR"
MASTER_PW="$MASTER_PW_DIR/master_password"
_SM="$(sed -nE 's/^SECRET_MGT[[:space:]]*=[[:space:]]*//p' ansible-agent/agent.conf 2>/dev/null | tail -1 | tr -d "\"'\r" | tr 'A-Z' 'a-z' | xargs)"
if [ "$_SM" = kms ] && ! ls ansible-agent/connect_external/kms/credentials/*/secret_id >/dev/null 2>&1; then   # SECRET_MGT=local (or not set): no kms
    if [ -n "$MASTER_PW_DIR" ] && [ -s "$MASTER_PW" ] && grep -q '[^[:space:]]' "$MASTER_PW" 2>/dev/null; then
        echo -e "\033[36m[ INFO ]${RESET} the ansible-agent has no kms login yet — it signs itself up as it starts (kms's master_password is filled)"
    elif [ -z "${SVC_RUN:-}" ] && [ -t 0 ]; then
        bash ansible-agent/connect_external/kms/signup_with_kms.sh || exit 1
    else
        echo -e "\033[31m[ERROR]${RESET} the ansible-agent is not signed up with kms yet — put your kms password into $MASTER_PW (kms's master_password), then start again — or once by hand: bash $SCRIPT_DIR/start.sh"; exit 1
    fi
fi
# the container mounts kms's master_password folder: it must exist (empty is fine)
[ -n "$MASTER_PW_DIR" ] && mkdir -p "$MASTER_PW_DIR" 2>/dev/null || true

echo -e "${BOLD}==> Starting Ansible ${ANSIBLE_CORE_VERSION} (confmgt)...${RESET}"
docker compose up -d
# "started" is not "ready": the agent first needs kms — wait for its answer, else say why (CONFMGT-13)
bash ansible-agent/wait_until_answering.sh || exit 1

echo ""
echo -e "${GREEN}${BOLD}==> Ansible (confmgt) is up${RESET}"
KMS_ENTRY="$(grep -E '^ANSIBLE_SSH_KEY_SECRET=' ansible-agent/agent.conf | grep -oE '/v1/kv/data/[^ ]+' | head -1)"   # where (no value)
if [ -n "$KMS_ENTRY" ]; then SRC="kms (kv/${KMS_ENTRY#/v1/kv/data/})"; else SRC="agent.conf (SECRET_MGT=local)"; fi
echo -e "    SSH key   : ${BOLD}made in RAM${RESET} from $SRC — never on disk"
echo -e "    Agent     : ${BOLD}http://${AGENT_HOST}:${AGENT_PORT}${RESET} (Ansible's assistant — always on)"
echo ""
echo -e "    ${BOLD}./show_public_key.sh${RESET} — the key to put on each machine"
echo -e "    ${BOLD}./check_playbook.sh${RESET}  — dry run · ${BOLD}./apply_playbook.sh${RESET} — real run"
echo -e "    ${BOLD}./logs.sh${RESET} · ${BOLD}./status.sh${RESET} · ${BOLD}./stop.sh${RESET} · ${BOLD}./destroy.sh${RESET}"
