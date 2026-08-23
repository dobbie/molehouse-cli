// Package contract holds the shared pieces of CONTRACT.md that `status` and
// `analyze` both need: the top-level envelope fields §1.5 requires even on
// the two commands that otherwise stay flat, the §1.4 Warning shape, and the
// warning-code constants each command's own §2.4/§3.3/§4.6 defines.
//
// Both commands are separate `package main` binaries (M1-T7 is the project's
// first Go task, so there is no prior cross-command package to extend other
// than internal/units). Duplicating these types in cmd/status and cmd/analyze
// is exactly how the two payloads drift apart from each other and from
// CONTRACT.md; this package is the one place both read from.
package contract

// SchemaVersion is CONTRACT.md §1.2's payload schema_version, pinned at 1 by
// tests/schemas/envelope.schema.json ("const": 1).
//
// This is NOT cmd/analyze/cache.go's cacheSchemaVersion (currently 3) -- that
// constant versions the on-disk overview size cache, a private implementation
// detail with no relationship to this one. Do not reuse it, do not renumber
// it to match, and do not let the two meet.
const SchemaVersion = 1

// ScanStatus is CONTRACT.md §1.4's scan_status enum.
type ScanStatus string

const (
	ScanComplete ScanStatus = "complete"
	ScanPartial  ScanStatus = "partial"
	ScanFailed   ScanStatus = "failed"
)

// Warning is CONTRACT.md §1.4's warnings[] entry, guarded by
// tests/schemas/warning.schema.json. `Message` is display-only diagnostic
// text -- Molehouse must never parse it (§1.4); `Code` is the contract.
type Warning struct {
	Code    string `json:"code"`
	Scope   string `json:"scope,omitempty"`
	Message string `json:"message"`
}

// Error is CONTRACT.md §1.5's failure envelope `error` object, used by
// `analyze --json`'s NEW §4.6 failure payload.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Warning codes. Each is namespaced to the command(s) that emit it so a
// reader of Molehouse's decode path can tell which contract section to
// re-check without cross-referencing this file.

const (
	// WarnCollectorFailed is CONTRACT.md §2.4: a `status` collector ran and
	// failed. `Scope` is the JSON field name the failure cost (e.g.
	// "batteries"), not the Go function name -- Molehouse keys the
	// per-card failure marker off it.
	WarnCollectorFailed = "collector_failed"

	// WarnCollectorPending is CONTRACT.md §3.3 (as corrected by F-048): a
	// `status --watch` fast frame did not run this collector yet, for
	// every field the fast frame skips -- the five null arrays and the
	// struct/scalar-valued fields that carry a plausible zero instead.
	WarnCollectorPending = "collector_pending"

	// WarnSubtreeUnreadable is CONTRACT.md §4.6: `analyze` could not read a
	// subtree mid-scan. `Scope` is the unreadable path. The scan continues;
	// the total becomes a lower bound, never a silent shrink.
	WarnSubtreeUnreadable = "subtree_unreadable"

	// WarnSubtreeUnreadableTruncated caps WarnSubtreeUnreadable entries at
	// MaxSubtreeUnreadableWarnings so a permission-dense tree cannot grow
	// the payload without bound.
	WarnSubtreeUnreadableTruncated = "subtree_unreadable_truncated"

	// WarnMeasureFailed is `analyze` overview mode (§4.5): an entry's size
	// measurement failed for a reason that isn't itself a
	// permission/existence problem (which would be WarnSubtreeUnreadable
	// instead).
	WarnMeasureFailed = "measure_failed"

	// WarnZeroSizeEntriesOmitted is CONTRACT.md §4.5: overview mode dropped
	// one or more entries whose measured size was a genuine zero, kept
	// distinct from a dropped failed measurement so the two causes of a
	// disappearing row are never conflated.
	WarnZeroSizeEntriesOmitted = "zero_size_entries_omitted"
)

// Error codes for `analyze --json`'s §4.6 failure envelope.
const (
	ErrPathNotFound     = "path_not_found"
	ErrPermissionDenied = "permission_denied"
	ErrNotADirectory    = "not_a_directory"
	ErrScanFailed       = "scan_failed"
)

// MaxSubtreeUnreadableWarnings is the brief's cap on how many
// subtree_unreadable entries one `analyze` payload may carry before the rest
// collapse into one WarnSubtreeUnreadableTruncated summary warning.
const MaxSubtreeUnreadableWarnings = 64
