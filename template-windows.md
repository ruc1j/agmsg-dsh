---
name: agmsg
description: Cross-agent messaging via SQLite (agmsg) for DeepSeek Harness on Windows. Check the inbox, send messages to teammates (Claude Code, Codex, other agents), join a team, and run the background inbox watcher.
---

# agmsg for dsh (Windows)

agmsg lets agents on this machine message each other through a shared SQLite
database. Always go through the scripts below; never read or edit the DB, team
files, or config directly. Your agent type is always `dsh`.

dsh's shell on Windows is PowerShell, while every agmsg script is Bash. Run each
script through Git for Windows' Bash, keeping the payload inside one
single-quoted string:

```
& '{{BASH_WIN}}' -lc '<command>'
```

Do not call the `.sh` files directly from PowerShell. `<project>` below is the
absolute path of your workspace.

## Who am I

```
& '{{BASH_WIN}}' -lc '~/.agents/skills/agmsg/scripts/whoami.sh "<project>" dsh'
```

Prints `agent=<name> teams=<t1,...>` when joined, `not_joined=true` otherwise.

## Join a team (only when asked)

```
& '{{BASH_WIN}}' -lc '~/.agents/skills/agmsg/scripts/join.sh <team> <name> dsh "<project>"'
```

## Messages

- Read and consume unread messages: `inbox.sh <team> <your-name>`
- Send: `send.sh <team> <your-name> <to> "<message>"`
- Recent history: `history.sh <team>`
- Teammates and their status: `team.sh <team>`

All of them run through the Git Bash wrapper above, for example:

```
& '{{BASH_WIN}}' -lc '~/.agents/skills/agmsg/scripts/inbox.sh <team> <your-name>'
```

## Real-time delivery (monitor mode)

Turn it on for a project (once):

```
& '{{BASH_WIN}}' -lc '~/.agents/skills/agmsg/scripts/delivery.sh set monitor dsh "<project>"'
```

With monitor mode on, each new dsh session gets a SessionStart note telling it
to start the watcher. The watcher is one-shot: start it with the pwsh tool and
`run_in_background: true`:

```
& '{{BASH_WIN}}' '{{PLUGIN_DIR}}/dsh-watch.sh' '<project>'
```

It blocks until a message arrives, prints it (marking it read), and exits. The
"background job ... finished" notice wakes you: read it with `job_output`, act
on the messages, reply with `send.sh` if needed, then start the watcher again
in the background. Keep exactly one watcher per session. If the watcher is
missing when your turn ends, the Stop hook asks you to start it again.

Turn delivery off with `delivery.sh set off dsh "<project>"`; check it with
`delivery.sh status dsh "<project>"`.
