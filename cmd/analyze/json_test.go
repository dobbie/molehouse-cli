//go:build darwin

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/tw93/mole/internal/contract"
)

func TestPerformScanForJSONIncludesAllEntriesAndLargeFiles(t *testing.T) {
	root := t.TempDir()

	totalFiles := maxEntries + 6
	for i := 0; i < totalFiles-1; i++ {
		path := filepath.Join(root, fmt.Sprintf("small-%02d.txt", i))
		if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
			t.Fatalf("write small file %d: %v", i, err)
		}
	}

	hugeFile := filepath.Join(root, "huge.bin")
	if err := os.WriteFile(hugeFile, make([]byte, 2<<20), 0o644); err != nil {
		t.Fatalf("write huge file: %v", err)
	}

	result := performScanForJSON(root, false)

	if result.Overview {
		t.Fatalf("expected non-overview JSON result")
	}
	if got := len(result.Entries); got != totalFiles {
		t.Fatalf("expected %d entries, got %d", totalFiles, got)
	}
	if result.TotalFiles != int64(totalFiles) {
		t.Fatalf("expected %d total files, got %d", totalFiles, result.TotalFiles)
	}
	if len(result.LargeFiles) == 0 {
		t.Fatalf("expected large_files to include the large file")
	}

	foundHuge := false
	for _, file := range result.LargeFiles {
		if file.Name == "huge.bin" && file.Path == hugeFile {
			foundHuge = true
			break
		}
	}
	if !foundHuge {
		t.Fatalf("expected huge.bin in large_files, got %#v", result.LargeFiles)
	}
}

func TestJSONEntriesFromDirEntriesIncludesMetadata(t *testing.T) {
	oldAccess := time.Now().AddDate(0, 0, -120)

	entries := jsonEntriesFromDirEntries([]dirEntry{
		{
			Name:       "old.bin",
			Path:       "/tmp/old.bin",
			Size:       42,
			IsDir:      false,
			LastAccess: oldAccess,
		},
		{
			Name:  "node_modules",
			Path:  "/tmp/project/node_modules",
			Size:  128,
			IsDir: true,
		},
	}, false, nil)

	if entries[0].LastAccess == "" {
		t.Fatalf("expected last_access to be populated")
	}
	if entries[1].Cleanable != true {
		t.Fatalf("expected node_modules entry to be marked cleanable")
	}
}

func TestJSONEntriesFromDirEntriesMarksOverviewInsights(t *testing.T) {
	entry := dirEntry{
		Name:  "Old Downloads (90d+)",
		Path:  "/tmp/test-home/Downloads",
		Size:  256,
		IsDir: true,
	}

	entries := jsonEntriesFromDirEntries([]dirEntry{entry}, true, map[string]bool{
		entry.Path: true,
	})

	if len(entries) != 1 {
		t.Fatalf("expected one entry, got %d", len(entries))
	}
	if !entries[0].Insight {
		t.Fatalf("expected entry to be marked as insight")
	}
}

func TestPerformOverviewScanForJSONSchemaWithInjectedEntries(t *testing.T) {
	root := t.TempDir()
	payload := filepath.Join(root, "payload")
	if err := os.WriteFile(payload, []byte("overview"), 0o644); err != nil {
		t.Fatalf("write overview payload: %v", err)
	}

	result := performOverviewScanForJSONWithEntries("/", nil, []dirEntry{{
		Name:  "Fixture",
		Path:  root,
		IsDir: true,
		Size:  -1,
	}})

	if result.Path != "/" || !result.Overview {
		t.Fatalf("unexpected overview identity: path=%q overview=%v", result.Path, result.Overview)
	}
	if result.Entries == nil {
		t.Fatal("overview entries must be a JSON list, not nil")
	}
	if result.TotalSize <= 0 {
		t.Fatalf("expected measured overview size, got %d", result.TotalSize)
	}
}

// TestOverviewMeasurementThatNeverReturnsYieldsPartialEnvelope is F-096's
// regression test. Before the fix, an overview entry whose measurement blocked
// in an uninterruptible directory read left main parked in
// measureOverviewEntriesForJSON's wg.Wait() forever and the command wrote zero
// bytes. The assertion is on what the user receives -- a returned envelope,
// scan_status "partial", and a measure_failed warning naming the folder -- not
// on any internal plumbing.
func TestOverviewMeasurementThatNeverReturnsYieldsPartialEnvelope(t *testing.T) {
	blocked := make(chan struct{})
	t.Cleanup(func() { close(blocked) })

	restoreMeasure := measureOverviewSizeFn
	restoreTimeout := overviewMeasureTimeout
	measureOverviewSizeFn = func(string) (int64, error) {
		<-blocked
		return 0, nil
	}
	overviewMeasureTimeout = 50 * time.Millisecond
	t.Cleanup(func() {
		measureOverviewSizeFn = restoreMeasure
		overviewMeasureTimeout = restoreTimeout
	})

	stuck := t.TempDir()
	done := make(chan jsonOutput, 1)
	go func() {
		done <- performOverviewScanForJSONWithEntries("/", nil, []dirEntry{{
			Name:  "Stuck",
			Path:  stuck,
			IsDir: true,
			Size:  -1,
		}})
	}()

	var result jsonOutput
	select {
	case result = <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("analyze --json never returned: an unresponsive folder must not hang the command")
	}

	if result.ScanStatus != contract.ScanPartial {
		t.Fatalf("scan_status = %q, want %q", result.ScanStatus, contract.ScanPartial)
	}

	var found *contract.Warning
	for i := range result.Warnings {
		if result.Warnings[i].Code == contract.WarnMeasureFailed && result.Warnings[i].Scope == stuck {
			found = &result.Warnings[i]
			break
		}
	}
	if found == nil {
		t.Fatalf("no %s warning naming %q; warnings = %+v", contract.WarnMeasureFailed, stuck, result.Warnings)
	}
	if !strings.Contains(found.Message, "timed out") {
		t.Fatalf("warning message does not tell the user it timed out: %q", found.Message)
	}
}

// TestDirectoryScanTimeoutIsReportedNotWaitedOn covers the sibling path,
// `analyze --json <path>`: the deadline must win over a scan that cannot
// finish, so the caller sees an error rather than silence.
func TestDirectoryScanTimeoutIsReportedNotWaitedOn(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	var files, dirs, bytes int64
	current := &atomic.Value{}
	current.Store("")

	returned := make(chan error, 1)
	go func() {
		_, err := scanDirectoryWithDeadline(ctx, "/", &files, &dirs, &bytes, current)
		returned <- err
	}()

	select {
	case err := <-returned:
		if err == nil {
			// A tiny deadline can still be beaten on a fast machine; the
			// claim under test is only that the call returns.
			return
		}
		if classifyScanError(err) != contract.ErrScanFailed {
			t.Fatalf("timed-out scan classified as %q, want %q", classifyScanError(err), contract.ErrScanFailed)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("scanDirectoryWithDeadline ignored its deadline and blocked")
	}
}
