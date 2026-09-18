#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- missing-window probes never read the fallback pane ----------------------
# tmux resolves `display-message -t` loosely: a target naming a window that does
# not exist falls back to the session's current window and exits 0 (and a
# missing session reads empty, still exit 0), while a name that is a prefix of a
# live window resolves to that window for every command. Each recorded-target
# probe must instead match the exact recorded window and read a closed one as
# absent. The probes run twice - from outside any tmux client and from inside a
# pane of the private server, where TMUX and TMUX_PANE are set by tmux itself -
# because the fallback was first observed from inside a client; both contexts
# assert the raw fallback first so neither case can pass vacuously.

PROBE="$SHIM_DIR/probe-missing.sh"
cat > "$PROBE" <<'SH'
#!/usr/bin/env bash
# Prints one key=value verdict per probe for the smoke test to assert.
set -u
root=$1 session=$2 gone=$3 prefix=$4 live=$5
# shellcheck source=/dev/null
. "$root/bin/fm-backend.sh"
fm_backend_source tmux || { echo "source=failed"; exit 1; }
verdict() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }
nonempty() { local out; out=$("$@" 2>/dev/null) || out=; [ -n "$out" ] && echo yes || echo no; }
echo "context=${TMUX_PANE:-outside}"
echo "raw_fallback=$(verdict tmux display-message -p -t "$session:$gone" '#{pane_id}')"
echo "raw_prefix=$(tmux display-message -p -t "$session:$prefix" '#{window_name}' 2>/dev/null)"
echo "exists_live=$(verdict fm_backend_target_exists tmux "$session:$live")"
echo "exists_gone=$(verdict fm_backend_target_exists tmux "$session:$gone")"
echo "exists_prefix=$(verdict fm_backend_target_exists tmux "$session:$prefix")"
echo "exists_gone_session=$(verdict fm_backend_target_exists tmux "no-such-session-xyz:$live")"
live_pane=$(tmux list-panes -t "=$session:=$live" -F '#{pane_id}' | head -1)
live_window=$(tmux list-panes -t "=$session:=$live" -F '#{window_id}' | head -1)
echo "exists_live_pane=$(verdict fm_backend_target_exists tmux "$live_pane")"
echo "exists_live_window=$(verdict fm_backend_target_exists tmux "$live_window")"
echo "exists_gone_pane=$(verdict fm_backend_target_exists tmux '%99999')"
echo "exists_gone_window=$(verdict fm_backend_target_exists tmux '@99999')"
echo "state_gone=$(fm_backend_agent_state tmux "$session:$gone")"
echo "state_prefix=$(fm_backend_agent_state tmux "$session:$prefix")"
echo "capture_gone=$(verdict fm_backend_tmux_capture "$session:$gone" 5)"
echo "capture_prefix=$(verdict fm_backend_tmux_capture "$session:$prefix" 5)"
echo "capture_live=$(verdict fm_backend_tmux_capture "$session:$live" 5)"
echo "command_gone=$(nonempty fm_backend_tmux_current_command "$session:$gone")"
echo "command_live=$(nonempty fm_backend_tmux_current_command "$session:$live")"
echo "path_gone=$(nonempty fm_backend_tmux_current_path "$session:$gone")"
echo "path_live=$(nonempty fm_backend_tmux_current_path "$session:$live")"
echo "fg_gone=$(nonempty fm_backend_tmux_foreground_comms "$session:$gone")"
echo "fg_live=$(nonempty fm_backend_tmux_foreground_comms "$session:$live")"
echo "cursor_gone=$(nonempty fm_tmux_composer_cursor_row "$session:$gone")"
echo "busy_gone=$(fm_pane_busy_state "$session:$gone")"
echo "composer_gone=$(fm_tmux_composer_state "$session:$gone")"
echo "key_gone=$(verdict fm_backend_tmux_send_key "$session:$gone" Escape)"
echo "key_prefix=$(verdict fm_backend_tmux_send_key "$session:$prefix" Escape)"
echo "literal_prefix=$(verdict fm_backend_tmux_send_literal "$session:$prefix" x)"
echo "line_prefix=$(verdict fm_backend_tmux_send_text_line "$session:$prefix" x)"
echo "submit_prefix=$(fm_tmux_submit_core "$session:$prefix" x 1 0 0)"
SH
chmod +x "$PROBE"

GONE="fm-closed-worker"
PREFIX="fm-smoke1"
LIVE="fm-smoke1-sibling"
tmux new-window -d -t "$SESSION:" -n "$LIVE" 'sleep 600' \
  || fail "real tmux: could not create the live sibling window"
tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -qx "$GONE" \
  && fail "the missing-window fixture unexpectedly exists"
tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -qx "$PREFIX" \
  && fail "the prefix-window fixture unexpectedly exists"

expect_probe() {  # <output> <key> <value> <context>
  case $'\n'"$1"$'\n' in
    *$'\n'"$2=$3"$'\n'*) : ;;
    *) fail "real tmux ($4): expected $2=$3"$'\n'"$1" ;;
  esac
}

assert_missing_probes() {  # <output> <context>
  local out=$1 ctx=$2 key
  # The premise: raw tmux really does resolve both loose targets to a live
  # window here, so the exact probes below are what separates them.
  expect_probe "$out" raw_fallback yes "$ctx"
  expect_probe "$out" raw_prefix "$LIVE" "$ctx"
  for key in exists_live exists_live_pane exists_live_window capture_live command_live path_live fg_live; do
    expect_probe "$out" "$key" yes "$ctx"
  done
  for key in exists_gone exists_prefix exists_gone_session exists_gone_pane exists_gone_window \
    capture_gone capture_prefix command_gone path_gone fg_gone cursor_gone \
    key_gone key_prefix literal_prefix line_prefix; do
    expect_probe "$out" "$key" no "$ctx"
  done
  expect_probe "$out" state_gone missing "$ctx"
  expect_probe "$out" state_prefix missing "$ctx"
  expect_probe "$out" busy_gone unknown "$ctx"
  expect_probe "$out" composer_gone unknown "$ctx"
  expect_probe "$out" submit_prefix send-failed "$ctx"
}

out=$(env -u TMUX -u TMUX_PANE "$PROBE" "$ROOT" "$SESSION" "$GONE" "$PREFIX" "$LIVE" 2>&1)
expect_probe "$out" context outside "outside a client"
assert_missing_probes "$out" "outside a client"
pass "real tmux: from outside a client, every recorded-target probe reads a missing or prefix-only window as absent"

INSIDE_OUT="$SHIM_DIR/probe-inside.out"
INSIDE_RC="$SHIM_DIR/probe-inside.rc"
tmux new-window -d -t "$SESSION:" -n fm-probe-runner \
  "PATH='$PATH'; export PATH; '$PROBE' '$ROOT' '$SESSION' '$GONE' '$PREFIX' '$LIVE' > '$INSIDE_OUT' 2>&1; echo \$? > '$INSIDE_RC'; sleep 600" \
  || fail "real tmux: could not start the in-pane probe"
for _ in $(seq 1 200); do
  [ -s "$INSIDE_RC" ] && break
  sleep 0.1
done
[ -s "$INSIDE_RC" ] || fail "the in-pane probe did not finish"
out=$(cat "$INSIDE_OUT")
case $'\n'"$out" in
  *$'\n'context=%*) : ;;
  *) fail "the in-pane probe did not run inside a tmux pane"$'\n'"$out" ;;
esac
assert_missing_probes "$out" "inside a client pane"
pass "real tmux: from inside a client pane, every recorded-target probe reads a missing or prefix-only window as absent"

cleanup_all
trap - EXIT
