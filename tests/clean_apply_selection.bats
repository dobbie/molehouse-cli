#!/usr/bin/env bats
# `mo clean --apply-selection [--json]` — Molehouse CONTRACT.md §5.5 (SEL-M).
#
# The property under test: Mole removes only the intersection of what THIS
# run's scan proposes and what the user selected, and it moves that to the
# Trash. Each scenario test asserts on the filesystem — what is still on disk
# and what is in the sandbox Trash — not only on the counts the payload
# reports, because a payload can agree with a broken gate.
#
# Every run uses a throwaway HOME built here. Host tools a real scan shells out
# to (sudo, brew, xcrun, osascript, tmutil) are inert PATH stubs.

bats_require_minimum_version 1.5.0

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME
}

teardown_file() {
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-apply-selection.XXXXXX")"
    export HOME
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-clean-apply-selection."* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    export TERM="xterm-256color"
    export NO_COLOR=1
    TMPDIR="$HOME/tmp"
    export TMPDIR
    mkdir -p "$TMPDIR" "$HOME/.config/mole" "$HOME/.Trash"

    STUB_BIN="$HOME/stub-bin"
    mkdir -p "$STUB_BIN"
    local tool
    for tool in sudo xcrun osascript tmutil; do
        printf '#!/bin/bash\nexit 1\n' > "$STUB_BIN/$tool"
    done
    cat > "$STUB_BIN/brew" << 'MOCK'
#!/bin/bash
case "${1:-}" in
    --cache) echo "$HOME/Library/Caches/Homebrew" ;;
    --prefix) echo "$HOME/homebrew" ;;
esac
exit 0
MOCK
    chmod +x "$STUB_BIN"/*

    CACHES="$HOME/Library/Caches"
    mkdir -p "$CACHES/com.example.SelA" "$CACHES/com.example.SelB" "$HOME/Documents"
    dd if=/dev/zero of="$CACHES/com.example.SelA/blob.bin" bs=1024 count=64 2> /dev/null
    dd if=/dev/zero of="$CACHES/com.example.SelB/blob.bin" bs=1024 count=32 2> /dev/null
    printf 'keep me\n' > "$HOME/Documents/keep.txt"
}

teardown() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-clean-apply-selection."* ]]; then
        chmod -R u+w "$HOME" 2> /dev/null || true
        rm -rf "$HOME"
    fi
}

# Run mole with the sandbox environment. Extra leading VAR=value words are
# passed through env. MOLE_TEST_NO_AUTH=1 plus MOLE_TEST_TRASH_DIR is the
# default; tests that exercise the real Trash mover override both.
run_mole() {
    run --separate-stderr env HOME="$HOME" TMPDIR="$TMPDIR" PATH="$STUB_BIN:$PATH" \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 MOLE_TEST_TRASH_DIR="$HOME/.Trash" \
        MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT="$HOME/absent-sim-runtime-volumes" \
        MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT="$HOME/absent-sim-runtime-cryptex" \
        MOLE_LSREGISTER_PATH="" \
        "$@"
}

selection_doc() {
    local out="$HOME/selection.json"
    jq -n '{schema_version: 1, selected_paths: $ARGS.positional}' --args "$@" > "$out"
    printf '%s\n' "$out"
}

assert_untouched_fixtures() {
    [[ -f "$CACHES/com.example.SelA/blob.bin" ]] || { echo "SelA was removed by a refused request"; return 1; }
    [[ -f "$CACHES/com.example.SelB/blob.bin" ]] || { echo "SelB was removed by a refused request"; return 1; }
    [[ -z "$(ls -A "$HOME/.Trash")" ]] || { echo "the sandbox Trash is not empty:"; ls -A "$HOME/.Trash"; return 1; }
}

# --- usage errors: exit 2, nothing removed ---------------------------------

@test "usage: --apply-selection with --dry-run is refused before any scan" {
    local doc
    doc=$(selection_doc "$CACHES/com.example.SelA")
    run_mole "$PROJECT_ROOT/mole" clean --apply-selection --dry-run --json < "$doc"
    [ "$status" -eq 2 ] || { echo "status=$status"; return 1; }
    [ -z "$output" ] || { echo "stdout should be empty for a flag error: $output"; return 1; }
    [[ "$stderr" == *"does not accept --dry-run"* ]] || { echo "$stderr"; return 1; }
    assert_untouched_fixtures
}

@test "usage: --apply-selection with --external is refused before any scan" {
    local doc
    doc=$(selection_doc "$CACHES/com.example.SelA")
    # A target that passes --external's own validation, so the refusal under
    # test is --apply-selection's and not the volume check's.
    mkdir -p "$HOME/Volumes/Ext"
    printf '#!/bin/bash\nexit 1\n' > "$STUB_BIN/diskutil"
    chmod +x "$STUB_BIN/diskutil"
    run_mole MOLE_EXTERNAL_VOLUMES_ROOT="$HOME/Volumes" \
        "$PROJECT_ROOT/mole" clean --apply-selection --external "$HOME/Volumes/Ext" --json < "$doc"
    [ "$status" -eq 2 ] || { echo "status=$status $stderr"; return 1; }
    [[ "$stderr" == *"does not support --external"* ]] || { echo "$stderr"; return 1; }
    assert_untouched_fixtures
}

@test "usage: every malformed selection exits 2 with a failed envelope and removes nothing" {
    local -a docs=(
        '{not json'
        '{"schema_version":1,"selected_paths":[]}'
        '{"schema_version":1}'
        '{"schema_version":2,"selected_paths":["/tmp/x"]}'
        '{"schema_version":"1","selected_paths":["/tmp/x"]}'
        '{"schema_version":1,"selected_paths":"/tmp/x"}'
        '{"schema_version":1,"selected_paths":[5]}'
        '{"schema_version":1,"selected_paths":["Library/Caches/com.example.SelA"]}'
        "{\"schema_version\":1,\"selected_paths\":[\"$CACHES/com.example.SelB/../com.example.SelA\"]}"
        "{\"schema_version\":1,\"selected_paths\":[\"$HOME\"]}"
        '{"schema_version":1,"selected_paths":["/"]}'
    )
    local doc
    for doc in "${docs[@]}"; do
        printf '%s' "$doc" > "$HOME/bad.json"
        run_mole "$PROJECT_ROOT/mole" clean --apply-selection --json < "$HOME/bad.json"
        [ "$status" -eq 2 ] || { echo "exit $status for: $doc"; return 1; }
        [[ "$(jq -r '.scan_status' <<< "$output")" == "failed" ]] || { echo "no failed envelope for: $doc -> $output"; return 1; }
        [[ "$(jq -r '.error.code' <<< "$output")" == "invalid_selection" ]] || { echo "wrong code for: $doc"; return 1; }
        [[ "$(jq -r '.mode' <<< "$output")" == "apply" ]] || return 1
        [[ "$(jq -r '.data' <<< "$output")" == "null" ]] || return 1
        [[ -n "$stderr" ]] || { echo "no stderr reason for: $doc"; return 1; }
        assert_untouched_fixtures || { echo "...after: $doc"; return 1; }
    done
}

@test "usage: a malformed selection without --json exits 2 with empty stdout" {
    printf '{not json' > "$HOME/bad.json"
    run_mole "$PROJECT_ROOT/mole" clean --apply-selection < "$HOME/bad.json"
    [ "$status" -eq 2 ] || return 1
    [ -z "$output" ] || { echo "$output"; return 1; }
    [[ "$stderr" == *"not a valid JSON document"* ]] || { echo "$stderr"; return 1; }
    assert_untouched_fixtures
}

@test "usage: bare clean --json without --dry-run stays rejected" {
    run_mole "$PROJECT_ROOT/mole" clean --json < /dev/null
    [ "$status" -eq 2 ] || return 1
    [[ "$stderr" == *"requires --dry-run"* ]] || { echo "$stderr"; return 1; }
    assert_untouched_fixtures
}

# --- the selection property, on the real scan ------------------------------

@test "a real apply removes only the selected proposal; the unselected, the unproposed and the late file survive" {
    # Preview first: prove SelA and SelB are both proposals of this scan, so
    # SelB surviving below is the gate's doing, not a scan that missed it.
    run_mole "$PROJECT_ROOT/mole" clean --dry-run --json
    [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
    local preview="$output"
    jq -e --arg p "$CACHES/com.example.SelA" '[.data.categories[].entries[].path] | index($p) != null' <<< "$preview" > /dev/null ||
        { echo "precondition: the preview must propose SelA"; return 1; }
    jq -e --arg p "$CACHES/com.example.SelB" '[.data.categories[].entries[].path] | index($p) != null' <<< "$preview" > /dev/null ||
        { echo "precondition: the preview must propose SelB"; return 1; }

    # After the preview: a new proposable cache folder inside no selection.
    mkdir -p "$CACHES/com.example.Late"
    dd if=/dev/zero of="$CACHES/com.example.Late/late.bin" bs=1024 count=16 2> /dev/null

    local doc
    doc=$(selection_doc "$CACHES/com.example.SelA" "$HOME/Documents/keep.txt" "$CACHES/com.example.Ghost")
    run_mole "$PROJECT_ROOT/mole" clean --apply-selection --json < "$doc"
    [ "$status" -eq 0 ] || { echo "exit $status: $stderr"; return 1; }
    local json="$output"

    # 1. Proposed but unselected: still on disk.
    [[ -f "$CACHES/com.example.SelB/blob.bin" ]] ||
        { echo "SelB was proposed but NOT selected, and it was removed"; return 1; }
    # 2. Selected but not proposed: still on disk, and reported as not proposed.
    [[ -f "$HOME/Documents/keep.txt" ]] ||
        { echo "a selected path the scan never proposed was removed"; return 1; }
    jq -e --arg p "$HOME/Documents/keep.txt" '.data.selection.not_proposed | index($p) != null' <<< "$json" > /dev/null ||
        { echo "keep.txt missing from not_proposed: $(jq -c .data.selection <<< "$json")"; return 1; }
    jq -e --arg p "$CACHES/com.example.Ghost" '.data.selection.not_proposed | index($p) != null' <<< "$json" > /dev/null || return 1
    # 3. Appeared after the preview, inside no selection: still on disk.
    [[ -f "$CACHES/com.example.Late/late.bin" ]] ||
        { echo "a file created after the preview, inside no selected path, was removed"; return 1; }
    # 4. Selected and proposed: gone from its place and present in the Trash.
    [[ ! -e "$CACHES/com.example.SelA" ]] || { echo "the selected proposal is still in place"; return 1; }
    local trashed
    trashed=$(find "$HOME/.Trash" -name 'blob.bin' -path '*com.example.SelA*' | head -1)
    [[ -n "$trashed" && "$(stat -f%z "$trashed")" -eq 65536 ]] ||
        { echo "SelA did not arrive intact in the sandbox Trash"; ls -laR "$HOME/.Trash"; return 1; }

    [[ "$(jq -r '.data.delete_mode' <<< "$json")" == "trash" ]] || return 1
    [[ "$(jq -r '.data.removed_items' <<< "$json")" == "1" ]] || { jq -c .data <<< "$json"; return 1; }
    [[ "$(jq -r '.data.freed_bytes' <<< "$json")" == "65536" ]] || return 1
    [[ "$(jq -r '.data.selection.requested' <<< "$json")" == "3" ]] || return 1
    [[ "$(jq -r '.data.selection.removed_or_partial' <<< "$json")" == "1" ]] || return 1
    # SelB and Late were proposed and left alone: counted, never as failures.
    [[ "$(jq -r '.data.selection.not_selected_items' <<< "$json")" -ge 2 ]] || return 1
    [[ "$(jq -r '.data.failed_items' <<< "$json")" == "0" ]] || return 1
    [[ "$(jq -r '.data.skipped_items' <<< "$json")" == "0" ]] || return 1

    run python3 "$PROJECT_ROOT/tests/schemas/validate.py" \
        "$PROJECT_ROOT/tests/schemas/clean_apply.schema.json" /dev/stdin <<< "$json"
    [ "$status" -eq 0 ] || { echo "schema: $output"; return 1; }
}

@test "the real Trash mover puts the selection in the invoking user's Trash, and a caller cannot make it permanent" {
    local doc
    doc=$(selection_doc "$CACHES/com.example.SelA")
    # No MOLE_TEST_NO_AUTH and no MOLE_TEST_TRASH_DIR: the production mover.
    # sudo and osascript are stubs, so nothing can authenticate or prompt.
    run --separate-stderr env -u MOLE_TEST_NO_AUTH -u MOLE_TEST_TRASH_DIR \
        HOME="$HOME" TMPDIR="$TMPDIR" PATH="$STUB_BIN:$PATH" \
        MOLE_TEST_MODE=0 MOLE_DELETE_MODE=permanent \
        MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT="$HOME/absent-sim-runtime-volumes" \
        MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT="$HOME/absent-sim-runtime-cryptex" \
        MOLE_LSREGISTER_PATH="" \
        "$PROJECT_ROOT/mole" clean --apply-selection --json < "$doc"
    [ "$status" -eq 0 ] || { echo "exit $status: $stderr"; return 1; }

    [[ ! -e "$CACHES/com.example.SelA" ]] || { echo "SelA is still in place"; return 1; }
    [[ -f "$HOME/.Trash/com.example.SelA/blob.bin" ]] ||
        { echo "SelA is not in \$HOME/.Trash: MOLE_DELETE_MODE=permanent from the caller must not win"; ls -la "$HOME/.Trash"; return 1; }
    [[ -f "$CACHES/com.example.SelB/blob.bin" ]] || return 1
    [[ "$(jq -r '.data.delete_mode' <<< "$output")" == "trash" ]] || return 1
}

@test "without --json, a person in Terminal gets human output and the same selection behaviour" {
    local doc
    doc=$(selection_doc "$CACHES/com.example.SelA" "$CACHES/com.example.Ghost")
    run_mole "$PROJECT_ROOT/mole" clean --apply-selection < "$doc"
    [ "$status" -eq 0 ] || { echo "exit $status: $stderr"; return 1; }
    [[ "$output" != *'"schema_version"'* ]] || { echo "JSON on the human path"; return 1; }
    [[ "$output" == *"Selection"*"1 moved to the Trash"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"com.example.Ghost"* ]] || { echo "the unproposed path is not named"; return 1; }
    [[ ! -e "$CACHES/com.example.SelA" ]] || return 1
    [[ -f "$CACHES/com.example.SelB/blob.bin" ]] || return 1
}

# --- the gate itself, at the shared sinks ----------------------------------

# Source the real file_ops.sh and drive the sinks directly, so each sink's
# gate is tested on its own rather than through whichever caller reaches it.
run_sink_script() {
    run env HOME="$HOME" TMPDIR="$TMPDIR" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_TEST_NO_AUTH=1 MOLE_TEST_TRASH_DIR="$HOME/.Trash" \
        /bin/bash --noprofile --norc "$@"
}

@test "gate: safe_remove, safe_remove_symlink and mole_delete refuse an unselected target and trash a selected one" {
    ln -s "$HOME/Documents/keep.txt" "$CACHES/com.example.SelB/link"
    run_sink_script << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
sel=$(mktemp "$TMPDIR/sel.XXXXXX"); res=$(mktemp "$TMPDIR/res.XXXXXX")
printf '%s\0' "$HOME/Library/Caches/com.example.SelA" > "$sel"
export MOLE_CLEAN_SELECTION_FILE="$sel" MOLE_CLEAN_SELECTION_RESULTS_FILE="$res" MOLE_DELETE_MODE=trash
C="$HOME/Library/Caches"
safe_remove "$C/com.example.SelB" true && { echo "safe_remove removed an unselected dir"; exit 1; }
[[ -d "$C/com.example.SelB" ]] || { echo "SelB gone after safe_remove"; exit 1; }
safe_remove_symlink "$C/com.example.SelB/link" && { echo "symlink removed"; exit 1; }
[[ -L "$C/com.example.SelB/link" ]] || { echo "unselected symlink gone"; exit 1; }
mole_delete "$C/com.example.SelB/blob.bin" && { echo "mole_delete removed an unselected file"; exit 1; }
[[ -f "$C/com.example.SelB/blob.bin" ]] || { echo "SelB blob gone after mole_delete"; exit 1; }
safe_remove "$C/com.example.SelA/blob.bin" true || { echo "selected child refused"; exit 1; }
[[ ! -e "$C/com.example.SelA/blob.bin" ]] || { echo "selected child still present"; exit 1; }
ls "$HOME/.Trash" | grep -q '^blob.bin' || { echo "selected child not in Trash"; exit 1; }
tr '\0' '\n' < "$res" | grep -c '^not_selected$' | grep -qx 3 || { echo "expected 3 not_selected records"; exit 1; }
echo GATE_OK
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *GATE_OK* ]] || { echo "$output"; return 1; }
}

@test "gate: a target spelt with .. under a selected root is refused, not resolved" {
    run_sink_script << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
sel=$(mktemp "$TMPDIR/sel.XXXXXX"); res=$(mktemp "$TMPDIR/res.XXXXXX")
printf '%s\0' "$HOME/Library/Caches/com.example.SelA" > "$sel"
export MOLE_CLEAN_SELECTION_FILE="$sel" MOLE_CLEAN_SELECTION_RESULTS_FILE="$res"
safe_remove "$HOME/Library/Caches/com.example.SelA/../com.example.SelB" true && { echo "dotdot escape removed"; exit 1; }
[[ -d "$HOME/Library/Caches/com.example.SelB" ]] || { echo "SelB gone through a .. escape"; exit 1; }
echo DOTDOT_OK
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *DOTDOT_OK* ]] || return 1
}

@test "gate: an armed selection whose file is missing permits nothing" {
    run_sink_script << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
export MOLE_CLEAN_SELECTION_FILE="$TMPDIR/does-not-exist"
safe_remove "$HOME/Library/Caches/com.example.SelA" true && { echo "removed with no readable selection"; exit 1; }
[[ -d "$HOME/Library/Caches/com.example.SelA" ]] || exit 1
echo FAIL_CLOSED_OK
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *FAIL_CLOSED_OK* ]] || return 1
}

@test "gate: owner-tool cleanups refuse under a selection and report a selected scope as skipped" {
    run_sink_script << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
mole_selection_refuses "npm cache" "$HOME/.npm" && { echo "refused with no selection armed"; exit 1; }
sel=$(mktemp "$TMPDIR/sel.XXXXXX"); res=$(mktemp "$TMPDIR/res.XXXXXX")
printf '%s\0' "$HOME/.npm" > "$sel"
export MOLE_CLEAN_SELECTION_FILE="$sel" MOLE_CLEAN_SELECTION_RESULTS_FILE="$res"
mole_selection_refuses "npm cache" "$HOME/.npm" || { echo "ran under a selection"; exit 1; }
mole_selection_refuses "Homebrew cleanup" "$HOME/Library/Caches/Homebrew" || { echo "ran under a selection"; exit 1; }
records=$(tr '\0' '\n' < "$res")
grep -qx 'unsupported_in_selection' <<< "$records" || { echo "selected scope not reported skipped"; exit 1; }
grep -qx 'not_selected' <<< "$records" || { echo "unselected scope not counted"; exit 1; }
echo REFUSE_OK
EOF
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *REFUSE_OK* ]] || return 1
}

@test "audit: every owner-tool and raw removal on the clean path is behind the selection gate" {
    # Source invariant for the SEL-M audit. Each of these lines deletes
    # outside the shared sinks; each must sit after a mole_selection_refuses
    # check in the same function. A new one added without a gate fails here.
    run python3 - "$PROJECT_ROOT" << 'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
sinks = [
    ("lib/clean/dev.sh", r'^\s*if "\$@" > /dev/null 2>&1; then'),          # clean_tool_cache
    ("lib/clean/dev.sh", r'bun pm cache rm'),
    ("lib/clean/dev.sh", r'command_args\+=\("\$clean_flag"\)'),          # go clean
    ("lib/clean/dev.sh", r'_run_simctl "\$MOLE_TIMEOUT_PKG_CLEANUP_SEC" delete unavailable'),
    ("lib/clean/brew.sh", r'brew cleanup --prune'),
    ("lib/clean/system.sh", r'tmutil delete "\$inprogress_file"'),
    ("lib/clean/user.sh", r'run_with_timeout .*tart prune --entries caches'),
    ("lib/clean/apps.sh", r'command rm -f -- "\$metadata_plist"'),
]
bad = []
for rel, pattern in sinks:
    lines = (root / rel).read_text().splitlines()
    hits = [i for i, l in enumerate(lines) if re.search(pattern, l) and not l.lstrip().startswith("#")]
    if not hits:
        bad.append(f"{rel}: pattern not found (guard went blind): {pattern}")
        continue
    for i in hits:
        # Walk back to the enclosing function header; a gate must appear between.
        j, gated = i, False
        while j > 0 and not re.match(r'^[A-Za-z_][A-Za-z0-9_]*\(\) \{', lines[j]):
            if "mole_selection_refuses" in lines[j] or "mole_selection_active" in lines[j]:
                gated = True
            j -= 1
        if not gated:
            bad.append(f"{rel}:{i+1}: ungated: {lines[i].strip()}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
