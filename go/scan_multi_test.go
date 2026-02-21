package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestScan_MultipleDirs(t *testing.T) {
	dir1 := t.TempDir()
	dir2 := t.TempDir()

	os.WriteFile(filepath.Join(dir1, "a.md"), []byte("- [ ] Task in dir1 (@[[2026-02-17]])\n"), 0644)
	os.WriteFile(filepath.Join(dir2, "b.md"), []byte("- [ ] Task in dir2 (@[[2026-02-18]])\n"), 0644)

	matches, err := Scan(dir1, dir2)
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 2 {
		t.Fatalf("got %d matches, want 2", len(matches))
	}

	bodies := map[string]bool{}
	for _, m := range matches {
		bodies[m.Text] = true
	}
	for _, want := range []string{"Task in dir1", "Task in dir2"} {
		found := false
		for text := range bodies {
			if len(text) > 0 && contains(text, want) {
				found = true
			}
		}
		if !found {
			t.Errorf("missing task containing %q", want)
		}
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && stringContains(s, substr))
}

func stringContains(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func TestDeduplicatePaths_Nested(t *testing.T) {
	dir := t.TempDir()
	sub := filepath.Join(dir, "sub")
	os.MkdirAll(sub, 0755)

	got := deduplicatePaths([]string{dir, sub})
	if len(got) != 1 {
		t.Fatalf("got %d paths, want 1: %v", len(got), got)
	}
	if got[0] != dir {
		t.Errorf("kept %q, want %q", got[0], dir)
	}
}

func TestDeduplicatePaths_Disjoint(t *testing.T) {
	dir1 := t.TempDir()
	dir2 := t.TempDir()

	got := deduplicatePaths([]string{dir1, dir2})
	if len(got) != 2 {
		t.Fatalf("got %d paths, want 2: %v", len(got), got)
	}
}

func TestScan_GlobExpansion(t *testing.T) {
	dir := t.TempDir()
	sub := filepath.Join(dir, "notes")
	os.MkdirAll(sub, 0755)
	os.WriteFile(filepath.Join(sub, "task.md"), []byte("- [ ] Glob task (@[[2026-03-01]])\n"), 0644)

	// Use glob pattern
	pattern := filepath.Join(dir, "note*")
	matches, err := Scan(pattern)
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 1 {
		t.Fatalf("got %d matches, want 1", len(matches))
	}
}
