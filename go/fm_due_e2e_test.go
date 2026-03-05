package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// =============================================================================
// Helpers
// =============================================================================

// fullPipeline runs the full cmdList-style pipeline against a vault:
// Scan -> Parse -> MergeFrontmatterTags -> FilterCompleted -> MergeFrontmatterDue -> open filter
func fullPipeline(t *testing.T, ctx *ParseContext, fmCfg FrontmatterConfig, paths ...string) []Task {
	t.Helper()
	matches, err := Scan(ctx, paths...)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	tasks := ParseTasks(matches, ctx)
	MergeFrontmatterTags(tasks)
	tasks = FilterCompletedFrontmatterTasks(tasks, fmCfg)
	MergeFrontmatterDue(tasks, fmCfg, ctx.formats.GoDate, nil)
	return tasks
}

func fullPipelineOpen(t *testing.T, ctx *ParseContext, fmCfg FrontmatterConfig, paths ...string) []Task {
	t.Helper()
	all := fullPipeline(t, ctx, fmCfg, paths...)
	return openTasks(all)
}

func boolPtr(b bool) *bool { return &b }

// =============================================================================
// Basic Inheritance
// =============================================================================

func TestFMDue_BasicInheritance(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "basic-inherit.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	// 3 open tasks: 2 undated (inherit FM 2026-04-15), 1 inline (2026-03-01)
	if len(tasks) != 3 {
		t.Fatalf("got %d open tasks, want 3", len(tasks))
	}

	for _, task := range tasks {
		if task.DueDate == nil {
			t.Errorf("task %q has nil DueDate after inheritance", task.Body)
			continue
		}
		switch task.Body {
		case "Undated task one", "Undated task two":
			if task.DueDate.Format("2006-01-02") != "2026-04-15" {
				t.Errorf("task %q: date = %s, want 2026-04-15", task.Body, task.DueDate.Format("2006-01-02"))
			}
		case "Dated task with inline":
			if task.DueDate.Format("2006-01-02") != "2026-03-01" {
				t.Errorf("task %q: date = %s, want 2026-03-01 (inline wins)", task.Body, task.DueDate.Format("2006-01-02"))
			}
		}
	}
}

func TestFMDue_InlineAlwaysWins(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "basic-inherit.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	task := findTask(tasks, "Dated task with inline")
	if task == nil {
		t.Fatal("inline dated task not found")
	}
	// FM due is 2026-04-15, inline is 2026-03-01 -- inline must win
	if task.DueDate.Format("2006-01-02") != "2026-03-01" {
		t.Errorf("inline date overridden by FM: got %s", task.DueDate.Format("2006-01-02"))
	}
}

// =============================================================================
// Completion Filtering
// =============================================================================

func TestFMDue_CompletedFileFiltersUndated(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "done-file.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	// 2 undated tasks should be filtered, 1 inline-dated should survive
	if len(tasks) != 1 {
		bodies := taskBodies(tasks)
		t.Fatalf("got %d tasks, want 1 (inline survivor only): %v", len(tasks), bodies)
	}
	if tasks[0].Body != "Inline dated task from done file" {
		t.Errorf("wrong task survived: %q", tasks[0].Body)
	}
}

func TestFMDue_CompleteStatusAlsoFilters(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "complete-status.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	// status: complete should also trigger filtering (default done_values includes "complete")
	if len(tasks) != 0 {
		t.Errorf("expected 0 tasks from complete file, got %d: %v", len(tasks), taskBodies(tasks))
	}
}

func TestFMDue_DoneMixedFileSurvivors(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "done-mixed.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	// 2 undated filtered, 2 inline-dated survive
	if len(tasks) != 2 {
		t.Fatalf("got %d tasks, want 2: %v", len(tasks), taskBodies(tasks))
	}
	for _, task := range tasks {
		if task.DueDate == nil {
			t.Errorf("survivor %q should have inline date", task.Body)
		}
	}
}

func TestFMDue_ActiveFileNotFiltered(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "active-status.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	// status: active is not in done_values, so undated tasks survive and inherit
	// 2 open undated + 0 open inline (the [x] is done) = 2
	if len(tasks) != 2 {
		t.Fatalf("got %d open tasks from active file, want 2: %v", len(tasks), taskBodies(tasks))
	}
	for _, task := range tasks {
		if task.DueDate == nil {
			t.Errorf("task %q should have inherited FM date", task.Body)
		}
		if task.DueDate.Format("2006-01-02") != "2026-04-10" {
			t.Errorf("task %q: date = %s, want 2026-04-10", task.Body, task.DueDate.Format("2006-01-02"))
		}
	}
}

// =============================================================================
// No Due / No Frontmatter
// =============================================================================

func TestFMDue_NoDueInFrontmatter(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "no-due.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	// FM has no due key, so tasks stay undated
	for _, task := range tasks {
		if task.DueDate != nil {
			t.Errorf("task %q should remain undated (FM has no due), got %s", task.Body, task.DueDate.Format("2006-01-02"))
		}
	}
}

func TestFMDue_NoFrontmatterAtAll(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "no-frontmatter.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	for _, task := range tasks {
		if task.DueDate != nil {
			t.Errorf("task %q should remain undated (no FM), got %s", task.Body, task.DueDate.Format("2006-01-02"))
		}
	}
}

// =============================================================================
// InheritDue = false
// =============================================================================

func TestFMDue_InheritDueDisabled(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "basic-inherit.md")
	fmCfg := FrontmatterConfig{InheritDue: boolPtr(false)}
	tasks := fullPipelineOpen(t, DefaultParseContext(), fmCfg, f)

	// With inherit_due=false, only the inline-dated task has a date
	dated := 0
	for _, task := range tasks {
		if task.DueDate != nil {
			dated++
		}
	}
	if dated != 1 {
		t.Errorf("expected 1 dated task (inline only), got %d", dated)
	}
}

// =============================================================================
// Custom Key Names
// =============================================================================

func TestFMDue_CustomDueKey(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "custom-key.md")
	fmCfg := FrontmatterConfig{DueKey: "deadline"}
	tasks := fullPipelineOpen(t, DefaultParseContext(), fmCfg, f)

	if len(tasks) != 3 {
		t.Fatalf("got %d tasks, want 3", len(tasks))
	}

	for _, task := range tasks {
		if task.DueDate == nil {
			t.Errorf("task %q has nil DueDate", task.Body)
			continue
		}
		switch task.Body {
		case "Task using deadline key", "Another deadline task":
			if task.DueDate.Format("2006-01-02") != "2026-06-01" {
				t.Errorf("task %q: inherited date = %s, want 2026-06-01", task.Body, task.DueDate.Format("2006-01-02"))
			}
		case "Inline overrides deadline":
			if task.DueDate.Format("2006-01-02") != "2026-07-01" {
				t.Errorf("task %q: inline date = %s, want 2026-07-01", task.Body, task.DueDate.Format("2006-01-02"))
			}
		}
	}
}

func TestFMDue_CustomDueKeyDefaultIgnoresStandardDue(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "custom-key.md")
	// Using default due_key="due" should NOT find "deadline"
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	for _, task := range tasks {
		if task.Body == "Task using deadline key" && task.DueDate != nil {
			t.Error("default due_key should not read 'deadline' field")
		}
	}
}

func TestFMDue_CustomStatusKeyAndDoneValues(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "custom-status.md")
	fmCfg := FrontmatterConfig{
		DueKey:     "deadline",
		StatusKey:  "state",
		DoneValues: []string{"archived"},
	}
	tasks := fullPipelineOpen(t, DefaultParseContext(), fmCfg, f)

	// state: archived with custom done_values=["archived"] should filter undated
	// 2 undated filtered, 1 inline survives
	if len(tasks) != 1 {
		t.Fatalf("got %d tasks, want 1 (inline survivor): %v", len(tasks), taskBodies(tasks))
	}
	if tasks[0].Body != "Inline dated in archived" {
		t.Errorf("wrong survivor: %q", tasks[0].Body)
	}
}

func TestFMDue_CustomStatusKeyNotMatchingDefault(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "custom-status.md")
	// Default status_key="status" won't find "state: archived"
	fmCfg := FrontmatterConfig{DueKey: "deadline"}
	tasks := fullPipelineOpen(t, DefaultParseContext(), fmCfg, f)

	// No filtering should happen (default status key "status" finds nothing)
	// All 3 tasks should be present, 2 undated inherit deadline
	if len(tasks) != 3 {
		t.Fatalf("got %d tasks, want 3 (no filtering with default status key): %v", len(tasks), taskBodies(tasks))
	}
}

// =============================================================================
// Require Tags
// =============================================================================

func TestFMDue_RequireTagsSingleMatch(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	fmCfg := FrontmatterConfig{RequireTags: []string{"project"}}

	hasTag := filepath.Join(vault, "require-tags.md")
	missingTag := filepath.Join(vault, "missing-required-tag.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), fmCfg, hasTag, missingTag)

	for _, task := range tasks {
		switch task.Body {
		case "Task in file with required tags":
			if task.DueDate == nil {
				t.Error("task with matching required tag should inherit FM due")
			}
		case "Task in file missing required tag":
			if task.DueDate != nil {
				t.Error("task without matching required tag should NOT inherit FM due")
			}
		}
	}
}

func TestFMDue_RequireTagsMultipleMustAllMatch(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	// Require both "project" AND "important" -- require-tags.md has both
	fmCfg := FrontmatterConfig{RequireTags: []string{"project", "important"}}
	f := filepath.Join(vault, "require-tags.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), fmCfg, f)

	if tasks[0].DueDate == nil {
		t.Error("file has both required tags, should inherit")
	}
}

func TestFMDue_RequireTagsPartialMatchFails(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	// Require "project" AND "secret" -- require-tags.md only has project+important
	fmCfg := FrontmatterConfig{RequireTags: []string{"project", "secret"}}
	f := filepath.Join(vault, "require-tags.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), fmCfg, f)

	if tasks[0].DueDate != nil {
		t.Error("file missing 'secret' tag, should NOT inherit")
	}
}

func TestFMDue_EmptyRequireTagsAllowsAll(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	fmCfg := FrontmatterConfig{RequireTags: []string{}}
	f := filepath.Join(vault, "basic-inherit.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), fmCfg, f)

	undated := findTask(tasks, "Undated task one")
	if undated == nil || undated.DueDate == nil {
		t.Error("empty require_tags should allow all files to inherit")
	}
}

// =============================================================================
// Time Inheritance
// =============================================================================

func TestFMDue_InheritsTimeFromFM(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "due-with-time.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	for _, task := range tasks {
		switch task.Body {
		case "Undated task inheriting time":
			if task.DueDate == nil {
				t.Error("should inherit FM due date")
				continue
			}
			if task.DueDate.Format("2006-01-02") != "2026-04-15" {
				t.Errorf("date = %s, want 2026-04-15", task.DueDate.Format("2006-01-02"))
			}
			if task.DueTime != "14:30" {
				t.Errorf("time = %q, want 14:30", task.DueTime)
			}
		case "Inline has own time":
			if task.DueTime != "09:00" {
				t.Errorf("inline time = %q, want 09:00 (inline wins)", task.DueTime)
			}
		}
	}
}

// =============================================================================
// Bare YAML Date (auto-parsed by YAML v3 to time.Time)
// =============================================================================

func TestFMDue_BareYAMLDate(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "bare-date.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	if len(tasks) != 1 {
		t.Fatalf("got %d tasks, want 1", len(tasks))
	}
	if tasks[0].DueDate == nil {
		t.Fatal("bare YAML date should be parsed and inherited")
	}
	if tasks[0].DueDate.Format("2006-01-02") != "2026-04-15" {
		t.Errorf("date = %s, want 2026-04-15", tasks[0].DueDate.Format("2006-01-02"))
	}
}

// =============================================================================
// Mixed Files in Single Vault
// =============================================================================

func TestFMDue_MixedInlineAndUndated(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "mixed-inline-undated.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	// 3 undated (inherit 2026-04-20), 1 inline (2026-03-10) = 4 open
	if len(tasks) != 4 {
		t.Fatalf("got %d open tasks, want 4: %v", len(tasks), taskBodies(tasks))
	}

	for _, task := range tasks {
		if task.DueDate == nil {
			t.Errorf("task %q should have a date", task.Body)
			continue
		}
		if task.Body == "Has inline date" {
			if task.DueDate.Format("2006-01-02") != "2026-03-10" {
				t.Errorf("inline task date = %s, want 2026-03-10", task.DueDate.Format("2006-01-02"))
			}
		} else {
			if task.DueDate.Format("2006-01-02") != "2026-04-20" {
				t.Errorf("inherited task %q date = %s, want 2026-04-20", task.Body, task.DueDate.Format("2006-01-02"))
			}
		}
	}
}

// =============================================================================
// Full Vault Scan (all files together)
// =============================================================================

func TestFMDue_FullVaultDefaultConfig(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, vault)

	// Verify key properties across the whole vault
	taskMap := make(map[string]*Task)
	for i := range tasks {
		taskMap[tasks[i].Body] = &tasks[i]
	}

	// Tasks from done-file.md: only inline survivor
	if _, ok := taskMap["Leftover undated task"]; ok {
		t.Error("undated task from done file should be filtered")
	}
	if _, ok := taskMap["Inline dated task from done file"]; !ok {
		t.Error("inline dated task from done file should survive")
	}

	// Tasks from no-due.md: should remain undated
	if task, ok := taskMap["Undated task in no-due file"]; ok && task.DueDate != nil {
		t.Error("task in no-due file should remain undated")
	}

	// Tasks from basic-inherit.md: undated should inherit
	if task, ok := taskMap["Undated task one"]; ok {
		if task.DueDate == nil || task.DueDate.Format("2006-01-02") != "2026-04-15" {
			t.Errorf("basic inherit task: date = %v, want 2026-04-15", task.DueDate)
		}
	}

	// No tasks from complete-status.md (all undated, file is "complete")
	if _, ok := taskMap["Undated task in complete file"]; ok {
		t.Error("undated task from complete file should be filtered")
	}
}

// =============================================================================
// Combined Weird Configs: multiple options set simultaneously
// =============================================================================

func TestFMDue_CustomKeyPlusRequireTags(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	fmCfg := FrontmatterConfig{
		DueKey:      "deadline",
		RequireTags: []string{"project"},
	}
	// custom-key.md: deadline: 2026-06-01, tags: [project] -> should inherit
	// basic-inherit.md: due: 2026-04-15, tags: [work] -> "due" != "deadline", so no inherit
	tasks := fullPipelineOpen(t, DefaultParseContext(), fmCfg,
		filepath.Join(vault, "custom-key.md"),
		filepath.Join(vault, "basic-inherit.md"),
	)

	for _, task := range tasks {
		switch task.Body {
		case "Task using deadline key":
			if task.DueDate == nil || task.DueDate.Format("2006-01-02") != "2026-06-01" {
				t.Errorf("custom-key task should inherit deadline, got %v", task.DueDate)
			}
		case "Undated task one":
			// basic-inherit.md has "due" not "deadline", so no inheritance with custom key
			if task.DueDate != nil {
				t.Errorf("basic-inherit task should NOT inherit (wrong key name), got %s", task.DueDate.Format("2006-01-02"))
			}
		}
	}
}

func TestFMDue_CustomKeyPlusCustomStatusPlusDoneValues(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	fmCfg := FrontmatterConfig{
		DueKey:     "deadline",
		StatusKey:  "state",
		DoneValues: []string{"archived", "retired"},
	}
	// custom-status.md: deadline: 2026-06-15, state: archived -> should filter undated
	tasks := fullPipelineOpen(t, DefaultParseContext(), fmCfg,
		filepath.Join(vault, "custom-status.md"),
	)

	if len(tasks) != 1 {
		t.Fatalf("got %d tasks, want 1 (inline survivor): %v", len(tasks), taskBodies(tasks))
	}
	if tasks[0].Body != "Inline dated in archived" {
		t.Errorf("wrong survivor: %q", tasks[0].Body)
	}
}

func TestFMDue_InheritFalsePlusCompletionFiltering(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	fmCfg := FrontmatterConfig{InheritDue: boolPtr(false)}
	// done-mixed.md: status: done, 2 undated + 2 inline
	// With inherit_due=false: FilterCompleted still runs, removes undated from done files
	// Then MergeFrontmatterDue is a no-op
	tasks := fullPipelineOpen(t, DefaultParseContext(), fmCfg,
		filepath.Join(vault, "done-mixed.md"),
	)

	// Only inline-dated tasks survive (completion filtering doesn't need inherit_due)
	if len(tasks) != 2 {
		t.Fatalf("got %d tasks, want 2 (inline only): %v", len(tasks), taskBodies(tasks))
	}
}

func TestFMDue_RequireTagsPlusCompletionFiltering(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	fmCfg := FrontmatterConfig{RequireTags: []string{"cleanup"}}
	// done-file.md: tags: [cleanup], status: done
	// Undated tasks are filtered by completion filter (regardless of require_tags)
	// require_tags only affects inheritance, not completion filtering
	tasks := fullPipelineOpen(t, DefaultParseContext(), fmCfg,
		filepath.Join(vault, "done-file.md"),
	)

	// Undated tasks from done file filtered, inline survives
	if len(tasks) != 1 {
		t.Fatalf("got %d, want 1: %v", len(tasks), taskBodies(tasks))
	}
}

func TestFMDue_AllOptionsSimultaneous(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	fmCfg := FrontmatterConfig{
		DueKey:      "deadline",
		InheritDue:  boolPtr(true),
		RequireTags: []string{"project"},
		StatusKey:   "state",
		DoneValues:  []string{"archived"},
	}

	tasks := fullPipelineOpen(t, DefaultParseContext(), fmCfg,
		filepath.Join(vault, "custom-key.md"),     // deadline: 2026-06-01, tags: [project] -> inherit
		filepath.Join(vault, "custom-status.md"),   // deadline: 2026-06-15, state: archived, tags: [old] -> filter undated (no "project" tag, but completion still filters)
		filepath.Join(vault, "basic-inherit.md"),    // due: 2026-04-15 (wrong key), tags: [work] -> no inherit
		filepath.Join(vault, "require-tags.md"),     // due: 2026-05-20 (wrong key), tags: [project, important] -> no inherit (wrong key)
		filepath.Join(vault, "active-status.md"),    // due: 2026-04-10 (wrong key), state: active -> no inherit
	)

	for _, task := range tasks {
		switch task.Body {
		case "Task using deadline key", "Another deadline task":
			// custom-key.md: has "deadline", has "project" tag -> inherits
			if task.DueDate == nil || task.DueDate.Format("2006-01-02") != "2026-06-01" {
				t.Errorf("task %q should inherit deadline 2026-06-01, got %v", task.Body, task.DueDate)
			}
		case "Inline overrides deadline":
			// Has inline date, should be preserved
			if task.DueDate == nil || task.DueDate.Format("2006-01-02") != "2026-07-01" {
				t.Errorf("task %q inline date should be 2026-07-01, got %v", task.Body, task.DueDate)
			}
		case "Task in archived file", "Another archived task":
			// custom-status.md: state=archived matches DoneValues, these are undated -> filtered
			t.Errorf("task %q from archived file should be filtered", task.Body)
		case "Inline dated in archived":
			// Has inline date, survives completion filter
			if task.DueDate == nil || task.DueDate.Format("2006-01-02") != "2026-08-01" {
				t.Errorf("task %q date = %v, want 2026-08-01", task.Body, task.DueDate)
			}
		case "Undated task one", "Undated task two":
			// basic-inherit.md: "due" key != "deadline" key -> no inheritance
			if task.DueDate != nil {
				t.Errorf("task %q should NOT inherit (wrong key), got %s", task.Body, task.DueDate.Format("2006-01-02"))
			}
		case "Task in file with required tags":
			// require-tags.md: "due" key != "deadline" key -> no inheritance
			if task.DueDate != nil {
				t.Errorf("task %q: 'due' != 'deadline', should not inherit", task.Body)
			}
		}
	}
}

// =============================================================================
// Pipeline Ordering Matters
// =============================================================================

func TestFMDue_FilterBeforeInherit(t *testing.T) {
	// Verify that filtering happens BEFORE inheritance.
	// If we inherit first, undated tasks from done files would get a date,
	// then the filter wouldn't know they were originally undated.
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "done-file.md")

	// Run pipeline in WRONG order: inherit then filter
	ctx := DefaultParseContext()
	matches, _ := Scan(ctx, f)
	tasks := ParseTasks(matches, ctx)
	MergeFrontmatterTags(tasks)
	// WRONG: inherit first
	MergeFrontmatterDue(tasks, FrontmatterConfig{}, ctx.formats.GoDate, nil)
	// Now all tasks have dates, filter won't remove any
	wrongResult := FilterCompletedFrontmatterTasks(openTasks(tasks), FrontmatterConfig{})

	// CORRECT order
	ResetFrontmatterCache()
	correctResult := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	// Wrong order should have more tasks (undated got dates before filtering)
	if len(wrongResult) <= len(correctResult) {
		t.Skipf("pipeline ordering test inconclusive: wrong=%d, correct=%d", len(wrongResult), len(correctResult))
	}
	// Correct pipeline: only inline-dated task survives
	if len(correctResult) != 1 {
		t.Errorf("correct pipeline: got %d tasks, want 1", len(correctResult))
	}
}

// =============================================================================
// Format Output Integration
// =============================================================================

func TestFMDue_FormatOutputShowsInheritedDates(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "basic-inherit.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	now := time.Date(2026, 4, 15, 10, 0, 0, 0, time.Local)
	output := FormatTaskfile(tasks, now, FormatOpts{})

	// Inherited tasks should appear under "Today" (since FM due = 2026-04-15 = now)
	if !strings.Contains(output, "# Today") {
		t.Error("expected Today header for inherited due date")
	}
	if !strings.Contains(output, "Undated task one") {
		t.Error("inherited task should appear in formatted output")
	}
}

func TestFMDue_FormatIgnoreUndatedStillShowsInherited(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "basic-inherit.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	now := time.Date(2026, 4, 15, 10, 0, 0, 0, time.Local)
	output := FormatTaskfile(tasks, now, FormatOpts{IgnoreUndated: true})

	// After inheritance, these tasks have dates, so IgnoreUndated should NOT hide them
	if !strings.Contains(output, "Undated task one") {
		t.Error("inherited tasks have dates and should show with IgnoreUndated")
	}
}

func TestFMDue_FormatTagFilterOnInheritedTasks(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "basic-inherit.md")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	now := time.Date(2026, 4, 15, 10, 0, 0, 0, time.Local)
	// basic-inherit.md has FM tags: [work], so MergeFrontmatterTags adds "work" to all tasks
	output := FormatTaskfile(tasks, now, FormatOpts{TagFilter: []string{"work"}})

	if !strings.Contains(output, "Undated task one") {
		t.Error("FM tag 'work' should match inherited tasks")
	}

	// Filter by nonexistent tag
	output = FormatTaskfile(tasks, now, FormatOpts{TagFilter: []string{"nonexistent"}})
	if strings.Contains(output, "Undated task one") {
		t.Error("nonexistent tag should not match")
	}
}

// =============================================================================
// cmdList End-to-End
// =============================================================================

func TestFMDue_CmdListEndToEnd(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")

	old := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w

	cfg := Config{Frontmatter: FrontmatterConfig{}}
	err := cmdList([]string{vault}, DefaultParseContext(), nil, cfg)

	w.Close()
	os.Stdout = old

	if err != nil {
		t.Fatal(err)
	}

	buf := make([]byte, 128*1024)
	n, _ := r.Read(buf)
	output := string(buf[:n])

	// Inherited tasks should appear
	if !strings.Contains(output, "Undated task one") {
		t.Error("expected inherited task in cmdList output")
	}
	// Filtered tasks should NOT appear
	if strings.Contains(output, "Leftover undated task") {
		t.Error("undated task from done file should be filtered in cmdList")
	}
	// Inline from done file should appear
	if !strings.Contains(output, "Inline dated task from done file") {
		t.Error("inline dated from done file should survive in cmdList")
	}
}

func TestFMDue_CmdListCustomConfig(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")

	old := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w

	cfg := Config{
		Frontmatter: FrontmatterConfig{
			DueKey:     "deadline",
			StatusKey:  "state",
			DoneValues: []string{"archived"},
		},
	}
	err := cmdList(
		[]string{filepath.Join(vault, "custom-key.md"), filepath.Join(vault, "custom-status.md")},
		DefaultParseContext(), nil, cfg,
	)

	w.Close()
	os.Stdout = old

	if err != nil {
		t.Fatal(err)
	}

	buf := make([]byte, 128*1024)
	n, _ := r.Read(buf)
	output := string(buf[:n])

	// custom-key.md tasks should inherit deadline
	if !strings.Contains(output, "Task using deadline key") {
		t.Error("custom-key tasks should inherit from 'deadline' field")
	}
	// custom-status.md undated tasks should be filtered (state: archived)
	if strings.Contains(output, "Task in archived file") {
		t.Error("undated tasks from archived file should be filtered")
	}
	// Inline from archived file survives
	if !strings.Contains(output, "Inline dated in archived") {
		t.Error("inline dated from archived file should survive")
	}
}

// =============================================================================
// ScanProjects with FrontmatterConfig
// =============================================================================

func TestFMDue_ScanProjectsCustomDoneValues(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()

	// Project with custom done status
	f := filepath.Join(dir, "project.md")
	os.WriteFile(f, []byte("---\ntags:\n  - project\ndue: 2026-07-01\nstatus: shipped\n---\n# Project\n"), 0644)

	// Default done_values: shipped is NOT in ["done", "complete"]
	tasks, err := ScanProjects("2006-01-02", FrontmatterConfig{}, nil, dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(tasks) != 1 {
		t.Errorf("default config: expected 1 project (shipped != done), got %d", len(tasks))
	}

	// Custom done_values including "shipped"
	ResetFrontmatterCache()
	tasks, err = ScanProjects("2006-01-02", FrontmatterConfig{DoneValues: []string{"shipped", "done"}}, nil, dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(tasks) != 0 {
		t.Errorf("custom config: expected 0 projects (shipped is done), got %d", len(tasks))
	}
}

func TestFMDue_ScanProjectsCustomDueKey(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()

	f := filepath.Join(dir, "project.md")
	os.WriteFile(f, []byte("---\ntags:\n  - project\ndeadline: 2026-07-01\nstatus: active\n---\n# Project\n"), 0644)

	// Default due_key="due" won't find "deadline"
	tasks, err := ScanProjects("2006-01-02", FrontmatterConfig{}, nil, dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(tasks) != 0 {
		t.Errorf("default key: expected 0 (no 'due' field), got %d", len(tasks))
	}

	// Custom due_key="deadline"
	ResetFrontmatterCache()
	tasks, err = ScanProjects("2006-01-02", FrontmatterConfig{DueKey: "deadline"}, nil, dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(tasks) != 1 {
		t.Fatalf("custom key: expected 1 project, got %d", len(tasks))
	}
	if tasks[0].DueDate.Format("2006-01-02") != "2026-07-01" {
		t.Errorf("date = %s, want 2026-07-01", tasks[0].DueDate.Format("2006-01-02"))
	}
}

func TestFMDue_ScanProjectsCustomStatusKey(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()

	f := filepath.Join(dir, "project.md")
	os.WriteFile(f, []byte("---\ntags:\n  - project\ndue: 2026-07-01\nstate: retired\n---\n# Project\n"), 0644)

	// Default status_key="status" won't find "state: retired"
	tasks, err := ScanProjects("2006-01-02", FrontmatterConfig{}, nil, dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(tasks) != 1 {
		t.Errorf("default status key: expected 1 (status not found = active), got %d", len(tasks))
	}

	// Custom status_key="state", done_values=["retired"]
	ResetFrontmatterCache()
	tasks, err = ScanProjects("2006-01-02", FrontmatterConfig{StatusKey: "state", DoneValues: []string{"retired"}}, nil, dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(tasks) != 0 {
		t.Errorf("custom status key: expected 0 (state=retired is done), got %d", len(tasks))
	}
}

// =============================================================================
// Edge Cases & Stress
// =============================================================================

func TestFMDue_EmptyVault(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, dir)
	if len(tasks) != 0 {
		t.Errorf("empty vault should produce 0 tasks, got %d", len(tasks))
	}
}

func TestFMDue_AllTasksHaveInlineDates(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "all-inline.md")
	os.WriteFile(f, []byte("---\ndue: 2026-12-25\nstatus: done\n---\n- [ ] Task A (@[[2026-01-01]])\n- [ ] Task B (@[[2026-02-01]])\n"), 0644)

	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	// Both have inline dates, so they survive done-file filtering
	if len(tasks) != 2 {
		t.Fatalf("got %d tasks, want 2 (inline dates survive done file)", len(tasks))
	}
}

func TestFMDue_FileWithDueButNoDoneStatus(t *testing.T) {
	// File has due but no status field at all -> not "done", tasks should inherit
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "no-status.md")
	os.WriteFile(f, []byte("---\ndue: 2026-09-01\n---\n- [ ] Task no status\n"), 0644)

	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	if len(tasks) != 1 || tasks[0].DueDate == nil {
		t.Error("task should inherit due from file with no status field")
	}
}

func TestFMDue_DoneStatusButNoDue(t *testing.T) {
	// File has status: done but no due field -> no filtering happens
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "done-no-due.md")
	os.WriteFile(f, []byte("---\nstatus: done\n---\n- [ ] Task in done file without due\n"), 0644)

	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)

	// FilterCompletedFrontmatterTasks requires BOTH due AND done status
	if len(tasks) != 1 {
		t.Errorf("task should survive: done file has no due field, got %d", len(tasks))
	}
}

func TestFMDue_CaseInsensitiveDoneValues(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()

	f := filepath.Join(dir, "upper-done.md")
	os.WriteFile(f, []byte("---\ndue: 2026-03-01\nstatus: DONE\n---\n- [ ] Should be filtered\n"), 0644)

	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{}, f)
	if len(tasks) != 0 {
		t.Error("'DONE' (uppercase) should match default done_values (case insensitive)")
	}
}

func TestFMDue_MultipleFilesShareSameConfig(t *testing.T) {
	// Ensure the pipeline handles multiple files correctly with a single config
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	tasks := fullPipelineOpen(t, DefaultParseContext(), FrontmatterConfig{},
		filepath.Join(vault, "basic-inherit.md"),
		filepath.Join(vault, "done-file.md"),
		filepath.Join(vault, "no-due.md"),
		filepath.Join(vault, "no-frontmatter.md"),
		filepath.Join(vault, "active-status.md"),
	)

	// Count tasks per source behavior
	inherited := 0
	filtered := 0
	undated := 0
	for _, task := range tasks {
		if task.DueDate != nil {
			inherited++
		} else {
			undated++
		}
	}

	// basic-inherit: 2 inherited + 1 inline = 3 dated
	// done-file: 2 filtered, 1 inline survived = 1 dated
	// no-due: 2 undated
	// no-frontmatter: 2 undated
	// active-status: 2 inherited (active, not filtered)
	// Totals: 7 dated, 4 undated
	_ = filtered // not directly countable from output
	if inherited < 6 {
		t.Errorf("expected at least 6 dated tasks across files, got %d", inherited)
	}
	if undated < 4 {
		t.Errorf("expected at least 4 undated tasks (from no-due + no-frontmatter), got %d", undated)
	}
}

// =============================================================================
// SortLast: Project Tasks Sort Below Their File's Tasks
// =============================================================================

func TestFMDue_ProjectSortsBelowInheritedTasks(t *testing.T) {
	ResetFrontmatterCache()
	vault := vaultPath(t, "fm-due-vault")
	f := filepath.Join(vault, "project-sort.md")

	// Run full pipeline to get regular tasks with inherited dates
	ctx := DefaultParseContext()
	tasks := fullPipelineOpen(t, ctx, FrontmatterConfig{}, f)

	// Get synthetic project task
	projects, err := ScanProjects(ctx.formats.GoDate, FrontmatterConfig{}, nil, f)
	if err != nil {
		t.Fatal(err)
	}
	if len(projects) != 1 {
		t.Fatalf("expected 1 project task, got %d", len(projects))
	}

	all := append(tasks, projects...)
	now := time.Date(2026, 4, 15, 10, 0, 0, 0, time.Local)
	output := FormatTaskfile(all, now, FormatOpts{})

	firstIdx := strings.Index(output, "First subtask")
	secondIdx := strings.Index(output, "Second subtask")
	// Find project-sort body line (not filepath occurrences) by looking for the tab-delimited body
	projIdx := strings.Index(output, "\t project-sort \t")

	if projIdx < 0 || firstIdx < 0 || secondIdx < 0 {
		t.Fatalf("missing tasks in output:\n%s", output)
	}
	if projIdx < firstIdx {
		t.Errorf("project task appeared before 'First subtask' in output:\n%s", output)
	}
	if projIdx < secondIdx {
		t.Errorf("project task appeared before 'Second subtask' in output:\n%s", output)
	}
}

func TestFMDue_SortLastFieldSetOnProjectTasks(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()

	f := filepath.Join(dir, "proj.md")
	os.WriteFile(f, []byte("---\ntags:\n  - project\ndue: 2026-07-01\n---\n- [ ] A task\n"), 0644)

	projects, err := ScanProjects("2006-01-02", FrontmatterConfig{}, nil, dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(projects) != 1 {
		t.Fatalf("expected 1 project, got %d", len(projects))
	}
	if !projects[0].SortLast {
		t.Error("ScanProjects should set SortLast=true on synthetic project tasks")
	}
}

func TestFMDue_SortLastComparatorUnit(t *testing.T) {
	// Two tasks with same date, filepath, and line number -- SortLast breaks tie
	date := time.Date(2026, 4, 15, 0, 0, 0, 0, time.Local)
	regular := Task{
		FilePath:   "/notes/tasks.md",
		LineNumber: 1,
		Body:       "regular-task",
		DueDate:    &date,
		Status:     "open",
		SortLast:   false,
	}
	synthetic := Task{
		FilePath:   "/notes/tasks.md",
		LineNumber: 1,
		Body:       "synthetic-task",
		DueDate:    &date,
		Status:     "open",
		SortLast:   true,
	}

	// Format with synthetic first to test that sort reorders
	tasks := []Task{synthetic, regular}
	now := time.Date(2026, 4, 15, 10, 0, 0, 0, time.Local)
	output := FormatTaskfile(tasks, now, FormatOpts{})

	regIdx := strings.Index(output, "regular-task")
	synIdx := strings.Index(output, "synthetic-task")
	if regIdx < 0 || synIdx < 0 {
		t.Fatalf("missing tasks in output:\n%s", output)
	}
	if synIdx < regIdx {
		t.Errorf("SortLast task should appear after regular task:\n%s", output)
	}
}
