package main

import (
	"strings"
	"testing"
	"time"
)

// Fixed "now" for deterministic bucket boundaries.
// 2026-02-17 is a Tuesday.
var testNow = time.Date(2026, 2, 17, 10, 0, 0, 0, time.Local)

// Default opts: no markers, no tag filter
var defaultOpts = FormatOpts{}
var markersOpts = FormatOpts{ShowMarkers: true}

func TestFormatTaskLine_Simple(t *testing.T) {
	task := Task{
		FilePath:   "/notes/project.md",
		LineNumber: 11,
		Body:       "Buy groceries",
		DueDate:    mustDatePtr("2026-02-17"),
		Status:     "open",
	}
	got := formatTaskLine(task, defaultOpts)
	want := "/notes/project.md:11:1:\t[[2026-02-17]]\t |       |     |\t Buy groceries \t"
	if got != want {
		t.Errorf("got:\n%q\nwant:\n%q", got, want)
	}
}

func TestFormatTaskLine_WithTime(t *testing.T) {
	task := Task{
		FilePath:   "/notes/test.md",
		LineNumber: 5,
		Body:       "Team meeting",
		DueDate:    mustDatePtr("2026-02-17"),
		DueTime:    "16:00",
		Status:     "open",
	}
	got := formatTaskLine(task, defaultOpts)
	want := "/notes/test.md:5:1:\t[[2026-02-17]] | 16:00 |     |\t Team meeting \t"
	if got != want {
		t.Errorf("got:\n%q\nwant:\n%q", got, want)
	}
}

func TestFormatTaskLine_WithDuration(t *testing.T) {
	task := Task{
		FilePath:   "/notes/test.md",
		LineNumber: 1,
		Body:       "Deep work",
		DueDate:    mustDatePtr("2026-02-17"),
		Duration:   "90m",
		Status:     "open",
	}
	got := formatTaskLine(task, defaultOpts)
	want := "/notes/test.md:1:1:\t[[2026-02-17]]\t |       | 90m |\t Deep work \t"
	if got != want {
		t.Errorf("got:\n%q\nwant:\n%q", got, want)
	}
}

func TestFormatTaskLine_WithTags(t *testing.T) {
	task := Task{
		FilePath:   "/notes/test.md",
		LineNumber: 1,
		Body:       "Run 5k",
		DueDate:    mustDatePtr("2026-02-17"),
		Tags:       []string{"exercise", "target"},
		Status:     "open",
	}
	got := formatTaskLine(task, defaultOpts)
	want := "/notes/test.md:1:1:\t[[2026-02-17]]\t |       |     |\t Run 5k \t #exercise #target"
	if got != want {
		t.Errorf("got:\n%q\nwant:\n%q", got, want)
	}
}

func TestFormatTaskLine_WithMarkers(t *testing.T) {
	task := Task{
		FilePath:   "/notes/test.md",
		LineNumber: 1,
		Body:       "Some task",
		DueDate:    mustDatePtr("2026-01-21"),
		Status:     "open",
		Markers: []Marker{
			{Kind: "original", Date: "2026-01-14"},
			{Kind: "deferral", Date: "2026-01-21", Time: "12:03"},
		},
	}
	got := formatTaskLine(task, markersOpts)
	want := "/notes/test.md:1:1:\t[[2026-01-21]]\t |       |     |\t Some task \t ::original [[2026-01-14]] ::deferral [[2026-01-21]] 12:03"
	if got != want {
		t.Errorf("got:\n%q\nwant:\n%q", got, want)
	}
}

func TestFormatTaskLine_MarkersHiddenByDefault(t *testing.T) {
	task := Task{
		FilePath:   "/notes/test.md",
		LineNumber: 1,
		Body:       "Some task",
		DueDate:    mustDatePtr("2026-01-21"),
		Status:     "open",
		Markers: []Marker{
			{Kind: "original", Date: "2026-01-14"},
		},
	}
	got := formatTaskLine(task, defaultOpts)
	if strings.Contains(got, "::original") {
		t.Errorf("markers should be hidden by default, got: %q", got)
	}
}

func TestFormatTaskLine_Full(t *testing.T) {
	task := Task{
		FilePath:   "/notes/project.md",
		LineNumber: 42,
		Body:       "Rewrite About Me Section",
		DueDate:    mustDatePtr("2026-01-23"),
		DueTime:    "15:00",
		Duration:   "30m",
		Status:     "done",
		Markers: []Marker{
			{Kind: "start", Date: "2026-01-23", Time: "15:17"},
			{Kind: "complete", Date: "2026-01-23", Time: "17:19"},
		},
	}
	got := formatTaskLine(task, markersOpts)
	want := "/notes/project.md:42:1:\t[[2026-01-23]] | 15:00 | 30m |\t Rewrite About Me Section \t ::start [[2026-01-23]] 15:17 ::complete [[2026-01-23]] 17:19"
	if got != want {
		t.Errorf("got:\n%q\nwant:\n%q", got, want)
	}
}

func TestFormatTaskLine_ShortDuration(t *testing.T) {
	task := Task{
		FilePath:   "/notes/test.md",
		LineNumber: 1,
		Body:       "Quick task",
		DueDate:    mustDatePtr("2026-02-17"),
		Duration:   "5m",
		Status:     "open",
	}
	got := formatTaskLine(task, defaultOpts)
	want := "/notes/test.md:1:1:\t[[2026-02-17]]\t |       |  5m |\t Quick task \t"
	if got != want {
		t.Errorf("got:\n%q\nwant:\n%q", got, want)
	}
}

func TestFormatTaskLine_Undated(t *testing.T) {
	task := Task{
		FilePath:   "/notes/someday.md",
		LineNumber: 3,
		Body:       "Investigate OOM Kill",
		Status:     "open",
	}
	got := formatTaskLine(task, defaultOpts)
	// Undated: 10 spaces instead of [[YYYY-MM-DD]]
	want := "/notes/someday.md:3:1:\t          \t |       |     |\t Investigate OOM Kill \t"
	if got != want {
		t.Errorf("got:\n%q\nwant:\n%q", got, want)
	}
}

func TestFormatTaskfile_BucketsAndHeaders(t *testing.T) {
	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "Overdue task", DueDate: mustDatePtr("2026-02-15"), Status: "open"},
		{FilePath: "/b.md", LineNumber: 2, Body: "Today task", DueDate: mustDatePtr("2026-02-17"), Status: "open"},
		{FilePath: "/c.md", LineNumber: 3, Body: "Tomorrow task", DueDate: mustDatePtr("2026-02-18"), Status: "open"},
		{FilePath: "/d.md", LineNumber: 4, Body: "This week task", DueDate: mustDatePtr("2026-02-19"), Status: "open"},
		{FilePath: "/e.md", LineNumber: 5, Body: "This month task", DueDate: mustDatePtr("2026-02-26"), Status: "open"},
		{FilePath: "/f.md", LineNumber: 6, Body: "This year task", DueDate: mustDatePtr("2026-04-01"), Status: "open"},
		{FilePath: "/g.md", LineNumber: 7, Body: "Far off task", DueDate: mustDatePtr("2028-01-01"), Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, defaultOpts)

	for _, header := range []string{"# Overdue", "# Today", "# Tomorrow", "# This Week", "# This Month", "# This Year", "# Far Off"} {
		if !strings.Contains(got, header) {
			t.Errorf("missing header %q in output:\n%s", header, got)
		}
	}

	overdueIdx := strings.Index(got, "# Overdue")
	todayIdx := strings.Index(got, "# Today")
	tomorrowIdx := strings.Index(got, "# Tomorrow")
	farOffIdx := strings.Index(got, "# Far Off")

	overdueTask := strings.Index(got, "Overdue task")
	todayTask := strings.Index(got, "Today task")
	tomorrowTask := strings.Index(got, "Tomorrow task")
	farOffTask := strings.Index(got, "Far off task")

	if overdueTask < overdueIdx || overdueTask > todayIdx {
		t.Error("overdue task not in Overdue section")
	}
	if todayTask < todayIdx || todayTask > tomorrowIdx {
		t.Error("today task not in Today section")
	}
	if tomorrowTask < tomorrowIdx {
		t.Error("tomorrow task not in Tomorrow section")
	}
	if farOffTask < farOffIdx {
		t.Error("far off task not in Far Off section")
	}
}

func TestFormatTaskfile_SortsByDate(t *testing.T) {
	tasks := []Task{
		{FilePath: "/b.md", LineNumber: 1, Body: "Later", DueDate: mustDatePtr("2026-02-19"), Status: "open"},
		{FilePath: "/a.md", LineNumber: 1, Body: "Earlier", DueDate: mustDatePtr("2026-02-17"), Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, defaultOpts)

	earlierIdx := strings.Index(got, "Earlier")
	laterIdx := strings.Index(got, "Later")
	if earlierIdx > laterIdx {
		t.Error("tasks not sorted by date — Earlier should appear before Later")
	}
}

func TestFormatTaskfile_EmptyInput(t *testing.T) {
	got := FormatTaskfile(nil, testNow, defaultOpts)
	if got != "" {
		t.Errorf("expected empty string for nil tasks, got %q", got)
	}
}

func TestFormatTaskfile_SkipsEmptyBuckets(t *testing.T) {
	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "Only today", DueDate: mustDatePtr("2026-02-17"), Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, defaultOpts)

	if strings.Contains(got, "# Overdue") {
		t.Error("should not contain Overdue header when no overdue tasks")
	}
	if !strings.Contains(got, "# Today") {
		t.Error("should contain Today header")
	}
	if strings.Contains(got, "# Tomorrow") {
		t.Error("should not contain Tomorrow header when no tomorrow tasks")
	}
}

func TestFormatTaskfile_SomedayBucket(t *testing.T) {
	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "Today task", DueDate: mustDatePtr("2026-02-17"), Status: "open"},
		{FilePath: "/b.md", LineNumber: 2, Body: "Undated task one", Status: "open"},
		{FilePath: "/c.md", LineNumber: 3, Body: "Undated task two", Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, defaultOpts)

	if !strings.Contains(got, "# Today") {
		t.Error("should contain Today header")
	}
	if !strings.Contains(got, "# Someday") {
		t.Error("should contain Someday header")
	}
	// Someday should come after Today
	todayIdx := strings.Index(got, "# Today")
	somedayIdx := strings.Index(got, "# Someday")
	if somedayIdx < todayIdx {
		t.Error("Someday should appear after Today")
	}
	// Both undated tasks should be under Someday
	task1 := strings.Index(got, "Undated task one")
	task2 := strings.Index(got, "Undated task two")
	if task1 < somedayIdx || task2 < somedayIdx {
		t.Error("undated tasks should be under Someday header")
	}
}

func TestFormatTaskfile_OnlyUndated(t *testing.T) {
	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "Undated only", Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, defaultOpts)

	if !strings.Contains(got, "# Someday") {
		t.Error("should contain Someday header")
	}
	if strings.Contains(got, "# Today") {
		t.Error("should not contain Today header")
	}
}

func TestFormatTaskfile_TagFilter(t *testing.T) {
	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "Tagged task", DueDate: mustDatePtr("2026-02-17"), Tags: []string{"sspi"}, Status: "open"},
		{FilePath: "/b.md", LineNumber: 2, Body: "Untagged task", DueDate: mustDatePtr("2026-02-17"), Status: "open"},
		{FilePath: "/c.md", LineNumber: 3, Body: "Other tagged", DueDate: mustDatePtr("2026-02-17"), Tags: []string{"project"}, Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, FormatOpts{TagFilter: []string{"sspi"}})

	if !strings.Contains(got, "Tagged task") {
		t.Error("should include task with matching tag")
	}
	if strings.Contains(got, "Untagged task") {
		t.Error("should not include untagged task")
	}
	if strings.Contains(got, "Other tagged") {
		t.Error("should not include task with non-matching tag")
	}
}

func TestFormatTaskfile_IgnoreUndated(t *testing.T) {
	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "Today task", DueDate: mustDatePtr("2026-02-17"), Status: "open"},
		{FilePath: "/b.md", LineNumber: 2, Body: "Undated task", Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, FormatOpts{IgnoreUndated: true})

	if strings.Contains(got, "# Someday") {
		t.Error("should not contain Someday header when IgnoreUndated is true")
	}
	if strings.Contains(got, "Undated task") {
		t.Error("should not contain undated task body when IgnoreUndated is true")
	}
	if !strings.Contains(got, "Today task") {
		t.Error("should still contain dated task")
	}
}

func TestFormatTaskfile_IgnoreUndatedKeepsDated(t *testing.T) {
	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "Overdue task", DueDate: mustDatePtr("2026-02-15"), Status: "open"},
		{FilePath: "/b.md", LineNumber: 2, Body: "Today task", DueDate: mustDatePtr("2026-02-17"), Status: "open"},
		{FilePath: "/c.md", LineNumber: 3, Body: "Undated task", Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, FormatOpts{IgnoreUndated: true})

	if !strings.Contains(got, "# Overdue") {
		t.Error("should contain Overdue header")
	}
	if !strings.Contains(got, "# Today") {
		t.Error("should contain Today header")
	}
	if !strings.Contains(got, "Overdue task") {
		t.Error("should contain overdue task")
	}
	if !strings.Contains(got, "Today task") {
		t.Error("should contain today task")
	}
	if strings.Contains(got, "# Someday") {
		t.Error("should not contain Someday header")
	}
	if strings.Contains(got, "Undated task") {
		t.Error("should not contain undated task")
	}
}

func TestFormatTaskfile_TagFilterOR(t *testing.T) {
	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "SSPI task", DueDate: mustDatePtr("2026-02-17"), Tags: []string{"sspi"}, Status: "open"},
		{FilePath: "/b.md", LineNumber: 2, Body: "Project task", DueDate: mustDatePtr("2026-02-17"), Tags: []string{"project"}, Status: "open"},
		{FilePath: "/c.md", LineNumber: 3, Body: "Neither", DueDate: mustDatePtr("2026-02-17"), Tags: []string{"other"}, Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, FormatOpts{TagFilter: []string{"sspi", "project"}})

	if !strings.Contains(got, "SSPI task") {
		t.Error("should include sspi task")
	}
	if !strings.Contains(got, "Project task") {
		t.Error("should include project task")
	}
	if strings.Contains(got, "Neither") {
		t.Error("should not include task with non-matching tag")
	}
}
