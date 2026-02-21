package main

import (
	"path/filepath"
	"testing"
)

func TestParseConfig_FromJSON(t *testing.T) {
	json := `{"state_dir":"/tmp/test-state","date_format":"%Y-%m-%d","time_format":"%H:%M"}`
	cfg := parseConfig(json)
	if cfg.StateDir != "/tmp/test-state" {
		t.Errorf("state_dir = %q, want /tmp/test-state", cfg.StateDir)
	}
	if cfg.DateFormat != "%Y-%m-%d" {
		t.Errorf("date_format = %q", cfg.DateFormat)
	}
}

func TestParseConfig_Defaults(t *testing.T) {
	cfg := parseConfig("")
	if cfg.StateDir != "" {
		t.Errorf("expected empty state_dir for empty config, got %q", cfg.StateDir)
	}
}

func TestWriteAndReadCurrentTask_CustomStateDir(t *testing.T) {
	dir := t.TempDir()
	stateDir := filepath.Join(dir, "custom-state")

	ct := CurrentTask{
		StartTime:  1739800000,
		Name:       "Custom state test",
		FilePath:   "/notes/test.md",
		LineNumber: 3,
	}

	if err := WriteCurrentTaskTo(stateDir, ct); err != nil {
		t.Fatal(err)
	}

	got, err := ReadCurrentTaskFrom(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	if got == nil {
		t.Fatal("expected task, got nil")
	}
	if got.Name != "Custom state test" {
		t.Errorf("name = %q", got.Name)
	}

	if err := ClearCurrentTaskFrom(stateDir); err != nil {
		t.Fatal(err)
	}
	got, _ = ReadCurrentTaskFrom(stateDir)
	if got != nil {
		t.Error("expected nil after clear")
	}
}
