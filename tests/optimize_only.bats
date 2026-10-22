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

# F-117: the apply path asks for a sudo session only when a task that will run
# needs admin. The shim records every sudo and osascript call; `sudo -n true`
# answers yes so a run that does ask never reaches a tty or a password dialog.
make_sudo_shim() {
    SHIM_DIR="$HOME/shim"
    SUDO_LOG="$HOME/sudo-calls.log"
    mkdir -p "$SHIM_DIR"
    : > "$SUDO_LOG"
    printf '#!/bin/bash\necho "sudo $*" >> "%s"\nexit 0\n' "$SUDO_LOG" > "$SHIM_DIR/sudo"
    printf '#!/bin/bash\necho "osascript $*" >> "%s"\nexit 1\n' "$SUDO_LOG" > "$SHIM_DIR/osascript"
    chmod +x "$SHIM_DIR/sudo" "$SHIM_DIR/osascript"
}

@test "apply --only with no admin task never touches sudo (F-117)" {
    catalog_ids > "$HOME/.config/mole/whitelist_optimize"
    make_sudo_shim
    run --separate-stderr env -u MOLE_TEST_NO_AUTH -u MOLE_TEST_MODE HOME="$HOME" PATH="$SHIM_DIR:$PATH" \
        "$PROJECT_ROOT/mole" optimize --json --only cache_refresh,fix_broken_configs
    [ "$status" -eq 0 ] || { echo "exit $status: $stderr"; return 1; }
    [[ "$(jq -r '.mode' <<< "$output")" == "apply" ]] || return 1
    [[ ! -s "$SUDO_LOG" ]] ||
        { echo "a run of non-admin tasks must not call sudo or show a dialog; saw: $(cat "$SUDO_LOG")"; return 1; }
}

@test "apply --only with an admin task still asks for the sudo session (F-117)" {
    catalog_ids > "$HOME/.config/mole/whitelist_optimize"
    make_sudo_shim
    run --separate-stderr env -u MOLE_TEST_NO_AUTH -u MOLE_TEST_MODE HOME="$HOME" PATH="$SHIM_DIR:$PATH" \
        "$PROJECT_ROOT/mole" optimize --json --only fix_broken_configs,network_optimization
    [ "$status" -eq 0 ] || { echo "exit $status: $stderr"; return 1; }
    grep -q '^sudo ' "$SUDO_LOG" ||
        { echo "a run that includes an admin task must still request sudo; log: $(cat "$SUDO_LOG")"; return 1; }
}

@test "human apply --only with no admin task never touches sudo (F-117)" {
    catalog_ids > "$HOME/.config/mole/whitelist_optimize"
    make_sudo_shim
    run env -u MOLE_TEST_NO_AUTH -u MOLE_TEST_MODE HOME="$HOME" PATH="$SHIM_DIR:$PATH" \
        "$PROJECT_ROOT/mole" optimize --only fix_broken_configs
    [[ ! -s "$SUDO_LOG" ]] ||
        { echo "saw: $(cat "$SUDO_LOG")"; return 1; }
    [[ "$output" != *"Skipping sudo-required optimizations"* ]] || return 1
}

@test "optimize_selected_requires_sudo follows the selection" {
    run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc -c '
        source "$PROJECT_ROOT/lib/optimize/catalog.sh"
        optimize_selected_requires_sudo && echo all-yes || echo all-no
        MOLE_OPTIMIZE_ONLY_IDS=(cache_refresh)
        optimize_selected_requires_sudo && echo one-yes || echo one-no
        MOLE_OPTIMIZE_ONLY_IDS=(cache_refresh network_optimization)
        optimize_selected_requires_sudo && echo mix-yes || echo mix-no'
    [ "$status" -eq 0 ]
    [[ "$output" == $'all-yes\none-no\nmix-yes' ]] || { echo "$output"; return 1; }
}
