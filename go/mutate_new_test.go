package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestChangeCheckbox(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("- [ ] Open task\n- [x] Done task\n"), 0644)

	err := ChangeCheckbox(path, 1, "- [ ]", "- [-]")
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	lines := splitLines(string(data))
	if lines[0] != "- [-] Open task" {
		t.Errorf("line 1 = %q", lines[0])
	}
	if lines[1] != "- [x] Done task" {
		t.Errorf("line 2 should be unchanged, got %q", lines[1])
	}
}

func TestRemoveLastMarker(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("- [-] Task (@[[2026-02-17]]) ::irrelevant [[2026-02-18]] 10:00\n"), 0644)

	err := RemoveLastMarker(path, 1, "irrelevant")
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	line := splitLines(string(data))[0]
	if strings.Contains(line, "::irrelevant") {
		t.Errorf("marker should be removed, got %q", line)
	}
	if !strings.Contains(line, "(@[[2026-02-17]])") {
		t.Errorf("date should be preserved, got %q", line)
	}
}

func TestRemoveLastMarker_MultipleMarkers(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("- [-] Task ::irrelevant [[2026-02-17]] 09:00 ::irrelevant [[2026-02-18]] 10:00\n"), 0644)

	err := RemoveLastMarker(path, 1, "irrelevant")
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	line := splitLines(string(data))[0]
	// Should still have the first marker
	if !strings.Contains(line, "::irrelevant [[2026-02-17]] 09:00") {
		t.Errorf("first marker should remain, got %q", line)
	}
	// Should not have the second
	if strings.Contains(line, "2026-02-18") {
		t.Errorf("second marker should be removed, got %q", line)
	}
}

func TestInsertAfterHeader(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("# Tasks\n- [ ] Existing task\n\n# Other\n"), 0644)

	err := InsertAfterHeader(path, "# Tasks", "- [ ] New task")
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	lines := splitLines(string(data))
	if lines[0] != "# Tasks" {
		t.Errorf("header should be preserved, got %q", lines[0])
	}
	if lines[1] != "- [ ] New task" {
		t.Errorf("new task should be inserted after header, got %q", lines[1])
	}
	if lines[2] != "- [ ] Existing task" {
		t.Errorf("existing task should follow, got %q", lines[2])
	}
}

func TestInsertAfterHeader_CreatesFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "new.md")

	err := InsertAfterHeader(path, "## Tasks", "- [ ] First task")
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	content := string(data)
	if !strings.Contains(content, "## Tasks") {
		t.Error("should contain header")
	}
	if !strings.Contains(content, "- [ ] First task") {
		t.Error("should contain task")
	}
}

func TestAppendToFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("# Tasks\n- [ ] Existing\n"), 0644)

	err := AppendToFile(path, "- [ ] Appended task")
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	if !strings.HasSuffix(strings.TrimRight(string(data), "\n"), "- [ ] Appended task") {
		t.Errorf("task should be appended, got %q", string(data))
	}
}

func TestAppendToFile_CreatesFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "new.md")

	err := AppendToFile(path, "- [ ] Brand new task")
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	if !strings.Contains(string(data), "- [ ] Brand new task") {
		t.Errorf("file should contain task, got %q", string(data))
	}
}

func TestCmdDefer(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("- [ ] Deferred task (@[[2026-02-17]])\n"), 0644)

	err := cmdDefer([]string{path, "1"})
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	line := splitLines(string(data))[0]
	if !strings.Contains(line, "::original [[2026-02-17]]") {
		t.Errorf("should have original marker, got %q", line)
	}
	if !strings.Contains(line, "::deferral") {
		t.Errorf("should have deferral marker, got %q", line)
	}
}

func TestCmdDefer_PreservesOriginal(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("- [ ] Task (@[[2026-02-20]]) ::original [[2026-02-17]]\n"), 0644)

	err := cmdDefer([]string{path, "1"})
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	line := splitLines(string(data))[0]
	// Should still have original pointing to 02-17, not 02-20
	count := strings.Count(line, "::original")
	if count != 1 {
		t.Errorf("should have exactly 1 ::original, got %d in %q", count, line)
	}
	if !strings.Contains(line, "::original [[2026-02-17]]") {
		t.Errorf("original date should be preserved, got %q", line)
	}
}

func TestCmdIrrelevant(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("- [ ] Irrelevant task (@[[2026-02-17]])\n"), 0644)

	err := cmdIrrelevant([]string{path, "1"})
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	line := splitLines(string(data))[0]
	if !strings.Contains(line, "- [-]") {
		t.Errorf("checkbox should be [-], got %q", line)
	}
	if !strings.Contains(line, "::irrelevant") {
		t.Errorf("should have irrelevant marker, got %q", line)
	}
}

func TestCmdUnset_Irrelevant(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("- [-] Task (@[[2026-02-17]]) ::irrelevant [[2026-02-18]] 10:00\n"), 0644)

	err := cmdUnset([]string{path, "1"})
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	line := splitLines(string(data))[0]
	if !strings.Contains(line, "- [ ]") {
		t.Errorf("checkbox should be restored to [ ], got %q", line)
	}
	if strings.Contains(line, "::irrelevant") {
		t.Errorf("marker should be removed, got %q", line)
	}
}

func TestCmdUnset_Partial(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	os.WriteFile(path, []byte("- [~] Task (@[[2026-02-17]]) ::partial [[2026-02-18]] 10:00\n"), 0644)

	err := cmdUnset([]string{path, "1"})
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	line := splitLines(string(data))[0]
	if !strings.Contains(line, "- [ ]") {
		t.Errorf("checkbox should be restored to [ ], got %q", line)
	}
	if strings.Contains(line, "::partial") {
		t.Errorf("marker should be removed, got %q", line)
	}
}

func TestCmdCreate_AppendToFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "inbox.md")
	os.WriteFile(path, []byte("# Inbox\n"), 0644)

	err := cmdCreate([]string{"--file", path, "Test task body"})
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	content := string(data)
	if !strings.Contains(content, "- [ ] Test task body") {
		t.Errorf("should contain new task, got %q", content)
	}
}

func TestCmdCreate_InsertAfterHeader(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "inbox.md")
	os.WriteFile(path, []byte("# Notes\nSome text\n\n## Tasks\n- [ ] Existing task\n\n## Other\n"), 0644)

	err := cmdCreate([]string{"--file", path, "--header", "## Tasks", "New task here"})
	if err != nil {
		t.Fatal(err)
	}

	data, _ := os.ReadFile(path)
	lines := splitLines(string(data))

	// Find ## Tasks header and verify new task is right after it
	for i, line := range lines {
		if line == "## Tasks" {
			if i+1 >= len(lines) {
				t.Fatal("no line after header")
			}
			if lines[i+1] != "- [ ] New task here" {
				t.Errorf("expected new task after header, got %q", lines[i+1])
			}
			return
		}
	}
	t.Error("## Tasks header not found")
}
