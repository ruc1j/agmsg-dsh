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

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
HOOK="$PLUGIN_DIR/dsh-hook.sh"

mkdir -p "$DSH_HOME/skills/agmsg"
cp "$PLUGIN_DIR/template.md" "$DSH_HOME/skills/agmsg/SKILL.md"
echo "  + $DSH_HOME/skills/agmsg/SKILL.md"

python3 - "$HOOK" "$DSH_HOME/agmsg-hooks.json" <<'PY'
import json, shlex, sys
hook, out = sys.argv[1], sys.argv[2]
def entry(event, timeout):
    return [{"hooks": [{"type": "command",
                        "command": f"{shlex.quote(hook)} {event}",
                        "timeout": timeout}]}]
cfg = {"hooks": {"SessionStart": entry("session-start", 30),
                 "Stop": entry("stop", 30)}}
with open(out, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
echo "  + $DSH_HOME/agmsg-hooks.json"
