#!/usr/bin/env bash
# Replays the AGENTS.md section 8 queued-wake dispatch rule against the real
# bin/fm-guard.sh, bin/fm-wake-drain.sh, and bin/fm-fleet-sync.sh in a scratch
# home as the main actor, with one task in flight and a healthy watcher so the
# queued-wakes warning is the only alarm in play.
# Usage: queued-wake-rule-e2e.sh <firstmate-checkout>
set -u
ROOT=$1
cd "$ROOT" || exit 1
dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-queued-wake-e2e.XXXXXX")
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/state" "$dir/projects" "$dir/data" "$dir/config"
export FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_PROJECTS_OVERRIDE="$dir/projects"
export FM_GUARD_GRACE=300
unset FM_SUPERVISION_ACTOR FM_GUARD_READ_ONLY CLAUDECODE PI_CODING_AGENT

# One ship task in flight, supervised by a live watcher with a fresh beacon.
printf 'window=fmtest:fm-task-a\nkind=ship\n' > "$dir/state/task-a.meta"
identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$")
mkdir "$dir/state/.watch.lock"
printf '%s\n' "$$" > "$dir/state/.watch.lock/pid"
printf '%s\n' "$dir" > "$dir/state/.watch.lock/fm-home"
printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
touch "$dir/state/.last-watcher-beat"

append() {  # <kind> <key> <payload>
  bash -c '. "$1"; fm_wake_append "$2" "$3" "$4"' _ "$ROOT/bin/fm-wake-lib.sh" "$@"
}
run() {
  printf '\n$ %s\n' "$*"
  "$@" > "$dir/out" 2> "$dir/err" < /dev/null
  rc=$?
  if [ -s "$dir/out" ]; then printf -- '--- stdout\n'; cat "$dir/out"; fi
  if [ -s "$dir/err" ]; then printf -- '--- stderr\n'; cat "$dir/err"; fi
  printf '[exit %s]\n' "$rc"
}
boundary() {
  sed -n 's/^WAKE_ACK_REQUIRED:.*\(--ack-through [0-9][0-9]* --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/err" | tail -1
}
queued() {
  printf 'rows still in state/.wake-queue: %s\n' "$(grep -c "$(printf '\t')" "$dir/state/.wake-queue" 2>/dev/null || echo 0)"
}

echo "# AGENTS.md section 8: \"when a command or guard warns of pending wakes this turn has not yet drained,"
echo "#                       drain and handle them before spawning, syncing, or tearing down\""
echo "# Scratch home, main actor, one ship task in flight, live watcher; real guard/drain/fleet-sync."

echo
echo "== 1. A worker signal (its PR merged) is queued before main's wake-handling turn =="
append signal task-a.status "signal: task-a: PR merged"
queued
run bin/fm-guard.sh
echo ">> Nothing drained this turn yet, so the rule applies: drain and handle before anything else."

echo
echo "== 2. Main drains at the start of the wake-handling turn =="
run bin/fm-wake-drain.sh
ack1=$(boundary)
queued
echo ">> Presented, but the row stays queued until the acknowledgement, so the drain's own closing guard repeats the warning."

echo
echo "== 3. Handling that merged PR needs the fleet sync; the guard inside it warns again =="
run bin/fm-fleet-sync.sh
echo ">> These rows were already drained this turn, so the scoped rule lets the sync - the handling itself - proceed."

echo
echo "== 4. What the replaced unscoped wording demanded instead: drain again before syncing =="
run bin/fm-wake-drain.sh
ack2=$(boundary)
queued
echo ">> Same row presented a second time, same warning: draining cannot clear it, so the sync never gets its turn."

echo
echo "== 5. Handling complete: acknowledge through the presented boundary =="
# shellcheck disable=SC2086
run bin/fm-wake-drain.sh $ack2
queued
run bin/fm-guard.sh
echo ">> Queue clear, guard silent."

echo
echo "== 6. A fresh wake lands later in the turn: this one has NOT been drained =="
append signal task-b.status "signal: task-b: needs captain input"
run bin/fm-guard.sh
echo ">> The rule applies again: drain and handle it before the next spawn, sync, or teardown."
run bin/fm-wake-drain.sh
ack3=$(boundary)
# shellcheck disable=SC2086
run bin/fm-wake-drain.sh $ack3
queued
