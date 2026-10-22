package main

import (
	"context"
	"errors"
	"runtime"
	"testing"
	"time"

	"github.com/shirou/gopsutil/v4/disk"
	gopsutilnet "github.com/shirou/gopsutil/v4/net"

	"github.com/tw93/mole/internal/contract"
)

// F-080: a collector that returns nothing because it failed must say so; only a
// device that is genuinely absent may be empty without a warning.

func stubCommands(t *testing.T, exists func(string) bool, run func(string, ...string) (string, error)) {
	t.Helper()
	origRun, origExists := runCmd, commandExists
	t.Cleanup(func() { runCmd, commandExists = origRun, origExists })
	commandExists = exists
	runCmd = func(_ context.Context, name string, args ...string) (string, error) {
		return run(name, args...)
	}
}

func hasScopeWarning(warnings []contract.Warning, code, scope string) bool {
	for _, w := range warnings {
		if w.Code == code && w.Scope == scope {
			return true
		}
	}
	return false
}

func TestCollectNetworkReportsCounterFailure(t *testing.T) {
	original := ioCountersFunc
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		return nil, errors.New("netstat blocked")
	}
	t.Cleanup(func() { ioCountersFunc = original })

	c := &Collector{}
	got, err := c.collectNetwork(time.Now())
	if err == nil || got != nil {
		t.Fatalf("expected nil stats and an error, got %+v, %v", got, err)
	}
}

func TestCollectNetworkOnlyNoiseInterfacesIsAbsentNotFailed(t *testing.T) {
	original := ioCountersFunc
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		return []gopsutilnet.IOCountersStat{{Name: "lo0"}}, nil
	}
	t.Cleanup(func() { ioCountersFunc = original })

	c := &Collector{}
	got, err := c.collectNetwork(time.Now())
	if err != nil || len(got) != 0 {
		t.Fatalf("expected empty stats and no error, got %+v, %v", got, err)
	}
}

func TestCollectFastWarnsWhenNetworkCountersFail(t *testing.T) {
	original := ioCountersFunc
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		return nil, errors.New("netstat blocked")
	}
	t.Cleanup(func() { ioCountersFunc = original })

	c := NewCollector(ProcessWatchOptions{})
	snapshot, _ := c.CollectFast()
	if !hasScopeWarning(snapshot.Warnings, contract.WarnCollectorFailed, "network") {
		t.Fatalf("expected collector_failed for network, got %+v", snapshot.Warnings)
	}
	if snapshot.ScanStatus != contract.ScanPartial {
		t.Fatalf("scan_status = %q, want partial", snapshot.ScanStatus)
	}
}

func stubSingleVolume(t *testing.T, usage func(string) (*disk.UsageStat, error)) {
	t.Helper()
	origPartitions, origUsage := diskPartitionsFunc, diskUsageFunc
	t.Cleanup(func() { diskPartitionsFunc, diskUsageFunc = origPartitions, origUsage })
	diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
		return []disk.PartitionStat{{Device: "/dev/disk3s1s1", Mountpoint: "/", Fstype: "apfs"}}, nil
	}
	diskUsageFunc = usage
}

func TestCollectDisksReportsUnreadableVolumes(t *testing.T) {
	stubSingleVolume(t, func(string) (*disk.UsageStat, error) { return nil, errors.New("statfs: permission denied") })

	got, err := collectDisksFast()
	if err == nil || got != nil {
		t.Fatalf("expected nil disks and an error, got %+v, %v", got, err)
	}
}

func TestCollectDisksNoVolumesIsAbsentNotFailed(t *testing.T) {
	origPartitions := diskPartitionsFunc
	t.Cleanup(func() { diskPartitionsFunc = origPartitions })
	diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) { return nil, nil }

	got, err := collectDisksFast()
	if err != nil || len(got) != 0 {
		t.Fatalf("expected empty disks and no error, got %+v, %v", got, err)
	}
}

func TestCollectGPUDarwinReportsFailedQuery(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("darwin GPU path")
	}
	// No nvidia-smi, as on any Mac: the fall-through would otherwise answer
	// with a placeholder "No GPU metrics available" row.
	stubCommands(t,
		func(name string) bool { return name != "nvidia-smi" },
		func(name string, _ ...string) (string, error) { return "", errors.New(name + " timed out") })

	c := &Collector{}
	got, err := c.collectGPU(time.Now())
	if err == nil || got != nil {
		t.Fatalf("expected nil gpus and an error, got %+v, %v", got, err)
	}
}

func TestCollectBatteriesDarwinNoBatteryIsAbsentNotFailed(t *testing.T) {
	stubCommands(t,
		func(string) bool { return true },
		func(string, ...string) (string, error) { return "Now drawing from 'AC Power'\n", nil })

	got, err := collectBatteriesDarwin()
	if err != nil || got != nil {
		t.Fatalf("a Mac with no battery must be nil, nil; got %+v, %v", got, err)
	}
}

func TestCollectBatteriesDarwinReportsFailedPmset(t *testing.T) {
	stubCommands(t,
		func(string) bool { return true },
		func(string, ...string) (string, error) { return "", errors.New("pmset timed out") })

	got, err := collectBatteriesDarwin()
	if err == nil || got != nil {
		t.Fatalf("expected nil batteries and an error, got %+v, %v", got, err)
	}
}

func TestCollectBatteriesDarwinReportsMissingPmset(t *testing.T) {
	stubCommands(t,
		func(string) bool { return false },
		func(string, ...string) (string, error) { return "", nil })

	if _, err := collectBatteriesDarwin(); err == nil {
		t.Fatal("a missing pmset must be an error, not an absent battery")
	}
}

func TestCollectBatteriesDarwinReportsUnparseableBatteryLine(t *testing.T) {
	stubCommands(t,
		func(string) bool { return true },
		func(string, ...string) (string, error) { return " -InternalBattery-0 (id=1) 5%x garbage\n", nil })

	got, err := collectBatteriesDarwin()
	if err == nil || got != nil {
		t.Fatalf("expected an error for an unparseable battery line, got %+v, %v", got, err)
	}
}
