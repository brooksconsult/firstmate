#!/usr/bin/env bash
# e2e-session-start-closed-window.sh <checkout-root> <label>
#
# End-to-end reproduction of the reported defect: after a terminal restart
# closes worker windows, bin/fm-session-start.sh's fleet digest must not print
# `endpoint: alive` for them. Runs the REAL fm-session-start.sh of the given
# checkout against a REAL tmux server on a private socket (never the host's
# sessions), both from outside any tmux client and from inside a pane of that
# server (TMUX / TMUX_PANE set by tmux itself, the condition in the report).
#
# Fleet: session `firstmate` with window `main` (current), one live worker
# `fm-live-worker`, and two workers `fm-closed-a` / `fm-closed-b` whose windows
# were created and then killed, plus `fm-closed-a-restarted`, a live window
# whose name has the closed worker's name as a prefix.
set -u
CHECKOUT=$1
LABEL=$2
REAL_TMUX=$(command -v tmux)
SOCKET="fm-e2e-closed-$$"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-e2e-closed.XXXXXX")
W=$(cd -P "$W" && pwd -P)
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT

SHIM="$W/shim"; FAKE="$W/fakebin"; ROOT_REPO="$W/root"
mkdir -p "$SHIM" "$FAKE"
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"

# Deterministic stand-ins for the non-tmux toolchain bootstrap detects, so the
# digest does not depend on this host's network or installed CLIs.
for t in node chrome-devtools-axi gh; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$t"; done
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo 0.1.46\nexit 0\n' > "$FAKE/lavish-axi"
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo 0.1.29\nexit 0\n' > "$FAKE/gh-axi"
printf '#!/usr/bin/env bash\n[ "${1:-}" = get ] && [ "${2:-}" = --help ] && echo "Usage: treehouse get [--lease]"\nexit 0\n' > "$FAKE/treehouse"
printf '#!/usr/bin/env bash\n[ "${1:-}" = --version ] && echo "no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z"\nexit 0\n' > "$FAKE/no-mistakes"
chmod +x "$FAKE"/*
git init -q -b main "$ROOT_REPO"
git -C "$ROOT_REPO" -c user.name=e2e -c user.email=e2e@example.invalid commit -q --allow-empty -m init

PATH="$SHIM:$FAKE:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

tmux new-session -d -s firstmate -n main -x 200 -y 50
tmux new-window -d -t firstmate: -n fm-live-worker 'sleep 600'
tmux new-window -d -t firstmate: -n fm-closed-a 'sleep 600'
tmux new-window -d -t firstmate: -n fm-closed-b 'sleep 600'
# The terminal restart: every closed worker's window goes away.
tmux kill-window -t '=firstmate:=fm-closed-a'
tmux kill-window -t '=firstmate:=fm-closed-b'
tmux new-window -d -t firstmate: -n fm-closed-a-restarted 'sleep 600'

run_digest() {  # <context> <home>
  local ctx=$1 home=$2
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf 'window=firstmate:fm-live-worker\nkind=ship\n' > "$home/state/task-live.meta"
  printf 'window=firstmate:fm-closed-a\nkind=ship\n' > "$home/state/task-closed-a.meta"
  printf 'window=firstmate:fm-closed-b\nkind=ship\n' > "$home/state/task-closed-b.meta"
  if [ "$ctx" = outside ]; then
    env -u TMUX -u TMUX_PANE -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT_REPO" "$CHECKOUT/bin/fm-session-start.sh" \
      > "$home/digest.out" 2>&1
  else
    local rc="$home/digest.rc"
    tmux new-window -d -t firstmate: -n fm-digest-runner \
      "PATH='$PATH'; export PATH; env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT FM_HOME='$home' FM_ROOT_OVERRIDE='$ROOT_REPO' '$CHECKOUT/bin/fm-session-start.sh' > '$home/digest.out' 2>&1; echo \"TMUX_PANE=\$TMUX_PANE\" > '$home/context'; echo \$? > '$rc'; sleep 600"
    for _ in $(seq 1 600); do [ -s "$rc" ] && break; sleep 0.1; done
    tmux kill-window -t '=firstmate:=fm-digest-runner' 2>/dev/null || true
  fi
}

printf '### %s (%s)\n' "$LABEL" "$(git -C "$CHECKOUT" rev-parse --short HEAD 2>/dev/null || echo "$CHECKOUT")"
printf 'real tmux windows in session firstmate: %s\n' "$(tmux list-windows -t '=firstmate' -F '#{window_name}' | tr '\n' ' ')"
printf 'live worker pane: %s\n' "$(tmux list-panes -t '=firstmate:=fm-live-worker' -F '#{pane_id}')"
for w in fm-closed-a fm-closed-b; do
  printf 'raw probe  tmux display-message -p -t firstmate:%s #{window_name}/#{pane_id} -> %s (exit %s)\n' "$w" \
    "$(tmux display-message -p -t "firstmate:$w" '#{window_name}/#{pane_id}' 2>&1)" "$(tmux display-message -p -t "firstmate:$w" '#{pane_id}' >/dev/null 2>&1; echo $?)"
  printf 'raw probe  tmux has-session -t firstmate:%s -> %s\n' "$w" "$(tmux has-session -t "firstmate:$w" 2>&1; echo "(exit $?)")" | tr '\n' ' '
  echo
done
for ctx in outside inside; do
  home="$W/home-$ctx"
  run_digest "$ctx" "$home"
  where=$ctx
  [ "$ctx" = inside ] && where="inside tmux pane $(sed -n 's/^TMUX_PANE=//p' "$home/context" 2>/dev/null)"
  printf '\n-- fm-session-start.sh run %s --\n' "$where"
  grep -E '^(--- task-|endpoint:)' "$home/digest.out" || { echo "(no endpoint lines; digest tail follows)"; tail -20 "$home/digest.out"; }
done
