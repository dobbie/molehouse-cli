#!/bin/bash
# Mole - `mo clean --dry-run --json` structured preview emitter.
#
# Serialises state bin/clean.sh already computes for the human-readable dry
# run: the dry-run ledger (identity, size_kb, count, size_known, section,
# path), the sudo-availability flag, sizing-timeout counters, and the
# project-artifact "mo purge" hint. This file adds no new scanning; it only
# formats what bin/clean.sh already has. See Molehouse/CONTRACT.md §5.
#
# Bash 3.2 compatible: no `declare -A`, no `${var,,}`, no `mapfile`.

set -euo pipefail

if [[ -n "${MOLE_CLEAN_JSON_EMIT_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_CLEAN_JSON_EMIT_LOADED=1

# String escaping reuses lib/core/history.sh's per-character JSON escaper
# (history_json_escape / history_json_string) instead of a second copy —
# scripts/audit_function_duplication.py gates new same-body groups, and this
# one is exactly that: general-purpose JSON string escaping, not
# history-specific. See mole/CLAUDE.md "Judge duplication by body, not name."
_MOLE_JSON_EMIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/core/history.sh
source "$_MOLE_JSON_EMIT_DIR/../core/history.sh"

_clean_json_escape() { history_json_escape "${1:-}"; }
_clean_json_string() { history_json_string "${1:-}"; }

# Stable machine slug from a display section label: lowercase, non
# [a-z0-9] runs collapsed to one underscore, trimmed. Bash-3.2 safe (tr
# instead of ${var,,}).
# shellcheck disable=SC2329
_clean_json_slug() {
    local s
    s=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')
    while [[ "$s" == *__* ]]; do
        s="${s//__/_}"
    done
    s="${s#_}"
    s="${s%_}"
    [[ -n "$s" ]] || s="uncategorized"
    printf '%s' "$s"
}

# Look up the index of $1 in the CLEAN_JSON_CAT_NAMES array. Prints the
# index and returns 0 on a hit; returns 1 with nothing printed on a miss.
# shellcheck disable=SC2329
_clean_json_cat_index() {
    local name="$1" i
    if [[ ${#CLEAN_JSON_CAT_NAMES[@]} -eq 0 ]]; then
        return 1
    fi
    for i in "${!CLEAN_JSON_CAT_NAMES[@]}"; do
        if [[ "${CLEAN_JSON_CAT_NAMES[$i]}" == "$name" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

# Build the `data.categories` + running totals from the deduplicated dry-run
# ledger (see bin/clean.sh:emit_deduplicated_dry_run_ledger). Populates:
#   CLEAN_JSON_CAT_NAMES / CLEAN_JSON_CAT_ENTRIES / CLEAN_JSON_CAT_BYTES / CLEAN_JSON_CAT_ITEMS
#   CLEAN_JSON_TOTAL_BYTES, CLEAN_JSON_TOTAL_ITEMS, CLEAN_JSON_UNMEASURED_ITEMS
# Args: system_clean ("true"/"false")
# shellcheck disable=SC2329
clean_json_collect_ledger() {
    local system_clean="$1"

    CLEAN_JSON_CAT_NAMES=()
    CLEAN_JSON_CAT_ENTRIES=()
    CLEAN_JSON_CAT_BYTES=()
    CLEAN_JSON_CAT_ITEMS=()
    CLEAN_JSON_TOTAL_BYTES=0
    CLEAN_JSON_TOTAL_ITEMS=0
    CLEAN_JSON_UNMEASURED_ITEMS=0

    local identity size_kb count size_known section path
    while IFS= read -r -d '' identity &&
        IFS= read -r -d '' size_kb &&
        IFS= read -r -d '' count &&
        IFS= read -r -d '' size_known &&
        IFS= read -r -d '' section &&
        IFS= read -r -d '' path; do
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
        [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || count=1
        [[ "$size_known" == "true" || "$size_known" == "false" ]] || size_known=false

        local label requires_sudo entry_json size_bytes
        label=$(basename "$path")
        if [[ "$section" == "System" ]]; then
            requires_sudo=true
        else
            requires_sudo=false
        fi

        entry_json='{"path":"'
        entry_json+=$(_clean_json_escape "$path")
        entry_json+='","label":"'
        entry_json+=$(_clean_json_escape "$label")
        entry_json+='","size_known":'
        entry_json+="$size_known"
        if [[ "$size_known" == "true" ]]; then
            size_bytes=$((size_kb * 1024))
            entry_json+=",\"size_bytes\":$size_bytes"
            CLEAN_JSON_TOTAL_BYTES=$((CLEAN_JSON_TOTAL_BYTES + size_bytes))
        else
            CLEAN_JSON_UNMEASURED_ITEMS=$((CLEAN_JSON_UNMEASURED_ITEMS + 1))
        fi
        entry_json+=",\"item_count\":$count,\"requires_sudo\":$requires_sudo}"

        local idx
        if idx=$(_clean_json_cat_index "$section"); then
            :
        else
            CLEAN_JSON_CAT_NAMES+=("$section")
            CLEAN_JSON_CAT_ENTRIES+=("")
            CLEAN_JSON_CAT_BYTES+=(0)
            CLEAN_JSON_CAT_ITEMS+=(0)
            idx=$((${#CLEAN_JSON_CAT_NAMES[@]} - 1))
        fi

        if [[ -n "${CLEAN_JSON_CAT_ENTRIES[idx]}" ]]; then
            CLEAN_JSON_CAT_ENTRIES[idx]+=",$entry_json"
        else
            CLEAN_JSON_CAT_ENTRIES[idx]="$entry_json"
        fi
        if [[ "$size_known" == "true" ]]; then
            CLEAN_JSON_CAT_BYTES[idx]=$((CLEAN_JSON_CAT_BYTES[idx] + size_bytes))
        fi
        CLEAN_JSON_CAT_ITEMS[idx]=$((CLEAN_JSON_CAT_ITEMS[idx] + 1))
        CLEAN_JSON_TOTAL_ITEMS=$((CLEAN_JSON_TOTAL_ITEMS + 1))
    done < <(emit_deduplicated_dry_run_ledger)

    return 0
}

# Build the final category display order into the global CLEAN_JSON_CAT_ORDER
# array: merges ledger groups with sections that ran but found nothing (from
# JSON_SECTION_NAMES, populated by start_section) and the System section when
# sudo was unavailable (it never calls start_section at all in that case).
# Must be called directly (not inside `$(...)`) — it sets a global array, and
# a command-substitution subshell would discard that assignment on exit.
# Args: system_clean ("true"/"false")
# shellcheck disable=SC2329
clean_json_build_category_order() {
    local system_clean="$1"
    local name found existing

    CLEAN_JSON_CAT_ORDER=()

    # Every `for … in "${arr[@]}"` below is guarded by a `${#arr[@]} -gt 0`
    # check first: bash 3.2 (macOS's /bin/bash) raises "unbound variable"
    # on `${arr[@]}` for a zero-element array under `set -u`, unlike bash
    # 4.4+. See mole/CLAUDE.md's bash-3.2 note.
    if [[ ${#JSON_SECTION_NAMES[@]} -gt 0 ]]; then
        for name in "${JSON_SECTION_NAMES[@]}"; do
            [[ "$name" == "Project artifacts" ]] && continue
            found=false
            if [[ ${#CLEAN_JSON_CAT_ORDER[@]} -gt 0 ]]; then
                for existing in "${CLEAN_JSON_CAT_ORDER[@]}"; do
                    [[ "$existing" == "$name" ]] && found=true && break
                done
            fi
            [[ "$found" == "true" ]] || CLEAN_JSON_CAT_ORDER+=("$name")
        done
    fi

    if [[ "$system_clean" != "true" ]]; then
        found=false
        if [[ ${#CLEAN_JSON_CAT_ORDER[@]} -gt 0 ]]; then
            for existing in "${CLEAN_JSON_CAT_ORDER[@]}"; do
                [[ "$existing" == "System" ]] && found=true && break
            done
        fi
        if [[ "$found" != "true" ]]; then
            if [[ ${#CLEAN_JSON_CAT_ORDER[@]} -gt 0 ]]; then
                CLEAN_JSON_CAT_ORDER=("System" "${CLEAN_JSON_CAT_ORDER[@]}")
            else
                CLEAN_JSON_CAT_ORDER=("System")
            fi
        fi
    fi

    if [[ ${#CLEAN_JSON_CAT_NAMES[@]} -gt 0 ]]; then
        for name in "${CLEAN_JSON_CAT_NAMES[@]}"; do
            found=false
            if [[ ${#CLEAN_JSON_CAT_ORDER[@]} -gt 0 ]]; then
                for existing in "${CLEAN_JSON_CAT_ORDER[@]}"; do
                    [[ "$existing" == "$name" ]] && found=true && break
                done
            fi
            [[ "$found" == "true" ]] || CLEAN_JSON_CAT_ORDER+=("$name")
        done
    fi

    return 0
}

# Render the `data.categories` array onto stdout from CLEAN_JSON_CAT_ORDER
# (clean_json_build_category_order must run first, in the parent shell).
# Safe to call inside `$(...)` — it only reads globals, sets none the caller
# needs back.
# Args: system_clean ("true"/"false")
# shellcheck disable=SC2329
clean_json_render_categories() {
    local system_clean="$1"
    local name

    printf '['
    if [[ ${#CLEAN_JSON_CAT_ORDER[@]} -eq 0 ]]; then
        printf ']'
        return 0
    fi
    local first=true
    for name in "${CLEAN_JSON_CAT_ORDER[@]}"; do
        local idx status entries total_bytes item_count
        if idx=$(_clean_json_cat_index "$name"); then
            entries="${CLEAN_JSON_CAT_ENTRIES[$idx]}"
            total_bytes="${CLEAN_JSON_CAT_BYTES[$idx]}"
            item_count="${CLEAN_JSON_CAT_ITEMS[$idx]}"
            status="scanned"
        else
            entries=""
            total_bytes=0
            item_count=0
            if [[ "$name" == "System" && "$system_clean" != "true" ]]; then
                status="skipped"
            else
                status="nothing_to_clean"
            fi
        fi

        [[ "$first" == "true" ]] || printf ','
        first=false
        printf '{"id":"%s","label":' "$(_clean_json_slug "$name")"
        _clean_json_string "$name"
        printf ',"total_bytes":%s,"item_count":%s,"status":"%s","entries":[%s]}' \
            "$total_bytes" "$item_count" "$status" "$entries"
    done
    printf ']'
}

# Render `data.deferred` — the "mo purge" build-artifact advisory, when the
# probe found any. Never counted toward totals (§5.4).
# shellcheck disable=SC2329
clean_json_render_deferred() {
    if [[ "${PROJECT_ARTIFACT_HINT_DETECTED:-false}" != "true" ]]; then
        printf '[]'
        return 0
    fi

    local item_count="${PROJECT_ARTIFACT_HINT_COUNT:-0}"
    [[ "$item_count" =~ ^[0-9]+$ ]] || item_count=0

    printf '[{"id":"project_artifacts","label":"Build artifacts","item_count":%s,"suggested_command":"purge"' \
        "$item_count"
    if [[ "${PROJECT_ARTIFACT_HINT_ESTIMATE_SAMPLES:-0} " -gt 0 && "${PROJECT_ARTIFACT_HINT_ESTIMATED_KB:-0}" =~ ^[0-9]+$ ]]; then
        printf ',"size_bytes":%s' "$((PROJECT_ARTIFACT_HINT_ESTIMATED_KB * 1024))"
    fi
    printf '}]'
}

# Emit the full CONTRACT.md §5.5 envelope for `mole clean --dry-run --json`
# onto the real stdout (fd 1 at call time must already be restored — the
# caller redirects fd 1 to /dev/null only around start_cleanup/perform_cleanup).
# Args: cleanup_rc, start_rc, mole_version
# shellcheck disable=SC2329
clean_json_emit_preview() {
    local cleanup_rc="${1:-0}"
    local start_rc="${2:-0}"
    local mole_version="${3:-unknown}"
    local generated_at
    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if [[ "$start_rc" -ne 0 ]]; then
        printf '{"schema_version":1,"mole_version":"%s","command":"clean","mode":"preview","generated_at":"%s","scan_status":"failed","warnings":[],"error":{"code":"scan_failed","message":"could not prepare the cleanup preview"},"data":null}\n' \
            "$mole_version" "$generated_at"
        return 0
    fi

    local system_clean="${SYSTEM_CLEAN:-false}"
    clean_json_collect_ledger "$system_clean"

    local -a warnings=()
    if [[ "$system_clean" != "true" ]]; then
        warnings+=('{"code":"sudo_unavailable","scope":"System caches","message":"System caches need sudo; preview is incomplete."}')
    fi
    local sizing_timeouts="${MOLE_CLEAN_SIZING_TIMEOUTS:-0}"
    [[ "$sizing_timeouts" =~ ^[0-9]+$ ]] || sizing_timeouts=0
    if [[ "$sizing_timeouts" -gt 0 ]]; then
        warnings+=("{\"code\":\"sizing_timeout\",\"message\":\"$sizing_timeouts item(s) exceeded the sizing budget and were counted as size_known: false.\"}")
    fi
    if [[ "$cleanup_rc" -ne 0 ]]; then
        warnings+=("{\"code\":\"scan_cancelled\",\"message\":\"The scan was cancelled or timed out before completing (exit $cleanup_rc); results are a lower bound.\"}")
    fi

    local scan_status="complete"
    [[ ${#warnings[@]} -gt 0 ]] && scan_status="partial"

    local warnings_json="[]"
    if [[ ${#warnings[@]} -gt 0 ]]; then
        warnings_json="["
        local w first=true
        for w in "${warnings[@]}"; do
            [[ "$first" == "true" ]] || warnings_json+=","
            first=false
            warnings_json+="$w"
        done
        warnings_json+="]"
    fi

    # Must run outside command substitution: it sets the global
    # CLEAN_JSON_CAT_ORDER array that both the count below and the render
    # call after it depend on. See its header comment.
    clean_json_build_category_order "$system_clean"
    local category_count=${#CLEAN_JSON_CAT_ORDER[@]}

    local categories_json deferred_json
    categories_json=$(clean_json_render_categories "$system_clean")
    deferred_json=$(clean_json_render_deferred)

    printf '{"schema_version":1,"mole_version":"%s","command":"clean","mode":"preview","generated_at":"%s","scan_status":"%s","warnings":%s,"error":null,"data":{"total_bytes":%s,"total_items":%s,"category_count":%s,"unmeasured_items":%s,"sudo_available":%s,"categories":%s,"deferred":%s}}\n' \
        "$mole_version" "$generated_at" "$scan_status" "$warnings_json" \
        "$CLEAN_JSON_TOTAL_BYTES" "$CLEAN_JSON_TOTAL_ITEMS" "$category_count" "$CLEAN_JSON_UNMEASURED_ITEMS" \
        "$system_clean" "$categories_json" "$deferred_json"
}
