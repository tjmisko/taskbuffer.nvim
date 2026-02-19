package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestScan_FindsTasksInTempDir(t *testing.T) {
	dir := t.TempDir()

	// File with two tasks
	err := os.WriteFile(filepath.Join(dir, "project.md"), []byte(
		"# Project\n"+
			"- [ ] First task (@[[2026-02-17]])\n"+
			"- [x] Done task (@[[2026-02-16]] 10:00)::complete [[2026-02-16]] 11:00\n"+
			"Some other content\n",
	), 0644)
	if err != nil {
		t.Fatal(err)
	}

	// File with no tasks
	err = os.WriteFile(filepath.Join(dir, "empty.md"), []byte("# Nothing here\n"), 0644)
	if err != nil {
		t.Fatal(err)
	}

	// File with one task
	err = os.WriteFile(filepath.Join(dir, "daily.md"), []byte(
		"\t- [ ] Indented task <30m> (@[[2026-02-18]])\n",
	), 0644)
	if err != nil {
		t.Fatal(err)
	}

	// File with undated task
	err = os.WriteFile(filepath.Join(dir, "someday.md"), []byte(
		"- [ ] Investigate OOM Kill Root Cause\n"+
			"- [x] Already done undated task\n",
	), 0644)
	if err != nil {
		t.Fatal(err)
	}

	matches, err := Scan(dir)
	if err != nil {
		t.Fatal(err)
	}

	if len(matches) != 5 {
		t.Fatalf("got %d matches, want 5", len(matches))
	}

	// Verify paths are absolute and point to our temp files
	for _, m := range matches {
		if !filepath.IsAbs(m.Path) {
			t.Errorf("path %q is not absolute", m.Path)
		}
		if m.LineNumber < 1 {
			t.Errorf("line number %d < 1", m.LineNumber)
		}
		if m.Text == "" {
			t.Error("text is empty")
		}
	}
}

func TestScan_EmptyDir(t *testing.T) {
	dir := t.TempDir()
	matches, err := Scan(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 0 {
		t.Errorf("got %d matches, want 0", len(matches))
	}
}

func TestScan_NoMatchesInFile(t *testing.T) {
	dir := t.TempDir()
	err := os.WriteFile(filepath.Join(dir, "notes.md"), []byte("No tasks here\n"), 0644)
	if err != nil {
		t.Fatal(err)
	}
	matches, err := Scan(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 0 {
		t.Errorf("got %d matches, want 0", len(matches))
	}
}
