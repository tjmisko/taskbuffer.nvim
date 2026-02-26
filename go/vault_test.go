package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// testdataDir returns the absolute path to the testdata directory.
func testdataDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot determine test file path")
	}
	return filepath.Join(filepath.Dir(file), "testdata")
}

func vaultPath(t *testing.T, name string) string {
	t.Helper()
	return filepath.Join(testdataDir(t), name)
}

// scanAndParse is a helper that runs the full Scan -> ParseTasks pipeline with default context.
func scanAndParse(t *testing.T, paths ...string) []Task {
	t.Helper()
	return scanAndParseWith(t, DefaultParseContext(), paths...)
}

// scanAndParseWith runs the full Scan -> ParseTasks pipeline with a custom context.
func scanAndParseWith(t *testing.T, ctx *ParseContext, paths ...string) []Task {
	t.Helper()
	matches, err := Scan(ctx, paths...)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}
	return ParseTasks(matches, ctx)
}

// openTasks filters to only open tasks.
func openTasks(tasks []Task) []Task {
	var out []Task
	for _, t := range tasks {
		if t.Status == "open" {
			out = append(out, t)
		}
	}
	return out
}

// taskBodies returns the Body field of each task.
func taskBodies(tasks []Task) []string {
	out := make([]string, len(tasks))
	for i, t := range tasks {
		out[i] = t.Body
	}
	return out
}

// =============================================================================
// Basic vault: scan, parse, and format a simple set of tasks
// =============================================================================

func TestVault_BasicScanAndParse(t *testing.T) {
	vault := vaultPath(t, "basic-vault")
	tasks := scanAndParse(t, vault)

	// daily.md has 4 task lines, someday.md has 3
	if len(tasks) != 7 {
		t.Fatalf("got %d tasks, want 7", len(tasks))
	}

	open := openTasks(tasks)
	// 3 open in daily.md + 3 in someday.md = 6
	if len(open) != 6 {
		t.Errorf("got %d open tasks, want 6", len(open))
	}
}

func TestVault_BasicFormatOutput(t *testing.T) {
	vault := vaultPath(t, "basic-vault")
	tasks := openTasks(scanAndParse(t, vault))

	now := time.Date(2026, 2, 17, 10, 0, 0, 0, time.Local)
	output := FormatTaskfile(tasks, now, FormatOpts{})

	// Should have Today, Tomorrow, and Someday buckets
	if !strings.Contains(output, "# Today") {
		t.Error("expected Today header")
	}
	if !strings.Contains(output, "# Tomorrow") {
		t.Error("expected Tomorrow header")
	}
	if !strings.Contains(output, "# Someday") {
		t.Error("expected Someday header")
	}

	// Verify specific tasks appear
	if !strings.Contains(output, "Morning standup") {
		t.Error("expected 'Morning standup' in output")
	}
	if !strings.Contains(output, "Learn Rust") {
		t.Error("expected 'Learn Rust' in someday section")
	}
}

func TestVault_BasicIgnoreUndated(t *testing.T) {
	vault := vaultPath(t, "basic-vault")
	tasks := openTasks(scanAndParse(t, vault))

	now := time.Date(2026, 2, 17, 10, 0, 0, 0, time.Local)
	output := FormatTaskfile(tasks, now, FormatOpts{IgnoreUndated: true})

	if strings.Contains(output, "# Someday") {
		t.Error("should not contain Someday header with IgnoreUndated")
	}
	if strings.Contains(output, "Learn Rust") {
		t.Error("should not contain undated tasks with IgnoreUndated")
	}
	if !strings.Contains(output, "Morning standup") {
		t.Error("should still contain dated tasks")
	}
}

// =============================================================================
// Tagged vault: tag filtering
// =============================================================================

func TestVault_TagFilterSingle(t *testing.T) {
	vault := vaultPath(t, "tagged-vault")
	tasks := openTasks(scanAndParse(t, vault))

	now := time.Date(2026, 2, 17, 10, 0, 0, 0, time.Local)
	output := FormatTaskfile(tasks, now, FormatOpts{TagFilter: []string{"work"}})

	if !strings.Contains(output, "Deploy staging server") {
		t.Error("expected work-tagged task")
	}
	if !strings.Contains(output, "Fix login bug") {
		t.Error("expected work-tagged task")
	}
	if strings.Contains(output, "Plan team outing") {
		t.Error("should not contain personal-only task")
	}
	if strings.Contains(output, "Grocery shopping") {
		t.Error("should not contain personal-only task")
	}
}

func TestVault_TagFilterMultiple(t *testing.T) {
	vault := vaultPath(t, "tagged-vault")
	tasks := openTasks(scanAndParse(t, vault))

	now := time.Date(2026, 2, 17, 10, 0, 0, 0, time.Local)
	output := FormatTaskfile(tasks, now, FormatOpts{TagFilter: []string{"urgent", "errands"}})

	if !strings.Contains(output, "Fix login bug") {
		t.Error("expected urgent-tagged task")
	}
	if !strings.Contains(output, "Grocery shopping") {
		t.Error("expected errands-tagged task")
	}
	if strings.Contains(output, "Deploy staging server") {
		t.Error("should not include task with non-matching tags only")
	}
}

func TestVault_TagFilterNoMatch(t *testing.T) {
	vault := vaultPath(t, "tagged-vault")
	tasks := openTasks(scanAndParse(t, vault))

	now := time.Date(2026, 2, 17, 10, 0, 0, 0, time.Local)
	output := FormatTaskfile(tasks, now, FormatOpts{TagFilter: []string{"nonexistent"}})

	if output != "" {
		t.Errorf("expected empty output for non-matching tag, got:\n%s", output)
	}
}

// =============================================================================
// Multi-source vault: scanning multiple directories
// =============================================================================

func TestVault_MultiSource(t *testing.T) {
	base := vaultPath(t, "multi-source")
	workDir := filepath.Join(base, "work")
	personalDir := filepath.Join(base, "personal")

	tasks := scanAndParse(t, workDir, personalDir)

	if len(tasks) != 4 {
		t.Fatalf("got %d tasks from two sources, want 4", len(tasks))
	}

	bodies := taskBodies(tasks)
	hasWork := false
	hasPersonal := false
	for _, b := range bodies {
		if strings.Contains(b, "API migration") {
			hasWork = true
		}
		if strings.Contains(b, "Practice guitar") {
			hasPersonal = true
		}
	}
	if !hasWork {
		t.Error("missing work task from work source")
	}
	if !hasPersonal {
		t.Error("missing personal task from personal source")
	}
}

func TestVault_SingleSourceOnly(t *testing.T) {
	workDir := filepath.Join(vaultPath(t, "multi-source"), "work")
	tasks := scanAndParse(t, workDir)

	if len(tasks) != 2 {
		t.Fatalf("got %d tasks from work source, want 2", len(tasks))
	}
	for _, task := range tasks {
		if !strings.Contains(task.FilePath, "work") {
			t.Errorf("task from wrong source: %s", task.FilePath)
		}
	}
}

// =============================================================================
// Frontmatter vault: tag merging from YAML frontmatter
// =============================================================================

func TestVault_FrontmatterTagMerge(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "frontmatter-vault")
	tasks := scanAndParse(t, vault)
	MergeFrontmatterTags(tasks)

	// Find the task in tagged-note.md (has sspi, research frontmatter tags)
	for _, task := range tasks {
		if task.Body == "Analyze indicator data" {
			tagSet := make(map[string]bool)
			for _, tag := range task.Tags {
				tagSet[tag] = true
			}
			if !tagSet["sspi"] {
				t.Error("expected 'sspi' tag from frontmatter")
			}
			if !tagSet["research"] {
				t.Error("expected 'research' tag from frontmatter")
			}
			return
		}
	}
	t.Error("could not find 'Analyze indicator data' task")
}

func TestVault_FrontmatterTagFilterAfterMerge(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "frontmatter-vault")
	tasks := openTasks(scanAndParse(t, vault))
	MergeFrontmatterTags(tasks)

	now := time.Date(2026, 2, 17, 10, 0, 0, 0, time.Local)

	// Filter by frontmatter tag "sspi" — should include tasks from tagged-note.md
	output := FormatTaskfile(tasks, now, FormatOpts{TagFilter: []string{"sspi"}})

	if !strings.Contains(output, "Analyze indicator data") {
		t.Error("expected task with frontmatter sspi tag")
	}
	if !strings.Contains(output, "Write methodology section") {
		t.Error("expected second task from same file with sspi frontmatter tag")
	}
	// Task from plain.md only has #inline, not sspi
	if strings.Contains(output, "Task without frontmatter tags") {
		t.Error("should not include task without sspi tag")
	}
}

func TestVault_ProjectScanning(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "frontmatter-vault")

	projectTasks, err := ScanProjects(vault)
	if err != nil {
		t.Fatalf("ScanProjects failed: %v", err)
	}

	// project-note.md has tags: [project], due: 2026-02-20, status: active
	if len(projectTasks) != 1 {
		t.Fatalf("got %d project tasks, want 1", len(projectTasks))
	}

	pt := projectTasks[0]
	if pt.Body != "project-note" {
		t.Errorf("project task body = %q, want 'project-note'", pt.Body)
	}
	if pt.DueDate == nil || pt.DueDate.Format("2006-01-02") != "2026-02-20" {
		t.Errorf("project due date = %v, want 2026-02-20", pt.DueDate)
	}
}

// =============================================================================
// Mixed status vault: status filtering
// =============================================================================

func TestVault_MixedStatusFiltering(t *testing.T) {
	vault := vaultPath(t, "mixed-status-vault")
	tasks := scanAndParse(t, vault)

	statusCounts := make(map[string]int)
	for _, task := range tasks {
		statusCounts[task.Status]++
	}

	if statusCounts["open"] != 3 {
		t.Errorf("open tasks = %d, want 3", statusCounts["open"])
	}
	if statusCounts["done"] != 2 {
		t.Errorf("done tasks = %d, want 2", statusCounts["done"])
	}
	if statusCounts["irrelevant"] != 1 {
		t.Errorf("irrelevant tasks = %d, want 1", statusCounts["irrelevant"])
	}
}

func TestVault_MixedStatusOpenOnly(t *testing.T) {
	vault := vaultPath(t, "mixed-status-vault")
	open := openTasks(scanAndParse(t, vault))

	if len(open) != 3 {
		t.Fatalf("got %d open tasks, want 3", len(open))
	}

	now := time.Date(2026, 2, 17, 10, 0, 0, 0, time.Local)
	output := FormatTaskfile(open, now, FormatOpts{})

	if strings.Contains(output, "Completed task") {
		t.Error("should not show completed tasks")
	}
	if strings.Contains(output, "Cancelled task") {
		t.Error("should not show cancelled tasks")
	}
	if !strings.Contains(output, "Open task one") {
		t.Error("should show open tasks")
	}
	if !strings.Contains(output, "Open task three") {
		t.Error("should show open tasks with duration and time")
	}
}

func TestVault_MixedStatusDurationAndTime(t *testing.T) {
	vault := vaultPath(t, "mixed-status-vault")
	tasks := scanAndParse(t, vault)

	for _, task := range tasks {
		if task.Body == "Open task three" {
			if task.Duration != "45m" {
				t.Errorf("duration = %q, want 45m", task.Duration)
			}
			if task.DueTime != "14:00" {
				t.Errorf("time = %q, want 14:00", task.DueTime)
			}
			if len(task.Tags) != 1 || task.Tags[0] != "urgent" {
				t.Errorf("tags = %v, want [urgent]", task.Tags)
			}
			return
		}
	}
	t.Error("could not find 'Open task three' task")
}

// =============================================================================
// End-to-end: cmdList against vault fixtures
// =============================================================================

func TestVault_CmdListEndToEnd(t *testing.T) {
	vault := vaultPath(t, "tagged-vault")

	old := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w

	err := cmdList([]string{vault}, DefaultParseContext(), []string{"--tag", "devops"})

	w.Close()
	os.Stdout = old

	if err != nil {
		t.Fatal(err)
	}

	buf := make([]byte, 64*1024)
	n, _ := r.Read(buf)
	output := string(buf[:n])

	if !strings.Contains(output, "Deploy staging server") {
		t.Errorf("expected devops task in output, got:\n%s", output)
	}
	if strings.Contains(output, "Fix login bug") {
		t.Errorf("should not include non-devops task, got:\n%s", output)
	}
}

func TestVault_CmdListIgnoreUndated(t *testing.T) {
	vault := vaultPath(t, "basic-vault")

	old := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w

	err := cmdList([]string{vault}, DefaultParseContext(), []string{"--ignore-undated"})

	w.Close()
	os.Stdout = old

	if err != nil {
		t.Fatal(err)
	}

	buf := make([]byte, 64*1024)
	n, _ := r.Read(buf)
	output := string(buf[:n])

	if strings.Contains(output, "Learn Rust") {
		t.Error("should not show undated tasks with --ignore-undated")
	}
	if !strings.Contains(output, "Morning standup") {
		t.Error("should show dated tasks")
	}
}
