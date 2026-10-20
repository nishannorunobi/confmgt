# confmgt — configuration management

One folder per tool. Each is a standard project with its own container, its own agent as the entry point, and its own scripts.

| Folder | Tool | State |
|---|---|---|
| `ansible/` | Ansible | in use: container + ansible-agent (CONFMGT-3) — see `ansible/README.md` |
| `salt/` · `puppet/` · `chef/` | Salt · Puppet · Chef | later, the same shape |

Background: `ansible/ansible_arch.md` (reference architecture for large scale).
