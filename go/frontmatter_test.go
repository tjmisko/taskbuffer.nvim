package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestParseFrontmatterTags_WithTags(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ntags:\n  - sspi\n  - project\n---\n# Content\n"), 0644)

	tags, err := ParseFrontmatterTags(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(tags) != 2 || tags[0] != "sspi" || tags[1] != "project" {
		t.Errorf("tags = %v, want [sspi project]", tags)
	}
}

func TestParseFrontmatterTags_NoFrontmatter(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("# Just a heading\nSome content\n"), 0644)

	tags, err := ParseFrontmatterTags(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(tags) != 0 {
		t.Errorf("tags = %v, want empty", tags)
	}
}

func TestParseFrontmatterTags_EmptyTags(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ntags: []\n---\n"), 0644)

	tags, err := ParseFrontmatterTags(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(tags) != 0 {
		t.Errorf("tags = %v, want empty", tags)
	}
}

func TestParseFrontmatterTags_NoTagsField(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ntitle: My Note\n---\n"), 0644)

	tags, err := ParseFrontmatterTags(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(tags) != 0 {
		t.Errorf("tags = %v, want empty", tags)
	}
}

func TestParseFrontmatterTags_Cached(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ntags:\n  - cached\n---\n"), 0644)

	tags1, _ := ParseFrontmatterTags(f)
	// Overwrite file — cached result should still be returned
	os.WriteFile(f, []byte("---\ntags:\n  - different\n---\n"), 0644)
	tags2, _ := ParseFrontmatterTags(f)

	if len(tags1) != 1 || tags1[0] != "cached" {
		t.Errorf("first call: tags = %v", tags1)
	}
	if len(tags2) != 1 || tags2[0] != "cached" {
		t.Errorf("second call should be cached: tags = %v", tags2)
	}
}

func TestMergeFrontmatterTags_MergesAndDeduplicates(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ntags:\n  - project\n  - sspi\n---\n"), 0644)

	tasks := []Task{
		{FilePath: f, Tags: []string{"sspi", "inline"}},
	}
	MergeFrontmatterTags(tasks)

	// Should have sspi, inline, project (sspi not duplicated)
	if len(tasks[0].Tags) != 3 {
		t.Fatalf("tags count = %d, want 3: %v", len(tasks[0].Tags), tasks[0].Tags)
	}
	tagSet := make(map[string]bool)
	for _, tag := range tasks[0].Tags {
		tagSet[tag] = true
	}
	for _, want := range []string{"sspi", "inline", "project"} {
		if !tagSet[want] {
			t.Errorf("missing tag %q in %v", want, tasks[0].Tags)
		}
	}
}

func TestParseFrontmatter_CustomDueKey(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ndeadline: 2026-04-01\ntags:\n  - work\n---\n"), 0644)

	fm, err := ParseFrontmatter(f)
	if err != nil {
		t.Fatal(err)
	}
	if got := fm.GetString("deadline"); got != "2026-04-01" {
		t.Errorf("GetString(deadline) = %q, want 2026-04-01", got)
	}
	if got := fm.GetString("due"); got != "" {
		t.Errorf("GetString(due) = %q, want empty", got)
	}
}

func TestParseFrontmatter_CustomStatusKey(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\nstate: finished\n---\n"), 0644)

	fm, err := ParseFrontmatter(f)
	if err != nil {
		t.Fatal(err)
	}
	if got := fm.GetString("state"); got != "finished" {
		t.Errorf("GetString(state) = %q, want finished", got)
	}
}

func TestMergeFrontmatterDue_InheritsWhenNoDueDate(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ndue: 2026-05-10\ntags:\n  - work\n---\n"), 0644)

	tasks := []Task{
		{FilePath: f, LineNumber: 5, Body: "undated task"},
	}
	MergeFrontmatterDue(tasks, FrontmatterConfig{}, "2006-01-02", nil)

	if tasks[0].DueDate == nil {
		t.Fatal("expected DueDate to be set from frontmatter")
	}
	want := time.Date(2026, 5, 10, 0, 0, 0, 0, time.UTC)
	if !tasks[0].DueDate.Equal(want) {
		t.Errorf("DueDate = %v, want %v", tasks[0].DueDate, want)
	}
}

func TestMergeFrontmatterDue_InlineWins(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ndue: 2026-05-10\n---\n"), 0644)

	inlineDate := time.Date(2026, 3, 15, 0, 0, 0, 0, time.UTC)
	tasks := []Task{
		{FilePath: f, LineNumber: 5, Body: "dated task", DueDate: &inlineDate},
	}
	MergeFrontmatterDue(tasks, FrontmatterConfig{}, "2006-01-02", nil)

	if !tasks[0].DueDate.Equal(inlineDate) {
		t.Errorf("DueDate changed to %v, want inline date %v", tasks[0].DueDate, inlineDate)
	}
}

func TestMergeFrontmatterDue_InheritDueFalse(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ndue: 2026-05-10\n---\n"), 0644)

	inheritFalse := false
	tasks := []Task{
		{FilePath: f, LineNumber: 5, Body: "undated task"},
	}
	MergeFrontmatterDue(tasks, FrontmatterConfig{InheritDue: &inheritFalse}, "2006-01-02", nil)

	if tasks[0].DueDate != nil {
		t.Errorf("DueDate should be nil when inherit_due=false, got %v", tasks[0].DueDate)
	}
}

func TestMergeFrontmatterDue_RequireTags(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()

	// File with required tag
	f1 := filepath.Join(dir, "has-tag.md")
	os.WriteFile(f1, []byte("---\ndue: 2026-05-10\ntags:\n  - project\n---\n"), 0644)

	// File without required tag
	f2 := filepath.Join(dir, "no-tag.md")
	os.WriteFile(f2, []byte("---\ndue: 2026-05-10\ntags:\n  - notes\n---\n"), 0644)

	tasks := []Task{
		{FilePath: f1, LineNumber: 5, Body: "task in project file"},
		{FilePath: f2, LineNumber: 5, Body: "task in notes file"},
	}
	fmCfg := FrontmatterConfig{RequireTags: []string{"project"}}
	MergeFrontmatterDue(tasks, fmCfg, "2006-01-02", nil)

	if tasks[0].DueDate == nil {
		t.Error("task with matching tag should inherit due date")
	}
	if tasks[1].DueDate != nil {
		t.Error("task without matching tag should not inherit due date")
	}
}

func TestMergeFrontmatterDue_WithTime(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ndue: \"2026-05-10 14:30\"\n---\n"), 0644)

	tasks := []Task{
		{FilePath: f, LineNumber: 5, Body: "timed task"},
	}
	MergeFrontmatterDue(tasks, FrontmatterConfig{}, "2006-01-02", nil)

	if tasks[0].DueDate == nil {
		t.Fatal("expected DueDate to be set")
	}
	if tasks[0].DueTime != "14:30" {
		t.Errorf("DueTime = %q, want 14:30", tasks[0].DueTime)
	}
}

func TestMergeFrontmatterDue_CustomDueKey(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ndeadline: 2026-06-01\n---\n"), 0644)

	tasks := []Task{
		{FilePath: f, LineNumber: 5, Body: "custom key task"},
	}
	fmCfg := FrontmatterConfig{DueKey: "deadline"}
	MergeFrontmatterDue(tasks, fmCfg, "2006-01-02", nil)

	if tasks[0].DueDate == nil {
		t.Fatal("expected DueDate from custom key 'deadline'")
	}
	want := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	if !tasks[0].DueDate.Equal(want) {
		t.Errorf("DueDate = %v, want %v", tasks[0].DueDate, want)
	}
}

func TestFilterCompletedFrontmatterTasks_ExcludesInheritedOnly(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "done-file.md")
	os.WriteFile(f, []byte("---\ndue: 2026-05-01\nstatus: done\ntags:\n  - project\n---\n"), 0644)

	tasks := []Task{
		{FilePath: f, LineNumber: 5, Body: "undated from done file"},        // DueDate nil
		{FilePath: f, LineNumber: 6, Body: "another undated from done file"}, // DueDate nil
	}

	result := FilterCompletedFrontmatterTasks(tasks, FrontmatterConfig{})
	if len(result) != 0 {
		t.Errorf("expected 0 tasks (all undated from done file), got %d", len(result))
	}
}

func TestFilterCompletedFrontmatterTasks_KeepsInlineDated(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "done-file.md")
	os.WriteFile(f, []byte("---\ndue: 2026-05-01\nstatus: done\n---\n"), 0644)

	inlineDate := time.Date(2026, 3, 15, 0, 0, 0, 0, time.UTC)
	tasks := []Task{
		{FilePath: f, LineNumber: 5, Body: "undated task"},                                // should be filtered
		{FilePath: f, LineNumber: 6, Body: "inline dated task", DueDate: &inlineDate}, // should survive
	}

	result := FilterCompletedFrontmatterTasks(tasks, FrontmatterConfig{})
	if len(result) != 1 {
		t.Fatalf("expected 1 task, got %d", len(result))
	}
	if result[0].Body != "inline dated task" {
		t.Errorf("wrong task survived: %q", result[0].Body)
	}
}

func TestFilterCompletedFrontmatterTasks_CustomDoneValues(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "archived.md")
	os.WriteFile(f, []byte("---\ndue: 2026-05-01\nstatus: archived\n---\n"), 0644)

	tasks := []Task{
		{FilePath: f, LineNumber: 5, Body: "task in archived file"},
	}

	// Default done values don't include "archived"
	result := FilterCompletedFrontmatterTasks(tasks, FrontmatterConfig{})
	if len(result) != 1 {
		t.Error("task should survive with default done values (archived not in list)")
	}

	// Custom done values include "archived"
	ResetFrontmatterCache()
	result = FilterCompletedFrontmatterTasks(tasks, FrontmatterConfig{DoneValues: []string{"archived", "done"}})
	if len(result) != 0 {
		t.Error("task should be filtered with custom done values including 'archived'")
	}
}

func TestFilterCompletedFrontmatterTasks_KeepsFromActiveFiles(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "active.md")
	os.WriteFile(f, []byte("---\ndue: 2026-05-01\nstatus: active\n---\n"), 0644)

	tasks := []Task{
		{FilePath: f, LineNumber: 5, Body: "undated task from active file"},
	}

	result := FilterCompletedFrontmatterTasks(tasks, FrontmatterConfig{})
	if len(result) != 1 {
		t.Error("task from active file should not be filtered")
	}
}
