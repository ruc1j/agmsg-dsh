# agmsg-dsh

An [agmsg](https://www.npmjs.com/package/agmsg) agent-type plugin for
**DeepSeek Harness** (`dsh` / `dsh-tui`). It lets a dsh session join an agmsg
team as a `dsh` member and receive teammate messages in real time.

Tested with agmsg v1.5.3, dsh 0.2.0-rc.2, dsh-tui 0.14.0 on macOS, and with
agmsg v1.7.1, dsh 0.2.2-rc.1, dsh-tui 0.19.0 on Windows 11 (Git for Windows,
Python 3.12).

## How it works

dsh has no Monitor-style streaming tool, but it has background bash jobs whose
completion wakes the agent. So delivery works like this:

1. `dsh-hook.sh session-start` (SessionStart hook) tells the agent to start
   `dsh-watch.sh <project>` as a background bash job.
2. `dsh-watch.sh` blocks until an unread message arrives, prints it (marking it
   read) and exits. The job-finished notice wakes the agent, which handles the
   message and starts the watcher again.
3. `dsh-hook.sh stop` (Stop hook) blocks the end of a turn when no watcher is
   alive, so the agent re-arms it (at most `AGMSG_DSH_MAX_REARM_BLOCKS`, default 2).

The hooks are Claude Code-format hooks run by dsh's
`@deepseek-ai/dsh-hooks-claude-code` bridge from one global config,
`~/.dsh/agmsg-hooks.json`. A project opts in through the marker file
`<project>/.dsh/agmsg-delivery`.

| File | Role |
|---|---|
| `type.conf` | agmsg type manifest (data only, never sourced) |
| `_delivery.sh` | delivery plug used by `delivery.sh set/status` |
| `dsh-hook.sh` | SessionStart / Stop hook entry point |
| `dsh-watch.sh` | one-shot inbox watcher run as a dsh background job |
| `dsh-install.sh` | writes `~/.dsh/agmsg-hooks.json` and `~/.dsh/skills/agmsg/SKILL.md` |
| `template.md` | dsh-flavoured agmsg skill (macOS / Linux) |
| `template-windows.md` | the same skill for Windows, with Git Bash paths filled in |

## Windows

dsh's shell on Windows is PowerShell; every agmsg script is Bash. The plugin
runs on Windows with these differences:

- The hook commands in `~/.dsh/agmsg-hooks.json` invoke Git's
  `bin/bash.exe` explicitly — a bare `.sh` path is not a runnable PowerShell
  command.
- The SessionStart note (and the re-arm note) tell the agent to start the
  watcher with the **pwsh** tool, passing the command to Git Bash.
- `dsh-watch.sh` cannot see the native parent through Git Bash's `ps`. It walks
  the Windows process tree once (past the `bash.exe` wrapper) and polls the
  hosting `pwsh` with `tasklist`, so a watcher whose session is disposed exits
  instead of lingering.
- The hook scripts pick whichever of `python3` / `python` can actually run: Git
  Bash resolves `python3` to the Microsoft Store alias, which exists but exits
  with an error, so `command -v` alone is not enough.

Run the setup commands below in Git Bash. From PowerShell that is:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' -lc '<command>'
```

## Setup (instructions for an AI agent)

Run these steps on the target machine in order. Each step says how to verify
it. Do not edit the agmsg database or team files directly.

### 0. Prerequisites

```bash
command -v bash sqlite3 git node npx dsh dsh-tui
command -v python3 || command -v python
```

All must resolve in the shell that runs the hooks. On Windows that is Git Bash;
the hooks accept `python` when `python3` resolves to the Microsoft Store alias,
which cannot run. If `dsh`/`dsh-tui` are missing, install DeepSeek Harness
first; this plugin does not install it.

### 1. Install agmsg

Skip if `~/.agents/skills/agmsg/scripts` already exists.

```bash
npx agmsg@latest install
cat ~/.agents/skills/agmsg/VERSION
```

### 2. Put this plugin into agmsg's plugin directory

The directory name must be exactly `dsh`.

```bash
mkdir -p ~/.agents/skills/agmsg/plugins/types
git clone https://github.com/ruc1j/agmsg-dsh.git ~/.agents/skills/agmsg/plugins/types/dsh
chmod +x ~/.agents/skills/agmsg/plugins/types/dsh/*.sh
```

`npx agmsg install --update` keeps `plugins/`, so the plugin survives agmsg updates.
To update the plugin itself: `git -C ~/.agents/skills/agmsg/plugins/types/dsh pull`.

### 3. Trust the plugin

agmsg ignores external drivers until they are trusted.

```bash
~/.agents/skills/agmsg/scripts/plugin.sh trust types/dsh
~/.agents/skills/agmsg/scripts/plugin.sh list
```

`list` must show `types/dsh` as trusted
(`~/.agents/skills/agmsg/db/trusted-plugins` gets a `types/dsh<TAB><path>` line).

### 4. Install the dsh side

```bash
~/.agents/skills/agmsg/plugins/types/dsh/dsh-install.sh
```

This writes `~/.dsh/agmsg-hooks.json` (absolute paths to `dsh-hook.sh` on this
machine) and `~/.dsh/skills/agmsg/SKILL.md`. Re-run it if the plugin path changes.
On Windows the hook commands are written for PowerShell (they invoke Git's
`bin/bash.exe`), and the skill installed is `template-windows.md`.

### 5. Mount the hooks bridge in the dsh profile

Append this to the profile's `cordis.patch.yml`. For dsh-tui the file is
`~/.dsh/profiles/dsh-tui/cordis.patch.yml`. Replace `<HOME>` with the absolute
home directory (`echo $HOME`); do not use `~` or `$HOME` inside the YAML.
The file is a top-level YAML list; keep its existing indentation style.

```yaml
# agmsg delivery for dsh: run the Claude Code-format SessionStart/Stop hooks in
# ~/.dsh/agmsg-hooks.json (installed by agmsg plugins/types/dsh/dsh-install.sh).
- insert:
    - id: hooks-agmsg
      name: '@deepseek-ai/dsh-hooks-claude-code'
      config:
        configPath: <HOME>/.dsh/agmsg-hooks.json
```

On Windows `<HOME>` is a native path such as `C:\Users\you` (forward slashes in
`C:/Users/you/.dsh/agmsg-hooks.json` are accepted too).

Verify that the merged config contains it:

```bash
dsh --profile dsh-tui --dump-config | grep -n -A3 hooks-agmsg
```

### 6. Join a team and turn on delivery for a project

`<project>` is the absolute path of the directory where dsh-tui is started.

```bash
~/.agents/skills/agmsg/scripts/join.sh <team> <name> dsh '<project>'
~/.agents/skills/agmsg/scripts/delivery.sh set monitor dsh '<project>'
~/.agents/skills/agmsg/scripts/delivery.sh status dsh '<project>'
```

`status` must print `mode: monitor` and a `hooks:` line that is not `MISSING`.
`<project>/.dsh/agmsg-delivery` now exists.

### 7. End-to-end check

1. Start `dsh-tui` in `<project>`. The agent should start
   `.../plugins/types/dsh/dsh-watch.sh <project>` as a background job on its own
   (with the bash tool on macOS/Linux, with the pwsh tool on Windows).
2. From another agent (or a shell), send a message:
   `~/.agents/skills/agmsg/scripts/send.sh <team> <sender> <name> "ping"`
3. The dsh agent should wake, show the message, and start the watcher again.

## Troubleshooting

- **No SessionStart instruction appears**: check step 5 with `--dump-config`,
  that `~/.dsh/agmsg-hooks.json` points at an existing `dsh-hook.sh`, and that
  `<project>/.dsh/agmsg-delivery` contains `monitor`.
- **Watcher says "no dsh identity"**: the project has not joined a team as type
  `dsh` (step 6).
- **Plugin is ignored / type `dsh` unknown**: it is not trusted (step 3), or the
  directory is not named `plugins/types/dsh`.
- **Windows, watcher exits immediately with `dirname: command not found`**: it
  was started with `usr/bin/bash.exe` instead of Git's `bin/bash.exe`. The raw
  MSYS binary inherits a Windows PATH and cannot find the MSYS utilities; use
  `C:/Program Files/Git/bin/bash.exe`.
- **Windows, no SessionStart instruction and no hook output**: neither `python3`
  nor `python` can run in Git Bash (the Store alias returns an error). Install
  Python or put a working interpreter on PATH; the hook exits silently without
  one.
- Leftover watchers: `delivery.sh set off dsh '<project>'` kills them. On Windows
  an orphan can also be stopped with `taskkill /PID <pid> /F`; the pidfile is
  `~/.agents/skills/agmsg/run/dsh-watch.<session>.pid`.

## Uninstall

```bash
~/.agents/skills/agmsg/scripts/delivery.sh set off dsh '<project>'
~/.agents/skills/agmsg/scripts/plugin.sh untrust types/dsh
rm -rf ~/.agents/skills/agmsg/plugins/types/dsh ~/.dsh/agmsg-hooks.json ~/.dsh/skills/agmsg
```

Then remove the `hooks-agmsg` block from `cordis.patch.yml`.
