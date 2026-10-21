#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# test_mypostgresql_db_role.sh — automatic tests for story 3.5: Ansible renders mypostgresql_db's db-agent/agent.conf (check), writes + restarts (apply)
#
# What for    Proves that the mirror + shared/ + roles/mypostgresql_db render its REAL db-agent/agent.conf
#             byte for byte — on a THROWAWAY copy of those files, inside this checkout's image. Nothing real is touched.
#
# Who         Claude (Test 3a in the branch · 3c on main), or you.
#
# How         bash dockerspace/host_scripts/test_mypostgresql_db_role.sh        (≈30 s)
#
# Checks      M1 dry run with the dev environment's real values against a copy of its real db-agent/agent.conf → changed=0
#             M3 apply with nothing changed → changed=0, no restart
#             M2 its PORT changed → exactly that line · M5 apply → written + restart (stop.sh, start.sh) · M6 again → none
#             M7 shared/postgres.yml port changed → its PG_PORT line follows
#             M4 the source of truth (mirror + shared/) holds no secret: every password / key line is a kms address
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
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"             # confmgt/ansible
d="$_WS_ROOT"; while [ "$d" != / ] && [ ! -f "$d/projectspace/mypostgresql_db/db-agent/agent.conf" ]; do d="$(dirname "$d")"; done
MYPOSTGRESQL_DB="${MYPOSTGRESQL_DB_DIR:-$d/projectspace/mypostgresql_db}"                     # the REAL files — only READ, copied
IMG=confmgt-ansible:test-mypostgresql-db; FAIL=0; TMP="$(mktemp -d)"
ok()  { echo -e "\033[32m[  OK  ]\033[0m $*"; }
bad() { echo -e "\033[31m[ERROR]\033[0m  $*"; FAIL=1; }
trap 'docker run --rm -v "$TMP:/t" alpine:3 rm -rf /t/ws /t/p >/dev/null 2>&1; rm -rf "$TMP"; docker image rm "$IMG" >/dev/null 2>&1' EXIT
docker build -q -t "$IMG" -f "$HERE/dockerspace/Dockerfile" \
    $(sed -nE 's/^(PYTHON_IMAGE|PYTHON_DIGEST|ANSIBLE_CORE_VERSION)=(.*)/--build-arg \1=\2/p' "$HERE/dockerspace/.env") "$HERE" >/dev/null \
    || { bad "the test image did not build"; exit 1; }
# a throwaway workspace with a COPY of its db-agent/agent.conf · the Ansible project + an inventory t (this container, local)
W="$TMP/ws/projectspace/mypostgresql_db"; mkdir -p "$W/db-agent"
cp "$MYPOSTGRESQL_DB/db-agent/agent.conf" "$W/db-agent/agent.conf"
# its own stop.sh / start.sh as STUBS: they only write down that they were called (never the live database)
printf '#!/bin/bash\necho stop >> /ws/calls\n' > "$W/stop.sh"
printf '#!/bin/bash\necho "start $* SVC_RUN=${SVC_RUN:-}" >> /ws/calls\n' > "$W/start.sh"
calls() { cat "$TMP/ws/calls" 2>/dev/null | tr '\n' '|'; }
P="$TMP/p"; cp -a "$HERE/ansible_project" "$P"; mkdir -p "$P/inventories/t/group_vars"
printf 'all:\n  children:\n    mypostgresql_db:\n      hosts:\n        m1:\n          ansible_connection: local\n          workspace_root: /ws\n' > "$P/inventories/t/hosts.yml"
cp -a "$P/inventories/dev/group_vars/." "$P/inventories/t/group_vars/"; cp -a "$P/inventories/dev/myworkspace" "$P/inventories/dev/shared" "$P/inventories/t/"   # the DEV environment's REAL values (the mirror)
run() { docker run --rm -v "$TMP/ws:/ws" -v "$P:/p" -w /p -e ANSIBLE_CONFIG=/p/ansible.cfg -e ANSIBLE_NOCOLOR=1 "$IMG" \
          ansible-playbook -i inventories/t playbooks/mypostgresql_db.yml "$@" 2>&1; }
sum() { md5sum "$W/db-agent/agent.conf" | cut -c1-32 | tr '\n' ' '; }
S0="$(sum)"

o="$(run --check --diff)"; r=$?
[ $r = 0 ] && grep -qE 'm1 +: ok=[0-9]+ +changed=0 ' <<< "$o" && [ "$(sum)" = "$S0" ] \
  && ok "M1 the dev values render its real db-agent/agent.conf byte for byte → changed=0" \
  || bad "M1 rc=$r $(grep -E 'changed=|^[-+][A-Z]|FAILED|ERROR' <<< "$o" | head -6 | tr '\n' '¦')"

o="$(run)"; r=$?
[ $r = 0 ] && grep -qE 'm1 +: ok=[0-9]+ +changed=0 ' <<< "$o" && [ "$(sum)" = "$S0" ] && [ -z "$(calls)" ] \
  && ok "M3 apply with nothing changed → changed=0, no restart" || bad "M3 rc=$r calls=[$(calls)] $(grep -E 'changed=|FAILED' <<< "$o" | head -3 | tr '\n' '¦')"

sed -i 's#^  PORT: .*#  PORT: "8999"#' "$P/inventories/t/myworkspace/projectspace/mypostgresql_db/db-agent/agent.conf.yml"
o="$(run --check --diff)"; r=$?
[ $r = 0 ] && grep -qE 'm1 +: ok=[0-9]+ +changed=1 ' <<< "$o" && grep -qx -- '-PORT=8890' <<< "$o" && grep -qx -- '+PORT=8999' <<< "$o" \
  && [ "$(grep -cE '^[-+][A-Za-z_]+=' <<< "$o")" = 2 ] && [ "$(sum)" = "$S0" ] \
  && [ -z "$(calls)" ] && ok "M2 PORT changed in the source of truth → the dry run shows exactly -PORT=8890 +PORT=8999 · nothing written, no restart" \
  || bad "M2 rc=$r $(grep -E 'changed=|^[-+][A-Za-z]' <<< "$o" | head -6 | tr '\n' '¦')"

o="$(run --diff)"; r=$?
d="$(diff "$MYPOSTGRESQL_DB/db-agent/agent.conf" "$W/db-agent/agent.conf" | grep -E '^[<>]')"
[ $r = 0 ] && grep -qE 'm1 +: ok=[0-9]+ +changed=2 ' <<< "$o" && [ "$d" = $'< PORT=8890\n> PORT=8999' ] \
  && [ "$(calls)" = "stop|start  SVC_RUN=1|" ] \
  && ok "M5 apply with PORT changed → only PORT written · restart via its own stop.sh, then start.sh (SVC_RUN=1)" \
  || bad "M5 rc=$r calls=[$(calls)] diff=[$(tr '\n' '¦' <<< "$d")] $(grep -E 'changed=|FAILED|fatal' <<< "$o" | head -3 | tr '\n' '¦')"

o="$(run)"; r=$?
[ $r = 0 ] && grep -qE 'm1 +: ok=[0-9]+ +changed=0 ' <<< "$o" && [ "$(calls)" = "stop|start  SVC_RUN=1|" ] \
  && ok "M6 apply again → changed=0, no second restart (idempotent)" || bad "M6 rc=$r calls=[$(calls)]"

# M7 a SHARED value changed (shared/postgres.yml) → its PG_PORT line follows (the mirror refers to it, no copy)
sed -i 's#^  port: .*#  port: "5433"#' "$P/inventories/t/shared/postgres.yml"
o="$(run --check --diff)"; r=$?
[ $r = 0 ] && grep -qx -- '+PG_PORT=5433' <<< "$o" && grep -qE 'm1 +: ok=[0-9]+ +changed=1 ' <<< "$o" \
  && ok "M7 shared/postgres.yml port changed → the dry run shows its PG_PORT line follow it (+PG_PORT=5433)" \
  || bad "M7 rc=$r $(grep -E 'changed=|^[-+]PG_PORT|FAILED|fatal' <<< "$o" | head -4 | tr '\n' '¦')"

b4="$(grep -hE '^  [A-Za-z_]*(PASS|PASSWORD|SECRET|TOKEN|_KEY|api_key)[A-Za-z_]*: ' $(find "$HERE/ansible_project/inventories/dev/myworkspace/projectspace/mypostgresql_db" "$HERE/ansible_project/inventories/dev/shared" -name "*.yml") | grep -vE '^  (KMS_MASTER_PASSWORD_DIR|SECRET_MGT|secret_mgt): ' | grep -vE ': "\{\{ shared_[a-z_.]+ \}\}"' | grep -vE ': "(\$\{KMS_URL\}|https?://[^"]+)/v1/kv/data/')"   # a folder path / the mode: no secret
[ -z "$b4" ] && ok "M4 the source of truth holds no secret — every password / key is a kms address" || bad "M4 a secret value: $(cut -d: -f1 <<< "$b4" | tr '\n' ' ')"

[ "$FAIL" = 0 ] && ok "mypostgresql_db role tests passed (throwaway copy removed; the real file was only read)" && exit 0
exit 1
