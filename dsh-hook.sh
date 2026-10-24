#!/usr/bin/env bash
set -euo pipefail

# Claude Code-format hook entry point for DeepSeek Harness (dsh).
#
# Usage: dsh-hook.sh session-start|stop     (hook payload JSON on stdin)
#
# Registered once, globally, in ~/.dsh/agmsg-hooks.json and run by dsh's
# @deepseek-ai/dsh-hooks-claude-code bridge for every session. A session takes
# part only when its workspace (or an ancestor) holds the per-project marker
# .dsh/agmsg-delivery written by `delivery.sh set monitor dsh <project>`, and
# the project has a dsh identity. Everything else exits 0 silently.
#
# The bridge only feeds JSON back to the model (plain stdout is ignored):
#   session-start -> hookSpecificOutput.additionalContext with the launch directive
#   stop          -> {"decision":"block","reason":...} when no watcher is alive,
#                    which steers the agent into one more step to re-arm it.
# The bridge always sends stop_hook_active=false, so the Stop re-arm loop is
# bounded here instead: after MAX_BLOCKS consecutive blocks without a live
# watcher the hook lets the turn end.

EVENT="${1:?Usage: dsh-hook.sh session-start|stop}"
MAX_BLOCKS="${AGMSG_DSH_MAX_REARM_BLOCKS:-2}"

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$PLUGIN_DIR/../../.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
RUN_DIR="$SKILL_DIR/run"

INPUT="$(cat 2>/dev/null || true)"
json_field() {
  printf '%s' "$INPUT" | python3 -c 'import json,sys
try: v=json.load(sys.stdin).get(sys.argv[1],"")
except Exception: v=""
print(v if isinstance(v,str) else "")' "$1" 2>/dev/null || true
}
SESSION="$(json_field session_id)"
CWD="${CLAUDE_PROJECT_DIR:-$(json_field cwd)}"
[ -n "$CWD" ] || CWD="$PWD"
[ -n "$SESSION" ] || exit 0
case "$SESSION" in *[!A-Za-z0-9._-]*) exit 0 ;; esac

# Nearest ancestor holding the marker is the registered project.
PROJECT=""
d="$CWD"
while [ -n "$d" ]; do
  if [ -f "$d/.dsh/agmsg-delivery" ]; then PROJECT="$d"; break; fi
  [ "$d" = "/" ] && break
  d="$(dirname "$d")"
done
[ -n "$PROJECT" ] || exit 0
grep -q '^monitor$' "$PROJECT/.dsh/agmsg-delivery" 2>/dev/null || exit 0

PAIRS="$("$SCRIPTS/identities.sh" "$PROJECT" dsh 2>/dev/null || true)"
[ -n "$PAIRS" ] || exit 0

# No session id in the command: dsh-watch.sh reads DSH_SESSION_ID itself, so
# the model has nothing long to copy (and mistype).
WATCH_CMD="$(printf '%q %q' "$PLUGIN_DIR/dsh-watch.sh" "$PROJECT")"
PIDFILE="$RUN_DIR/dsh-watch.$SESSION.pid"
COUNTFILE="$RUN_DIR/dsh-rearm.$SESSION.count"

watcher_alive() {
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
    && ps -o command= -p "$pid" 2>/dev/null | grep -q 'dsh-watch\.sh'
}

# emit <python expression building the output object from the stdin text t>
emit() {
  python3 -c "import json,sys; t=sys.stdin.read(); print(json.dumps($1))"
}

IDENTITIES="$(printf '%s\n' "$PAIRS" | awk -F'\t' 'NF>=2 {printf "%s%s/%s", sep, $1, $2; sep=", "}')"

case "$EVENT" in
  session-start)
    rm -f "$COUNTFILE"
    if watcher_alive; then exit 0; fi
    emit '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":t}}' <<MSG
AGMSG monitor mode (dsh). This session is the agmsg agent ${IDENTITIES} (team/name) for project ${PROJECT}.
To receive teammate messages, start the agmsg inbox watcher with the bash tool and run_in_background: true:

  ${WATCH_CMD}

Use exactly that command (no pipes, no redirection, no trailing &). It blocks until a teammate message arrives, prints it, and exits; a "background job ... finished" notice then wakes you.
When that notice arrives: read the job with job_output, act on the messages (reply with ${SCRIPTS}/send.sh <team> <your-name> <to> "<message>"), and start the same command again in the background. Keep exactly one watcher running; if it says "already running", do nothing. If it says "stopping", do not re-arm.
agmsg is only for teammates. Answer the user here in the conversation as usual; do not send the user's conversation to agmsg.
MSG
    ;;
  stop)
    if watcher_alive; then rm -f "$COUNTFILE"; exit 0; fi
    n="$(cat "$COUNTFILE" 2>/dev/null || echo 0)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -lt "$MAX_BLOCKS" ] || exit 0
    echo $((n + 1)) > "$COUNTFILE"
    emit '{"decision":"block","reason":t}' <<MSG
agmsg: the inbox watcher is not running, so teammate messages cannot reach this session. Restart it with the bash tool and run_in_background: true, exactly:

  ${WATCH_CMD}
MSG
    ;;
  *)
    echo "dsh-hook.sh: unknown event: $EVENT" >&2
    exit 1
    ;;
esac
