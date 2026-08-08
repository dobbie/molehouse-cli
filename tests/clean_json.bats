#!/usr/bin/env bats
# `mo clean --dry-run --json` — CONTRACT.md §5 structured preview.
# Serialisation-only assertions: the ledger and sudo-availability flag are
# already exercised by tests/clean_core.bats; these tests only check the
# JSON shape and the byte-identical guarantee for the non-JSON path.

setup_file() {
    PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export PROJECT_ROOT

    ORIGINAL_HOME="${HOME:-}"
    export ORIGINAL_HOME

    HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-clean-json-home.XXXXXX")"
    export HOME

    MOLE_TEST_MODE=1
    export MOLE_TEST_MODE

    # Same isolation as clean_core.bats: point the two expensive host scans
    # at nothing so MOLE_TEST_MODE=0 tests stay fast and host-independent.
    MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT="$HOME/absent-sim-runtime-volumes"
    MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT="$HOME/absent-sim-runtime-cryptex"
    MOLE_LSREGISTER_PATH=""
    export MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT
    export MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT
    export MOLE_LSREGISTER_PATH

    mkdir -p "$HOME"
}

teardown_file() {
    if [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        rm -rf "$HOME"
    fi
    if [[ -n "${ORIGINAL_HOME:-}" ]]; then
        export HOME="$ORIGINAL_HOME"
    fi
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    export TERM="xterm-256color"
    rm -rf "${HOME:?}"/*
    rm -rf "$HOME/Library" "$HOME/.config"
    mkdir -p "$HOME/Library/Caches" "$HOME/.config/mole"
    unset TEST_MOCK_BIN MOCK_TOOLCHAIN_BIN
}

set_mock_sudo_uncached() {
    local mock_home="${1:-$HOME}"
    TEST_MOCK_BIN="$mock_home/bin"
    mkdir -p "$TEST_MOCK_BIN"
    cat > "$TEST_MOCK_BIN/sudo" << 'MOCK'
#!/bin/bash
# Shim: sudo -n always fails (no cached credentials).
exit 1
MOCK
    chmod +x "$TEST_MOCK_BIN/sudo"
}

# Stub the two host toolchains the real pipeline shells out to. See
# tests/clean_core.bats:set_mock_host_toolchains for the full rationale;
# duplicated here rather than shared because bats files don't share
# function definitions.
set_mock_host_toolchains() {
    local mock_home="${1:-$HOME}"
    MOCK_TOOLCHAIN_BIN="$mock_home/toolchain-bin"
    mkdir -p "$MOCK_TOOLCHAIN_BIN"

    cat > "$MOCK_TOOLCHAIN_BIN/brew" << 'MOCK'
#!/bin/bash
case "${1:-}" in
    --cache) echo "$HOME/Library/Caches/Homebrew" ;;
    --prefix) echo "$HOME/homebrew" ;;
esac
exit 0
MOCK

    cat > "$MOCK_TOOLCHAIN_BIN/xcrun" << 'MOCK'
#!/bin/bash
exit 1
MOCK

    chmod +x "$MOCK_TOOLCHAIN_BIN/brew" "$MOCK_TOOLCHAIN_BIN/xcrun"
}

@test "mo clean --json without --dry-run is a usage error, not a scan" {
    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --json
    [ "$status" -eq 2 ]
    [ -z "$output" ] || [[ "$output" == *"requires --dry-run"* ]]
}

@test "mo clean --dry-run --json emits only JSON on stdout" {
    set_mock_sudo_uncached
    run env HOME="$HOME" PATH="$TEST_MOCK_BIN:$PATH" MOLE_TEST_MODE=1 \
        "$PROJECT_ROOT/mole" clean --dry-run --json
    [ "$status" -eq 0 ] || return 1

    # A single well-formed JSON document and nothing else: jq fails on any
    # leading/trailing prose, ANSI, or a second document on the same stream.
    echo "$output" | jq -e . > /dev/null
}

@test "mo clean --dry-run --json envelope matches CONTRACT.md §1.5/§5.4" {
    set_mock_sudo_uncached
    run env HOME="$HOME" PATH="$TEST_MOCK_BIN:$PATH" MOLE_TEST_MODE=1 \
        "$PROJECT_ROOT/mole" clean --dry-run --json
    [ "$status" -eq 0 ] || return 1

    local json="$output"
    [[ "$(echo "$json" | jq -r '.schema_version')" == "1" ]] || return 1
    [[ "$(echo "$json" | jq -r '.command')" == "clean" ]] || return 1
    [[ "$(echo "$json" | jq -r '.mode')" == "preview" ]] || return 1
    [[ "$(echo "$json" | jq -r '.error')" == "null" ]] || return 1
    echo "$json" | jq -e '.warnings | type == "array"' > /dev/null || return 1
    echo "$json" | jq -e '.data.categories | type == "array"' > /dev/null || return 1
    echo "$json" | jq -e '.data.deferred | type == "array"' > /dev/null || return 1
    echo "$json" | jq -e '.data.total_bytes | type == "number"' > /dev/null || return 1
    echo "$json" | jq -e '.data.total_bytes == (.data.total_bytes | floor)' > /dev/null || return 1
}

@test "mo clean --dry-run --json reports sudo_unavailable + partial without cached sudo" {
    set_mock_sudo_uncached
    run env HOME="$HOME" PATH="$TEST_MOCK_BIN:$PATH" MOLE_TEST_MODE=1 \
        "$PROJECT_ROOT/mole" clean --dry-run --json
    [ "$status" -eq 0 ] || return 1

    local json="$output"
    [[ "$(echo "$json" | jq -r '.scan_status')" == "partial" ]] || return 1
    [[ "$(echo "$json" | jq -r '.data.sudo_available')" == "false" ]] || return 1
    echo "$json" | jq -e '.warnings | any(.code == "sudo_unavailable")' > /dev/null || return 1
    local system_cat
    system_cat=$(echo "$json" | jq -c '.data.categories[] | select(.id == "system")')
    [[ "$(echo "$system_cat" | jq -r '.status')" == "skipped" ]] || return 1
}

@test "mo clean --dry-run --json entries carry integer size_bytes, never a display string" {
    mkdir -p "$HOME/Library/Caches/TestApp"
    dd if=/dev/zero of="$HOME/Library/Caches/TestApp/cache.bin" bs=1024 count=512 2> /dev/null

    set_mock_sudo_uncached
    set_mock_host_toolchains
    run env HOME="$HOME" PATH="$TEST_MOCK_BIN:$MOCK_TOOLCHAIN_BIN:$PATH" MOLE_TEST_MODE=0 \
        MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" clean --dry-run --json
    [ "$status" -eq 0 ] || return 1

    local json="$output"
    # No display-string size anywhere in the payload (§1.1).
    [[ "$json" != *MB* && "$json" != *GB* && "$json" != *KB* ]] || return 1

    local entry
    entry=$(echo "$json" | jq -c '[.data.categories[].entries[] | select(.path | test("TestApp$"))][0]')
    [[ "$entry" != "null" ]] || return 1
    [[ "$(echo "$entry" | jq -r '.size_known')" == "true" ]] || return 1
    echo "$entry" | jq -e '.size_bytes | type == "number"' > /dev/null || return 1
    [[ "$(echo "$entry" | jq -r '.size_bytes')" -gt 0 ]] || return 1
    [[ "$(echo "$entry" | jq -r '.requires_sudo')" == "false" ]] || return 1
}

@test "mo clean --dry-run --json category_count counts categories, not entries" {
    mkdir -p "$HOME/Library/Caches/TestApp"
    dd if=/dev/zero of="$HOME/Library/Caches/TestApp/cache.bin" bs=1024 count=64 2> /dev/null

    set_mock_sudo_uncached
    set_mock_host_toolchains
    run env HOME="$HOME" PATH="$TEST_MOCK_BIN:$MOCK_TOOLCHAIN_BIN:$PATH" MOLE_TEST_MODE=0 \
        MOLE_TEST_NO_AUTH=1 "$PROJECT_ROOT/mole" clean --dry-run --json
    [ "$status" -eq 0 ] || return 1

    local json="$output"
    local declared actual
    declared=$(echo "$json" | jq -r '.data.category_count')
    actual=$(echo "$json" | jq -r '.data.categories | length')
    [[ "$declared" == "$actual" ]] || return 1
    # A regression guard for the bug this test was written against: counting
    # top-level "{" in the rendered array double-counts every nested entry,
    # so with real ledger entries present the wrong implementation would
    # report a number in the thousands, not a small category count.
    [[ "$declared" -lt 100 ]] || return 1
}

@test "mo clean --dry-run --json total_bytes only sums size_known entries" {
    set_mock_sudo_uncached
    run env HOME="$HOME" PATH="$TEST_MOCK_BIN:$PATH" MOLE_TEST_MODE=1 \
        "$PROJECT_ROOT/mole" clean --dry-run --json
    [ "$status" -eq 0 ] || return 1

    local json="$output"
    local expected
    expected=$(echo "$json" | jq '[.data.categories[].entries[] | select(.size_known == true) | .size_bytes] | add // 0')
    [[ "$(echo "$json" | jq -r '.data.total_bytes')" == "$expected" ]] || return 1
}

@test "mo clean --dry-run --json is deterministic across two runs on identical input" {
    set_mock_sudo_uncached
    run env HOME="$HOME" PATH="$TEST_MOCK_BIN:$PATH" MOLE_TEST_MODE=1 \
        "$PROJECT_ROOT/mole" clean --dry-run --json
    [ "$status" -eq 0 ] || return 1
    local first
    first=$(echo "$output" | jq 'del(.generated_at)')

    run env HOME="$HOME" PATH="$TEST_MOCK_BIN:$PATH" MOLE_TEST_MODE=1 \
        "$PROJECT_ROOT/mole" clean --dry-run --json
    [ "$status" -eq 0 ] || return 1
    local second
    second=$(echo "$output" | jq 'del(.generated_at)')

    [[ "$first" == "$second" ]] || return 1
}

@test "mo clean rejects removed cleanup selection flags with --json set" {
    run env HOME="$HOME" MOLE_TEST_MODE=1 "$PROJECT_ROOT/mole" clean --dry-run --json --select foo
    [ "$status" -ne 0 ]
    [[ "$output" == *"was removed in this release"* ]]
}

@test "mo clean --dry-run (no --json) output is unchanged: no JSON envelope keys" {
    set_mock_sudo_uncached
    run env HOME="$HOME" PATH="$TEST_MOCK_BIN:$PATH" MOLE_TEST_MODE=1 \
        "$PROJECT_ROOT/mole" clean --dry-run
    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Dry Run Mode"* ]] || return 1
    [[ "$output" != *'"schema_version"'* ]] || return 1
    [[ "$output" != *'"scan_status"'* ]] || return 1
}
