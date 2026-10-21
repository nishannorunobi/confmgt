# confmgt / ansible

Ansible in its own container: the workspace's configuration management (CONFMGT-3).
The **ansible-agent** is the container's entry point. It gets the SSH key's secret from kms, makes the key in RAM, and runs playbooks when you ask.
Ansible reaches machines over SSH: it writes a project's files there and runs that project's own scripts.

## Where is what — the names say where a script runs

```
confmgt/ansible/
  start.sh · stop.sh · status.sh            start / stop / see it (status.sh --state = one word for scripts)
  authorize_ansible_on_this_pc.sh           let Ansible log in to THIS PC (its key → ~/.ssh/authorized_keys, once)
  show_public_key.sh                        the key to put on each machine (once per machine)
  check_playbook.sh                         dry run: what WOULD change — asks playbook · inventory · machines
  apply_playbook.sh                         the real run
  deploy_on_this_pc.sh                      Ansible deploys the workspace on THIS PC (deploy · dev) — startup.sh's last step (deploy-dev)
  stop_on_this_pc.sh                        Ansible takes the projects DOWN on THIS PC (stop · dev) — shutdown's first step (deploy-dev)
  dockerspace/
    docker-compose.yml · Dockerfile · .env  the container (built once, then offline)
    host_scripts/      ON YOUR PC:  start.sh · stop.sh (Docker only) · logs.sh · clean.sh (⚠ forgets known_hosts)
                                    confmgt_ansible_container_login.sh (a shell inside)
                                    test_ansible_container.sh · test_mycache_role.sh
    container_scripts/ INSIDE:      env_check.sh  (after logging in: bash /container_scripts/env_check.sh)
  ansible-agent/                    the agent — the container's entry point (kms → SSH key in RAM → API)
  ansible_project/                  plain Ansible: inventories · playbooks · roles (runs without Docker too)
```

Everything is a script: `bash <name>.sh`. You never type docker, curl or other commands.

## How it fits together

```
your PC ── check_playbook.sh / apply_playbook.sh ──▶ http://127.0.0.1:8897  (ansible-agent API)
                                                         │
docker compose up → confmgt-ansible container            │
  └─ ansible-agent/supervisor.py (entry point)           │
       kms ──▶ ANSIBLE_SSH_KEY_SECRET (own login)        │
       → SSH key in RAM /run/ansible-ssh  ·  API :8897 ◀─┘
            └─ ansible-playbook  (ansible_project/, read-only) ──SSH──▶ the machines (test VM, …)
```

| Layer | What | Runs without the layer above? |
|---|---|---|
| 1 host scripts | `start.sh` … only Docker | — |
| 2 ansible-agent | kms → SSH key in RAM → API: check / apply | yes, inside the container |
| 3 `ansible_project/` | plain Ansible: inventories, playbooks, roles | yes, on any PC with ansible-core |

## 🔑 Where are the secrets?

**Not in any file of this project.** There is one secret, `ANSIBLE_SSH_KEY_SECRET`. It is 32 random characters that live in **kms**, at `kv/confmgt/ansible`.
It is created automatically the first time: the agent's register script runs when the agent finds the secret missing.
The agent turns it into Ansible's SSH key, an ed25519 key whose 32-byte seed is the SHA-256 of the secret. The key exists **only in RAM**, in the container's `/run/ansible-ssh`.

In `ansible-agent/agent.conf` the secret's value is **its kms address**:

```
# kms: ${KMS_URL}/v1/kv/data/confmgt/ansible
ANSIBLE_SSH_KEY_SECRET=${KMS_URL}/v1/kv/data/confmgt/ansible
```

| Secret | Used by | Where it lives | Fetched by |
|---|---|---|---|
| `ANSIBLE_SSH_KEY_SECRET` | Ansible's SSH key (made in RAM) | kms `kv/confmgt/ansible` | the ansible-agent (`supervisor.py` → `connect_external/kms/kms.py`) |

- `dockerspace/.env` holds the image versions, the port and TZ. It has no secret and is tracked in git.
- The agent's kms login is in `ansible-agent/connect_external/kms/credentials/`. It is git-ignored, and the agent signs up by itself the first time.
- Without kms, set `SECRET_MGT=local` in `agent.conf` and write the value there. The rotation scripts in `connect_external/kms/` move values both ways.
- **A new secret means a new key.** Run `show_public_key.sh` again and put the new key on the machines.

## The machines

`ansible_project/inventories/<env>/` holds the machines, one folder per environment.
`dev` is the developer PC (default), reached as `host.docker.internal` port 22 — `bash authorize_ansible_on_this_pc.sh` lets Ansible in. `test` is a placeholder for a test VM.
A machine lets Ansible in only when the public key from `show_public_key.sh` is in its `~/.ssh/authorized_keys`.
The first contact is trusted and remembered in the data volume (`known_hosts`). A host key that changes later is refused.

## On its own machine

confmgt does not need the workspace. Clone it anywhere (e.g. `/opt/confmgt`) and set this machine's paths, nothing else:

| File | Setting | On the PC (default) | On its own server (example) |
|---|---|---|---|
| `dockerspace/.env` | `LOG_DIR` | `../../../../mountspace/logs` | `/var/log/confmgt` |
| `dockerspace/.env` | `KMS_MASTER_PASSWORD_DIR` | `../../../../mountspace/usb/…/master_password` | `/opt/confmgt-data/kms/master_password` |
| `ansible-agent/agent.conf` | `KMS_URL` | `http://kms-openbao:8200` | `https://<kms-host>:<port>` |

`start.sh` creates both folders when missing. Then `bash start.sh`.

## Agent API (`http://127.0.0.1:8897`)

| Call | What |
|---|---|
| `GET /health` | alive · the Ansible version · SSH key ready · whether a run is going on |
| `GET /public-key` | the public key (safe to show) |
| `GET /playbooks` | the playbooks and inventories it found (`ansible_project/playbooks/*.yml`, `inventories/*/`) |
| `POST /check` · `POST /apply` | `{"playbook": "ping", "inventory": "test", "limit": "test-vm"}` — known names only, one run at a time (busy → 409), at most `RUN_TIMEOUT` s |
| `GET /runs/last` | the last run: exit code, output, log file |

Every run's output is kept in `mountspace/logs/myworkspace/projectspace/confmgt/ansible/ansible-agent/runs/`, which keeps the newest 50.

## Test

```
bash dockerspace/host_scripts/test_ansible_container.sh      throwaway kms + this checkout's image + a throwaway SSH machine (≈2 min)
```
