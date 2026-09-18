#!/usr/bin/env bash
# E2E reproduction of the defect: "the session-start check reports a closed
# worker window as still alive".
#
# Usage: e2e-session-start-closed-windows.sh <tree-under-test> <helpers-tree> <label>
#
# Builds a REAL tmux server on a private socket (never the host's sessions):
#   session `firstmate`, window `main` (where firstmate runs), worker windows
#   fm-alpha, fm-beta, fm-gamma. Then fm-beta and fm-gamma are killed, the way
#   the terminal restart closed the workers' windows; fm-alpha stays live as
#   a control. A remote secondmate meta (remote_host set) is also recorded.
# Then the REAL bin/fm-session-start.sh of <tree-under-test> runs from INSIDE
# the `main` pane of that server (TMUX/TMUX_PANE set by tmux itself), exactly
# where firstmate runs it, and its FLEET STATE digest is printed.
# Only the peripheral toolchain (gh, treehouse, node, lavish-axi, ps ancestry,
# ssh) is faked, using the same fixtures tests/fm-session-start.test.sh uses.
set -u
TREE=$(cd "$1" && pwd)
HELPERS=$(cd "$2" && pwd)
LABEL=$3
REAL_TMUX=$(command -v tmux)
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-e2e-closed.XXXXXX")
SOCK="fm-e2e-closed-$$"
T() { "$REAL_TMUX" -L "$SOCK" "$@"; }
cleanup() { T kill-server >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT

# Test fixtures: fake peripheral toolchain + fake harness ancestry.
# shellcheck source=/dev/null
. "$HELPERS/tests/lib.sh"
trap cleanup EXIT
eval "$(sed -n '/^make_fake_toolchain() {/,/^}/p; /^make_fake_ps_claude() {/,/^}/p; /^make_fake_ps_harness() {/,/^}/p' "$HELPERS/tests/fm-session-start.test.sh")"

mkdir -p "$W/home/state" "$W/home/data" "$W/home/config" "$W/fakebin"
git init -q -b main "$W/root"
git -C "$W/root" commit -q --allow-empty -m init
make_fake_toolchain "$W/fakebin"
make_fake_ps_claude "$W/fakebin"
# The real tmux, pinned to the private socket.
cat > "$W/fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
SH
chmod +x "$W/fakebin/tmux"
printf '#!/usr/bin/env bash\nexit 255\n' > "$W/fakebin/ssh"
chmod +x "$W/fakebin/ssh"

# --- the real tmux world ---------------------------------------------------
T new-session -d -s firstmate -n main -x 200 -y 50 'sleep 600'
T new-window -d -t firstmate: -n fm-alpha 'sleep 600'
T new-window -d -t firstmate: -n fm-beta 'sleep 600'
T new-window -d -t firstmate: -n fm-gamma 'sleep 600'
for id in alpha beta gamma; do
  printf 'window=firstmate:fm-%s\nkind=ship\nharness=claude\n' "$id" > "$W/home/state/$id.meta"
done
printf 'window=remote:sm-far\nendpoint_task_id=sm-far\nkind=secondmate\nharness=claude\nhome=/srv/fm-sm-far\nremote_host=far-box\nremote_root=/srv/fm-sm-far\n' \
  > "$W/home/state/sm-far.meta"

# The terminal restart closes the workers' windows.
T kill-window -t '=firstmate:=fm-beta'
T kill-window -t '=firstmate:=fm-gamma'

echo "=== [$LABEL] tree: $TREE ($(git -C "$TREE" rev-parse --short HEAD 2>/dev/null || cat "$TREE/.commit" 2>/dev/null))"
echo "=== tmux $("$REAL_TMUX" -V | cut -d' ' -f2), private socket; live windows in session firstmate:"
T list-windows -t '=firstmate' -F '    #{window_index}: #{window_name}'

# --- run firstmate's session start from inside the `main` pane --------------
RUNNER="$W/run-in-pane.sh"
cat > "$RUNNER" <<SH
#!/usr/bin/env bash
cd "$W"
{
  echo "context: TMUX_PANE=\${TMUX_PANE:-outside}"
  printf 'premise: tmux display-message -p -t firstmate:fm-beta #{pane_id} -> '
  out=\$(tmux display-message -p -t firstmate:fm-beta '#{pane_id}' 2>&1); rc=\$?
  echo "exit \$rc, printed '\$out'"
  printf 'premise: tmux has-session -t firstmate:fm-beta -> '
  out=\$(tmux has-session -t firstmate:fm-beta 2>&1); rc=\$?
  echo "exit \$rc, printed '\$out'"
} > "$W/premise.txt"
env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT -u FM_STATE_OVERRIDE \
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$W/home" FM_ROOT_OVERRIDE="$W/root" \
  "$TREE/bin/fm-session-start.sh" > "$W/out.txt" 2>&1
echo \$? > "$W/rc"
SH
chmod +x "$RUNNER"
T respawn-pane -k -t '=firstmate:=main' \
  "PATH='$W/fakebin:/usr/bin:/bin:/usr/sbin:/sbin'; export PATH; '$RUNNER'; sleep 600"
for _ in $(seq 1 600); do [ -s "$W/rc" ] && break; sleep 0.1; done
[ -s "$W/rc" ] || { echo "session start did not finish"; exit 1; }

cat "$W/premise.txt"
echo "=== bin/fm-session-start.sh exit status: $(cat "$W/rc")"
echo "=== FLEET STATE > Work under way (verbatim digest excerpt):"
awk '/Work under way/ { on = 1 } /Orphan status logs/ { on = 0 } on' "$W/out.txt"
echo "=== endpoint verdict lines:"
grep '^endpoint:' "$W/out.txt"
