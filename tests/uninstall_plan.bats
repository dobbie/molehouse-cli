#!/usr/bin/env bats

# CONTRACT.md §7 — `uninstall --plan` / `uninstall --apply-plan`.
#
# Every apply-path case runs against a fixture app inside a throwaway HOME with
# MOLE_TEST_TRASH_DIR pointed at a sandbox directory, exactly as
# tests/uninstall_remove_file_list.bats does. No test here may reach a real
# installed application, a real Trash, or a real Library.

# `run --separate-stderr` needs bats 1.5+. Several assertions here are about
# stdout being EMPTY (§1.6 exit 2), which the default merged capture cannot
# express.
bats_require_minimum_version 1.5.0

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
}

setup() {
    SANDBOX="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-uninstall-plan.XXXXXX")"
    export SANDBOX
    HOME="$SANDBOX/home"
    export HOME
    mkdir -p "$HOME"
    export MOLE_TEST_TRASH_DIR="$SANDBOX/Trash"
    export MOLE_TEST_NO_AUTH=1
    export MOLE_DELETE_LOG="$SANDBOX/deletions.log"
    export TERM="dumb"
    unset MOLE_DRY_RUN
    RUNNER="$SANDBOX/runner.sh"
    export RUNNER
    APPS_CACHE="$SANDBOX/apps"
    export APPS_CACHE
    write_runner
}

teardown() {
    if [[ "$SANDBOX" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        chmod -R u+w "$SANDBOX" 2> /dev/null || true
        rm -rf "$SANDBOX"
    fi
}

# A standalone entry point that loads the real bin/uninstall.sh function
# bodies, stubs only the scanner (so no real machine inventory is ever read),
# and dispatches through the real main(). Running it as a FILE rather than a
# heredoc matters: --apply-plan reads its plan from stdin.
write_runner() {
    cat > "$RUNNER" << RUNNER_EOF
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
# Production scan_applications hands back a temp file the caller owns and
# deletes. Copy the fixture inventory per call so a test can run the command
# more than once without the first run consuming the fixture.
scan_applications() {
    local copy
    copy=\$(mktemp "\${TMPDIR:-/tmp}/mole-apps.XXXXXX") || return 1
    cat "$APPS_CACHE" > "\$copy"
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

make_fixture_app() {
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
        "$app" > "$APPS_CACHE"
}

run_mole() {
    run --separate-stderr env HOME="$HOME" MOLE_TEST_TRASH_DIR="$MOLE_TEST_TRASH_DIR" \
        MOLE_TEST_NO_AUTH=1 MOLE_DELETE_LOG="$MOLE_DELETE_LOG" TERM=dumb \
        MOLE_TEST_HOOK="${MOLE_TEST_HOOK:-}" \
        /bin/bash --noprofile --norc "$RUNNER" "$@"
}

run_mole_stdin() {
    local plan="$1"
    shift
    run --separate-stderr env HOME="$HOME" MOLE_TEST_TRASH_DIR="$MOLE_TEST_TRASH_DIR" \
        MOLE_TEST_NO_AUTH=1 MOLE_DELETE_LOG="$MOLE_DELETE_LOG" TERM=dumb \
        MOLE_TEST_HOOK="${MOLE_TEST_HOOK:-}" \
        /bin/bash --noprofile --norc "$RUNNER" "$@" < "$plan"
}

# Write the plan for the fixture app to $1.
make_plan() {
    env HOME="$HOME" MOLE_TEST_TRASH_DIR="$MOLE_TEST_TRASH_DIR" \
        MOLE_TEST_NO_AUTH=1 MOLE_DELETE_LOG="$MOLE_DELETE_LOG" TERM=dumb \
        /bin/bash --noprofile --norc "$RUNNER" --plan Fixture --json > "$1"
}

# Add a `selected` array to a plan document. Extra args are entry paths whose
# ids should be selected; with none, every non-protected entry is selected.
add_selection() {
    local src="$1" dest="$2"
    shift 2
    python3 - "$src" "$dest" "$@" << 'PY'
import json, sys
src, dest = sys.argv[1], sys.argv[2]
wanted = sys.argv[3:]
d = json.load(open(src))
entries = d["data"]["entries"]
if wanted:
    sel = [e["id"] for e in entries if e["path"] in wanted]
else:
    sel = [e["id"] for e in entries if not e["protected"]]
d["data"]["selected"] = sel
json.dump(d, open(dest, "w"))
PY
}

jq_get() {
    python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{"d":d}))' "$1" "$2"
}

@test "uninstall --plan emits a §1.5 envelope with mode plan and one entry per discovered path" {
    make_fixture_app
    run_mole --plan Fixture --json

    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    printf '%s\n' "$output" > "$SANDBOX/plan.json"
    python3 - "$SANDBOX/plan.json" "$HOME" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
home = sys.argv[2]
assert d["schema_version"] == 1, d
assert d["command"] == "uninstall"
assert d["mode"] == "plan"
assert d["scan_status"] == "complete"
assert d["warnings"] == []
assert d["error"] is None
data = d["data"]
assert data["app"]["bundle_id"] == "com.example.fixture"
assert data["app"]["uninstall_name"] == "Fixture"
assert data["app"]["version"] == "1.2.3"
assert len(data["plan_digest"]) == 64
paths = {e["path"] for e in data["entries"]}
for expected in (
    home + "/Applications/Fixture.app",
    home + "/Library/Caches/com.example.fixture",
    home + "/Library/Preferences/com.example.fixture.plist",
    home + "/Library/Application Support/Fixture",
):
    assert expected in paths, (expected, paths)
assert data["total_items"] == len(data["entries"])
known = [e for e in data["entries"] if e["size_known"]]
assert data["total_bytes"] == sum(e["size_bytes"] for e in known)
assert data["unmeasured_items"] == len(data["entries"]) - len(known)
assert data["requires_sudo"] == any(e["requires_sudo"] for e in data["entries"])
PY
}

@test "uninstall --plan entry ids are sha256(path) truncated to 16 hex chars" {
    make_fixture_app
    run_mole --plan Fixture --json
    [ "$status" -eq 0 ] || return 1
    printf '%s\n' "$output" > "$SANDBOX/plan.json"

    local path id expected
    while IFS='	' read -r id path; do
        expected=$(printf '%s' "$path" | shasum -a 256 | cut -c1-16)
        [ "$id" = "$expected" ] || {
            echo "id mismatch for $path: $id != $expected"
            return 1
        }
    done < <(python3 -c '
import json,sys
for e in json.load(open(sys.argv[1]))["data"]["entries"]:
    print(e["id"] + "\t" + e["path"])
' "$SANDBOX/plan.json")
}

@test "uninstall --plan is byte-identical across two runs apart from generated_at" {
    make_fixture_app
    make_plan "$SANDBOX/a.json"
    make_plan "$SANDBOX/b.json"

    python3 - "$SANDBOX/a.json" "$SANDBOX/b.json" << 'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
assert a["data"]["plan_digest"] == b["data"]["plan_digest"]
a["generated_at"] = b["generated_at"] = "X"
assert json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)
PY
}

@test "uninstall_plan_digest ignores record order and changes with path or size" {
    run /bin/bash --noprofile --norc << EOF
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/core/history.sh"
SCRIPT_DIR="$PROJECT_ROOT/bin"
eval "\$(sed -n '/^uninstall_list_mole_version()/,/main "\\\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '\$d')"

us=\$'\x1f'
a="$SANDBOX/rec-a"
b="$SANDBOX/rec-b"
c="$SANDBOX/rec-c"
d="$SANDBOX/rec-d"
# Canonical order is LC_ALL=C sorted by path; \$b holds the same three entries
# written in a different order and sorted back into canonical order, which is
# what the production path always does.
printf '/a%s10%strue%sfalse%sfalse%sfalse%sother\n' "\$us" "\$us" "\$us" "\$us" "\$us" "\$us" > "\$a"
printf '/b%s20%strue%sfalse%sfalse%sfalse%sother\n' "\$us" "\$us" "\$us" "\$us" "\$us" "\$us" >> "\$a"
printf '/c%s%sfalse%sfalse%sfalse%sfalse%sother\n' "\$us" "\$us" "\$us" "\$us" "\$us" "\$us" >> "\$a"
tail -r "\$a" | LC_ALL=C sort > "\$b"
# One byte of size difference.
sed 's/^\/b'"\$us"'20/\/b'"\$us"'21/' "\$a" > "\$c"
# One path renamed.
sed 's/^\/b/\/z/' "\$a" | LC_ALL=C sort > "\$d"

da=\$(uninstall_plan_digest "com.example.fixture" "/Applications/Fixture.app" "\$a")
db=\$(uninstall_plan_digest "com.example.fixture" "/Applications/Fixture.app" "\$b")
dc=\$(uninstall_plan_digest "com.example.fixture" "/Applications/Fixture.app" "\$c")
dd=\$(uninstall_plan_digest "com.example.fixture" "/Applications/Fixture.app" "\$d")
de=\$(uninstall_plan_digest "com.example.other" "/Applications/Fixture.app" "\$a")
printf 'A=%s\nB=%s\nC=%s\nD=%s\nE=%s\n' "\$da" "\$db" "\$dc" "\$dd" "\$de"
EOF
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    local a b c d e
    a=$(printf '%s\n' "$output" | sed -n 's/^A=//p')
    b=$(printf '%s\n' "$output" | sed -n 's/^B=//p')
    c=$(printf '%s\n' "$output" | sed -n 's/^C=//p')
    d=$(printf '%s\n' "$output" | sed -n 's/^D=//p')
    e=$(printf '%s\n' "$output" | sed -n 's/^E=//p')

    [ "${#a}" -eq 64 ] || return 1
    [ "$a" = "$b" ] || return 1  # reordering the same entries cannot change it
    [ "$a" != "$c" ] || return 1 # a size change does
    [ "$a" != "$d" ] || return 1 # a path change does
    [ "$a" != "$e" ] # so does the app's bundle id
}

@test "uninstall_plan_classify_category maps each documented subtree" {
    run /bin/bash --noprofile --norc << EOF
set -uo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/core/history.sh"
SCRIPT_DIR="$PROJECT_ROOT/bin"
eval "\$(sed -n '/^uninstall_list_mole_version()/,/main "\\\$@"/p' "$PROJECT_ROOT/bin/uninstall.sh" | sed '\$d')"
app="/Applications/Fixture.app"
while IFS='|' read -r path want; do
    [[ -n "\$path" ]] || continue
    got=\$(uninstall_plan_classify_category "\$path" "\$app")
    printf '%s %s %s\n' "\$got" "\$want" "\$path"
done <<'TABLE'
/Applications/Fixture.app|bundle
/Users/x/Library/Caches/com.example.fixture|caches
/Users/x/Library/Preferences/com.example.fixture.plist|preferences
/Users/x/Library/Application Support/Fixture|application_support
/Users/x/Library/Containers/com.example.fixture|containers
/Users/x/Library/Group Containers/ABC.com.example|group_containers
/Users/x/Library/LaunchAgents/com.example.fixture.plist|launch_agents
/Users/x/Library/Logs/Fixture|logs
/Users/x/Library/Saved Application State/com.example.fixture.savedState|saved_state
/Users/x/.config/fixture|other
TABLE
EOF
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    local got want path
    while read -r got want path; do
        [ "$got" = "$want" ] || {
            echo "classify($path) = $got, wanted $want"
            return 1
        }
    done <<< "$output"
    # Positive control: the loop above must have seen every row.
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 10 ]
}

@test "uninstall --plan reports size_known false with no size_bytes when a path cannot be measured" {
    make_fixture_app
    # Force the measurement to fail for one path only, leaving the rest
    # measured, so the assertion cannot pass vacuously.
    cat > "$SANDBOX/hook.sh" << HOOK
_real_measure() { :; }
eval "\$(declare -f uninstall_plan_measure_bytes | sed '1s/uninstall_plan_measure_bytes/_real_measure/')"
uninstall_plan_measure_bytes() {
    case "\$1" in
        */com.example.fixture.plist) return 1 ;;
    esac
    _real_measure "\$1"
}
HOOK
    MOLE_TEST_HOOK="$SANDBOX/hook.sh" run_mole --plan Fixture --json
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    printf '%s\n' "$output" > "$SANDBOX/plan.json"

    python3 - "$SANDBOX/plan.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
data = d["data"]
unknown = [e for e in data["entries"] if not e["size_known"]]
known = [e for e in data["entries"] if e["size_known"]]
assert len(unknown) == 1, data["entries"]
assert "size_bytes" not in unknown[0], unknown[0]
assert unknown[0]["path"].endswith("com.example.fixture.plist")
assert known, "positive control: some entries must still be measured"
assert data["unmeasured_items"] == 1
assert data["total_bytes"] == sum(e["size_bytes"] for e in known)
# §1.4: a total that excludes unmeasured entries is a lower bound and says so.
assert d["scan_status"] == "partial", d["scan_status"]
assert any(w["code"] == "size_unmeasured" for w in d["warnings"]), d["warnings"]
PY
}

@test "uninstall --plan marks a path that fails validate_path_for_deletion as protected" {
    make_fixture_app
    # The discovered cache path is a symlink into a protected system tree.
    # validate_path_for_deletion refuses it, so §7.3 requires protected: true
    # in the entry rather than a silent drop.
    rm -rf "$HOME/Library/Caches/com.example.fixture"
    ln -s /System/Library "$HOME/Library/Caches/com.example.fixture"

    run_mole --plan Fixture --json
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    printf '%s\n' "$output" > "$SANDBOX/plan.json"

    python3 - "$SANDBOX/plan.json" << 'PY'
import json, sys
entries = json.load(open(sys.argv[1]))["data"]["entries"]
prot = [e for e in entries if e["protected"]]
assert len(prot) == 1, entries
assert prot[0]["path"].endswith("Caches/com.example.fixture"), prot[0]
# Positive control: the ordinary entries are still unprotected, so this is not
# a blanket true.
assert any(not e["protected"] for e in entries)
PY
}

@test "uninstall --plan refuses a name matching zero apps with exit 2 and empty stdout" {
    make_fixture_app
    run_mole --plan NotInstalled --json
    [ "$status" -eq 2 ] || return 1
    [ -z "$output" ]
}

@test "uninstall --plan refuses a name matching more than one app with exit 2" {
    make_fixture_app
    # Two distinct installs reporting the same uninstall_name. --plan needs
    # exactly one target; a best guess here would remove the wrong app's files.
    mkdir -p "$HOME/Applications/Other/Fixture.app/Contents"
    printf '1700000000|%s|Fixture|com.example.fixture2|1MB|Today|1024|1700000000|1690000000|9.9\n' \
        "$HOME/Applications/Other/Fixture.app" >> "$APPS_CACHE"

    run_mole --plan Fixture --json
    [ "$status" -eq 2 ] || {
        echo "$output"
        return 1
    }
    [ -z "$output" ]
}

@test "uninstall --plan deletes nothing" {
    make_fixture_app
    local before after
    before=$(find "$HOME" -not -path "*/Library/Logs*" | LC_ALL=C sort)
    run_mole --plan Fixture --json
    [ "$status" -eq 0 ] || return 1
    after=$(find "$HOME" -not -path "*/Library/Logs*" | LC_ALL=C sort)
    [ "$before" = "$after" ] || {
        diff <(printf '%s\n' "$before") <(printf '%s\n' "$after")
        return 1
    }
    [[ ! -d "$MOLE_TEST_TRASH_DIR" ]] || [[ -z "$(ls -A "$MOLE_TEST_TRASH_DIR")" ]]
}

@test "uninstall_path_requires_sudo answers both branches" {
    local writable="$SANDBOX/writable"
    local locked="$SANDBOX/locked"
    mkdir -p "$writable" "$locked"
    : > "$writable/a"
    : > "$locked/a"
    chmod 500 "$locked"

    run /bin/bash --noprofile --norc << EOF
set -uo pipefail
export MOLE_DELETE_MODE=trash
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/uninstall/batch.sh"
if uninstall_path_requires_sudo "$writable/a"; then echo "WRITABLE=true"; else echo "WRITABLE=false"; fi
if uninstall_path_requires_sudo "$locked/a"; then echo "LOCKED=true"; else echo "LOCKED=false"; fi
EOF
    chmod 700 "$locked"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"WRITABLE=false"* ]] || return 1
    [[ "$output" == *"LOCKED=true"* ]]
}

@test "uninstall --plan reports requires_sudo true when a leftover's parent is not writable" {
    make_fixture_app
    chmod 500 "$HOME/Library/Preferences"

    run_mole --plan Fixture --json
    local plan_status="$status" plan_output="$output"
    chmod 700 "$HOME/Library/Preferences"

    [ "$plan_status" -eq 0 ] || {
        echo "$plan_output"
        return 1
    }
    printf '%s\n' "$plan_output" > "$SANDBOX/plan.json"
    python3 - "$SANDBOX/plan.json" << 'PY'
import json, sys
data = json.load(open(sys.argv[1]))["data"]
sudo = [e for e in data["entries"] if e["requires_sudo"]]
assert sudo, data["entries"]
assert all(e["path"].endswith("com.example.fixture.plist") for e in sudo), sudo
# Positive control plus §7.3's aggregation rule.
assert any(not e["requires_sudo"] for e in data["entries"])
assert data["requires_sudo"] is True
PY
}

@test "uninstall --apply-plan reports one result per submitted entry and trashes only the selection" {
    make_fixture_app
    make_plan "$SANDBOX/plan.json"
    add_selection "$SANDBOX/plan.json" "$SANDBOX/sel.json" \
        "$HOME/Library/Caches/com.example.fixture" \
        "$HOME/Library/Preferences/com.example.fixture.plist"

    run_mole_stdin "$SANDBOX/sel.json" --apply-plan --json
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    printf '%s\n' "$output" > "$SANDBOX/apply.json"

    python3 - "$SANDBOX/apply.json" "$SANDBOX/plan.json" "$HOME" << 'PY'
import json, sys
res = json.load(open(sys.argv[1]))
plan = json.load(open(sys.argv[2]))
home = sys.argv[3]
data = res["data"]
assert res["mode"] == "apply"
assert res["scan_status"] == "complete"
assert data["mode"] == "trash"
assert data["plan_digest"] == plan["data"]["plan_digest"]
# One record for EVERY submitted entry, not only the selected ones.
assert len(data["results"]) == len(plan["data"]["entries"]), data["results"]
by_path = {r["path"]: r for r in data["results"]}
assert by_path[home + "/Library/Caches/com.example.fixture"]["outcome"] == "trashed"
assert by_path[home + "/Library/Preferences/com.example.fixture.plist"]["outcome"] == "trashed"
assert by_path[home + "/Applications/Fixture.app"]["outcome"] == "not_selected"
assert by_path[home + "/Library/Application Support/Fixture"]["outcome"] == "not_selected"
trashed = [r for r in data["results"] if r["outcome"] == "trashed"]
assert data["freed_bytes"] == sum(r["size_bytes"] for r in trashed), data
PY

    # The approved set is the executed set, on disk as well as in the payload.
    [[ ! -e "$HOME/Library/Caches/com.example.fixture" ]] || return 1
    [[ ! -e "$HOME/Library/Preferences/com.example.fixture.plist" ]] || return 1
    [[ -e "$HOME/Applications/Fixture.app" ]] || return 1
    [[ -e "$HOME/Library/Application Support/Fixture/d.bin" ]] || return 1
    [ "$(find "$MOLE_TEST_TRASH_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 2 ]
}

@test "uninstall --apply-plan --permanent removes instead of trashing" {
    make_fixture_app
    make_plan "$SANDBOX/plan.json"
    add_selection "$SANDBOX/plan.json" "$SANDBOX/sel.json" \
        "$HOME/Library/Caches/com.example.fixture"

    run_mole_stdin "$SANDBOX/sel.json" --apply-plan --permanent --json
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    printf '%s\n' "$output" > "$SANDBOX/apply.json"
    python3 - "$SANDBOX/apply.json" << 'PY'
import json, sys
data = json.load(open(sys.argv[1]))["data"]
assert data["mode"] == "permanent", data["mode"]
done = [r for r in data["results"] if r["outcome"] == "removed"]
assert len(done) == 1, data["results"]
assert not any(r["outcome"] == "trashed" for r in data["results"])
PY
    [[ ! -e "$HOME/Library/Caches/com.example.fixture" ]] || return 1
    # Permanent means permanent: nothing landed in the sandbox Trash.
    [[ ! -d "$MOLE_TEST_TRASH_DIR" ]] || [ -z "$(ls -A "$MOLE_TEST_TRASH_DIR")" ]
}

@test "uninstall --apply-plan defaults to Trash when --permanent is absent" {
    make_fixture_app
    make_plan "$SANDBOX/plan.json"
    add_selection "$SANDBOX/plan.json" "$SANDBOX/sel.json" \
        "$HOME/Library/Caches/com.example.fixture"

    run_mole_stdin "$SANDBOX/sel.json" --apply-plan --json
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *'"mode":"trash"'* ]] || return 1
    [[ "$output" == *'"outcome":"trashed"'* ]] || return 1
    [ "$(find "$MOLE_TEST_TRASH_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]
}

@test "uninstall --apply-plan refuses a stale plan with exit 4 and deletes nothing" {
    make_fixture_app
    make_plan "$SANDBOX/plan.json"
    add_selection "$SANDBOX/plan.json" "$SANDBOX/sel.json"

    # A file a real re-scan will catch appears between plan and apply, exactly
    # as it would if the app ran once while the user was reading the preview.
    mkdir -p "$HOME/Library/Logs/Fixture"
    printf 'log\n' > "$HOME/Library/Logs/Fixture/run.log"

    local before
    before=$(find "$HOME" -not -path "*/Library/Logs*" | LC_ALL=C sort)

    run_mole_stdin "$SANDBOX/sel.json" --apply-plan --json
    [ "$status" -eq 4 ] || {
        echo "status=$status $output"
        return 1
    }
    printf '%s\n' "$output" > "$SANDBOX/apply.json"
    python3 - "$SANDBOX/apply.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["scan_status"] == "failed", d
assert d["error"]["code"] == "plan_stale", d["error"]
assert d["data"] is None
PY

    # Nothing deleted: every fixture file is still exactly where it was.
    local after
    after=$(find "$HOME" -not -path "*/Library/Logs*" | LC_ALL=C sort)
    [ "$before" = "$after" ] || {
        diff <(printf '%s\n' "$before") <(printf '%s\n' "$after")
        return 1
    }
    [[ ! -d "$MOLE_TEST_TRASH_DIR" ]] || [ -z "$(ls -A "$MOLE_TEST_TRASH_DIR")" ]
}

@test "uninstall --apply-plan refuses a stale plan when a planned path disappears" {
    make_fixture_app
    make_plan "$SANDBOX/plan.json"
    add_selection "$SANDBOX/plan.json" "$SANDBOX/sel.json"

    rm -rf "$HOME/Library/Application Support/Fixture"

    run_mole_stdin "$SANDBOX/sel.json" --apply-plan --json
    [ "$status" -eq 4 ] || {
        echo "status=$status $output"
        return 1
    }
    [[ "$output" == *'"plan_stale"'* ]] || return 1
    # The refusal is total: the paths that DID still match are untouched.
    [[ -e "$HOME/Library/Caches/com.example.fixture" ]] || return 1
    [[ -e "$HOME/Library/Preferences/com.example.fixture.plist" ]] || return 1
    [[ -e "$HOME/Applications/Fixture.app" ]]
}

@test "uninstall --apply-plan refuses an unknown selection id with exit 2 and deletes nothing" {
    make_fixture_app
    make_plan "$SANDBOX/plan.json"
    python3 - "$SANDBOX/plan.json" "$SANDBOX/sel.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# One real id plus one that is not in entries: the whole run must refuse, not
# apply the valid half.
d["data"]["selected"] = [d["data"]["entries"][0]["id"], "deadbeefdeadbeef"]
json.dump(d, open(sys.argv[2], "w"))
PY

    local before
    before=$(find "$HOME" -not -path "*/Library/Logs*" | LC_ALL=C sort)
    run_mole_stdin "$SANDBOX/sel.json" --apply-plan --json
    [ "$status" -eq 2 ] || {
        echo "status=$status $output"
        return 1
    }
    printf '%s\n' "$output" > "$SANDBOX/apply.json"
    python3 - "$SANDBOX/apply.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["error"]["code"] == "unknown_selection_id", d["error"]
assert d["data"] is None
PY
    local after
    after=$(find "$HOME" -not -path "*/Library/Logs*" | LC_ALL=C sort)
    [ "$before" = "$after" ]
}

@test "uninstall --apply-plan refuses a protected selection with exit 2 and deletes nothing" {
    make_fixture_app
    rm -rf "$HOME/Library/Caches/com.example.fixture"
    ln -s /System/Library "$HOME/Library/Caches/com.example.fixture"
    make_plan "$SANDBOX/plan.json"
    python3 - "$SANDBOX/plan.json" "$SANDBOX/sel.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
prot = [e for e in d["data"]["entries"] if e["protected"]]
assert prot, "fixture must produce a protected entry"
ok = [e for e in d["data"]["entries"] if not e["protected"]]
d["data"]["selected"] = [ok[0]["id"], prot[0]["id"]]
json.dump(d, open(sys.argv[2], "w"))
PY

    local before
    before=$(find "$HOME" -not -path "*/Library/Logs*" | LC_ALL=C sort)
    run_mole_stdin "$SANDBOX/sel.json" --apply-plan --json
    [ "$status" -eq 2 ] || {
        echo "status=$status $output"
        return 1
    }
    printf '%s\n' "$output" > "$SANDBOX/apply.json"
    python3 - "$SANDBOX/apply.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["error"]["code"] == "protected_selection", d["error"]
assert d["data"] is None
PY
    local after
    after=$(find "$HOME" -not -path "*/Library/Logs*" | LC_ALL=C sort)
    [ "$before" = "$after" ]
}

@test "uninstall --apply-plan reports missing for a path that vanished after the digest matched" {
    make_fixture_app
    make_plan "$SANDBOX/plan.json"
    add_selection "$SANDBOX/plan.json" "$SANDBOX/sel.json"

    # Remove the path from under the deletion loop, after verification has
    # already passed, by hooking the first mole_delete call.
    cat > "$SANDBOX/hook.sh" << HOOK
_real_delete() { :; }
eval "\$(declare -f mole_delete | sed '1s/mole_delete/_real_delete/')"
mole_delete() {
    rm -f "$HOME/Library/Preferences/com.example.fixture.plist"
    _real_delete "\$@"
}
HOOK
    MOLE_TEST_HOOK="$SANDBOX/hook.sh" run_mole_stdin "$SANDBOX/sel.json" --apply-plan --json
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    printf '%s\n' "$output" > "$SANDBOX/apply.json"
    python3 - "$SANDBOX/apply.json" << 'PY'
import json, sys
results = json.load(open(sys.argv[1]))["data"]["results"]
missing = [r for r in results if r["outcome"] == "missing"]
assert len(missing) == 1, results
assert missing[0]["path"].endswith("com.example.fixture.plist"), missing
assert any(r["outcome"] == "trashed" for r in results), results
PY
}

@test "uninstall --apply-plan interrupted mid-run reports per-entry outcomes and exits 130" {
    make_fixture_app
    make_plan "$SANDBOX/plan.json"
    add_selection "$SANDBOX/plan.json" "$SANDBOX/sel.json"

    # Matches tests/uninstall_remove_file_list.bats's interrupt fixture: the
    # sink reports the interrupt status rather than the test racing a signal.
    cat > "$SANDBOX/hook.sh" << 'HOOK'
_real_delete() { :; }
eval "$(declare -f mole_delete | sed '1s/mole_delete/_real_delete/')"
_mole_delete_calls=0
mole_delete() {
    _mole_delete_calls=$((_mole_delete_calls + 1))
    if [[ $_mole_delete_calls -ge 2 ]]; then
        return 130
    fi
    _real_delete "$@"
}
HOOK
    MOLE_TEST_HOOK="$SANDBOX/hook.sh" run_mole_stdin "$SANDBOX/sel.json" --apply-plan --json
    [ "$status" -eq 130 ] || {
        echo "status=$status $output"
        return 1
    }
    printf '%s\n' "$output" > "$SANDBOX/apply.json"
    python3 - "$SANDBOX/apply.json" "$SANDBOX/plan.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
plan = json.load(open(sys.argv[2]))
# §7.6: a partial result payload is mandatory, never an empty or generic one.
assert d["scan_status"] == "partial", d["scan_status"]
results = d["data"]["results"]
assert len(results) == len(plan["data"]["entries"]), results
done = [r for r in results if r["outcome"] in ("trashed", "removed")]
assert len(done) == 1, results
stopped = [r for r in results if r["outcome"] == "failed"]
assert len(stopped) == len(results) - 1, results
assert all(r.get("message") for r in stopped), stopped
PY
    # Exactly one path actually left the disk.
    [ "$(find "$MOLE_TEST_TRASH_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -eq 1 ]
}

@test "uninstall --apply-plan refuses --dry-run instead of reporting phantom removals" {
    make_fixture_app
    make_plan "$SANDBOX/plan.json"
    add_selection "$SANDBOX/plan.json" "$SANDBOX/sel.json"

    run_mole_stdin "$SANDBOX/sel.json" --apply-plan --dry-run --json
    [ "$status" -eq 2 ] || {
        echo "status=$status $output"
        return 1
    }
    [ -z "$output" ] || return 1
    [[ -e "$HOME/Library/Caches/com.example.fixture" ]]
}

@test "uninstall --apply-plan refuses a plan with no selected array" {
    make_fixture_app
    make_plan "$SANDBOX/plan.json"

    run_mole_stdin "$SANDBOX/plan.json" --apply-plan --json
    [ "$status" -eq 2 ] || {
        echo "status=$status $output"
        return 1
    }
    [[ -e "$HOME/Library/Caches/com.example.fixture" ]]
}

@test "uninstall --apply-plan refuses a plan whose app.path is not an application bundle" {
    make_fixture_app
    make_plan "$SANDBOX/plan.json"
    python3 - "$SANDBOX/plan.json" "$SANDBOX/sel.json" "$HOME" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["data"]["selected"] = [e["id"] for e in d["data"]["entries"]]
# A hand-built plan pointing discovery at an ordinary directory.
d["data"]["app"]["path"] = sys.argv[3] + "/Library"
json.dump(d, open(sys.argv[2], "w"))
PY

    run_mole_stdin "$SANDBOX/sel.json" --apply-plan --json
    [ "$status" -eq 2 ] || {
        echo "status=$status $output"
        return 1
    }
    [[ -e "$HOME/Library/Caches/com.example.fixture" ]]
}

@test "uninstall --apply-plan refuses malformed JSON on stdin" {
    make_fixture_app
    printf '{not a plan\n' > "$SANDBOX/bad.json"

    run_mole_stdin "$SANDBOX/bad.json" --apply-plan --json
    [ "$status" -eq 2 ] || {
        echo "status=$status $output"
        return 1
    }
    [[ -e "$HOME/Library/Caches/com.example.fixture" ]]
}

@test "uninstall --plan and --apply-plan reject being combined or given positional names" {
    make_fixture_app
    run_mole --plan Fixture --apply-plan --json
    [ "$status" -eq 2 ] || return 1
    run_mole --plan Fixture Extra --json
    [ "$status" -eq 2 ]
}

@test "uninstall --apply-plan refuses when only a planned size changed" {
    make_fixture_app
    make_plan "$SANDBOX/plan.json"
    add_selection "$SANDBOX/plan.json" "$SANDBOX/sel.json"

    # The path SET is unchanged, so only the digest can catch this: the app
    # wrote to its own cache between preview and approval. §7.2 makes that a
    # re-plan, deliberately, because it means the app was active in between.
    printf 'a much larger cache body than before\n' >> "$HOME/Library/Caches/com.example.fixture/c.bin"
    dd if=/dev/zero of="$HOME/Library/Caches/com.example.fixture/big.bin" bs=1024 count=64 2> /dev/null

    run_mole_stdin "$SANDBOX/sel.json" --apply-plan --json
    [ "$status" -eq 4 ] || {
        echo "status=$status $output"
        return 1
    }
    [[ "$output" == *'"plan_stale"'* ]] || return 1
    [[ -e "$HOME/Library/Caches/com.example.fixture" ]] || return 1
    [[ -e "$HOME/Library/Preferences/com.example.fixture.plist" ]] || return 1
    [[ -e "$HOME/Applications/Fixture.app" ]]
}

@test "uninstall --apply-plan's stdin-tty guard sits ahead of the blocking read" {
    # A pty-based behavioural test was tried first and rejected: under bats
    # 1.5+ semantics stdin is a socket, `script` cannot allocate a terminal,
    # and the case fails for reasons that have nothing to do with the guard.
    # A source invariant is the honest form here, per .claude/skills/bugs
    # ("turn the fix into a source invariant") — it fails if the guard is
    # removed or moved after the read that would otherwise block forever.
    local guard_line cat_line
    guard_line=$(grep -n 'if \[\[ -t 0 \]\]; then' "$PROJECT_ROOT/bin/uninstall.sh" | head -1 | cut -d: -f1)
    # shellcheck disable=SC2016 # matching the literal source text, not expanding it
    cat_line=$(grep -n 'cat > "$plan_file"' "$PROJECT_ROOT/bin/uninstall.sh" | head -1 | cut -d: -f1)
    [ -n "$guard_line" ] || {
        echo "no stdin-tty guard in uninstall_apply_command"
        return 1
    }
    [ -n "$cat_line" ] || {
        echo "no stdin read in uninstall_apply_command"
        return 1
    }
    [ "$guard_line" -lt "$cat_line" ] || {
        echo "guard at $guard_line is after the blocking read at $cat_line"
        return 1
    }

    # Positive control: a redirected plan on stdin is not a terminal, so the
    # guard must not fire for the normal path.
    make_fixture_app
    make_plan "$SANDBOX/plan.json"
    add_selection "$SANDBOX/plan.json" "$SANDBOX/sel.json"
    run_mole_stdin "$SANDBOX/sel.json" --apply-plan --json
    [ "$status" -eq 0 ]
}
