"""
Ansible Agent HTTP API — runs inside the confmgt-ansible container on port 8897
(started by supervisor.py, the container's entry point).

What for   The one door to Ansible: the owner's scripts (check_playbook.sh, apply_playbook.sh, show_public_key.sh)
           and, later, the workspace call it. It runs ansible-playbook from the Ansible project
           (/ansible_project, read-only) with the SSH key in RAM — never shown, never on disk.

Endpoints
  GET  /health        alive · the Ansible version · SSH key ready · a run going on
  GET  /public-key    the public key to put into ~/.ssh/authorized_keys on each machine (safe to show)
  GET  /playbooks     what can run: playbooks/*.yml and inventories/<env>/ — found at run time (a new file = a new choice)
  POST /check         {"playbook": "ping", "inventory": "test", "limit": "test-vm"}  → dry run (--check --diff)
  POST /apply         the same body → the real run
  GET  /runs/last     the last run: what, when, exit code, output

Rules     names only from the lists above (anything else → 400) · one run at a time (busy → 409) ·
          a run longer than RUN_TIMEOUT seconds (agent.conf, default 1800) is stopped · every run's output is kept
          in its own log file (the newest 50 kept)
"""
import glob
import json
import os
import re
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import PlainTextResponse, RedirectResponse
from pydantic import BaseModel

PROJECT = Path(os.environ.get("ANSIBLE_PROJECT_DIR", "/ansible_project"))
DATA = Path(os.environ.get("ANSIBLE_DATA_DIR", "/data"))
KEY_DIR = Path(os.environ.get("ANSIBLE_SSH_DIR", "/run/ansible-ssh"))
LOG_ROOT = os.environ.get("LOG_MIRROR_ROOT", "")
RUN_LOGS = Path(LOG_ROOT) / "ansible-agent" / "runs" if LOG_ROOT else DATA / "runs"
KEEP_RUNS = 50
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")              # a playbook / inventory name
LIMIT = re.compile(r"^[A-Za-z0-9_.,:*!&\[\]-]+$")              # Ansible's --limit pattern, plain characters only


def _timeout() -> int:
    v = os.environ.get("RUN_TIMEOUT", "1800").strip()
    if v.isdigit() and int(v) > 0:
        return int(v)
    print(f"[agent] WARN: RUN_TIMEOUT={v} is not a number of seconds — using 1800", flush=True)
    return 1800


RUN_TIMEOUT = _timeout()
_lock = threading.Lock()
_last: dict = {}

app = FastAPI(title="Ansible Agent", version="1.0.0")


def playbooks() -> list:
    return sorted({Path(p).stem for p in glob.glob(str(PROJECT / "playbooks" / "*.y*ml"))})


def inventories() -> list:
    return sorted(Path(p).parent.name for p in glob.glob(str(PROJECT / "inventories" / "*" / "hosts.y*ml")))


def _playbook_file(name: str) -> Path:
    for ext in ("yml", "yaml"):
        f = PROJECT / "playbooks" / f"{name}.{ext}"
        if f.is_file():
            return f
    raise HTTPException(400, f"no playbook '{name}' — known: {', '.join(playbooks()) or 'none'}")


def _ansible_version() -> str:
    try:
        out = subprocess.run(["ansible", "--version"], capture_output=True, text=True, timeout=20).stdout
        return out.splitlines()[0].strip() if out else "unknown"
    except Exception:
        return "unknown"


ANSIBLE_VERSION = _ansible_version()


class Run(BaseModel):
    playbook: str
    inventory: str = "test"
    limit: str | None = None


def _prune():
    logs = sorted(RUN_LOGS.glob("*.log"))
    for old in logs[:-KEEP_RUNS]:
        old.unlink(missing_ok=True)


def _run(req: Run, check: bool) -> dict:
    if not NAME.match(req.playbook or ""):
        raise HTTPException(400, "playbook: letters, digits, _ . - only")
    if not NAME.match(req.inventory or "") or req.inventory not in inventories():
        raise HTTPException(400, f"no inventory '{req.inventory}' — known: {', '.join(inventories()) or 'none'}")
    if req.limit is not None and not LIMIT.match(req.limit):
        raise HTTPException(400, "limit: host / group names and , : * ! & only")
    book = _playbook_file(req.playbook)
    key = KEY_DIR / "id_ed25519"
    if not key.is_file():
        raise HTTPException(503, "no SSH key in RAM — the agent did not start right: docker logs confmgt-ansible")
    if not _lock.acquire(blocking=False):
        raise HTTPException(409, f"another run is going on: {_last.get('mode')} {_last.get('playbook')} — try again later")
    try:
        mode = "check" if check else "apply"
        cmd = ["ansible-playbook", "-i", str(PROJECT / "inventories" / req.inventory), str(book)]
        if check:
            cmd += ["--check", "--diff"]
        if req.limit:
            cmd += ["--limit", req.limit]
        env = dict(os.environ)
        env.update({
            "ANSIBLE_CONFIG": str(PROJECT / "ansible.cfg"),
            "ANSIBLE_PRIVATE_KEY_FILE": str(key),
            # trust on first use: a new machine's host key is remembered; a CHANGED one is refused
            "ANSIBLE_SSH_ARGS": f"-o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=accept-new "
                                f"-o UserKnownHostsFile={DATA / 'known_hosts'}",
            "ANSIBLE_NOCOLOR": "1",
            "ANSIBLE_LOCAL_TEMP": "/tmp/ansible-local",
        })
        started = datetime.now()
        _last.clear()
        _last.update({"mode": mode, "playbook": req.playbook, "inventory": req.inventory, "limit": req.limit,
                      "started": started.isoformat(timespec="seconds"), "running": True})
        print(f"[agent] {mode}: {req.playbook} on {req.inventory}{' --limit ' + req.limit if req.limit else ''}", flush=True)
        t0 = time.monotonic()
        try:
            r = subprocess.run(cmd, cwd=str(PROJECT), env=env, capture_output=True, text=True, timeout=RUN_TIMEOUT)
            rc, out = r.returncode, r.stdout + r.stderr
        except subprocess.TimeoutExpired as e:
            rc = 124
            out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
            out += f"\n[agent] stopped: longer than RUN_TIMEOUT={RUN_TIMEOUT} s\n"
        secs = round(time.monotonic() - t0, 1)
        RUN_LOGS.mkdir(parents=True, exist_ok=True)
        log = RUN_LOGS / f"{started:%Y-%m-%d_%H%M%S}_{mode}_{req.playbook}_{req.inventory}.log"
        log.write_text(f"$ {' '.join(cmd)}\n\n{out}\n[agent] exit {rc} after {secs} s\n")
        _prune()
        _last.update({"running": False, "rc": rc, "ok": rc == 0, "seconds": secs, "log": str(log), "output": out})
        print(f"[agent] {mode} {req.playbook} on {req.inventory}: {'OK' if rc == 0 else f'FAILED (exit {rc})'} "
              f"after {secs} s — {log}", flush=True)
        return dict(_last)
    finally:
        _lock.release()


@app.get("/")
def root():
    return RedirectResponse("/docs")


@app.get("/health")
def health():
    return {"status": "ok", "agent": "ansible-agent", "tool": "ansible", "ansible": ANSIBLE_VERSION,
            "ssh_key": (KEY_DIR / "id_ed25519").is_file(), "running": _lock.locked(),
            "time": datetime.now().isoformat(timespec="seconds")}


@app.get("/public-key", response_class=PlainTextResponse)
def public_key():
    pub = KEY_DIR / "id_ed25519.pub"
    if not pub.is_file():
        raise HTTPException(503, "no SSH key yet — docker logs confmgt-ansible says why")
    return pub.read_text()


@app.get("/playbooks")
def list_playbooks():
    return {"playbooks": playbooks(), "inventories": inventories()}


@app.post("/check")
def check(req: Run):
    return _run(req, check=True)


@app.post("/apply")
def apply(req: Run):
    return _run(req, check=False)


@app.get("/runs/last")
def last_run():
    if not _last:
        raise HTTPException(404, "no run yet")
    return _last
