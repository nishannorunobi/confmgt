#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# lib_run_playbook.sh — SOURCED by check_playbook.sh and apply_playbook.sh: pick a playbook + inventory, ask the agent
#
# How         source lib_run_playbook.sh; run_playbook check|apply [PLAYBOOK [INVENTORY [LIMIT]]]
#
# Steps       1. the agent answers? (no → how to start it)
#             2. what can run: the agent's /playbooks (found in ansible_project/ at run time)
#             3. no names given → asks, Enter = the default (playbook ping · inventory pc · all machines)
#             4. POST /check or /apply → the output, the result, where the full log is
# ─────────────────────────────────────────────────────────────────────────────
run_playbook() {
    local mode="$1"; shift
    local here port url list pb inv lim tty=
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    port="$(grep -E '^AGENT_PORT=' "$here/../.env" 2>/dev/null | cut -d= -f2)"; url="${ANSIBLE_AGENT_URL:-http://127.0.0.1:${port:-8897}}"
    { : </dev/tty; } 2>/dev/null && tty=1
    list="$(curl -fsS --max-time 5 "$url/playbooks" 2>/dev/null)" \
        || { echo -e "\033[31m[ERROR]\033[0m  the ansible-agent does not answer on $url — start it: bash $(cd "$here/../.." && pwd)/start.sh"; return 1; }
    local books invs
    books="$(python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["playbooks"]))' <<< "$list")"
    invs="$(python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["inventories"]))' <<< "$list")"
    pb="${1:-}"; inv="${2:-}"; lim="${3:-}"
    if [ -z "$pb" ]; then
        if [ -z "$tty" ]; then
            if [ "$mode" = apply ]; then
                echo -e "\033[33m[ PLAN ]\033[0m apply needs a terminal to choose (or the names): bash $here/apply_playbook.sh <playbook> <inventory>"
                echo "         playbooks: $books · inventories: $invs"; return 3
            fi
            pb=ping; inv="${inv:-pc}"
        else
            echo -e "\033[36m[ INFO ]\033[0m playbooks: \033[1m$books\033[0m · inventories: \033[1m$invs\033[0m"
            read -r -p "Playbook  [ping]: " pb </dev/tty;  pb="${pb:-ping}"
            read -r -p "Inventory [pc]:   " inv </dev/tty; inv="${inv:-pc}"
            read -r -p "Machines  [all]:  " lim </dev/tty
        fi
    fi
    inv="${inv:-pc}"
    local body out rc
    body="$(python3 -c 'import json,sys; a=sys.argv; print(json.dumps({"playbook":a[1],"inventory":a[2],"limit":a[3] or None}))' "$pb" "$inv" "$lim")"
    echo -e "\033[1m==> $mode: $pb on $inv${lim:+ (machines: $lim)}\033[0m"
    out="$(curl -sS --max-time 3700 -X POST -H 'Content-Type: application/json' --data "$body" "$url/$mode" 2>&1)" || { echo -e "\033[31m[ERROR]\033[0m  $out"; return 1; }
    # the answer comes through stdin (an output can be bigger than one command-line argument may be)
    local ws="$here"; while [ ! -d "$ws/mountspace" ] && [ "$ws" != / ]; do ws="$(dirname "$ws")"; done
    printf '%s' "$out" | WS_ROOT="$ws" python3 -c '
import json, os, sys
raw = sys.stdin.read()
try:
    r = json.loads(raw)
except ValueError:
    print(raw); sys.exit(1)
if "detail" in r:                                   # refused before running (unknown name, busy, no key)
    print("\033[31m[ERROR]\033[0m  " + str(r["detail"])); sys.exit(1)
print(r.get("output", "").rstrip())
ok = r.get("ok")
tag = "\033[32m[  OK  ]\033[0m" if ok else "\033[31m[FAILED]\033[0m"
print("\n%s %s %s on %s: exit %s after %s s · full log: %s" % (tag, r["mode"], r["playbook"], r["inventory"], r["rc"], r["seconds"], r["log"].replace("/mountspace/", os.environ["WS_ROOT"] + "/mountspace/", 1)))
sys.exit(0 if ok else 1)'
}
