#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# test_deploy_playbook.sh — automatic tests: playbooks/deploy.yml per environment + deploy_on_this_pc.sh (CONFMGT [6.2])
#
# What for    Proves on THROWAWAY things only (an SSH test machine, a temp key, a temp copy of the Ansible project, a
#             stand-in agent, a temp authorized_keys) that the dev PC is deployed WITHOUT git and Docker steps, and
#             that deploy_on_this_pc.sh does its three steps. Your PC, its SSH, the live agent and kms are never touched.
#
# Who         Claude (Test 3a in the branch · 3c on the release branch), or you.
#
# How         bash dockerspace/host_scripts/test_deploy_playbook.sh      (~1 min; needs the confmgt image and the SSH
#             test machine's image — test_ansible_container.sh builds it once)
#
# Checks      P1 the real inventories: dev → deploy_targets = dev-pc, git + Docker OFF · test → test-vm, both ON
#             P2 dev-like (switches off) on the SSH machine → git / GitHub / clone / Docker skipped, the workspace there → ok
#             P3 switches not set at all → the same (off is the default) · run again → changed=0
#             P4 no svc_policy.conf in ws_dir → FAILED (the workspace is not there)
#             P5 deploy_on_this_pc.sh: --state stopped before · the key into a temp authorized_keys once · apply deploy dev
#                → OK · --state running · the agent failing → exit 1 · --state partial
#             P6 deploy_projects on the SSH machine (a fake project role + a fake svcmgt/start_targets.sh): in order, config
#                rendered + restart once, targets STARTED · again → changed=0, no restart · a value changed → restart only ·
#                a target that fails → the play stops, the projects after it are not tried
#             P7 the real lists agree: inventories/dev deploy_projects targets == ~/myworkspace svc_policy.conf SVC_VIA_DEPLOY
#             P8 a config-only project's REAL restart handler (default "no" in the start plan) on stub scripts: stopped →
#                nothing started, a message · running → its own stop + start
#             P9 playbooks/stop.yml on the SSH machine (a fake svcmgt/stop_targets.sh): projects in REVERSE order, each one's
#                targets reversed · one failing → the others are STILL stopped, the play ends FAILED · all down → ok
#             P10 stop_on_this_pc.sh: the agent answers → apply stop dev → deploy_on_this_pc.sh --state stopped · the agent
#                is down → nothing started, exit 1, --state partial
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
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"          # confmgt/ansible
PROJ="$HERE/ansible_project"
ok()  { echo -e "\033[32m[  OK  ]\033[0m $*"; }
bad() { echo -e "\033[31m[ERROR]\033[0m  $*"; FAIL=1; }
FAIL=0; MIMG=confmgt-test-sshd-machine:1; NET=my_docker_network; M=confmgt-deploy-test-machine; STUB=
IMG="confmgt-ansible:$(docker images confmgt-ansible --format '{{.Tag}}' | grep -v test | head -1)"
[ "$IMG" != "confmgt-ansible:" ] || { echo "no confmgt-ansible image — build it: bash $HERE/start.sh"; exit 1; }
docker image inspect "$MIMG" >/dev/null 2>&1 || { echo "no $MIMG — run test_ansible_container.sh once (it builds it)"; exit 1; }
WORK="$(mktemp -d)"
cleanup() {
    docker rm -f "$M" >/dev/null 2>&1; [ -n "$STUB" ] && kill "$STUB" 2>/dev/null
    docker run --rm -v "$WORK:/w" alpine:3 rm -rf /w/a >/dev/null 2>&1; rm -rf "$WORK"
}
trap cleanup EXIT

# ── P1: the real inventories ─────────────────────────────────────────────────
inv() { docker run --rm -v "$PROJ:/p:ro" -w /p "$IMG" ansible-inventory -i "inventories/$1" --host "$2" 2>/dev/null; }
grp() { docker run --rm -v "$PROJ:/p:ro" -w /p "$IMG" ansible-inventory -i "inventories/$1" --graph deploy_targets 2>/dev/null; }
d="$(inv dev dev-pc)"; t="$(inv test test-vm)"
grep -q 'dev-pc' <<< "$(grp dev)" && grep -q 'test-vm' <<< "$(grp test)" \
  && grep -q '"ws_manage_git": false' <<< "$d" && grep -q '"ws_manage_docker": false' <<< "$d" \
  && grep -q '"ws_manage_git": true' <<< "$t" && grep -q '"ws_manage_docker": true' <<< "$t" \
  && ok "P1 inventories: dev → dev-pc, git + Docker OFF · test → test-vm, both ON" || bad "P1 dev=$(tr -d '\n ' <<< "$d" | cut -c1-200)"

# ── the SSH test machine + a temp key + a temp project copy with inventory t ──
mkdir -p "$WORK/a"; cp -a "$PROJ" "$WORK/a/project"; ssh-keygen -q -t ed25519 -N '' -C confmgt-ansible -f "$WORK/a/key"
docker run -d --name "$M" --network "$NET" "$MIMG" >/dev/null
docker cp "$WORK/a/key.pub" "$M:/home/ansible/.ssh/authorized_keys" >/dev/null
docker exec "$M" sh -c 'chown ansible /home/ansible/.ssh/authorized_keys && chmod 600 /home/ansible/.ssh/authorized_keys
    mkdir -p /home/ansible/ws/svcmgt /home/ansible/empty && touch /home/ansible/ws/svcmgt/svc_policy.conf && chown -R ansible /home/ansible'
mkinv() {   # NAME "group_vars lines"
    local i="$WORK/a/project/inventories/$1"; mkdir -p "$i/group_vars/deploy_targets"
    printf 'all:\n  children:\n    deploy_targets:\n      hosts:\n        m1:\n          ansible_host: %s\n          ansible_user: ansible\n' "$M" > "$i/hosts.yml"
    printf '%b' "$2" > "$i/group_vars/deploy_targets/workspace.yml"
}
mkinv p2 'ws_manage_git: false\nws_manage_docker: false\nws_dir: /home/ansible/ws\n'
mkinv p3 'ws_dir: /home/ansible/ws\n'
mkinv p4 'ws_manage_git: false\nws_manage_docker: false\nws_dir: /home/ansible/empty\n'
play() {   # INVENTORY [args] — the playbook in a throwaway container of the confmgt image
    docker run --rm --network "$NET" -v "$WORK/a:/a" -w /a/project -e HOME=/tmp -e ANSIBLE_CONFIG=/a/project/ansible.cfg \
        -e ANSIBLE_PRIVATE_KEY_FILE=/a/key -e ANSIBLE_NOCOLOR=1 -e ANSIBLE_LOCAL_TEMP=/tmp/al \
        -e "ANSIBLE_SSH_ARGS=-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/a/known_hosts" \
        "$IMG" ansible-playbook -i "inventories/$1" playbooks/deploy.yml "${@:2}" 2>&1
}
sleep 2

# ── P2: dev-like ─────────────────────────────────────────────────────────────
o2="$(play p2)"
sk() { for n in "git + curl" "GitHub answers" "the workspace — clone" "Docker — the workspace"; do grep -A1 "TASK \[$n" <<< "$1" | grep -q '^skipping: \[m1\]' || echo "$n"; done; }
[ -z "$(sk "$o2")" ] && grep -qE 'm1 +: ok=1 +changed=0 .*failed=0' <<< "$o2" \
  && ok "P2 switches off → git · GitHub · clone · Docker skipped, the workspace is there → the only ok" || bad "P2 $(grep -E 'm1 +:|fatal' <<< "$o2")"

# ── P3: switches not set → off · again → changed=0 ───────────────────────────
o3="$(play p3)"; o3b="$(play p3)"
[ -z "$(sk "$o3")" ] && grep -qE 'm1 +: ok=1 +changed=0 .*failed=0' <<< "$o3" && grep -qE 'm1 +: ok=1 +changed=0 .*failed=0' <<< "$o3b" \
  && ok "P3 switches not set → off (all four skipped) · again → changed=0" || bad "P3 $(grep -E 'm1 +:|fatal' <<< "$o3")"

# ── P4: no workspace ─────────────────────────────────────────────────────────
o4="$(play p4)"
grep -qE 'm1 +: .*failed=1' <<< "$o4" && ok "P4 no svc_policy.conf in ws_dir → FAILED (the workspace is not there)" || bad "P4 $(grep -E 'm1 +:' <<< "$o4")"

# ── P5: deploy_on_this_pc.sh against a stand-in agent ────────────────────────
PORT=18898; SF="$WORK/state"; AKF="$WORK/akhome/.ssh/authorized_keys"; echo ok > "$WORK/mode"
cat > "$WORK/stub.py" <<'EOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
W, PORT = sys.argv[1], int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        b = body.encode(); self.send_response(code); self.send_header("Content-Type", ctype); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path == "/health": self._send(200, '{"status": "ok"}')
        elif self.path == "/public-key": self._send(200, open(f"{W}/a/key.pub").read(), "text/plain")
        elif self.path == "/playbooks": self._send(200, json.dumps({"playbooks": ["deploy"], "inventories": ["dev"]}))
        else: self._send(404, "{}")
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        open(f"{W}/asked", "w").write(json.dumps(req))
        good = open(f"{W}/mode").read().strip() == "ok"
        self._send(200, json.dumps({"ok": good, "mode": "apply", "playbook": req["playbook"], "inventory": req["inventory"],
                                    "rc": 0 if good else 2, "seconds": 0.1, "output": "PLAY RECAP", "log": "/mountspace/logs/x.log"}))
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", PORT), H).serve_forever()
EOF
python3 "$WORK/stub.py" "$WORK" "$PORT" >/dev/null 2>&1 & STUB=$!; sleep 1
run5() { ANSIBLE_AGENT_URL="http://127.0.0.1:$PORT" AUTHORIZED_KEYS_FILE="$AKF" DEPLOY_STATE_FILE="$SF" bash "$HERE/deploy_on_this_pc.sh" "$@" </dev/null 2>&1; }
s0="$(run5 --state)"; o5="$(run5)"; r5=$?; s1="$(run5 --state)"; o5b="$(run5)"
echo bad > "$WORK/mode"; o5c="$(run5)"; r5c=$?; s2="$(run5 --state)"
[ "$s0" = stopped ] && [ $r5 = 0 ] && grep -q "key added to $AKF" <<< "$o5" && grep -q "already in $AKF" <<< "$o5b" \
  && [ "$(grep -c confmgt-ansible "$AKF")" = 1 ] && grep -q '"playbook": "deploy", "inventory": "dev"' "$WORK/asked" \
  && grep -q 'OK.*apply deploy on dev' <<< "$o5" && [ "$s1" = running ] && [ $r5c = 1 ] && [ "$s2" = partial ] \
  && ok "P5 deploy_on_this_pc.sh: --state stopped → key added once (temp authorized_keys) → apply deploy dev OK → running · agent fails → exit 1, partial" \
  || bad "P5 s0=$s0 r5=$r5 s1=$s1 r5c=$r5c s2=$s2 · $(tail -2 <<< "$o5" | tr '\n' '¦')"

# ── P6: the project loop ─────────────────────────────────────────────────────
R="$WORK/a/project/roles/fakeproj"; mkdir -p "$R/tasks" "$R/handlers" "$R/templates"
printf -- '- name: fake config\n  ansible.builtin.template:\n    src: fake.j2\n    dest: "{{ ws_dir }}/{{ fake_file }}"\n  notify: restart fakeproj\n' > "$R/tasks/main.yml"
printf -- '- name: restart fakeproj\n  ansible.builtin.shell: echo "restart {{ fake_file }}" >> {{ ws_dir }}/events\n' > "$R/handlers/main.yml"
printf 'value={{ fake_value }}\n' > "$R/templates/fake.j2"
docker exec "$M" sh -c '[ -e /bin/bash ] || { printf "#!/bin/sh\nexec sh \"\$@\"\n" > /bin/bash; chmod 755 /bin/bash; }'   # alpine: the playbook calls bash
docker exec -u ansible "$M" sh -c 'cat > /home/ansible/ws/svcmgt/start_targets.sh <<"X"
cd "$(dirname "$0")/.."; for t in "$@"; do
  [ "$t" = bad ] && { echo "$t FAILED"; exit 1; }
  if [ -f "up_$t" ]; then echo "$t RUNNING"; else touch "up_$t"; echo "start $t" >> events; echo "$t STARTED"; fi
done
X'
p6() {   # VALUE [extra project]
    mkinv p6 "ws_manage_git: false\nws_dir: /home/ansible/ws\nfake_value: $1\ndeploy_projects:\n  - {name: one, role: fakeproj, targets: [a1, a2]}\n${2:-}  - {name: two, role: fakeproj, targets: [b1]}\n"
    mkdir -p "$WORK/a/project/inventories/p6/shared"; play p6 -e fake_file=fake.conf
}
ev() { docker exec "$M" sh -c 'cat /home/ansible/ws/events 2>/dev/null' | tr '\n' ',' ; }
o6="$(p6 1)"; e1="$(ev)"; o6b="$(p6 1)"; e2="$(ev)"; o6c="$(p6 2)"; e3="$(ev)"
docker exec "$M" sh -c 'rm -f /home/ansible/ws/up_* /home/ansible/ws/events'
o6d="$(p6 1 '  - {name: broken, role: fakeproj, targets: [bad]}\n')"; e4="$(ev)"
[ "$e1" = "restart fake.conf,start a1,start a2,start b1," ] && grep -qE 'm1 +: .*failed=0' <<< "$o6" \
  && [ "$e2" = "$e1" ] && grep -qE 'm1 +: ok=[0-9]+ +changed=0 .*failed=0' <<< "$o6b" \
  && [ "$e3" = "${e1}restart fake.conf," ] && grep -qE 'm1 +: .*failed=0' <<< "$o6c" \
  && [ "$e4" = "restart fake.conf,start a1,start a2," ] && grep -qE 'm1 +: .*failed=1' <<< "$o6d" \
  && ok "P6 deploy_projects: in order · config + restart once · STARTED · again changed=0 · a value changed → restart only · a failing target stops the play" \
  || bad "P6 e1=[$e1] e2=[$e2] e3=[$e3] e4=[$e4] $(grep -E 'm1 +:|fatal|ERROR' <<< "$o6$o6d" | head -3 | tr '\n' '¦')"

# ── P7: the two lists agree ──────────────────────────────────────────────────
inv_t="$(inv dev dev-pc | python3 -c 'import json,sys; print(" ".join(sorted(t for p in json.load(sys.stdin).get("deploy_projects",[]) for t in p.get("targets",[]))))')"
pol_t="$(bash -c 'source "$1"; printf "%s\n" "${SVC_VIA_DEPLOY[@]:-}" | sort | xargs' _ "$_WS_ROOT/svcmgt/svc_policy.conf")"
[ "$inv_t" = "$pol_t" ] && ok "P7 inventories/dev deploy_projects targets == svc_policy.conf SVC_VIA_DEPLOY [${inv_t:-none}]" \
  || bad "P7 inventory [$inv_t] ≠ svc_policy.conf [$pol_t]"

# ── P8: restart handlers that must never START a stopped project ────────────
h8=""
for spec in "myodoo:projectspace/myodoo:--19" "mylog_analytics:projectspace/mylog_analytics:"; do
    IFS=: read -r role dir arg <<< "$spec"
    docker exec -u ansible "$M" sh -c "mkdir -p /home/ansible/ws/$dir && cd /home/ansible/ws/$dir && rm -f calls
        printf '#!/bin/sh\ncat state\n' > status.sh; printf '#!/bin/sh\necho \"stop \$*\" >> calls\n' > stop.sh; printf '#!/bin/sh\necho \"start \$*\" >> calls\n' > start.sh"
    printf -- '- hosts: deploy_targets\n  gather_facts: false\n  vars: {workspace_root: /home/ansible/ws}\n  tasks:\n    - ansible.builtin.include_tasks: ../roles/%s/handlers/main.yml\n' "$role" > "$WORK/a/project/playbooks/h8.yml"
    for s in stopped running; do
        docker exec -u ansible "$M" sh -c "cd /home/ansible/ws/$dir && echo 'x $s' > state && rm -f calls"
        o8="$(docker run --rm --network "$NET" -v "$WORK/a:/a" -w /a/project -e HOME=/tmp -e ANSIBLE_CONFIG=/a/project/ansible.cfg \
            -e ANSIBLE_PRIVATE_KEY_FILE=/a/key -e ANSIBLE_NOCOLOR=1 -e ANSIBLE_LOCAL_TEMP=/tmp/al \
            -e "ANSIBLE_SSH_ARGS=-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/a/known_hosts" \
            "$IMG" ansible-playbook -i inventories/p2 playbooks/h8.yml -v 2>&1)"
        c="$(docker exec "$M" sh -c "cat /home/ansible/ws/$dir/calls 2>/dev/null" | tr '\n' ',')"
        case "$s" in
            stopped) [ -z "$c" ] && grep -q 'is stopped — not started' <<< "$o8" || h8+=" $role/stopped[$c]" ;;
            running) [ "$c" = "stop $arg,start $arg," ] || h8+=" $role/running[$c]" ;;
        esac
    done
done
rm -f "$WORK/a/project/playbooks/h8.yml"
[ -z "$h8" ] && ok "P8 restart handlers of config-only projects (myodoo · mylog_analytics): stopped → nothing started, a message · running → own stop + start" \
  || bad "P8:$h8"

# ── P9: stop.yml ─────────────────────────────────────────────────────────────
docker exec -u ansible "$M" sh -c 'rm -f /home/ansible/ws/events; cat > /home/ansible/ws/svcmgt/stop_targets.sh <<"X"
cd "$(dirname "$0")/.."; rc=0; for t in "$@"; do
  if [ "$t" = bad ]; then echo "$t FAILED"; rc=1; else echo "stop $t" >> events; echo "$t DOWN"; fi
done; exit $rc
X'
pb() { docker run --rm --network "$NET" -v "$WORK/a:/a" -w /a/project -e HOME=/tmp -e ANSIBLE_CONFIG=/a/project/ansible.cfg \
        -e ANSIBLE_PRIVATE_KEY_FILE=/a/key -e ANSIBLE_NOCOLOR=1 -e ANSIBLE_LOCAL_TEMP=/tmp/al \
        -e "ANSIBLE_SSH_ARGS=-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/a/known_hosts" \
        "$IMG" ansible-playbook -i inventories/p9 playbooks/stop.yml 2>&1; }
mkinv p9 "ws_dir: /home/ansible/ws\ndeploy_projects:\n  - {name: one, targets: [a1, a2]}\n  - {name: cfg, targets: []}\n  - {name: two, targets: [b1]}\n"
o9="$(pb)"; e9="$(ev)"; docker exec "$M" sh -c 'rm -f /home/ansible/ws/events'
mkinv p9 "ws_dir: /home/ansible/ws\ndeploy_projects:\n  - {name: one, targets: [a1, a2]}\n  - {name: broken, targets: [bad]}\n  - {name: two, targets: [b1]}\n"
o9b="$(pb)"; e9b="$(ev)"
[ "$e9" = "stop b1,stop a2,stop a1," ] && grep -qE 'm1 +: .*failed=0' <<< "$o9" \
  && [ "$e9b" = "stop b1,stop a2,stop a1," ] && grep -qE 'm1 +: .*failed=1' <<< "$o9b" && grep -q 'not every project stopped' <<< "$o9b" \
  && ok "P9 stop.yml: reverse order (two, then one's a2 → a1), config-only skipped · one failing → the others still stopped, the play FAILED" \
  || bad "P9 e9=[$e9] e9b=[$e9b] $(grep -E 'm1 +:' <<< "$o9$o9b" | tr '\n' '¦')"

# ── P10: stop_on_this_pc.sh ──────────────────────────────────────────────────
echo ok > "$WORK/mode"; rm -f "$SF"
run10() { ANSIBLE_AGENT_URL="$1" DEPLOY_STATE_FILE="$SF" bash "$HERE/stop_on_this_pc.sh" </dev/null 2>&1; }
o10="$(run10 "http://127.0.0.1:$PORT")"; r10=$?; s10="$(DEPLOY_STATE_FILE="$SF" bash "$HERE/deploy_on_this_pc.sh" --state)"
asked="$(cat "$WORK/asked")"
o10b="$(run10 "http://127.0.0.1:1")"; r10b=$?; s10b="$(DEPLOY_STATE_FILE="$SF" bash "$HERE/deploy_on_this_pc.sh" --state)"
[ $r10 = 0 ] && grep -q '"playbook": "stop", "inventory": "dev"' <<< "$asked" && [ "$s10" = stopped ] \
  && [ $r10b = 1 ] && grep -q 'nothing stopped by Ansible' <<< "$o10b" && [ "$s10b" = partial ] \
  && ok "P10 stop_on_this_pc.sh: apply stop dev → --state stopped · agent down → nothing started, exit 1, --state partial" \
  || bad "P10 r10=$r10 s10=$s10 r10b=$r10b s10b=$s10b asked=$asked"

[ $FAIL = 0 ] && ok "deploy playbook tests passed (throwaway machine + stand-in agent removed)" || { echo -e "\033[31m[FAILED]\033[0m deploy playbook tests"; exit 1; }
