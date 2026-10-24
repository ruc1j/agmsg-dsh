#!/usr/bin/env bash
set -euo pipefail

# One-shot agmsg inbox watcher for DeepSeek Harness (dsh).
#
# Usage: dsh-watch.sh <project_path> [session_id]
#
# Run by the dsh agent as a background bash job (run_in_background: true).
# Blocks until unread messages exist for this project's dsh identities, prints
# them through inbox.sh (which marks them read), and exits. dsh's job runtime
# then wakes the agent with a completion notice; the agent reads the output
# with job_output, handles the messages, and starts this script again.
#
# Only one watcher per dsh session: a second start while one is alive prints a
# note and exits 0. The pidfile run/dsh-watch.<session>.pid is what the Stop
# hook (dsh-hook.sh) checks to decide whether a re-arm is needed.
#
# The session id comes from DSH_SESSION_ID, which dsh exports to every bash
# command; the optional argument is only for running outside dsh. Inside dsh
# the environment wins, because a model copying a 36-char uuid into the
# command was seen to mistype it and start a second, misnamed watcher.
#
# dsh does not kill background jobs when the TUI exits; the watcher is
# reparented and would go on consuming messages nobody reads. So it remembers
# its parent and stops, without consuming anything, once that parent is gone.

PROJECT="${1:?Usage: dsh-watch.sh <project_path> [session_id]}"
SESSION="${DSH_SESSION_ID:-${2:-}}"
PARENT_PID="$PPID"
POLL_TIMEOUT="${AGMSG_DSH_POLL_TIMEOUT:-20}"

parent_alive() {
  [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" = "$PARENT_PID" ] \
    && kill -0 "$PARENT_PID" 2>/dev/null
}

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$PLUGIN_DIR/../../.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
RUN_DIR="$SKILL_DIR/run"
WATCH_ONCE="$SCRIPTS/drivers/types/codex/watch-once.sh"
INTERVAL="${AGMSG_WATCH_INTERVAL:-3}"

if [ -z "$SESSION" ]; then
  echo "agmsg watch: error - no session id (pass it or run inside dsh, which sets DSH_SESSION_ID)" >&2
  exit 1
fi
case "$SESSION" in *[!A-Za-z0-9._-]*) echo "agmsg watch: error - unsafe session id: $SESSION" >&2; exit 1 ;; esac

PIDFILE="$RUN_DIR/dsh-watch.$SESSION.pid"
mkdir -p "$RUN_DIR"

if [ -f "$PIDFILE" ]; then
  old="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$old" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null \
     && ps -o command= -p "$old" 2>/dev/null | grep -q 'dsh-watch\.sh'; then
    echo "agmsg watch: already running for this session (pid $old) - nothing to do, do not start another"
    exit 0
  fi
fi
echo "$$" > "$PIDFILE"
_cleanup() {
  if [ "$(cat "$PIDFILE" 2>/dev/null || true)" = "$$" ]; then rm -f "$PIDFILE"; fi
}
trap _cleanup EXIT
trap 'exit 143' TERM INT HUP

PAIRS="$("$SCRIPTS/identities.sh" "$PROJECT" dsh 2>/dev/null || true)"
if [ -z "$PAIRS" ]; then
  echo "agmsg watch: stopping - this project has no dsh identity (join a team first); do not re-arm"
  exit 0
fi

while true; do
  parent_alive || exit 0
  rc=0
  "$WATCH_ONCE" "$PROJECT" dsh --timeout "$POLL_TIMEOUT" --interval "$INTERVAL" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) break ;;
    2) continue ;;
    *) echo "agmsg watch: error - watch-once exited $rc"; exit 1 ;;
  esac
done
parent_alive || exit 0

while IFS=$'\t' read -r team agent; do
  [ -n "$team" ] && [ -n "$agent" ] || continue
  "$SCRIPTS/inbox.sh" "$team" "$agent" --quiet || true
done <<< "$PAIRS"

printf '\nagmsg watch: delivered - handle the messages above (reply with send.sh), then re-arm the watcher:\n  %q %q   (bash, run_in_background: true)\n' \
  "$PLUGIN_DIR/dsh-watch.sh" "$PROJECT"
