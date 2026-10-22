#!/usr/bin/env bats
# `mo optimize --only <id>[,<id>...]` — Molehouse CONTRACT.md §8 (SEL-M).
#
# A per-run task selection. It never writes the user's persistent
# whitelist_optimize, and a whitelisted task stays skipped even when selected.
# Apply-mode tests run only under a whitelist, so no handler ever executes.

bats_require_minimum_version 1.5.0

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT
    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME
    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-optimize-only-home.XXXXXX")"
    export HOME
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-optimize-only-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-optimize-only-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    export TERM="xterm-256color"
    export NO_COLOR=1
    rm -rf "${HOME:?}"/*
    mkdir -p "$HOME/.config/mole"
}

catalog_ids() {
    env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lib/optimize/catalog.sh"
        printf "%s\n" "${MOLE_OPTIMIZE_ACTIONS[@]}"'
}

@test "--only with --dry-run --json runs only the named tasks, in catalog order, and counts only them" {
    run --separate-stderr env HOME="$HOME" MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/mole" optimize --dry-run --json --only cache_refresh,system_maintenance
    [ "$status" -eq 0 ] || { echo "exit $status: $stderr"; return 1; }
    local json="$output"

    [[ "$(jq -c '[.data.tasks[].id]' <<< "$json")" == '["system_maintenance","cache_refresh"]' ]] ||
        { echo "tasks that ran: $(jq -c '[.data.tasks[].id]' <<< "$json")"; return 1; }
    [[ "$(jq '[.data.counts[]] | add' <<< "$json")" == "2" ]] ||
        { echo "counts must cover only the 2 tasks that ran: $(jq -c .data.counts <<< "$json")"; return 1; }
    [[ "$(jq -c '.data.selection' <<< "$json")" == '["cache_refresh","system_maintenance"]' ]] || return 1

    run python3 "$PROJECT_ROOT/tests/schemas/validate.py" \
        "$PROJECT_ROOT/tests/schemas/optimize_preview.schema.json" /dev/stdin <<< "$json"
    [ "$status" -eq 0 ] || { echo "schema: $output"; return 1; }
}

@test "without --only every catalog task runs and data.selection is null" {
    run --separate-stderr env HOME="$HOME" MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/mole" optimize --dry-run --json
    [ "$status" -eq 0 ] || return 1
    [[ "$(jq -r '.data.selection' <<< "$output")" == "null" ]] || return 1
    [[ "$(jq '.data.tasks | length' <<< "$output")" == "$(catalog_ids | wc -l | tr -d ' ')" ]] || return 1
}

@test "--only without --json runs only the named task in the human output" {
    run --separate-stderr env HOME="$HOME" MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/mole" optimize --dry-run --only cache_refresh
    [[ "$output" == *"Finder Cache Refresh"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"DNS & Spotlight Check"* ]] || { echo "an unselected task ran"; return 1; }
    [[ "$output" != *'"schema_version"'* ]] || return 1
}

@test "an unknown or retired id is a usage error: exit 2, empty stdout, nothing runs" {
    local id
    for id in no_such_task dock_refresh memory_pressure_relief "cache_refresh,dock_refresh" "" ",,"; do
        run --separate-stderr env HOME="$HOME" MOLE_TEST_NO_AUTH=1 \
            "$PROJECT_ROOT/mole" optimize --dry-run --json --only "$id"
        [ "$status" -eq 2 ] || { echo "exit $status for --only '$id'"; return 1; }
        [ -z "$output" ] || { echo "stdout for --only '$id': $output"; return 1; }
        [[ -n "$stderr" ]] || return 1
    done
    run --separate-stderr env HOME="$HOME" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" optimize --json --only
    [ "$status" -eq 2 ] || return 1
    run --separate-stderr env HOME="$HOME" MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" optimize --list --json --only cache_refresh
    [ "$status" -eq 2 ] || return 1
    [ -z "$output" ] || return 1
}

@test "apply honours the whitelist under --only, and --only never writes whitelist_optimize" {
    catalog_ids > "$HOME/.config/mole/whitelist_optimize"
    local before
    before=$(shasum "$HOME/.config/mole/whitelist_optimize")

    run --separate-stderr env HOME="$HOME" MOLE_TEST_NO_AUTH=1 \
        "$PROJECT_ROOT/mole" optimize --json --only cache_refresh
    [ "$status" -eq 0 ] || { echo "exit $status: $stderr"; return 1; }
    [[ "$(jq -r '.mode' <<< "$output")" == "apply" ]] || return 1
    [[ "$(jq -c '[.data.tasks[] | {id, outcome}]' <<< "$output")" == '[{"id":"cache_refresh","outcome":"skipped"}]' ]] ||
        { echo "a selected but whitelisted task must report skipped: $(jq -c .data.tasks <<< "$output")"; return 1; }
    [[ "$(jq -r '.data.tasks[0].detail' <<< "$output")" == *"whitelisted"* ]] || return 1
    [[ "$(shasum "$HOME/.config/mole/whitelist_optimize")" == "$before" ]] ||
        { echo "--only modified the persistent whitelist"; return 1; }
}
