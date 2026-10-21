# ansible_project — the Ansible project (playbooks · inventories · roles)

Plain Ansible. It runs inside the confmgt-ansible container, where the ansible-agent runs it, and on any PC with ansible-core installed.
Docker and the agent only add the SSH key from kms and the API.

## The folders

```
ansible.cfg                                       Ansible's settings (default inventory: dev = the developer PC)
inventories/<env>/hosts.yml                       the machines of one environment (dev · test · staging · prod)
inventories/<env>/host_vars/<machine>.yml         how to reach one machine (address, port, user, workspace_root)
inventories/<env>/group_vars/all/<topic>.yml      Ansible's own settings for every machine (e.g. connection)
inventories/<env>/shared/<topic>.yml             SHARED: values used by 2+ projects, once (kms · clock · anthropic · rabbitmq · postgres …)
inventories/<env>/myworkspace/<path>.yml          THE MIRROR: only that project's own values of ~/myworkspace/<path>, one file per real config file
playbooks/<name>.yml                              what can run — the agent finds every file here by itself
roles/<project>/templates/myworkspace/<path>.j2   the real file's shape (its own comments), values from the mirror
```

## The mirror — the single source of truth, laid out like the workspace

```
inventories/dev/myworkspace/projectspace/mycache/.env.yml                 → ~/myworkspace/projectspace/mycache/.env
inventories/dev/myworkspace/projectspace/mycache/cache-agent/agent.conf.yml → ~/myworkspace/projectspace/mycache/cache-agent/agent.conf
```
A value used by 2+ projects is NOT in the mirror: it lives once in `shared/<topic>.yml`, and the mirrored file refers to it by name:
```
inventories/dev/shared/clock.yml       shared_clock.tz: "America/New_York"
inventories/dev/myworkspace/projectspace/mycache/.env.yml      TZ: "{{ shared_clock.tz }}"
```
Every playbook loads `shared/` first (role `shared`); a new topic = a new file there.

Find a setting by the path you already know (like the mirror logs in mountspace/logs/myworkspace/…).
Each environment has its own mirror with the same paths and its own values.

| Project | Mirrored files | Playbook | Story |
|---|---|---|---|
| mycache | `.env` · `cache-agent/agent.conf` (TZ · KMS_URL · SECRET_MGT · Anthropic → shared/) | `mycache.yml` (check · apply + restart via its own scripts) | 3.1 · 3.2 · 3.3 |
| mychannels | `.env` · `channel-agent/agent.conf` (RabbitMQ → NEW shared/rabbitmq.yml, owned by mychannels) | `mychannels.yml` (check · apply + restart) | 3.4 |
| mypostgresql_db | `db-agent/agent.conf` (databases, users, password addresses → NEW shared/postgres.yml, owned by mypostgresql_db) | `mypostgresql_db.yml` (check · apply + restart via its stop.sh + start.sh) | 3.5 |
| mydocs (Plane) | `.env` (Postgres · Redis · RabbitMQ → shared/, NEW shared/redis.yml owned by mycache) | `mydocs.yml` (check · apply + restart via ensure_stopped/ensure_running) | 3.6 |
| mylog_analytics | `log-agent/agent.conf` (all three values → shared/) | `mylog_analytics.yml` (check · apply + restart via stop/start) | 3.7 |
| myodoo | `odoo-agent/agent.conf` · `odoo-19/odoo.conf` (INI; database → shared/postgres.yml) | `myodoo.yml` (check · apply + restart Odoo 19 via stop/start --19) | 3.8 |
| agents · workspace-agent | `agents/shared.conf` (ums db → shared/postgres.yml) · `agents/workspace-agent/mcp.conf` | `agents.yml` (restart-agents.sh) · `workspace_agent.yml` (mcp_json_from_kms.sh) | 3.9 |

A project joins (one story each): its files in the mirror + their templates + a role listing them + a playbook — no core change.

## Run it

| How | Command |
|---|---|
| through the agent (normal) | `bash ../check_playbook.sh` (dry run) · `bash ../apply_playbook.sh` |
| without Docker | `ansible-playbook -i inventories/test playbooks/ping.yml --private-key <key>` |
