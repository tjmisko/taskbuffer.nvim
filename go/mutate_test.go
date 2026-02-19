package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAppendToLine(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("line one\nline two\nline three\n"), 0644)

	err := AppendToLine(path, 2, "::start [[2026-02-17]] 15:00 ")
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	lines := splitLines(string(data))
	if lines[1] != "line two ::start [[2026-02-17]] 15:00 " {
		t.Errorf("line 2 = %q", lines[1])
	}
	// Other lines unchanged
	if lines[0] != "line one" {
		t.Errorf("line 1 = %q", lines[0])
	}
	if lines[2] != "line three" {
		t.Errorf("line 3 = %q", lines[2])
	}
}

func TestAppendToLine_OutOfRange(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("only one line\n"), 0644)

	err := AppendToLine(path, 5, "text")
	if err == nil {
		t.Error("expected error for out-of-range line")
	}
}

func TestCheckOffTask(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("# Tasks\n- [ ] Buy groceries (@[[2026-02-17]])\n- [ ] Other task\n"), 0644)

	err := CheckOffTask(path, 2)
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	lines := splitLines(string(data))
	if lines[1] != "- [x] Buy groceries (@[[2026-02-17]])" {
		t.Errorf("line 2 = %q", lines[1])
	}
	// Other lines unchanged
	if lines[2] != "- [ ] Other task" {
		t.Errorf("line 3 should be unchanged, got %q", lines[2])
	}
}

func TestCheckOffTask_IndentedTask(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("\t- [ ] Indented task (@[[2026-02-17]])\n"), 0644)

	err := CheckOffTask(path, 1)
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	lines := splitLines(string(data))
	if lines[0] != "\t- [x] Indented task (@[[2026-02-17]])" {
		t.Errorf("line 1 = %q", lines[0])
	}
}

func splitLines(s string) []string {
	// Split but handle trailing newline
	lines := []string{}
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			lines = append(lines, s[start:i])
			start = i + 1
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}
