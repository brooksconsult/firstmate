#!/usr/bin/env bash
# tests/fake-tmux-inventory.sh - the pane inventory a fake tmux answers.
#
# Production resolves every recorded tmux target exactly against one
# `tmux list-panes -a` read (fm_tmux_resolve_pane in bin/fm-tmux-lib.sh), so a
# fake tmux that pretends a window exists must also list it.
# fm_test_fake_tmux_inventory (tests/fixtures.sh) copies this script into the
# fake's own directory, and the fake delegates:
#
#   list-panes) exec "$(dirname "$0")/fake-tmux-inventory.sh" list "$(dirname "$0")" ;;
#   new-window) exec "$(dirname "$0")/fake-tmux-inventory.sh" new-window "$(dirname "$0")" "$@" ;;
#
# `list` prints one production-format row per live window, in order:
#   1. every window the fake created through `new-window`, recorded in
#      <fakebin>/.tmux-windows with the id `new-window -P` printed, so that id
#      stays valid;
#   2. FM_FAKE_TMUX_INVENTORY, whitespace-separated <session>:<window> or
#      %<pane> entries a test declares live;
#   3. every window= target recorded in the state directory (FM_STATE_OVERRIDE,
#      else $FM_HOME/state), which is the "every recorded endpoint is live"
#      world most suites assume, unless FM_FAKE_TMUX_META_WINDOWS=0.
# A repeated entry is listed once. Created window N is @N with pane %N; the
# other entries are numbered from 1000, and a %<pane> entry keeps its own pane
# id.
#
# `new-window` records the -t session and -n name under the next free id and
# prints that id when the caller passed -P. Creating a name that is already
# recorded replaces it, the way a relaunch closes and recreates its window.
set -u

mode=${1:-}
dir=${2:-}
record="$dir/.tmux-windows"

entries() {
  local meta line state
  for line in ${FM_FAKE_TMUX_INVENTORY:-}; do
    printf '%s\n' "$line"
  done
  [ "${FM_FAKE_TMUX_META_WINDOWS:-1}" != 0 ] || return 0
  state=${FM_STATE_OVERRIDE:-}
  [ -n "$state" ] || { [ -n "${FM_HOME:-}" ] && state=$FM_HOME/state; } || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    line=$(grep -m1 '^window=' "$meta" 2>/dev/null) || continue
    printf '%s\n' "${line#window=}"
  done
}

case "$mode" in
  list)
    seen=$'\n'
    if [ -f "$record" ]; then
      while read -r n entry; do
        [ -n "$entry" ] || continue
        seen="$seen$entry"$'\n'
        printf '%s:@%s:%%%s:1:%s:%s\n' "$n" "$n" "$n" "${entry%%:*}" "${entry#*:}"
      done < "$record"
    fi
    n=999
    entries | while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$seen" in *$'\n'"$entry"$'\n'*) continue ;; esac
      seen="$seen$entry"$'\n'
      n=$((n + 1))
      case "$entry" in
        %*) printf '%s:@%s:%s:1:fake:pane%s\n' "$n" "$n" "$entry" "$n" ;;
        *:*) printf '%s:@%s:%%%s:1:%s:%s\n' "$n" "$n" "$n" "${entry%%:*}" "${entry#*:}" ;;
      esac
    done
    ;;
  new-window)
    shift 2
    session=firstmate name='' print=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) session=${2%%:*}; shift 2 ;;
        -n) name=$2; shift 2 ;;
        -c|-F|-e) shift 2 ;;
        -*P*) print=1; shift ;;
        *) shift ;;
      esac
    done
    [ -n "$name" ] || name=window
    id=1
    if [ -f "$record" ]; then
      id=$(awk 'BEGIN { m = 0 } $1 > m { m = $1 } END { print m + 1 }' "$record")
      awk -v entry="$session:$name" '$2 != entry' "$record" > "$record.next"
      mv "$record.next" "$record"
    fi
    printf '%s %s:%s\n' "$id" "$session" "$name" >> "$record"
    if [ "$print" = 1 ]; then
      printf '@%s\n' "$id"
    fi
    ;;
  *)
    echo "usage: fake-tmux-inventory.sh list|new-window <fakebin> [new-window args]" >&2
    exit 2
    ;;
esac
