package main

import (
	"fmt"
	"sort"

	"github.com/tw93/mole/internal/contract"
)

// fastSkippedScopes lists every collector `collectFull` runs and `collectFast`
// does not, keyed by the JSON field it fills (metrics.go's struct tags), not
// the Go function name -- CONTRACT.md §3.3/F-048's collector_pending keys its
// `scope` off the payload key so Molehouse can match it directly.
//
// "hardware" is included even though it isn't itself a collectConcurrently
// task: refreshHardware only fires on a full collect (snapshotFromMetrics),
// so on a fast round with no prior enrichment cache it is left at its zero
// value exactly like proxy/thermal/trash_size are (F-048).
//
// "sensors" is deliberately absent. It is disabled upstream (commented out
// in collectFull itself) and is null in *every* frame, fast or full alike --
// marking it collector_pending would promise a resolution that never comes,
// which is the opposite of what "pending" means. This mirrors §2.4's own
// carve-out for sensors on the one-shot payload and is a judgement call
// flagged in the M1-T7 report, since a literal reading of §3.3's five-null
// list would include it.
var fastSkippedScopes = []string{"gpu", "batteries", "bluetooth", "proxy", "thermal", "trash_size", "hardware"}

// fastPendingScopes returns the scopes a fast collection round did not run
// and that are not yet backed by a prior full collect's enrichment cache.
//
// Once `hadEnrichment` is true, applyEnrichment backfills every skipped
// field from the last full collect's cached values -- correct, not a
// fabricated zero -- so nothing is pending. Only the very first collection
// of a Collector's lifetime (no cache to fall back on) leaves these fields
// at their zero value, which is F-048's actual failure mode. Verified
// against a real watch capture: only frame 0 shows the five null arrays;
// every later fast-mode frame is cache-backed and correctly reports
// complete.
func fastPendingScopes(includeProcesses, hadEnrichment bool) []string {
	if hadEnrichment {
		return nil
	}
	scopes := make([]string, 0, len(fastSkippedScopes)+1)
	scopes = append(scopes, fastSkippedScopes...)
	if !includeProcesses {
		scopes = append(scopes, "top_processes")
	}
	return scopes
}

// buildWarnings turns a collectConcurrently failure (if any) and a pending
// list into CONTRACT.md §1.4 warnings[], always non-nil so it marshals to
// `[]`, never `null`.
func buildWarnings(collectErr error, pending []string) []contract.Warning {
	warnings := make([]contract.Warning, 0)

	if cf, ok := collectErr.(*collectionFailures); ok && cf != nil {
		failures := make([]collectorFailure, len(cf.failures))
		copy(failures, cf.failures)
		sort.Slice(failures, func(i, j int) bool { return failures[i].scope < failures[j].scope })
		for _, f := range failures {
			warnings = append(warnings, contract.Warning{
				Code:    contract.WarnCollectorFailed,
				Scope:   f.scope,
				Message: fmt.Sprintf("%s collector failed: %v", f.scope, f.err),
			})
		}
	}

	pendingSorted := append([]string(nil), pending...)
	sort.Strings(pendingSorted)
	for _, scope := range pendingSorted {
		warnings = append(warnings, contract.Warning{
			Code:    contract.WarnCollectorPending,
			Scope:   scope,
			Message: "initial frame, collector still running",
		})
	}

	return warnings
}

// scanStatusForWarnings is CONTRACT.md §2.4 / §3.3: any warning at all
// (failed or pending) makes the scan partial. `status` has no failed state
// (§1.5 of the M1-T7 brief) -- its collectors leave zero values rather than
// aborting, so a snapshot always exists.
func scanStatusForWarnings(warnings []contract.Warning) contract.ScanStatus {
	if len(warnings) == 0 {
		return contract.ScanComplete
	}
	return contract.ScanPartial
}

// applyEnvelope stamps the three NEW top-level fields onto a snapshot in
// place.
func applyEnvelope(snapshot *MetricsSnapshot, collectErr error, pending []string) {
	warnings := buildWarnings(collectErr, pending)
	snapshot.SchemaVersion = contract.SchemaVersion
	snapshot.Warnings = warnings
	snapshot.ScanStatus = scanStatusForWarnings(warnings)
}
