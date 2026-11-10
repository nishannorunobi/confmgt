#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# test_ports.sh — every published port is in ONE place (inventories/<env>/shared/ports.yml) and nowhere twice
#
# What for    CONFMGT [9]: a port changes in one line; clashes are caught before anything starts.
#
# Who         Claude (3a / 3c of epic [9]), or you. Reads files only — no Ansible run, no container.
#
# How         bash ccc/confmgt/ansible/tests/test_ports.sh
#
# Checks      P1 every inventory has shared/ports.yml with shared_ports: (key → port)
#             P2 no two ports equal in one inventory (today one inventory = one machine)
#             P3 no port of ports.yml typed again in that inventory's shared/ or mirror (only {{ shared_ports.<key> }}):
#                a *port*: key or a URL on this machine (localhost · 127.0.0.1 · 0.0.0.0); container-name URLs and
#                shared/hosts.yml are INSIDE-container ports (facts of the image), not checked
#             P4 dev and test list the same keys
#             P5 self-test: a throwaway copy with a duplicate port → P2 FAILS
#
# Output      [  OK  ] / [ FAIL ] per check, then ALL PASS (exit 0) or N FAIL (exit 1)
# ─────────────────────────────────────────────────────────────────────────────
case "${1:-}" in -h|--help) sed -n '2,/^# ─/{/^# ─/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;; esac
set -uo pipefail

# ── Mirror logging ────────────────────────────────────────────────────────────
_WS_ROOT="$(d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; while [ ! -d "$d/mountspace" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done; echo "$d")"
if [ -f "$_WS_ROOT/ccc/scripts/lib/create_logging_path.sh" ]; then
    source "$_WS_ROOT/ccc/scripts/lib/create_logging_path.sh"
    setup_logging
fi
# ──────────────────────────────────────────────────────────────────────────────
INV="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ansible_project/inventories" && pwd)"

# the checks, for one inventories folder → prints OK/FAIL lines, exit = number of FAILs
check() {
python3 - "$1" <<'EOF'
import sys, re, pathlib, yaml
inv = pathlib.Path(sys.argv[1]); fails = 0
def ok(m):   print(f"\033[32m[  OK  ]\033[0m {m}")
def bad(m):
    global fails; fails += 1; print(f"\033[31m[ FAIL ]\033[0m {m}")
keys = {}
for env in sorted(p.name for p in inv.iterdir() if (p / "hosts.yml").exists()):
    f = inv / env / "shared" / "ports.yml"
    ports = (yaml.safe_load(f.read_text()) or {}).get("shared_ports") if f.exists() else None
    if not isinstance(ports, dict) or not ports:
        bad(f"P1 {env}: no shared/ports.yml with shared_ports:"); continue
    ok(f"P1 {env}: shared/ports.yml — {len(ports)} ports"); keys[env] = set(ports)
    seen = {}
    for k, v in ports.items(): seen.setdefault(str(v), []).append(k)
    dup = {v: ks for v, ks in seen.items() if len(ks) > 1}
    bad(f"P2 {env}: same port twice — " + " · ".join(f"{v}: {', '.join(ks)}" for v, ks in dup.items())) if dup \
        else ok(f"P2 {env}: no two ports equal")
    typed = []
    for p in sorted((inv / env).rglob("*.y*ml")):
        if p == f or p.name == "hosts.yml" and p.parent.name == "shared" or "group_vars" in p.parts or "host_vars" in p.parts or p.name == "hosts.yml": continue
        for n, line in enumerate(p.read_text().splitlines(), 1):
            code = line.split("#", 1)[0]
            for v in map(str, ports.values()):
                # a URL on this machine (localhost · 127.0.0.1 · 0.0.0.0) or a *port*: key — a container name = inside the network
                if re.search(rf'((localhost|127\.0\.0\.1|0\.0\.0\.0):{v}\b|port\w*: *"?{v}"?\s*$)', code, re.I):
                    typed.append(f"{p.relative_to(inv)}:{n} ({v})")
    bad(f"P3 {env}: port typed again — " + " · ".join(typed)) if typed \
        else ok(f"P3 {env}: every port only through {{{{ shared_ports.<key> }}}}")
if len(keys) > 1:
    a, b = list(keys.values())[:2]
    bad(f"P4 keys differ: {' '.join(sorted(a ^ b))}") if a != b else ok(f"P4 {' and '.join(keys)}: the same keys")
sys.exit(fails)
EOF
}

check "$INV"; FAIL=$?

# P5 — self-test on a throwaway copy: a duplicate port must be caught
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -r "$INV" "$TMP/inv"
first="$(sed -n 's/^  \([a-z_]*\): "\([0-9]*\)".*/\2/p' "$TMP/inv/dev/shared/ports.yml" | head -1)"
printf '  zz_duplicate: "%s"\n' "$first" >> "$TMP/inv/dev/shared/ports.yml"
P5_OUT="$(check "$TMP/inv" 2>&1)"
if grep -q 'P2 dev: same port twice' <<<"$P5_OUT"; then
    echo -e "\033[32m[  OK  ]\033[0m P5 self-test: a duplicate port ($first) is caught"
else
    echo -e "\033[31m[ FAIL ]\033[0m P5 self-test: a duplicate port ($first) was NOT caught"; FAIL=$((FAIL+1))
fi

echo
[ "$FAIL" -eq 0 ] && { echo -e "\033[32m[  OK  ]\033[0m ALL PASS"; exit 0; }
echo -e "\033[31m[ FAIL ]\033[0m $FAIL FAIL"; exit 1
