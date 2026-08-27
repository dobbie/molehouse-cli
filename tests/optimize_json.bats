#!/usr/bin/env bats
# `mo optimize --list --json` / `mo optimize [--dry-run] --json` —
# CONTRACT.md §8 structured catalog/preview/apply output.
# Serialisation-only assertions: individual task behaviour is already
# exercised by tests/optimize.bats and tests/optimize_db.bats; these tests
# only check the JSON shape, the exit-code remap, and the byte-identical
# guarantee for the non-JSON path.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-optimize-json-home.XXXXXX")"
    export HOME
    mkdir -p "$HOME"
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-optimize-json-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-optimize-json-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    export TERM="xterm-256color"
    export NO_COLOR=1
    rm -rf "${HOME:?}"/*
    mkdir -p "$HOME/.config/mole"
}

# Whitelists every catalog action so `mo optimize --json` (apply mode, no
# --dry-run) never actually invokes a handler — execute_optimization
# short-circuits every task to "skipped" before dispatch (lib/optimize/tasks.sh
# execute_optimization). Same technique tests/optimize_summary.bats uses to
# exercise apply mode without touching real system state.
whitelist_every_catalog_action() {
    local config_dir="$HOME/.config/mole"
    mkdir -p "$config_dir"
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/catalog.sh"
printf '%s\n' "${MOLE_OPTIMIZE_ACTIONS[@]}"
EOF
    [[ "$status" -eq 0 ]] || return 1
    printf '%s\n' "$output" > "$config_dir/whitelist_optimize"
}

@test "mo optimize --list without --json is a usage error, runs nothing" {
    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" optimize --list
    [ "$status" -eq 2 ]
    [[ "$output" != *'"schema_version"'* ]]
}

@test "mo optimize --list --json emits only JSON and returns every catalog task in order" {
    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" optimize --list --json
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    # A single well-formed JSON document and nothing else.
    echo "$output" | jq -e . > /dev/null

    local json="$output"
    [[ "$(echo "$json" | jq -r '.schema_version')" == "1" ]] || return 1
    [[ "$(echo "$json" | jq -r '.command')" == "optimize" ]] || return 1
    [[ "$(echo "$json" | jq -r '.mode')" == "list" ]] || return 1
    [[ "$(echo "$json" | jq -r '.scan_status')" == "complete" ]] || return 1
    [[ "$(echo "$json" | jq -r '.error')" == "null" ]] || return 1
    echo "$json" | jq -e '.warnings == []' > /dev/null || return 1

    local catalog_ids declared_ids
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/catalog.sh"
printf '%s\n' "${MOLE_OPTIMIZE_ACTIONS[@]}"
EOF
    [[ "$status" -eq 0 ]] || return 1
    catalog_ids="$output"
    declared_ids=$(echo "$json" | jq -r '.data.tasks[].id')
    [[ "$declared_ids" == "$catalog_ids" ]] || {
        echo "catalog order: $catalog_ids"
        echo "--list order:  $declared_ids"
        return 1
    }

    local catalog_count
    catalog_count=$(printf '%s\n' "$catalog_ids" | wc -l | tr -d ' ')
    [[ "$(echo "$json" | jq '.data.tasks | length')" == "$catalog_count" ]] || return 1

    # Every row carries the G fields; requires_sudo is a real boolean.
    echo "$json" | jq -e '[.data.tasks[] | select((.requires_sudo | type) != "boolean")] | length == 0' > /dev/null || return 1
    echo "$json" | jq -e '[.data.tasks[] | select(.label == null or .description == null or .id == null)] | length == 0' > /dev/null || return 1
}

@test "mo optimize --dry-run --json emits only JSON on stdout" {
    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_VPN_ACTIVE=0 \
        "$PROJECT_ROOT/mole" optimize --dry-run --json
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    echo "$output" | jq -e . > /dev/null
}

@test "mo optimize --dry-run --json envelope matches CONTRACT.md §1.5/§8.5" {
    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_VPN_ACTIVE=0 \
        "$PROJECT_ROOT/mole" optimize --dry-run --json
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    local json="$output"
    [[ "$(echo "$json" | jq -r '.schema_version')" == "1" ]] || return 1
    [[ "$(echo "$json" | jq -r '.command')" == "optimize" ]] || return 1
    [[ "$(echo "$json" | jq -r '.mode')" == "preview" ]] || return 1
    [[ "$(echo "$json" | jq -r '.error')" == "null" ]] || return 1
    echo "$json" | jq -e '.warnings | type == "array"' > /dev/null || return 1

    # data.counts: all six keys, always present.
    for key in applied unchanged skipped unavailable attention failed; do
        echo "$json" | jq -e ".data.counts | has(\"$key\")" > /dev/null || {
            echo "missing counts.$key"
            return 1
        }
        echo "$json" | jq -e ".data.counts.$key | type == \"number\"" > /dev/null || return 1
    done

    # counts sums to the same total as data.tasks length (§8.5).
    local counts_sum tasks_len
    counts_sum=$(echo "$json" | jq '[.data.counts[]] | add')
    tasks_len=$(echo "$json" | jq '.data.tasks | length')
    [[ "$counts_sum" == "$tasks_len" ]] || {
        echo "counts sum $counts_sum != tasks length $tasks_len"
        return 1
    }

    # Every task row is a closed-enum outcome and carries an id/label.
    echo "$json" | jq -e '[.data.tasks[] | select(.outcome as $o | (["applied","unchanged","skipped","unavailable","attention","failed"] | index($o)) == null)] | length == 0' > /dev/null || return 1
    echo "$json" | jq -e '[.data.tasks[] | select(.id == null or .label == null)] | length == 0' > /dev/null || return 1
}

# Stubs `find` to fail so saved_state_cleanup's discovery scan reports
# "failed" deterministically, even under --dry-run (unlike cache_refresh's
# qlmanage calls, which opt_cache_refresh skips entirely in dry-run mode —
# see lib/optimize/tasks.sh). Same technique as
# tests/optimize_probe_outcomes.bats's "saved state cleanup reports a failed
# discovery scan", just driven through the full `mole optimize --json` CLI
# instead of calling execute_optimization directly.
force_saved_state_scan_failure() {
    mkdir -p "$HOME/Library/Saved Application State"
    local stub_dir="$HOME/bin"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/find" << 'EOF'
#!/bin/bash
exit 7
EOF
    chmod +x "$stub_dir/find"
}

@test "mo optimize --dry-run --json exits 0 while the non-JSON path keeps exit 1 on task failure" {
    force_saved_state_scan_failure

    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_VPN_ACTIVE=0 PATH="$HOME/bin:$PATH" \
        "$PROJECT_ROOT/mole" optimize --dry-run
    [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    [[ "$output" == *"failed"* ]] || { echo "$output"; return 1; }

    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_VPN_ACTIVE=0 PATH="$HOME/bin:$PATH" \
        "$PROJECT_ROOT/mole" optimize --dry-run --json
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local json="$output"
    [[ "$(echo "$json" | jq -r '.scan_status')" == "partial" ]] || return 1
    [[ "$(echo "$json" | jq '.data.counts.failed')" -ge 1 ]] || return 1
}

@test "mo optimize --dry-run --json reports one warning per failed task with the action id as scope" {
    force_saved_state_scan_failure

    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_VPN_ACTIVE=0 PATH="$HOME/bin:$PATH" \
        "$PROJECT_ROOT/mole" optimize --dry-run --json
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    local json="$output"

    local failed_ids warning_scopes
    failed_ids=$(echo "$json" | jq -r '[.data.tasks[] | select(.outcome == "failed") | .id] | sort | join(",")')
    warning_scopes=$(echo "$json" | jq -r '[.warnings[] | select(.code == "task_failed") | .scope] | sort | join(",")')
    [[ "$failed_ids" == "$warning_scopes" ]] || {
        echo "failed task ids:   $failed_ids"
        echo "warning scopes:    $warning_scopes"
        return 1
    }
    [[ -n "$failed_ids" ]] || return 1
    [[ "$failed_ids" == *"saved_state_cleanup"* ]] || return 1

    # saved_state_cleanup's failure has real captured detail — the exact
    # specimen text CONTRACT.md §8.7 quotes — so this warning must not be
    # the generic fallback.
    local saved_state_message
    saved_state_message=$(echo "$json" | jq -r '.warnings[] | select(.scope == "saved_state_cleanup") | .message')
    [[ "$saved_state_message" == "Failed to scan old saved states" ]] || {
        echo "saved_state_cleanup warning message: $saved_state_message"
        return 1
    }
}

@test "mo optimize --dry-run --json is deterministic across two runs on identical input" {
    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_VPN_ACTIVE=0 \
        "$PROJECT_ROOT/mole" optimize --dry-run --json
    [ "$status" -eq 0 ] || return 1
    local first
    first=$(echo "$output" | jq 'del(.generated_at)')

    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_VPN_ACTIVE=0 \
        "$PROJECT_ROOT/mole" optimize --dry-run --json
    [ "$status" -eq 0 ] || return 1
    local second
    second=$(echo "$output" | jq 'del(.generated_at)')

    [[ "$first" == "$second" ]] || {
        diff <(echo "$first") <(echo "$second")
        return 1
    }
}

@test "mo optimize --json (apply mode) reports mode apply and stays safe under a full whitelist" {
    whitelist_every_catalog_action

    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" optimize --json
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    local json="$output"
    [[ "$(echo "$json" | jq -r '.mode')" == "apply" ]] || return 1
    [[ "$(echo "$json" | jq -r '.scan_status')" == "complete" ]] || return 1
    echo "$json" | jq -e '.warnings == []' > /dev/null || return 1
    [[ "$(echo "$json" | jq '.data.counts.failed')" == "0" ]] || return 1
    # Every task is whitelisted, so every task is "skipped" and nothing ran.
    echo "$json" | jq -e '[.data.tasks[] | select(.outcome != "skipped")] | length == 0' > /dev/null || return 1

    rm -f "$HOME/.config/mole/whitelist_optimize"
}

@test "mo optimize --dry-run (no --json) output is unchanged: no JSON envelope keys" {
    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_VPN_ACTIVE=0 \
        "$PROJECT_ROOT/mole" optimize --dry-run
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    [[ "$output" == *"Dry Run"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *'"schema_version"'* ]] || return 1
    [[ "$output" != *'"scan_status"'* ]] || return 1
}

@test "F-083: no task in a preview payload reports a completed action" {
    # The screen this feeds is the one where a misreading means an unrequested
    # change to the user's machine. Asserted over the payload a reader sees,
    # not over the ledger variable the emitter consults.
    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_VPN_ACTIVE=0 \
        "$PROJECT_ROOT/mole" optimize --dry-run --json
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    [[ "$(echo "$output" | jq -r '.mode')" == "preview" ]] || return 1

    local offenders
    offenders=$(echo "$output" | jq -c '[.data.tasks[] | select(.outcome == "applied" and has("detail"))]')
    [[ "$offenders" == "[]" ]] || {
        printf 'a preview described changes it did not make: %s\n' "$offenders" >&2
        return 1
    }
}

@test "F-083: a preview still reports why a task failed" {
    # The other half: suppressing every detail would suppress the §8.5
    # task_failed warning messages with them. Whenever a preview reports a
    # failure, that failure keeps its text.
    run env HOME="$HOME" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_VPN_ACTIVE=0 \
        "$PROJECT_ROOT/mole" optimize --dry-run --json
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    local failed
    failed=$(echo "$output" | jq -r '.data.counts.failed')
    if [[ "$failed" -gt 0 ]]; then
        echo "$output" | jq -e '.warnings | any(.code == "task_failed")' > /dev/null || return 1
        echo "$output" | jq -e '[.warnings[] | select(.code == "task_failed") | .message | select(length > 0)] | length > 0' > /dev/null || {
            printf 'a failed task in a preview lost its message\n' >&2
            return 1
        }
    fi
}
