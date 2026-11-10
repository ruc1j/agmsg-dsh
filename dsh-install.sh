#!/usr/bin/env bash
set -euo pipefail

# Install the dsh side of the agmsg dsh type.
#
# Usage: dsh-install.sh
#
#   ~/.dsh/agmsg-hooks.json   Claude Code-format hooks (SessionStart, Stop) that
#                             dsh's @deepseek-ai/dsh-hooks-claude-code bridge runs.
#   ~/.dsh/skills/agmsg/      dsh-flavoured agmsg skill (template.md). dsh scans
#                             ~/.dsh/skills ahead of ~/.agents/skills, so this
#                             shadows the shared, Claude Code-rendered SKILL.md.
#
# The bridge itself still has to be mounted in the dsh profile, e.g. in
# ~/.dsh/profiles/<profile>/cordis.patch.yml:
#
#   - insert:
#       - id: hooks-agmsg
#         name: '@deepseek-ai/dsh-hooks-claude-code'
#         config:
#           configPath: <HOME>/.dsh/agmsg-hooks.json
#
# Windows (Git Bash): dsh's shell is PowerShell, so a bare .sh path is not a
# runnable command. The hook commands written here invoke Git's bin/bash.exe
# explicitly, and the skill template's watcher example does the same. The
# scripts themselves pick a working Python interpreter, because Git Bash
# resolves `python3` to the Microsoft Store alias, which cannot run.

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
HOOK="$PLUGIN_DIR/dsh-hook.sh"

case "$(uname -s 2>/dev/null || true)" in
  MINGW*|MSYS*|CYGWIN*) AGMSG_DSH_WINDOWS=1 ;;
  *) AGMSG_DSH_WINDOWS=0 ;;
esac

# Quote one word for the shell that runs the hook command: POSIX sh on macOS
# and Linux, PowerShell on Windows. Both use single quotes; PowerShell escapes
# an embedded quote by doubling it, POSIX by closing and reopening.
sh_quote() {
  local s="$1"
  if [ "$AGMSG_DSH_WINDOWS" = 1 ]; then
    printf "'%s'" "${s//\'/\'\'}"
  else
    printf "'%s'" "${s//\'/\'\\\'\'}"
  fi
}

# A Windows path with forward slashes ("C:/Program Files/Git/bin/bash.exe").
# PowerShell accepts it, and it keeps the hooks JSON free of backslash escapes.
win_path() {
  cygpath -m "$1" 2>/dev/null || printf '%s' "$1"
}

# The model must call Git's bin/bash.exe wrapper, not /usr/bin/bash: the raw
# MSYS binary launched with a Windows PATH cannot find dirname/cat/ps.
win_bash() {
  local b="/c/Program Files/Git/bin/bash.exe"
  if [ ! -x "$b" ]; then
    b="$(command -v bash 2>/dev/null || printf 'bash')"
    case "$b" in
      */usr/bin/bash) b="${b%/usr/bin/bash}/bin/bash" ;;
      */mingw64/bin/bash) b="${b%/mingw64/bin/bash}/bin/bash" ;;
    esac
  fi
  win_path "$b"
}

# The command dsh runs for one event.
hook_command() {
  if [ "$AGMSG_DSH_WINDOWS" = 1 ]; then
    printf '& %s %s %s' "$(sh_quote "$(win_bash)")" "$(sh_quote "$HOOK")" "$1"
  else
    printf '%s %s' "$(sh_quote "$HOOK")" "$1"
  fi
}

# JSON string literal. Windows paths are written forward-slash above, so only
# embedded quotes can appear; escape backslashes too for safety.
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# The skill text: the POSIX template verbatim, or a Windows variant whose
# {{BASH_WIN}} / {{PLUGIN_DIR}} are filled in with this machine's paths (a
# PowerShell user cannot expand ~ in a command they are told to copy).
if [ "$AGMSG_DSH_WINDOWS" = 1 ]; then
  TEMPLATE="$PLUGIN_DIR/template-windows.md"
  BASH_WIN="$(win_bash)"
else
  TEMPLATE="$PLUGIN_DIR/template.md"
  BASH_WIN=""
fi

mkdir -p "$DSH_HOME/skills/agmsg"
while IFS= read -r line || [ -n "$line" ]; do
  line="${line//\{\{BASH_WIN\}\}/$BASH_WIN}"
  line="${line//\{\{PLUGIN_DIR\}\}/$PLUGIN_DIR}"
  printf '%s\n' "$line"
done < "$TEMPLATE" > "$DSH_HOME/skills/agmsg/SKILL.md"
echo "  + $DSH_HOME/skills/agmsg/SKILL.md"

cat > "$DSH_HOME/agmsg-hooks.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": $(json_str "$(hook_command session-start)"),
            "timeout": 30
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": $(json_str "$(hook_command stop)"),
            "timeout": 30
          }
        ]
      }
    ]
  }
}
EOF
echo "  + $DSH_HOME/agmsg-hooks.json"
