#!/usr/bin/env bash
# dsh delivery plug — per-project marker file plus a globally registered
# Claude Code-format hook config that dsh's hooks bridge runs.
#
# Why not the default JSON event-hooks: dsh's @deepseek-ai/dsh-hooks-claude-code
# bridge reads ONE config per process (configPath, read once at startup), not a
# per-project settings file. So the hooks live once in ~/.dsh/agmsg-hooks.json
# (installed by dsh-install.sh) and decide per session whether to act by
# looking for this project's marker, <project>/.dsh/agmsg-delivery. The marker
# body is the mode; only `monitor` exists today, `off` removes the file.
#
# Uses resolve_hooks_file + RUN_DIR from delivery.sh's sourced context.

_agmsg_dsh_plugin_dir() {
  agmsg_type_dir dsh 2>/dev/null
}

agmsg_delivery_apply() {
  local type="$1" project="$2" mode="$3"
  local marker
  marker="$(resolve_hooks_file "$type" "$project")" || return 1
  case "$mode" in
    monitor)
      mkdir -p "$(dirname "$marker")"
      printf 'monitor\n' > "$marker"
      ;;
    off)
      rm -f "$marker"
      ;;
    *)
      echo "agmsg_delivery_apply (dsh): unsupported mode '$mode'" >&2
      return 1
      ;;
  esac
}

agmsg_delivery_on_enable() {
  local mode="$1" type="$2" project="$3"
  [ "$mode" = "monitor" ] || return 0
  local hooks="$HOME/.dsh/agmsg-hooks.json"
  if [ ! -f "$hooks" ]; then
    echo "  ! $hooks is missing: run $(_agmsg_dsh_plugin_dir)/dsh-install.sh so dsh runs the agmsg hooks."
  fi
  echo "  Restart the dsh session in $project: the SessionStart hook starts the inbox watcher."
}

agmsg_delivery_on_disable() {
  _agmsg_dsh_kill_watchers "$2"
}

agmsg_delivery_stop_directive() {
  cat <<'EOF'

AGMSG-DIRECTIVE: The dsh inbox watcher for this project has been stopped. Do not
start dsh-watch.sh again unless delivery is turned back on.
EOF
}

agmsg_delivery_status() {
  local type="$1" project="$2"
  local marker
  marker="$(resolve_hooks_file "$type" "$project")" || return 1
  if [ -f "$marker" ] && grep -q '^monitor$' "$marker" 2>/dev/null; then
    echo "mode: monitor"
  else
    echo "mode: off"
  fi
  echo "  marker: $marker"
  if [ -f "$HOME/.dsh/agmsg-hooks.json" ]; then
    echo "  hooks:  $HOME/.dsh/agmsg-hooks.json"
  else
    echo "  hooks:  MISSING ($HOME/.dsh/agmsg-hooks.json) - run dsh-install.sh"
  fi
}

agmsg_delivery_runtime_status() {
  local type="$1" project="$2"
  local alive=0 stale=0 f pid
  for f in "$RUN_DIR"/dsh-watch.*.pid; do
    [ -f "$f" ] || continue
    pid="$(cat "$f" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
       && ps -o command= -p "$pid" 2>/dev/null | grep -qF "dsh-watch.sh $project"; then
      alive=$((alive + 1))
    elif [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      stale=$((stale + 1))
    fi
  done
  echo "dsh watchers: $alive alive, $stale stale pidfiles"
}

# Kill this project's dsh-watch.sh processes (scoped by argv, like
# kill_all_watchers does for watch.sh).
_agmsg_dsh_kill_watchers() {
  local project="$1" f pid
  for f in "$RUN_DIR"/dsh-watch.*.pid; do
    [ -f "$f" ] || continue
    pid="$(cat "$f" 2>/dev/null || true)"
    [ -n "$pid" ] || { rm -f "$f"; continue; }
    if kill -0 "$pid" 2>/dev/null; then
      ps -o command= -p "$pid" 2>/dev/null | grep -qF "dsh-watch.sh $project" || continue
      pkill -TERM -P "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
    fi
    rm -f "$f"
  done
}
