#!/bin/bash
# Mole - selection gate for `mo clean --apply-selection` (Molehouse SEL-M).
#
# The safety property: under --apply-selection, a removal happens only when
# this run's scan proposes a target AND that target is equal to, or inside, a
# path the user selected. Everything else the scan proposes is left alone.
#
# The gate is enforced at the shared removal sinks in lib/core/file_ops.sh
# (safe_remove, safe_remove_symlink, safe_sudo_remove, mole_delete, and the
# privileged batch in safe_sudo_find_delete), not in the callers, so a cleanup
# family added later is gated without being edited. Removal paths that bypass
# those sinks (owner-tool commands such as `brew cleanup`, `tmutil delete`)
# call mole_selection_refuses and do not run at all while a selection is active.
#
# State lives in two files named by exported variables, because several clean
# sections run in subshells and an array assignment there would be lost:
#   MOLE_CLEAN_SELECTION_FILE          NUL-delimited, normalised selected paths
#   MOLE_CLEAN_SELECTION_RESULTS_FILE  append-only NUL-delimited records:
#                                      outcome, section, size_kb, code, root, path
#
# A set MOLE_CLEAN_SELECTION_FILE that cannot be read permits nothing. The gate
# fails closed: the only way to remove a path is to match a loaded selection.
#
# Bash 3.2 compatible.

set -euo pipefail

if [[ -n "${MOLE_SELECTION_GATE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_SELECTION_GATE_LOADED=1

_MOLE_SELECTION_PATHS=()
_MOLE_SELECTION_LOADED_FROM=""
_MOLE_SELECTION_MATCH=""
_MOLE_SELECTION_NORMALIZED=""
# Set to 1 by a sink immediately before it attempts the Trash move, so the
# gated wrapper can tell "Mole's own policy refused this path" (skipped) from
# "the move was attempted and failed" (failed).
_MOLE_SELECTION_TRASH_ATTEMPTED=0

mole_selection_active() {
    [[ -n "${MOLE_CLEAN_SELECTION_FILE:-}" ]]
}

# Lexically normalise an absolute path: collapse repeated slashes, drop `.`
# components and a trailing slash. A `..` component is refused rather than
# resolved — resolving it lexically is not what the filesystem does through a
# symlink, and the gate must never guess. Sets _MOLE_SELECTION_NORMALIZED.
_mole_selection_normalize() {
    local raw="$1"
    _MOLE_SELECTION_NORMALIZED=""
    [[ "$raw" == /* ]] || return 1
    [[ "$raw" != *$'\n'* ]] || return 1

    local out="" component rest="${raw#/}"
    while [[ -n "$rest" ]]; do
        if [[ "$rest" == */* ]]; then
            component="${rest%%/*}"
            rest="${rest#*/}"
        else
            component="$rest"
            rest=""
        fi
        case "$component" in
            "" | ".") continue ;;
            "..") return 1 ;;
        esac
        out="$out/$component"
    done
    [[ -n "$out" ]] || out="/"
    _MOLE_SELECTION_NORMALIZED="$out"
}

_mole_selection_load() {
    local file="${MOLE_CLEAN_SELECTION_FILE:-}"
    [[ "$_MOLE_SELECTION_LOADED_FROM" == "$file" ]] && return 0
    _MOLE_SELECTION_PATHS=()
    _MOLE_SELECTION_LOADED_FROM="$file"
    [[ -n "$file" && -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
    local entry
    while IFS= read -r -d '' entry; do
        [[ -n "$entry" ]] && _MOLE_SELECTION_PATHS+=("$entry")
    done < "$file"
    return 0
}

# Does $1 fall under the selection? Sets _MOLE_SELECTION_MATCH to the selected
# root it matched. Equal-or-inside only: a selected child never authorises its
# parent, because removing the parent would remove unselected siblings.
_mole_selection_match() {
    local path="$1"
    _MOLE_SELECTION_MATCH=""
    _mole_selection_load || return 1
    [[ ${#_MOLE_SELECTION_PATHS[@]} -gt 0 ]] || return 1
    _mole_selection_normalize "$path" || return 1
    local target="$_MOLE_SELECTION_NORMALIZED" root
    for root in "${_MOLE_SELECTION_PATHS[@]}"; do
        if [[ "$target" == "$root" || "$target" == "$root/"* ]]; then
            _MOLE_SELECTION_MATCH="$root"
            return 0
        fi
    done
    return 1
}

# Append one outcome record. Outcomes:
#   trashed       moved to Trash
#   failed        the Trash move was attempted and did not complete
#   skipped       selected, but Mole's own policy refused it (code says why)
#   missing       selected and proposed, but gone before the sink ran
#   not_selected  proposed by the scan, not selected; untouched
_mole_selection_record() {
    local outcome="$1" path="$2" size_kb="${3:-}" code="${4:-}" root="${5:-}"
    local file="${MOLE_CLEAN_SELECTION_RESULTS_FILE:-}"
    [[ -n "$file" && -f "$file" && ! -L "$file" ]] || return 0
    printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
        "$outcome" "${CURRENT_SECTION:-Uncategorized}" "$size_kb" "$code" "$root" "$path" \
        >> "$file" 2> /dev/null || true
}

_mole_selection_in_user_trash() {
    local path="$1" user_home=""
    if declare -f get_invoking_home > /dev/null 2>&1; then
        user_home=$(get_invoking_home)
    else
        user_home="${HOME:-}"
    fi
    [[ -n "$user_home" ]] || return 1
    user_home="${user_home%/}"
    [[ "$path" == "$user_home/.Trash" || "$path" == "$user_home/.Trash/"* ]]
}

# The only removal a selection run performs: a rename into the invoking user's
# Trash. Never Finder or a third-party `trash` CLI (they act on the logged-in
# user's real Trash, ignore a sandbox HOME, and can raise Automation prompts),
# and never a fallback to permanent removal. Test harnesses that set
# MOLE_TEST_TRASH_DIR get the existing redirect.
# Args: path, needs_sudo, expected_parent, expected_parent_id, expected_target_id
_mole_selection_move_to_trash() {
    _MOLE_SELECTION_TRASH_ATTEMPTED=1
    if [[ -n "${MOLE_TEST_TRASH_DIR:-}" ]]; then
        _mole_move_to_trash "$@"
        return $?
    fi
    _mole_move_path_to_user_trash "$@"
}

# Run one sink under the gate. Called by each sink when a selection is active
# and the call is not already nested inside a gated call.
# Args: sink_function, path, precomputed_size_kb, sink_args...
_mole_selection_gated_call() {
    local sink="$1" path="$2" precomputed_kb="$3"
    shift 3

    # A selection run never previews: --apply-selection rejects --dry-run, so
    # a dry-run probe here means something unexpected. Remove nothing.
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        return 1
    fi

    if ! _mole_selection_match "$path"; then
        _mole_selection_record not_selected "$path"
        debug_log "Selection gate: not selected, left in place: $path"
        return 1
    fi
    local root="$_MOLE_SELECTION_MATCH"

    if _mole_selection_in_user_trash "$path"; then
        _mole_selection_record skipped "$path" "" already_in_trash "$root"
        return 1
    fi

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        _mole_selection_record missing "$path" "" "" "$root"
        return 0
    fi

    local size_kb=""
    if [[ "$precomputed_kb" =~ ^[0-9]+$ ]]; then
        size_kb="$precomputed_kb"
    else
        local measured="" size_rc=0
        measured=$(get_path_size_kb "$path" 2> /dev/null) || size_rc=$?
        if [[ $size_rc -ge 128 ]]; then
            _mole_record_clean_cancellation "$size_rc"
            return "$size_rc"
        fi
        [[ $size_rc -eq 0 && "$measured" =~ ^[0-9]+$ ]] && size_kb="$measured"
    fi

    local _MOLE_SELECTION_DEPTH=1
    _MOLE_SELECTION_TRASH_ATTEMPTED=0
    local rc=0
    "$sink" "$@" || rc=$?

    if [[ $rc -eq 0 ]]; then
        if [[ -e "$path" || -L "$path" ]]; then
            _mole_selection_record failed "$path" "$size_kb" still_present "$root"
        else
            _mole_selection_record trashed "$path" "$size_kb" "" "$root"
        fi
    elif [[ "$_MOLE_SELECTION_TRASH_ATTEMPTED" == "1" ]]; then
        local code="trash_failed"
        [[ $rc -eq 124 ]] && code="removal_timeout"
        [[ $rc -ge 128 ]] && code="interrupted"
        [[ $rc -eq ${MOLE_ERR_PRIVACY_DENIED:-14} ]] && code="permission_denied"
        if [[ -e "$path" || -L "$path" ]]; then
            _mole_selection_record failed "$path" "$size_kb" "$code" "$root"
        else
            # The move reported failure but the source is gone: a timed-out
            # rename that completed. Count what actually happened.
            _mole_selection_record trashed "$path" "$size_kb" "" "$root"
        fi
    else
        _mole_selection_record skipped "$path" "$size_kb" refused_by_policy "$root"
    fi
    _MOLE_SELECTION_TRASH_ATTEMPTED=0
    return "$rc"
}

# True when the calling sink must route through _mole_selection_gated_call.
_mole_selection_must_gate() {
    mole_selection_active && [[ "${_MOLE_SELECTION_DEPTH:-0}" == "0" ]]
}

# For removal paths that do not go through a file_ops.sh sink: owner-tool
# commands and the few deliberate raw carve-outs. Returns 0 — "refuse, do not
# run" — whenever a selection is active, and records why. A selected path that
# is the refused scope, or contains it, is reported as skipped with code
# unsupported_in_selection, so the caller learns it was seen and refused rather
# than reading it as "no longer proposed". A selected path strictly inside the
# scope is not: another cleaner may still propose and trash it on its own.
# Returns 1 when no selection is active: the caller proceeds as before.
# Args: label, scope_path (may be empty)
mole_selection_refuses() {
    mole_selection_active || return 1
    local label="$1" scope="${2:-}"
    local overlapped=false root normalized_scope=""

    if [[ -n "$scope" ]] && _mole_selection_normalize "$scope"; then
        normalized_scope="$_MOLE_SELECTION_NORMALIZED"
    fi
    if [[ -n "$normalized_scope" ]] && _mole_selection_load &&
        [[ ${#_MOLE_SELECTION_PATHS[@]} -gt 0 ]]; then
        for root in "${_MOLE_SELECTION_PATHS[@]}"; do
            if [[ "$root" == "$normalized_scope" || "$normalized_scope" == "$root/"* ]]; then
                _mole_selection_record skipped "$root" "" unsupported_in_selection "$root"
                overlapped=true
            fi
        done
    fi
    if [[ "$overlapped" != "true" ]]; then
        _mole_selection_record not_selected "${normalized_scope:-$label}"
    fi
    debug_log "Selection gate: refused owner-tool cleanup under --apply-selection: $label"
    return 0
}
