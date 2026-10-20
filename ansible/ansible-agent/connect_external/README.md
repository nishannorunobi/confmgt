# ansible-agent/connect_external — how the ansible-agent talks to other components

The ansible-agent is its own component (Ansible's assistant), so it has its own connections.
Everything here talks over the **network (APIs)** — no file of another project.

| Folder | Component | How | Used by |
|---|---|---|---|
| `kms/` | kms (OpenBao) — secrets | HTTP API (the address is in each `agent.conf` value) · sign up once: `signup_with_kms.sh` (or `../start.sh` by hand) | `kms.py`: `supervisor.py` at start (the SSH key secret) |
