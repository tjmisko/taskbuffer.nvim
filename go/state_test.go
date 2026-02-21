package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWriteAndReadCurrentTask(t *testing.T) {
	// Use a temp dir as HOME so we don't clobber real state
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	ct := CurrentTask{
		StartTime:  1739800000,
		Name:       "Buy groceries",
		FilePath:   "/notes/daily/2026-02-17.md",
		LineNumber: 5,
	}

	if err := WriteCurrentTask(ct); err != nil {
		t.Fatal(err)
	}

	got, err := ReadCurrentTask()
	if err != nil {
		t.Fatal(err)
	}
	if got == nil {
		t.Fatal("expected current task, got nil")
	}
	if got.StartTime != ct.StartTime {
		t.Errorf("start time = %d, want %d", got.StartTime, ct.StartTime)
	}
	if got.Name != ct.Name {
		t.Errorf("name = %q, want %q", got.Name, ct.Name)
	}
	if got.FilePath != ct.FilePath {
		t.Errorf("filepath = %q, want %q", got.FilePath, ct.FilePath)
	}
	if got.LineNumber != ct.LineNumber {
		t.Errorf("line = %d, want %d", got.LineNumber, ct.LineNumber)
	}
}

func TestReadCurrentTask_NoFile(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	got, err := ReadCurrentTask()
	if err != nil {
		t.Fatal(err)
	}
	if got != nil {
		t.Errorf("expected nil, got %+v", got)
	}
}

func TestClearCurrentTask(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	ct := CurrentTask{StartTime: 1, Name: "test", FilePath: "/a.md", LineNumber: 1}
	if err := WriteCurrentTask(ct); err != nil {
		t.Fatal(err)
	}

	if err := ClearCurrentTask(); err != nil {
		t.Fatal(err)
	}

	// File should be gone
	path := filepath.Join(tmp, defaultStateDir, stateFile)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("state file still exists after clear")
	}
}

func TestClearCurrentTask_NoFile(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	// Should not error when file doesn't exist
	if err := ClearCurrentTask(); err != nil {
		t.Fatal(err)
	}
}
