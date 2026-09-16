#!/usr/bin/env bash
# Shows the updated AGENTS.md reaching a running Pi primary session through the
# real bin/fm-session-start.sh compact instruction refresh, reusing the world
# builders from tests/fm-session-start.test.sh.
# Usage: agents-md-instruction-refresh-e2e.sh <firstmate-checkout> <base-commit> <target-commit> <evidence-dir>
set -u
WT=$1 BASE=$2 TARGET=$3 EV=$4
cd "$WT" || exit 1
# shellcheck source=/dev/null
. tests/lib.sh
# shellcheck source=/dev/null
. tests/wake-helpers.sh
SESSION_START="$ROOT/bin/fm-session-start.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-agents-refresh-evidence)
SESSION_START_TEST_HARNESS_PID=$$
trap 'rm -rf "$TMP_ROOT"' EXIT
fm_git_identity fmtest fmtest@example.invalid

extract() {  # <function-name>
  awk -v name="$1" '
    index($0, name "() {") == 1 { on = 1; print; next }
    on && /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { exit }
    on { print }
  ' tests/fm-session-start.test.sh
}
for fn in new_world make_fake_toolchain make_fake_ps_harness run_pi_session_start; do
  eval "$(extract "$fn")"
done

rec=$(new_world agents-refresh)
IFS='|' read -r root home fakebin <<REC
$rec
REC
make_fake_toolchain "$fakebin"
make_fake_ps_harness "$fakebin" pi
git -C "$WT" show "$BASE:AGENTS.md" > "$root/AGENTS.md"
git -C "$WT" show "$TARGET:AGENTS.md" > "$TMP_ROOT/target-AGENTS.md"

echo "# AGENTS.md delivery to a running Pi primary session (real bin/fm-session-start.sh, fm-session-start.test.sh fixtures)"
echo
echo "\$ fm-session-start.sh --source startup                 # on-disk AGENTS.md = base ${BASE:0:7}"
startup=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source startup 2>&1)
printf 'exit ok; SESSION START digest present: %s; instruction refresh sections: %s\n' \
  "$(printf '%s\n' "$startup" | grep -c '^SESSION START - ')" \
  "$(printf '%s\n' "$startup" | grep -c '^CURRENT AGENTS.md - INSTRUCTION REFRESH$')"

cp "$TMP_ROOT/target-AGENTS.md" "$root/AGENTS.md"
echo
echo "\$ fm-session-start.sh --reemit --source compact        # AGENTS.md updated on disk to target ${TARGET:0:7}"
FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact > "$TMP_ROOT/compact.out" 2>&1
echo "exit $?"
refresh_line=$(grep -n '^CURRENT AGENTS.md - INSTRUCTION REFRESH$' "$TMP_ROOT/compact.out" | head -1 | cut -d: -f1)
bootstrap_line=$(grep -n '^BOOTSTRAP$' "$TMP_ROOT/compact.out" | head -1 | cut -d: -f1)
echo "INSTRUCTION REFRESH header at output line ${refresh_line:-<missing>}; BOOTSTRAP digest starts at line ${bootstrap_line:-<missing>}"
[ -n "$refresh_line" ] && [ -n "$bootstrap_line" ] || { sed -n 1,40p "$TMP_ROOT/compact.out"; exit 1; }
sed -n "${refresh_line},$((bootstrap_line - 1))p" "$TMP_ROOT/compact.out" > "$TMP_ROOT/refresh.txt"
sed "s#$TMP_ROOT#<scratch>#g" "$TMP_ROOT/refresh.txt" > "$EV/session-start-compact-instruction-refresh.txt"

echo
echo "--- refresh preamble (as emitted)"
first_contract_line=$(grep -nFx "$(head -1 "$TMP_ROOT/target-AGENTS.md")" "$TMP_ROOT/refresh.txt" | head -1 | cut -d: -f1)
sed -n "1,$((first_contract_line - 1))p" "$TMP_ROOT/refresh.txt" | sed "s#$TMP_ROOT#<scratch>#g"
contract_lines=$(wc -l < "$TMP_ROOT/target-AGENTS.md" | tr -d ' ')
sed -n "${first_contract_line},$((first_contract_line + contract_lines - 1))p" "$TMP_ROOT/refresh.txt" > "$TMP_ROOT/embedded.md"
if cmp -s "$TMP_ROOT/embedded.md" "$TMP_ROOT/target-AGENTS.md"; then
  echo "--- embedded contract: byte-identical to target AGENTS.md ($contract_lines lines)"
else
  echo "--- embedded contract DIFFERS from target AGENTS.md"; diff "$TMP_ROOT/embedded.md" "$TMP_ROOT/target-AGENTS.md" | head -20
fi
echo "--- after the contract (emitted lines until BOOTSTRAP)"
sed -n "$((first_contract_line + contract_lines)),\$p" "$TMP_ROOT/refresh.txt" | sed "s#$TMP_ROOT#<scratch>#g"

echo
echo "--- kept edits and review-round wording as the session receives them (line within the refresh)"
while IFS= read -r anchor; do
  hit=$(grep -nF -- "$anchor" "$TMP_ROOT/refresh.txt" | head -1)
  if [ -n "$hit" ]; then printf '  %s\n' "$(printf '%s' "$hit" | cut -c1-200)"; else printf '  MISSING: %s\n' "$anchor"; fi
done <<'ANCHORS'
If your working directory is inside `projects/`
Every means every: a one-line progress note
The digest is the only read of the context
A printed warning that supervision is down is itself the trigger
Session start is the only exception
A queued wake also blocks the next dispatch: when a command or guard warns of pending wakes this turn has not yet drained
Everything else follows this etiquette:
Check counts, "still running", unchanged poll results
reply `Captain, shipshape.` and nothing else
It is a complete reply, never a greeting
- The configured `tasks-axi` backend is the durable queue
`bin/fm-tasks-axi.sh <command> --help` own the backlog schema
Never invoke the bare `tasks-axi` binary
ANCHORS
echo "--- replaced wording no longer delivered (count within the refresh)"
printf '  "when any command or guard warns that wakes are pending": %s\n' "$(grep -cF 'when any command or guard warns that wakes are pending' "$TMP_ROOT/refresh.txt")"
printf '  "current `tasks-axi --help`": %s\n' "$(grep -cF 'current `tasks-axi --help`' "$TMP_ROOT/refresh.txt")"
