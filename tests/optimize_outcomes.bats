#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT
}

@test "optimize outcomes record one result per task" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"

optimize_outcomes_reset
optimize_task_start
optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
optimize_task_finish system_maintenance

[[ "$(optimize_outcome_count applied)" == "1" ]] || exit 1
[[ "$(optimize_outcome_count unchanged)" == "0" ]] || exit 1
[[ "$(optimize_outcome_total)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "optimize outcomes distinguish unresolved attention from failure" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"

optimize_outcomes_reset
optimize_task_start
optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_ATTENTION"
optimize_task_finish login_items_audit

[[ "$(optimize_outcome_count attention)" == "1" ]] || exit 1
[[ "$(optimize_outcome_count failed)" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "optimize outcome counts give failures precedence over partial changes" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"

optimize_outcomes_reset
optimize_task_start
optimize_task_result_from_counts 2 1 0
optimize_task_finish sqlite_vacuum

[[ "$(optimize_outcome_count failed)" == "1" ]] || exit 1
[[ "$(optimize_outcome_count applied)" == "0" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "optimize run success rejects failed tasks but allows attention" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"

optimize_task_start
optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_ATTENTION"
optimize_task_finish login_items_audit
optimize_outcomes_succeeded || exit 1

optimize_task_start
optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
optimize_task_finish periodic_maintenance
if optimize_outcomes_succeeded; then
    exit 1
fi
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "optimize outcomes reject invalid and duplicate task results" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"

if optimize_task_result invented; then
    echo "invalid outcome accepted"
    exit 1
fi

optimize_task_start
optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
if optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"; then
    echo "second task outcome accepted"
    exit 1
fi
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Invalid optimize task outcome: invented"* ]] || return 1
	[[ "$output" == *"Optimize task outcome is already set: unchanged"* ]] || return 1
}

@test "optimize outcomes reject results outside an active task" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"

if optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"; then
    echo "inactive task outcome accepted"
    exit 1
fi
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Optimize task was not started"* ]] || return 1
}

@test "optimize outcomes reject missing and duplicate task records" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"

optimize_task_start
if optimize_task_finish periodic_maintenance; then
    echo "missing task outcome accepted"
    exit 1
fi

optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
optimize_task_finish periodic_maintenance
optimize_task_start
optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
if optimize_task_finish periodic_maintenance; then
    echo "duplicate task record accepted"
    exit 1
fi
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"Optimize task did not report an outcome: periodic_maintenance"* ]] || return 1
	[[ "$output" == *"Optimize task outcome is already recorded: periodic_maintenance"* ]] || return 1
}

@test "optimize outcomes expose failed actions without leaking ledger storage" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"

for record in "cache_refresh:applied" "disk_verify:failed" "login_items_audit:attention" "periodic_maintenance:failed"; do
    action=${record%%:*}
    outcome=${record#*:}
    optimize_task_start
    optimize_task_result "$outcome"
    optimize_task_finish "$action"
done

expected=$(printf 'disk_verify\nperiodic_maintenance\n')
[[ "$(optimize_failed_actions)" == "$expected" ]] || exit 1
if grep -q 'MOLE_OPTIMIZE_RESULT_' "$PROJECT_ROOT/bin/optimize.sh"; then
    echo "optimize command reads private outcome storage"
    exit 1
fi
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# F-083 — a preview must not carry completed-action prose
# ---------------------------------------------------------------------------

@test "F-083: an applied outcome carries no detail in preview mode" {
	# The four strings F-083 named — "DNS cache flushed", "LaunchServices
	# repaired", ".DS_Store prevention enabled on network & USB volumes",
	# "QuickLook thumbnails refreshed" — are past tense, and after a dry run
	# none of them happened. `detail` is C (CONTRACT.md §8.5), so the honest
	# preview asserts nothing rather than asserting something untrue.
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MOLE_DRY_RUN=1
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"

optimize_outcomes_reset
optimize_task_start
optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED" "DNS cache flushed"
optimize_task_finish system_maintenance

[[ -z "${MOLE_OPTIMIZE_RESULT_DETAILS[0]}" ]] || {
    printf 'a preview reported a completed action: %s\n' "${MOLE_OPTIMIZE_RESULT_DETAILS[0]}" >&2
    exit 1
}
[[ "$(optimize_outcome_count applied)" == "1" ]] || exit 1
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "F-083: a real run's applied outcome keeps its detail" {
	# The suppression must be conditional on preview mode. After a real run
	# "DNS cache flushed" is simply true, and dropping it would hide real
	# signal.
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MOLE_DRY_RUN=0
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"

optimize_outcomes_reset
optimize_task_start
optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED" "DNS cache flushed"
optimize_task_finish system_maintenance

[[ "${MOLE_OPTIMIZE_RESULT_DETAILS[0]}" == "DNS cache flushed" ]] || {
    printf 'a real run lost its detail: %s\n' "${MOLE_OPTIMIZE_RESULT_DETAILS[0]}" >&2
    exit 1
}
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}

@test "F-083: preview keeps every non-applied detail, including the failed ones" {
	# Only `applied` is counterfactual in a preview. A failed scan really did
	# fail during the dry run, and its detail is the §8.5 task_failed warning
	# message — suppressing it would suppress the warning's text.
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MOLE_DRY_RUN=1
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"

optimize_outcomes_reset
for pair in \
    "$MOLE_OPTIMIZE_OUTCOME_FAILED:Failed to scan old saved states:saved_state_cleanup" \
    "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED:All preference files valid:fix_broken_configs" \
    "$MOLE_OPTIMIZE_OUTCOME_SKIPPED:Disk verify skipped:disk_verify" \
    "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE:Not available on this macOS version:periodic_maintenance" \
    "$MOLE_OPTIMIZE_OUTCOME_ATTENTION:1 broken login item(s):login_items_audit"; do
    outcome="${pair%%:*}"
    rest="${pair#*:}"
    detail="${rest%:*}"
    action="${rest##*:}"
    optimize_task_start
    optimize_task_result "$outcome" "$detail"
    optimize_task_finish "$action"
done

index=0
for expected in \
    "Failed to scan old saved states" \
    "All preference files valid" \
    "Disk verify skipped" \
    "Not available on this macOS version" \
    "1 broken login item(s)"; do
    [[ "${MOLE_OPTIMIZE_RESULT_DETAILS[$index]}" == "$expected" ]] || {
        printf 'detail %s was dropped from a preview: got %s\n' \
            "$expected" "${MOLE_OPTIMIZE_RESULT_DETAILS[$index]}" >&2
        exit 1
    }
    index=$((index + 1))
done
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}
