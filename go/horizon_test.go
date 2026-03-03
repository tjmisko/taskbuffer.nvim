package main

import (
	"strings"
	"testing"
	"time"
)

// testToday is 2026-02-17 (Tuesday), matching testNow in format_test.go
var testToday = time.Date(2026, 2, 17, 0, 0, 0, 0, time.Local)

func TestParseAfterValue_IntegerOffset(t *testing.T) {
	tests := []struct {
		name   string
		offset float64
		want   string
	}{
		{"zero is today", 0, "2026-02-17"},
		{"one is tomorrow", 1, "2026-02-18"},
		{"negative is past", -7, "2026-02-10"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseAfterValue(tt.offset, testToday, time.Monday)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.Format("2006-01-02") != tt.want {
				t.Errorf("got %s, want %s", got.Format("2006-01-02"), tt.want)
			}
		})
	}
}

func TestParseAfterValue_DurationString(t *testing.T) {
	tests := []struct {
		name string
		dur  string
		want string
	}{
		{"2d", "2d", "2026-02-19"},
		{"1w", "1w", "2026-02-24"},
		{"1m", "1m", "2026-03-19"},
		{"1y", "1y", "2027-02-17"},
		{"-1w", "-1w", "2026-02-10"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseAfterValue(tt.dur, testToday, time.Monday)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.Format("2006-01-02") != tt.want {
				t.Errorf("got %s, want %s", got.Format("2006-01-02"), tt.want)
			}
		})
	}
}

func TestParseAfterValue_CalendarKeywords(t *testing.T) {
	// testToday is 2026-02-17, Tuesday, week_start=Monday
	tests := []struct {
		name string
		kw   string
		want string
	}{
		{"past", "past", "1926-02-17"},
		{"yesterday", "yesterday", "2026-02-16"},
		// Week: Mon-Sun, today is Tue, end_of_week = day after Sunday = next Monday
		{"end_of_week", "end_of_week", "2026-02-23"},
		// End of Feb = March 1
		{"end_of_month", "end_of_month", "2026-03-01"},
		// Q1 ends March 31, next quarter starts April 1
		{"end_of_quarter", "end_of_quarter", "2026-04-01"},
		// Next year
		{"end_of_year", "end_of_year", "2027-01-01"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseAfterValue(tt.kw, testToday, time.Monday)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.Format("2006-01-02") != tt.want {
				t.Errorf("got %s, want %s", got.Format("2006-01-02"), tt.want)
			}
		})
	}
}

func TestParseAfterValue_EndOfWeek_SundayStart(t *testing.T) {
	// With Sunday start, week ends Saturday.
	// Today is Tuesday. Saturday is 4 days away. Day after = Sunday = 2026-02-22.
	got, err := parseAfterValue("end_of_week", testToday, time.Sunday)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := "2026-02-22"
	if got.Format("2006-01-02") != want {
		t.Errorf("got %s, want %s", got.Format("2006-01-02"), want)
	}
}

func TestParseAfterValue_InvalidInput(t *testing.T) {
	_, err := parseAfterValue("bogus", testToday, time.Monday)
	if err == nil {
		t.Error("expected error for bogus keyword")
	}

	_, err = parseAfterValue(nil, testToday, time.Monday)
	if err == nil {
		t.Error("expected error for nil")
	}
}

func TestResolveHorizons_DefaultsWhenNil(t *testing.T) {
	horizons, err := ResolveHorizons(nil, testToday, time.Monday, "sorted")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// 7 dated + 1 undated = 8
	if len(horizons) != 8 {
		t.Fatalf("expected 8 horizons, got %d", len(horizons))
	}

	// Last one should be undated
	last := horizons[len(horizons)-1]
	if !last.Undated {
		t.Error("last horizon should be undated")
	}
	if last.Label != "# Someday" {
		t.Errorf("last horizon label = %q, want # Someday", last.Label)
	}

	// First dated should be overdue (earliest cutoff)
	if horizons[0].Label != "# Overdue" {
		t.Errorf("first horizon = %q, want # Overdue", horizons[0].Label)
	}
}

func TestResolveHorizons_CustomSpecs(t *testing.T) {
	specs := []HorizonSpec{
		{Label: "# Past", After: "past"},
		{Label: "# Now", After: float64(0)},
		{Label: "# Soon", After: "1w"},
		{Label: "# Backlog", Undated: true},
	}
	horizons, err := ResolveHorizons(specs, testToday, time.Monday, "sorted")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(horizons) != 4 {
		t.Fatalf("expected 4 horizons, got %d", len(horizons))
	}
	if horizons[0].Label != "# Past" {
		t.Errorf("first = %q, want # Past", horizons[0].Label)
	}
	if horizons[1].Label != "# Now" {
		t.Errorf("second = %q, want # Now", horizons[1].Label)
	}
	if horizons[2].Label != "# Soon" {
		t.Errorf("third = %q, want # Soon", horizons[2].Label)
	}
	if horizons[3].Label != "# Backlog" || !horizons[3].Undated {
		t.Errorf("fourth = %q undated=%v, want # Backlog undated=true", horizons[3].Label, horizons[3].Undated)
	}
}

func TestResolveHorizons_SortedOverlap(t *testing.T) {
	// Specs out of order — sorted overlap should reorder by cutoff
	specs := []HorizonSpec{
		{Label: "# Later", After: "1w"},
		{Label: "# Now", After: float64(0)},
		{Label: "# Past", After: "past"},
	}
	horizons, err := ResolveHorizons(specs, testToday, time.Monday, "sorted")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(horizons) != 3 {
		t.Fatalf("expected 3 horizons, got %d", len(horizons))
	}
	// Should be sorted: Past, Now, Later
	if horizons[0].Label != "# Past" {
		t.Errorf("first = %q, want # Past", horizons[0].Label)
	}
	if horizons[1].Label != "# Now" {
		t.Errorf("second = %q, want # Now", horizons[1].Label)
	}
	if horizons[2].Label != "# Later" {
		t.Errorf("third = %q, want # Later", horizons[2].Label)
	}

	// Cutoffs should be ascending
	for i := 1; i < len(horizons); i++ {
		if !horizons[i].Cutoff.After(horizons[i-1].Cutoff) {
			t.Errorf("cutoff[%d] (%s) not after cutoff[%d] (%s)",
				i, horizons[i].Cutoff, i-1, horizons[i-1].Cutoff)
		}
	}
}

func TestResolveHorizons_FallbackOnError(t *testing.T) {
	specs := []HorizonSpec{
		{Label: "# Bad", After: "bogus_keyword"},
	}
	horizons, err := ResolveHorizons(specs, testToday, time.Monday, "sorted")
	if err != nil {
		t.Fatalf("unexpected error (should fallback): %v", err)
	}
	// Should fall back to defaults (8 horizons)
	if len(horizons) != 8 {
		t.Fatalf("expected 8 default horizons on fallback, got %d", len(horizons))
	}
}

func TestParseWeekday_Valid(t *testing.T) {
	if got := parseWeekday("monday"); got != time.Monday {
		t.Errorf("got %v, want Monday", got)
	}
	if got := parseWeekday("Sunday"); got != time.Sunday {
		t.Errorf("got %v, want Sunday", got)
	}
	if got := parseWeekday("FRIDAY"); got != time.Friday {
		t.Errorf("got %v, want Friday", got)
	}
}

func TestParseWeekday_Default(t *testing.T) {
	if got := parseWeekday(""); got != time.Monday {
		t.Errorf("got %v, want Monday for empty", got)
	}
	if got := parseWeekday("invalid"); got != time.Monday {
		t.Errorf("got %v, want Monday for invalid", got)
	}
}

func TestParseDuration(t *testing.T) {
	tests := []struct {
		input string
		want  int
		err   bool
	}{
		{"2d", 2, false},
		{"1w", 7, false},
		{"1m", 30, false},
		{"1y", 365, false},
		{"-1w", -7, false},
		{"3d", 3, false},
		{"bogus", 0, true},
		{"", 0, true},
	}
	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got, err := parseDuration(tt.input)
			if (err != nil) != tt.err {
				t.Fatalf("parseDuration(%q) error = %v, wantErr %v", tt.input, err, tt.err)
			}
			if got != tt.want {
				t.Errorf("parseDuration(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

func intPtr(n int) *int { return &n }

func TestParseDuration_EdgeCases(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  int
		err   bool
	}{
		{"zero days", "0d", 0, false},
		{"zero weeks", "0w", 0, false},
		{"large year", "999y", 364635, false},
		{"invalid unit x", "2x", 0, true},
		{"double unit dd", "1dd", 0, true},
		{"unit before number", "d2", 0, true},
		{"space in middle", "2 d", 0, true},
		{"leading space", " 1d", 0, true},
		{"trailing space", "1d ", 0, true},
		{"uppercase unit", "1D", 0, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseDuration(tt.input)
			if (err != nil) != tt.err {
				t.Fatalf("parseDuration(%q) error = %v, wantErr %v", tt.input, err, tt.err)
			}
			if !tt.err && got != tt.want {
				t.Errorf("parseDuration(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

func TestParseAfterValue_UnsupportedTypes(t *testing.T) {
	t.Run("bool is unsupported", func(t *testing.T) {
		_, err := parseAfterValue(true, testToday, time.Monday)
		if err == nil {
			t.Fatal("expected error for bool input")
		}
		if !strings.Contains(err.Error(), "unsupported after type") {
			t.Errorf("error %q should contain 'unsupported after type'", err.Error())
		}
	})

	t.Run("slice is unsupported", func(t *testing.T) {
		_, err := parseAfterValue([]string{"a"}, testToday, time.Monday)
		if err == nil {
			t.Fatal("expected error for slice input")
		}
	})

	t.Run("int offset", func(t *testing.T) {
		got, err := parseAfterValue(int(5), testToday, time.Monday)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		want := "2026-02-22"
		if got.Format("2006-01-02") != want {
			t.Errorf("got %s, want %s", got.Format("2006-01-02"), want)
		}
	})
}

func TestResolveCalendarKeyword_WeekBoundaries(t *testing.T) {
	tests := []struct {
		name      string
		today     time.Time
		weekStart time.Weekday
		want      string
	}{
		// Monday-start week (Mon-Sun), week of Feb 16-22
		{"mon-start Mon Feb16", time.Date(2026, 2, 16, 0, 0, 0, 0, time.Local), time.Monday, "2026-02-23"},
		{"mon-start Tue Feb17", time.Date(2026, 2, 17, 0, 0, 0, 0, time.Local), time.Monday, "2026-02-23"},
		{"mon-start Wed Feb18", time.Date(2026, 2, 18, 0, 0, 0, 0, time.Local), time.Monday, "2026-02-23"},
		{"mon-start Thu Feb19", time.Date(2026, 2, 19, 0, 0, 0, 0, time.Local), time.Monday, "2026-02-23"},
		{"mon-start Fri Feb20", time.Date(2026, 2, 20, 0, 0, 0, 0, time.Local), time.Monday, "2026-02-23"},
		{"mon-start Sat Feb21", time.Date(2026, 2, 21, 0, 0, 0, 0, time.Local), time.Monday, "2026-02-23"},
		{"mon-start Sun Feb22", time.Date(2026, 2, 22, 0, 0, 0, 0, time.Local), time.Monday, "2026-03-02"},
		// Sunday-start week (Sun-Sat), week of Feb 15-21
		{"sun-start Sun Feb15", time.Date(2026, 2, 15, 0, 0, 0, 0, time.Local), time.Sunday, "2026-02-22"},
		{"sun-start Mon Feb16", time.Date(2026, 2, 16, 0, 0, 0, 0, time.Local), time.Sunday, "2026-02-22"},
		{"sun-start Tue Feb17", time.Date(2026, 2, 17, 0, 0, 0, 0, time.Local), time.Sunday, "2026-02-22"},
		{"sun-start Wed Feb18", time.Date(2026, 2, 18, 0, 0, 0, 0, time.Local), time.Sunday, "2026-02-22"},
		{"sun-start Thu Feb19", time.Date(2026, 2, 19, 0, 0, 0, 0, time.Local), time.Sunday, "2026-02-22"},
		{"sun-start Fri Feb20", time.Date(2026, 2, 20, 0, 0, 0, 0, time.Local), time.Sunday, "2026-02-22"},
		{"sun-start Sat Feb21", time.Date(2026, 2, 21, 0, 0, 0, 0, time.Local), time.Sunday, "2026-03-01"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := resolveCalendarKeyword("end_of_week", tt.today, tt.weekStart)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.Format("2006-01-02") != tt.want {
				t.Errorf("got %s, want %s", got.Format("2006-01-02"), tt.want)
			}
		})
	}
}

func TestResolveCalendarKeyword_MonthBoundaries(t *testing.T) {
	tests := []struct {
		name  string
		today time.Time
		want  string
	}{
		{"Jan 31", time.Date(2026, 1, 31, 0, 0, 0, 0, time.Local), "2026-02-01"},
		{"Feb 28 non-leap", time.Date(2026, 2, 28, 0, 0, 0, 0, time.Local), "2026-03-01"},
		{"Feb 29 leap year", time.Date(2028, 2, 29, 0, 0, 0, 0, time.Local), "2028-03-01"},
		{"Dec 31 year boundary", time.Date(2026, 12, 31, 0, 0, 0, 0, time.Local), "2027-01-01"},
		{"Feb 1 first day", time.Date(2026, 2, 1, 0, 0, 0, 0, time.Local), "2026-03-01"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := resolveCalendarKeyword("end_of_month", tt.today, time.Monday)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.Format("2006-01-02") != tt.want {
				t.Errorf("got %s, want %s", got.Format("2006-01-02"), tt.want)
			}
		})
	}
}

func TestResolveCalendarKeyword_QuarterBoundaries(t *testing.T) {
	tests := []struct {
		name  string
		today time.Time
		want  string
	}{
		{"Q1 mid", time.Date(2026, 1, 15, 0, 0, 0, 0, time.Local), "2026-04-01"},
		{"Q2 mid", time.Date(2026, 4, 15, 0, 0, 0, 0, time.Local), "2026-07-01"},
		{"Q3 mid", time.Date(2026, 7, 15, 0, 0, 0, 0, time.Local), "2026-10-01"},
		{"Q4 mid", time.Date(2026, 10, 15, 0, 0, 0, 0, time.Local), "2027-01-01"},
		{"Q1 last day", time.Date(2026, 3, 31, 0, 0, 0, 0, time.Local), "2026-04-01"},
		{"Q2 last day", time.Date(2026, 6, 30, 0, 0, 0, 0, time.Local), "2026-07-01"},
		{"Q3 last day", time.Date(2026, 9, 30, 0, 0, 0, 0, time.Local), "2026-10-01"},
		{"Q4 last day", time.Date(2026, 12, 31, 0, 0, 0, 0, time.Local), "2027-01-01"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := resolveCalendarKeyword("end_of_quarter", tt.today, time.Monday)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.Format("2006-01-02") != tt.want {
				t.Errorf("got %s, want %s", got.Format("2006-01-02"), tt.want)
			}
		})
	}
}

func TestResolveHorizons_EmptySlice(t *testing.T) {
	horizons, err := ResolveHorizons([]HorizonSpec{}, testToday, time.Monday, "sorted")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(horizons) != 8 {
		t.Fatalf("expected 8 default horizons for empty slice, got %d", len(horizons))
	}
}

func TestResolveHorizons_OnlyUndated(t *testing.T) {
	specs := []HorizonSpec{
		{Label: "# Backlog", Undated: true},
		{Label: "# Ideas", Undated: true},
	}
	horizons, err := ResolveHorizons(specs, testToday, time.Monday, "sorted")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(horizons) != 2 {
		t.Fatalf("expected 2 horizons, got %d", len(horizons))
	}
	for _, h := range horizons {
		if !h.Undated {
			t.Errorf("horizon %q should be undated", h.Label)
		}
	}
}

func TestResolveHorizons_MixedValidInvalid(t *testing.T) {
	specs := []HorizonSpec{
		{Label: "# Today", After: float64(0)},
		{Label: "# Bad", After: "bogus_keyword"},
		{Label: "# Someday", Undated: true},
	}
	horizons, err := ResolveHorizons(specs, testToday, time.Monday, "sorted")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(horizons) != 2 {
		t.Fatalf("expected 2 horizons (1 dated + 1 undated), got %d", len(horizons))
	}
}

func TestResolveHorizons_DuplicateCutoffs(t *testing.T) {
	specs := []HorizonSpec{
		{Label: "# Alpha", After: float64(0)},
		{Label: "# Beta", After: float64(0)},
	}
	horizons, err := ResolveHorizons(specs, testToday, time.Monday, "sorted")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(horizons) != 2 {
		t.Fatalf("expected 2 horizons, got %d", len(horizons))
	}
	labels := map[string]bool{}
	for _, h := range horizons {
		labels[h.Label] = true
	}
	if !labels["# Alpha"] || !labels["# Beta"] {
		t.Errorf("expected both labels present, got %v", labels)
	}
}

func TestResolveHorizons_ExplicitOrder(t *testing.T) {
	specs := []HorizonSpec{
		{Label: "# First", After: float64(0), Order: intPtr(10)},
		{Label: "# Second", After: float64(1), Order: intPtr(5)},
		{Label: "# Third", After: float64(2), Order: intPtr(1)},
	}
	// Use non-sorted overlap so explicit Order values are preserved
	horizons, err := ResolveHorizons(specs, testToday, time.Monday, "explicit")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(horizons) != 3 {
		t.Fatalf("expected 3 horizons, got %d", len(horizons))
	}
	for _, h := range horizons {
		switch h.Label {
		case "# First":
			if h.Order != 10 {
				t.Errorf("# First order = %d, want 10", h.Order)
			}
		case "# Second":
			if h.Order != 5 {
				t.Errorf("# Second order = %d, want 5", h.Order)
			}
		case "# Third":
			if h.Order != 1 {
				t.Errorf("# Third order = %d, want 1", h.Order)
			}
		default:
			t.Errorf("unexpected label %q", h.Label)
		}
	}
}

func TestResolveHorizons_MultipleUndated(t *testing.T) {
	specs := []HorizonSpec{
		{Label: "# Today", After: float64(0)},
		{Label: "# Backlog", Undated: true},
		{Label: "# Ideas", Undated: true},
	}
	horizons, err := ResolveHorizons(specs, testToday, time.Monday, "sorted")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(horizons) != 3 {
		t.Fatalf("expected 3 horizons, got %d", len(horizons))
	}
	undatedCount := 0
	for _, h := range horizons {
		if h.Undated {
			undatedCount++
		}
	}
	if undatedCount != 2 {
		t.Errorf("expected 2 undated horizons, got %d", undatedCount)
	}
}
