#!/bin/bash
# Mole - `mo clean --apply-selection [--json]` (Molehouse SEL-M).
#
# Reads the selection document on stdin, then bin/clean.sh runs its normal
# scan for real with the selection gate (lib/core/selection_gate.sh) active.
# This file owns the two ends of that run: parsing and validating the stdin
# document before anything is scanned, and reporting what the gate recorded.
# See Molehouse/CONTRACT.md §5.5.
#
# Bash 3.2 compatible: no `declare -A`, no `${var,,}`, no `mapfile`.

set -euo pipefail

if [[ -n "${MOLE_CLEAN_APPLY_SELECTION_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_CLEAN_APPLY_SELECTION_LOADED=1

CLEAN_SELECTION_ERROR=""
CLEAN_SELECTION_REQUESTED=0

# Print the strings of the document's `selected_paths` array, one per line.
# Fails closed: any element that is not a single-line <string> (a number, a
# nested array, a dict, or a string spanning lines because it contains a
# newline) exits nonzero, and so does a numeric character reference the
# unescape below does not handle.
# Args: document_file
_clean_selection_read_paths() {
    local doc_file="$1"
    plutil -extract selected_paths xml1 -o - "$doc_file" 2> /dev/null | awk '
        function unesc(s) {
            gsub(/&lt;/, "<", s)
            gsub(/&gt;/, ">", s)
            gsub(/&quot;/, "\"", s)
            gsub(/&apos;/, "'"'"'", s)
            gsub(/&amp;/, "\\&", s)
            return s
        }
        /^[[:space:]]*<\?xml/ || /^[[:space:]]*<!DOCTYPE/ || /^[[:space:]]*<plist/ { next }
        /^[[:space:]]*<\/plist>/ { next }
        /^[[:space:]]*<array\/>[[:space:]]*$/ { if (opened) exit 4; opened = 1; closed = 1; next }
        /^[[:space:]]*<array>[[:space:]]*$/ { if (opened) exit 4; opened = 1; next }
        /^[[:space:]]*<\/array>[[:space:]]*$/ { if (!opened || closed) exit 4; closed = 1; next }
        {
            if (!opened || closed) exit 4
            line = $0
            if (line !~ /^[[:space:]]*<string>.*<\/string>[[:space:]]*$/) exit 3
            if (line ~ /&#/) exit 3
            sub(/^[[:space:]]*<string>/, "", line)
            sub(/<\/string>[[:space:]]*$/, "", line)
            print unesc(line)
        }
        END { if (!opened || !closed) exit 4 }
    '
}

# Is $1 the invoking user's home, or one of its ancestors? Selecting one of
# those would authorise every target under it, turning a selection into the
# whole-scan clean it exists to avoid.
_clean_selection_is_home_or_ancestor() {
    local path="$1" user_home=""
    user_home=$(get_invoking_home 2> /dev/null || true)
    [[ -n "$user_home" ]] || user_home="${HOME:-}"
    user_home="${user_home%/}"
    [[ "$path" == "/" ]] && return 0
    [[ -n "$user_home" ]] || return 1
    [[ "$user_home" == "$path" || "$user_home" == "$path/"* ]]
}

# Read and validate the selection document.
# Args: document_file (stdin is copied here), selection_out (NUL-delimited)
# Returns 0, or 2 with CLEAN_SELECTION_ERROR set. Nothing is removed either way.
clean_selection_read() {
    local doc_file="$1" out_file="$2"
    CLEAN_SELECTION_ERROR=""
    CLEAN_SELECTION_REQUESTED=0

    # Reading a terminal would block on EOF with no output at all, which is
    # indistinguishable from a hang. Say what is expected instead.
    if [[ -t 0 ]]; then
        CLEAN_SELECTION_ERROR="reads a selection document on stdin, e.g. 'mo clean --apply-selection < selection.json'"
        return 2
    fi
    cat > "$doc_file"

    if ! plutil -convert json -o /dev/null "$doc_file" > /dev/null 2>&1; then
        CLEAN_SELECTION_ERROR="stdin is not a valid JSON document"
        return 2
    fi
    local schema_type schema_version
    schema_type=$(plutil -type schema_version "$doc_file" 2> /dev/null || true)
    schema_version=$(plutil -extract schema_version raw -o - "$doc_file" 2> /dev/null || true)
    if [[ "$schema_type" != "integer" || "$schema_version" != "1" ]]; then
        CLEAN_SELECTION_ERROR="schema_version must be the integer 1"
        return 2
    fi
    if [[ "$(plutil -type selected_paths "$doc_file" 2> /dev/null || true)" != "array" ]]; then
        CLEAN_SELECTION_ERROR="selected_paths must be an array of absolute paths"
        return 2
    fi

    local raw_list=""
    local parse_rc=0
    raw_list=$(_clean_selection_read_paths "$doc_file") || parse_rc=$?
    if [[ $parse_rc -ne 0 ]]; then
        CLEAN_SELECTION_ERROR="selected_paths must contain only single-line path strings"
        return 2
    fi

    : > "$out_file"
    if [[ -z "$raw_list" ]]; then
        CLEAN_SELECTION_ERROR="selected_paths is empty; nothing to clean"
        return 2
    fi
    local -a accepted=()
    local raw normalized existing duplicate
    while IFS= read -r raw; do
        if [[ -z "$raw" || "$raw" != /* ]]; then
            CLEAN_SELECTION_ERROR="every selected path must be absolute: '${raw}'"
            return 2
        fi
        if ! _mole_selection_normalize "$raw"; then
            CLEAN_SELECTION_ERROR="a selected path may not contain '..': '${raw}'"
            return 2
        fi
        normalized="$_MOLE_SELECTION_NORMALIZED"
        if _clean_selection_is_home_or_ancestor "$normalized"; then
            CLEAN_SELECTION_ERROR="a selected path may not be the home folder or one of its parents: '${raw}'"
            return 2
        fi
        duplicate=false
        if [[ ${#accepted[@]} -gt 0 ]]; then
            for existing in "${accepted[@]}"; do
                [[ "$existing" == "$normalized" ]] && duplicate=true && break
            done
        fi
        [[ "$duplicate" == "true" ]] && continue
        accepted+=("$normalized")
    done <<< "$raw_list"

    if [[ ${#accepted[@]} -eq 0 ]]; then
        CLEAN_SELECTION_ERROR="selected_paths is empty; nothing to clean"
        return 2
    fi
    printf '%s\0' "${accepted[@]}" > "$out_file"
    CLEAN_SELECTION_REQUESTED=${#accepted[@]}
    return 0
}

# Refusal before anything ran, as a §1.5 `failed` envelope.
# Args: mole_version, code, message
clean_json_emit_apply_failed() {
    local generated_at
    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '{"schema_version":1,"mole_version":'
    history_json_string "$1"
    printf ',"command":"clean","mode":"apply","generated_at":"%s","scan_status":"failed","warnings":[],"error":{"code":' "$generated_at"
    history_json_string "$2"
    printf ',"message":'
    history_json_string "$3"
    printf '},"data":null}\n'
}

_clean_apply_message_for_code() {
    case "$1" in
        trash_failed) echo "Could not be moved to the Trash; left in place." ;;
        permission_denied) echo "macOS refused the move to the Trash; left in place." ;;
        removal_timeout) echo "The move to the Trash timed out; the item may be partly moved." ;;
        interrupted) echo "The move to the Trash was interrupted." ;;
        still_present) echo "Reported as moved but still present; left in place." ;;
        already_in_trash) echo "Already in the Trash; a Trash-only clean cannot remove it." ;;
        refused_by_policy) echo "Refused at removal time by Mole's safety rules (protected, whitelisted, in use, or changed since the scan)." ;;
        unsupported_in_selection) echo "Cleaned only by a whole-cache tool command, which a selection cannot narrow; left in place." ;;
        *) echo "Not removed." ;;
    esac
}

# Fold the gate's records into the per-category and selection totals. Sets
# CLEAN_APPLY_* globals; must run in the parent shell, not inside $(...).
# Args: results_file, selection_file
clean_apply_collect() {
    local results_file="$1" selection_file="$2"

    CLEAN_APPLY_CAT_NAMES=()
    CLEAN_APPLY_CAT_FREED=()
    CLEAN_APPLY_CAT_REMOVED=()
    CLEAN_APPLY_CAT_FAILED=()
    CLEAN_APPLY_CAT_SKIPPED=()
    CLEAN_APPLY_CAT_FAILURES=()
    CLEAN_APPLY_CAT_SKIPS=()
    CLEAN_APPLY_FREED_BYTES=0
    CLEAN_APPLY_REMOVED=0
    CLEAN_APPLY_FAILED=0
    CLEAN_APPLY_SKIPPED=0
    CLEAN_APPLY_NOT_SELECTED=0
    CLEAN_APPLY_UNMEASURED=0
    CLEAN_APPLY_TIMEOUT_WARNINGS=()
    CLEAN_APPLY_ROOTS=()
    CLEAN_APPLY_ROOT_REMOVED=()
    CLEAN_APPLY_ROOT_SEEN=()

    local root
    if [[ -f "$selection_file" ]]; then
        while IFS= read -r -d '' root; do
            CLEAN_APPLY_ROOTS+=("$root")
            CLEAN_APPLY_ROOT_REMOVED+=(0)
            CLEAN_APPLY_ROOT_SEEN+=(0)
        done < "$selection_file"
    fi

    [[ -f "$results_file" ]] || return 0
    local outcome section size_kb code path idx i entry message
    while IFS= read -r -d '' outcome &&
        IFS= read -r -d '' section &&
        IFS= read -r -d '' size_kb &&
        IFS= read -r -d '' code &&
        IFS= read -r -d '' root &&
        IFS= read -r -d '' path; do
        if [[ "$outcome" == "not_selected" ]]; then
            CLEAN_APPLY_NOT_SELECTED=$((CLEAN_APPLY_NOT_SELECTED + 1))
            continue
        fi

        # Mark the selected root as proposed (and removed) by this run. A
        # `missing` record leaves the root unseen: it was already gone.
        if [[ "$outcome" != "missing" && ${#CLEAN_APPLY_ROOTS[@]} -gt 0 ]]; then
            for i in "${!CLEAN_APPLY_ROOTS[@]}"; do
                if [[ "${CLEAN_APPLY_ROOTS[$i]}" == "$root" ]]; then
                    CLEAN_APPLY_ROOT_SEEN[i]=1
                    [[ "$outcome" == "trashed" ]] && CLEAN_APPLY_ROOT_REMOVED[i]=1
                    break
                fi
            done
        fi
        [[ "$outcome" == "missing" ]] && continue

        idx=""
        if [[ ${#CLEAN_APPLY_CAT_NAMES[@]} -gt 0 ]]; then
            for i in "${!CLEAN_APPLY_CAT_NAMES[@]}"; do
                [[ "${CLEAN_APPLY_CAT_NAMES[$i]}" == "$section" ]] && idx="$i" && break
            done
        fi
        if [[ -z "$idx" ]]; then
            CLEAN_APPLY_CAT_NAMES+=("$section")
            CLEAN_APPLY_CAT_FREED+=(0)
            CLEAN_APPLY_CAT_REMOVED+=(0)
            CLEAN_APPLY_CAT_FAILED+=(0)
            CLEAN_APPLY_CAT_SKIPPED+=(0)
            CLEAN_APPLY_CAT_FAILURES+=("")
            CLEAN_APPLY_CAT_SKIPS+=("")
            idx=$((${#CLEAN_APPLY_CAT_NAMES[@]} - 1))
        fi

        case "$outcome" in
            trashed)
                CLEAN_APPLY_REMOVED=$((CLEAN_APPLY_REMOVED + 1))
                CLEAN_APPLY_CAT_REMOVED[idx]=$((CLEAN_APPLY_CAT_REMOVED[idx] + 1))
                if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
                    CLEAN_APPLY_FREED_BYTES=$((CLEAN_APPLY_FREED_BYTES + size_kb * 1024))
                    CLEAN_APPLY_CAT_FREED[idx]=$((CLEAN_APPLY_CAT_FREED[idx] + size_kb * 1024))
                else
                    CLEAN_APPLY_UNMEASURED=$((CLEAN_APPLY_UNMEASURED + 1))
                fi
                ;;
            failed)
                message=$(_clean_apply_message_for_code "$code")
                if [[ "$code" == "removal_timeout" ]]; then
                    # §5.5: a removal timeout means "possibly partly removed"
                    # and surfaces as a warning, never as a clean failure.
                    entry='{"code":"removal_timeout","scope":'
                    entry+="$(history_json_string "$path"),\"message\":$(history_json_string "$message")}"
                    CLEAN_APPLY_TIMEOUT_WARNINGS+=("$entry")
                    continue
                fi
                CLEAN_APPLY_FAILED=$((CLEAN_APPLY_FAILED + 1))
                CLEAN_APPLY_CAT_FAILED[idx]=$((CLEAN_APPLY_CAT_FAILED[idx] + 1))
                entry="{\"path\":$(history_json_string "$path"),\"code\":$(history_json_string "$code"),\"message\":$(history_json_string "$message")}"
                if [[ -n "${CLEAN_APPLY_CAT_FAILURES[idx]}" ]]; then
                    CLEAN_APPLY_CAT_FAILURES[idx]+=",$entry"
                else
                    CLEAN_APPLY_CAT_FAILURES[idx]="$entry"
                fi
                ;;
            skipped)
                CLEAN_APPLY_SKIPPED=$((CLEAN_APPLY_SKIPPED + 1))
                CLEAN_APPLY_CAT_SKIPPED[idx]=$((CLEAN_APPLY_CAT_SKIPPED[idx] + 1))
                message=$(_clean_apply_message_for_code "$code")
                entry="{\"path\":$(history_json_string "$path"),\"code\":$(history_json_string "$code"),\"message\":$(history_json_string "$message")}"
                if [[ -n "${CLEAN_APPLY_CAT_SKIPS[idx]}" ]]; then
                    CLEAN_APPLY_CAT_SKIPS[idx]+=",$entry"
                else
                    CLEAN_APPLY_CAT_SKIPS[idx]="$entry"
                fi
                ;;
        esac
    done < "$results_file"
    return 0
}

# Selected roots this run's scan never proposed (or that were already gone
# when the sink reached them), one per line.
clean_apply_not_proposed() {
    local i
    [[ ${#CLEAN_APPLY_ROOTS[@]} -gt 0 ]] || return 0
    for i in "${!CLEAN_APPLY_ROOTS[@]}"; do
        [[ "${CLEAN_APPLY_ROOT_SEEN[$i]}" == "1" ]] || printf '%s\n' "${CLEAN_APPLY_ROOTS[$i]}"
    done
}

clean_apply_removed_or_partial() {
    local i count=0
    if [[ ${#CLEAN_APPLY_ROOTS[@]} -gt 0 ]]; then
        for i in "${!CLEAN_APPLY_ROOTS[@]}"; do
            [[ "${CLEAN_APPLY_ROOT_REMOVED[$i]}" == "1" ]] && count=$((count + 1))
        done
    fi
    printf '%s' "$count"
}

# Emit the §5.5 apply envelope on the real stdout.
# Args: cleanup_rc, start_rc, mole_version, results_file, selection_file
clean_json_emit_apply() {
    local cleanup_rc="${1:-0}" start_rc="${2:-0}" mole_version="${3:-unknown}"
    local results_file="$4" selection_file="$5"

    if [[ "$start_rc" -ne 0 ]]; then
        clean_json_emit_apply_failed "$mole_version" "scan_failed" \
            "could not start the cleanup scan; nothing was removed"
        return 0
    fi

    clean_apply_collect "$results_file" "$selection_file"

    local -a not_proposed=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && not_proposed+=("$line")
    done < <(clean_apply_not_proposed)

    local user_home
    user_home=$(get_invoking_home 2> /dev/null || true)
    [[ -n "$user_home" ]] || user_home="${HOME:-}"
    user_home="${user_home%/}"

    local -a warnings=()
    if [[ "${SYSTEM_CLEAN:-false}" != "true" && ${#not_proposed[@]} -gt 0 ]]; then
        for line in "${not_proposed[@]}"; do
            if [[ "$line" != "$user_home/"* ]]; then
                warnings+=('{"code":"sudo_unavailable","scope":"System caches","message":"System caches need sudo and were not scanned; selected system paths were left in place."}')
                break
            fi
        done
    fi
    if [[ ${#CLEAN_APPLY_TIMEOUT_WARNINGS[@]} -gt 0 ]]; then
        warnings+=("${CLEAN_APPLY_TIMEOUT_WARNINGS[@]}")
    fi
    if [[ "$CLEAN_APPLY_UNMEASURED" -gt 0 ]]; then
        warnings+=("{\"code\":\"size_unmeasured\",\"message\":\"$CLEAN_APPLY_UNMEASURED item(s) moved to the Trash could not be measured; freed_bytes is a lower bound.\"}")
    fi
    if [[ "$CLEAN_APPLY_FAILED" -gt 0 ]]; then
        warnings+=("{\"code\":\"removal_failed\",\"message\":\"$CLEAN_APPLY_FAILED selected item(s) could not be moved to the Trash.\"}")
    fi
    if [[ "$cleanup_rc" -ne 0 ]]; then
        warnings+=("{\"code\":\"scan_cancelled\",\"message\":\"The run was cancelled or timed out before completing (exit $cleanup_rc); later selected items may not have been reached.\"}")
    fi

    local scan_status="complete"
    [[ ${#warnings[@]} -gt 0 ]] && scan_status="partial"

    local warnings_json="[" first=true w
    if [[ ${#warnings[@]} -gt 0 ]]; then
        for w in "${warnings[@]}"; do
            [[ "$first" == "true" ]] || warnings_json+=","
            first=false
            warnings_json+="$w"
        done
    fi
    warnings_json+="]"

    local not_proposed_json="[" p
    first=true
    if [[ ${#not_proposed[@]} -gt 0 ]]; then
        for p in "${not_proposed[@]}"; do
            [[ "$first" == "true" ]] || not_proposed_json+=","
            first=false
            not_proposed_json+=$(history_json_string "$p")
        done
    fi
    not_proposed_json+="]"

    local categories_json="[" i
    first=true
    if [[ ${#CLEAN_APPLY_CAT_NAMES[@]} -gt 0 ]]; then
        for i in "${!CLEAN_APPLY_CAT_NAMES[@]}"; do
            [[ "$first" == "true" ]] || categories_json+=","
            first=false
            categories_json+="{\"id\":\"$(_clean_json_slug "${CLEAN_APPLY_CAT_NAMES[$i]}")\""
            categories_json+=",\"label\":$(history_json_string "${CLEAN_APPLY_CAT_NAMES[$i]}")"
            categories_json+=",\"freed_bytes\":${CLEAN_APPLY_CAT_FREED[$i]}"
            categories_json+=",\"removed_items\":${CLEAN_APPLY_CAT_REMOVED[$i]}"
            categories_json+=",\"failed_items\":${CLEAN_APPLY_CAT_FAILED[$i]}"
            categories_json+=",\"skipped_items\":${CLEAN_APPLY_CAT_SKIPPED[$i]}"
            categories_json+=",\"failures\":[${CLEAN_APPLY_CAT_FAILURES[$i]}]"
            categories_json+=",\"skipped\":[${CLEAN_APPLY_CAT_SKIPS[$i]}]}"
        done
    fi
    categories_json+="]"

    local generated_at
    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '{"schema_version":1,"mole_version":'
    history_json_string "$mole_version"
    printf ',"command":"clean","mode":"apply","generated_at":"%s","scan_status":"%s","warnings":%s,"error":null,' \
        "$generated_at" "$scan_status" "$warnings_json"
    printf '"data":{"delete_mode":"trash","freed_bytes":%s,"removed_items":%s,"failed_items":%s,"skipped_items":%s,' \
        "$CLEAN_APPLY_FREED_BYTES" "$CLEAN_APPLY_REMOVED" "$CLEAN_APPLY_FAILED" "$CLEAN_APPLY_SKIPPED"
    printf '"selection":{"requested":%s,"removed_or_partial":%s,"not_proposed":%s,"not_selected_items":%s},' \
        "${#CLEAN_APPLY_ROOTS[@]}" "$(clean_apply_removed_or_partial)" "$not_proposed_json" "$CLEAN_APPLY_NOT_SELECTED"
    printf '"categories":%s}}\n' "$categories_json"
}

# Plain-text account of the selection for a person in Terminal.
# Args: results_file, selection_file
clean_apply_print_human_summary() {
    clean_apply_collect "$1" "$2"
    local -a not_proposed=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && not_proposed+=("$line")
    done < <(clean_apply_not_proposed)

    echo -e "${PURPLE_BOLD}Selection${NC} · ${#CLEAN_APPLY_ROOTS[@]} selected, $CLEAN_APPLY_REMOVED moved to the Trash, $CLEAN_APPLY_FAILED failed, $CLEAN_APPLY_SKIPPED refused, $CLEAN_APPLY_NOT_SELECTED unselected left in place"
    if [[ ${#not_proposed[@]} -gt 0 ]]; then
        echo -e "  ${GRAY}Not found by this scan (already gone, or no longer qualifies):${NC}"
        for line in "${not_proposed[@]}"; do
            echo -e "  ${GRAY}${ICON_SUBLIST}${NC} $line"
        done
    fi
    printf '\n'
}
