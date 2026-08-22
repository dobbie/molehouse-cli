#!/usr/bin/env bats
#
# CONTRACT.md as something a test can fail on (M1-T6 step 1).
#
# One JSON Schema document per payload under tests/schemas/, checked by
# tests/schemas/validate.py — stdlib only, because `jsonschema` is not
# installed and ENGINEERING-PLAYBOOK.md §4 makes adding a dependency a
# decision rather than a convenience.
#
# THE POINT OF THIS FILE IS THE REJECTIONS. A validator that accepts
# everything is worse than no validator: it manufactures confidence
# (.claude/skills/bugs archetype 11, "a test that cannot fail"). Every schema
# here is fed a deliberately corrupted payload and must reject it, and every
# corruption is a different kind: a missing guaranteed field, a size as a
# display string, a bool as the string "true", an array replaced by an object,
# a value outside a closed enum.
#
# G/C: CONTRACT.md §0 tags every field Guaranteed or Conditional. A schema that
# marks a C field required fails on a legitimate payload (F-017); one that
# marks a G field optional cannot catch the regression it exists for. The
# `C field absent` tests below hold that line from the other side.

bats_require_minimum_version 1.5.0

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME
    ORIGINAL_GOCACHE="$(go env GOCACHE 2> /dev/null || true)"
    export ORIGINAL_GOCACHE

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-contract-schemas.XXXXXX")"
    export HOME
    CONTRACT_PAYLOADS="$HOME/payloads"
    export CONTRACT_PAYLOADS
    mkdir -p "$CONTRACT_PAYLOADS"

    SCHEMAS="$PROJECT_ROOT/tests/schemas"
    VALIDATE="$PROJECT_ROOT/tests/schemas/validate.py"
    export SCHEMAS VALIDATE

    # shellcheck source=tests/contract_payloads.sh
    source "$PROJECT_ROOT/tests/contract_payloads.sh"
    contract_resolve_go_bins

    export MOLE_TEST_NO_AUTH=1
    export TERM=dumb

    # §2 / §3 — live machine state, read-only.
    if [[ -x "${STATUS_BIN:-}" ]]; then
        contract_capture status "$STATUS_BIN" --json
        python3 - "$STATUS_BIN" "$CONTRACT_PAYLOADS/watch.ndjson" << 'PY'
import json, subprocess, sys
status_bin, dest = sys.argv[1], sys.argv[2]
proc = subprocess.Popen([status_bin, "--watch", "--interval", "200ms"],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
frames, err = [], ""
try:
    for _ in range(3):
        line = proc.stdout.readline()
        if not line:
            break
        frames.append(line)
finally:
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=3)
    err = proc.stderr.read()
open(dest, "w").write("".join(frames))
open(dest + ".stderr", "w").write(err)
PY
    fi

    # §4 — a fixture directory, so the payload is a function of the fixture.
    ANALYZE_ROOT="$HOME/analyze-fixtures"
    export ANALYZE_ROOT
    contract_make_analyze_fixtures "$ANALYZE_ROOT"
    if [[ -x "${ANALYZE_BIN:-}" ]]; then
        contract_capture analyze-tiny "$ANALYZE_BIN" --json "$ANALYZE_ROOT/tiny"
        contract_capture analyze-large "$ANALYZE_BIN" --json "$ANALYZE_ROOT/large"
        contract_capture analyze-empty "$ANALYZE_BIN" --json "$ANALYZE_ROOT/empty"
        contract_capture analyze-missing "$ANALYZE_BIN" --json "$HOME/no-such-directory"
    fi

    # §5 — a temp HOME with one known cache directory. This reaches real host
    # paths outside HOME (see tests/contract_goldens.bats for why there is no
    # clean golden), which is fine for a schema check: the shape is the same.
    CLEAN_HOME="$HOME/clean-home"
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
    contract_capture clean-usage env HOME="$CLEAN_HOME" MOLE_TEST_MODE=1 \
        "$PROJECT_ROOT/mole" clean --json

    # §8 — every catalog action whitelisted, so no handler runs.
    OPTIMIZE_HOME="$HOME/optimize-home"
    mkdir -p "$OPTIMIZE_HOME"
    contract_whitelist_every_optimize_action "$OPTIMIZE_HOME"
    contract_capture optimize env HOME="$OPTIMIZE_HOME" MOLE_TEST_NO_AUTH=1 \
        TERM=dumb NO_COLOR=1 "$PROJECT_ROOT/mole" optimize --dry-run --json
    contract_capture optimize-usage env HOME="$OPTIMIZE_HOME" MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/mole" optimize --list

    # §6 / §7 — the fixture app harness. Nothing here touches a real
    # application, a real Trash, or a real Library.
    contract_uninstall_payloads "" "$HOME/uninstall-home"
}

teardown_file() {
    if [[ "${CONTRACT_OWNS_GO_BINS:-0}" == "1" ]]; then
        rm -f "${ANALYZE_BIN:-}" "${STATUS_BIN:-}"
    fi
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-contract-schemas."* ]]; then
        chmod -R u+w "$HOME" 2> /dev/null || true
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

# --- helpers ---------------------------------------------------------------

have_payload() {
    [[ -s "$CONTRACT_PAYLOADS/$1.json" ]] || skip "payload $1 was not produced (go missing?)"
}

assert_valid() {
    local schema="$1" payload="$2"
    run python3 "$VALIDATE" "$SCHEMAS/$schema" "$payload"
    [ "$status" -eq 0 ] || {
        echo "schema $schema rejected $payload:"
        echo "$output"
        return 1
    }
}

# The corrupted payload must be rejected, and the rejection must name the field
# that was corrupted. A generic "invalid" would pass even if the validator were
# tripping over something else entirely.
assert_rejects() {
    local schema="$1" payload="$2" needle="$3"
    run python3 "$VALIDATE" "$SCHEMAS/$schema" "$payload"
    [ "$status" -eq 1 ] || {
        echo "schema $schema ACCEPTED a corrupted payload — the guard is vacuous"
        echo "$output"
        return 1
    }
    [[ "$output" == *"$needle"* ]] || {
        echo "rejection did not mention $needle:"
        echo "$output"
        return 1
    }
}

# `status` and `analyze` come from upstream Go that has NOT yet gained §2.3 /
# §4.2's three NEW fields — nobody has been assigned that work. The schema
# states the contract, so the honest assertion is that these three, and
# ONLY these three, are outstanding: every other field in the payload must
# satisfy the contract today. When the Go work lands, this test fails and is
# flipped to assert_valid. It cannot pass vacuously — any other violation, in
# any of the ~25 status collectors, fails it.
assert_only_pending_new_fields() {
    local schema="$1" payload="$2"
    run python3 "$VALIDATE" "$SCHEMAS/$schema" "$payload"
    [ "$status" -eq 1 ] || {
        echo "$schema now satisfies the contract in full — flip this to assert_valid"
        echo "$output"
        return 1
    }
    local expected
    expected="<root>: missing required property 'scan_status'
<root>: missing required property 'schema_version'
<root>: missing required property 'warnings'"
    local got
    got="$(printf '%s\n' "$output" | sed 's/^frame [0-9]* //' | LC_ALL=C sort -u)"
    [ "$got" = "$expected" ] || {
        echo "unexpected violations beyond the three unimplemented NEW fields:"
        printf '%s\n' "$got"
        return 1
    }
}

corrupt() {
    python3 - "$1" "$2" "$3" << 'PY'
import json, sys
src, dest, script = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(src))
exec(script, {"d": d, "json": json})
json.dump(d, open(dest, "w"))
PY
}

# --- the validator itself --------------------------------------------------

@test "validate.py is stdlib-only and refuses a schema keyword it does not implement" {
    run python3 -c '
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
mods = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        mods.update(a.name.split(".")[0] for a in node.names)
    elif isinstance(node, ast.ImportFrom) and node.level == 0:
        mods.add((node.module or "").split(".")[0])
assert mods <= {"json", "os", "re", "sys"}, mods
print(" ".join(sorted(mods)))
' "$VALIDATE"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }

    # A silently-ignored keyword is how a schema stops guarding half of what it
    # claims to. Unknown keywords are a hard error, not a no-op.
    printf '{"type":"object","multipleOf":3}\n' > "$HOME/bad-schema.json"
    printf '{}\n' > "$HOME/any.json"
    run python3 "$VALIDATE" "$HOME/bad-schema.json" "$HOME/any.json"
    [ "$status" -eq 2 ]
}

@test "validate.py does not accept a JSON bool where the contract says integer" {
    printf '{"type":"object","properties":{"n":{"type":"integer"}}}\n' > "$HOME/int-schema.json"
    printf '{"n":true}\n' > "$HOME/bool.json"
    run python3 "$VALIDATE" "$HOME/int-schema.json" "$HOME/bool.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"expected integer"* ]]
}

# --- §2 status -------------------------------------------------------------

@test "§2 status --json satisfies its schema apart from the unimplemented NEW fields" {
    have_payload status
    assert_only_pending_new_fields status.schema.json "$CONTRACT_PAYLOADS/status.json"
}

@test "§2 status --json REJECTED when uptime_seconds becomes a display string" {
    have_payload status
    corrupt "$CONTRACT_PAYLOADS/status.json" "$HOME/bad-status.json" \
        'd["uptime_seconds"] = d["uptime"]'
    assert_rejects status.schema.json "$HOME/bad-status.json" "/uptime_seconds"
}

@test "§2 status --json C arrays may be null or absent, G objects may not" {
    have_payload status
    corrupt "$CONTRACT_PAYLOADS/status.json" "$HOME/status-c-absent.json" '
for k in ("gpu", "disks", "network", "batteries", "sensors", "bluetooth",
          "top_processes", "process_alerts"):
    d.pop(k, None)
d["sensors"] = None
'
    assert_only_pending_new_fields status.schema.json "$HOME/status-c-absent.json"

    corrupt "$CONTRACT_PAYLOADS/status.json" "$HOME/status-g-gone.json" 'd.pop("hardware")'
    assert_rejects status.schema.json "$HOME/status-g-gone.json" "'hardware'"
}

# --- §3 status --watch -----------------------------------------------------

@test "§3 every status --watch frame satisfies the §2 schema, frame 0 included" {
    [[ -s "$CONTRACT_PAYLOADS/watch.ndjson" ]] || skip "watch frames were not captured"
    run python3 -c 'import sys;print(sum(1 for l in open(sys.argv[1]) if l.strip()))' \
        "$CONTRACT_PAYLOADS/watch.ndjson"
    [ "$output" -ge 2 ] || {
        echo "expected at least two frames, got $output"
        return 1
    }
    run python3 "$VALIDATE" --ndjson "$SCHEMAS/status_watch_frame.schema.json" \
        "$CONTRACT_PAYLOADS/watch.ndjson"
    [ "$status" -eq 1 ]
    # Same three pending fields, per frame, and nothing else.
    local got
    got="$(printf '%s\n' "$output" | sed 's/^frame [0-9]* //' | LC_ALL=C sort -u)"
    [ "$got" = "<root>: missing required property 'scan_status'
<root>: missing required property 'schema_version'
<root>: missing required property 'warnings'" ] || {
        printf '%s\n' "$got"
        return 1
    }
}

@test "§3 status --watch REJECTED when a frame drops the hardware object" {
    [[ -s "$CONTRACT_PAYLOADS/watch.ndjson" ]] || skip "watch frames were not captured"
    python3 - "$CONTRACT_PAYLOADS/watch.ndjson" "$HOME/bad-watch.ndjson" << 'PY'
import json, sys
out = []
for index, line in enumerate(open(sys.argv[1])):
    if not line.strip():
        continue
    frame = json.loads(line)
    if index == 1:
        frame.pop("hardware", None)
    out.append(json.dumps(frame))
open(sys.argv[2], "w").write("\n".join(out) + "\n")
PY
    run python3 "$VALIDATE" --ndjson "$SCHEMAS/status_watch_frame.schema.json" \
        "$HOME/bad-watch.ndjson"
    [ "$status" -eq 1 ]
    [[ "$output" == *"frame 1 <root>: missing required property 'hardware'"* ]] || {
        echo "$output"
        return 1
    }
}

# --- §4 analyze ------------------------------------------------------------

@test "§4 analyze --json satisfies its schema on all three fixtures apart from the NEW fields" {
    have_payload analyze-tiny
    assert_only_pending_new_fields analyze.schema.json "$CONTRACT_PAYLOADS/analyze-tiny.json"
    assert_only_pending_new_fields analyze.schema.json "$CONTRACT_PAYLOADS/analyze-large.json"
    assert_only_pending_new_fields analyze.schema.json "$CONTRACT_PAYLOADS/analyze-empty.json"
}

@test "§4 analyze --json REJECTED when entries is an object instead of an array" {
    have_payload analyze-tiny
    corrupt "$CONTRACT_PAYLOADS/analyze-tiny.json" "$HOME/bad-analyze.json" \
        'd["entries"] = {e["name"]: e for e in d["entries"]}'
    assert_rejects analyze.schema.json "$HOME/bad-analyze.json" "/entries"
}

@test "§4 F-017: total_files and large_files absent is legitimate, total_size absent is not" {
    have_payload analyze-empty
    # The empty fixture already omits both C fields; assert that on purpose.
    run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert "total_files" not in d, d
assert "large_files" not in d, d
assert d["total_size"] == 0
' "$CONTRACT_PAYLOADS/analyze-empty.json"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    assert_only_pending_new_fields analyze.schema.json "$CONTRACT_PAYLOADS/analyze-empty.json"

    # total_size carries no omitempty (§4.3) and is G. Dropping it must fail.
    corrupt "$CONTRACT_PAYLOADS/analyze-empty.json" "$HOME/no-total-size.json" \
        'd.pop("total_size")'
    assert_rejects analyze.schema.json "$HOME/no-total-size.json" "'total_size'"
}

@test "§4 analyze --json large_files appears only above the 1 MiB threshold" {
    have_payload analyze-large
    run python3 -c '
import json, sys
large = json.load(open(sys.argv[1]))
tiny = json.load(open(sys.argv[2]))
assert [f["name"] for f in large["large_files"]] == ["big.bin"], large
assert "large_files" not in tiny, tiny
' "$CONTRACT_PAYLOADS/analyze-large.json" "$CONTRACT_PAYLOADS/analyze-tiny.json"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}

# --- §5 clean --------------------------------------------------------------

@test "§5 clean --dry-run --json validates against its schema" {
    have_payload clean
    assert_valid clean_preview.schema.json "$CONTRACT_PAYLOADS/clean.json"
}

@test "§5 clean --dry-run --json REJECTED when size_known becomes the string \"true\"" {
    have_payload clean
    corrupt "$CONTRACT_PAYLOADS/clean.json" "$HOME/bad-clean.json" '
for c in d["data"]["categories"]:
    for e in c["entries"]:
        e["size_known"] = "true"
'
    assert_rejects clean_preview.schema.json "$HOME/bad-clean.json" "size_known"
}

@test "§5 clean --dry-run --json REJECTED when an entry size becomes a display string" {
    have_payload clean
    corrupt "$CONTRACT_PAYLOADS/clean.json" "$HOME/bad-clean-size.json" '
for c in d["data"]["categories"]:
    for e in c["entries"]:
        if "size_bytes" in e:
            e["size_bytes"] = "512.0KB"
'
    assert_rejects clean_preview.schema.json "$HOME/bad-clean-size.json" "size_bytes"
}

@test "§5 clean C fields: an unmeasured entry carries no size_bytes and still validates" {
    have_payload clean
    corrupt "$CONTRACT_PAYLOADS/clean.json" "$HOME/clean-unmeasured.json" '
for c in d["data"]["categories"]:
    for e in c["entries"]:
        e.pop("size_bytes", None)
        e.pop("item_count", None)
        e["size_known"] = False
'
    assert_valid clean_preview.schema.json "$HOME/clean-unmeasured.json"
}

# --- §6 uninstall --list ---------------------------------------------------

@test "§6 uninstall --list --json validates against its schema" {
    have_payload uninstall-list
    assert_valid uninstall_list.schema.json "$CONTRACT_PAYLOADS/uninstall-list.json"
}

@test "§6 uninstall --list --json REJECTED when size_bytes carries the display string" {
    have_payload uninstall-list
    corrupt "$CONTRACT_PAYLOADS/uninstall-list.json" "$HOME/bad-list.json" '
d["data"]["apps"][0]["size_bytes"] = d["data"]["apps"][0]["size"]
'
    assert_rejects uninstall_list.schema.json "$HOME/bad-list.json" "size_bytes"
}

@test "§6 uninstall --list C fields: the unmeasured app has no size_bytes, version or last_used" {
    have_payload uninstall-list
    run python3 -c '
import json, sys
apps = {a["name"]: a for a in json.load(open(sys.argv[1]))["data"]["apps"]}
broken = apps["Broken"]
assert broken["size_known"] is False, broken
for key in ("size_bytes", "version", "last_used"):
    assert key not in broken, (key, broken)
assert broken["size"] == "--"
assert apps["Slack"]["size_known"] is True and apps["Slack"]["size_bytes"] > 0
' "$CONTRACT_PAYLOADS/uninstall-list.json"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    assert_valid uninstall_list.schema.json "$CONTRACT_PAYLOADS/uninstall-list.json"
}

# --- §7 uninstall --plan / --apply-plan ------------------------------------

@test "§7.3 uninstall --plan --json validates under both delete modes" {
    have_payload plan-trash
    assert_valid uninstall_plan.schema.json "$CONTRACT_PAYLOADS/plan-trash.json"
    assert_valid uninstall_plan.schema.json "$CONTRACT_PAYLOADS/plan-permanent.json"
}

@test "§7.7 uninstall --plan --json REJECTED when delete_mode is missing" {
    have_payload plan-trash
    corrupt "$CONTRACT_PAYLOADS/plan-trash.json" "$HOME/bad-plan.json" \
        'd["data"].pop("delete_mode")'
    assert_rejects uninstall_plan.schema.json "$HOME/bad-plan.json" "'delete_mode'"
}

@test "§7.7 uninstall --plan --json REJECTED when delete_mode is outside its enum" {
    have_payload plan-trash
    corrupt "$CONTRACT_PAYLOADS/plan-trash.json" "$HOME/bad-plan-enum.json" \
        'd["data"]["delete_mode"] = "recycle"'
    assert_rejects uninstall_plan.schema.json "$HOME/bad-plan-enum.json" "delete_mode"
}

@test "§7.3 uninstall --plan C fields: no app.version and an unmeasured entry still validate" {
    have_payload plan-trash
    corrupt "$CONTRACT_PAYLOADS/plan-trash.json" "$HOME/plan-c-absent.json" '
d["data"]["app"].pop("version", None)
for e in d["data"]["entries"]:
    e.pop("size_bytes", None)
    e["size_known"] = False
d["data"]["unmeasured_items"] = len(d["data"]["entries"])
d["data"]["total_bytes"] = 0
'
    assert_valid uninstall_plan.schema.json "$HOME/plan-c-absent.json"
}

@test "§7.5 uninstall --apply-plan --json validates against its schema" {
    have_payload apply
    assert_valid uninstall_apply.schema.json "$CONTRACT_PAYLOADS/apply.json"
}

@test "§7.5 uninstall --apply-plan --json REJECTED on an outcome outside the closed enum" {
    have_payload apply
    corrupt "$CONTRACT_PAYLOADS/apply.json" "$HOME/bad-apply.json" \
        'd["data"]["results"][0]["outcome"] = "vaporised"'
    assert_rejects uninstall_apply.schema.json "$HOME/bad-apply.json" "outcome"
}

@test "§7.5 uninstall --apply-plan C fields: a result may carry neither size_bytes nor message" {
    have_payload apply
    corrupt "$CONTRACT_PAYLOADS/apply.json" "$HOME/apply-c-absent.json" '
for r in d["data"]["results"]:
    r.pop("size_bytes", None)
    r.pop("message", None)
d["data"]["freed_bytes"] = 0
'
    assert_valid uninstall_apply.schema.json "$HOME/apply-c-absent.json"
}

# --- §8 optimize -----------------------------------------------------------

@test "§8.5 optimize --dry-run --json validates against its schema" {
    have_payload optimize
    assert_valid optimize_preview.schema.json "$CONTRACT_PAYLOADS/optimize.json"
}

@test "§8.5 optimize --dry-run --json REJECTED when a counts key is omitted" {
    have_payload optimize
    corrupt "$CONTRACT_PAYLOADS/optimize.json" "$HOME/bad-optimize.json" \
        'd["data"]["counts"].pop("failed")'
    assert_rejects optimize_preview.schema.json "$HOME/bad-optimize.json" "'failed'"
}

@test "§8.5 optimize C fields: a task without detail, freed_bytes or duration_ms validates" {
    have_payload optimize
    corrupt "$CONTRACT_PAYLOADS/optimize.json" "$HOME/optimize-c-absent.json" '
for t in d["data"]["tasks"]:
    for key in ("detail", "freed_bytes", "duration_ms"):
        t.pop(key, None)
'
    assert_valid optimize_preview.schema.json "$HOME/optimize-c-absent.json"
}

# --- §1.3 / §1.6 the milestone bar, per command ----------------------------

@test "§1.3 every JSON payload is one JSON document on stdout with an empty stderr" {
    local name empty=1
    for name in status analyze-tiny analyze-large analyze-empty clean \
        uninstall-list plan-trash plan-permanent apply optimize; do
        [[ -s "$CONTRACT_PAYLOADS/$name.json" ]] || continue
        empty=0
        run python3 -c 'import json,sys;json.load(open(sys.argv[1]))' \
            "$CONTRACT_PAYLOADS/$name.json"
        [ "$status" -eq 0 ] || {
            echo "$name: stdout is not one JSON document"
            echo "$output"
            return 1
        }
        local bytes
        bytes=$(wc -c < "$CONTRACT_PAYLOADS/$name.stderr" | tr -d ' ')
        [ "$bytes" -eq 0 ] || {
            echo "$name wrote $bytes bytes to stderr:"
            cat "$CONTRACT_PAYLOADS/$name.stderr"
            return 1
        }
        [ "$(cat "$CONTRACT_PAYLOADS/$name.rc")" -eq 0 ] || {
            echo "$name exited $(cat "$CONTRACT_PAYLOADS/$name.rc")"
            return 1
        }
    done
    # Positive control: the loop must have seen payloads.
    [ "$empty" -eq 0 ]
    # The watch stream is NDJSON, so it is checked as frames, not as one document.
    if [[ -s "$CONTRACT_PAYLOADS/watch.ndjson.stderr" ]]; then
        cat "$CONTRACT_PAYLOADS/watch.ndjson.stderr"
        return 1
    fi
}

@test "§1.6 failure paths exit non-zero and put no human text in the JSON stream" {
    local name rc
    for name in analyze-missing clean-usage optimize-usage plan-usage apply-mismatch; do
        [[ -f "$CONTRACT_PAYLOADS/$name.rc" ]] || continue
        rc=$(cat "$CONTRACT_PAYLOADS/$name.rc")
        [ "$rc" -ne 0 ] || {
            echo "$name exited 0 on a failure path"
            return 1
        }
        # stdout is either empty or a well-formed JSON envelope — never prose.
        if [[ -s "$CONTRACT_PAYLOADS/$name.json" ]]; then
            run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["scan_status"] == "failed", d
assert d["error"] and d["error"]["code"], d
' "$CONTRACT_PAYLOADS/$name.json"
            [ "$status" -eq 0 ] || {
                echo "$name stdout is not a §1.4 failed envelope:"
                cat "$CONTRACT_PAYLOADS/$name.json"
                echo "$output"
                return 1
            }
        fi
    done
    # The mode mismatch is §7.7's own exit 2, and it must say so by code.
    [ "$(cat "$CONTRACT_PAYLOADS/apply-mismatch.rc")" -eq 2 ]
    run python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d["error"]["code"] == "plan_mode_mismatch", d
assert d["data"] is None, d
' "$CONTRACT_PAYLOADS/apply-mismatch.json"
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
}
