# ansible_project — the Ansible project (playbooks · inventories · roles)

Plain Ansible. It runs inside the confmgt-ansible container, where the ansible-agent runs it, and on any PC with ansible-core installed.
Docker and the agent only add the SSH key from kms and the API.

## The folders

```
ansible.cfg                                   Ansible's settings (default inventory: pc = this PC)
inventories/<env>/hosts.yml                   the machines of one environment
inventories/<env>/host_vars/<machine>.yml     how to reach one machine (address, port, user)
inventories/<env>/group_vars/all/<topic>.yml  values for EVERY machine of the environment, one topic per file
playbooks/<name>.yml                          what can run — the agent finds every file here by itself
roles/<project>/                              one project's configuration (later stories)
```

A new environment is a new folder next to `test/`. A new machine is one line in `hosts.yml` plus its `host_vars` file. A new playbook is a new file in `playbooks/`. You never edit code to add any of these.

## Who has joined (epic [3], one story per step)

| Project | Values | Renders | Playbook | Story |
|---|---|---|---|---|
| mycache | `inventories/pc/group_vars/mycache/main.yml` | `.env` · `cache-agent/agent.conf` | `mycache.yml` (check only) | 3.1 |

## How the rest joins: the single source of truth for every project

Each project joins in its own story. It only **adds** files:

```
inventories/<env>/group_vars/all/kms.yml        workspace-wide values, once per environment (KMS_URL, SECRET_MGT …)
inventories/<env>/group_vars/<project>/*.yml    one project's values
inventories/<env>/hosts.yml                     + the group <project>: which machines run it
roles/<project>/templates/<its file>.j2         renders the project's own .env / agent.conf from those values
playbooks/<project>.yml                         applies the role to its group
```

The project still runs alone from its rendered file, without Ansible.

## Run it

| How | Command |
|---|---|
| through the agent (normal) | `bash ../check_playbook.sh` (dry run) · `bash ../apply_playbook.sh` |
| without Docker | `ansible-playbook -i inventories/test playbooks/ping.yml --private-key <key>` |
