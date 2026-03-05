package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// invalidDateCases covers all categories of invalid dates for reuse across surfaces.
var invalidDateCases = []struct {
	name    string
	dateStr string // YYYY-MM-DD format
}{
	// Month out of range
	{"month 00", "2026-00-15"},
	{"month 13", "2026-13-01"},
	{"month 99", "2026-99-01"},

	// Day out of range
	{"day 00", "2026-01-00"},
	{"day 32", "2026-01-32"},
	{"day 99", "2026-01-99"},

	// Impossible month/day combos (30-day months)
	{"Apr 31", "2026-04-31"},
	{"Jun 31", "2026-06-31"},
	{"Sep 31", "2026-09-31"},
	{"Nov 31", "2026-11-31"},

	// February edge cases
	{"Feb 30", "2026-02-30"},
	{"Feb 31", "2026-02-31"},
	{"Feb 29 non-leap", "2025-02-29"},
	{"Feb 29 century non-leap", "2100-02-29"},
}

// validDateCases ensures valid dates are not falsely flagged.
var validDateCases = []struct {
	name    string
	dateStr string
}{
	{"Jan 01", "2026-01-01"},
	{"Dec 31", "2026-12-31"},
	{"Feb 28 non-leap", "2025-02-28"},
	{"Feb 29 leap", "2024-02-29"},
	{"Feb 29 century leap", "2000-02-29"},
	{"Apr 30", "2026-04-30"},
	{"Jun 30", "2026-06-30"},
}

// =============================================================================
// Inline due dates
// =============================================================================

func TestDateValidation_InlineDates_Strict(t *testing.T) {
	ctx := NewParseContext(Config{Strict: true})
	var dateErrors []DateError
	ctx.dateErrors = &dateErrors

	for _, tt := range invalidDateCases {
		t.Run(tt.name, func(t *testing.T) {
			dateErrors = dateErrors[:0]
			input := "- [ ] Task (@[[" + tt.dateStr + "]])"
			task, err := ParseTask(rawMatch(input), ctx)
			if err != nil {
				t.Fatalf("strict mode should not return error, got: %v", err)
			}
			if task.DueDate != nil {
				t.Error("expected nil DueDate for invalid date")
			}
			if len(dateErrors) != 1 {
				t.Fatalf("expected 1 DateError, got %d", len(dateErrors))
			}
			de := dateErrors[0]
			if de.DateStr != tt.dateStr {
				t.Errorf("DateStr = %q, want %q", de.DateStr, tt.dateStr)
			}
			if de.Context != "inline due date" {
				t.Errorf("Context = %q, want %q", de.Context, "inline due date")
			}
			if de.FilePath != "adversarial.md" {
				t.Errorf("FilePath = %q, want %q", de.FilePath, "adversarial.md")
			}
			if de.LineNumber != 1 {
				t.Errorf("LineNumber = %d, want 1", de.LineNumber)
			}
		})
	}
}

func TestDateValidation_InlineDates_StrictPreservesBody(t *testing.T) {
	ctx := NewParseContext(Config{Strict: true})
	var dateErrors []DateError
	ctx.dateErrors = &dateErrors

	input := "- [ ] Important task #work (@[[2026-13-01]])"
	task, err := ParseTask(rawMatch(input), ctx)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if task.Body != "Important task" {
		t.Errorf("body = %q, want %q", task.Body, "Important task")
	}
	if len(task.Tags) != 1 || task.Tags[0] != "work" {
		t.Errorf("tags = %v, want [work]", task.Tags)
	}
	if task.DueDate != nil {
		t.Error("DueDate should be nil for invalid date")
	}
}

func TestDateValidation_InlineDates_NonStrict(t *testing.T) {
	ctx := DefaultParseContext()

	for _, tt := range invalidDateCases {
		t.Run(tt.name, func(t *testing.T) {
			input := "- [ ] Task (@[[" + tt.dateStr + "]])"
			_, err := ParseTask(rawMatch(input), ctx)
			if err == nil {
				t.Error("non-strict mode should return error for invalid date")
			}
		})
	}
}

func TestDateValidation_InlineDates_ValidDates(t *testing.T) {
	ctx := NewParseContext(Config{Strict: true})
	var dateErrors []DateError
	ctx.dateErrors = &dateErrors

	for _, tt := range validDateCases {
		t.Run(tt.name, func(t *testing.T) {
			dateErrors = dateErrors[:0]
			input := "- [ ] Task (@[[" + tt.dateStr + "]])"
			task, err := ParseTask(rawMatch(input), ctx)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if task.DueDate == nil {
				t.Error("expected non-nil DueDate for valid date")
			}
			if len(dateErrors) != 0 {
				t.Errorf("expected 0 DateErrors, got %d: %v", len(dateErrors), dateErrors)
			}
		})
	}
}

// =============================================================================
// Marker dates
// =============================================================================

func TestDateValidation_MarkerDates_Strict(t *testing.T) {
	ctx := NewParseContext(Config{Strict: true})
	var dateErrors []DateError
	ctx.dateErrors = &dateErrors

	for _, tt := range invalidDateCases {
		t.Run(tt.name, func(t *testing.T) {
			dateErrors = dateErrors[:0]
			input := "- [ ] Task (@[[2026-01-15]]) ::start [[" + tt.dateStr + "]] 10:00"
			task, err := ParseTask(rawMatch(input), ctx)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			// Task should still have valid inline date
			if task.DueDate == nil {
				t.Error("inline date should still be parsed")
			}
			// Marker should still be stored
			if len(task.Markers) != 1 {
				t.Fatalf("expected 1 marker, got %d", len(task.Markers))
			}
			if task.Markers[0].Date != tt.dateStr {
				t.Errorf("marker date = %q, want %q", task.Markers[0].Date, tt.dateStr)
			}
			// Should have collected an error
			if len(dateErrors) != 1 {
				t.Fatalf("expected 1 DateError, got %d", len(dateErrors))
			}
			if !strings.Contains(dateErrors[0].Context, "marker (start)") {
				t.Errorf("Context = %q, want to contain %q", dateErrors[0].Context, "marker (start)")
			}
		})
	}
}

func TestDateValidation_MarkerDates_NonStrict(t *testing.T) {
	ctx := DefaultParseContext()

	// Non-strict: markers store whatever the regex matched, no validation
	input := "- [ ] Task (@[[2026-01-15]]) ::start [[2026-13-45]] 10:00"
	task, err := ParseTask(rawMatch(input), ctx)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(task.Markers) != 1 {
		t.Fatalf("expected 1 marker, got %d", len(task.Markers))
	}
	// Invalid date stored as-is in non-strict mode
	if task.Markers[0].Date != "2026-13-45" {
		t.Errorf("marker date = %q, want %q", task.Markers[0].Date, "2026-13-45")
	}
}

func TestDateValidation_MarkerDates_ValidDates(t *testing.T) {
	ctx := NewParseContext(Config{Strict: true})
	var dateErrors []DateError
	ctx.dateErrors = &dateErrors

	for _, tt := range validDateCases {
		t.Run(tt.name, func(t *testing.T) {
			dateErrors = dateErrors[:0]
			input := "- [ ] Task (@[[2026-01-15]]) ::complete [[" + tt.dateStr + "]] 14:00"
			_, err := ParseTask(rawMatch(input), ctx)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(dateErrors) != 0 {
				t.Errorf("expected 0 DateErrors for valid marker date, got %d", len(dateErrors))
			}
		})
	}
}

func TestDateValidation_MarkerDates_MultipleMarkers(t *testing.T) {
	ctx := NewParseContext(Config{Strict: true})
	var dateErrors []DateError
	ctx.dateErrors = &dateErrors

	// Two markers, both invalid
	input := "- [ ] Task (@[[2026-01-15]]) ::start [[2026-13-01]] 10:00 ::stop [[2026-00-15]] 11:00"
	task, err := ParseTask(rawMatch(input), ctx)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(task.Markers) != 2 {
		t.Fatalf("expected 2 markers, got %d", len(task.Markers))
	}
	if len(dateErrors) != 2 {
		t.Fatalf("expected 2 DateErrors, got %d", len(dateErrors))
	}
	if !strings.Contains(dateErrors[0].Context, "marker (start)") {
		t.Errorf("first error Context = %q", dateErrors[0].Context)
	}
	if !strings.Contains(dateErrors[1].Context, "marker (stop)") {
		t.Errorf("second error Context = %q", dateErrors[1].Context)
	}
}

// =============================================================================
// Frontmatter due dates
// =============================================================================

func writeFrontmatterFile(t *testing.T, dir, name, content string) string {
	t.Helper()
	f := filepath.Join(dir, name)
	if err := os.WriteFile(f, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestDateValidation_FrontmatterDue_Strict(t *testing.T) {
	for _, tt := range invalidDateCases {
		t.Run(tt.name, func(t *testing.T) {
			ResetFrontmatterCache()
			dir := t.TempDir()
			f := writeFrontmatterFile(t, dir, "test.md",
				"---\ndue: \""+tt.dateStr+"\"\ntags:\n  - work\n---\n")

			tasks := []Task{
				{FilePath: f, LineNumber: 5, Body: "undated task"},
			}
			var dateErrors []DateError
			MergeFrontmatterDue(tasks, FrontmatterConfig{}, "2006-01-02", &dateErrors)

			if tasks[0].DueDate != nil {
				t.Error("DueDate should remain nil for invalid frontmatter date")
			}
			if len(dateErrors) != 1 {
				t.Fatalf("expected 1 DateError, got %d", len(dateErrors))
			}
			if dateErrors[0].Context != "frontmatter due" {
				t.Errorf("Context = %q, want %q", dateErrors[0].Context, "frontmatter due")
			}
			if dateErrors[0].FilePath != f {
				t.Errorf("FilePath = %q, want %q", dateErrors[0].FilePath, f)
			}
		})
	}
}

func TestDateValidation_FrontmatterDue_NonStrict(t *testing.T) {
	for _, tt := range invalidDateCases {
		t.Run(tt.name, func(t *testing.T) {
			ResetFrontmatterCache()
			dir := t.TempDir()
			f := writeFrontmatterFile(t, dir, "test.md",
				"---\ndue: \""+tt.dateStr+"\"\ntags:\n  - work\n---\n")

			tasks := []Task{
				{FilePath: f, LineNumber: 5, Body: "undated task"},
			}
			MergeFrontmatterDue(tasks, FrontmatterConfig{}, "2006-01-02", nil)

			// Non-strict: silently skipped, no crash
			if tasks[0].DueDate != nil {
				t.Error("DueDate should remain nil for invalid frontmatter date")
			}
		})
	}
}

func TestDateValidation_FrontmatterDue_ValidDates(t *testing.T) {
	for _, tt := range validDateCases {
		t.Run(tt.name, func(t *testing.T) {
			ResetFrontmatterCache()
			dir := t.TempDir()
			f := writeFrontmatterFile(t, dir, "test.md",
				"---\ndue: \""+tt.dateStr+"\"\n---\n")

			tasks := []Task{
				{FilePath: f, LineNumber: 5, Body: "task"},
			}
			var dateErrors []DateError
			MergeFrontmatterDue(tasks, FrontmatterConfig{}, "2006-01-02", &dateErrors)

			if tasks[0].DueDate == nil {
				t.Error("DueDate should be set for valid date")
			}
			if len(dateErrors) != 0 {
				t.Errorf("expected 0 DateErrors, got %d", len(dateErrors))
			}
		})
	}
}

// =============================================================================
// ScanProjects (frontmatter project due dates)
// =============================================================================

func TestDateValidation_ScanProjects_Strict(t *testing.T) {
	for _, tt := range invalidDateCases {
		t.Run(tt.name, func(t *testing.T) {
			ResetFrontmatterCache()
			dir := t.TempDir()
			writeFrontmatterFile(t, dir, "project.md",
				"---\ndue: \""+tt.dateStr+"\"\ntags:\n  - project\n---\n- project\n")

			var dateErrors []DateError
			tasks, err := ScanProjects("2006-01-02", FrontmatterConfig{}, &dateErrors, dir)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(tasks) != 0 {
				t.Error("expected 0 tasks for invalid project date")
			}
			if len(dateErrors) != 1 {
				t.Fatalf("expected 1 DateError, got %d", len(dateErrors))
			}
			if dateErrors[0].Context != "frontmatter project due" {
				t.Errorf("Context = %q, want %q", dateErrors[0].Context, "frontmatter project due")
			}
		})
	}
}

func TestDateValidation_ScanProjects_NonStrict(t *testing.T) {
	for _, tt := range invalidDateCases {
		t.Run(tt.name, func(t *testing.T) {
			ResetFrontmatterCache()
			dir := t.TempDir()
			writeFrontmatterFile(t, dir, "project.md",
				"---\ndue: \""+tt.dateStr+"\"\ntags:\n  - project\n---\n- project\n")

			tasks, err := ScanProjects("2006-01-02", FrontmatterConfig{}, nil, dir)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			// Non-strict: silently skipped
			if len(tasks) != 0 {
				t.Error("expected 0 tasks for invalid project date")
			}
		})
	}
}

// =============================================================================
// Error message formatting
// =============================================================================

func TestDateValidation_ErrorMessages(t *testing.T) {
	t.Run("inline with line number", func(t *testing.T) {
		e := DateError{
			FilePath:   "/notes/daily.md",
			LineNumber: 15,
			DateStr:    "2026-13-01",
			Context:    "inline due date",
			Err:        errFromParse("2026-13-01"),
		}
		msg := e.Error()
		if !strings.Contains(msg, "/notes/daily.md:15") {
			t.Errorf("error should contain file:line, got: %s", msg)
		}
		if !strings.Contains(msg, "inline due date") {
			t.Errorf("error should contain context, got: %s", msg)
		}
		if !strings.Contains(msg, "2026-13-01") {
			t.Errorf("error should contain date string, got: %s", msg)
		}
	})

	t.Run("frontmatter without line number", func(t *testing.T) {
		e := DateError{
			FilePath: "/notes/project.md",
			DateStr:  "2026-02-30",
			Context:  "frontmatter due",
			Err:      errFromParse("2026-02-30"),
		}
		msg := e.Error()
		// Should NOT have :0 in the output
		if strings.Contains(msg, ":0:") {
			t.Errorf("frontmatter error should not show line 0, got: %s", msg)
		}
		if !strings.Contains(msg, "/notes/project.md:") {
			// Should just have the path without line
			if !strings.Contains(msg, "/notes/project.md") {
				t.Errorf("error should contain file path, got: %s", msg)
			}
		}
	})

	t.Run("marker with kind", func(t *testing.T) {
		e := DateError{
			FilePath:   "/notes/task.md",
			LineNumber: 8,
			DateStr:    "2026-04-31",
			Context:    "marker (start)",
			Err:        errFromParse("2026-04-31"),
		}
		msg := e.Error()
		if !strings.Contains(msg, "marker (start)") {
			t.Errorf("error should contain marker kind, got: %s", msg)
		}
	})
}

// =============================================================================
// Multiple errors across surfaces
// =============================================================================

func TestDateValidation_MultipleErrorsCollected(t *testing.T) {
	ctx := NewParseContext(Config{Strict: true})
	var dateErrors []DateError
	ctx.dateErrors = &dateErrors

	// Task with invalid inline date
	input1 := "- [ ] Task one (@[[2026-13-01]])"
	_, _ = ParseTask(rawMatch(input1), ctx)

	// Task with valid inline date but invalid marker
	input2 := "- [ ] Task two (@[[2026-01-15]]) ::start [[2026-04-31]] 10:00"
	_, _ = ParseTask(rawMatch(input2), ctx)

	// Frontmatter with invalid date
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := writeFrontmatterFile(t, dir, "bad-fm.md",
		"---\ndue: \"2026-02-30\"\n---\n")
	tasks := []Task{{FilePath: f, LineNumber: 5, Body: "undated"}}
	MergeFrontmatterDue(tasks, FrontmatterConfig{}, "2006-01-02", &dateErrors)

	if len(dateErrors) != 3 {
		t.Fatalf("expected 3 DateErrors across surfaces, got %d:", len(dateErrors))
	}

	contexts := make(map[string]bool)
	for _, e := range dateErrors {
		contexts[e.Context] = true
	}
	for _, want := range []string{"inline due date", "marker (start)", "frontmatter due"} {
		if !contexts[want] {
			t.Errorf("missing error context %q in collected errors", want)
		}
	}
}

// =============================================================================
// Strict mode does not affect non-date errors
// =============================================================================

func TestDateValidation_StrictDoesNotSuppressCheckboxErrors(t *testing.T) {
	ctx := NewParseContext(Config{Strict: true})
	var dateErrors []DateError
	ctx.dateErrors = &dateErrors

	// No checkbox — should still return error even in strict mode
	_, err := ParseTask(RawMatch{Path: "test.md", LineNumber: 1, Text: "Not a task line"}, ctx)
	if err == nil {
		t.Error("expected error for missing checkbox even in strict mode")
	}
	if len(dateErrors) != 0 {
		t.Error("non-date error should not be collected as DateError")
	}
}

// =============================================================================
// Nil collector safety
// =============================================================================

func TestDateValidation_NilCollectorSafe(t *testing.T) {
	// Calling collectDateError with nil should not panic
	collectDateError(nil, DateError{
		FilePath: "test.md",
		DateStr:  "2026-13-01",
		Context:  "test",
	})
}

// errFromParse generates a realistic parse error for test assertions.
func errFromParse(dateStr string) error {
	_, err := time.Parse("2006-01-02", dateStr)
	return err
}
