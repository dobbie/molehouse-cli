#!/bin/bash
# Payload generators shared by tests/contract_schemas.bats and
# tests/contract_goldens.bats — CONTRACT.md's eight JSON payloads, produced
# from injected fixtures rather than from this machine wherever that is
# possible.
#
# Sourced, never executed. Bats files do not share function definitions, so the
# alternative was a second copy of the uninstall fixture harness in the second
# file; one copy that both files source is cheaper to keep honest.
#
# Every generator writes three files into $CONTRACT_PAYLOADS:
#   <name>.json     stdout
#   <name>.stderr   stderr, byte-counted by the §1.3 "nothing but JSON on
#                   stdout" assertions
#   <name>.rc       exit status
# so a test can assert the stream discipline without re-running the command.

# Resolve the two Go helpers the same way tests/cli.bats does: prebuilt by
# scripts/test.sh when the whole suite runs, built here for a focused run, and
# absent when Go is not installed — in which case the caller skips.
contract_resolve_go_bins() {
    if [[ -x "${MOLE_TEST_ANALYZE_BIN:-}" && -x "${MOLE_TEST_STATUS_BIN:-}" ]]; then
        ANALYZE_BIN="$MOLE_TEST_ANALYZE_BIN"
        STATUS_BIN="$MOLE_TEST_STATUS_BIN"
    elif command -v go > /dev/null 2>&1; then
        ANALYZE_BIN="$(mktemp "${TMPDIR:-/tmp}/contract-analyze-go.XXXXXX")"
        STATUS_BIN="$(mktemp "${TMPDIR:-/tmp}/contract-status-go.XXXXXX")"
        CONTRACT_OWNS_GO_BINS=1
        GOPATH="${ORIGINAL_HOME}/go" GOMODCACHE="${ORIGINAL_HOME}/go/pkg/mod" \
            GOCACHE="${ORIGINAL_GOCACHE}" \
            go build -o "$ANALYZE_BIN" "$PROJECT_ROOT/cmd/analyze" 2> /dev/null
        GOPATH="${ORIGINAL_HOME}/go" GOMODCACHE="${ORIGINAL_HOME}/go/pkg/mod" \
            GOCACHE="${ORIGINAL_GOCACHE}" \
            go build -o "$STATUS_BIN" "$PROJECT_ROOT/cmd/status" 2> /dev/null
    else
        ANALYZE_BIN=""
        STATUS_BIN=""
    fi
    export ANALYZE_BIN STATUS_BIN CONTRACT_OWNS_GO_BINS
}

# Run a command, capturing stdout, stderr and status under $1's name.
contract_capture() {
    local name="$1"
    shift
    local rc=0
    "$@" > "$CONTRACT_PAYLOADS/$name.json" 2> "$CONTRACT_PAYLOADS/$name.stderr" || rc=$?
    printf '%s\n' "$rc" > "$CONTRACT_PAYLOADS/$name.rc"
    return 0
}

# --- §4 analyze ------------------------------------------------------------

# Three directories with fixed contents and a fixed access time, so the payload
# is a function of the fixture and nothing else. `tiny` and `empty` are the
# F-017 pair: no file reaches the 1 MiB threshold, so `large_files` is absent,
# and `empty` additionally drops `total_files`.
contract_make_analyze_fixtures() {
    local root="$1"
    rm -rf "$root"
    mkdir -p "$root/tiny" "$root/empty" "$root/large/sub"
    printf 'hello' > "$root/tiny/a.txt"
    dd if=/dev/zero of="$root/large/big.bin" bs=1024 count=1600 2> /dev/null
    printf 'hello' > "$root/large/small.txt"
    printf 'x' > "$root/large/sub/inner.txt"
    # `last_access` is the file's atime. Pin it: a golden that records whatever
    # this machine's clock said is not a golden.
    TZ=UTC touch -a -t 202601020304.05 \
        "$root/tiny/a.txt" "$root/large/big.bin" "$root/large/small.txt" \
        "$root/large/sub/inner.txt"
}

# --- §5 clean --------------------------------------------------------------

# Stub the two host toolchains clean shells out to, as tests/clean_json.bats
# and tests/clean_core.bats do, plus a sudo that never has a cached credential.
contract_make_clean_mocks() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/sudo" << 'MOCK'
#!/bin/bash
# Shim: sudo -n always fails (no cached credentials).
exit 1
MOCK
    cat > "$dir/brew" << 'MOCK'
#!/bin/bash
case "${1:-}" in
    --cache) echo "$HOME/Library/Caches/Homebrew" ;;
    --prefix) echo "$HOME/homebrew" ;;
esac
exit 0
MOCK
    cat > "$dir/xcrun" << 'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$dir/sudo" "$dir/brew" "$dir/xcrun"
}

# --- §8 optimize -----------------------------------------------------------

# Whitelist every catalog action so no handler runs: execute_optimization
# short-circuits each task to `skipped` before dispatch. The same technique
# tests/optimize_json.bats and tests/optimize_summary.bats use to exercise
# optimize without touching real system state — and the reason the optimize
# payload is reproducible at all.
contract_whitelist_every_optimize_action() {
    local home="$1"
    mkdir -p "$home/.config/mole"
    PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc -c '
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/catalog.sh"
printf "%s\n" "${MOLE_OPTIMIZE_ACTIONS[@]}"
' > "$home/.config/mole/whitelist_optimize"
}

# --- §6/§7 uninstall -------------------------------------------------------

# A standalone entry point that loads the real bin/uninstall.sh function
# bodies, stubs only the scanner, and dispatches through the real main().
# Copied in shape from tests/uninstall_plan.bats, which is where the technique
# was established; running it as a FILE matters because --apply-plan reads its
# plan from stdin.
contract_write_uninstall_runner() {
    local runner="$1" apps_cache="$2"
    cat > "$runner" << RUNNER_EOF
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/core/history.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
SCRIPT_DIR="$PROJECT_ROOT/bin"
MOLE_UNINSTALL_EPOCH_FLOOR=978307200
log_operation_session_start() { :; }
log_operation_session_end() { :; }
show_uninstall_help() { :; }
hide_cursor() { :; }
show_cursor() { :; }
clear_screen() { :; }
uninstall_normalize_size_display() {
    local s="\${1:-}"
    [[ -z "\$s" || "\$s" == "0" || "\$s" == "Unknown" ]] && echo "N/A" || echo "\$s"
}
scan_applications() {
    local copy
    copy=\$(mktemp "\${TMPDIR:-/tmp}/mole-apps.XXXXXX") || return 1
    cat "$apps_cache" > "\$copy"
    printf '%s\n' "\$copy"
}
is_homebrew_available() { return 1; }
get_brew_cask_name() { return 1; }
load_applications() {
    apps_data=()
    apps_meta_data=()
    selection_state=()
    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb real_used app_mtime version; do
        apps_data+=("\$epoch|\$app_path|\$app_name|\$bundle_id|\$size|\$last_used|\${size_kb:-0}")
        apps_meta_data+=("\${real_used:-}|\${app_mtime:-}|\${version:-}")
    done < "\$1"
    [[ \${#apps_data[@]} -gt 0 ]]
}
eval "\$(sed -n '/^uninstall_list_mole_version()/,/main "\\\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '\$d')"
[[ -z "\${MOLE_TEST_HOOK:-}" ]] || source "\${MOLE_TEST_HOOK}"
main "\$@"
RUNNER_EOF
}

# One fixture app plus its leftovers, under the throwaway HOME. Byte sizes are
# fixed by construction, which is what lets the plan's totals be a golden.
contract_make_fixture_app() {
    local apps_cache="$1"
    local app="$HOME/Applications/Fixture.app"
    mkdir -p "$app/Contents"
    cat > "$app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.fixture</string>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
</dict></plist>
PLIST
    mkdir -p "$HOME/Library/Caches/com.example.fixture"
    printf 'cache\n' > "$HOME/Library/Caches/com.example.fixture/c.bin"
    mkdir -p "$HOME/Library/Preferences"
    printf 'pref\n' > "$HOME/Library/Preferences/com.example.fixture.plist"
    mkdir -p "$HOME/Library/Application Support/Fixture"
    printf 'data\n' > "$HOME/Library/Application Support/Fixture/d.bin"

    printf '1700000000|%s|Fixture|com.example.fixture|1MB|Today|1024|1700000000|1690000000|1.2.3\n' \
        "$app" > "$apps_cache"
}

# The §6 list fixture is a pure data fixture: two apps that are never on disk,
# one fully measured and one whose size could not be measured (§1.1's "--"
# sentinel). No path in it varies by machine, so its payload is a golden with
# nothing normalised but `generated_at`.
contract_make_list_cache() {
    cat > "$1" << 'CACHE'
1700000000|/Applications/Slack.app|Slack|com.tinyspeck.slackmacgap|180MB|Today|184320|1700000000|1690000000|4.36.0
1690000000|/Applications/Broken.app|Broken|com.example.broken|--|Unknown|0||1690000000|
CACHE
}

contract_run_uninstall() {
    env HOME="$HOME" MOLE_TEST_TRASH_DIR="${MOLE_TEST_TRASH_DIR:-}" \
        MOLE_TEST_NO_AUTH=1 MOLE_DELETE_LOG="${MOLE_DELETE_LOG:-}" TERM=dumb \
        MOLE_TEST_HOOK="${MOLE_TEST_HOOK:-}" \
        /bin/bash --noprofile --norc "$CONTRACT_RUNNER" "$@"
}

contract_run_uninstall_stdin() {
    local plan="$1"
    shift
    env HOME="$HOME" MOLE_TEST_TRASH_DIR="${MOLE_TEST_TRASH_DIR:-}" \
        MOLE_TEST_NO_AUTH=1 MOLE_DELETE_LOG="${MOLE_DELETE_LOG:-}" TERM=dumb \
        MOLE_TEST_HOOK="${MOLE_TEST_HOOK:-}" \
        /bin/bash --noprofile --norc "$CONTRACT_RUNNER" "$@" < "$plan"
}

# Add §7.4's `selected` array to a plan document. Extra arguments are path
# substrings; an entry is selected when its path contains one of them. With
# none, every entry that is neither protected nor privileged is selected.
contract_add_selection() {
    python3 - "$@" << 'PY'
import json, sys
src, dest, wanted = sys.argv[1], sys.argv[2], sys.argv[3:]
d = json.load(open(src))
entries = d["data"]["entries"]
if wanted:
    selected = [e["id"] for e in entries if any(w in e["path"] for w in wanted)]
else:
    selected = [
        e["id"] for e in entries if not e["protected"] and not e["requires_sudo"]
    ]
d["data"]["selected"] = selected
json.dump(d, open(dest, "w"))
PY
}

# Generate the §6/§7 payload set for one throwaway HOME.
#
#   contract_uninstall_payloads SUFFIX UHOME [selected-path-substring ...]
#
# Writes uninstall-list$SUFFIX, plan-trash$SUFFIX, plan-permanent$SUFFIX,
# plan-usage$SUFFIX, apply-mismatch$SUFFIX and apply$SUFFIX, plus
# uninstall$SUFFIX.root naming the sandbox root the goldens normalise away.
#
# HOME is a `local` here rather than an `export` in a subshell: the helpers
# below read it by dynamic scope, nothing outside this call sees it, and the
# caller's own HOME is untouched when it returns.
contract_uninstall_payloads() {
    local suffix="$1" uhome="$2"
    shift 2
    local HOME="$uhome"
    local MOLE_TEST_TRASH_DIR="$uhome/Trash"
    local MOLE_DELETE_LOG="$uhome/deletions.log"
    local CONTRACT_RUNNER="$uhome/runner.sh"
    local apps="$uhome/apps-cache"
    local list_cache="$uhome/apps-list-cache"

    mkdir -p "$uhome"
    printf '%s\n' "$uhome" > "$CONTRACT_PAYLOADS/uninstall$suffix.root"

    contract_make_list_cache "$list_cache"
    contract_write_uninstall_runner "$CONTRACT_RUNNER" "$list_cache"
    contract_capture "uninstall-list$suffix" contract_run_uninstall --list --json

    contract_write_uninstall_runner "$CONTRACT_RUNNER" "$apps"
    contract_make_fixture_app "$apps"
    contract_capture "plan-trash$suffix" contract_run_uninstall --plan Fixture --json
    contract_capture "plan-permanent$suffix" contract_run_uninstall \
        --plan Fixture --permanent --json
    contract_capture "plan-usage$suffix" contract_run_uninstall --plan NoSuchApp --json

    contract_add_selection "$CONTRACT_PAYLOADS/plan-trash$suffix.json" \
        "$uhome/selected.json" "$@"
    # §7.7: a trash plan applied under --permanent. Refused before anything is
    # deleted, which is why the real apply below still has a fixture to act on.
    contract_capture "apply-mismatch$suffix" contract_run_uninstall_stdin \
        "$uhome/selected.json" --apply-plan --permanent --json
    contract_capture "apply$suffix" contract_run_uninstall_stdin \
        "$uhome/selected.json" --apply-plan --json
}
