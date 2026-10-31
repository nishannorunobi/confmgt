#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# test_all_roles.sh — every project in the source of truth renders its REAL config files: changed=0 (check + apply)
#
# What for    The epic's promise in one test: for EVERY role (roles/<project>/defaults <project>_files), the dev mirror +
#             shared/ render the project's real files byte for byte — on THROWAWAY copies, in this checkout's image.
#
# Who         Claude (3a / 3c of every epic-[3] story), or you.
#
# How         bash tests/test_all_roles.sh        (≈1 min)
#
# Checks      A1 every project: dry run → changed=0 · A2 every project: apply → changed=0, no restart (nothing changed)
#             A3 the real files only read · A4 no secret in the mirror or shared/ (passwords / keys = kms addresses)
#             A5 playbooks/deploy.yml with the REAL dev deploy_projects (CONFMGT [6]) on the copies: changed=0, each
#                project's targets handed to ccc/scripts/svcmgt/start_targets.sh (a stub) in projects.yml's order, the copies unchanged
#             A6 the TEST values (inventories/test/) render every project's real files too · A7 no secret in the test mirror
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
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"             # confmgt/ansible
d="$_WS_ROOT"; while [ "$d" != / ] && [ ! -f "$d/ccc/scripts/svcmgt/svc_policy.conf" ]; do d="$(dirname "$d")"; done
REAL="${REAL_WORKSPACE:-$d}"                                           # the REAL workspace — only READ, copied
IMG=ccc:test-all-roles; FAIL=0; TMP="$(mktemp -d)"
ok()  { echo -e "\033[32m[  OK  ]\033[0m $*"; }
bad() { echo -e "\033[31m[ERROR]\033[0m  $*"; FAIL=1; }
trap 'docker run --rm -v "$TMP:/t" alpine:3 rm -rf /t/ws /t/p >/dev/null 2>&1; rm -rf "$TMP"; docker image rm "$IMG" >/dev/null 2>&1' EXIT
CCC="$(cd "$HERE/../.." && pwd)"                                      # ccc/ — THE CCC image (CLAUDEWORK-270)
docker build -q -t "$IMG" -f "$CCC/container/Dockerfile" \
    $(sed -nE 's/^(PYTHON_IMAGE|PYTHON_DIGEST|ANSIBLE_CORE_VERSION)=(.*)/--build-arg \1=\2/p' "$CCC/container/.env") "$CCC" >/dev/null \
    || { bad "the test image did not build"; exit 1; }
P="$TMP/p"; cp -a "$HERE/ansible_project" "$P"; mkdir -p "$P/inventories/t"
cp -a "$P/inventories/dev/group_vars" "$P/inventories/dev/myworkspace" "$P/inventories/dev/shared" "$P/inventories/t/"
roles="$(cd "$P/roles" && for r in *; do grep -qE "^${r}_files:" "$r/defaults/main.yml" 2>/dev/null && echo "$r"; done)"
{ printf 'all:\n  children:\n'; for r in $roles; do printf '    %s:\n      hosts:\n        m1:\n' "$r"; done
  printf '  hosts:\n    m1:\n      ansible_connection: local\n      workspace_root: /ws\n'; } > "$P/inventories/t/hosts.yml"
files="$(for r in $roles; do sed -nE 's/^  - (.+)$/\1/p' "$P/roles/$r/defaults/main.yml"; done)"
for f in $files; do mkdir -p "$TMP/ws/$(dirname "$f")"; cp "$REAL/$f" "$TMP/ws/$f"; done
S0="$(cd "$TMP/ws" && md5sum $files)"
run() { docker run --rm -v "$TMP/ws:/ws" -v "$P:/p" -w /p -e ANSIBLE_CONFIG=/p/ansible.cfg -e ANSIBLE_NOCOLOR=1 "$IMG" \
          ansible-playbook -i inventories/t "playbooks/$1.yml" "${@:2}" 2>&1; }
b1=""; b2=""
for r in $roles; do
    o="$(run "$r" --check --diff)"; grep -qE 'm1 +: ok=[0-9]+ +changed=0 ' <<< "$o" || b1+=" $r[$(grep -E '^[-+][A-Za-z_]|fatal|ERROR' <<< "$o" | head -2 | tr '\n' '¦')]"
    o="$(run "$r")";              grep -qE 'm1 +: ok=[0-9]+ +changed=0 ' <<< "$o" || b2+=" $r[$(grep -E 'changed=|fatal' <<< "$o" | head -2 | tr '\n' '¦')]"
done
n="$(wc -w <<< "$roles")"
[ -z "$b1" ] && ok "A1 every project ($n: $(tr '\n' ' ' <<< "$roles"| xargs)) — dry run renders its real files byte for byte → changed=0" || bad "A1:$b1"
[ -z "$b2" ] && ok "A2 every project — apply → changed=0, no restart (nothing changed)" || bad "A2:$b2"
[ "$(cd "$TMP/ws" && md5sum $files)" = "$S0" ] && ok "A3 the copies unchanged — the real files were only read" || bad "A3 a copy changed"

# ── A6: the TEST values (inventories/test/myworkspace + shared/) render the same real files ──────
mkdir -p "$P/inventories/t6"; cp -a "$P/inventories/dev/group_vars" "$HERE/ansible_project/inventories/test/myworkspace" "$HERE/ansible_project/inventories/test/shared" "$P/inventories/t6/"
cp "$P/inventories/t/hosts.yml" "$P/inventories/t6/"
b6=""
for r in $roles; do
    o="$(docker run --rm -v "$TMP/ws:/ws" -v "$P:/p" -w /p -e ANSIBLE_CONFIG=/p/ansible.cfg -e ANSIBLE_NOCOLOR=1 "$IMG" \
          ansible-playbook -i inventories/t6 "playbooks/$r.yml" --check --diff 2>&1)"
    grep -qE 'm1 +: ok=[0-9]+ +changed=0 ' <<< "$o" || b6+=" $r[$(grep -E '^[-+][A-Za-z_]|fatal|ERROR' <<< "$o" | head -2 | tr '\n' '¦')]"
done
[ -z "$b6" ] && ok "A6 every project ($n) renders its real files from the TEST values too → changed=0 (test = dev today; a VM-only value shows here)" || bad "A6:$b6"

# ── A5: deploy.yml with the real dev deploy_projects, on the copies ──────────
mkdir -p "$TMP/ws/ccc/scripts/svcmgt"; [ -f "$TMP/ws/ccc/scripts/svcmgt/svc_policy.conf" ] || cp "$REAL/ccc/scripts/svcmgt/svc_policy.conf" "$TMP/ws/ccc/scripts/svcmgt/"
printf '#!/bin/bash\necho "$*" >> /ws/started\nfor t in "$@"; do echo "$t RUNNING"; done\n' > "$TMP/ws/ccc/scripts/svcmgt/start_targets.sh"
sed -i '/^  children:$/a\    deploy_targets:\n      hosts:\n        m1:' "$P/inventories/t/hosts.yml"
o5="$(run deploy)"
want="$(docker run --rm -v "$P:/p" -w /p "$IMG" ansible-inventory -i inventories/t --host m1 2>/dev/null \
        | python3 -c 'import json,sys; [print(" ".join(p["targets"])) for p in json.load(sys.stdin).get("deploy_projects",[]) if p.get("targets")]')"
got="$(cat "$TMP/ws/started" 2>/dev/null)"
np="$(docker run --rm -v "$P:/p" -w /p "$IMG" ansible-inventory -i inventories/t --host m1 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("deploy_projects",[])))')"
grep -qE 'm1 +: ok=[0-9]+ +changed=0 .*failed=0' <<< "$o5" && [ "$got" = "$want" ] && [ "$(cd "$TMP/ws" && md5sum $files)" = "$S0" ] \
  && ok "A5 deploy.yml with the real dev deploy_projects ($np): changed=0 · targets up in order [$(tr '\n' '|' <<< "$want")] · the copies unchanged" \
  || bad "A5 want=[$want] got=[$got] $(grep -E 'm1 +:|fatal' <<< "$o5" | head -2 | tr '\n' '¦')"
b4="$(find "$HERE/ansible_project/inventories/dev/myworkspace" "$HERE/ansible_project/inventories/dev/shared" -name '*.yml' -exec grep -hE '^ +[A-Za-z_]*(PASS|PASSWORD|SECRET|TOKEN|_KEY|passwd|password|api_key)[A-Za-z_]*: ' {} + \
      | grep -vE '^ +([A-Z_]+_DIR|SECRET_MGT|secret_mgt|ENABLE_EMAIL_PASSWORD): ' | grep -vE ': "\{\{ shared_[a-z_.]+ \}\}' \
      | grep -vE ': "(\$\{KMS_URL\}|https?://[^"]+)/v1/kv/data/' | grep -vE ': ""')"
[ -z "$b4" ] && ok "A4 no secret in the mirror or shared/ — every password / key is a kms address (or empty)" || bad "A4 a secret value: $(cut -d: -f1 <<< "$b4" | tr '\n' ' ')"
b7="$(find "$HERE/ansible_project/inventories/test/myworkspace" "$HERE/ansible_project/inventories/test/shared" -name '*.yml' -exec grep -hE '^ +[A-Za-z_]*(PASS|PASSWORD|SECRET|TOKEN|_KEY|passwd|password|api_key)[A-Za-z_]*: ' {} + \
      | grep -vE '^ +([A-Z_]+_DIR|SECRET_MGT|secret_mgt|ENABLE_EMAIL_PASSWORD): ' | grep -vE ': "\{\{ shared_[a-z_.]+ \}\}' \
      | grep -vE ': "(\$\{KMS_URL\}|https?://[^"]+)/v1/kv/data/' | grep -vE ': ""')"
[ -z "$b7" ] && ok "A7 no secret in the TEST mirror or shared/ either" || bad "A7 a secret value: $(cut -d: -f1 <<< "$b7" | tr '\n' ' ')"
[ "$FAIL" = 0 ] && ok "all-roles tests passed ($n projects; throwaway copies removed)" && exit 0
exit 1
