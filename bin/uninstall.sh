#!/bin/bash
# Mole - Uninstall command.
# Interactive app uninstaller.
# Removes app files and leftovers.

set -euo pipefail

# Preserve user's locale for app display name lookup.
readonly MOLE_UNINSTALL_USER_LC_ALL="${LC_ALL:-}"
readonly MOLE_UNINSTALL_USER_LANG="${LANG:-}"

# Fix locale issues on non-English systems.
export LC_ALL=C
export LANG=C

# Load shared helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The repository root, captured here and never reassigned (F-044). $SCRIPT_DIR
# is this file's own bin/ directory at this point, but lib/uninstall/batch.sh —
# sourced below, not subshelled — reassigns the global $SCRIPT_DIR to the repo
# root, so any function that reads $SCRIPT_DIR after startup gets whichever
# value won last. uninstall_list_mole_version did exactly that and resolved
# "$SCRIPT_DIR/../mole" to a path outside the repository, reporting
# "mole_version":"unknown" for all three uninstall JSON modes. This variable is
# the one stable handle on the repo root; use it, not $SCRIPT_DIR, for any path
# resolved after sourcing.
MOLE_UNINSTALL_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly MOLE_UNINSTALL_REPO_ROOT
source "$SCRIPT_DIR/../lib/core/common.sh"
# history_json_escape / history_json_string back the --list --json envelope
# (CONTRACT.md §6) instead of a fourth JSON escaper — see
# lib/clean/json_emit.sh's identical note and mole/CLAUDE.md "Judge
# duplication by body, not name." Sourced here, before lib/uninstall/batch.sh
# below: that file reassigns the global $SCRIPT_DIR to the repo root (it is
# sourced, not subshelled, so the reassignment is not scoped away), so any
# "$SCRIPT_DIR/../..." source after it resolves one directory too high.
# shellcheck source=lib/core/history.sh
source "$SCRIPT_DIR/../lib/core/history.sh"

# Clean temp files on exit.
trap cleanup_temp_files EXIT INT TERM
source "$SCRIPT_DIR/../lib/ui/menu_paginated.sh"
source "$SCRIPT_DIR/../lib/ui/app_selector.sh"
source "$SCRIPT_DIR/../lib/uninstall/steam.sh"
source "$SCRIPT_DIR/../lib/uninstall/batch.sh"

# State
selected_apps=()
declare -a apps_data=()
# Index-aligned with apps_data: "real_used_epoch|app_mtime|version" per app.
# See load_applications's header comment for why this is a separate array
# rather than a widened apps_data.
declare -a apps_meta_data=()
declare -a selection_state=()
total_items=0
files_cleaned=0
total_size_cleaned=0

readonly MOLE_UNINSTALL_META_CACHE_DIR="$HOME/.cache/mole"
# v2 (M1-T4 / F-036): the cache row gained a trailing `version` column.
# Bumped rather than adding a `cached_version == ""` needs_refresh trigger,
# which would force a permanent refresh loop for apps whose plist genuinely
# has no readable CFBundleShortVersionString. Bumping instead makes every
# machine's pre-change cache a clean miss once, on this deploy, rather than
# leaving `version` silently dependent on cache warmth (F-036;
# .claude/skills/bugs archetype 8, model commit 7a996aa5).
readonly MOLE_UNINSTALL_META_CACHE_FILE="$MOLE_UNINSTALL_META_CACHE_DIR/uninstall_app_metadata_v2"
readonly MOLE_UNINSTALL_META_CACHE_LOCK="${MOLE_UNINSTALL_META_CACHE_FILE}.lock"
readonly MOLE_UNINSTALL_META_REFRESH_TTL=604800 # 7 days
readonly MOLE_UNINSTALL_EPOCH_FLOOR=978307200
# Display-name mdls lookup budget during scan; overridable for slow disks or
# cold Spotlight.
readonly MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC="${MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC:-0.04}"
readonly MOLE_UNINSTALL_INLINE_MDLS_SIZE_TIMEOUT_SEC="${MOLE_UNINSTALL_INLINE_MDLS_SIZE_TIMEOUT_SEC:-0.04}"
# Bounded inline du fallback for cold rows whose quick mdls probe missed
# (new apps are often not yet Spotlight-indexed). Only enabled when the
# cold-row count is small so a fully cold first scan keeps the fast path.
readonly MOLE_UNINSTALL_INLINE_DU_SIZE_TIMEOUT_SEC="${MOLE_UNINSTALL_INLINE_DU_SIZE_TIMEOUT_SEC:-2}"
readonly MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS="${MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS:-20}"

uninstall_normalize_size_display() {
    local size="${1:-}"
    local app_path="${2:-}"

    if [[ -n "$app_path" ]] && uninstall_app_is_steam_launcher "$app_path"; then
        echo "N/A (Steam-managed)"
        return 0
    fi

    if [[ -z "$size" || "$size" == "0" || "$size" == "Unknown" ]]; then
        echo "N/A"
        return 0
    fi
    echo "$size"
}

uninstall_normalize_last_used_display() {
    local last_used="${1:-}"
    local display
    display=$(format_last_used_summary "$last_used")
    if [[ -z "$display" || "$display" == "Never" ]]; then
        echo "Unknown"
        return 0
    fi
    echo "$display"
}

uninstall_quick_app_size_kb() {
    local app_path="$1"
    [[ -n "$app_path" && -d "$app_path" ]] || {
        echo "0"
        return 0
    }

    local physical_size
    physical_size=$(run_with_timeout "$MOLE_UNINSTALL_INLINE_MDLS_SIZE_TIMEOUT_SEC" mdls -name kMDItemPhysicalSize -raw "$app_path" 2> /dev/null || echo "")
    if [[ "$physical_size" =~ ^[0-9]+$ && "$physical_size" -gt 0 ]]; then
        echo $(((physical_size + 1023) / 1024))
        return 0
    fi

    echo "0"
}

# This bounded physical-size fallback stands in until the deferred refresh
# can query Spotlight metadata.
uninstall_inline_du_size_kb() {
    local app_path="$1"
    [[ -n "$app_path" && -d "$app_path" ]] || {
        echo "0"
        return 0
    }

    local du_size_kb
    du_size_kb=$(run_with_timeout "$MOLE_UNINSTALL_INLINE_DU_SIZE_TIMEOUT_SEC" du -skP "$app_path" 2> /dev/null | awk '{print $1; exit}') || du_size_kb=""
    if [[ "$du_size_kb" =~ ^[0-9]+$ && "$du_size_kb" -gt 0 ]]; then
        echo "$du_size_kb"
        return 0
    fi

    echo "0"
}

uninstall_resolve_display_name() {
    local app_path="$1"
    local app_name="$2"
    local display_name="$app_name"

    if [[ -f "$app_path/Contents/Info.plist" ]]; then
        local md_display_name
        if [[ -n "$MOLE_UNINSTALL_USER_LC_ALL" ]]; then
            md_display_name=$(run_with_timeout "$MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC" env LC_ALL="$MOLE_UNINSTALL_USER_LC_ALL" LANG="$MOLE_UNINSTALL_USER_LANG" mdls -name kMDItemDisplayName -raw "$app_path" 2> /dev/null || echo "")
        elif [[ -n "$MOLE_UNINSTALL_USER_LANG" ]]; then
            md_display_name=$(run_with_timeout "$MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC" env LANG="$MOLE_UNINSTALL_USER_LANG" mdls -name kMDItemDisplayName -raw "$app_path" 2> /dev/null || echo "")
        else
            md_display_name=$(run_with_timeout "$MOLE_UNINSTALL_INLINE_MDLS_DISPLAY_TIMEOUT_SEC" mdls -name kMDItemDisplayName -raw "$app_path" 2> /dev/null || echo "")
        fi

        local bundle_display_name
        bundle_display_name=$(plutil -extract CFBundleDisplayName raw "$app_path/Contents/Info.plist" 2> /dev/null || echo "")
        local bundle_name
        bundle_name=$(plutil -extract CFBundleName raw "$app_path/Contents/Info.plist" 2> /dev/null || echo "")

        if [[ "$md_display_name" == /* ]]; then
            md_display_name=""
        fi
        md_display_name="${md_display_name//|/-}"
        md_display_name="${md_display_name//[$'\t\r\n']/}"

        bundle_display_name="${bundle_display_name//|/-}"
        bundle_display_name="${bundle_display_name//[$'\t\r\n']/}"

        bundle_name="${bundle_name//|/-}"
        bundle_name="${bundle_name//[$'\t\r\n']/}"

        if [[ -n "$md_display_name" && "$md_display_name" != "(null)" && "$md_display_name" != "$app_name" ]]; then
            display_name="$md_display_name"
        elif [[ -n "$bundle_display_name" && "$bundle_display_name" != "(null)" ]]; then
            display_name="$bundle_display_name"
        elif [[ -n "$bundle_name" && "$bundle_name" != "(null)" ]]; then
            display_name="$bundle_name"
        fi
    fi

    if [[ "$display_name" == /* ]]; then
        display_name="$app_name"
    fi

    # Keep versioned bundle names when metadata collapses distinct installs.
    if [[ -n "$display_name" && "$app_name" == "$display_name"* && "$app_name" != "$display_name" ]]; then
        local suffix
        suffix="${app_name#"$display_name"}"
        if [[ "$suffix" == *[0-9]* ]]; then
            display_name="$app_name"
        fi
    fi

    display_name="${display_name%.app}"
    display_name="${display_name//|/-}"
    display_name="${display_name//[$'\t\r\n']/}"
    echo "$display_name"
}

uninstall_acquire_metadata_lock() {
    local lock_dir="$1"
    local attempts=0

    while ! mkdir "$lock_dir" 2> /dev/null; do
        ((attempts++))
        if [[ $attempts -ge 40 ]]; then
            return 1
        fi

        # Clean stale lock if older than 5 minutes.
        if [[ -d "$lock_dir" ]]; then
            local lock_mtime
            lock_mtime=$(get_file_mtime "$lock_dir")
            # Skip stale detection if mtime lookup failed (returns 0).
            if [[ "$lock_mtime" =~ ^[0-9]+$ && $lock_mtime -gt 0 ]]; then
                local lock_age
                lock_age=$(($(get_epoch_seconds) - lock_mtime))
                if [[ "$lock_age" =~ ^-?[0-9]+$ && $lock_age -gt 300 ]]; then
                    rmdir "$lock_dir" 2> /dev/null || true
                fi
            fi
        fi

        sleep 0.1 2> /dev/null || sleep 1
    done

    return 0
}

uninstall_release_metadata_lock() {
    local lock_dir="$1"
    [[ -d "$lock_dir" ]] && rmdir "$lock_dir" 2> /dev/null || true
}

# Atomically replace the metadata cache file, healing stale root-owned copies.
# stdin is closed so BSD mv/cp never blocks prompting on a non-writable target.
uninstall_persist_cache_file() {
    local src="$1"
    local dst="$2"

    [[ -s "$src" ]] || {
        rm -f "$src" 2> /dev/null || true
        return 0
    }

    # Heal stale file the user cannot write to (e.g. root-owned from a prior
    # sudo run). The parent dir is user-owned, so rm succeeds regardless.
    if [[ -e "$dst" && ! -w "$dst" ]]; then
        rm -f "$dst" 2> /dev/null || true
    fi

    # shellcheck disable=SC2217 # BSD mv/cp read stdin when prompting; close it to avoid hang.
    mv -f "$src" "$dst" < /dev/null 2> /dev/null || {
        # shellcheck disable=SC2217
        cp -f "$src" "$dst" < /dev/null 2> /dev/null || true
        rm -f "$src" 2> /dev/null || true
    }
}

start_uninstall_metadata_refresh() {
    local refresh_file="$1"
    [[ ! -s "$refresh_file" ]] && {
        rm -f "$refresh_file" 2> /dev/null || true
        return 0
    }

    (
        _refresh_debug() {
            if [[ "${MO_DEBUG:-}" == "1" ]]; then
                local ts
                ts=$(date "+%Y-%m-%d %H:%M:%S" 2> /dev/null || echo "?")
                echo "[$ts] DEBUG: [metadata-refresh] $*" >> "${HOME}/.config/mole/mole_debug_session.log" 2> /dev/null || true
            fi
        }

        ensure_user_dir "$MOLE_UNINSTALL_META_CACHE_DIR"
        ensure_user_file "$MOLE_UNINSTALL_META_CACHE_FILE"
        if [[ ! -r "$MOLE_UNINSTALL_META_CACHE_FILE" ]]; then
            if ! : > "$MOLE_UNINSTALL_META_CACHE_FILE" 2> /dev/null; then
                _refresh_debug "Cannot create cache file, aborting"
                exit 0
            fi
        fi
        if [[ ! -w "$MOLE_UNINSTALL_META_CACHE_FILE" ]]; then
            _refresh_debug "Cache file not writable, aborting"
            exit 0
        fi

        local updates_file
        updates_file=$(mktemp 2> /dev/null) || {
            _refresh_debug "mktemp failed, aborting"
            exit 0
        }
        local now_epoch
        now_epoch=$(get_epoch_seconds)
        local max_parallel
        max_parallel=$(get_optimal_parallel_jobs "io")
        if [[ ! "$max_parallel" =~ ^[0-9]+$ || $max_parallel -lt 1 ]]; then
            max_parallel=1
        elif [[ $max_parallel -gt 4 ]]; then
            max_parallel=4
        fi
        local -a worker_pids=()
        local worker_idx=0

        while IFS='|' read -r app_path app_mtime bundle_id display_name; do
            [[ -n "$app_path" && -d "$app_path" ]] || continue
            ((worker_idx++))
            local worker_output="${updates_file}.${worker_idx}"

            # stdin from /dev/null: these workers never read the terminal, and a
            # background job that keeps the tty on stdin lets its timeout helpers
            # take the terminal away from the foreground prompt (#1222).
            (
                local last_used_epoch=0
                local metadata_date
                metadata_date=$(run_with_timeout 0.2 mdls -name kMDItemLastUsedDate -raw "$app_path" 2> /dev/null || echo "") # 0.2s: per-app probe in tight scan loop, see lib/core/timeouts.sh
                if [[ "$metadata_date" != "(null)" && -n "$metadata_date" ]]; then
                    last_used_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$metadata_date" "+%s" 2> /dev/null || echo "0")
                fi

                if [[ ! "$last_used_epoch" =~ ^[0-9]+$ || $last_used_epoch -le 0 || $last_used_epoch -lt $MOLE_UNINSTALL_EPOCH_FLOOR ]]; then
                    last_used_epoch=0
                fi

                local size_kb
                size_kb=$(get_path_size_kb "$app_path")
                [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

                # This refresh cycle replaces the whole cache row (see the
                # merge below), so version must be re-read here too — a
                # worker that skipped it would silently drop `version` back
                # to absent on every 7-day refresh.
                local version
                version=$(uninstall_read_bundle_version "$app_path")

                printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "$app_path" "${app_mtime:-0}" "$size_kb" "${last_used_epoch:-0}" "$now_epoch" "$bundle_id" "$display_name" "$version" > "$worker_output"
            ) < /dev/null &
            worker_pids+=($!)

            if ((${#worker_pids[@]} >= max_parallel)); then
                wait "${worker_pids[0]}" 2> /dev/null || true
                worker_pids=("${worker_pids[@]:1}")
            fi
        done < "$refresh_file"

        local worker_pid
        for worker_pid in "${worker_pids[@]}"; do
            wait "$worker_pid" 2> /dev/null || true
        done

        local worker_output
        for worker_output in "${updates_file}".*; do
            [[ -f "$worker_output" ]] || continue
            cat "$worker_output" >> "$updates_file"
            rm -f "$worker_output"
        done

        if [[ ! -s "$updates_file" ]]; then
            rm -f "$updates_file"
            exit 0
        fi

        if ! uninstall_acquire_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"; then
            _refresh_debug "Failed to acquire lock, aborting merge"
            rm -f "$updates_file"
            exit 0
        fi

        local refresh_merged_file
        refresh_merged_file=$(mktemp 2> /dev/null) || {
            _refresh_debug "mktemp for merge failed, aborting"
            uninstall_release_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"
            rm -f "$updates_file"
            exit 0
        }

        awk -F'|' '
            NR == FNR { updates[$1] = $0; next }
            !($1 in updates) { print }
            END {
                for (path in updates) {
                    print updates[path]
                }
            }
        ' "$updates_file" "$MOLE_UNINSTALL_META_CACHE_FILE" > "$refresh_merged_file"

        uninstall_persist_cache_file "$refresh_merged_file" "$MOLE_UNINSTALL_META_CACHE_FILE"

        uninstall_release_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"
        rm -f "$updates_file" "$refresh_merged_file"
        rm -f "$refresh_file" 2> /dev/null || true
        # Redirect stdin from /dev/null so the perl timeout fallback does not see
        # a tty on stdin and hand the controlling terminal to its timed child.
        # This background refresh (and its nested workers, which inherit this
        # stdin) never needs the terminal; leaving stdin as the tty lets a worker
        # steal the foreground process group and stop the foreground prompt with
        # SIGTTIN (issue #1222). The interactive sudo handoff (#1201) is on
        # non-background call sites and is unaffected.
    ) > /dev/null 2>&1 < /dev/null &
    disown "$!" 2> /dev/null || true

}

uninstall_print_app_search_dirs() {
    local -a app_dirs=(
        "/Applications"
        "$HOME/Applications"
        "/Library/Input Methods"
        "$HOME/Library/Input Methods"
    )

    local vol_app_dir
    local nullglob_was_set=0
    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    for vol_app_dir in /Volumes/*/Applications; do
        [[ -d "$vol_app_dir" && -r "$vol_app_dir" ]] || continue
        if [[ -d "/Applications" && "$vol_app_dir" -ef "/Applications" ]]; then
            continue
        fi
        if [[ -d "$HOME/Applications" && "$vol_app_dir" -ef "$HOME/Applications" ]]; then
            continue
        fi
        app_dirs+=("$vol_app_dir")
    done
    if [[ $nullglob_was_set -eq 0 ]]; then
        shopt -u nullglob
    fi

    printf '%s\n' "${app_dirs[@]}"
}

uninstall_should_skip_app_path() {
    local app_path="$1"

    [[ -e "$app_path" ]] || return 0

    # Skip nested apps inside another .app bundle.
    local parent_dir="${app_path%/*}"
    if [[ "$parent_dir" == *".app" || "$parent_dir" == *".app/"* ]]; then
        return 0
    fi

    if [[ -L "$app_path" ]]; then
        local link_target
        link_target=$(readlink "$app_path" 2> /dev/null)
        if [[ -n "$link_target" ]]; then
            local resolved_target="$link_target"
            if [[ "$link_target" != /* ]]; then
                local link_dir="${app_path%/*}"
                local _link_parent="${link_target%/*}"
                [[ "$_link_parent" == "$link_target" ]] && _link_parent="."
                resolved_target=$(cd "$link_dir" 2> /dev/null && cd "$_link_parent" 2> /dev/null && pwd)/"${link_target##*/}" 2> /dev/null || echo ""
            fi
            case "$resolved_target" in
                /System/* | /usr/bin/* | /usr/lib/* | /bin/* | /sbin/* | /private/etc/*)
                    return 0
                    ;;
            esac
        fi
    fi

    return 1
}

uninstall_resolve_bundle_id() {
    local app_path="$1"
    local fallback_bundle_id="${2:-}"
    local bundle_id=""
    local plist="$app_path/Contents/Info.plist"

    fallback_bundle_id="${fallback_bundle_id//|/-}"
    fallback_bundle_id="${fallback_bundle_id//[$'\t\r\n']/}"

    if [[ -f "$plist" ]]; then
        bundle_id=$(plutil -extract CFBundleIdentifier raw "$plist" 2> /dev/null || echo "")
        bundle_id="${bundle_id//|/-}"
        bundle_id="${bundle_id//[$'\t\r\n']/}"
    fi

    if [[ -n "$bundle_id" && "$bundle_id" != "(null)" ]]; then
        printf '%s\n' "$bundle_id"
        return 0
    fi

    if [[ -n "$fallback_bundle_id" && "$fallback_bundle_id" != "(null)" ]]; then
        printf '%s\n' "$fallback_bundle_id"
        return 0
    fi

    printf '%s\n' "unknown"
}

# Read CFBundleShortVersionString from Info.plist. Same shape as
# uninstall_resolve_bundle_id: a plutil read of a file already on disk, no
# mdls/du timeout budget needed. Prints nothing (not even a newline) when
# unreadable — CONTRACT.md §6.4 marks `version` C, absent when unreadable.
uninstall_read_bundle_version() {
    local app_path="$1"
    local plist="$app_path/Contents/Info.plist"
    local version=""

    if [[ -f "$plist" ]]; then
        version=$(plutil -extract CFBundleShortVersionString raw "$plist" 2> /dev/null || echo "")
    fi
    version="${version//|/-}"
    version="${version//[$'\t\r\n']/}"
    [[ "$version" != "(null)" ]] || version=""

    printf '%s' "$version"
}

uninstall_app_is_background_only() {
    local app_path="$1"
    local plist="$app_path/Contents/Info.plist"
    [[ -f "$plist" ]] || return 1

    local bg_only
    bg_only=$(plutil -extract LSBackgroundOnly raw "$plist" 2> /dev/null || echo "")
    case "$bg_only" in
        1 | YES | yes | TRUE | true)
            return 0
            ;;
    esac

    return 1
}

uninstall_app_is_directly_in_search_root() {
    local app_path="$1"
    local app_parent="${app_path%/*}"
    local app_dir

    while IFS= read -r app_dir; do
        [[ -n "$app_dir" ]] || continue
        if [[ "$app_parent" == "$app_dir" ]]; then
            return 0
        fi
    done < <(uninstall_print_app_search_dirs)

    return 1
}

uninstall_app_is_currently_eligible() {
    local app_path="$1"
    local bundle_id="${2:-}"

    [[ -n "$app_path" && -e "$app_path" ]] || return 1

    if [[ -n "$bundle_id" && "$bundle_id" != "unknown" ]] && should_protect_from_uninstall "$bundle_id"; then
        return 1
    fi

    if uninstall_app_is_background_only "$app_path" && ! uninstall_app_is_directly_in_search_root "$app_path"; then
        return 1
    fi

    return 0
}

uninstall_resolve_eligible_bundle_id() {
    local app_path="$1"
    local fallback_bundle_id="${2:-}"
    local bundle_id

    bundle_id=$(uninstall_resolve_bundle_id "$app_path" "$fallback_bundle_id")
    uninstall_app_is_currently_eligible "$app_path" "$bundle_id" || return 1
    printf '%s\n' "$bundle_id"
}

uninstall_print_app_paths_with_mtime() {
    local app_dir="$1"
    local app_path app_mtime

    [[ -d "$app_dir" ]] || return 0

    while IFS= read -r -d '' app_path; do
        [[ -n "$app_path" ]] || continue
        app_mtime=$(get_file_mtime "$app_path")
        printf '%s\t%s\n' "${app_mtime:-0}" "$app_path"
    done < <(command find "$app_dir" -maxdepth 3 -name "*.app" -print0 2> /dev/null)
}

uninstall_app_inventory_fingerprint() {
    local app_dir app_path app_mtime info_mtime pkg_app_path

    {
        while IFS= read -r pkg_app_path; do
            [[ -n "$pkg_app_path" && -d "$pkg_app_path" ]] || continue
            app_mtime=$(get_file_mtime "$pkg_app_path")
            info_mtime=$(get_file_mtime "$pkg_app_path/Contents/Info.plist")
            printf '%s|%s|%s\n' "$pkg_app_path" "${app_mtime:-0}" "${info_mtime:-0}"
        done < <(pkg_receipt_nonstandard_app_paths)

        while IFS= read -r app_dir; do
            [[ -d "$app_dir" ]] || continue
            while IFS=$'\t' read -r app_mtime app_path; do
                [[ -n "$app_path" ]] || continue
                uninstall_should_skip_app_path "$app_path" && continue
                info_mtime=$(get_file_mtime "$app_path/Contents/Info.plist")
                printf '%s|%s|%s\n' "$app_path" "${app_mtime:-0}" "${info_mtime:-0}"
            done < <(uninstall_print_app_paths_with_mtime "$app_dir")
        done < <(uninstall_print_app_search_dirs)
    } | LC_ALL=C sort -u
}

# The in-session app index remains valid when the live inventory only loses
# rows. load_applications rechecks path existence before displaying each row.
# New rows and changed mtimes must rebuild the index so protection and bundle
# metadata are evaluated again.
uninstall_inventory_can_reuse_cached_apps() {
    local cached_inventory="$1"
    local current_inventory="$2"
    local additions=""
    local removals=""

    [[ -n "$cached_inventory" && -n "$current_inventory" ]] || return 1
    additions=$(LC_ALL=C comm -13 \
        <(printf '%s\n' "$cached_inventory") \
        <(printf '%s\n' "$current_inventory")) || return 1
    [[ -z "$additions" ]] || return 1

    removals=$(LC_ALL=C comm -23 \
        <(printf '%s\n' "$cached_inventory") \
        <(printf '%s\n' "$current_inventory")) || return 1
    local removed_row removed_path
    while IFS= read -r removed_row; do
        [[ -n "$removed_row" ]] || continue
        removed_path="${removed_row%|*}"
        removed_path="${removed_path%|*}"
        [[ ! -e "$removed_path" ]] || return 1
    done <<< "$removals"
    return 0
}

# Internal helpers for scan_applications. They read and write locals
# declared in the orchestrator's scope via bash dynamic scoping; do not
# call them outside scan_applications.

# Phase 2 (Pass 1): discover candidate .app paths by combining the
# configured app search directories with pkg-receipt non-standard install
# locations, skipping bundles flagged by uninstall_should_skip_app_path.
# Each row in discovered_file is encoded as <app_path>|<app_name>|<app_mtime>.
# Writes: discovered_file
_scan_discover_apps() {
    local -a app_dirs=()
    local app_dir
    while IFS= read -r app_dir; do
        [[ -n "$app_dir" ]] && app_dirs+=("$app_dir")
    done < <(uninstall_print_app_search_dirs)

    # Scan for pkg-installed apps in non-standard locations.
    local pkg_app_path
    while IFS= read -r pkg_app_path; do
        [[ -n "$pkg_app_path" ]] || continue

        local already_scanned=false
        for app_dir in "${app_dirs[@]}"; do
            if [[ "$pkg_app_path" == "$app_dir"/*.app ]]; then
                already_scanned=true
                break
            fi
        done
        [[ "$already_scanned" == true ]] && continue

        local app_name="${pkg_app_path##*/}"
        app_name="${app_name%.app}"

        local app_mtime
        app_mtime=$(get_file_mtime "$pkg_app_path")

        printf "%s|%s|%s\n" "$pkg_app_path" "$app_name" "${app_mtime:-0}" >> "$discovered_file"
    done < <(pkg_receipt_nonstandard_app_paths)

    for app_dir in "${app_dirs[@]}"; do
        if [[ ! -d "$app_dir" ]]; then continue; fi

        while IFS=$'\t' read -r app_mtime app_path; do
            if [[ ! -e "$app_path" ]]; then continue; fi

            local app_name="${app_path##*/}"
            app_name="${app_name%.app}"

            uninstall_should_skip_app_path "$app_path" && continue

            printf "%s|%s|%s\n" "$app_path" "$app_name" "${app_mtime:-0}" >> "$discovered_file"
        done < <(uninstall_print_app_paths_with_mtime "$app_dir")
    done
}

# Phase 3: partition discovered apps into warm-cache rows (written
# directly to scan_raw_file) and cold rows (queued in app_data_tuples
# for parallel metadata resolution in _scan_resolve_uncached).
# Reads:  cache_source, discovered_file
# Writes: cached_rows_file, uncached_rows_file, scan_raw_file (via the
#         nested use_cached_scan_metadata helper), app_data_tuples
_scan_partition_cache() {
    use_cached_scan_metadata() {
        local cached_app_path="$1"
        local cached_app_mtime="$2"
        local cached_bundle_id="$3"
        local cached_display_name="$4"
        local cached_size_kb="$5"
        local cached_version="${6:-}"

        [[ -n "$cached_bundle_id" && -n "$cached_display_name" ]] || return 1
        [[ "$cached_size_kb" =~ ^[0-9]+$ && "$cached_size_kb" -gt 0 ]] || return 1

        cached_bundle_id=$(uninstall_resolve_eligible_bundle_id "$cached_app_path" "$cached_bundle_id") || return 1

        printf "%s|%s|%s|%s|%s|%s\n" "$cached_app_path" "$cached_display_name" "$cached_bundle_id" "$cached_app_mtime" "$cached_size_kb" "$cached_version" >> "$scan_raw_file"
        return 0
    }

    if [[ -s "$discovered_file" ]]; then
        awk -F'|' -v cached_out="$cached_rows_file" -v uncached_out="$uncached_rows_file" '
            FILENAME == ARGV[1] {
                cache_mtime[$1] = $2
                cache_size[$1] = $3
                cache_bundle[$1] = $6
                cache_display[$1] = $7
                cache_version[$1] = $8
                next
            }
            {
                path = $1
                app_mtime = $3
                if (cache_mtime[path] == app_mtime && cache_display[path] != "" && cache_size[path] ~ /^[0-9]+$/ && cache_size[path] > 0) {
                    cached_bundle = cache_bundle[path] == "" ? "unknown" : cache_bundle[path]
                    print path "|" app_mtime "|" cached_bundle "|" cache_display[path] "|" cache_size[path] "|" cache_version[path] >> cached_out
                } else {
                    print path "|" $2 "|" app_mtime "|" cache_bundle[path] "|" cache_display[path] >> uncached_out
                }
            }
        ' "$cache_source" "$discovered_file"

        local cached_app_path cached_app_mtime cached_bundle_id cached_display_name cached_size_kb cached_version
        while IFS='|' read -r cached_app_path cached_app_mtime cached_bundle_id cached_display_name cached_size_kb cached_version; do
            use_cached_scan_metadata "$cached_app_path" "$cached_app_mtime" "$cached_bundle_id" "$cached_display_name" "$cached_size_kb" "$cached_version" || true
        done < "$cached_rows_file"

        local uncached_app_path uncached_app_name uncached_app_mtime uncached_bundle_id uncached_display_name
        while IFS='|' read -r uncached_app_path uncached_app_name uncached_app_mtime uncached_bundle_id uncached_display_name; do
            app_data_tuples+=("${uncached_app_path}|${uncached_app_name}|${uncached_app_mtime}|${uncached_bundle_id}|${uncached_display_name}")
        done < "$uncached_rows_file"
    fi
}

# Phase 5 (Pass 2): resolve display names and bundle IDs in parallel for
# the cold rows queued by _scan_partition_cache. Spawns the progress
# spinner subprocess (assigns spinner_pid), fans out workers up to
# max_parallel, and waits for completion.
# Reads:  app_data_tuples
# Writes: scan_raw_file (appended by worker subshells)
_scan_resolve_uncached() {
    local app_count=0
    local total_apps=${#app_data_tuples[@]}
    # Cold rows are usually the handful of newly installed or updated apps;
    # give those a bounded du when the quick mdls probe misses so the size
    # shows on first paint. A fully cold cache (first run) exceeds the cap
    # and keeps the fast path; the deferred refresh still fills the cache.
    local inline_du_fallback=0
    if [[ "$MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS" =~ ^[0-9]+$ ]] &&
        ((total_apps > 0 && total_apps <= MOLE_UNINSTALL_INLINE_DU_MAX_COLD_ROWS)); then
        inline_du_fallback=1
    fi
    local max_parallel
    max_parallel=$(get_optimal_parallel_jobs "io")
    if [[ $max_parallel -lt 8 ]]; then
        max_parallel=8 # At least 8 for good performance
    elif [[ $max_parallel -gt 32 ]]; then
        max_parallel=32 # Cap at 32 to avoid too many processes
    fi
    local pids=()

    process_app_metadata() {
        local app_data_tuple="$1"
        local output_file="$2"

        IFS='|' read -r app_path app_name app_mtime cached_bundle_id cached_display_name <<< "$app_data_tuple"

        local bundle_id
        bundle_id=$(uninstall_resolve_eligible_bundle_id "$app_path" "${cached_bundle_id:-}") || return 0

        local display_name="${cached_display_name:-}"
        if [[ -z "$display_name" ]]; then
            display_name=$(uninstall_resolve_display_name "$app_path" "$app_name")
        fi

        display_name="${display_name%.app}"
        display_name="${display_name//|/-}"
        display_name="${display_name//[$'\t\r\n']/}"

        local quick_size_kb
        quick_size_kb=$(uninstall_quick_app_size_kb "$app_path")
        [[ "$quick_size_kb" =~ ^[0-9]+$ ]] || quick_size_kb=0

        if [[ "$quick_size_kb" -eq 0 && "${inline_du_fallback:-0}" == "1" ]]; then
            quick_size_kb=$(uninstall_inline_du_size_kb "$app_path")
            [[ "$quick_size_kb" =~ ^[0-9]+$ ]] || quick_size_kb=0
        fi

        # Read in this worker, not in a serial emitter loop: a plist read per
        # app must not land on the critical path of a command with a latency
        # budget (F-035 / docs/handoff-M1-T4.md).
        local version
        version=$(uninstall_read_bundle_version "$app_path")

        echo "${app_path}|${display_name}|${bundle_id}|${app_mtime}|${quick_size_kb}|${version}" >> "$output_file"
    }

    update_scan_status "Scanning applications..." "0" "$total_apps"

    # Skip Pass 2 when the warm cache already wrote every row to $scan_raw_file.
    # Also avoids expanding an empty array; macOS bash 3.2 (the /bin/bash that
    # this script targets) treats `"${empty[@]}"` as unbound under `set -u`.
    if ((total_apps > 0)); then
        for app_data_tuple in "${app_data_tuples[@]}"; do
            ((app_count++))
            # Redirect stdin from /dev/null so the perl timeout fallback used by
            # process_app_metadata does not hand the controlling terminal to its
            # timed mdls/du child from this background worker (issue #1222).
            process_app_metadata "$app_data_tuple" "$scan_raw_file" < /dev/null &
            pids+=($!)
            update_scan_status "Scanning applications..." "$app_count" "$total_apps"

            if ((${#pids[@]} >= max_parallel)); then
                wait "${pids[0]}" 2> /dev/null
                pids=("${pids[@]:1}")
            fi
        done

        for pid in "${pids[@]}"; do
            wait "$pid" 2> /dev/null
        done
    fi
}

# Phase 6: collapse duplicate bundle IDs discovered from backup volumes or
# mirrored Applications folders. Keep the live app locations first.
# The dedupe key includes the .app basename so distinct installs that share a
# bundle ID (e.g. Xcode.app and Xcode-beta.app, both com.apple.dt.Xcode) are
# kept, while true clones of the same bundle name in mirrored roots collapse.
_scan_dedupe_bundle_ids() {
    [[ -s "$scan_raw_file" ]] || return 0

    local deduped_file="${scan_raw_file}.deduped"
    if ! awk -F'|' -v home_apps="$HOME/Applications/" '
        function starts_with(value, prefix) {
            return prefix != "" && substr(value, 1, length(prefix)) == prefix
        }
        function direct_app_under(path, prefix, rest) {
            if (!starts_with(path, prefix)) {
                return 0
            }
            rest = substr(path, length(prefix) + 1)
            return index(rest, "/") == 0 && rest ~ /[.]app$/
        }
        function path_rank(path) {
            if (direct_app_under(path, "/Applications/")) {
                return 1
            }
            if (direct_app_under(path, home_apps)) {
                return 2
            }
            if (starts_with(path, "/Volumes/")) {
                return 4
            }
            return 3
        }
        function app_basename(path, n, parts) {
            n = split(path, parts, "/")
            return parts[n]
        }
        {
            bundle_id = $3
            if (bundle_id == "" || bundle_id == "unknown") {
                key = "__path__" NR
                rows[key] = $0
                order[++count] = key
                next
            }

            key = bundle_id "|" app_basename($1)
            rank = path_rank($1)
            if (!(key in rows)) {
                rows[key] = $0
                ranks[key] = rank
                order[++count] = key
                next
            }
            if (rank < ranks[key]) {
                rows[key] = $0
                ranks[key] = rank
            }
        }
        END {
            for (i = 1; i <= count; i++) {
                key = order[i]
                if (key in rows) {
                    print rows[key]
                }
            }
        }
    ' "$scan_raw_file" > "$deduped_file"; then
        rm -f "$deduped_file" 2> /dev/null || true
        return 0
    fi

    if ! mv "$deduped_file" "$scan_raw_file" 2> /dev/null; then
        rm -f "$deduped_file" 2> /dev/null || true
    fi
}

# Phase 7+8: merge scan_raw_file with the persistent metadata cache,
# compute display size / last-used / refresh-needed flags via the embedded awk
# pipeline, persist the cache snapshot under a lock, sort the result by epoch,
# kick off the deferred background refresh, and echo the sorted index path for
# the caller to capture.
# Reads:  scan_raw_file, cache_source
# Writes: merged_file, refresh_file, cache_snapshot_file, temp_file,
#         ${temp_file}.sorted, MOLE_UNINSTALL_META_CACHE_FILE
# Returns: 0 on success (sorted path is echoed on stdout), 1 if sort
#          fails or the sorted file did not materialize.
_scan_finalize_index() {
    update_scan_status "Merging cache data..." "0" "0"
    awk -F'|' '
        NR == FNR {
            cache_mtime[$1] = $2
            cache_size[$1] = $3
            cache_epoch[$1] = $4
            cache_updated[$1] = $5
            cache_bundle[$1] = $6
            cache_display[$1] = $7
            cache_version[$1] = $8
            next
        }
        {
            print $0 "|" cache_mtime[$1] "|" cache_size[$1] "|" cache_epoch[$1] "|" cache_updated[$1] "|" cache_bundle[$1] "|" cache_display[$1] "|" cache_version[$1]
        }
    ' "$cache_source" "$scan_raw_file" > "$merged_file"
    if [[ ! -s "$merged_file" && -s "$scan_raw_file" ]]; then
        awk '{print $0 "|||||||"}' "$scan_raw_file" > "$merged_file"
    fi

    local current_epoch
    current_epoch=$(get_epoch_seconds)
    local metadata_total=0
    metadata_total=$(wc -l < "$merged_file" 2> /dev/null || echo "0")
    [[ "$metadata_total" =~ ^[0-9]+$ ]] || metadata_total=0
    update_scan_status "Collecting metadata..." "0" "$metadata_total"

    awk -F'|' \
        -v now="$current_epoch" \
        -v floor="$MOLE_UNINSTALL_EPOCH_FLOOR" \
        -v ttl="$MOLE_UNINSTALL_META_REFRESH_TTL" \
        -v refresh_out="$refresh_file" \
        -v snapshot_out="$cache_snapshot_file" \
        -v apps_out="$temp_file" '
            function isnum(value) {
                return value ~ /^[0-9]+$/
            }
            function human_size(kb, bytes, scaled) {
                if (!isnum(kb) || kb <= 0) {
                    return "--"
                }
                bytes = kb * 1024
                if (bytes >= 1000000000) {
                    scaled = int((bytes * 100 + 500000000) / 1000000000)
                    return sprintf("%d.%02dGB", int(scaled / 100), scaled % 100)
                }
                if (bytes >= 1000000) {
                    scaled = int((bytes * 10 + 500000) / 1000000)
                    return sprintf("%d.%01dMB", int(scaled / 10), scaled % 10)
                }
                if (bytes >= 1000) {
                    return sprintf("%dKB", int((bytes + 500) / 1000))
                }
                return sprintf("%dB", bytes)
            }
            function relative_time(epoch, now_epoch, days_ago, weeks_ago, months_ago, years_ago) {
                if (!isnum(epoch) || epoch <= 0 || epoch < floor) {
                    return "Unknown"
                }
                days_ago = int((now_epoch - epoch) / 86400)
                if (days_ago < 0) {
                    days_ago = 0
                }
                if (days_ago == 0) {
                    return "Today"
                }
                if (days_ago == 1) {
                    return "Yesterday"
                }
                if (days_ago < 7) {
                    return days_ago " days ago"
                }
                if (days_ago < 30) {
                    weeks_ago = int(days_ago / 7)
                    return weeks_ago == 1 ? "1 week ago" : weeks_ago " weeks ago"
                }
                if (days_ago < 365) {
                    months_ago = int(days_ago / 30)
                    return months_ago == 1 ? "1 month ago" : months_ago " months ago"
                }
                years_ago = int(days_ago / 365)
                return years_ago == 1 ? "1 year ago" : years_ago " years ago"
            }
            {
                app_path = $1
                display_name = $2
                bundle_id = $3
                app_mtime = $4
                if (NF >= 13) {
                    inline_size_kb = $5
                    inline_version = $6
                    cached_mtime = $7
                    cached_size_kb = $8
                    cached_epoch = $9
                    cached_updated_epoch = $10
                    cached_bundle_id = $11
                    cached_display_name = $12
                    cached_version = $13
                } else {
                    inline_size_kb = 0
                    inline_version = ""
                    cached_mtime = $5
                    cached_size_kb = $6
                    cached_epoch = $7
                    cached_updated_epoch = $8
                    cached_bundle_id = $9
                    cached_display_name = $10
                    cached_version = (NF >= 11) ? $11 : ""
                }

                cache_match = (cached_mtime != "" && app_mtime != "" && cached_mtime == app_mtime)

                # real_used_epoch is the true "macOS has a use record" fact --
                # cached_epoch, floor-filtered, before the mtime fallback
                # below is ever applied. final_epoch keeps its historic
                # meaning (real epoch OR mtime fallback) because it drives
                # the terminal table relative_time() call and the sort key;
                # the JSON emitter reads real_used_epoch separately so it
                # never relabels a modification time as a last-used date
                # (F-035).
                real_used_epoch = (isnum(cached_epoch) && cached_epoch > 0) ? cached_epoch : 0
                if (isnum(real_used_epoch) && real_used_epoch < floor) {
                    real_used_epoch = 0
                }
                final_epoch = real_used_epoch
                if ((!isnum(final_epoch) || final_epoch <= 0) && isnum(app_mtime) && app_mtime > floor) {
                    final_epoch = app_mtime
                }

                final_version = (inline_version != "") ? inline_version : cached_version

                final_size_kb = (isnum(cached_size_kb) && cached_size_kb > 0) ? cached_size_kb : 0
                if ((!isnum(final_size_kb) || final_size_kb <= 0) && isnum(inline_size_kb) && inline_size_kb > 0) {
                    final_size_kb = inline_size_kb
                }
                final_size = human_size(final_size_kb)
                final_last_used = relative_time(final_epoch, now)

                needs_refresh = 0
                if (!cache_match) {
                    needs_refresh = 1
                } else if (!isnum(cached_size_kb) || cached_size_kb <= 0) {
                    needs_refresh = 1
                } else if (!isnum(cached_epoch) || cached_epoch <= 0) {
                    needs_refresh = 1
                } else if (!isnum(cached_updated_epoch)) {
                    needs_refresh = 1
                } else if (cached_bundle_id == "" || cached_display_name == "") {
                    needs_refresh = 1
                } else if ((now - cached_updated_epoch) > ttl) {
                    needs_refresh = 1
                }

                if (needs_refresh) {
                    print app_path "|" app_mtime "|" bundle_id "|" display_name >> refresh_out
                }

                persist_updated_epoch = (isnum(cached_updated_epoch) && cached_updated_epoch > 0) ? cached_updated_epoch : 0
                print app_path "|" app_mtime "|" final_size_kb "|" final_epoch "|" persist_updated_epoch "|" bundle_id "|" display_name "|" final_version >> snapshot_out
                # apps_out gains real_used_epoch, app_mtime and final_version as
                # trailing fields for the JSON emitter (CONTRACT.md §6.4). This
                # is a private intermediate format, not the public contract, so
                # widening it is safe (F-035 / docs/handoff-M1-T4.md); the first
                # 7 fields are unchanged and still drive the terminal table.
                print final_epoch "|" app_path "|" display_name "|" bundle_id "|" final_size "|" final_last_used "|" final_size_kb "|" real_used_epoch "|" app_mtime "|" final_version >> apps_out
            }
        ' "$merged_file"

    update_scan_status "Updating cache..." "0" "0"
    if [[ -s "$cache_snapshot_file" ]]; then
        if uninstall_acquire_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"; then
            uninstall_persist_cache_file "$cache_snapshot_file" "$MOLE_UNINSTALL_META_CACHE_FILE"
            uninstall_release_metadata_lock "$MOLE_UNINSTALL_META_CACHE_LOCK"
        fi
    fi

    update_scan_status "Sorting application list..." "0" "0"
    sort -t'|' -k1,1n "$temp_file" > "${temp_file}.sorted" || {
        stop_scan_spinner
        rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file"
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        return 1
    }
    rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file"
    [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true

    update_scan_status "Finalizing list..." "0" "0"
    start_uninstall_metadata_refresh "$refresh_file"
    stop_scan_spinner

    if [[ -f "${temp_file}.sorted" ]]; then
        register_temp_file "${temp_file}.sorted"
        restore_scan_int_trap
        echo "${temp_file}.sorted"
        return 0
    else
        restore_scan_int_trap
        return 1
    fi
}

# Scan applications and collect information. Orchestrates the four
# phases (discover, partition, resolve, finalize) and owns the shared
# temp files, spinner subprocess, INT trap, and metadata cache lock.
scan_applications() {
    local temp_file scan_raw_file merged_file refresh_file cache_snapshot_file discovered_file cached_rows_file uncached_rows_file
    temp_file=$(create_temp_file)
    scan_raw_file="${temp_file}.scan"
    merged_file="${temp_file}.merged"
    refresh_file="${temp_file}.refresh"
    cache_snapshot_file="${temp_file}.cache"
    discovered_file="${temp_file}.discovered"
    cached_rows_file="${temp_file}.cached_rows"
    uncached_rows_file="${temp_file}.uncached_rows"
    local scan_status_file="${temp_file}.scan_status"
    : > "$scan_raw_file"
    : > "$refresh_file"
    : > "$cache_snapshot_file"
    : > "$discovered_file"
    : > "$cached_rows_file"
    : > "$uncached_rows_file"
    : > "$scan_status_file"

    ensure_user_dir "$MOLE_UNINSTALL_META_CACHE_DIR"
    ensure_user_file "$MOLE_UNINSTALL_META_CACHE_FILE"
    local cache_source="$MOLE_UNINSTALL_META_CACHE_FILE"
    local cache_source_is_temp=false
    if [[ ! -r "$cache_source" ]]; then
        cache_source=$(create_temp_file)
        : > "$cache_source"
        cache_source_is_temp=true
    fi

    # Local spinner_pid for cleanup
    local spinner_pid=""
    local spinner_shown_file="${temp_file}.spinner_shown"
    local previous_int_trap=""
    previous_int_trap=$(trap -p INT || true)

    restore_scan_int_trap() {
        if [[ -n "$previous_int_trap" ]]; then
            # eval: restore previous trap captured by $(trap -p INT)
            eval "$previous_int_trap"
        else
            trap - INT
        fi
    }

    # Trap to handle Ctrl+C during scan
    # shellcheck disable=SC2329  # Function invoked indirectly via trap
    trap_scan_cleanup() {
        if [[ -n "$spinner_pid" ]]; then
            kill -TERM "$spinner_pid" 2> /dev/null || true
            wait "$spinner_pid" 2> /dev/null || true
        fi
        if [[ -f "$spinner_shown_file" ]]; then
            printf "\r\033[K" >&2
        fi
        rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file" "$scan_status_file" "${temp_file}.sorted" "$spinner_shown_file" 2> /dev/null || true
        exit 130
    }
    trap trap_scan_cleanup INT

    update_scan_status() {
        local message="$1"
        local completed="${2:-0}"
        local total="${3:-0}"
        printf "%s|%s|%s\n" "$message" "$completed" "$total" > "$scan_status_file"
    }

    start_scan_spinner() {
        [[ -n "$spinner_pid" ]] && return 0
        [[ -t 2 || "${MOLE_TEST_FORCE_SCAN_SPINNER:-0}" == "1" ]] || return 0
        (
            # shellcheck disable=SC2329  # Function invoked indirectly via trap
            cleanup_spinner() { exit 0; }
            trap cleanup_spinner TERM INT EXIT
            [[ -f "$scan_status_file" ]] || exit 0
            local spinner_chars="|/-\\"
            local i=0
            : > "$spinner_shown_file"
            while true; do
                local status_line status_message status_completed status_total
                status_line=$(cat "$scan_status_file" 2> /dev/null || echo "")
                IFS='|' read -r status_message status_completed status_total <<< "$status_line"
                [[ -z "$status_message" ]] && status_message="Scanning applications..."
                local c="${spinner_chars:$((i % 4)):1}"
                if [[ "$status_completed" =~ ^[0-9]+$ && "$status_total" =~ ^[0-9]+$ && $status_total -gt 0 ]]; then
                    printf "\r\033[K%s %s %d/%d" "$c" "$status_message" "$status_completed" "$status_total" >&2
                else
                    printf "\r\033[K%s %s" "$c" "$status_message" >&2
                fi
                ((i++))
                sleep 0.1 2> /dev/null || sleep 1
            done
        ) &
        spinner_pid=$!
    }

    stop_scan_spinner() {
        if [[ -n "$spinner_pid" ]]; then
            kill -TERM "$spinner_pid" 2> /dev/null || true
            wait "$spinner_pid" 2> /dev/null || true
            spinner_pid=""
        fi
        if [[ -f "$spinner_shown_file" ]]; then
            printf "\r\033[K" >&2
        fi
        rm -f "$spinner_shown_file" "$scan_status_file" 2> /dev/null || true
    }

    update_scan_status "Scanning applications..." "0" "0"
    start_scan_spinner

    # Phase 2: discover candidate apps.
    _scan_discover_apps

    # Phase 3: partition into warm-cache and cold rows.
    local -a app_data_tuples=()
    _scan_partition_cache

    # Phase 4: bail out if discovery yielded nothing.
    if [[ ${#app_data_tuples[@]} -eq 0 && ! -s "$scan_raw_file" ]]; then
        stop_scan_spinner
        rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file" "$scan_status_file" "${temp_file}.sorted" "$spinner_shown_file" 2> /dev/null || true
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        printf "\r\033[K" >&2
        echo "No applications found to uninstall." >&2
        return 1
    fi
    # Phase 5: parallel metadata resolution for cold rows.
    _scan_resolve_uncached

    # Phase 6: bail out if Pass 2 produced nothing.
    update_scan_status "Building uninstall index..." "0" "0"

    if [[ ! -s "$scan_raw_file" ]]; then
        stop_scan_spinner
        echo "No applications found to uninstall" >&2
        rm -f "$temp_file" "$scan_raw_file" "$merged_file" "$refresh_file" "$cache_snapshot_file" "$discovered_file" "$cached_rows_file" "$uncached_rows_file" "${temp_file}.sorted" "$spinner_shown_file" 2> /dev/null || true
        [[ $cache_source_is_temp == true ]] && rm -f "$cache_source" 2> /dev/null || true
        restore_scan_int_trap
        return 1
    fi

    _scan_dedupe_bundle_ids

    # Phase 7+8: merge cache, persist, sort, return path.
    _scan_finalize_index
}

load_applications() {
    local apps_file="$1"

    if [[ ! -f "$apps_file" || ! -s "$apps_file" ]]; then
        log_warning "No applications found for uninstallation"
        return 1
    fi

    apps_data=()
    apps_meta_data=()
    selection_state=()

    # apps_out (bin/uninstall.sh's _scan_finalize_index) widened to 10
    # fields for M1-T4 (CONTRACT.md §6): real_used_epoch, app_mtime and
    # version trail the original 7. apps_data keeps its original 7-field
    # shape unchanged — every other consumer in this file, lib/ui/app_selector.sh
    # and lib/uninstall/batch.sh destructures it positionally, and widening it
    # would silently corrupt their trailing field via read's overflow-into-
    # last-var behavior. The 3 new fields go into the parallel apps_meta_data
    # array instead, index-aligned with apps_data. Readers: uninstall_list_apps
    # (CONTRACT.md §6) and uninstall_plan_resolve_app (§7.3's app.version).
    # Widening apps_meta_data means checking both.
    while IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb real_used_epoch app_mtime version; do
        [[ ! -e "$app_path" ]] && continue

        apps_data+=("$epoch|$app_path|$app_name|$bundle_id|$size|$last_used|${size_kb:-0}")
        apps_meta_data+=("${real_used_epoch:-}|${app_mtime:-}|${version:-}")
        selection_state+=(false)
    done < "$apps_file"

    if [[ ${#apps_data[@]} -eq 0 ]]; then
        log_warning "No applications available for uninstallation"
        return 1
    fi

    return 0
}

# Keep the scan and selector on one alternate screen so restoring the terminal
# also restores the primary-screen cursor to the command's original row.
start_uninstall_interactive_screen() {
    if [[ -t 1 && -t 2 && "${MOLE_ALT_SCREEN_ACTIVE:-}" != "1" ]]; then
        enter_alt_screen
        export MOLE_ALT_SCREEN_ACTIVE=1
        export MOLE_MANAGED_ALT_SCREEN=1
        printf '\033[2J\033[H' >&2
    fi
}

stop_uninstall_interactive_screen() {
    if [[ "${MOLE_ALT_SCREEN_ACTIVE:-}" == "1" ]]; then
        leave_alt_screen
    fi
    unset MOLE_ALT_SCREEN_ACTIVE MOLE_MANAGED_ALT_SCREEN
}

# Surface an abort during scan/load/selection instead of returning to the
# prompt as if the run had succeeded. Interactive mode renders on an alternate
# screen, so the reason has to be printed after the screen is restored (#1339).
uninstall_abort() {
    local reason="$1"
    stop_uninstall_interactive_screen
    show_cursor
    log_error "Uninstall aborted: $reason"
}

# Cleanup: restore cursor and kill keepalive.
cleanup() {
    local exit_code="${1:-$?}"
    stop_uninstall_interactive_screen
    if [[ -n "${sudo_keepalive_pid:-}" ]]; then
        kill "$sudo_keepalive_pid" 2> /dev/null || true
        wait "$sudo_keepalive_pid" 2> /dev/null || true
        sudo_keepalive_pid=""
    fi
    # Log session end
    log_operation_session_end "uninstall" "${files_cleaned:-0}" "${total_size_cleaned:-0}"
    show_cursor
    exit "$exit_code"
}

trap cleanup EXIT INT TERM

# Match app names from scan data against user-provided search terms.
# Performs case-insensitive substring matching on app display names.
# Returns matched entries from apps_data in selected_apps.
match_apps_by_name() {
    local -a search_terms=("$@")
    selected_apps=()
    local -a matched_indices=()

    # `mo uninstall Tor Browser` arrives as two words. Matching each word
    # alone sent "Tor" into a substring hit on WebSTORm while the app the
    # user actually named sat in the list (#1365). When the words joined
    # with spaces exactly match an installed app's display or directory
    # name, that is the query, UNLESS every word already exactly names its
    # own installed app: with Foo.app, Bar.app, and "Foo Bar.app" all
    # present, `mo uninstall Foo Bar` keeps its original two-app meaning
    # rather than silently collapsing into the third.
    if [[ ${#search_terms[@]} -gt 1 ]]; then
        local every_word_exact=true
        local word word_lower word_app word_hit
        for word in "${search_terms[@]}"; do
            word_lower=$(echo "$word" | tr '[:upper:]' '[:lower:]')
            word_hit=false
            for word_app in "${apps_data[@]}"; do
                IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$word_app"
                local word_name_lower word_dir_lower
                word_name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
                word_dir_lower=$(basename "$app_path" .app | tr '[:upper:]' '[:lower:]')
                if [[ "$word_name_lower" == "$word_lower" || "$word_dir_lower" == "$word_lower" ]]; then
                    word_hit=true
                    break
                fi
            done
            if [[ "$word_hit" == "false" ]]; then
                every_word_exact=false
                break
            fi
        done
        if [[ "$every_word_exact" == "false" ]]; then
            local joined_lower
            joined_lower=$(echo "$*" | tr '[:upper:]' '[:lower:]')
            local joined_app
            for joined_app in "${apps_data[@]}"; do
                IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$joined_app"
                local joined_name_lower joined_dir_lower
                joined_name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
                joined_dir_lower=$(basename "$app_path" .app | tr '[:upper:]' '[:lower:]')
                if [[ "$joined_name_lower" == "$joined_lower" || "$joined_dir_lower" == "$joined_lower" ]]; then
                    selected_apps=("$joined_app")
                    return 0
                fi
            done
        fi
    fi

    for search_term in "${search_terms[@]}"; do
        local search_lower
        search_lower=$(echo "$search_term" | tr '[:upper:]' '[:lower:]')
        # Escape glob characters to prevent pattern injection
        search_lower=${search_lower//\\/\\\\}
        search_lower=${search_lower//\*/\\*}
        search_lower=${search_lower//\?/\\?}
        search_lower=${search_lower//\[/\\[}
        local found=false
        local idx=0
        for app_data in "${apps_data[@]}"; do
            IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$app_data"
            local name_lower
            name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
            # Also try matching against the .app directory base name
            local dir_name
            dir_name=$(basename "$app_path" .app)
            local dir_lower
            dir_lower=$(echo "$dir_name" | tr '[:upper:]' '[:lower:]')

            if [[ "$name_lower" == "$search_lower" || "$dir_lower" == "$search_lower" ]]; then
                # Exact match - prefer this
                local already=false
                local mi
                for mi in "${matched_indices[@]+"${matched_indices[@]}"}"; do
                    [[ -z "$mi" ]] && continue
                    [[ "$mi" == "$idx" ]] && already=true && break
                done
                if [[ "$already" == "false" ]]; then
                    selected_apps+=("$app_data")
                    matched_indices+=("$idx")
                fi
                found=true
                break
            fi
            idx=$((idx + 1))
        done

        # If no exact match, try substring match
        if [[ "$found" == "false" ]]; then
            idx=0
            for app_data in "${apps_data[@]}"; do
                IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$app_data"
                local name_lower
                name_lower=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
                local dir_name
                dir_name=$(basename "$app_path" .app)
                local dir_lower
                dir_lower=$(echo "$dir_name" | tr '[:upper:]' '[:lower:]')

                if [[ "$name_lower" == *"$search_lower"* || "$dir_lower" == *"$search_lower"* ]]; then
                    local already=false
                    local mi
                    for mi in "${matched_indices[@]+"${matched_indices[@]}"}"; do
                        [[ -z "$mi" ]] && continue
                        [[ "$mi" == "$idx" ]] && already=true && break
                    done
                    if [[ "$already" == "false" ]]; then
                        selected_apps+=("$app_data")
                        matched_indices+=("$idx")
                    fi
                    found=true
                fi
                idx=$((idx + 1))
            done
        fi

        if [[ "$found" == "false" ]]; then
            echo -e "${YELLOW}Warning:${NC} No application found matching '$search_term'"
        fi
    done
}

# VERSION= stays in the `mole` router; read it the same way bin/clean.sh's
# and bin/optimize.sh's --json paths do, so all three emitters degrade the
# same way (mole_version is diagnostic-only per CONTRACT.md §1.5 — never
# gate behaviour on it).
uninstall_list_mole_version() {
    local version
    version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$MOLE_UNINSTALL_REPO_ROOT/mole" 2> /dev/null | head -1)
    [[ -n "$version" ]] || version="unknown"
    printf '%s' "$version"
}

# Epoch -> RFC 3339 UTC, or nothing when the epoch is not a real value.
# Honours MOLE_UNINSTALL_EPOCH_FLOOR the same way the scan awk does — see
# F-035 / docs/handoff-M1-T4.md.
uninstall_list_epoch_to_rfc3339() {
    local epoch="${1:-}"
    [[ "$epoch" =~ ^[0-9]+$ && "$epoch" -ge "$MOLE_UNINSTALL_EPOCH_FLOOR" ]] || return 1
    date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2> /dev/null
}

# CONTRACT.md §1.5 envelope header, through "scan_status". Callers append
# the rest (warnings/error/data) and the closing brace.
uninstall_list_envelope_open() {
    local mole_version="$1"
    local scan_status="$2"
    local generated_at
    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '{"schema_version":1,"mole_version":'
    history_json_string "$mole_version"
    printf ',"command":"uninstall","mode":"list","generated_at":'
    history_json_string "$generated_at"
    printf ',"scan_status":'
    history_json_string "$scan_status"
}

# §6.8: scan_status "failed", data absent, exit is the caller's job (1 per
# §1.6). Used when the scan itself could not complete — never for a scan
# that completed with zero apps (that is data.apps: [], not a failure).
uninstall_list_emit_failed() {
    local mole_version="$1"
    local code="$2"
    local message="$3"
    uninstall_list_envelope_open "$mole_version" "failed"
    printf ',"warnings":[],"error":{"code":'
    history_json_string "$code"
    printf ',"message":'
    history_json_string "$message"
    printf '},"data":null}\n'
}

# The single predicate deciding whether an app's measured size is real
# (CONTRACT.md §1.1/§6.4: `size_known: false` and no `size_bytes`, never
# `size_bytes: 0`). Both the per-entry `size_known` flag and the envelope's
# degradation warning below read this one function, so the summary can never
# disagree with the entries it summarises — F-089 was exactly that
# disagreement: 65 apps with `size_known: false` under `scan_status:
# "complete"` and `warnings: []`.
uninstall_list_size_is_known() {
    local size_kb="${1:-0}"
    [[ "$size_kb" =~ ^[0-9]+$ ]] && [[ "$size_kb" -gt 0 ]]
}

# How many apps in apps_data have no real size. Reads field 7 (size_kb) of the
# same 7-field tuple uninstall_list_emit_json destructures.
uninstall_list_unmeasured_count() {
    local total=${#apps_data[@]}
    local i count=0 size_kb
    for ((i = 0; i < total; i++)); do
        IFS='|' read -r _ _ _ _ _ _ size_kb <<< "${apps_data[$i]}"
        uninstall_list_size_is_known "$size_kb" || count=$((count + 1))
    done
    printf '%s' "$count"
}

# §6.3/§6.4 envelope: `mode: "list"`, `data.apps` (always an array). Reads
# apps_data (unchanged 7-field shape) and the index-aligned apps_meta_data
# (real_used_epoch|app_mtime|version — see load_applications) that
# load_applications populated. size_bytes/size_known and last_used/
# installed_at follow F-035's decision: last_used comes from
# real_used_epoch only (a real macOS use record), never from app_mtime, so
# an app macOS has no use record for reports no last_used at all rather
# than silently relabelling its modification time.
uninstall_list_emit_json() {
    local mole_version="$1"

    # §1.4: a listing in which some size could not be measured is `partial`,
    # not `complete` — the per-app sizes are a floor, and an app reporting no
    # size at all is a unit of work that did not finish. `uninstall --plan`
    # has always declared this (`size_unmeasured`, bin/uninstall.sh:2242);
    # `--list` asserted `complete` over the same condition. Same command, one
    # standard now.
    local total=${#apps_data[@]}
    local unmeasured warnings_json="[]" scan_status="complete"
    unmeasured=$(uninstall_list_unmeasured_count)
    if [[ "$unmeasured" -gt 0 ]]; then
        scan_status="partial"
        warnings_json="[{\"code\":\"size_unmeasured\",\"message\":$(history_json_string "$unmeasured of $total applications could not be measured; their sizes are unknown, not zero.")}]"
    fi

    uninstall_list_envelope_open "$mole_version" "$scan_status"
    printf ',"warnings":%s,"error":null,"data":{"apps":[' "$warnings_json"

    local i first=1
    for ((i = 0; i < total; i++)); do
        local app_data="${apps_data[$i]}"
        local meta="${apps_meta_data[i]:-||}"
        local app_path app_name bundle_id size size_kb
        local real_used_epoch app_mtime_epoch version
        IFS='|' read -r _ app_path app_name bundle_id size _ size_kb <<< "$app_data"
        IFS='|' read -r real_used_epoch app_mtime_epoch version <<< "$meta"

        local cask=""
        if is_homebrew_available; then
            cask=$(get_brew_cask_name "$app_path" 2> /dev/null || true)
        fi
        local uninstall_name="${cask:-$app_name}"
        local source_label="App"
        [[ -n "$cask" ]] && source_label="Homebrew"
        local size_display
        size_display=$(uninstall_normalize_size_display "$size" "$app_path")

        # §1.1: size_known false + size_bytes absent, never size_bytes: 0.
        # human_size() in the scan awk returns "--" for kb <= 0 — F-022's
        # sentinel at its source — so kb > 0 is the same test this emitter
        # must use to agree with it. A Steam launcher shortcut's own size is
        # not the game's size (upstream #1461-adjacent Steam-managed work,
        # lib/uninstall/steam.sh): keep size_known/size_bytes reporting the
        # shortcut bundle's real, honest kb — only the deprecated display
        # string "size" is replaced with the Steam-managed label, matching
        # uninstall_normalize_size_display's existing text-mode behaviour.
        local size_known="false" size_bytes=""
        if uninstall_list_size_is_known "$size_kb"; then
            size_known="true"
            size_bytes=$((size_kb * 1024))
        fi

        local last_used=""
        last_used=$(uninstall_list_epoch_to_rfc3339 "$real_used_epoch") || last_used=""

        local installed_at="" installed_at_source=""
        if installed_at=$(uninstall_list_epoch_to_rfc3339 "$app_mtime_epoch"); then
            installed_at_source="bundle_mtime"
        else
            installed_at=""
        fi

        [[ "$first" == "1" ]] || printf ','
        first=0

        printf '{"name":'
        history_json_string "$app_name"
        printf ',"bundle_id":'
        history_json_string "$bundle_id"
        printf ',"source":'
        history_json_string "$source_label"
        printf ',"uninstall_name":'
        history_json_string "$uninstall_name"
        printf ',"path":'
        history_json_string "$app_path"
        printf ',"size":'
        history_json_string "$size_display"
        printf ',"size_known":%s' "$size_known"
        [[ -z "$size_bytes" ]] || printf ',"size_bytes":%s' "$size_bytes"
        if [[ -n "$version" ]]; then
            printf ',"version":'
            history_json_string "$version"
        fi
        if [[ -n "$last_used" ]]; then
            printf ',"last_used":'
            history_json_string "$last_used"
        fi
        if [[ -n "$installed_at" ]]; then
            printf ',"installed_at":'
            history_json_string "$installed_at"
            printf ',"installed_at_source":'
            history_json_string "$installed_at_source"
        fi
        printf '}'
    done

    printf ']}}\n'
}

# Read-only listing: surface each installed app's display name, bundle id,
# the exact name `mo uninstall` accepts, and human-readable size. Reuses the
# existing scanner so the output stays in lockstep with what the destructive
# path sees. Args: json_flag ("1" when --json was passed explicitly).
uninstall_list_apps() {
    local json_flag="${1:-0}"
    local mole_version
    mole_version=$(uninstall_list_mole_version)

    # §6.1: --json is explicit; the TTY auto-switch stays for schema_version
    # 1 backward compatibility (Molehouse itself must always pass --json
    # explicitly and never rely on this).
    local format="text"
    if [[ "$json_flag" == "1" || ! -t 1 ]]; then
        format="json"
    fi

    local apps_file=""
    if ! apps_file=$(scan_applications); then
        if [[ "$format" == "json" ]]; then
            uninstall_list_emit_failed "$mole_version" "scan_failed" "could not complete the application scan"
            return 1
        fi
        uninstall_abort "could not complete the application scan"
        return 1
    fi
    if [[ ! -f "$apps_file" ]]; then
        if [[ "$format" == "json" ]]; then
            uninstall_list_emit_failed "$mole_version" "scan_failed" "application scan produced no list"
            return 1
        fi
        uninstall_abort "application scan produced no list"
        return 1
    fi
    if ! load_applications "$apps_file"; then
        rm -f "$apps_file"
        # A scan that completed and legitimately found nothing is §6.8's
        # `no_apps` case: not an error. data.apps: [], exit 0. Text mode is
        # not governed by the contract, so it keeps its pre-existing abort
        # behaviour unchanged.
        if [[ "$format" == "json" ]]; then
            uninstall_list_emit_json "$mole_version"
            return 0
        fi
        uninstall_abort "no applications available for uninstallation"
        return 1
    fi
    rm -f "$apps_file"

    if [[ "$format" == "json" ]]; then
        uninstall_list_emit_json "$mole_version"
        return 0
    fi

    local total=${#apps_data[@]}
    if [[ $total -eq 0 ]]; then
        echo "No applications found."
        return 0
    fi

    printf '\n'
    printf '%-36s %-30s %-30s %8s\n' 'NAME' 'BUNDLE ID' 'UNINSTALL NAME' 'SIZE'
    printf -- '-%.0s' $(seq 1 108)
    printf '\n'

    local app_data
    for app_data in "${apps_data[@]+"${apps_data[@]}"}"; do
        IFS='|' read -r _ app_path app_name bundle_id size _ _ <<< "$app_data"
        local cask=""
        if is_homebrew_available; then
            cask=$(get_brew_cask_name "$app_path" 2> /dev/null || true)
        fi
        local uninstall_name="${cask:-$app_name}"
        local size_display
        size_display=$(uninstall_normalize_size_display "$size" "$app_path")

        # Truncate by display columns, then adjust printf width for CJK.
        # printf counts bytes (LC_ALL=C), but CJK chars are 3 bytes yet only
        # 2 display columns wide, so we pad with the extra bytes to land on
        # the correct visual column.
        local name_trunc name_display_w name_byte_count name_printf_w
        name_trunc=$(truncate_by_display_width "$app_name" 34)
        name_display_w=$(get_display_width "$name_trunc")

        # Get byte count in C locale for printf
        local old_lc="${LC_ALL:-}"
        export LC_ALL=C
        name_byte_count=${#name_trunc}
        if [[ -n "$old_lc" ]]; then
            export LC_ALL="$old_lc"
        else
            unset LC_ALL
        fi

        name_printf_w=$((36 + name_byte_count - name_display_w))

        printf "%-*s %-30s %-30s %8s\n" \
            "$name_printf_w" "$name_trunc" \
            "${bundle_id:0:28}" \
            "${uninstall_name:0:28}" \
            "$size_display"
    done

    printf '\n%d application(s)  |  Remove with: mo uninstall <UNINSTALL NAME>\n\n' "$total"
    return 0
}

# ===========================================================================
# CONTRACT.md §7 — `uninstall --plan` / `uninstall --apply-plan`
#
# Non-interactive per-file uninstall preview, and the apply half that reads
# that preview back and deletes only what the caller approved.
#
# The one invariant everything below exists to protect: the set of paths the
# user approved is the set of paths that get deleted. `--apply-plan` re-runs
# discovery, recomputes `plan_digest` over the CURRENT discovery, and refuses
# the whole operation (exit 4) when it disagrees with the submitted plan. It
# never searches for what to delete: it deletes the submitted plan's own path
# strings, filtered by `selected`, each re-validated at the deletion boundary.
# That is what makes "12 approved, 40 deleted" structurally impossible rather
# than merely unlikely.
#
# Records move between the stages one entry per line, fields separated by US
# (0x1f):
#   plan record       path US size_bytes US size_known US is_dir US protected
#                     US requires_sudo US category
#   submitted record  id US path US size_bytes US size_known US protected
#
# A path containing a control character can never appear in a record.
# `validate_path_for_deletion` refuses control characters outright, so such a
# path is not deletable in the first place, and `find_app_files` returns a
# newline-separated list that could not carry one intact anyway. Plan build
# drops those paths with a `path_unrepresentable` warning rather than
# silently mis-splitting a record.
# ===========================================================================

# `sha256(path)` truncated to 16 hex chars (§7.3). shasum -a 256 is already a
# dependency of lib/clean/user.sh and bin/installer.sh — no new one here.
uninstall_plan_entry_id() {
    printf '%s' "$1" | shasum -a 256 | cut -c1-16
}

# §7.3 `category`, from the path string alone. Kept pure and table-shaped so
# M1-T6 can fixture it against a table of inputs. Group Containers is tested
# before Containers on purpose: the two subtrees are siblings and the narrower
# label has to win.
uninstall_plan_classify_category() {
    local path="$1"
    local app_path="${2:-}"

    if [[ -n "$app_path" && "$path" == "$app_path" ]]; then
        printf 'bundle'
        return 0
    fi

    case "$path" in
        */Group\ Containers/*) printf 'group_containers' ;;
        */Containers/*) printf 'containers' ;;
        */Caches/*) printf 'caches' ;;
        */Preferences/*) printf 'preferences' ;;
        */Application\ Support/*) printf 'application_support' ;;
        */Saved\ Application\ State/*) printf 'saved_state' ;;
        */LaunchAgents/* | */LaunchDaemons/*) printf 'launch_agents' ;;
        */Logs/*) printf 'logs' ;;
        *) printf 'other' ;;
    esac
}

# §7.3 `label` — display text, derived from the category so the two can never
# describe different things.
uninstall_plan_category_label() {
    case "$1" in
        bundle) printf 'Application bundle' ;;
        caches) printf 'Caches' ;;
        preferences) printf 'Preferences' ;;
        application_support) printf 'Application Support' ;;
        containers) printf 'Container' ;;
        group_containers) printf 'Group Container' ;;
        launch_agents) printf 'Launch Agent' ;;
        logs) printf 'Logs' ;;
        saved_state) printf 'Saved Application State' ;;
        *) printf 'Other' ;;
    esac
}

# Measure a path in bytes, or fail (return 1) when it cannot be measured.
#
# §1.1 / F-022: "0 bytes" and "could not measure" must never share a
# representation, so the failure is reported through the exit status and the
# caller emits `size_known: false` with no `size_bytes` key at all.
#
# Deliberately NOT get_path_size_kb: that helper prefers `mdls` for .app
# bundles and returns a bare "0" both for an empty path and for a failed
# probe, which collapses exactly the two facts §1.1 separates. These numbers
# are digest inputs, so they must be reproducible from the filesystem alone
# between the plan call and the apply call; an mdls probe that answers on one
# run and times out into the du fallback on the next would present as a stale
# plan when nothing on disk had changed. Every external command here is
# bounded (.claude/skills/bugs archetype 4).
uninstall_plan_measure_bytes() {
    local path="$1"
    local raw="" rc=0

    if [[ -L "$path" || -f "$path" ]]; then
        raw=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            "$STAT_BSD" -f%z "$path" 2> /dev/null) || rc=$?
        [[ $rc -eq 0 && "$raw" =~ ^[0-9]+$ ]] || return 1
        printf '%s' "$raw"
        return 0
    fi

    if [[ -d "$path" ]]; then
        raw=$(run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
            du -skP "$path" 2> /dev/null | awk 'NR==1 {print $1; exit}') || rc=$?
        [[ $rc -eq 0 && "$raw" =~ ^[0-9]+$ ]] || return 1
        printf '%s' "$((raw * 1024))"
        return 0
    fi

    return 1
}

# §7.2's canonical serialisation, hashed:
#
#   bundle_id NUL app_path NUL
#   then, for every entry sorted by path under LC_ALL=C:
#       path NUL size_bytes NUL size_known NUL
#
# size_bytes is the decimal byte count, or the empty string when size_known is
# false. size_known is the literal `true` or `false`. §7.2 does not spell
# either of those out; both are pinned here and reported in
# docs/handoff-M1-T5.md's answer so Molehouse implements the same bytes.
#
# $3 is a plan-record file already in canonical (LC_ALL=C sorted) order, which
# is why reordering the same entries cannot change the digest.
uninstall_plan_digest() {
    local bundle_id="$1"
    local app_path="$2"
    local records_file="$3"

    {
        printf '%s\0%s\0' "$bundle_id" "$app_path"
        local line path size_bytes size_known
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            IFS=$'\x1f' read -r path size_bytes size_known _ <<< "$line"
            printf '%s\0%s\0%s\0' "$path" "$size_bytes" "$size_known"
        done < "$records_file"
    } | shasum -a 256 | awk '{print $1; exit}'
}

# Build the canonical plan-record file for one app.
#
# Args: bundle_id app_name app_path out_records_file out_warnings_file
# Returns 0 when discovery completed, 1 when it did not (the caller decides
# whether that is a `partial` plan or a refused apply), or the timeout /
# interrupt status when discovery was cancelled.
#
# The app bundle itself is an entry: find_app_files never discovers it (the
# caller supplies app_path separately), and a plan that omitted it would
# preview an uninstall that leaves the application behind.
uninstall_plan_build_records() {
    local bundle_id="$1"
    local app_name="$2"
    local app_path="$3"
    local out_file="$4"
    local warn_file="$5"
    local us=$'\x1f'

    : > "$out_file"

    local discovered="" discovery_rc=0
    discovered=$(find_app_files "$bundle_id" "$app_name" "$app_path" 2> /dev/null) || discovery_rc=$?
    if [[ $discovery_rc -eq 124 || $discovery_rc -ge 128 ]]; then
        return "$discovery_rc"
    fi

    local raw_file unsorted_file
    raw_file=$(create_temp_file) || return 1
    unsorted_file=$(create_temp_file) || return 1

    {
        printf '%s\n' "$app_path"
        [[ -z "$discovered" ]] || printf '%s\n' "$discovered"
    } | awk 'NF && !seen[$0]++' > "$raw_file"

    local path size_bytes size_known is_dir protected requires_sudo category
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ -e "$path" || -L "$path" ]] || continue

        if [[ "$path" =~ [[:cntrl:]] ]]; then
            printf 'path_unrepresentable\n' >> "$warn_file"
            continue
        fi

        size_known="false"
        if size_bytes=$(uninstall_plan_measure_bytes "$path"); then
            size_known="true"
        else
            size_bytes=""
        fi

        is_dir="false"
        [[ -d "$path" && ! -L "$path" ]] && is_dir="true"

        # §7.3: `protected` has to be known at PLAN time so the UI can render
        # the row disabled and unselectable rather than discovering the
        # refusal as a failure at apply time. Validation runs again per entry
        # at the deletion boundary regardless (§7.2) — this is a preview of
        # that verdict, never a substitute for it.
        protected="false"
        if [[ "${MO_DEBUG:-0}" == "1" ]]; then
            validate_path_for_deletion "$path" || protected="true"
        else
            validate_path_for_deletion "$path" 2> /dev/null || protected="true"
        fi

        requires_sudo="false"
        uninstall_path_requires_sudo "$path" && requires_sudo="true"

        category=$(uninstall_plan_classify_category "$path" "$app_path")

        printf '%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
            "$path" "$us" "$size_bytes" "$us" "$size_known" "$us" \
            "$is_dir" "$us" "$protected" "$us" "$requires_sudo" "$us" \
            "$category" >> "$unsorted_file"
    done < "$raw_file"

    LC_ALL=C sort "$unsorted_file" > "$out_file"
    rm -f "$raw_file" "$unsorted_file" 2> /dev/null || true # SAFE: exact tracked temp files created above

    [[ $discovery_rc -eq 0 ]] || return 1
    return 0
}

# True when any record carries size_known == false, so the caller can mark the
# plan `partial` (§1.4: a total that excludes unmeasured entries is a lower
# bound and must say so).
uninstall_plan_has_unmeasured() {
    local records_file="$1"
    local line size_known
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\x1f' read -r _ _ size_known _ <<< "$line"
        [[ "$size_known" == "true" ]] || return 0
    done < "$records_file"
    return 1
}

# Exactly-one lookup for `--plan <uninstall_name>` (§7.2 step 1).
#
# Deliberately NOT match_apps_by_name: that matcher is case-insensitive
# substring matching across several words and can return more than one app,
# which is right for an interactive picker and wrong for a scriptable command
# whose whole contract is "this one app". `uninstall_name` is the exact token
# `--list` already reports (§6.4), so an exact string comparison is the
# correct lookup, and zero-or-many is a usage error rather than a best guess.
#
# Sets PLAN_APP_NAME / PLAN_APP_PATH / PLAN_APP_BUNDLE_ID /
# PLAN_APP_UNINSTALL_NAME / PLAN_APP_VERSION on success.
# Returns 0 on exactly one match, 2 on none, 3 on more than one.
uninstall_plan_resolve_app() {
    local wanted="$1"
    local total=${#apps_data[@]}
    local i match_count=0 match_index=-1

    for ((i = 0; i < total; i++)); do
        local app_path app_name
        IFS='|' read -r _ app_path app_name _ _ _ _ <<< "${apps_data[$i]}"
        local cask=""
        if is_homebrew_available; then
            cask=$(get_brew_cask_name "$app_path" 2> /dev/null || true)
        fi
        if [[ "${cask:-$app_name}" == "$wanted" ]]; then
            match_count=$((match_count + 1))
            match_index=$i
        fi
    done

    [[ $match_count -eq 0 ]] && return 2
    [[ $match_count -gt 1 ]] && return 3

    local app_path app_name bundle_id
    IFS='|' read -r _ app_path app_name bundle_id _ _ _ <<< "${apps_data[$match_index]}"
    local cask=""
    if is_homebrew_available; then
        cask=$(get_brew_cask_name "$app_path" 2> /dev/null || true)
    fi
    local version=""
    IFS='|' read -r _ _ version <<< "${apps_meta_data[$match_index]:-||}"

    PLAN_APP_NAME="$app_name"
    PLAN_APP_PATH="$app_path"
    PLAN_APP_BUNDLE_ID="$bundle_id"
    PLAN_APP_UNINSTALL_NAME="${cask:-$app_name}"
    PLAN_APP_VERSION="$version"
    return 0
}

# §1.5 envelope header for the plan/apply modes. The sibling
# uninstall_list_envelope_open is pinned to `mode: "list"`; this one takes the
# mode because plan and apply share it.
uninstall_plan_envelope_open() {
    local mole_version="$1"
    local mode="$2"
    local scan_status="$3"
    local generated_at
    generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '{"schema_version":1,"mole_version":'
    history_json_string "$mole_version"
    printf ',"command":"uninstall","mode":'
    history_json_string "$mode"
    printf ',"generated_at":'
    history_json_string "$generated_at"
    printf ',"scan_status":'
    history_json_string "$scan_status"
}

# §1.4 `failed` envelope: data absent, error present. The exit code is the
# caller's job (§1.6).
uninstall_plan_emit_failed() {
    local mole_version="$1"
    local mode="$2"
    local code="$3"
    local message="$4"
    uninstall_plan_envelope_open "$mole_version" "$mode" "failed"
    printf ',"warnings":[],"error":{"code":'
    history_json_string "$code"
    printf ',"message":'
    history_json_string "$message"
    printf '},"data":null}\n'
}

# Render the warnings array from the codes collected during the run. Codes are
# deduplicated: one `size_unmeasured` warning describes the run, not each
# entry — the per-entry fact is already in that entry's `size_known`.
uninstall_plan_emit_warnings() {
    local warn_file="$1"
    printf '['
    local first=1 code message
    while IFS= read -r code; do
        [[ -n "$code" ]] || continue
        case "$code" in
            size_unmeasured)
                message="One or more paths could not be measured; total_bytes is a lower bound."
                ;;
            discovery_incomplete)
                message="Leftover discovery did not complete; the plan may be missing entries."
                ;;
            path_unrepresentable)
                message="A discovered path contains control characters and was excluded; it cannot be deleted."
                ;;
            *) message="$code" ;;
        esac
        [[ "$first" == "1" ]] || printf ','
        first=0
        printf '{"code":'
        history_json_string "$code"
        printf ',"message":'
        history_json_string "$message"
        printf '}'
    done < <(LC_ALL=C sort -u "$warn_file")
    printf ']'
}

# CONTRACT.md §7.7: the delete mode this run assumes, normalised to the two
# values the contract allows. `uninstall_path_requires_sudo` treats anything
# that is not literally `trash` as permanent semantics, so this normalisation
# is the same rule the predicate applies, not a second opinion about it.
uninstall_plan_delete_mode() {
    [[ "${MOLE_DELETE_MODE:-trash}" == "trash" ]] && {
        printf 'trash\n'
        return 0
    }
    printf 'permanent\n'
}

# §7.3 plan payload.
uninstall_plan_emit_json() {
    local mole_version="$1"
    local records_file="$2"
    local warn_file="$3"
    local digest="$4"
    local scan_status="$5"

    local total_items=0 unmeasured_items=0 total_bytes=0 plan_requires_sudo="false"
    local line path size_bytes size_known is_dir protected requires_sudo category
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\x1f' read -r path size_bytes size_known is_dir protected requires_sudo category <<< "$line"
        total_items=$((total_items + 1))
        if [[ "$size_known" == "true" ]]; then
            total_bytes=$((total_bytes + size_bytes))
        else
            unmeasured_items=$((unmeasured_items + 1))
        fi
        [[ "$requires_sudo" == "true" ]] && plan_requires_sudo="true"
    done < "$records_file"

    uninstall_plan_envelope_open "$mole_version" "plan" "$scan_status"
    printf ',"warnings":'
    uninstall_plan_emit_warnings "$warn_file"
    printf ',"error":null,"data":{"app":{"name":'
    history_json_string "$PLAN_APP_NAME"
    printf ',"bundle_id":'
    history_json_string "$PLAN_APP_BUNDLE_ID"
    printf ',"path":'
    history_json_string "$PLAN_APP_PATH"
    printf ',"uninstall_name":'
    history_json_string "$PLAN_APP_UNINSTALL_NAME"
    if [[ -n "$PLAN_APP_VERSION" ]]; then
        printf ',"version":'
        history_json_string "$PLAN_APP_VERSION"
    fi
    printf '},"delete_mode":'
    history_json_string "$(uninstall_plan_delete_mode)"
    printf ',"plan_digest":'
    history_json_string "$digest"
    printf ',"total_bytes":%s,"total_items":%s,"unmeasured_items":%s,"requires_sudo":%s,"entries":[' \
        "$total_bytes" "$total_items" "$unmeasured_items" "$plan_requires_sudo"

    local first=1 entry_id label
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\x1f' read -r path size_bytes size_known is_dir protected requires_sudo category <<< "$line"

        entry_id=$(uninstall_plan_entry_id "$path")
        label=$(uninstall_plan_category_label "$category")

        [[ "$first" == "1" ]] || printf ','
        first=0

        printf '{"id":'
        history_json_string "$entry_id"
        printf ',"path":'
        history_json_string "$path"
        printf ',"label":'
        history_json_string "$label"
        printf ',"category":'
        history_json_string "$category"
        printf ',"size_known":%s' "$size_known"
        [[ "$size_known" == "true" ]] && printf ',"size_bytes":%s' "$size_bytes"
        printf ',"is_dir":%s,"requires_sudo":%s,"protected":%s}' \
            "$is_dir" "$requires_sudo" "$protected"
    done < "$records_file"

    printf ']}}\n'
}

# `mole uninstall --plan <uninstall_name> [--json]`
#
# Read-only: deletes nothing, prompts for nothing, needs no privilege. JSON is
# the only output format. §7 defines no text rendering for a plan, and
# inventing one would create a second, unspecified representation of the most
# destructive screen in the product; `--json` is accepted and documented so
# callers can be explicit, as §6.1 requires of `--list`.
uninstall_plan_command() {
    local wanted="$1"
    local mole_version
    mole_version=$(uninstall_list_mole_version)

    local apps_file=""
    if ! apps_file=$(scan_applications); then
        uninstall_plan_emit_failed "$mole_version" "plan" "scan_failed" \
            "could not complete the application scan"
        return 1
    fi
    if [[ ! -f "$apps_file" ]]; then
        uninstall_plan_emit_failed "$mole_version" "plan" "scan_failed" \
            "application scan produced no list"
        return 1
    fi
    if ! load_applications "$apps_file"; then
        rm -f "$apps_file"
        # A completed scan that found nothing cannot match an exact name. That
        # is the same usage error as any other miss (§1.6 exit 2: nothing ran,
        # stdout empty), not a failed scan.
        echo "No application named '$wanted' is installed." >&2
        return 2
    fi
    rm -f "$apps_file"

    local resolve_rc=0
    uninstall_plan_resolve_app "$wanted" || resolve_rc=$?
    case "$resolve_rc" in
        0) ;;
        2)
            echo "No application named '$wanted' is installed." >&2
            echo "Run 'mo uninstall --list' for the exact names --plan accepts." >&2
            return 2
            ;;
        *)
            echo "More than one application matches '$wanted'; --plan needs exactly one." >&2
            echo "Run 'mo uninstall --list' for the exact names --plan accepts." >&2
            return 2
            ;;
    esac

    local records_file warn_file
    records_file=$(create_temp_file) || return 1
    warn_file=$(create_temp_file) || return 1
    : > "$warn_file"

    local build_rc=0
    uninstall_plan_build_records "$PLAN_APP_BUNDLE_ID" "$PLAN_APP_NAME" \
        "$PLAN_APP_PATH" "$records_file" "$warn_file" || build_rc=$?
    if [[ $build_rc -eq 124 || $build_rc -ge 128 ]]; then
        rm -f "$records_file" "$warn_file" 2> /dev/null || true # SAFE: exact tracked temp files created above
        return "$build_rc"
    fi
    [[ $build_rc -eq 0 ]] || printf 'discovery_incomplete\n' >> "$warn_file"

    uninstall_plan_has_unmeasured "$records_file" && printf 'size_unmeasured\n' >> "$warn_file"

    local scan_status="complete"
    [[ -s "$warn_file" ]] && scan_status="partial"

    local digest
    digest=$(uninstall_plan_digest "$PLAN_APP_BUNDLE_ID" "$PLAN_APP_PATH" "$records_file")

    uninstall_plan_emit_json "$mole_version" "$records_file" "$warn_file" \
        "$digest" "$scan_status"

    rm -f "$records_file" "$warn_file" 2> /dev/null || true # SAFE: exact tracked temp files created above
    return 0
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

# Turn one `plutil -extract ... xml1` array of dicts into US-separated records.
#
# There is no JSON parser in this repo and none in a stock macOS shell, but
# plutil reads JSON natively and its xml1 rendering puts one tag on one line,
# which an awk pass can read without guessing. One plutil fork for the whole
# array, not one per field: a 400-entry plan through per-key extraction would
# be thousands of forks (.claude/skills/bugs archetype 4 — "the bound is on
# the right command but the slow stage is the consumer").
#
# $1 is the comma-separated list of dict keys to emit, in order. A `<string>`
# value that does not close on its own line means the value contains a
# newline; awk exits 3 and the caller refuses the plan rather than acting on a
# record it cannot trust.
uninstall_apply_xml_records() {
    local keys="$1"
    awk -v keys="$keys" '
        function unesc(s) {
            gsub(/&lt;/, "<", s)
            gsub(/&gt;/, ">", s)
            gsub(/&quot;/, "\"", s)
            gsub(/&apos;/, "'"'"'", s)
            gsub(/&amp;/, "\\&", s)
            return s
        }
        function flush(  i, out) {
            out = ""
            for (i = 1; i <= nkeys; i++) {
                if (i > 1) out = out US
                out = out val[keyname[i]]
            }
            print out
        }
        BEGIN {
            US = sprintf("%c", 31)
            nkeys = split(keys, keyname, ",")
        }
        /<dict>/ {
            for (i = 1; i <= nkeys; i++) val[keyname[i]] = ""
            indict = 1
            curkey = ""
            next
        }
        /<\/dict>/ {
            if (indict) { flush(); indict = 0 }
            next
        }
        {
            line = $0
            if (match(line, /<key>[^<]*<\/key>/)) {
                curkey = substr(line, RSTART + 5, RLENGTH - 11)
                next
            }
            if (line ~ /<string>/) {
                if (line !~ /<\/string>[[:space:]]*$/) { exit 3 }
                sub(/^[[:space:]]*<string>/, "", line)
                sub(/<\/string>[[:space:]]*$/, "", line)
                val[curkey] = unesc(line)
                next
            }
            if (line ~ /<true\/>/) { val[curkey] = "true"; next }
            if (line ~ /<false\/>/) { val[curkey] = "false"; next }
            if (match(line, /<integer>[^<]*<\/integer>/)) {
                val[curkey] = substr(line, RSTART + 9, RLENGTH - 19)
                next
            }
        }
    '
}

# `selected` is a flat array of strings rather than of dicts, so it gets its
# own small reader. Same one-fork, fail-closed rules.
uninstall_apply_xml_strings() {
    awk '
        function unesc(s) {
            gsub(/&lt;/, "<", s)
            gsub(/&gt;/, ">", s)
            gsub(/&quot;/, "\"", s)
            gsub(/&apos;/, "'"'"'", s)
            gsub(/&amp;/, "\\&", s)
            return s
        }
        /<string>/ {
            if ($0 !~ /<\/string>[[:space:]]*$/) { exit 3 }
            line = $0
            sub(/^[[:space:]]*<string>/, "", line)
            sub(/<\/string>[[:space:]]*$/, "", line)
            print unesc(line)
        }
    '
}

# Read one scalar out of the submitted plan. A missing key returns nonzero.
uninstall_apply_scalar() {
    plutil -extract "$2" raw -o - "$1" 2> /dev/null
}

# Refuse the whole operation, on stdout as a §1.4 `failed` envelope. Every
# apply refusal happens before any deletion, so "nothing was deleted" is a
# statement of fact about the code path, not a hope.
uninstall_apply_refuse() {
    local mole_version="$1"
    local code="$2"
    local message="$3"
    uninstall_plan_emit_failed "$mole_version" "apply" "$code" "$message"
}

# §7.5 apply payload.
uninstall_apply_emit_json() {
    local mole_version="$1"
    local results_file="$2"
    local digest="$3"
    local result_mode="$4"
    local freed_bytes="$5"
    local scan_status="$6"
    local warn_file="$7"

    uninstall_plan_envelope_open "$mole_version" "apply" "$scan_status"
    printf ',"warnings":'
    uninstall_plan_emit_warnings "$warn_file"
    printf ',"error":null,"data":{"app":{"name":'
    history_json_string "$PLAN_APP_NAME"
    printf ',"bundle_id":'
    history_json_string "$PLAN_APP_BUNDLE_ID"
    printf ',"path":'
    history_json_string "$PLAN_APP_PATH"
    printf ',"uninstall_name":'
    history_json_string "$PLAN_APP_UNINSTALL_NAME"
    if [[ -n "$PLAN_APP_VERSION" ]]; then
        printf ',"version":'
        history_json_string "$PLAN_APP_VERSION"
    fi
    printf '},"plan_digest":'
    history_json_string "$digest"
    printf ',"mode":'
    history_json_string "$result_mode"
    printf ',"freed_bytes":%s,"results":[' "$freed_bytes"

    local first=1 line rid rpath outcome rsize rmessage
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\x1f' read -r rid rpath outcome rsize rmessage <<< "$line"
        [[ "$first" == "1" ]] || printf ','
        first=0
        printf '{"id":'
        history_json_string "$rid"
        printf ',"path":'
        history_json_string "$rpath"
        printf ',"outcome":'
        history_json_string "$outcome"
        if [[ "$rsize" =~ ^[0-9]+$ ]]; then
            printf ',"size_bytes":%s' "$rsize"
        fi
        if [[ -n "$rmessage" ]]; then
            printf ',"message":'
            history_json_string "$rmessage"
        fi
        printf '}'
    done < "$results_file"

    printf ']}}\n'
}

# `mole uninstall --apply-plan [--json] [--permanent] < plan-with-selection.json`
#
# §7.4/§7.5. Reads the whole plan document back on stdin, verifies it against
# fresh discovery, then deletes only the approved entries and reports one
# record for every entry the plan contained.
#
# This does NOT call remove_file_list. That helper returns a bare count and
# silently `continue`s past a path that fails validation or has disappeared,
# which cannot produce §7.5's per-entry `results` — the evidence that the
# approved set is the executed set. The loop below keeps per-id bookkeeping
# around the same audited sink (`mole_delete`, which owns validation, Trash
# routing, the forensic log and the dry-run gate) rather than reimplementing
# deletion.
uninstall_apply_command() {
    local mole_version
    mole_version=$(uninstall_list_mole_version)
    local result_mode success_outcome="removed"
    result_mode=$(uninstall_plan_delete_mode)
    [[ "$result_mode" != "trash" ]] || success_outcome="trashed"

    # --dry-run has no meaning here and is unsafe if accepted: mole_delete
    # returns success without deleting under MOLE_DRY_RUN, so every approved
    # entry would report `trashed` while still sitting on disk. `--plan` is
    # the dry run for this command.
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo "uninstall --apply-plan does not accept --dry-run; use --plan for a preview." >&2
        return 2
    fi

    # One tracked scratch directory for the whole run, so every refusal path
    # below tears down with a single statement and none of them can leak a
    # file by forgetting one name.
    local work_dir
    work_dir=$(create_temp_dir) || return 1
    local plan_file="$work_dir/plan.json"
    local submitted_file="$work_dir/submitted"
    local selected_file="$work_dir/selected"
    local current_file="$work_dir/current"
    local warn_file="$work_dir/warnings"
    local submitted_paths="$work_dir/submitted-paths"
    local current_paths="$work_dir/current-paths"
    local normalized_file="$work_dir/normalized"
    local results_file="$work_dir/results"
    : > "$warn_file"

    # The plan arrives on stdin. Reading a terminal here would block on EOF
    # with no output at all, which on the most destructive command in the tool
    # is indistinguishable from a hang. Say which cause was hit and what to
    # run next, per mole/CLAUDE.md's rule for refusing gates.
    if [[ -t 0 ]]; then
        echo "uninstall --apply-plan reads a plan document on stdin." >&2
        echo "Produce one with: mo uninstall --plan <NAME> --json" >&2
        rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
        return 2
    fi

    cat > "$plan_file"

    # `plutil -lint` is plist-only and rejects a JSON document outright, so the
    # validity gate is a no-output round trip through the JSON converter
    # instead. Verified against both a real plan and a malformed one.
    if ! plutil -convert json -o /dev/null "$plan_file" > /dev/null 2>&1; then
        echo "uninstall --apply-plan: stdin is not a valid JSON plan document." >&2
        rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
        return 2
    fi

    local submitted_digest app_name app_path app_bundle_id app_uninstall_name app_version
    submitted_digest=$(uninstall_apply_scalar "$plan_file" "data.plan_digest") || submitted_digest=""
    app_name=$(uninstall_apply_scalar "$plan_file" "data.app.name") || app_name=""
    app_path=$(uninstall_apply_scalar "$plan_file" "data.app.path") || app_path=""
    app_bundle_id=$(uninstall_apply_scalar "$plan_file" "data.app.bundle_id") || app_bundle_id=""
    app_uninstall_name=$(uninstall_apply_scalar "$plan_file" "data.app.uninstall_name") || app_uninstall_name=""
    app_version=$(uninstall_apply_scalar "$plan_file" "data.app.version") || app_version=""

    if [[ -z "$submitted_digest" || -z "$app_path" || -z "$app_name" ]]; then
        echo "uninstall --apply-plan: the plan is missing data.plan_digest or data.app." >&2
        rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
        return 2
    fi

    # The submitted app identity is an INPUT to re-discovery, so it cannot be
    # taken on trust: a plan naming an arbitrary directory as `app.path` would
    # otherwise make that directory an entry of the recomputed plan. Pin it to
    # a real application bundle before anything else runs.
    if [[ "$app_path" != *.app || ! -d "$app_path" ]]; then
        echo "uninstall --apply-plan: data.app.path is not an installed application bundle." >&2
        rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
        return 2
    fi
    if [[ -n "$app_bundle_id" && "$app_bundle_id" != "unknown" ]]; then
        local on_disk_bundle_id=""
        on_disk_bundle_id=$(plutil -extract CFBundleIdentifier raw \
            "$app_path/Contents/Info.plist" 2> /dev/null || echo "")
        if [[ -n "$on_disk_bundle_id" && "$on_disk_bundle_id" != "$app_bundle_id" ]]; then
            echo "uninstall --apply-plan: data.app.bundle_id does not match the bundle at data.app.path." >&2
            rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
            return 2
        fi
    fi

    # §7.7: the plan records which delete-mode semantics its `requires_sudo`
    # verdicts were computed under. A plan built for one mode and applied under
    # the other is not interpretable, and the refusal must name that cause
    # rather than fall through to a generic privilege error (F-041). Checked
    # here, before re-discovery: nothing has been deleted at this point and
    # nothing after this point can run.
    #
    # `delete_mode` is deliberately NOT part of `plan_digest` (§7.7), so a
    # mismatch can never surface as `plan_stale`.
    local submitted_mode
    submitted_mode=$(uninstall_apply_scalar "$plan_file" "data.delete_mode") || submitted_mode=""
    if [[ -z "$submitted_mode" ]]; then
        uninstall_apply_refuse "$mole_version" "plan_mode_mismatch" \
            "the plan does not record data.delete_mode; nothing was deleted"
        rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
        return 2
    fi
    if [[ "$submitted_mode" != "$result_mode" ]]; then
        uninstall_apply_refuse "$mole_version" "plan_mode_mismatch" \
            "the plan was built for delete mode '$submitted_mode' but this run is '$result_mode'; nothing was deleted"
        rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
        return 2
    fi

    local parse_rc=0
    plutil -extract data.entries xml1 -o - "$plan_file" 2> /dev/null |
        uninstall_apply_xml_records "id,path,size_bytes,size_known,protected" \
            > "$submitted_file" || parse_rc=$?
    if [[ $parse_rc -ne 0 ]]; then
        echo "uninstall --apply-plan: data.entries could not be read." >&2
        rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
        return 2
    fi

    # `selected` is required (§7.4). An absent key is a caller defect, not an
    # empty selection: refuse rather than silently apply nothing.
    if ! plutil -extract data.selected xml1 -o - "$plan_file" > /dev/null 2>&1; then
        echo "uninstall --apply-plan: the plan has no data.selected array." >&2
        rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
        return 2
    fi
    parse_rc=0
    plutil -extract data.selected xml1 -o - "$plan_file" 2> /dev/null |
        uninstall_apply_xml_strings > "$selected_file" || parse_rc=$?
    if [[ $parse_rc -ne 0 ]]; then
        echo "uninstall --apply-plan: data.selected could not be read." >&2
        rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
        return 2
    fi

    PLAN_APP_NAME="$app_name"
    PLAN_APP_PATH="$app_path"
    PLAN_APP_BUNDLE_ID="$app_bundle_id"
    PLAN_APP_UNINSTALL_NAME="${app_uninstall_name:-$app_name}"
    PLAN_APP_VERSION="$app_version"

    # §7.2 steps 1 and 2: re-run discovery and recompute the digest over the
    # CURRENT discovery. Never over the submitted entries — hashing what the
    # caller sent would only verify the caller against itself.
    local build_rc=0
    uninstall_plan_build_records "$app_bundle_id" "$app_name" "$app_path" \
        "$current_file" "$warn_file" || build_rc=$?
    if [[ $build_rc -eq 124 || $build_rc -ge 128 ]]; then
        rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
        return "$build_rc"
    fi
    if [[ $build_rc -ne 0 ]]; then
        # A truncated re-discovery cannot verify anything. Refuse before any
        # deletion rather than compare a digest against a partial scan.
        uninstall_apply_refuse "$mole_version" "scan_failed" \
            "leftover discovery did not complete; nothing was deleted"
        rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
        return 1
    fi

    local current_digest
    current_digest=$(uninstall_plan_digest "$app_bundle_id" "$app_path" "$current_file")

    if [[ "$current_digest" != "$submitted_digest" ]]; then
        uninstall_apply_refuse "$mole_version" "plan_stale" \
            "the submitted plan no longer matches what is on disk; nothing was deleted"
        rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
        return 4
    fi

    # The digest already proves set equality of (path, size_bytes,
    # size_known). Assert the path lists literally too: it costs one cmp, and
    # it turns a digest collision or a builder defect into a refusal instead
    # of a deletion nobody previewed.
    local rec sid spath ssize sknown sprot rid
    while IFS= read -r rec; do
        [[ -n "$rec" ]] || continue
        IFS=$'\x1f' read -r sid spath ssize sknown sprot <<< "$rec"
        printf '%s\n' "$spath"
    done < "$submitted_file" | LC_ALL=C sort > "$submitted_paths"
    while IFS= read -r rec; do
        [[ -n "$rec" ]] || continue
        IFS=$'\x1f' read -r spath _ <<< "$rec"
        printf '%s\n' "$spath"
    done < "$current_file" | LC_ALL=C sort > "$current_paths"
    if ! cmp -s "$submitted_paths" "$current_paths"; then
        uninstall_apply_refuse "$mole_version" "plan_stale" \
            "the submitted plan's paths do not match discovery; nothing was deleted"
        rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
        return 4
    fi

    # Normalise the submitted entries, recomputing every id from its own path.
    # The submitted id is display data, never authority: an entry whose id was
    # tampered with simply stops matching anything in `selected`, and the
    # selection check below then refuses the run.
    #
    # `protected` is the union of the submitted flag and the CURRENT verdict.
    # Re-validation at apply time is what makes the deletion safe (§7.2), and
    # a plan can only ever under-report a refusal.
    local protected_index="|" submitted_index="|" selected_index="|"
    local cur_prot_index="|" sudo_index="|" cpath cprot csudo cid
    while IFS= read -r rec; do
        [[ -n "$rec" ]] || continue
        IFS=$'\x1f' read -r cpath _ _ _ cprot csudo _ <<< "$rec"
        [[ "$cprot" == "true" || "$csudo" == "true" ]] || continue
        cid=$(uninstall_plan_entry_id "$cpath")
        [[ "$cprot" != "true" ]] || cur_prot_index+="$cid|"
        [[ "$csudo" != "true" ]] || sudo_index+="$cid|"
    done < "$current_file"

    : > "$normalized_file"
    while IFS= read -r rec; do
        [[ -n "$rec" ]] || continue
        IFS=$'\x1f' read -r sid spath ssize sknown sprot <<< "$rec"
        rid=$(uninstall_plan_entry_id "$spath")
        submitted_index+="$rid|"
        if [[ "$sprot" == "true" || "$cur_prot_index" == *"|$rid|"* ]]; then
            protected_index+="$rid|"
        fi
        printf '%s\x1f%s\n' "$rid" "$spath" >> "$normalized_file"
    done < "$submitted_file"

    # §7.4: an id that is not in `entries`, or one whose entry is protected,
    # refuses the WHOLE operation before anything is deleted. Not a partial
    # skip — a caller that asked for something impossible has a defect, and
    # applying the rest of its list would hide it.
    local sel
    while IFS= read -r sel; do
        [[ -n "$sel" ]] || continue
        if [[ "$submitted_index" != *"|$sel|"* ]]; then
            uninstall_apply_refuse "$mole_version" "unknown_selection_id" \
                "a selected id is not present in the plan's entries; nothing was deleted"
            rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
            return 2
        fi
        if [[ "$protected_index" == *"|$sel|"* ]]; then
            uninstall_apply_refuse "$mole_version" "protected_selection" \
                "a selected entry is protected and cannot be removed; nothing was deleted"
            rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
            return 2
        fi
        # §7.6 / §1.6 exit 3: privilege required and unavailable, BEFORE any
        # deletion. This command never prompts and never escalates — it is
        # non-interactive by contract (§7.2) and F-003 leaves escalation
        # unsolved — so a selected entry that needs privilege can only ever
        # fail. Refusing the run up front is the honest answer; deleting the
        # rest and reporting this one as `failed` would leave the app half
        # removed on the strength of a preview that said otherwise. The plan
        # tells the caller which entries these are through `requires_sudo`.
        if [[ "$sudo_index" == *"|$sel|"* ]]; then
            uninstall_apply_refuse "$mole_version" "permission" \
                "a selected entry needs elevated privilege, which this command never acquires; nothing was deleted"
            rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
            return 3
        fi
        selected_index+="$sel|"
    done < "$selected_file"

    # Deletion. One record per submitted entry, in the plan's own order,
    # including the entries the caller did not select — §7.5 is explicit that
    # a bare count cannot distinguish 12 approved from 40 deleted.
    : > "$results_file"
    local freed_bytes=0 interrupted=0 any_failed=0 actual_bytes delete_rc
    while IFS= read -r rec; do
        [[ -n "$rec" ]] || continue
        IFS=$'\x1f' read -r rid spath <<< "$rec"

        if [[ $interrupted -eq 1 ]]; then
            printf '%s\x1f%s\x1ffailed\x1f\x1fnot attempted: the run was interrupted\n' \
                "$rid" "$spath" >> "$results_file"
            continue
        fi

        if [[ "$selected_index" != *"|$rid|"* ]]; then
            printf '%s\x1f%s\x1fnot_selected\x1f\x1f\n' "$rid" "$spath" >> "$results_file"
            continue
        fi

        if [[ ! -e "$spath" && ! -L "$spath" ]]; then
            printf '%s\x1f%s\x1fmissing\x1f\x1f\n' "$rid" "$spath" >> "$results_file"
            continue
        fi

        # Third and final validation of this path (plan build, selection
        # gate, here). mole_delete validates again internally; this call is
        # what lets the result say `refused_protected` instead of `failed`.
        if ! validate_path_for_deletion "$spath" 2> /dev/null; then
            printf '%s\x1f%s\x1frefused_protected\x1f\x1fthe path failed validation at the deletion boundary\n' \
                "$rid" "$spath" >> "$results_file"
            continue
        fi

        actual_bytes=$(uninstall_plan_measure_bytes "$spath") || actual_bytes=""

        delete_rc=0
        mole_delete "$spath" "false" || delete_rc=$?

        if [[ $delete_rc -eq 124 || $delete_rc -ge 128 ]]; then
            interrupted=1
            printf '%s\x1f%s\x1ffailed\x1f\x1finterrupted before this entry was removed\n' \
                "$rid" "$spath" >> "$results_file"
            continue
        fi
        if [[ $delete_rc -ne 0 ]]; then
            any_failed=1
            printf '%s\x1f%s\x1ffailed\x1f\x1fremoval failed (status %s)\n' \
                "$rid" "$spath" "$delete_rc" >> "$results_file"
            continue
        fi

        [[ "$actual_bytes" =~ ^[0-9]+$ ]] && freed_bytes=$((freed_bytes + actual_bytes))
        printf '%s\x1f%s\x1f%s\x1f%s\x1f\n' "$rid" "$spath" "$success_outcome" "$actual_bytes" >> "$results_file"
    done < "$normalized_file"

    local scan_status="complete"
    [[ $any_failed -eq 1 || $interrupted -eq 1 ]] && scan_status="partial"

    uninstall_apply_emit_json "$mole_version" "$results_file" "$submitted_digest" \
        "$result_mode" "$freed_bytes" "$scan_status" "$warn_file"

    rm -rf "$work_dir" 2> /dev/null || true # SAFE: tracked scratch dir this function created
    [[ $interrupted -eq 1 ]] && return 130
    return 0
}

main() {
    # Set current command for operation logging
    export MOLE_CURRENT_COMMAND="uninstall"
    log_operation_session_start "uninstall"

    # Default to Trash routing so an accidental uninstall is recoverable.
    # The caller can opt back into rm -rf with --permanent. See #723.
    export MOLE_DELETE_MODE="${MOLE_DELETE_MODE:-trash}"

    # Parse flags and collect app name arguments
    local -a app_name_args=()
    local list_mode=0
    local list_json=0
    # CONTRACT.md §7. --plan takes the app's uninstall_name as its NEXT
    # argument rather than a combined --plan=NAME form: an app name can
    # contain '=' and every other flag in this parser is a bare word, so the
    # separate-argument form is the one that stays unambiguous against the
    # positional app-name arguments below.
    local plan_mode=0
    local plan_target=""
    local expect_plan_target=0
    local apply_plan_mode=0
    for arg in "$@"; do
        if [[ $expect_plan_target -eq 1 ]]; then
            plan_target="$arg"
            expect_plan_target=0
            continue
        fi
        case "$arg" in
            "--help" | "-h")
                show_uninstall_help
                exit 0
                ;;
            "--debug")
                export MO_DEBUG=1
                ;;
            "--dry-run" | "-n")
                export MOLE_DRY_RUN=1
                ;;
            "--permanent")
                export MOLE_DELETE_MODE="permanent"
                ;;
            "--list")
                list_mode=1
                ;;
            "--json")
                list_json=1
                ;;
            "--plan")
                plan_mode=1
                expect_plan_target=1
                ;;
            "--apply-plan")
                apply_plan_mode=1
                ;;
            "--whitelist")
                echo "Unknown uninstall option: $arg"
                echo "Whitelist management is currently supported by: mo clean --whitelist / mo optimize --whitelist"
                echo "Use 'mo uninstall --help' for supported options."
                exit 1
                ;;
            -*)
                echo "Unknown uninstall option: $arg"
                echo "Use 'mo uninstall --help' for supported options."
                exit 1
                ;;
            *)
                app_name_args+=("$arg")
                ;;
        esac
    done

    if [[ $expect_plan_target -eq 1 ]]; then
        echo "uninstall --plan needs an uninstall name; see 'mo uninstall --list'." >&2
        return 2
    fi
    if [[ $plan_mode -eq 1 && $apply_plan_mode -eq 1 ]]; then
        echo "uninstall: --plan and --apply-plan are separate steps; pass one." >&2
        return 2
    fi
    if [[ ($plan_mode -eq 1 || $apply_plan_mode -eq 1) && ${#app_name_args[@]} -gt 0 ]]; then
        echo "uninstall: --plan/--apply-plan do not take positional app names." >&2
        return 2
    fi

    # --plan / --apply-plan short-circuit before the interactive scan loop, the
    # same way --list does: both are non-interactive by contract (§7.2) and
    # must never reach a prompt. --plan additionally never deletes anything.
    if [[ $plan_mode -eq 1 ]]; then
        uninstall_plan_command "$plan_target"
        return $?
    fi
    if [[ $apply_plan_mode -eq 1 ]]; then
        uninstall_apply_command
        return $?
    fi

    # --list short-circuits before any destructive code. Read-only path:
    # scan, resolve uninstall names, print table or JSON, exit 0.
    if [[ $list_mode -eq 1 ]]; then
        uninstall_list_apps "$list_json"
        return $?
    fi

    hide_cursor
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, No app files or settings will be modified"
        printf '\n'
    fi

    # Direct uninstall by app name
    if [[ ${#app_name_args[@]} -gt 0 ]]; then
        local apps_file=""
        if ! apps_file=$(scan_applications); then
            uninstall_abort "could not complete the application scan"
            return 1
        fi
        if [[ ! -f "$apps_file" ]]; then
            uninstall_abort "application scan produced no list"
            return 1
        fi
        if ! load_applications "$apps_file"; then
            rm -f "$apps_file"
            uninstall_abort "no applications available for uninstallation"
            return 1
        fi

        match_apps_by_name "${app_name_args[@]}"
        rm -f "$apps_file"

        if [[ ${#selected_apps[@]} -eq 0 ]]; then
            show_cursor
            echo "No matching applications found."
            return 1
        fi

        show_cursor
        clear_screen
        local selection_count=${#selected_apps[@]}
        echo -e "${BLUE}${ICON_CONFIRM}${NC} Matched ${selection_count} app(s):"
        local index=1
        for selected_app in "${selected_apps[@]}"; do
            IFS='|' read -r _ app_path app_name _ size last_used _ <<< "$selected_app"
            local size_display
            size_display=$(uninstall_normalize_size_display "$size" "$app_path")
            local last_display
            last_display=$(uninstall_normalize_last_used_display "$last_used")
            printf "%d. %s  %s  |  Last: %s\n" "$index" "$app_name" "$size_display" "$last_display"
            ((index++))
        done

        printf '\n'
        printf "Proceed with uninstallation? [y/N] "
        local confirm
        read -r confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Aborted."
            return 0
        fi

        batch_uninstall_applications
        return 0
    fi

    local first_scan=true
    local cached_apps_file=""
    local cached_inventory_fingerprint=""
    unset MOLE_INLINE_LOADING MOLE_MANAGED_ALT_SCREEN MOLE_ALT_SCREEN_ACTIVE
    while true; do
        unset MOLE_INLINE_LOADING

        # Keep scanning and selection on one alternate screen. Entering the
        # selector only after the scan leaves the primary-screen cursor below
        # the scan progress; restoring it on cancel then creates a large blank
        # gap before the next shell prompt (#1194).
        start_uninstall_interactive_screen

        if [[ $first_scan == false ]]; then
            echo -e "${GRAY}Checking application list...${NC}" >&2
        fi
        first_scan=false

        local apps_file=""
        local reused_app_cache=false
        if [[ -n "$cached_apps_file" && -f "$cached_apps_file" && -n "$cached_inventory_fingerprint" ]]; then
            local current_inventory_fingerprint
            current_inventory_fingerprint=$(uninstall_app_inventory_fingerprint 2> /dev/null || echo "")
            if uninstall_inventory_can_reuse_cached_apps "$cached_inventory_fingerprint" "$current_inventory_fingerprint"; then
                apps_file="$cached_apps_file"
                reused_app_cache=true
                cached_inventory_fingerprint="$current_inventory_fingerprint"
            fi
        fi

        if [[ "$reused_app_cache" != "true" ]]; then
            if [[ -n "$cached_apps_file" && -f "$cached_apps_file" ]]; then
                rm -f "$cached_apps_file" 2> /dev/null || true
            fi

            local scan_abort_reason=""
            if ! apps_file=$(scan_applications); then
                scan_abort_reason="could not complete the application scan"
            elif [[ ! -f "$apps_file" ]]; then
                scan_abort_reason="application scan produced no list"
            fi
            if [[ -n "$scan_abort_reason" ]]; then
                uninstall_abort "$scan_abort_reason"
                rm -f "$apps_file"
                [[ "$apps_file" == "$cached_apps_file" ]] && cached_apps_file=""
                return 1
            fi

            cached_apps_file="$apps_file"
            cached_inventory_fingerprint=$(uninstall_app_inventory_fingerprint 2> /dev/null || echo "")
        fi

        if ! load_applications "$apps_file"; then
            rm -f "$apps_file"
            [[ "$apps_file" == "$cached_apps_file" ]] && cached_apps_file=""
            uninstall_abort "no applications available for uninstallation"
            return 1
        fi

        # Keystrokes typed during the scan/load phase must not leak into the
        # selector. A queued Enter would confirm whichever app is highlighted
        # first and drop the user straight into the destructive path. See #726.
        drain_pending_input 0.2

        set +e
        select_apps_for_uninstall
        local exit_code=$?
        set -e

        if [[ $exit_code -ne 0 ]]; then
            rm -f "$apps_file"
            [[ "$apps_file" == "$cached_apps_file" ]] && cached_apps_file=""
            if [[ "${_MOLE_MENU_USER_QUIT:-0}" == "1" ]]; then
                # A deliberate q is a cancel, not a failure: leave quietly
                # with success, matching mole's other cancel flows. Only a
                # selector that broke gets the visible abort below.
                stop_uninstall_interactive_screen
                show_cursor
                return 0
            fi
            uninstall_abort "application selection did not complete"
            return 1
        fi

        stop_uninstall_interactive_screen
        show_cursor
        clear_screen
        printf '\033[2J\033[H' >&2
        local selection_count=${#selected_apps[@]}
        if [[ $selection_count -eq 0 ]]; then
            echo "No apps selected"
            continue
        fi
        echo -e "${BLUE}${ICON_CONFIRM}${NC} Selected ${selection_count} apps:"
        local -a summary_rows=()
        local max_name_display_width=0
        local max_size_width=0
        local max_last_width=0
        for selected_app in "${selected_apps[@]}"; do
            IFS='|' read -r _ app_path app_name _ size last_used _ <<< "$selected_app"
            local name_width=$(get_display_width "$app_name")
            [[ $name_width -gt $max_name_display_width ]] && max_name_display_width=$name_width
            local size_display
            size_display=$(uninstall_normalize_size_display "$size" "$app_path")
            [[ ${#size_display} -gt $max_size_width ]] && max_size_width=${#size_display}
            local last_display
            last_display=$(uninstall_normalize_last_used_display "$last_used")
            [[ ${#last_display} -gt $max_last_width ]] && max_last_width=${#last_display}
        done
        ((max_size_width < 5)) && max_size_width=5
        ((max_last_width < 5)) && max_last_width=5
        ((max_name_display_width < 16)) && max_name_display_width=16

        local term_width=$(tput cols 2> /dev/null || echo 100)
        local available_for_name=$((term_width - 17 - max_size_width - max_last_width))

        local min_name_width=24
        if [[ $term_width -ge 120 ]]; then
            min_name_width=50
        elif [[ $term_width -ge 100 ]]; then
            min_name_width=42
        elif [[ $term_width -ge 80 ]]; then
            min_name_width=30
        fi

        local name_trunc_limit=$max_name_display_width
        [[ $name_trunc_limit -lt $min_name_width ]] && name_trunc_limit=$min_name_width
        [[ $name_trunc_limit -gt $available_for_name ]] && name_trunc_limit=$available_for_name
        [[ $name_trunc_limit -gt 60 ]] && name_trunc_limit=60

        max_name_display_width=0

        for selected_app in "${selected_apps[@]}"; do
            IFS='|' read -r epoch app_path app_name bundle_id size last_used size_kb <<< "$selected_app"

            local display_name
            display_name=$(truncate_by_display_width "$app_name" "$name_trunc_limit")

            local current_width
            current_width=$(get_display_width "$display_name")
            [[ $current_width -gt $max_name_display_width ]] && max_name_display_width=$current_width

            local size_display
            size_display=$(uninstall_normalize_size_display "$size" "$app_path")

            local last_display
            last_display=$(uninstall_normalize_last_used_display "$last_used")

            summary_rows+=("$display_name|$size_display|$last_display")
        done

        ((max_name_display_width < 16)) && max_name_display_width=16

        local index=1
        for row in "${summary_rows[@]}"; do
            IFS='|' read -r name_cell size_cell last_cell <<< "$row"
            local name_display_width
            name_display_width=$(get_display_width "$name_cell")

            # Get byte count for printf width calculation
            local old_lc="${LC_ALL:-}"
            export LC_ALL=C
            local name_byte_count=${#name_cell}
            if [[ -n "$old_lc" ]]; then
                export LC_ALL="$old_lc"
            else
                unset LC_ALL
            fi

            local padding_needed=$((max_name_display_width - name_display_width))
            local printf_name_width=$((name_byte_count + padding_needed))

            printf "%d. %-*s  %*s  |  Last: %s\n" "$index" "$printf_name_width" "$name_cell" "$max_size_width" "$size_cell" "$last_cell"
            ((index++))
        done

        batch_uninstall_applications

        # A nested command may have returned the controlling terminal to the
        # parent shell. Reading while Mole is no longer the foreground process
        # group would suspend the completed uninstall with SIGTTIN. The removal
        # is already finished, so exit cleanly instead of touching terminal input.
        if ! mole_tty_is_foreground; then
            show_cursor
            return 0
        fi

        local _countdown=5
        local _key=""
        local _pressed=false
        while [[ $_countdown -gt 0 ]]; do
            printf "\r${GRAY}Press Enter to return to the app list, press q to exit (%d)${NC} " "$_countdown"
            if IFS= read -r -s -n1 -t 1 _key; then
                _pressed=true
                break
            fi
            ((_countdown--))
        done
        printf "\n"
        drain_pending_input

        if [[ "$_pressed" == "true" && -z "$_key" ]]; then
            :
        else
            show_cursor
            return 0
        fi

    done
}

# Run only when executed; sourcing loads definitions for tests. Kept on one
# line because test harnesses slice this file with sed/awk anchored on the
# `main "$@"` sentinel, and a multi-line guard leaves them an unclosed `if`.
[[ "${BASH_SOURCE[0]}" != "$0" ]] || main "$@"
