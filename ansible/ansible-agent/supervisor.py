#!/opt/venv/bin/python
# ─────────────────────────────────────────────────────────────────────────────
# supervisor.py — the ansible-agent as the container's entry point: Ansible's assistant
#
# What for    Ansible needs an SSH key to reach the machines, but the key must never sit on disk or in git.
#             The agent runs first, gets the key's secret from kms, makes the key in RAM, serves its API
#             (check / apply a playbook) and keeps the API alive. Ansible itself runs only when asked.
#
# Who         docker compose (confmgt/ansible/docker-compose.yml "command") — always on.
#
# How         /opt/venv/bin/python /ansible-agent/supervisor.py        (in the container)
#
# Steps       0. (SECRET_MGT=kms only) no kms login yet → signs itself up: the owner's kms password from kms's
#                master_password (read-only mount, KMS_MASTER_PASSWORD_FILE) → its own connect_external/kms/signup_with_kms.sh
#             1. agent.conf → settings; SECRET_MGT: local (also when not set) → the value as written, no kms ·
#                kms → the kms address → its value (kms.py, own login) — a key kms does not have →
#                connect_external/kms/register_kms_ansible_keys_with_random_initial.sh (owner login from
#                master_password): created with an initial random value, fetched again
#             2. ANSIBLE_SSH_KEY_SECRET → the SSH key (ed25519: its 32-byte seed = SHA-256 of the secret) in RAM:
#                /run/ansible-ssh/id_ed25519 (600) + id_ed25519.pub — never on disk, never printed
#             3. start the agent API (uvicorn server:app :PORT) as a child
#             4. watch: API exits → started again after 2 s · SIGTERM → the API stops, then exit 0
#
# Output      [agent] ANSIBLE_SSH_KEY_SECRET ← kms (confmgt/ansible)      names only, never values
#             [agent] SSH key ready in RAM — public key: ssh-ed25519 AAAA… confmgt-ansible
#             [agent] API started on :8897 (pid 20)
#
# Errors      kms SEALED / unreachable / no login / no access → exit 1 with the reason; compose restarts the
#             container, so unsealing is enough · the secret is empty → exit 1 (no key, no Ansible)
#
# Next        docker logs confmgt-ansible  ·  http://localhost:8897/health
# ─────────────────────────────────────────────────────────────────────────────
import hashlib
import os
import re
import signal
import subprocess
import sys
import time

AGENT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(AGENT_DIR, "connect_external", "kms"))
import kms  # noqa: E402

KEY_DIR = os.environ.get("ANSIBLE_SSH_DIR", "/run/ansible-ssh")      # RAM (tmpfs /run)
KEY_COMMENT = "confmgt-ansible"


def say(msg):
    print(f"[agent] {msg}", file=sys.stderr, flush=True)


def usage():
    seen = False
    for line in open(__file__):
        if line.startswith("# ─"):
            if seen:
                break
            seen = True
            continue
        if seen:
            print(line[2:].rstrip())


def write_private(path, data, mode=0o600):
    tmp = path + ".new"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.chmod(tmp, mode)            # os.open applies the umask — set the mode explicitly
    os.replace(tmp, path)


def settings():
    """agent.conf + the environment (compose env_file). Values may be kms addresses."""
    from dotenv import dotenv_values
    env = dict(os.environ)
    env.update({k: v for k, v in dotenv_values(os.path.join(AGENT_DIR, "agent.conf")).items() if v is not None})
    return env


CRED_DIR = os.path.join(AGENT_DIR, "connect_external", "kms", "credentials")


def owner_login(env, by_hand):
    """The owner's kms login for a one-off write (sign-up / register): the password from kms's master_password folder,
    mounted READ-ONLY (KMS_MASTER_PASSWORD_FILE). Empty / missing → one line naming the file + the by-hand command,
    exit 1. Returns (kms base URL, token). The password is never printed or logged."""
    import json, urllib.request
    pw_file = os.environ.get("KMS_MASTER_PASSWORD_FILE", "")
    host_hint = "mountspace/usb/myworkspace/projectspace/kms/master_password/master_password (on the PC)"
    pw = ""
    if pw_file and os.path.isfile(pw_file):
        with open(pw_file) as f:
            pw = f.readline().rstrip("\r\n")
    if not pw.strip():
        why = "not mounted" if not pw_file or not os.path.isfile(pw_file) else "empty"
        say(f"ERROR: kms's master_password is {why} — put your kms password into {host_hint}, then start again"
            f" (or by hand on the PC: {by_hand})")
        sys.exit(1)
    base = next((v.split("/v1/")[0] for v in env.values() if kms.is_address(v)), "")
    if not base:
        say("ERROR: agent.conf names no kms address")
        sys.exit(1)
    owner = os.environ.get("KMS_OWNER", "nishan")
    try:
        req = urllib.request.Request(f"{base}/v1/auth/userpass/login/{owner}", data=json.dumps({"password": pw}).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=10) as r:
            token = json.load(r)["auth"]["client_token"]
    except Exception as e:
        del pw
        say(f"ERROR: kms refused the login with the password from master_password ({type(e).__name__}) — check {host_hint}")
        sys.exit(1)
    del pw
    return base, token


def revoke(base, token):
    import urllib.request
    try:                                          # the login is not needed any more
        urllib.request.urlopen(urllib.request.Request(f"{base}/v1/auth/token/revoke-self", data=b"{}",
                               headers={"X-Vault-Token": token}, method="POST"), timeout=10).close()
    except Exception:
        pass


def run_kms_script(name, base, token, args=()):
    """connect_external/kms/<name> with the owner login handed over (KMS_TOKEN) — its lines shown indented."""
    child = dict(os.environ)
    child.update({"KMS_TOKEN": token, "KMS_URL": base})
    r = subprocess.run(["bash", os.path.join(AGENT_DIR, "connect_external", "kms", name), *args],
                       env=child, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    del child
    for line in (r.stdout + r.stderr).splitlines():
        if line.strip() and "[logging]" not in line:
            say("  " + re.sub(r"\x1b\[[0-9;]*m", "", line))
    return r.returncode


def ensure_login(env):
    """No kms login yet → the agent signs itself up with the owner's kms password from kms's master_password
    (read-only) and its own connect_external/kms/signup_with_kms.sh. The new login files get the agent folder's owner
    (this container runs as root). Already signed up → nothing. The password is never printed or logged."""
    import glob
    if glob.glob(os.path.join(CRED_DIR, "*", "secret_id")):
        return
    owner = os.environ.get("KMS_OWNER", "nishan")
    say(f"no kms login yet — signing up with kms as {owner}, password from kms's master_password")
    base, token = owner_login(env, "bash start.sh (asks your kms password)")
    rc = run_kms_script("signup_with_kms.sh", base, token)
    revoke(base, token)
    del token
    if rc != 0 or not glob.glob(os.path.join(CRED_DIR, "*", "secret_id")):
        say("ERROR: the kms sign-up failed — the lines above say why")
        sys.exit(1)
    st = os.stat(AGENT_DIR)                       # the host user who owns the project folder
    for root, dirs, files in os.walk(CRED_DIR):
        for n in [root] + [os.path.join(root, x) for x in dirs + files]:
            os.chown(n, st.st_uid, st.st_gid)
    say("signed up with kms — login saved in connect_external/kms/credentials/ (600)")


SECRET_NAME = re.compile(r"(PASS|PASSWD|PASSWORD|SECRET|TOKEN|_KEY)$", re.I)   # a password-like setting


def secret_mode(env):
    """agent.conf's SECRET_MGT: kms → the secret lines are kms addresses (sign-up, register, fetch) · local → they
    hold the real values, used as written, no kms at all · missing / empty → local · unknown → WARN, local.
    A wrong mix stops with one clear line: a kms address in local mode, a plain secret in kms mode."""
    from dotenv import dotenv_values
    conf = {k: (v or "") for k, v in dotenv_values(os.path.join(AGENT_DIR, "agent.conf")).items()}
    v = conf.get("SECRET_MGT", "").strip().lower()
    mode = v if v in ("kms", "local") else "local"
    if v and v not in ("kms", "local"):
        say(f"WARN: SECRET_MGT={v} is not known (kms · local) — using local")
    for k, val in conf.items():
        if mode == "local" and kms.is_address(val):
            say(f"ERROR: SECRET_MGT={v or 'local (not set)'} but {k} is a kms address — set SECRET_MGT=kms in agent.conf, or write the real value")
            sys.exit(1)
        if mode == "kms" and SECRET_NAME.search(k) and val.strip() and not kms.is_address(val):
            say(f"ERROR: SECRET_MGT=kms but {k} is not a kms address — write ${{KMS_URL}}/v1/kv/data/<entry>, or set SECRET_MGT=local")
            sys.exit(1)
    say(f"secrets: {mode} (SECRET_MGT{'=' + v if v else ' not set'})")
    return mode


MISSING = (" is not in kms", "no key ")             # kms.py's words for a key kms does not have (a 403 "may not read" is not)


def fetch(env):
    """Every kms address → its value. A key kms does not have → registered once with an initial random value
    (connect_external/kms/register_kms_ansible_keys_with_random_initial.sh), then fetched again — a fresh kms never
    stops the agent."""
    try:
        secrets, where = kms.resolve(env)
    except kms.KmsError as e:
        if not any(m in str(e) for m in MISSING):
            say(f"ERROR: {e}")
            sys.exit(1)
        missing = []
        for name in sorted(k for k, v in env.items() if kms.is_address(v)):
            try:
                kms.resolve({name: env[name]}, fresh=True)
            except kms.KmsError as e1:
                if not any(m in str(e1) for m in MISSING):
                    say(f"ERROR: {e1}")
                    sys.exit(1)
                missing.append(name)
        say(f"{', '.join(missing)}: not in kms — registering with an initial random value")
        base, token = owner_login(env, f"bash connect_external/kms/register_kms_ansible_keys_with_random_initial.sh {' '.join(missing)}")
        rc = run_kms_script("register_kms_ansible_keys_with_random_initial.sh", base, token, missing)
        revoke(base, token)
        del token
        if rc != 0:
            say("ERROR: registering the missing keys failed — the lines above say why")
            sys.exit(1)
        try:
            secrets, where = kms.resolve(env, fresh=True)
        except kms.KmsError as e2:
            say(f"ERROR: {e2}")
            sys.exit(1)
    for name in secrets:
        say(f"{name} ← kms ({where[name][len('kv/data/'):]})")
    return secrets


def make_ssh_key(secret):
    """ANSIBLE_SSH_KEY_SECRET → Ansible's SSH key in RAM. An ed25519 private key IS a 32-byte seed (RFC 8032):
    the seed = SHA-256 of the secret, so the same secret always gives the same key, and a new secret a new key.
    Returns the public key line (safe to show)."""
    from cryptography.hazmat.primitives import serialization as s
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    if not secret:
        say("ERROR: ANSIBLE_SSH_KEY_SECRET is empty — no SSH key, so Ansible could reach no machine; set it in kms "
            "(or in agent.conf when SECRET_MGT=local)")
        sys.exit(1)
    key = Ed25519PrivateKey.from_private_bytes(hashlib.sha256(secret.encode()).digest())
    os.makedirs(KEY_DIR, mode=0o700, exist_ok=True)
    os.chmod(KEY_DIR, 0o700)
    write_private(os.path.join(KEY_DIR, "id_ed25519"),
                  key.private_bytes(s.Encoding.PEM, s.PrivateFormat.OpenSSH, s.NoEncryption()), 0o600)
    pub = key.public_key().public_bytes(s.Encoding.OpenSSH, s.PublicFormat.OpenSSH).decode() + f" {KEY_COMMENT}"
    write_private(os.path.join(KEY_DIR, "id_ed25519.pub"), (pub + "\n").encode(), 0o644)
    del key
    say(f"SSH key ready in RAM ({KEY_DIR}) — public key: {pub}")
    return pub


def start_api(env):
    port = env.get("PORT", "8897")
    p = subprocess.Popen([sys.executable, "-m", "uvicorn", "server:app", "--host", "0.0.0.0", "--port", port,
                          "--no-use-colors", "--access-log"], cwd=AGENT_DIR, env=env)
    say(f"API started on :{port} (pid {p.pid})")
    return p


def main(argv):
    if len(argv) > 1 and argv[1] in ("-h", "--help"):
        usage()
        return 0

    env = settings()
    if secret_mode(env) == "kms":
        ensure_login(env)                     # no kms login yet → signs itself up
        secrets = fetch(env)                  # the kms address → its value (missing → registered first)
    else:
        secrets = {}
    make_ssh_key({**env, **secrets}.get("ANSIBLE_SSH_KEY_SECRET", ""))
    del secrets
    api_env = {k: v for k, v in env.items() if k != "ANSIBLE_SSH_KEY_SECRET"}   # the API never sees the secret
    api_env["ANSIBLE_SSH_DIR"] = KEY_DIR
    api_p = start_api(api_env)

    stopping = {"now": False}

    def on_term(signum, frame):
        stopping["now"] = True
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    api_restarts = 0
    while True:
        if stopping["now"]:
            say("stopping — the API first")
            if api_p.poll() is None:
                api_p.terminate()
                try:
                    api_p.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    api_p.kill()
            return 0
        if api_p.poll() is not None:
            api_restarts += 1
            say(f"API exited ({api_p.returncode}) — starting it again in 2 s (restart {api_restarts})")
            time.sleep(2)
            api_p = start_api(api_env)
        time.sleep(1)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
