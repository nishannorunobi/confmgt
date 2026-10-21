#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# test_ansible_container.sh — automatic tests: the Ansible container, its agent, kms, the SSH key, check / apply
#
# What for    Proves CONFMGT-3 on THROWAWAY containers only: a throwaway kms, this checkout's image under a test tag,
#             and a throwaway SSH machine for Ansible to configure. The live stack, the real kms and its
#             master_password are never touched.
#
# Who         Claude (Test 3a in the branch · 3c on main after the deploy), or you.
#
# How         bash dockerspace/host_scripts/test_ansible_container.sh        (≈2 min; the first run builds the SSH test machine's image once)
#
# Checks      C0  sign-up: own login + files (600), may read confmgt/ansible-agent + confmgt/ansible only · creates a missing key
#             C1  kms mode, no login + key missing → the agent signs itself up (its sign-up creates the key), fetches it,
#                 makes the SSH key in RAM · healthy · /health ssh_key true · C1b signed up + key gone → the agent registers it
#             C2  public key = ssh-ed25519 … confmgt-ansible · private key 600 in RAM only · same secret → same key
#             C3  /playbooks finds the playbooks + inventories by itself
#             C4  check ping → ok on the SSH machine · apply a test playbook → the file is there · check again → no change
#             C5  unknown playbook / inventory, bad limit, bad extra_vars → 400 · nothing run
#             C6  one run at a time → 409 while busy
#             C7  every run in its own log file + /runs/last
#             C8  SECRET_MGT=local: the value as written, no kms · local + a kms address → refused · kms + a plain
#                 value → refused · empty secret → exits (fails closed)
#             C9  the API dies → restarted · docker stop → clean exit 0
#             C10 the API never sees the secret (its environment) · the Ansible project passes --syntax-check
#             C11 every script explains itself (--help) · .env + agent.conf secret-free · credentials ignored
#             C12 no test value in logs or git
#             C13 the register script by hand on the PC: the PC's kms + the usual master_password, nothing asked
#             C14 wait_until_answering.sh: OK when it answers · the agent's own reason when it cannot · C15 status.sh: no traceback
#             C16 container_scripts/env_check.sh inside: all OK · C17 the standard layout (CLAUDEWORK-98) + status.sh --state
#             C18 authorize_ansible_on_this_pc.sh: the key into authorized_keys once (a temp file)
#             C19 on its own machine: a copy outside the workspace with its own LOG_DIR / KMS_MASTER_PASSWORD_DIR
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"              # confmgt/ansible (this file: dockerspace/host_scripts/)
AGENT="$HERE/ansible-agent"
d="$_WS_ROOT"; while [ "$d" != / ] && [ ! -f "$d/projectspace/kms/dockerspace/.env" ]; do d="$(dirname "$d")"; done
KMSP="${KMS_PROJECT:-$d/projectspace/kms}"                               # test-only: the kms image + bootstrap (a test copy → the workspace's)
OPENBAO_IMAGE="$(grep -E '^OPENBAO_IMAGE=' "$KMSP/dockerspace/.env" | cut -d= -f2-)"   # only the image — never kms's folders
T=confmgt-test-kms; A=confmgt-test-ansible; M=confmgt-test-machine; NET=confmgt-testnet
KP=8133; AP=8134; export KMS_URL=http://127.0.0.1:$KP; API=http://127.0.0.1:$AP
IMG=confmgt-ansible:test                                                 # this checkout, a test-only tag — never the live one
MIMG=confmgt-test-sshd-machine:1                                         # the SSH test machine (kept: later runs are offline)
DATA="$(mktemp -d)"; AUDIT="$(mktemp -d)"; WORK="$(mktemp -d)"
export KMS_STATE_DIR="$(mktemp -d)" KMS_SECRETS_DIR="$(mktemp -d)/kms" KMS_ALLOWED_CIDRS="172.16.0.0/12,127.0.0.1/32"
export KMS_STATIC_KEY_DIR="$(mktemp -d)/usb" KMS_USB_BACKUP_DIR="$(mktemp -d)"   # kms's usb/ (key · shares · master_password): temp — never the real one
export KMS_APPROLE_DIR="$KMS_SECRETS_DIR/approle"
REAL_STATE="$(stat -c '%n %s %Y' "$AGENT/connect_external/kms/credentials"/*/* "$_WS_ROOT/mountspace/usb/myworkspace/projectspace/kms"/* "$_WS_ROOT/mountspace/usb/myworkspace/projectspace/kms"/*/* 2>/dev/null | sort)"
FAIL=0
ok()  { echo -e "\033[32m[  OK  ]\033[0m $*"; }
bad() { echo -e "\033[31m[ERROR]\033[0m  $*"; FAIL=1; }
cleanup() { docker rm -f "$T" "$A" "$M" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; docker image rm "$IMG" >/dev/null 2>&1
            docker run --rm -v "$WORK:/w" alpine:3 rm -rf /w/x >/dev/null 2>&1    # files the container wrote as root
            rm -rf "$DATA" "$AUDIT" "$WORK" "$KMS_STATE_DIR" "$(dirname "$KMS_SECRETS_DIR")" "$(dirname "$KMS_STATIC_KEY_DIR")" "$KMS_USB_BACKUP_DIR" 2>/dev/null; }
trap cleanup EXIT
health() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$KMS_URL/v1/sys/health"; }
j() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
post() { curl -s -w '\n%{http_code}' --max-time 120 -X POST -H 'Content-Type: application/json' --data "$2" "$API/$1"; }
code() { tail -1 <<< "$1"; }
body() { sed '$d' <<< "$1"; }

# ── images: this checkout (test tag) + the SSH test machine ──────────────────
docker build -q -t "$IMG" -f "$HERE/dockerspace/Dockerfile" \
    $(sed -nE 's/^(PYTHON_IMAGE|PYTHON_DIGEST|ANSIBLE_CORE_VERSION)=(.*)/--build-arg \1=\2/p' "$HERE/dockerspace/.env") "$HERE" >/dev/null \
    || { bad "the test image did not build"; exit 1; }
if ! docker image inspect "$MIMG" >/dev/null 2>&1; then
    printf 'FROM alpine:3\nRUN apk add --no-cache openssh python3 && ssh-keygen -A && adduser -D ansible && echo "ansible:*" | chpasswd -e \\\n && mkdir -p /home/ansible/.ssh && chown ansible /home/ansible/.ssh && chmod 700 /home/ansible/.ssh\nCMD ["/usr/sbin/sshd","-D","-e"]\n' \
        | docker build -q -t "$MIMG" - >/dev/null || { bad "the SSH test machine's image did not build (needs the internet once)"; exit 1; }
fi

# ── throwaway kms: init, unseal, bootstrap ───────────────────────────────────
docker rm -f "$T" "$A" "$M" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
docker network create "$NET" >/dev/null || { bad "test network failed"; exit 1; }
docker run -d --name "$T" --network "$NET" -p 127.0.0.1:$KP:8200 --user "$(id -u):$(id -g)" -e SKIP_CHOWN=true \
    -v "$KMSP/dockerspace/config:/openbao/config:ro" -v "$DATA:/openbao/data" -v "$AUDIT:/openbao/audit" \
    "$OPENBAO_IMAGE" server >/dev/null || { bad "throwaway kms did not start"; exit 1; }
for _ in $(seq 1 30); do [ "$(health)" = 501 ] && break; sleep 1; done
INIT="$(printf '{"secret_shares":3,"secret_threshold":2}' | curl -s -X PUT --data @- "$KMS_URL/v1/sys/init")"
S1="$(echo "$INIT" | j 'd["keys_base64"][0]')"; S2="$(echo "$INIT" | j 'd["keys_base64"][1]')"; unset INIT
for k in "$S1" "$S2"; do printf '{"key":"%s"}' "$k" | curl -s -X PUT --data @- "$KMS_URL/v1/sys/unseal" >/dev/null; done
for _ in $(seq 1 30); do [ "$(health)" = 200 ] && break; sleep 1; done
PW="pw-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf '%s\n%s\n%s\n%s\n' "$S1" "$S2" "$PW" "$PW" | bash "$KMSP/bootstrap.sh" >/dev/null 2>&1 || { bad "kms bootstrap failed"; exit 1; }
owner_token() { printf '%s' "$PW" | python3 -c 'import sys,json; print(json.dumps({"password":sys.stdin.read()}))' \
    | curl -s -X POST --data @- "$KMS_URL/v1/auth/userpass/login/nishan" | j 'd["auth"]["client_token"]'; }
kget() { local t; t="$(owner_token)"; curl -s -H @<(printf 'X-Vault-Token: %s\n' "$t") "$KMS_URL/v1/kv/data/$1" | j "d['data']['data'].get('$2','')"; }
kdel() { local t; t="$(owner_token)"; curl -s -o /dev/null -X DELETE -H @<(printf 'X-Vault-Token: %s\n' "$t") "$KMS_URL/v1/kv/metadata/$1"; }
KADDR="http://$T:8200/v1/kv/data"

# ── C0: sign-up with temp credentials ────────────────────────────────────────
export REG_AGENT_CONF="$(mktemp)"
printf 'KMS_URL=http://%s:8200\nSECRET_MGT=kms\n# kms: ${KMS_URL}/v1/kv/data/confmgt/ansible\nANSIBLE_SSH_KEY_SECRET=${KMS_URL}/v1/kv/data/confmgt/ansible\n' "$T" > "$REG_AGENT_CONF"
reg="$(printf '%s\n' "$PW" | bash "$AGENT/connect_external/kms/signup_with_kms.sh" 2>&1)"; rc=$?
reg2="$(printf '%s\n' "$PW" | bash "$AGENT/connect_external/kms/signup_with_kms.sh" 2>&1)"
rm -f "$REG_AGENT_CONF"; unset REG_AGENT_CONF
K0="$(kget confmgt/ansible ANSIBLE_SSH_KEY_SECRET)"
[ $rc = 0 ] && grep -q 'confmgt-ansible-agent — may read: confmgt/ansible-agent confmgt/ansible' <<< "$reg" && grep -q 'login kept' <<< "$reg2" \
  && [ "$(stat -c %a "$KMS_APPROLE_DIR/confmgt-ansible-agent/secret_id")" = 600 ] \
  && grep -q 'ANSIBLE_SSH_KEY_SECRET → kv/confmgt/ansible: initial RANDOM value' <<< "$reg" && [[ "$K0" =~ ^[A-Za-z0-9]{32}$ ]] \
  && grep -q 'ANSIBLE_SSH_KEY_SECRET already in kms' <<< "$reg2" && ! grep -qF -- "$K0" <<< "$reg$reg2" \
  && ok "C0 sign-up: own login (600), reads its 2 paths only · the missing key created right away with the same login · re-run keeps both" \
  || bad "C0 sign-up: $(grep -E 'ERROR|may read|RANDOM' <<< "$reg$reg2" | head -3)"
kdel confmgt/ansible                                                     # C1 starts again from a kms without the key

# ── helper: the agent exactly as compose runs it (supervisor.py), with a COPY of ansible-agent/ ──
AD="$WORK/x/ansible-agent"; PD="$WORK/x/ansible_project"; LG="$WORK/x/logs"; MPF="$WORK/x/master_password"
mkdir -p "$WORK/x" "$LG" "$WORK/x/data"; printf '%s\n' "$PW" > "$MPF"
# the test Ansible project: the real one + an inventory "t" (the SSH test machine) + test playbooks
rm -rf "$PD"; cp -a "$HERE/ansible_project" "$PD"
mkdir -p "$PD/inventories/t/host_vars"
printf 'all:\n  hosts:\n    m1:\n' > "$PD/inventories/t/hosts.yml"
printf 'ansible_host: %s\nansible_user: ansible\n' "$M" > "$PD/inventories/t/host_vars/m1.yml"
printf -- '- hosts: all\n  gather_facts: false\n  tasks:\n    - ansible.builtin.copy: {dest: /tmp/confmgt_marker, content: "confmgt was here\\n", mode: "0644"}\n' > "$PD/playbooks/zz_marker.yml"
printf -- '- hosts: all\n  gather_facts: false\n  tasks:\n    - ansible.builtin.command: sleep 6\n' > "$PD/playbooks/zz_sleep.yml"
run_agent() {   # run_agent <agent.conf text> [with-login] — a fresh COPY of ansible-agent/
    docker rm -f "$A" >/dev/null 2>&1; docker run --rm -v "$WORK/x:/x" alpine:3 rm -rf /x/ansible-agent >/dev/null 2>&1
    mkdir -p "$AD"; (cd "$AGENT" && tar --exclude=./connect_external/kms/credentials --exclude='./__pycache__' -cf - .) | tar -xf - -C "$AD"
    printf '%s\n' "$1" > "$AD/agent.conf"
    if [ "${2:-}" = with-login ]; then
        mkdir -p "$AD/connect_external/kms/credentials" && cp -r "$WORK/login" "$AD/connect_external/kms/credentials/confmgt-ansible-agent"
    fi
    docker run -d --name "$A" --network "$NET" -p 127.0.0.1:$AP:8897 --tmpfs /run \
        -e LOG_MIRROR_ROOT=/mountspace/logs/t -e KMS_MASTER_PASSWORD_FILE=/mpw/master_password -e KMS_ALLOWED_CIDRS \
        -e ANSIBLE_PROJECT_DIR=/ansible_project -e ANSIBLE_DATA_DIR=/data -e PYTHONUNBUFFERED=1 -e PYTHONDONTWRITEBYTECODE=1 \
        -v "$AD:/ansible-agent" -v "$PD:/ansible_project:ro" -v "$HERE/dockerspace/container_scripts:/container_scripts:ro" -v "$WORK/x/data:/data" -v "$LG:/mountspace/logs" -v "$(dirname "$MPF"):/mpw:ro" \
        "$IMG" /opt/venv/bin/python /ansible-agent/supervisor.py >/dev/null
}
up() { for _ in $(seq 1 40); do curl -fs -o /dev/null --max-time 2 "$API/health" && return 0
         [ "$(docker inspect -f '{{.State.Running}}' "$A" 2>/dev/null)" = false ] && return 1; sleep 1; done; return 1; }
stopped() { for _ in $(seq 1 20); do [ "$(docker inspect -f '{{.State.Running}}' "$A" 2>/dev/null)" = false ] && return 0; sleep 1; done; return 1; }
CONF_KMS="KMS_URL=http://$T:8200
SECRET_MGT=kms
PORT=8897
# kms: \${KMS_URL}/v1/kv/data/confmgt/ansible
ANSIBLE_SSH_KEY_SECRET=\${KMS_URL}/v1/kv/data/confmgt/ansible"

# ── C1: no login + key missing → signs up, registers, fetches, key in RAM ────
run_agent "$CONF_KMS"
if up; then lg="$(docker logs "$A" 2>&1)"; h="$(curl -s "$API/health")"; S="$(kget confmgt/ansible ANSIBLE_SSH_KEY_SECRET)"
    grep -q 'signed up with kms' <<< "$lg" && grep -q 'ANSIBLE_SSH_KEY_SECRET → kv/confmgt/ansible: initial RANDOM value' <<< "$lg" \
      && grep -q 'ANSIBLE_SSH_KEY_SECRET ← kms (confmgt/ansible)' <<< "$lg" && [[ "$S" =~ ^[A-Za-z0-9]{32}$ ]] \
      && [ "$(echo "$h" | j 'd["ssh_key"]')" = True ] && grep -q 'core 2.21' <<< "$(echo "$h" | j 'd["ansible"]')" \
      && ok "C1 no login + key missing → the agent signs up (its sign-up creates the key), fetches it, SSH key in RAM, /health ok" \
      || bad "C1: $(grep -E 'ERROR|WARN' <<< "$lg" | head -3) health=$h"
else bad "C1 the agent did not come up: $(docker logs "$A" 2>&1 | tail -3)"; fi
cp -r "$AD/connect_external/kms/credentials/confmgt-ansible-agent" "$WORK/login" 2>/dev/null || docker cp "$A:/ansible-agent/connect_external/kms/credentials/confmgt-ansible-agent" "$WORK/login"

# ── C1b: signed up, but the key is gone from kms → the agent registers it itself (master_password) ──
kdel confmgt/ansible; run_agent "$CONF_KMS" with-login
if up; then lg="$(docker logs "$A" 2>&1)"
    grep -q 'ANSIBLE_SSH_KEY_SECRET: not in kms — registering' <<< "$lg" && grep -q 'kms owner login: handed over' <<< "$lg" \
      && grep -q 'ANSIBLE_SSH_KEY_SECRET ← kms (confmgt/ansible)' <<< "$lg" && ! grep -q 'signed up with kms' <<< "$lg" \
      && ok "C1b signed up + key missing → the agent registers it itself (owner login from master_password), fetches it" \
      || bad "C1b: $(grep -E 'ERROR|registering' <<< "$lg" | head -2)"
else bad "C1b the agent did not come up: $(docker logs "$A" 2>&1 | tail -2)"; fi
S="$(kget confmgt/ansible ANSIBLE_SSH_KEY_SECRET)"

# ── C14a: wait_until_answering.sh — a healthy agent → OK at once ─────────────
o14="$(CONFMGT_CONTAINER="$A" ANSIBLE_AGENT_URL="$API" WAIT_SECONDS=20 bash "$AGENT/wait_until_answering.sh" 2>&1)"; r14=$?
[ $r14 = 0 ] && grep -q 'ansible-agent answers on .* (SSH key ready)' <<< "$o14" && ok "C14a wait_until_answering.sh: the agent answers → OK, SSH key ready" || bad "C14a rc=$r14 $o14"

# ── C2: public key, private key in RAM only, same secret → same key ─────────
PUB="$(curl -s "$API/public-key")"
perm="$(docker exec "$A" stat -c %a /run/ansible-ssh/id_ed25519 2>/dev/null)"
ondisk="$(docker exec "$A" sh -c 'grep -rl "PRIVATE KEY" /data /ansible-agent /ansible_project 2>/dev/null | head -1')"
docker restart "$A" >/dev/null; up; PUB2="$(curl -s "$API/public-key")"
[[ "$PUB" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+\ confmgt-ansible$ ]] && [ "$perm" = 600 ] && [ -z "$ondisk" ] && [ "$PUB" = "$PUB2" ] \
  && ok "C2 public key ssh-ed25519 … confmgt-ansible · private key 600 in RAM only · restart → the same key" \
  || bad "C2 pub='${PUB:0:30}…' perm=$perm ondisk=$ondisk same=$([ "$PUB" = "$PUB2" ] && echo y || echo n)"

# ── C18: authorize_ansible_on_this_pc.sh — the key into authorized_keys (a TEMP file), once ─────────
AKF="$WORK/akhome/.ssh/authorized_keys"
o18="$(ANSIBLE_AGENT_URL="$API" AUTHORIZED_KEYS_FILE="$AKF" bash "$HERE/authorize_ansible_on_this_pc.sh" 2>&1)"; r18=$?
o18b="$(ANSIBLE_AGENT_URL="$API" AUTHORIZED_KEYS_FILE="$AKF" bash "$HERE/authorize_ansible_on_this_pc.sh" 2>&1)"
[ $r18 = 0 ] && grep -q "key added to $AKF" <<< "$o18" && grep -q "already in $AKF" <<< "$o18b" && [ "$(grep -cxF -- "$PUB2" "$AKF")" = 1 ] \
  && [ "$(stat -c %a "$AKF")" = 600 ] && [ "$(stat -c %a "$(dirname "$AKF")")" = 700 ] \
  && ok "C18 authorize_ansible_on_this_pc.sh: the public key added once (600, folder 700) · again → 'already there'" \
  || bad "C18 rc=$r18 [$(tail -1 <<< "$o18")] [$(tail -1 <<< "$o18b")]"

# ── the SSH test machine: Ansible's public key in its authorized_keys ────────
docker run -d --name "$M" --network "$NET" "$MIMG" >/dev/null
printf '%s\n' "$PUB" > "$WORK/ak"; docker cp "$WORK/ak" "$M:/home/ansible/.ssh/authorized_keys" >/dev/null
docker exec "$M" sh -c 'chown ansible /home/ansible/.ssh/authorized_keys && chmod 600 /home/ansible/.ssh/authorized_keys'

# ── C16: env_check.sh inside the container (what you run after logging in) ───
o16="$(docker exec "$A" bash /container_scripts/env_check.sh 2>&1)"; r16=$?
[ $r16 = 0 ] && [ "$(grep -c '\[  OK  \]' <<< "$o16")" = 6 ] && ok "C16 env_check.sh inside the container: ansible · SSH key 600 · project read-only · playbooks · agent · /data — all OK" \
  || bad "C16 rc=$r16 $(grep ERROR <<< "$o16" | head -2 | tr '\n' '¦')"

# ── C3: discovery ────────────────────────────────────────────────────────────
pl="$(curl -s "$API/playbooks")"
[ "$(echo "$pl" | j '" ".join(d["playbooks"])')" = "$(cd "$PD/playbooks" && ls *.yml | sed 's/\.yml$//' | sort | xargs)" ] && [ "$(echo "$pl" | j '" ".join(d["inventories"])')" = "dev t test" ] \
  && ok "C3 /playbooks finds playbooks/*.yml + inventories/<env>/ by itself (a new file = a new choice)" || bad "C3 $pl"

# ── C4: check / apply on the SSH machine ─────────────────────────────────────
r1="$(post check '{"playbook":"ping","inventory":"t"}')"
r2="$(post check '{"playbook":"zz_marker","inventory":"t"}')"; m0="$(docker exec "$M" cat /tmp/confmgt_marker 2>/dev/null)"
r3="$(post apply '{"playbook":"zz_marker","inventory":"t","limit":"m1"}')"; m1="$(docker exec "$M" cat /tmp/confmgt_marker 2>/dev/null)"
r4="$(post check '{"playbook":"zz_marker","inventory":"t"}')"
[ "$(code "$r1")" = 200 ] && [ "$(body "$r1" | j 'd["ok"]')" = True ] && grep -q 'm1 *: ok=1 ' <<< "$(body "$r1" | j 'd["output"]')" \
  && [ "$(body "$r2" | j 'd["ok"]')" = True ] && grep -q 'changed=1' <<< "$(body "$r2" | j 'd["output"]')" && [ -z "$m0" ] \
  && [ "$(body "$r3" | j 'd["ok"]')" = True ] && [ "$m1" = "confmgt was here" ] \
  && grep -q 'changed=0' <<< "$(body "$r4" | j 'd["output"]')" \
  && ok "C4 check ping → reached · check → would change, nothing changed · apply → the file is there · check again → no change" \
  || bad "C4 r1=$(code "$r1") $(body "$r1" | j 'd.get("output","")[-300:]') r3=$(body "$r3" | j 'd.get("output","")[-200:]') m1=$m1"

# ── C5: allow-lists ──────────────────────────────────────────────────────────
c1="$(code "$(post check '{"playbook":"nope","inventory":"t"}')")"
c2="$(code "$(post check '{"playbook":"ping","inventory":"prod"}')")"
c3="$(code "$(post apply '{"playbook":"../playbooks/ping","inventory":"t"}')")"
c4="$(code "$(post check '{"playbook":"ping","inventory":"t","limit":"m1; rm -rf /"}')")"
c5="$(code "$(post check '{"playbook":"ping","inventory":"t","extra_vars":{"ws_branch":"x; rm -rf /"}}')")"
c8="$(code "$(post check '{"playbook":"ping","inventory":"t","extra_vars":{"ws_repo_branches":"projectspace/kms=story/X-1,projectspace/mydocs=main"}}')")"
c6="$(code "$(post check '{"playbook":"ping","inventory":"t","extra_vars":{"Bad-Name":"main"}}')")"
c7="$(code "$(post check '{"playbook":"ping","inventory":"t","extra_vars":{"ws_branch":"story/CONFMGT-1-x"}}')")"
[ "$c1$c2$c3$c4$c5$c6$c7$c8" = 400400400400400400200200 ] && ok "C5 unknown playbook / inventory, a path, a bad limit, a bad extra_vars value / name → 400, nothing run · a plain branch, a path=branch list → 200" || bad "C5 codes $c1 $c2 $c3 $c4 $c5 $c6 $c7 $c8"

# ── C6: one run at a time ────────────────────────────────────────────────────
post apply '{"playbook":"zz_sleep","inventory":"t"}' > "$WORK/busy" & bp=$!
sleep 2; c6="$(code "$(post check '{"playbook":"ping","inventory":"t"}')")"; busy="$(curl -s "$API/health" | j 'd["running"]')"; wait $bp
[ "$c6" = 409 ] && [ "$busy" = True ] && [ "$(body "$(cat "$WORK/busy")" | j 'd["ok"]')" = True ] \
  && ok "C6 a second run while one is going on → 409 (the first finishes)" || bad "C6 code=$c6 busy=$busy"

# ── C7: run logs + /runs/last ────────────────────────────────────────────────
n="$(ls "$LG/t/ansible-agent/runs/" 2>/dev/null | grep -c '\.log$')"; last="$(curl -s "$API/runs/last")"
[ "$n" -ge 5 ] && [ "$(echo "$last" | j 'd["playbook"]')" = zz_sleep ] && ls "$LG/t/ansible-agent/runs/" | grep -q '_apply_zz_marker_t\.log$' \
  && ok "C7 every run in its own log file ($n) · /runs/last = the last one" || bad "C7 logs=$n last=$(echo "$last" | j 'd.get("playbook")')"

# ── C9: the API dies → restarted · docker stop → clean exit 0 ────────────────
docker exec "$A" sh -c 'kill $(pgrep -f "uvicorn server:app")' 2>/dev/null; sleep 4
up && docker logs "$A" 2>&1 | grep -q 'API exited' && rs=1 || rs=0
docker stop -t 20 "$A" >/dev/null
[ $rs = 1 ] && [ "$(docker inspect -f '{{.State.ExitCode}}' "$A")" = 0 ] \
  && ok "C9 the API died → started again by the supervisor · docker stop → exit 0" || bad "C9 restart=$rs exit=$(docker inspect -f '{{.State.ExitCode}}' "$A")"

# ── C8: local mode and the wrong mixes ───────────────────────────────────────
LSEC="loc$(head -c 15 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 29)"
run_agent "SECRET_MGT=local
PORT=8897
ANSIBLE_SSH_KEY_SECRET=$LSEC"
up && l1="$(docker logs "$A" 2>&1)" && LPUB="$(curl -s "$API/public-key")"
run_agent "SECRET_MGT=local
ANSIBLE_SSH_KEY_SECRET=$KADDR/confmgt/ansible"; stopped; l2="$(docker logs "$A" 2>&1)"
run_agent "KMS_URL=http://$T:8200
SECRET_MGT=kms
ANSIBLE_SSH_KEY_SECRET=$LSEC" with-login; stopped; l3="$(docker logs "$A" 2>&1)"
run_agent "SECRET_MGT=local
ANSIBLE_SSH_KEY_SECRET="; stopped; l4="$(docker logs "$A" 2>&1)"
# ── C14b + C15: the agent is down — wait says why at once · status.sh one plain line, no traceback ──
o14b="$(CONFMGT_CONTAINER="$A" ANSIBLE_AGENT_URL="$API" WAIT_SECONDS=20 bash "$AGENT/wait_until_answering.sh" 2>&1)"; r14b=$?
o15="$(cd "$HERE" && CONFMGT_CONTAINER="$A" ANSIBLE_AGENT_URL="$API" bash status.sh 2>&1)"
[ $r14b = 1 ] && grep -q 'does not answer — why: ANSIBLE_SSH_KEY_SECRET is empty' <<< "$o14b" \
  && grep -q "agent: not answering on $API — last error: ANSIBLE_SSH_KEY_SECRET is empty" <<< "$o15" && ! grep -q Traceback <<< "$o15" \
  && ok "C14b + C15 agent down → wait_until_answering.sh names the agent's reason, exit 1 · status.sh one plain line with it, no traceback" \
  || bad "C14b/C15 rc=$r14b [$(tail -2 <<< "$o14b" | tr '\n' '¦')] [$(tail -2 <<< "$o15" | tr '\n' '¦')]"
grep -q 'secrets: local' <<< "$l1" && ! grep -q '← kms' <<< "${l1:-x}" && [[ "$LPUB" =~ ^ssh-ed25519\  ]] && [ "$LPUB" != "$PUB" ] \
  && grep -q 'but ANSIBLE_SSH_KEY_SECRET is a kms address' <<< "$l2" && grep -q 'SECRET_MGT=kms but ANSIBLE_SSH_KEY_SECRET is not a kms address' <<< "$l3" \
  && grep -q 'ANSIBLE_SSH_KEY_SECRET is empty' <<< "$l4" \
  && ok "C8 local → the value as written, no kms (another key) · local + address / kms + plain → refused · empty → exits" \
  || bad "C8 $(grep -E 'ERROR|secrets:' <<< "$l1$l2$l3$l4" | head -4 | tr '\n' '¦')"

# ── C10: the API never sees the secret · syntax check of the Ansible project ─
run_agent "$CONF_KMS" with-login; up
apienv="$(docker exec "$A" sh -c 'cat /proc/$(pgrep -f "uvicorn server:app" | head -1)/environ' 2>/dev/null | tr '\0' '\n')"
S="$(kget confmgt/ansible ANSIBLE_SSH_KEY_SECRET)"
syn="$(docker exec "$A" sh -c 'cd /ansible_project && for p in playbooks/*.yml; do ansible-playbook --syntax-check -i inventories/test "$p" || exit 1; done' 2>&1)"; src=$?
[ -n "$apienv" ] && ! grep -q 'ANSIBLE_SSH_KEY_SECRET' <<< "$apienv" && ! grep -qF -- "$S" <<< "$apienv" && [ $src = 0 ] \
  && ok "C10 the API's environment has no secret · every playbook passes --syntax-check" || bad "C10 env-has-secret=$(grep -c SECRET <<< "$apienv") syntax=$src ${syn: -200}"
docker rm -f "$A" >/dev/null

# ── C13: the register script by hand ON THE PC: agent.conf names kms as containers see it (unknown here) → the
#         PC's kms (KMS_HOST_URL) · the password from the usual master_password file (a temp workspace) · no terminal ──
kdel confmgt/ansible
PC="$WORK/pc"; PK="$PC/projectspace/confmgt/ansible/ansible-agent/connect_external/kms"; mkdir -p "$PK" "$PC/mountspace/usb/myworkspace/projectspace/kms/master_password"
cp "$AGENT/connect_external/kms/register_kms_ansible_keys_with_random_initial.sh" "$AGENT/connect_external/kms/kms_conf.sh" "$PK/"
printf '%s\n' "$PW" > "$PC/mountspace/usb/myworkspace/projectspace/kms/master_password/master_password"
printf 'KMS_URL=http://kms-not-from-the-pc.invalid:8200\nSECRET_MGT=kms\n# kms: ${KMS_URL}/v1/kv/data/confmgt/ansible\nANSIBLE_SSH_KEY_SECRET=${KMS_URL}/v1/kv/data/confmgt/ansible\n' > "$PC/projectspace/confmgt/ansible/ansible-agent/agent.conf"
o13="$(env -u KMS_URL -u KMS_TOKEN -u KMS_MASTER_PASSWORD_FILE KMS_HOST_URL="$KMS_URL" bash "$PK/register_kms_ansible_keys_with_random_initial.sh" </dev/null 2>&1)"; r13=$?
[ $r13 = 0 ] && grep -q "using this PC's kms at $KMS_URL" <<< "$o13" && grep -q "kms owner login: from kms's master_password" <<< "$o13" \
  && grep -q 'initial RANDOM value' <<< "$o13" && [[ "$(kget confmgt/ansible ANSIBLE_SSH_KEY_SECRET)" =~ ^[A-Za-z0-9]{32}$ ]] && ! grep -q 'password for' <<< "$o13" \
  && ok "C13 register script by hand on the PC: kms's container name unknown → the PC's kms · password from the usual master_password file, nothing asked" \
  || bad "C13 rc=$r13 [$(grep -E 'ERROR|INFO' <<< "$o13" | head -3 | tr '\n' '¦')]"

# ── C17: the standard layout (CLAUDEWORK-98) — the names say where a script runs ──
b17=""
for f in start.sh stop.sh status.sh show_public_key.sh check_playbook.sh apply_playbook.sh README.md \
         dockerspace/docker-compose.yml dockerspace/Dockerfile dockerspace/.env dockerspace/host_scripts/start.sh dockerspace/host_scripts/stop.sh \
         dockerspace/host_scripts/clean.sh dockerspace/host_scripts/confmgt_ansible_container_login.sh dockerspace/container_scripts/env_check.sh; do
    [ -f "$HERE/$f" ] || b17+=" missing:$f"
done
for f in "$HERE"/*.sh; do case "$(basename "$f")" in start.sh|stop.sh|status.sh|show_public_key.sh|check_playbook.sh|apply_playbook.sh|authorize_ansible_on_this_pc.sh|deploy_on_this_pc.sh|stop_on_this_pc.sh) ;; *) b17+=" top:$(basename "$f")" ;; esac; done
[ -e "$HERE/docker-compose.yml" ] && b17+=" top:docker-compose.yml"
s="$(cd "$HERE" && bash status.sh --state 2>&1)"; [[ "$s" =~ ^(running|stopped)$ ]] || b17+=" state:[$s]"
[ -z "$b17" ] && ok "C17 standard layout: top = start/stop/status + your commands · dockerspace/{compose, Dockerfile, .env, host_scripts/, container_scripts/} · status.sh --state = one word" \
  || bad "C17:$b17"

# ── C19: confmgt ON ITS OWN MACHINE: a copy outside the workspace, its own paths in .env ─────────────────
SRV="$WORK/x/opt/confmgt"; mkdir -p "$SRV"; (cd "$HERE" && tar --exclude=./ansible-agent/connect_external/kms/credentials -cf - .) | tar -xf - -C "$SRV"
sed -i -e "s#^LOG_DIR=.*#LOG_DIR=$WORK/x/srv/log#" -e "s#^KMS_MASTER_PASSWORD_DIR=.*#KMS_MASTER_PASSWORD_DIR=$WORK/x/srv/mpw#" "$SRV/dockerspace/.env"
STUB="$WORK/x/stubbin"; mkdir -p "$STUB"; printf '#!/bin/bash\necho "docker $*" >> %s/calls\n' "$WORK/x" > "$STUB/docker"; chmod +x "$STUB/docker"
o19="$(PATH="$STUB:$PATH" bash "$SRV/dockerspace/host_scripts/start.sh" 2>&1)"; r19=$?
cfg="$(cd "$SRV/dockerspace" && docker compose config 2>/dev/null)"
[ $r19 = 0 ] && [ -d "$WORK/x/srv/log" ] && [ -d "$WORK/x/srv/mpw" ] && grep -q 'LOG_DIR: created' <<< "$o19" && grep -q 'compose up -d' "$WORK/x/calls" \
  && grep -q "source: $WORK/x/srv/log" <<< "$cfg" && grep -q "source: $WORK/x/srv/mpw" <<< "$cfg" && ! grep -q 'mountspace/logs$' <<< "$(grep 'source:' <<< "$cfg")" \
  && ok "C19 on its own machine (a copy outside the workspace): LOG_DIR + KMS_MASTER_PASSWORD_DIR from .env → both folders created, mounted from there, compose up" \
  || bad "C19 rc=$r19 [$(tr '\n' '¦' <<< "$o19" | cut -c1-200)] calls=[$(cat "$WORK/x/calls" 2>/dev/null)]"

# ── C11: static ──────────────────────────────────────────────────────────────
b11=""
for f in "$HERE"/*.sh "$HERE"/dockerspace/host_scripts/*.sh "$HERE"/dockerspace/container_scripts/*.sh "$AGENT"/*.sh "$AGENT"/connect_external/kms/*.sh; do
    case "$(basename "$f")" in lib_run_playbook.sh|kms_conf.sh) continue ;; esac
    head -2 "$f" | grep -q '^# ─' || { b11+=" $(basename "$f"):header"; continue; }
    out="$(bash "$f" --help 2>&1 </dev/null)"; [ "$(wc -l <<< "$out")" -ge 2 ] || b11+=" $(basename "$f"):help"
done
grep -E '^[A-Z_]*(PASS|PASSWORD|SECRET|TOKEN|API_KEY)[A-Z_]*=.+' "$HERE/dockerspace/.env" | grep -vq '^KMS_MASTER_PASSWORD_DIR=' && b11+=" .env:secret"
grep -E '^[A-Z_]*(PASS|PASSWORD|SECRET|TOKEN|_KEY)=.+' "$AGENT/agent.conf" | grep -vqE '=(https?://[^ ]+|\$\{KMS_URL\})/v1/kv/' && b11+=" agent.conf:secret"
git -C "$HERE" check-ignore -q "ansible-agent/connect_external/kms/credentials/x/secret_id" || b11+=" credentials:not-ignored"
git -C "$HERE" check-ignore -q "ansible-agent/agent.conf" && b11+=" agent.conf:ignored"
[ -z "$b11" ] && ok "C11 every script has a tidy header + --help · .env / agent.conf secret-free and tracked · credentials ignored" || bad "C11:$b11"

# ── C12: no test value in logs or git; the real kms state untouched ──────────
leak=0
for v in "$PW" "$S" "$LSEC" "${K0:-}"; do [ -n "$v" ] || continue
    grep -rqF -- "$v" "$LG" "$_WS_ROOT/mountspace/logs/myworkspace/projectspace/under_develop/confmgt" "$_WS_ROOT/mountspace/logs/myworkspace/projectspace/confmgt" 2>/dev/null && leak=1
    git -C "$HERE" grep -qF -- "$v" 2>/dev/null && leak=1
done
NOW_STATE="$(stat -c '%n %s %Y' "$AGENT/connect_external/kms/credentials"/*/* "$_WS_ROOT/mountspace/usb/myworkspace/projectspace/kms"/* "$_WS_ROOT/mountspace/usb/myworkspace/projectspace/kms"/*/* 2>/dev/null | sort)"
[ $leak = 0 ] && [ "$NOW_STATE" = "$REAL_STATE" ] && ok "C12 no test value in logs or git · the real kms state + logins untouched" || bad "C12 leak=$leak real-state-changed=$([ "$NOW_STATE" = "$REAL_STATE" ] && echo no || echo YES)"

unset S1 S2 PW S LSEC K0
[ "$FAIL" = 0 ] && ok "confmgt Ansible tests passed (throwaway containers removed)" && exit 0
exit 1
