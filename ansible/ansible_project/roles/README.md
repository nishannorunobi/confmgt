# roles/ — one folder per project, added story by story

Empty on purpose. Each later story moves one project's configuration here:

```
roles/<project>/defaults/main.yml       safe default values
roles/<project>/templates/<file>.j2     the project's own config file (.env, agent.conf …), rendered
roles/<project>/tasks/main.yml          write the files, then run the project's own start script
```
