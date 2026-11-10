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
AGMSG_PLATFORM="$(uname -s 2>/dev/null || true)"

# Windows: Git Bash's ps cannot see the native parent, so resolve the spawning
# pwsh process once through Windows and poll it with tasklist. dsh cancels the
# job's pwsh when the session is disposed, but a bash grandchild can survive
# that kill (observed with a profile reload), so this check is not optional.
WIN_PARENT=""
case "$AGMSG_PLATFORM" in
  MINGW*|MSYS*|CYGWIN*)
    _self_winpid="$(cat "/proc/$$/winpid" 2>/dev/null || true)"
    case "$_self_winpid" in
      ''|*[!0-9]*) ;;
      *)
        # Git's bin/bash.exe is a wrapper that re-executes usr/bin/bash.exe, so
        # the immediate native parent is another bash. Walk past the bash/shell
        # layer and monitor the first real host (dsh's pwsh job process). When
        # that ancestor has already died, print the last parent we saw: it is
        # gone, and the poll below exits the watcher.
        WIN_PARENT="$(
          AGMSG_SELF_WINPID="$_self_winpid" powershell.exe -NoProfile -Command '
            $id = $env:AGMSG_SELF_WINPID
            $last = $id
            for ($i = 0; $i -lt 10 -and $id; $i++) {
              $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id"
              if (-not $p) { break }
              if ($p.Name -notmatch "^(bash|sh|dash|git)\.exe$") {
                [Console]::Out.Write($p.ProcessId); exit 0
              }
              $last = $p.ParentProcessId
              $id = $p.ParentProcessId
            }
            [Console]::Out.Write($last)
          ' 2>/dev/null | tr -d '\r' || true
        )"
        ;;
    esac
    case "$WIN_PARENT" in ''|*[!0-9]*) WIN_PARENT="" ;; esac
    unset _self_winpid
    ;;
esac

parent_alive() {
  case "$AGMSG_PLATFORM" in
    MINGW*|MSYS*|CYGWIN*)
      if [ -n "$WIN_PARENT" ]; then
        tasklist //FI "PID eq $WIN_PARENT" //NH 2>/dev/null \
          | awk -v p="$WIN_PARENT" '$2 == p { found = 1 } END { exit !found }'
        return $?
      fi
      return 0
      ;;
  esac
  [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" = "$PARENT_PID" ] \
    && kill -0 "$PARENT_PID" 2>/dev/null
}

# A pidfile pid is ours when it is alive and (where ps can answer) its argv is
# this script. Git Bash's ps has no -o, so otherwise the live pid is trusted.
watcher_pid_is_ours() {
  local pid="$1" out
  kill -0 "$pid" 2>/dev/null || return 1
  if out="$(ps -o command= -p "$pid" 2>/dev/null)" && [ -n "$out" ]; then
    printf '%s' "$out" | grep -q 'dsh-watch\.sh' || return 1
  fi
  return 0
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
  if [ -n "$old" ] && [ "$old" != "$$" ] && watcher_pid_is_ours "$old"; then
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

case "$AGMSG_PLATFORM" in
  MINGW*|MSYS*|CYGWIN*)
    BASH_WIN="/c/Program Files/Git/bin/bash.exe"
    if [ ! -x "$BASH_WIN" ]; then
      BASH_WIN="$(command -v bash 2>/dev/null || printf 'bash')"
      case "$BASH_WIN" in
        */usr/bin/bash) BASH_WIN="${BASH_WIN%/usr/bin/bash}/bin/bash" ;;
        */mingw64/bin/bash) BASH_WIN="${BASH_WIN%/mingw64/bin/bash}/bin/bash" ;;
      esac
    fi
    BASH_WIN="$(cygpath -w "$BASH_WIN" 2>/dev/null || printf '%s' "$BASH_WIN")"
    printf '\nagmsg watch: delivered - handle the messages above (reply with send.sh), then re-arm the watcher:\n  & %s %s %s   (pwsh, run_in_background: true)\n' \
      "'$BASH_WIN'" "'$(cygpath -w "$PLUGIN_DIR/dsh-watch.sh")'" "'$(cygpath -w "$PROJECT")'"
    ;;
  *)
    printf '\nagmsg watch: delivered - handle the messages above (reply with send.sh), then re-arm the watcher:\n  %q %q   (bash, run_in_background: true)\n' \
      "$PLUGIN_DIR/dsh-watch.sh" "$PROJECT"
    ;;
esac
