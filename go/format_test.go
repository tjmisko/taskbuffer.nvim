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

func TestInHorizon_Boundaries(t *testing.T) {
	horizons := []ResolvedHorizon{
		{Label: "# H0", Cutoff: extractDate(testNow)},                  // day 0
		{Label: "# H1", Cutoff: extractDate(testNow).AddDate(0, 0, 2)}, // day 2
		{Label: "# H2", Cutoff: extractDate(testNow).AddDate(0, 0, 5)}, // day 5
	}

	cases := []struct {
		name string
		date time.Time
		idx  int
		want bool
	}{
		{"day0 in H0", extractDate(testNow), 0, true},
		{"day0 in H1", extractDate(testNow), 1, false},
		{"day1 in H0", extractDate(testNow).AddDate(0, 0, 1), 0, true},
		{"day2 in H0", extractDate(testNow).AddDate(0, 0, 2), 0, false},
		{"day2 in H1", extractDate(testNow).AddDate(0, 0, 2), 1, true},
		{"day5 in H2", extractDate(testNow).AddDate(0, 0, 5), 2, true},
		{"day10 in H2", extractDate(testNow).AddDate(0, 0, 10), 2, true},
		{"day5 in H1", extractDate(testNow).AddDate(0, 0, 5), 1, false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := inHorizon(tc.date, tc.idx, horizons)
			if got != tc.want {
				t.Errorf("inHorizon(day offset, idx=%d) = %v, want %v", tc.idx, got, tc.want)
			}
		})
	}
}

func TestFirstMatchHorizon_Basic(t *testing.T) {
	// Unsorted horizons to exercise first-match ordering
	horizons := []ResolvedHorizon{
		{Label: "# Narrow", Cutoff: extractDate(testNow).AddDate(0, 0, 3)}, // day 3
		{Label: "# Wide", Cutoff: extractDate(testNow)},                     // day 0
		{Label: "# Far", Cutoff: extractDate(testNow).AddDate(0, 0, 7)},    // day 7
	}

	cases := []struct {
		name string
		date time.Time
		want int
	}{
		{"day4 matches Narrow first", extractDate(testNow).AddDate(0, 0, 4), 0},
		{"day1 matches Wide first", extractDate(testNow).AddDate(0, 0, 1), 1},
		{"day8 matches Narrow first", extractDate(testNow).AddDate(0, 0, 8), 0},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := firstMatchHorizon(tc.date, horizons)
			if got != tc.want {
				t.Errorf("firstMatchHorizon() = %d (%s), want %d (%s)",
					got, horizons[got].Label, tc.want, horizons[tc.want].Label)
			}
		})
	}

	// Fallback: all horizons in the future, date before any cutoff
	futureHorizons := []ResolvedHorizon{
		{Label: "# A", Cutoff: extractDate(testNow).AddDate(0, 0, 10)},
		{Label: "# B", Cutoff: extractDate(testNow).AddDate(0, 0, 20)},
	}
	got := firstMatchHorizon(extractDate(testNow), futureHorizons)
	if got != 1 {
		t.Errorf("fallback: firstMatchHorizon() = %d, want 1 (last dated horizon)", got)
	}
}

func TestNarrowestHorizon_Basic(t *testing.T) {
	horizons := []ResolvedHorizon{
		{Label: "# Wide", Cutoff: extractDate(testNow)},                     // day 0, span to day5 = 5 days
		{Label: "# Narrow", Cutoff: extractDate(testNow).AddDate(0, 0, 2)},  // day 2, span to day5 = 3 days
		{Label: "# Far", Cutoff: extractDate(testNow).AddDate(0, 0, 5)},     // day 5, last bucket
	}

	cases := []struct {
		name string
		date time.Time
		want int
	}{
		{"day3 in Narrow (span=3) not Wide (span=5)", extractDate(testNow).AddDate(0, 0, 3), 1},
		{"day1 only in Wide", extractDate(testNow).AddDate(0, 0, 1), 0},
		{"day6 only in Far", extractDate(testNow).AddDate(0, 0, 6), 2},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := narrowestHorizon(tc.date, horizons)
			if got != tc.want {
				t.Errorf("narrowestHorizon() = %d (%s), want %d (%s)",
					got, horizons[got].Label, tc.want, horizons[tc.want].Label)
			}
		})
	}
}

func TestFormatTaskfile_CustomHorizons(t *testing.T) {
	today := extractDate(testNow)
	horizons := []ResolvedHorizon{
		{Label: "# Urgent", Cutoff: today},
		{Label: "# Soon", Cutoff: today.AddDate(0, 0, 3)},
		{Label: "# Later", Cutoff: today.AddDate(0, 0, 10)},
		{Label: "# Backlog", Undated: true},
	}

	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "Fix crash", DueDate: mustDatePtr("2026-02-17"), Status: "open"},
		{FilePath: "/b.md", LineNumber: 2, Body: "Write docs", DueDate: mustDatePtr("2026-02-22"), Status: "open"},
		{FilePath: "/c.md", LineNumber: 3, Body: "Plan refactor", DueDate: mustDatePtr("2026-03-04"), Status: "open"},
		{FilePath: "/d.md", LineNumber: 4, Body: "Someday idea", Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, FormatOpts{Horizons: horizons})

	for _, header := range []string{"# Urgent", "# Soon", "# Later", "# Backlog"} {
		if !strings.Contains(got, header) {
			t.Errorf("missing header %q in output:\n%s", header, got)
		}
	}

	// Verify tasks under correct headers
	urgentIdx := strings.Index(got, "# Urgent")
	soonIdx := strings.Index(got, "# Soon")
	laterIdx := strings.Index(got, "# Later")
	backlogIdx := strings.Index(got, "# Backlog")

	crashIdx := strings.Index(got, "Fix crash")
	docsIdx := strings.Index(got, "Write docs")
	refactorIdx := strings.Index(got, "Plan refactor")
	ideaIdx := strings.Index(got, "Someday idea")

	if crashIdx < urgentIdx || crashIdx > soonIdx {
		t.Error("Fix crash should be under # Urgent")
	}
	if docsIdx < soonIdx || docsIdx > laterIdx {
		t.Error("Write docs should be under # Soon")
	}
	if refactorIdx < laterIdx || refactorIdx > backlogIdx {
		t.Error("Plan refactor should be under # Later")
	}
	if ideaIdx < backlogIdx {
		t.Error("Someday idea should be under # Backlog")
	}

	// Custom undated label used, not default
	if strings.Contains(got, "# Someday") {
		t.Error("should use custom undated label # Backlog, not # Someday")
	}
}

func TestFormatTaskfile_FirstMatchOverlap(t *testing.T) {
	today := extractDate(testNow)
	horizons := []ResolvedHorizon{
		{Label: "# Priority", Cutoff: today.AddDate(0, 0, 2)}, // day 2
		{Label: "# General", Cutoff: today},                    // day 0
		{Label: "# Someday", Undated: true},
	}

	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "Priority task", DueDate: mustDatePtr("2026-02-20"), Status: "open"},
		{FilePath: "/b.md", LineNumber: 2, Body: "General task", DueDate: mustDatePtr("2026-02-18"), Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, FormatOpts{Horizons: horizons, Overlap: "first_match"})

	priorityIdx := strings.Index(got, "# Priority")
	generalIdx := strings.Index(got, "# General")
	priorityTask := strings.Index(got, "Priority task")
	generalTask := strings.Index(got, "General task")

	if priorityIdx == -1 {
		t.Fatal("missing # Priority header")
	}
	if generalIdx == -1 {
		t.Fatal("missing # General header")
	}
	// Tasks are date-sorted, so General task (Feb 18) comes before Priority task (Feb 20).
	// General task (day1): first checks Priority (day1 >= day2? no), then General (day1 >= day0? yes) -> General
	// Priority task (day3): first checks Priority (day3 >= day2? yes) -> Priority
	if generalTask < generalIdx {
		t.Error("General task should be under # General header")
	}
	if priorityTask < priorityIdx {
		t.Error("Priority task should be under # Priority header")
	}
	// General (date-earlier) appears first in output, then Priority
	if generalIdx > priorityIdx {
		t.Error("# General header should appear before # Priority header (tasks sorted by date)")
	}
}

func TestFormatTaskfile_NarrowestOverlap(t *testing.T) {
	today := extractDate(testNow)
	horizons := []ResolvedHorizon{
		{Label: "# Wide", Cutoff: today},                    // day 0, span to day3 = 3
		{Label: "# Narrow", Cutoff: today.AddDate(0, 0, 3)}, // day 3, span to day7 = 4
		{Label: "# Far", Cutoff: today.AddDate(0, 0, 7)},    // day 7, last
		{Label: "# Backlog", Undated: true},
	}

	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "Wide task", DueDate: mustDatePtr("2026-02-18"), Status: "open"},
		{FilePath: "/b.md", LineNumber: 2, Body: "Narrow task", DueDate: mustDatePtr("2026-02-21"), Status: "open"},
		{FilePath: "/c.md", LineNumber: 3, Body: "Far task", DueDate: mustDatePtr("2026-02-25"), Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, FormatOpts{Horizons: horizons, Overlap: "narrowest"})

	wideIdx := strings.Index(got, "# Wide")
	narrowIdx := strings.Index(got, "# Narrow")
	farIdx := strings.Index(got, "# Far")

	wideTask := strings.Index(got, "Wide task")
	narrowTask := strings.Index(got, "Narrow task")
	farTask := strings.Index(got, "Far task")

	if wideIdx == -1 || narrowIdx == -1 || farIdx == -1 {
		t.Fatalf("missing headers in output:\n%s", got)
	}
	if wideTask < wideIdx || wideTask > narrowIdx {
		t.Errorf("Wide task should be under # Wide, output:\n%s", got)
	}
	if narrowTask < narrowIdx || narrowTask > farIdx {
		t.Errorf("Narrow task should be under # Narrow, output:\n%s", got)
	}
	if farTask < farIdx {
		t.Errorf("Far task should be under # Far, output:\n%s", got)
	}
}

func TestFormatTaskfile_ExactBoundaryDate(t *testing.T) {
	today := extractDate(testNow)
	horizons := []ResolvedHorizon{
		{Label: "# Past", Cutoff: today.AddDate(0, 0, -5)},
		{Label: "# Present", Cutoff: today},
		{Label: "# Future", Cutoff: today.AddDate(0, 0, 5)},
	}

	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "Present task", DueDate: mustDatePtr("2026-02-17"), Status: "open"},
		{FilePath: "/b.md", LineNumber: 2, Body: "Future task", DueDate: mustDatePtr("2026-02-22"), Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, FormatOpts{Horizons: horizons})

	presentIdx := strings.Index(got, "# Present")
	futureIdx := strings.Index(got, "# Future")
	presentTask := strings.Index(got, "Present task")
	futureTask := strings.Index(got, "Future task")

	if presentIdx == -1 || futureIdx == -1 {
		t.Fatalf("missing headers in output:\n%s", got)
	}
	// Task on exact cutoff of Present should land in Present, not Past
	if presentTask < presentIdx || presentTask > futureIdx {
		t.Errorf("Present task (on exact cutoff) should be under # Present, output:\n%s", got)
	}
	// Task on exact cutoff of Future should land in Future, not Present
	if futureTask < futureIdx {
		t.Errorf("Future task (on exact cutoff) should be under # Future, output:\n%s", got)
	}
	// Past header should not appear (no tasks in that range)
	if strings.Contains(got, "# Past") {
		t.Error("# Past should not appear when no tasks fall in that range")
	}
}

func TestFormatTaskfile_SingleHorizon(t *testing.T) {
	today := extractDate(testNow)
	horizons := []ResolvedHorizon{
		{Label: "# Everything", Cutoff: today.AddDate(0, 0, -100)},
	}

	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "Old task", DueDate: mustDatePtr("2026-01-01"), Status: "open"},
		{FilePath: "/b.md", LineNumber: 2, Body: "Today task", DueDate: mustDatePtr("2026-02-17"), Status: "open"},
		{FilePath: "/c.md", LineNumber: 3, Body: "Future task", DueDate: mustDatePtr("2026-06-01"), Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, FormatOpts{Horizons: horizons})

	if !strings.Contains(got, "# Everything") {
		t.Errorf("missing # Everything header in output:\n%s", got)
	}
	for _, body := range []string{"Old task", "Today task", "Future task"} {
		if !strings.Contains(got, body) {
			t.Errorf("missing task %q in output:\n%s", body, got)
		}
	}
	// All tasks should be under the single header
	headerIdx := strings.Index(got, "# Everything")
	for _, body := range []string{"Old task", "Today task", "Future task"} {
		if strings.Index(got, body) < headerIdx {
			t.Errorf("task %q should be after # Everything header", body)
		}
	}
}

func TestFormatTaskfile_AllTasksSameDate(t *testing.T) {
	today := extractDate(testNow)
	horizons := []ResolvedHorizon{
		{Label: "# Today", Cutoff: today},
		{Label: "# Future", Cutoff: today.AddDate(0, 0, 7)},
	}

	tasks := []Task{
		{FilePath: "/c.md", LineNumber: 1, Body: "Task C", DueDate: mustDatePtr("2026-02-17"), Status: "open"},
		{FilePath: "/a.md", LineNumber: 1, Body: "Task A", DueDate: mustDatePtr("2026-02-17"), Status: "open"},
		{FilePath: "/b.md", LineNumber: 1, Body: "Task B", DueDate: mustDatePtr("2026-02-17"), Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, FormatOpts{Horizons: horizons})

	if !strings.Contains(got, "# Today") {
		t.Fatalf("missing # Today header in output:\n%s", got)
	}
	if strings.Contains(got, "# Future") {
		t.Error("# Future should not appear when no tasks fall in that range")
	}

	// Tasks should be sorted by filepath: a, b, c
	aIdx := strings.Index(got, "Task A")
	bIdx := strings.Index(got, "Task B")
	cIdx := strings.Index(got, "Task C")

	if aIdx > bIdx || bIdx > cIdx {
		t.Errorf("tasks should be sorted by filepath (a < b < c), output:\n%s", got)
	}
}

func TestFormatTaskfile_CustomUndatedLabel(t *testing.T) {
	today := extractDate(testNow)
	horizons := []ResolvedHorizon{
		{Label: "# Tasks", Cutoff: today},
		{Label: "# Inbox", Undated: true},
	}

	tasks := []Task{
		{FilePath: "/a.md", LineNumber: 1, Body: "Undated thing", Status: "open"},
	}

	got := FormatTaskfile(tasks, testNow, FormatOpts{Horizons: horizons})

	if !strings.Contains(got, "# Inbox") {
		t.Errorf("should use custom undated label # Inbox, output:\n%s", got)
	}
	if strings.Contains(got, "# Someday") {
		t.Error("should NOT contain default # Someday label when custom undated label is set")
	}
	if !strings.Contains(got, "Undated thing") {
		t.Errorf("undated task should appear in output:\n%s", got)
	}
}
