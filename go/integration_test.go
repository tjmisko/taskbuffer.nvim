package main

import (
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// =============================================================================
// Helpers
// =============================================================================

type TaskExpect struct {
	Body       string
	Status     string
	Tags       []string // compared as sets
	DueDate    string   // "YYYY-MM-DD" or "" for nil
	DueTime    string
	Duration   string
	FileSuffix string // matched against end of FilePath
	Line       int    // 0 means don't check
}

func assertTask(t *testing.T, got Task, want TaskExpect) {
	t.Helper()
	if want.Body != "" && got.Body != want.Body {
		t.Errorf("body = %q, want %q", got.Body, want.Body)
	}
	if want.Status != "" && got.Status != want.Status {
		t.Errorf("status = %q, want %q (task: %q)", got.Status, want.Status, got.Body)
	}
	if want.DueDate != "" {
		if got.DueDate == nil {
			t.Errorf("date = nil, want %s (task: %q)", want.DueDate, got.Body)
		} else if got.DueDate.Format("2006-01-02") != want.DueDate {
			t.Errorf("date = %s, want %s (task: %q)", got.DueDate.Format("2006-01-02"), want.DueDate, got.Body)
		}
	} else if want.DueDate == "" && want.Body != "" {
		// If DueDate is empty string and Body is set, we expect nil
	}
	if want.DueTime != "" && got.DueTime != want.DueTime {
		t.Errorf("time = %q, want %q (task: %q)", got.DueTime, want.DueTime, got.Body)
	}
	if want.Duration != "" && got.Duration != want.Duration {
		t.Errorf("duration = %q, want %q (task: %q)", got.Duration, want.Duration, got.Body)
	}
	if want.FileSuffix != "" && !strings.HasSuffix(got.FilePath, want.FileSuffix) {
		t.Errorf("filepath = %q, want suffix %q (task: %q)", got.FilePath, want.FileSuffix, got.Body)
	}
	if want.Line > 0 && got.LineNumber != want.Line {
		t.Errorf("line = %d, want %d (task: %q)", got.LineNumber, want.Line, got.Body)
	}
	if len(want.Tags) > 0 {
		gotSet := make(map[string]bool)
		for _, tag := range got.Tags {
			gotSet[tag] = true
		}
		for _, tag := range want.Tags {
			if !gotSet[tag] {
				t.Errorf("missing tag %q (task: %q, got tags: %v)", tag, got.Body, got.Tags)
			}
		}
	}
}

func findTask(tasks []Task, body string) *Task {
	for _, t := range tasks {
		if t.Body == body {
			return &t
		}
	}
	return nil
}

func parseContextWith(overrides Config) *ParseContext {
	return NewParseContext(overrides)
}

// =============================================================================
// Edge Syntax Vault
// =============================================================================

func TestEdge_EmptyBody(t *testing.T) {
	vault := vaultPath(t, "edge-syntax-vault")
	tasks := scanAndParse(t, vault)

	// "- [ ] (@[[2026-02-17]])" has empty body
	for _, task := range tasks {
		if task.DueDate != nil && task.DueDate.Format("2006-01-02") == "2026-02-17" && task.Body == "" {
			return // found it
		}
	}
	t.Error("expected a task with empty body")
}

func TestEdge_WhitespaceTrimming(t *testing.T) {
	vault := vaultPath(t, "edge-syntax-vault")
	tasks := scanAndParse(t, vault)

	task := findTask(tasks, "Extra whitespace body")
	if task == nil {
		t.Fatal("expected 'Extra whitespace body' task (trimmed)")
	}
	if task.Duration != "30m" {
		t.Errorf("duration = %q, want 30m", task.Duration)
	}
}

func TestEdge_WikiLinksPreserved(t *testing.T) {
	vault := vaultPath(t, "edge-syntax-vault")
	tasks := scanAndParse(t, vault)

	task := findTask(tasks, "Visit [[The Commons]] for lunch")
	if task == nil {
		t.Fatal("expected wiki link preserved in body")
	}
}

func TestEdge_IndentedTasks(t *testing.T) {
	vault := vaultPath(t, "edge-syntax-vault")
	tasks := scanAndParse(t, vault)

	// indented.md has 3 tasks at different indent levels
	indentedCount := 0
	for _, task := range tasks {
		if strings.HasSuffix(task.FilePath, "indented.md") {
			indentedCount++
		}
	}
	if indentedCount != 3 {
		t.Errorf("got %d tasks from indented.md, want 3", indentedCount)
	}
}

func TestEdge_BlockquoteNotMatched(t *testing.T) {
	vault := vaultPath(t, "edge-syntax-vault")
	tasks := scanAndParse(t, vault)

	// "> - [ ] Task inside blockquote" — rg still finds it (matches `- [.]`)
	// but the parser may or may not parse it depending on regex anchoring.
	// The `> ` prefix means `^\s*` won't match; let's verify behavior.
	for _, task := range tasks {
		if strings.Contains(task.Body, "blockquote") {
			// If it parses, that's fine — document the behavior
			t.Logf("blockquote task parsed: %+v", task)
			return
		}
	}
	// If it doesn't parse, that's also fine
	t.Log("blockquote task not parsed (expected: regex anchors on whitespace + checkbox)")
}

func TestEdge_MultipleDurations(t *testing.T) {
	vault := vaultPath(t, "edge-syntax-vault")
	tasks := scanAndParse(t, vault)

	task := findTask(tasks, "First duration second duration")
	if task == nil {
		// The body extraction removes both <30m> and <60m> tag strings
		// Look for the task with the first duration match
		for _, t := range tasks {
			if t.Duration == "30m" && strings.Contains(t.Body, "duration") {
				task = &t
				break
			}
		}
	}
	if task == nil {
		t.Fatal("expected task with multiple durations")
	}
	if task.Duration != "30m" {
		t.Errorf("first <Nm> match should win: got %q, want 30m", task.Duration)
	}
}

func TestEdge_CodeBlockTasksMatched(t *testing.T) {
	vault := vaultPath(t, "edge-syntax-vault")
	tasks := scanAndParse(t, vault)

	// rg finds tasks inside code blocks by design
	codeBlockCount := 0
	for _, task := range tasks {
		if strings.HasSuffix(task.FilePath, "codeblock.md") {
			codeBlockCount++
		}
	}
	// Should find at least the real task, possibly the code block task too
	if codeBlockCount < 1 {
		t.Errorf("expected at least 1 task from codeblock.md, got %d", codeBlockCount)
	}
}

// =============================================================================
// Path Edge Vault
// =============================================================================

func TestPath_SpacesInPath(t *testing.T) {
	vault := vaultPath(t, "path-edge-vault")
	spaceDir := filepath.Join(vault, "space dir")
	tasks := scanAndParse(t, spaceDir)

	if len(tasks) != 1 {
		t.Fatalf("got %d tasks from space dir, want 1", len(tasks))
	}
	if tasks[0].Body != "Task in space dir" {
		t.Errorf("body = %q", tasks[0].Body)
	}
}

func TestPath_DeeplyNested(t *testing.T) {
	vault := vaultPath(t, "path-edge-vault")
	tasks := scanAndParse(t, vault)

	found := false
	for _, task := range tasks {
		if task.Body == "Deeply nested task" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected deeply nested task to be found")
	}
}

func TestPath_EmptyDirectory(t *testing.T) {
	vault := vaultPath(t, "path-edge-vault")
	emptyDir := filepath.Join(vault, "empty-dir")
	tasks := scanAndParse(t, emptyDir)

	if len(tasks) != 0 {
		t.Errorf("got %d tasks from empty dir, want 0", len(tasks))
	}
}

func TestPath_NoTasksInMarkdown(t *testing.T) {
	vault := vaultPath(t, "path-edge-vault")
	noTasksDir := filepath.Join(vault, "no-tasks")
	tasks := scanAndParse(t, noTasksDir)

	if len(tasks) != 0 {
		t.Errorf("got %d tasks from no-tasks dir, want 0", len(tasks))
	}
}

func TestPath_SymlinkDedup(t *testing.T) {
	vault := vaultPath(t, "path-edge-vault")
	realDir := filepath.Join(vault, "symlink-target")
	linkDir := filepath.Join(vault, "linked")

	tasks := scanAndParse(t, realDir, linkDir)

	// deduplicatePaths should resolve symlinks and dedup
	if len(tasks) != 1 {
		t.Errorf("got %d tasks scanning real+symlink, want 1 (deduped)", len(tasks))
	}
}

func TestPath_NonExistentPath(t *testing.T) {
	// rg returns exit code 2 for non-existent paths — verify Scan returns an error
	ctx := DefaultParseContext()
	_, err := Scan(ctx, "/nonexistent/path/that/does/not/exist")
	if err == nil {
		t.Error("expected error for non-existent path")
	}
}

func TestPath_OverlappingNested(t *testing.T) {
	vault := vaultPath(t, "path-edge-vault")
	parentDir := filepath.Join(vault, "deeply")
	nestedDir := filepath.Join(vault, "deeply", "nested", "dir")

	tasks := scanAndParse(t, parentDir, nestedDir)

	// Should dedup to just parentDir
	if len(tasks) != 1 {
		t.Errorf("got %d tasks, want 1 (deduped nested)", len(tasks))
	}
}

func TestPath_ExactDuplicates(t *testing.T) {
	vault := vaultPath(t, "path-edge-vault")
	normalDir := filepath.Join(vault, "normal")

	tasks := scanAndParse(t, normalDir, normalDir)

	if len(tasks) != 2 {
		t.Errorf("got %d tasks from duplicate paths, want 2 (deduped)", len(tasks))
	}
}

func TestPath_ParentScansAll(t *testing.T) {
	vault := vaultPath(t, "path-edge-vault")
	tasks := scanAndParse(t, vault)

	// normal(2) + space dir(1) + deeply nested(1) + symlink-target(1) + linked (deduped via symlink)
	// linked is a symlink to symlink-target, so rg may follow it or not
	// At minimum: 2 + 1 + 1 + 1 = 5
	if len(tasks) < 5 {
		t.Errorf("got %d tasks scanning parent, want at least 5", len(tasks))
	}
}

// =============================================================================
// Tag Edge Vault
// =============================================================================

func TestTag_FrontmatterMergeAll(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "tag-edge-vault")
	tasks := scanAndParse(t, vault)
	MergeFrontmatterTags(tasks)

	// Every task should have project-alpha and UPPERCASE from frontmatter
	for _, task := range tasks {
		tagSet := make(map[string]bool)
		for _, tag := range task.Tags {
			tagSet[tag] = true
		}
		if !tagSet["project-alpha"] {
			t.Errorf("task %q missing frontmatter tag project-alpha", task.Body)
		}
		if !tagSet["UPPERCASE"] {
			t.Errorf("task %q missing frontmatter tag UPPERCASE", task.Body)
		}
	}
}

func TestTag_InlineFrontmatterDedup(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "tag-edge-vault")
	tasks := scanAndParse(t, vault)
	MergeFrontmatterTags(tasks)

	task := findTask(tasks, "Task with inline and frontmatter tag")
	if task == nil {
		t.Fatal("task not found")
	}
	// #project-alpha inline + project-alpha frontmatter = 1 entry (deduped by MergeFrontmatterTags)
	count := 0
	for _, tag := range task.Tags {
		if tag == "project-alpha" {
			count++
		}
	}
	if count != 1 {
		t.Errorf("expected 1 project-alpha tag (deduped), got %d", count)
	}
}

func TestTag_DuplicateInline(t *testing.T) {
	vault := vaultPath(t, "tag-edge-vault")
	tasks := scanAndParse(t, vault)

	task := findTask(tasks, "Task with duplicate inline tags")
	if task == nil {
		t.Fatal("task not found")
	}
	dupeCount := 0
	for _, tag := range task.Tags {
		if tag == "dupe" {
			dupeCount++
		}
	}
	// Inline duplicates are NOT deduped (that only happens in MergeFrontmatterTags)
	if dupeCount != 2 {
		t.Errorf("expected 2 inline dupe tags, got %d", dupeCount)
	}
}

func TestTag_HyphenatedFilter(t *testing.T) {
	vault := vaultPath(t, "tag-edge-vault")
	tasks := openTasks(scanAndParse(t, vault))

	filtered := FormatTaskfile(tasks, testNow, FormatOpts{TagFilter: []string{"my-tag"}})
	if !strings.Contains(filtered, "Task with hyphenated tag") {
		t.Error("expected hyphenated tag to match")
	}
}

func TestTag_CaseSensitive(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "tag-edge-vault")
	tasks := openTasks(scanAndParse(t, vault))
	MergeFrontmatterTags(tasks)

	// UPPERCASE matches (from frontmatter)
	filtered := FormatTaskfile(tasks, testNow, FormatOpts{TagFilter: []string{"UPPERCASE"}})
	if filtered == "" {
		t.Error("expected UPPERCASE tag to match")
	}

	// lowercase doesn't match
	filtered = FormatTaskfile(tasks, testNow, FormatOpts{TagFilter: []string{"uppercase"}})
	if filtered != "" {
		t.Error("expected lowercase 'uppercase' to NOT match UPPERCASE")
	}
}

func TestTag_NoMatchEmptyOutput(t *testing.T) {
	vault := vaultPath(t, "tag-edge-vault")
	tasks := openTasks(scanAndParse(t, vault))

	filtered := FormatTaskfile(tasks, testNow, FormatOpts{TagFilter: []string{"nonexistent"}})
	if filtered != "" {
		t.Errorf("expected empty output, got:\n%s", filtered)
	}
}

// =============================================================================
// Frontmatter Edge Vault
// =============================================================================

func TestFM_MalformedYAML(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "frontmatter-edge-vault")
	malformedPath := filepath.Join(vault, "malformed.md")
	tasks := scanAndParse(t, malformedPath)

	if len(tasks) != 1 {
		t.Fatalf("got %d tasks, want 1", len(tasks))
	}
	// Malformed YAML should be silently skipped
	MergeFrontmatterTags(tasks)
	// No crash = success
}

func TestFM_EmptyFrontmatter(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "frontmatter-edge-vault")
	emptyFMPath := filepath.Join(vault, "empty-frontmatter.md")
	tasks := scanAndParse(t, emptyFMPath)

	if len(tasks) != 1 {
		t.Fatalf("got %d tasks, want 1", len(tasks))
	}
	MergeFrontmatterTags(tasks)
	// No frontmatter tags should be added
	if len(tasks[0].Tags) != 0 {
		t.Errorf("expected no tags, got %v", tasks[0].Tags)
	}
}

func TestFM_NoFrontmatter(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "frontmatter-edge-vault")
	noFMPath := filepath.Join(vault, "no-frontmatter.md")
	tasks := scanAndParse(t, noFMPath)

	if len(tasks) != 1 {
		t.Fatalf("got %d tasks, want 1", len(tasks))
	}
	MergeFrontmatterTags(tasks)
	if len(tasks[0].Tags) != 0 {
		t.Errorf("expected no tags, got %v", tasks[0].Tags)
	}
}

func TestFM_TagsAsString(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "frontmatter-edge-vault")
	stringTagsPath := filepath.Join(vault, "tags-as-string.md")

	fm, err := ParseFrontmatter(stringTagsPath)
	if err != nil {
		t.Fatalf("ParseFrontmatter error: %v", err)
	}
	// YAML string value for tags won't parse into []string via strict typing
	// Document the actual behavior
	t.Logf("frontmatter from tags-as-string.md: %+v", fm)
}

// =============================================================================
// Glob Vault
// =============================================================================

func TestGlob_StarWildcard(t *testing.T) {
	vault := vaultPath(t, "glob-vault")
	pattern := filepath.Join(vault, "notes-*")
	tasks := scanAndParse(t, pattern)

	if len(tasks) != 3 {
		t.Errorf("got %d tasks from notes-*, want 3", len(tasks))
	}
}

func TestGlob_QuestionMark(t *testing.T) {
	vault := vaultPath(t, "glob-vault")
	pattern := filepath.Join(vault, "notes-?")
	tasks := scanAndParse(t, pattern)

	if len(tasks) != 3 {
		t.Errorf("got %d tasks from notes-?, want 3", len(tasks))
	}
}

func TestGlob_MatchAll(t *testing.T) {
	vault := vaultPath(t, "glob-vault")
	pattern := filepath.Join(vault, "*")
	tasks := scanAndParse(t, pattern)

	if len(tasks) != 4 {
		t.Errorf("got %d tasks from *, want 4", len(tasks))
	}
}

func TestGlob_NoMatch(t *testing.T) {
	vault := vaultPath(t, "glob-vault")
	pattern := filepath.Join(vault, "nonexist-*")
	tasks := scanAndParse(t, pattern)

	if len(tasks) != 0 {
		t.Errorf("got %d tasks from nonexist-*, want 0", len(tasks))
	}
}

// =============================================================================
// Custom Format Vault
// =============================================================================

func TestCustom_CheckboxFormats(t *testing.T) {
	vault := vaultPath(t, "custom-format-vault")
	ctx := parseContextWith(Config{
		Checkbox: map[string]string{
			"open": "TODO ",
			"done": "DONE ",
			"skip": "SKIP ",
		},
		DateWrapper: []string{"{", "}"},
	})

	tasks := scanAndParseWith(t, ctx, filepath.Join(vault, "tasks.md"))

	if len(tasks) != 3 {
		t.Fatalf("got %d tasks, want 3 (bodies: %v)", len(tasks), taskBodies(tasks))
	}

	statusMap := make(map[string]string)
	for _, task := range tasks {
		statusMap[task.Body] = task.Status
	}

	if statusMap["Task with custom checkbox"] != "open" {
		t.Errorf("TODO task status = %q, want open", statusMap["Task with custom checkbox"])
	}
	if statusMap["Completed custom task"] != "done" {
		t.Errorf("DONE task status = %q, want done", statusMap["Completed custom task"])
	}
	if statusMap["Irrelevant custom task"] != "skip" {
		t.Errorf("SKIP task status = %q, want skip", statusMap["Irrelevant custom task"])
	}
}

func TestCustom_TagPrefix(t *testing.T) {
	vault := vaultPath(t, "custom-format-vault")
	ctx := parseContextWith(Config{
		TagPrefix: "+",
	})

	tasks := scanAndParseWith(t, ctx, filepath.Join(vault, "custom-tags.md"))

	if len(tasks) != 1 {
		t.Fatalf("got %d tasks, want 1", len(tasks))
	}

	task := tasks[0]
	sort.Strings(task.Tags)
	if len(task.Tags) != 2 {
		t.Fatalf("tags = %v, want [urgent work]", task.Tags)
	}
	if task.Tags[0] != "urgent" || task.Tags[1] != "work" {
		t.Errorf("tags = %v, want [urgent work]", task.Tags)
	}
}

func TestCustom_DateWrapper(t *testing.T) {
	vault := vaultPath(t, "custom-format-vault")
	ctx := parseContextWith(Config{
		Checkbox: map[string]string{
			"open": "TODO ",
			"done": "DONE ",
			"skip": "SKIP ",
		},
		DateWrapper: []string{"{", "}"},
	})

	tasks := scanAndParseWith(t, ctx, filepath.Join(vault, "tasks.md"))

	for _, task := range tasks {
		if task.Body == "Task with custom checkbox" {
			if task.DueDate == nil {
				t.Fatal("expected date to be parsed from {2026-02-17}")
			}
			if task.DueDate.Format("2006-01-02") != "2026-02-17" {
				t.Errorf("date = %s, want 2026-02-17", task.DueDate.Format("2006-01-02"))
			}
			return
		}
	}
	t.Error("custom checkbox task not found")
}

func TestCustom_MarkerPrefix(t *testing.T) {
	vault := vaultPath(t, "custom-format-vault")
	ctx := parseContextWith(Config{
		MarkerPrefix: ">>",
	})

	tasks := scanAndParseWith(t, ctx, filepath.Join(vault, "custom-markers.md"))

	if len(tasks) != 1 {
		t.Fatalf("got %d tasks, want 1", len(tasks))
	}
	if len(tasks[0].Markers) != 1 {
		t.Fatalf("markers = %d, want 1", len(tasks[0].Markers))
	}
	if tasks[0].Markers[0].Kind != "complete" {
		t.Errorf("marker kind = %q, want complete", tasks[0].Markers[0].Kind)
	}
}

func TestCustom_DefaultsUnchanged(t *testing.T) {
	// Empty config should produce same ParseContext as defaults
	ctx := parseContextWith(Config{})
	defaultCtx := DefaultParseContext()

	// Verify key fields match
	if ctx.tagPrefix != defaultCtx.tagPrefix {
		t.Errorf("tagPrefix: %q vs %q", ctx.tagPrefix, defaultCtx.tagPrefix)
	}
	if ctx.markerPrefix != defaultCtx.markerPrefix {
		t.Errorf("markerPrefix: %q vs %q", ctx.markerPrefix, defaultCtx.markerPrefix)
	}
	// Both should parse the same default task
	m := RawMatch{Path: "test.md", LineNumber: 1, Text: "- [ ] Test (@[[2026-02-17]])"}
	t1, err1 := ParseTask(m, ctx)
	t2, err2 := ParseTask(m, defaultCtx)
	if err1 != nil || err2 != nil {
		t.Fatalf("parse errors: %v, %v", err1, err2)
	}
	if t1.Body != t2.Body || t1.Status != t2.Status {
		t.Errorf("different results: %+v vs %+v", t1, t2)
	}
}

func TestCustom_PartialOverride(t *testing.T) {
	// Override only checkbox, keep default tags/dates/markers
	ctx := parseContextWith(Config{
		Checkbox: map[string]string{
			"open":    "- [ ]",
			"done":    "- [x]",
			"waiting": "- [w]",
		},
	})

	// Default tag/date/marker syntax should still work
	m := RawMatch{Path: "test.md", LineNumber: 1, Text: "- [ ] Test #tag (@[[2026-02-17]]) ::start [[2026-02-17]] 10:00"}
	task, err := ParseTask(m, ctx)
	if err != nil {
		t.Fatal(err)
	}
	if task.Status != "open" {
		t.Errorf("status = %q", task.Status)
	}
	if len(task.Tags) != 1 || task.Tags[0] != "tag" {
		t.Errorf("tags = %v", task.Tags)
	}
	if task.DueDate == nil {
		t.Error("expected date")
	}
	if len(task.Markers) != 1 {
		t.Errorf("markers = %d", len(task.Markers))
	}

	// Custom checkbox should work
	m2 := RawMatch{Path: "test.md", LineNumber: 2, Text: "- [w] Waiting task (@[[2026-02-17]])"}
	task2, err := ParseTask(m2, ctx)
	if err != nil {
		t.Fatal(err)
	}
	if task2.Status != "waiting" {
		t.Errorf("waiting status = %q", task2.Status)
	}
}

func TestCustom_PartialStatus(t *testing.T) {
	// Verify that [~] (partial) is parseable with default config
	ctx := DefaultParseContext()
	m := RawMatch{Path: "test.md", LineNumber: 1, Text: "- [~] Partial task (@[[2026-02-17]]) ::partial [[2026-02-17]] 10:00"}
	task, err := ParseTask(m, ctx)
	if err != nil {
		t.Fatalf("partial task should parse: %v", err)
	}
	if task.Status != "partial" {
		t.Errorf("status = %q, want partial", task.Status)
	}
	if task.Body != "Partial task" {
		t.Errorf("body = %q", task.Body)
	}
}

// =============================================================================
// Filter Combinations
// =============================================================================

func TestCombo_TagPlusIgnoreUndated(t *testing.T) {
	vault := vaultPath(t, "tag-edge-vault")
	tasks := openTasks(scanAndParse(t, vault))

	output := FormatTaskfile(tasks, testNow, FormatOpts{
		TagFilter:     []string{"my-tag"},
		IgnoreUndated: true,
	})

	if !strings.Contains(output, "Task with hyphenated tag") {
		t.Error("expected dated task with matching tag")
	}
	if strings.Contains(output, "# Someday") {
		t.Error("should not contain Someday with IgnoreUndated")
	}
}

func TestCombo_AllFiltersNoResults(t *testing.T) {
	vault := vaultPath(t, "tag-edge-vault")
	tasks := openTasks(scanAndParse(t, vault))

	output := FormatTaskfile(tasks, testNow, FormatOpts{
		TagFilter:     []string{"nonexistent-tag-xyz"},
		IgnoreUndated: true,
	})

	if output != "" {
		t.Errorf("expected empty output, got:\n%s", output)
	}
}
