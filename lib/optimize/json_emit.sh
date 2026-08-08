#!/bin/bash
# Mole - `mo optimize --list --json` / `mo optimize [--dry-run] --json`
# structured emitter.
#
# Serialises state bin/optimize.sh and lib/optimize/outcomes.sh already
# compute: the catalog (lib/optimize/catalog.sh) for `--list`, and the
# per-task outcome ledger (lib/optimize/outcomes.sh, populated by
# execute_optimization / optimize_task_finish) for preview/apply. This file
# adds no new scanning or task logic; it only formats what already ran. See
# Molehouse/CONTRACT.md §8.
#
# Bash 3.2 compatible: no `declare -A`, no `${var,,}`, no `mapfile`.

set -euo pipefail

if [[ -n "${MOLE_OPTIMIZE_JSON_EMIT_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_OPTIMIZE_JSON_EMIT_LOADED=1

# String escaping reuses lib/core/history.sh's per-character JSON escaper
# (history_json_escape / history_json_string) instead of a second copy — see
# lib/clean/json_emit.sh's identical note and mole/CLAUDE.md "Judge
# duplication by body, not name."
_MOLE_OPTIMIZE_JSON_EMIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/core/history.sh
source "$_MOLE_OPTIMIZE_JSON_EMIT_DIR/../core/history.sh"

_optimize_json_string() { history_json_string "${1:-}"; }

# One `data.tasks` row for `--list` (CONTRACT.md §8.4). Reads only the
# catalog arrays at the given index; runs nothing.
_optimize_json_list_row() {
    local index="$1"
    printf '{"id":'
    _optimize_json_string "${MOLE_OPTIMIZE_ACTIONS[$index]}"
    printf ',"label":'
    _optimize_json_string "${MOLE_OPTIMIZE_HEALTH_NAMES[$index]}"
    printf ',"description":'
    _optimize_json_string "${MOLE_OPTIMIZE_DESCRIPTIONS[$index]}"
    printf ',"whitelist_name":'
    _optimize_json_string "${MOLE_OPTIMIZE_WHITELIST_NAMES[$index]}"
    printf ',"requires_sudo":%s}' "${MOLE_OPTIMIZE_REQUIRES_SUDO[$index]}"
}

# Emit the §8.4 `--list` envelope onto the real stdout. Runs no task: the
# catalog is already fully populated by lib/optimize/catalog.sh at source
# time. Args: mole_version.
optimize_json_emit_list() {
    local mole_version="${1:-unknown}"
    local generated_at
    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    printf '{"schema_version":1,"mole_version":"%s","command":"optimize","mode":"list","generated_at":"%s","scan_status":"complete","warnings":[],"error":null,"data":{"tasks":[' \
        "$mole_version" "$generated_at"

    local count=${#MOLE_OPTIMIZE_ACTIONS[@]}
    local index
    for ((index = 0; index < count; index++)); do
        [[ $index -eq 0 ]] || printf ','
        _optimize_json_list_row "$index"
    done
    printf ']}}\n'
}

# Emit the "could not produce usable output" envelope (CONTRACT.md §1.4/§1.6
# exit 1 case): a missing dependency, a failed health-data collection, or an
# outcome ledger that does not match the catalog (see bin/optimize.sh's
# pre-existing "Optimize task outcomes are incomplete" guard). Args:
# mole_version, mode ("preview"|"apply").
optimize_json_emit_error() {
    local mole_version="${1:-unknown}"
    local mode="${2:-preview}"
    local generated_at
    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    printf '{"schema_version":1,"mole_version":"%s","command":"optimize","mode":"%s","generated_at":"%s","scan_status":"failed","warnings":[],"error":{"code":"scan_failed","message":"could not complete the optimize run"},"data":null}\n' \
        "$mole_version" "$mode" "$generated_at"
}

# Emit the §8.5 preview/apply envelope from the outcome ledger
# (MOLE_OPTIMIZE_RESULT_ACTIONS/_OUTCOMES/_DETAILS in lib/optimize/outcomes.sh)
# that execute_optimization already populated. Must be called only after
# confirming optimize_outcome_total equals the catalog size — the caller's
# job, not this emitter's — so every catalog task below has a matching
# ledger entry and `outcome` is never the empty string. Args: mole_version,
# mode ("preview"|"apply").
optimize_json_emit_result() {
    local mole_version="${1:-unknown}"
    local mode="${2:-preview}"
    local generated_at
    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local applied unchanged skipped unavailable attention failed
    applied=$(optimize_outcome_count "$MOLE_OPTIMIZE_OUTCOME_APPLIED")
    unchanged=$(optimize_outcome_count "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED")
    skipped=$(optimize_outcome_count "$MOLE_OPTIMIZE_OUTCOME_SKIPPED")
    unavailable=$(optimize_outcome_count "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE")
    attention=$(optimize_outcome_count "$MOLE_OPTIMIZE_OUTCOME_ATTENTION")
    failed=$(optimize_outcome_count "$MOLE_OPTIMIZE_OUTCOME_FAILED")

    local scan_status="complete"
    [[ "$failed" -gt 0 ]] && scan_status="partial"

    # data.tasks: one record per catalog task, in catalog order (§8.5). The
    # catalog — not the result ledger — drives iteration order, so a task
    # that never called optimize_task_finish would show up as a gap rather
    # than silently reordering around it (see Gap 3 in
    # docs/handoff-M1-T3.md: this never happens today, but the emitter does
    # not assume it never will).
    local tasks_json="" warnings_json=""
    local count=${#MOLE_OPTIMIZE_ACTIONS[@]}
    local index action label outcome detail result_index found
    local first_task=true first_warning=true
    for ((index = 0; index < count; index++)); do
        action="${MOLE_OPTIMIZE_ACTIONS[$index]}"
        label="${MOLE_OPTIMIZE_HEALTH_NAMES[$index]}"
        outcome=""
        detail=""
        found=false
        if [[ ${#MOLE_OPTIMIZE_RESULT_ACTIONS[@]} -gt 0 ]]; then
            for result_index in "${!MOLE_OPTIMIZE_RESULT_ACTIONS[@]}"; do
                if [[ "${MOLE_OPTIMIZE_RESULT_ACTIONS[$result_index]}" == "$action" ]]; then
                    outcome="${MOLE_OPTIMIZE_RESULT_OUTCOMES[$result_index]}"
                    detail="${MOLE_OPTIMIZE_RESULT_DETAILS[$result_index]:-}"
                    found=true
                    break
                fi
            done
        fi
        # Defensive only (see docstring): a catalog task with no ledger
        # entry has no outcome to report truthfully, so it is dropped from
        # data.tasks rather than fabricated as one of the six closed-enum
        # values. The caller is expected to have already turned this case
        # into a "failed" envelope before ever calling this function.
        [[ "$found" == "true" ]] || continue

        [[ "$first_task" == "true" ]] || tasks_json+=","
        first_task=false
        tasks_json+="{\"id\":$(_optimize_json_string "$action")"
        tasks_json+=",\"label\":$(_optimize_json_string "$label")"
        tasks_json+=",\"outcome\":$(_optimize_json_string "$outcome")"
        if [[ -n "$detail" ]]; then
            tasks_json+=",\"detail\":$(_optimize_json_string "$detail")"
        fi
        tasks_json+="}"

        if [[ "$outcome" == "$MOLE_OPTIMIZE_OUTCOME_FAILED" ]]; then
            local warn_message="$detail"
            [[ -n "$warn_message" ]] || warn_message="Task failed; no further detail was captured."
            [[ "$first_warning" == "true" ]] || warnings_json+=","
            first_warning=false
            warnings_json+="{\"code\":\"task_failed\",\"scope\":$(_optimize_json_string "$action")"
            warnings_json+=",\"message\":$(_optimize_json_string "$warn_message")}"
        fi
    done

    printf '{"schema_version":1,"mole_version":"%s","command":"optimize","mode":"%s","generated_at":"%s","scan_status":"%s","warnings":[%s],"error":null,"data":{"counts":{"applied":%s,"unchanged":%s,"skipped":%s,"unavailable":%s,"attention":%s,"failed":%s},"tasks":[%s]}}\n' \
        "$mole_version" "$mode" "$generated_at" "$scan_status" "$warnings_json" \
        "$applied" "$unchanged" "$skipped" "$unavailable" "$attention" "$failed" "$tasks_json"
}
