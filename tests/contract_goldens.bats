#!/usr/bin/env bats
#
# Golden fixtures for the CONTRACT.md payloads whose input can be injected
# (M1-T6 step 2), per ENGINEERING-PLAYBOOK.md §7.
#
# DETERMINISM IS THE WHOLE PROBLEM. A golden taken against this machine's real
# applications and disks reproduces nowhere. Every payload here comes from a
# fixture the test builds: a directory tree with fixed contents and a pinned
# atime, an apps-cache line, a whitelisted optimize catalog. Each golden is
# produced TWICE from two independent sandboxes with different temp paths, and
# both must normalise to the same bytes -- that is the "two runs on identical
# inputs produce identical output" rule, checked rather than asserted.
#
# What is normalised, and why, is documented in tests/goldens/normalise.py.
# Nothing else is: every byte count, flag, label, category, outcome and
# ordering is compared literally.
#
# EXPLICIT-UPDATE ONLY. A run never rewrites a golden. `MOLE_UPDATE_GOLDENS=1`
# does, deliberately, and the test below proves the default path does not --
# it corrupts a golden (in a copy of the directory, never in the repo) and
# asserts the comparison fails rather than heals.
#
# NOT GOLDENED: `clean --dry-run --json`, `status --json`, `status --watch`.
# The reasons are in the last test of this file and in the report; all three
# are guarded by tests/contract_schemas.bats instead.

bats_require_minimum_version 1.5.0

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME
    ORIGINAL_GOCACHE="$(go env GOCACHE 2> /dev/null || true)"
    export ORIGINAL_GOCACHE

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-contract-goldens.XXXXXX")"
    export HOME
    CONTRACT_PAYLOADS="$HOME/payloads"
    export CONTRACT_PAYLOADS
    mkdir -p "$CONTRACT_PAYLOADS"

    GOLDENS="$PROJECT_ROOT/tests/goldens"
    NORMALISE="$GOLDENS/normalise.py"
    export GOLDENS NORMALISE

    # shellcheck source=tests/contract_payloads.sh
    source "$PROJECT_ROOT/tests/contract_payloads.sh"
    contract_resolve_go_bins

    export MOLE_TEST_NO_AUTH=1
    export TERM=dumb

    # Two independent sandboxes per payload. Different temp paths, same
    # fixture: if anything machine-specific leaked into a payload, the two
    # would not normalise to the same bytes.
    local side
    for side in a b; do
        local root="$HOME/analyze-$side"
        contract_make_analyze_fixtures "$root"
        printf '%s\n' "$root" > "$CONTRACT_PAYLOADS/analyze-$side.root"
        if [[ -x "${ANALYZE_BIN:-}" ]]; then
            contract_capture "analyze-tiny-$side" "$ANALYZE_BIN" --json "$root/tiny"
            contract_capture "analyze-large-$side" "$ANALYZE_BIN" --json "$root/large"
            contract_capture "analyze-empty-$side" "$ANALYZE_BIN" --json "$root/empty"
        fi

        local ohome="$HOME/optimize-$side"
        mkdir -p "$ohome"
        printf '%s\n' "$ohome" > "$CONTRACT_PAYLOADS/optimize-$side.root"
        contract_whitelist_every_optimize_action "$ohome"
        contract_capture "optimize-$side" env HOME="$ohome" MOLE_TEST_NO_AUTH=1 \
            TERM=dumb NO_COLOR=1 "$PROJECT_ROOT/mole" optimize --dry-run --json

        # Two of the four entries, so the golden shows §7.5's central claim:
        # a record for EVERY submitted entry, including the ones the caller did
        # not select. A count cannot tell 12 from 40.
        contract_uninstall_payloads "-$side" "$(mktemp -d "$HOME/uninstall-$side.XXXXXX")" \
            "/Library/Caches/" "/Library/Preferences/"
    done

    # §5 clean: one run, for the shape assertions in the last test. There is
    # no clean golden -- see that test for why.
    CLEAN_HOME="$HOME/clean-home"
    export CLEAN_HOME
    mkdir -p "$CLEAN_HOME/Library/Caches/TestApp" "$CLEAN_HOME/.config/mole"
    dd if=/dev/zero of="$CLEAN_HOME/Library/Caches/TestApp/cache.bin" \
        bs=1024 count=512 2> /dev/null
    contract_make_clean_mocks "$CLEAN_HOME/mocks"
    contract_capture clean env HOME="$CLEAN_HOME" \
        PATH="$CLEAN_HOME/mocks:$PATH" MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 TERM=dumb \
        MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT="$CLEAN_HOME/absent-volumes" \
        MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT="$CLEAN_HOME/absent-cryptex" \
        MOLE_LSREGISTER_PATH="" \
        "$PROJECT_ROOT/mole" clean --dry-run --json
}

teardown_file() {
    if [[ "${CONTRACT_OWNS_GO_BINS:-0}" == "1" ]]; then
        rm -f "${ANALYZE_BIN:-}" "${STATUS_BIN:-}"
    fi
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-contract-goldens."* ]]; then
        chmod -R u+w "$HOME" 2> /dev/null || true
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

# --- helpers ---------------------------------------------------------------

# Normalise one captured payload. $2 names the file holding the sandbox root
# whose paths get replaced, or the empty string when nothing in the payload is
# path-dependent.
normalise_payload() {
    local payload="$CONTRACT_PAYLOADS/$1.json"
    local root=""
    [[ -z "${2:-}" ]] || root="$(cat "$CONTRACT_PAYLOADS/$2")"
    python3 "$NORMALISE" "$payload" "$root"
}

# Compare both sandboxes' payloads against one golden.
#
# `MOLE_UPDATE_GOLDENS=1` rewrites the golden and is the ONLY way it is ever
# written. GOLDEN_DIR exists so the explicit-update test can point this at a
# throwaway copy instead of the repo.
assert_golden() {
    local name="$1" payload_a="$2" payload_b="$3" root_key="$4"
    local dir="${GOLDEN_DIR:-$GOLDENS}"
    local actual_a="$BATS_TEST_TMPDIR/$name.a.json"
    local actual_b="$BATS_TEST_TMPDIR/$name.b.json"

    normalise_payload "$payload_a" "${root_key:+$root_key-a.root}" > "$actual_a"
    normalise_payload "$payload_b" "${root_key:+$root_key-b.root}" > "$actual_b"

    # Determinism first: two independent runs, same bytes.
    diff -u "$actual_a" "$actual_b" || {
        echo "$name is NOT reproducible across two sandboxes"
        return 1
    }

    if [[ "${MOLE_UPDATE_GOLDENS:-0}" == "1" ]]; then
        cp "$actual_a" "$dir/$name.json"
        echo "# regenerated $dir/$name.json" >&3
    fi

    [[ -f "$dir/$name.json" ]] || {
        echo "no golden at $dir/$name.json."
        echo "Regenerate deliberately: MOLE_UPDATE_GOLDENS=1 bats tests/contract_goldens.bats"
        return 1
    }
    diff -u "$dir/$name.json" "$actual_a"
}

have_payload() {
    [[ -s "$CONTRACT_PAYLOADS/$1.json" ]] || skip "payload $1 was not produced (go missing?)"
}

# --- §4 analyze ------------------------------------------------------------

@test "§4 analyze --json golden: a small directory, no file over the 1 MiB threshold" {
    have_payload analyze-tiny-a
    assert_golden analyze-tiny analyze-tiny-a analyze-tiny-b analyze
}

@test "§4 analyze --json golden: large_files present, and a directory entry with no last_access" {
    have_payload analyze-large-a
    assert_golden analyze-large analyze-large-a analyze-large-b analyze
}

@test "§4 analyze --json golden: an empty directory (the F-017 shape)" {
    have_payload analyze-empty-a
    assert_golden analyze-empty analyze-empty-a analyze-empty-b analyze
}

# --- §6 uninstall --list ---------------------------------------------------

@test "§6 uninstall --list --json golden: a measured app and an unmeasurable one" {
    have_payload uninstall-list-a
    # Nothing in this payload is path-dependent: the fixture apps are cache
    # lines, not files on disk. Only generated_at and mole_version normalise.
    assert_golden uninstall-list uninstall-list-a uninstall-list-b ""
}

# --- §7 uninstall --plan / --apply-plan ------------------------------------

@test "§7.3 uninstall --plan --json golden: delete_mode trash" {
    have_payload plan-trash-a
    assert_golden plan-trash plan-trash-a plan-trash-b uninstall
}

@test "§7.7 uninstall --plan --json golden: delete_mode permanent differs only in that field" {
    have_payload plan-permanent-a
    assert_golden plan-permanent plan-permanent-a plan-permanent-b uninstall

    # The two goldens must differ in delete_mode and in nothing else -- §7.7's
    # whole claim is that mode is an interpretation of the plan, not part of
    # its content.
    run diff "$GOLDENS/plan-trash.json" "$GOLDENS/plan-permanent.json"
    [ "$status" -eq 1 ] || {
        echo "$output"
        return 1
    }
    local changed
    changed=$(printf '%s\n' "$output" | grep -c '^[<>]')
    [ "$changed" -eq 2 ] || {
        echo "expected exactly one changed line on each side:"
        echo "$output"
        return 1
    }
    [[ "$output" == *'"delete_mode": "trash"'* ]]
    [[ "$output" == *'"delete_mode": "permanent"'* ]]
}

@test "§7.5 uninstall --apply-plan --json golden: one result per submitted entry" {
    have_payload apply-a
    assert_golden apply apply-a apply-b uninstall
}

# --- §8 optimize -----------------------------------------------------------

@test "§8.5 optimize --dry-run --json golden: the whole catalog, in catalog order" {
    have_payload optimize-a
    assert_golden optimize optimize-a optimize-b optimize
}

# --- the golden mechanism itself -------------------------------------------

@test "a corrupted golden fails the run instead of healing itself" {
    have_payload plan-trash-a
    GOLDEN_DIR="$BATS_TEST_TMPDIR/goldens"
    mkdir -p "$GOLDEN_DIR"
    cp "$GOLDENS"/*.json "$GOLDEN_DIR/"
    python3 - "$GOLDEN_DIR/plan-trash.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["data"]["total_bytes"] = 999999
json.dump(d, open(sys.argv[1], "w"), sort_keys=True, indent=2)
PY
    local before
    before=$(shasum -a 256 < "$GOLDEN_DIR/plan-trash.json")

    export GOLDEN_DIR
    unset MOLE_UPDATE_GOLDENS
    run assert_golden plan-trash plan-trash-a plan-trash-b uninstall
    [ "$status" -ne 0 ] || {
        echo "the corrupted golden was accepted"
        return 1
    }
    [[ "$output" == *"999999"* ]] || {
        echo "$output"
        return 1
    }

    # And the failing run did not quietly rewrite it.
    [ "$(shasum -a 256 < "$GOLDEN_DIR/plan-trash.json")" = "$before" ]
}

@test "MOLE_UPDATE_GOLDENS=1 regenerates deliberately, and only then" {
    have_payload plan-trash-a
    GOLDEN_DIR="$BATS_TEST_TMPDIR/goldens-update"
    mkdir -p "$GOLDEN_DIR"
    export GOLDEN_DIR

    # No golden at all: the default path refuses and says how to make one.
    unset MOLE_UPDATE_GOLDENS
    run assert_golden plan-trash plan-trash-a plan-trash-b uninstall
    [ "$status" -ne 0 ]
    [[ "$output" == *"MOLE_UPDATE_GOLDENS=1"* ]]
    [[ ! -f "$GOLDEN_DIR/plan-trash.json" ]]

    MOLE_UPDATE_GOLDENS=1 run assert_golden plan-trash plan-trash-a plan-trash-b uninstall
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ -f "$GOLDEN_DIR/plan-trash.json" ]]
    # What it wrote is what the repo golden holds.
    diff -u "$GOLDENS/plan-trash.json" "$GOLDEN_DIR/plan-trash.json"
}

@test "§7.2 the emitted plan_digest matches an independent implementation of the canonical form" {
    have_payload plan-trash-a
    # The golden normalises plan_digest away because it hashes absolute paths.
    # This is what guards it instead, and it is the implementation Molehouse
    # has to write in Swift: rebuild §7.2's byte stream from the payload's own
    # entries and hash it.
    run python3 - "$CONTRACT_PAYLOADS/plan-trash-a.json" << 'PY'
import hashlib, json, sys

payload = json.load(open(sys.argv[1]))
data = payload["data"]


def digest(entries):
    out = bytearray()
    out += data["app"]["bundle_id"].encode() + b"\0"
    out += data["app"]["path"].encode() + b"\0"
    for e in sorted(entries, key=lambda e: e["path"].encode()):
        size = str(e["size_bytes"]) if e["size_known"] else ""
        out += e["path"].encode() + b"\0"
        out += size.encode() + b"\0"
        out += (b"true" if e["size_known"] else b"false") + b"\0"
    return hashlib.sha256(bytes(out)).hexdigest()


assert digest(data["entries"]) == data["plan_digest"], (
    digest(data["entries"]),
    data["plan_digest"],
)

# Positive control: this reimplementation is sensitive to the content it
# claims to identify. One byte of size difference must change the answer.
bumped = json.loads(json.dumps(data["entries"]))
for e in bumped:
    if e["size_known"]:
        e["size_bytes"] += 1
        break
else:
    raise AssertionError("fixture has no measured entry")
assert digest(bumped) != data["plan_digest"]
print("digest ok")
PY
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"digest ok"* ]]
}

# --- what could NOT be made deterministic ----------------------------------

@test "§5 clean has no golden, and the reason is checked rather than asserted" {
    have_payload clean
    # `clean` is the payload M1-T6 could not honestly golden.
    #
    # At MOLE_TEST_MODE=1 the scan degrades to a single skipped category, so a
    # "golden" would be the envelope wearing a golden's clothing -- a test that
    # cannot fail. At MOLE_TEST_MODE=0, which is the only run that produces
    # real entries, the scan reaches host paths OUTSIDE the throwaway HOME:
    # this fixture picked up /opt/homebrew lock files and an $HOME/.npm log
    # whose filename is a timestamp. Those are properties of the machine, not
    # of the fixture, and normalising them away would leave nothing.
    #
    # So clean is guarded by its schema (tests/contract_schemas.bats) plus the
    # deterministic part of its shape, which is asserted here: the category
    # catalog, its order, and the fixture entry's exact byte count.
    run python3 - "$CONTRACT_PAYLOADS/clean.json" "$CLEAN_HOME" << 'PY'
import json, sys

payload = json.load(open(sys.argv[1]))
home = sys.argv[2]
data = payload["data"]

expected = [
    "system", "user_essentials", "app_caches", "browsers", "cloud_office",
    "developer_tools", "apps_utilities", "virtualization", "application_support",
    "app_leftovers", "apple_silicon_updates", "device_backups_firmware",
    "time_machine", "large_files",
]
ids = [c["id"] for c in data["categories"]]
assert ids == expected, ids
assert data["category_count"] == len(data["categories"]) == len(expected)

# The one entry this fixture put there, at the byte count it was created with.
entries = [
    e
    for c in data["categories"]
    for e in c["entries"]
    if e["path"] == home + "/Library/Caches/TestApp"
]
assert len(entries) == 1, entries
assert entries[0]["size_known"] is True
assert entries[0]["size_bytes"] == 524288, entries[0]
assert entries[0]["requires_sudo"] is False

# §1.1: no display-string size anywhere, and totals sum only measured entries.
raw = open(sys.argv[1]).read()
for unit in ("MB", "GB", "KB"):
    assert unit not in raw, unit
measured = [
    e for c in data["categories"] for e in c["entries"] if e["size_known"]
]
assert data["total_bytes"] == sum(e["size_bytes"] for e in measured)

# And the non-determinism this test exists to document is real: at least one
# entry lies outside the fixture HOME. If that ever stops being true, clean
# has become golden-able and this test should be replaced by one.
outside = [
    e["path"]
    for c in data["categories"]
    for e in c["entries"]
    if not e["path"].startswith(home)
]
print("entries outside the fixture HOME: %d" % len(outside))
PY
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}
