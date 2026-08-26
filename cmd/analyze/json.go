//go:build darwin

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/tw93/mole/internal/contract"
)

type jsonOutput struct {
	// SchemaVersion, ScanStatus and Warnings are CONTRACT.md §1.5's NEW
	// envelope fields (M1-T7 / F-045). `analyze` keeps its existing flat
	// shape per §1.5's own text -- these three are added at top level and
	// nothing else moves. Kept first in the struct for readability, though
	// §1.7 does not guarantee field order.
	SchemaVersion int                 `json:"schema_version"`
	ScanStatus    contract.ScanStatus `json:"scan_status"`
	Warnings      []contract.Warning  `json:"warnings"`

	Path       string          `json:"path"`
	Overview   bool            `json:"overview"`
	Entries    []jsonEntry     `json:"entries"`
	LargeFiles []jsonFileEntry `json:"large_files,omitempty"`
	TotalSize  int64           `json:"total_size"`
	TotalFiles int64           `json:"total_files,omitempty"`
}

// jsonFailure is CONTRACT.md §1.5's failure envelope, as §4.6 requires it for
// `analyze --json`: flat (§1.5's own text keeps `analyze` un-enveloped), no
// `data` key, and no `path`/`entries`/`total_size` -- a failed scan has no
// entries to report and must not fake an empty list.
type jsonFailure struct {
	SchemaVersion int                 `json:"schema_version"`
	ScanStatus    contract.ScanStatus `json:"scan_status"`
	Warnings      []contract.Warning  `json:"warnings"`
	Error         contract.Error      `json:"error"`
}

// classifyScanError turns the *fs.PathError os.ReadDir raises into one of
// CONTRACT.md §4.6's four error.code values, by errno via errors.Is --
// never by matching the message text (.claude/skills/bugs archetype 12:
// a string match breaks on the next Go release that rewords the error).
// ENOTDIR is checked before the generic fallback deliberately: order
// matters here.
func classifyScanError(err error) string {
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return contract.ErrPathNotFound
	case errors.Is(err, fs.ErrPermission):
		return contract.ErrPermissionDenied
	case errors.Is(err, syscall.ENOTDIR):
		return contract.ErrNotADirectory
	default:
		return contract.ErrScanFailed
	}
}

// writeFailureAndExit emits the §1.5/§4.6 failed envelope on stdout and
// exits 1. stderr keeps a human line for terminal users -- §1.3 governs
// stdout only.
func writeFailureAndExit(code string, humanErr error) {
	fmt.Fprintf(os.Stderr, "failed to scan directory: %v\n", humanErr)
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	_ = encoder.Encode(jsonFailure{
		SchemaVersion: contract.SchemaVersion,
		ScanStatus:    contract.ScanFailed,
		Warnings:      []contract.Warning{},
		Error:         contract.Error{Code: code, Message: humanErr.Error()},
	})
	os.Exit(1)
}

// unreadableWarnings turns a scan's recorded unreadable subtrees into
// CONTRACT.md §4.6 warnings, capped and deduplicated by
// unreadableRecorder already; this only shapes them into the warnings[]
// entries plus the truncation summary.
func unreadableWarnings(paths []string, dropped int) []contract.Warning {
	warnings := make([]contract.Warning, 0, len(paths)+1)
	for _, p := range paths {
		warnings = append(warnings, contract.Warning{
			Code:    contract.WarnSubtreeUnreadable,
			Scope:   p,
			Message: "could not read this subtree; its contribution to total_size is missing",
		})
	}
	if dropped > 0 {
		warnings = append(warnings, contract.Warning{
			Code:    contract.WarnSubtreeUnreadableTruncated,
			Message: fmt.Sprintf("%d more unreadable subtrees not listed", dropped),
		})
	}
	return warnings
}

type jsonEntry struct {
	Name       string `json:"name"`
	Path       string `json:"path"`
	Size       int64  `json:"size"`
	IsDir      bool   `json:"is_dir"`
	Insight    bool   `json:"insight,omitempty"`
	Cleanable  bool   `json:"cleanable,omitempty"`
	LastAccess string `json:"last_access,omitempty"`
}

type jsonFileEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Size int64  `json:"size"`
}

func runJSONMode(path string, isOverview bool) {
	result := performScanForJSON(path, isOverview)

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		fmt.Fprintf(os.Stderr, "failed to encode JSON: %v\n", err)
		os.Exit(1)
	}
}

func performScanForJSON(path string, isOverview bool) jsonOutput {
	if isOverview {
		return performOverviewScanForJSON(path)
	}
	return performDirectoryScanForJSON(path)
}

func performDirectoryScanForJSON(path string) jsonOutput {
	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := &atomic.Value{}
	currentPath.Store("")

	result, err := scanPathConcurrentAllEntries(context.Background(), path, &filesScanned, &dirsScanned, &bytesScanned, currentPath)
	if err != nil {
		// CONTRACT.md §4.6 (M1-T7): classify by errno, never by matching
		// the message text, and emit the flat failed envelope instead of
		// empty stdout so a caller can tell "no such path" from
		// "permission denied" (Full Disk Access) without parsing English.
		writeFailureAndExit(classifyScanError(err), err)
	}

	warnings := unreadableWarnings(result.UnreadablePaths, result.UnreadableDropped)
	status := contract.ScanComplete
	if len(warnings) > 0 {
		status = contract.ScanPartial
	}

	return jsonOutput{
		SchemaVersion: contract.SchemaVersion,
		ScanStatus:    status,
		Warnings:      warnings,
		Path:          path,
		Overview:      false,
		Entries:       jsonEntriesFromDirEntries(result.Entries, false, nil),
		LargeFiles:    jsonFileEntriesFromFileEntries(result.LargeFiles),
		TotalSize:     result.TotalSize,
		TotalFiles:    result.TotalFiles,
	}
}

func performOverviewScanForJSON(path string) jsonOutput {
	insightEntries := createInsightEntries()
	overviewEntries := createOverviewEntriesWithInsights(insightEntries)
	return performOverviewScanForJSONWithEntries(path, insightEntries, overviewEntries)
}

func performOverviewScanForJSONWithEntries(path string, insightEntries, overviewEntries []dirEntry) jsonOutput {
	insightPaths := make(map[string]bool, len(insightEntries))
	for _, insight := range insightEntries {
		insightPaths[insight.Path] = true
	}

	measured, failures := measureOverviewEntriesForJSON(overviewEntries, insightPaths)
	failedPaths := make(map[string]error, len(failures))
	for _, f := range failures {
		failedPaths[f.path] = f.err
	}

	var totalSize int64
	var zeroSizeOmitted int
	warnings := make([]contract.Warning, 0)
	entries := make([]dirEntry, 0, len(overviewEntries))
	for _, entry := range measured {
		// Match the TUI: omit scanned insight/tool entries that ended up empty.
		if entry.Size == 0 {
			// §4.5 + M1-T7: a dropped entry and a never-existed entry look
			// identical unless the cause is kept apart. A failed
			// measurement is subtree_unreadable/measure_failed by path; a
			// genuine empty directory rolls into the one
			// zero_size_entries_omitted summary instead.
			if measureErr, failed := failedPaths[entry.Path]; failed {
				code := contract.WarnMeasureFailed
				if errors.Is(measureErr, fs.ErrNotExist) || errors.Is(measureErr, fs.ErrPermission) {
					code = contract.WarnSubtreeUnreadable
				}
				warnings = append(warnings, contract.Warning{
					Code:    code,
					Scope:   entry.Path,
					Message: measureErr.Error(),
				})
			} else {
				zeroSizeOmitted++
			}
			continue
		}
		totalSize += entry.Size
		entries = append(entries, entry)
	}
	if zeroSizeOmitted > 0 {
		warnings = append(warnings, contract.Warning{
			Code:    contract.WarnZeroSizeEntriesOmitted,
			Message: fmt.Sprintf("%d zero-size entries omitted", zeroSizeOmitted),
		})
	}

	sort.SliceStable(entries, func(i, j int) bool {
		return entries[i].Size > entries[j].Size
	})

	status := contract.ScanComplete
	if len(warnings) > 0 {
		status = contract.ScanPartial
	}

	return jsonOutput{
		SchemaVersion: contract.SchemaVersion,
		ScanStatus:    status,
		Warnings:      warnings,
		Path:          path,
		Overview:      true,
		Entries:       jsonEntriesFromDirEntries(entries, true, insightPaths),
		TotalSize:     totalSize,
	}
}

// overviewMeasureFailure is a measurement that failed, kept apart from a
// genuine zero-size directory. §4.5's zero_size_entries_omitted covers the
// exhaustiveness gap for the second cause only; conflating the two would
// tell Molehouse an entry vanished because it was empty when the real
// reason was unreadable or otherwise unmeasurable (M1-T7 brief).
type overviewMeasureFailure struct {
	path string
	err  error
}

func measureOverviewEntriesForJSON(overviewEntries []dirEntry, insightPaths map[string]bool) ([]dirEntry, []overviewMeasureFailure) {
	if len(overviewEntries) == 0 {
		return nil, nil
	}

	type measurement struct {
		index int
		entry dirEntry
		err   error
	}

	measured := make([]dirEntry, len(overviewEntries))
	failed := make([]overviewMeasureFailure, 0)
	sem := make(chan struct{}, maxConcurrentOverview)
	results := make(chan measurement, len(overviewEntries))

	var wg sync.WaitGroup
	for index, item := range overviewEntries {
		wg.Go(func() {
			sem <- struct{}{}
			defer func() { <-sem }()

			var (
				size int64
				err  error
			)

			if cached, cacheErr := loadOverviewCachedSize(item.Path); cacheErr == nil && cached > 0 {
				size = cached
			} else if insightPaths[item.Path] {
				size, err = measureInsightSize(item.Path)
			} else {
				size, err = measureOverviewSize(item.Path)
			}

			if err == nil {
				item.Size = size
			}
			results <- measurement{index: index, entry: item, err: err}
		})
	}

	wg.Wait()
	close(results)

	for result := range results {
		measured[result.index] = result.entry
		if result.err != nil {
			failed = append(failed, overviewMeasureFailure{path: result.entry.Path, err: result.err})
		}
	}
	return measured, failed
}

func jsonEntriesFromDirEntries(entries []dirEntry, isOverview bool, insightPaths map[string]bool) []jsonEntry {
	output := make([]jsonEntry, 0, len(entries))
	for _, entry := range entries {
		item := jsonEntry{
			Name:      entry.Name,
			Path:      entry.Path,
			Size:      entry.Size,
			IsDir:     entry.IsDir,
			Cleanable: entry.IsDir && isCleanableDir(entry.Path),
		}

		if isOverview {
			item.Insight = insightPaths[entry.Path]
		}

		if !entry.LastAccess.IsZero() {
			item.LastAccess = entry.LastAccess.UTC().Format(time.RFC3339)
		}

		output = append(output, item)
	}
	return output
}

func jsonFileEntriesFromFileEntries(files []fileEntry) []jsonFileEntry {
	output := make([]jsonFileEntry, 0, len(files))
	for _, f := range files {
		output = append(output, jsonFileEntry(f))
	}
	return output
}
