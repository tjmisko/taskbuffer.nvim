package main

import (
	"regexp"
	"testing"
)

func TestStrftimeToGo(t *testing.T) {
	tests := []struct {
		name   string
		input  string
		expect string
	}{
		{"ISO date", "%Y-%m-%d", "2006-01-02"},
		{"US date", "%m/%d/%Y", "01/02/2006"},
		{"European date", "%d.%m.%Y", "02.01.2006"},
		{"Compact date", "%Y%m%d", "20060102"},
		{"24h time", "%H:%M", "15:04"},
		{"12h time", "%I:%M %p", "3:04 PM"},
		{"Shorthand date", "%F", "2006-01-02"},
		{"Shorthand time", "%R", "15:04"},
		{"Escaped percent", "%%Y", "%Y"},
		{"Empty", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := StrftimeToGo(tt.input)
			if got != tt.expect {
				t.Errorf("StrftimeToGo(%q) = %q, want %q", tt.input, got, tt.expect)
			}
		})
	}
}

func TestStrftimeToRegex(t *testing.T) {
	tests := []struct {
		name   string
		input  string
		expect string
	}{
		{"ISO date", "%Y-%m-%d", `\d{4}-\d{2}-\d{2}`},
		{"US date", "%m/%d/%Y", `\d{2}/\d{2}/\d{4}`},
		{"European date with dots", "%d.%m.%Y", `\d{2}\.\d{2}\.\d{4}`},
		{"Compact date", "%Y%m%d", `\d{4}\d{2}\d{2}`},
		{"24h time", "%H:%M", `\d{2}:\d{2}`},
		{"12h time", "%I:%M %p", `\d{1,2}:\d{2}\s*[AaPp][Mm]`},
		{"Empty", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := StrftimeToRegex(tt.input)
			if got != tt.expect {
				t.Errorf("StrftimeToRegex(%q) = %q, want %q", tt.input, got, tt.expect)
			}
		})
	}
}

func TestStrftimeToRegex_Matches(t *testing.T) {
	tests := []struct {
		name    string
		format  string
		match   string
		noMatch string
	}{
		{"ISO date", "%Y-%m-%d", "2026-03-04", "03/04/2026"},
		{"US date", "%m/%d/%Y", "03/04/2026", "2026-03-04"},
		{"Dot date", "%d.%m.%Y", "04.03.2026", "04X03X2026"},
		{"24h time", "%H:%M", "15:04", "3:04 PM"},
		{"12h time", "%I:%M %p", "1:00 PM", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			re := regexp.MustCompile("^" + StrftimeToRegex(tt.format) + "$")
			if !re.MatchString(tt.match) {
				t.Errorf("regex from %q should match %q", tt.format, tt.match)
			}
			if tt.noMatch != "" && re.MatchString(tt.noMatch) {
				t.Errorf("regex from %q should NOT match %q", tt.format, tt.noMatch)
			}
		})
	}
}

func TestResolveDateTimeFormats_Defaults(t *testing.T) {
	fmts := ResolveDateTimeFormats("", "")
	if fmts.GoDate != "2006-01-02" {
		t.Errorf("GoDate = %q, want 2006-01-02", fmts.GoDate)
	}
	if fmts.GoTime != "15:04" {
		t.Errorf("GoTime = %q, want 15:04", fmts.GoTime)
	}
	if fmts.DateRe != `\d{4}-\d{2}-\d{2}` {
		t.Errorf("DateRe = %q", fmts.DateRe)
	}
	if fmts.TimeRe != `\d{2}:\d{2}` {
		t.Errorf("TimeRe = %q", fmts.TimeRe)
	}
}

func TestResolveDateTimeFormats_Custom(t *testing.T) {
	fmts := ResolveDateTimeFormats("%m/%d/%Y", "%I:%M %p")
	if fmts.GoDate != "01/02/2006" {
		t.Errorf("GoDate = %q, want 01/02/2006", fmts.GoDate)
	}
	if fmts.GoTime != "3:04 PM" {
		t.Errorf("GoTime = %q, want 3:04 PM", fmts.GoTime)
	}
}

func TestStrftimeToRegex_12hTimeSpaceHandling(t *testing.T) {
	// The space between minutes and AM/PM should become \s* in the regex
	// to handle varying whitespace
	re := regexp.MustCompile("^" + StrftimeToRegex("%I:%M %p") + "$")
	if !re.MatchString("1:00 PM") {
		t.Error("should match '1:00 PM'")
	}
	if !re.MatchString("12:30PM") {
		t.Error("should match '12:30PM' (no space)")
	}
	if !re.MatchString("1:00  AM") {
		t.Error("should match '1:00  AM' (double space)")
	}
}
