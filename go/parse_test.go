package main

import (
	"testing"
	"time"
)

func mustDate(s string) time.Time {
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		panic(err)
	}
	return t
}

func mustDatePtr(s string) *time.Time {
	t := mustDate(s)
	return &t
}

var defaultCtx = DefaultParseContext()

func TestParseTask_Simple(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 5,
		Text:       "- [ ] Buy groceries (@[[2026-02-17]])",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.Body != "Buy groceries" {
		t.Errorf("body = %q, want %q", task.Body, "Buy groceries")
	}
	if task.Status != "open" {
		t.Errorf("status = %q, want %q", task.Status, "open")
	}
	if task.DueDate == nil || !task.DueDate.Equal(mustDate("2026-02-17")) {
		t.Errorf("date = %v, want 2026-02-17", task.DueDate)
	}
	if task.DueTime != "" {
		t.Errorf("time = %q, want empty", task.DueTime)
	}
	if task.Duration != "" {
		t.Errorf("duration = %q, want empty", task.Duration)
	}
	if len(task.Tags) != 0 {
		t.Errorf("tags = %v, want empty", task.Tags)
	}
	if len(task.Markers) != 0 {
		t.Errorf("markers = %v, want empty", task.Markers)
	}
}

func TestParseTask_WithTime(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 10,
		Text:       "- [ ] Team meeting (@[[2026-02-17]] 16:00)",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.Body != "Team meeting" {
		t.Errorf("body = %q", task.Body)
	}
	if task.DueTime != "16:00" {
		t.Errorf("time = %q, want 16:00", task.DueTime)
	}
}

func TestParseTask_WithDuration(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 1,
		Text:       "- [ ] Meeting with Professor <90m> (@[[2026-02-17]])",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.Body != "Meeting with Professor" {
		t.Errorf("body = %q", task.Body)
	}
	if task.Duration != "90m" {
		t.Errorf("duration = %q, want 90m", task.Duration)
	}
}

func TestParseTask_WithTags(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 1,
		Text:       "- [ ] Run 5k #exercise #target (@[[2026-02-17]])",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.Body != "Run 5k" {
		t.Errorf("body = %q", task.Body)
	}
	if len(task.Tags) != 2 || task.Tags[0] != "exercise" || task.Tags[1] != "target" {
		t.Errorf("tags = %v, want [exercise target]", task.Tags)
	}
}

func TestParseTask_WithMarkers(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 1,
		Text:       "- [ ] Some task (@[[2026-01-21]])::original [[2026-01-14]] ::deferral [[2026-01-21]] 12:03",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if len(task.Markers) != 2 {
		t.Fatalf("markers count = %d, want 2", len(task.Markers))
	}
	if task.Markers[0].Kind != "original" || task.Markers[0].Date != "2026-01-14" || task.Markers[0].Time != "" {
		t.Errorf("marker[0] = %+v", task.Markers[0])
	}
	if task.Markers[1].Kind != "deferral" || task.Markers[1].Date != "2026-01-21" || task.Markers[1].Time != "12:03" {
		t.Errorf("marker[1] = %+v", task.Markers[1])
	}
}

func TestParseTask_StartStop(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 1,
		Text:       "- [x] Write report (@[[2026-01-14]]) ::start [[2026-01-14]] 15:58 ::stop [[2026-01-14]] 16:40",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.Status != "done" {
		t.Errorf("status = %q, want done", task.Status)
	}
	if len(task.Markers) != 2 {
		t.Fatalf("markers count = %d, want 2", len(task.Markers))
	}
	if task.Markers[0].Kind != "start" || task.Markers[0].Time != "15:58" {
		t.Errorf("marker[0] = %+v", task.Markers[0])
	}
	if task.Markers[1].Kind != "stop" || task.Markers[1].Time != "16:40" {
		t.Errorf("marker[1] = %+v", task.Markers[1])
	}
}

func TestParseTask_Indented(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 1,
		Text:       "\t- [ ] Indented task (@[[2026-02-17]])\n",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.Body != "Indented task" {
		t.Errorf("body = %q", task.Body)
	}
}

func TestParseTask_WikiLinksInBody(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 1,
		Text:       "- [ ] Visit [[The Commons]] for lunch (@[[2026-02-17]])",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.Body != "Visit [[The Commons]] for lunch" {
		t.Errorf("body = %q", task.Body)
	}
}

func TestParseTask_AliasDate(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 1,
		Text:       "- [ ] Aliased task (@[[1749970209-GXKH|2025-06-15]])",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.DueDate == nil || !task.DueDate.Equal(mustDate("2025-06-15")) {
		t.Errorf("date = %v, want 2025-06-15", task.DueDate)
	}
}

func TestParseTask_PathPrefixDate(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 1,
		Text:       "- [ ] Path prefix task (@[[daily/2025-06-13]])",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.DueDate == nil || !task.DueDate.Equal(mustDate("2025-06-13")) {
		t.Errorf("date = %v, want 2025-06-13", task.DueDate)
	}
}

func TestParseTask_EmptyDate(t *testing.T) {
	// (@[[]]) doesn't match dateRe, so treated as undated
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 1,
		Text:       "- [ ] Broken task (@[[]])",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.DueDate != nil {
		t.Errorf("expected nil DueDate, got %v", task.DueDate)
	}
	if task.Body != "Broken task (@[[]])" {
		t.Errorf("body = %q", task.Body)
	}
}

func TestParseTask_NoSpaceMarkers(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 1,
		Text:       "- [x] Buy screws (@[[2026-01-28]]) #fish-tank::complete [[2026-01-29]] 09:16",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if len(task.Tags) != 1 || task.Tags[0] != "fish-tank" {
		t.Errorf("tags = %v", task.Tags)
	}
	if len(task.Markers) != 1 || task.Markers[0].Kind != "complete" {
		t.Errorf("markers = %v", task.Markers)
	}
}

func TestParseTask_FullComplex(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/project.md",
		LineNumber: 42,
		Text:       "- [x] Rewrite About Me Section <30m> (@[[2026-01-23]] 15:00) ::start [[2026-01-23]] 15:17::complete [[2026-01-23]] 17:19",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.Status != "done" {
		t.Errorf("status = %q", task.Status)
	}
	if task.Body != "Rewrite About Me Section" {
		t.Errorf("body = %q", task.Body)
	}
	if task.Duration != "30m" {
		t.Errorf("duration = %q", task.Duration)
	}
	if task.DueTime != "15:00" {
		t.Errorf("time = %q", task.DueTime)
	}
	if task.DueDate == nil || !task.DueDate.Equal(mustDate("2026-01-23")) {
		t.Errorf("date = %v", task.DueDate)
	}
	if len(task.Markers) != 2 {
		t.Fatalf("markers = %d, want 2", len(task.Markers))
	}
	if task.Markers[0].Kind != "start" || task.Markers[0].Time != "15:17" {
		t.Errorf("marker[0] = %+v", task.Markers[0])
	}
	if task.Markers[1].Kind != "complete" || task.Markers[1].Time != "17:19" {
		t.Errorf("marker[1] = %+v", task.Markers[1])
	}
}

func TestParseTask_IrrelevantStatus(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 1,
		Text:       "- [-] Cancelled task (@[[2024-11-25]])",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.Status != "irrelevant" {
		t.Errorf("status = %q, want irrelevant", task.Status)
	}
}

func TestParseTasks_SkipsUnparseable(t *testing.T) {
	matches := []RawMatch{
		{Path: "a.md", LineNumber: 1, Text: "- [ ] Good task (@[[2026-02-17]])"},
		{Path: "b.md", LineNumber: 2, Text: "not a task line at all"},
		{Path: "c.md", LineNumber: 3, Text: "- [ ] Also good (@[[2026-02-18]])"},
	}
	tasks := ParseTasks(matches, defaultCtx)
	if len(tasks) != 2 {
		t.Errorf("got %d tasks, want 2", len(tasks))
	}
}

func TestParseTask_MarkerWithPathPrefixDate(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/test.md",
		LineNumber: 1,
		Text:       "- [x] Backend docs <60m> (@[[2025-05-31]])::complete [[daily/2025-06-13]] 08:50",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if len(task.Markers) != 1 {
		t.Fatalf("markers count = %d, want 1", len(task.Markers))
	}
	if task.Markers[0].Date != "2025-06-13" {
		t.Errorf("marker date = %q, want 2025-06-13", task.Markers[0].Date)
	}
}

func TestParseTask_Undated(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/someday.md",
		LineNumber: 3,
		Text:       "- [ ] Investigate OOM Kill Root Cause",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.DueDate != nil {
		t.Errorf("expected nil DueDate, got %v", task.DueDate)
	}
	if task.Body != "Investigate OOM Kill Root Cause" {
		t.Errorf("body = %q", task.Body)
	}
	if task.Status != "open" {
		t.Errorf("status = %q, want open", task.Status)
	}
	if task.DueTime != "" {
		t.Errorf("time = %q, want empty", task.DueTime)
	}
}

func TestParseTask_UndatedWithTags(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/someday.md",
		LineNumber: 1,
		Text:       "- [ ] Fix memory leak #backend #urgent",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.DueDate != nil {
		t.Errorf("expected nil DueDate, got %v", task.DueDate)
	}
	if task.Body != "Fix memory leak" {
		t.Errorf("body = %q", task.Body)
	}
	if len(task.Tags) != 2 || task.Tags[0] != "backend" || task.Tags[1] != "urgent" {
		t.Errorf("tags = %v, want [backend urgent]", task.Tags)
	}
}

func TestParseTask_UndatedWithDuration(t *testing.T) {
	m := RawMatch{
		Path:       "/notes/someday.md",
		LineNumber: 1,
		Text:       "- [ ] Research caching strategies <60m>",
	}
	task, err := ParseTask(m, defaultCtx)
	if err != nil {
		t.Fatal(err)
	}
	if task.DueDate != nil {
		t.Errorf("expected nil DueDate, got %v", task.DueDate)
	}
	if task.Body != "Research caching strategies" {
		t.Errorf("body = %q", task.Body)
	}
	if task.Duration != "60m" {
		t.Errorf("duration = %q, want 60m", task.Duration)
	}
}
