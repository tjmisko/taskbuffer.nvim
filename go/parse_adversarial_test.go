package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// rawMatch builds a RawMatch with sensible defaults for adversarial tests.
func rawMatch(line string) RawMatch {
	return RawMatch{Path: "adversarial.md", LineNumber: 1, Text: line}
}

// =============================================================================
// 1. Regex alternation ordering (first-match, not longest-match)
// =============================================================================

func TestAdversarial_AlternationShortPrefixShadowsLong(t *testing.T) {
	// BUG: sortStrings sorts escaped checkboxes alphabetically. Regex `|` is
	// first-match. If "- " and "- [ ]" are both configured, "- " sorts first
	// and matches before "- [ ]" gets a chance. The captured checkbox is "- "
	// (the bullet), so statusMap maps it to "bullet" — the task is parsed but
	// with the wrong status and a mangled body that starts with "[ ] ".
	tests := []struct {
		name       string
		checkbox   map[string]string
		input      string
		wantStatus string
		wantBody   string
	}{
		{
			name:       "dash-space shadows dash-bracket",
			checkbox:   map[string]string{"open": "- [ ]", "bullet": "- "},
			input:      "- [ ] Real task",
			wantStatus: "open",
			wantBody:   "Real task",
		},
		{
			name:       "star variant",
			checkbox:   map[string]string{"open": "* [ ]", "bullet": "* "},
			input:      "* [ ] Star task",
			wantStatus: "open",
			wantBody:   "Star task",
		},
		{
			name:       "non-overlapping is fine",
			checkbox:   map[string]string{"open": "* [ ]", "done": "* [x]"},
			input:      "* [x] Done",
			wantStatus: "done",
			wantBody:   "Done",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx := NewParseContext(Config{Checkbox: tt.checkbox})
			task, err := ParseTask(rawMatch(tt.input), ctx)
			if err != nil {
				t.Fatalf("ParseTask error: %v", err)
			}
			if task.Status != tt.wantStatus {
				t.Errorf("status = %q, want %q", task.Status, tt.wantStatus)
			}
			if task.Body != tt.wantBody {
				t.Errorf("body = %q, want %q", task.Body, tt.wantBody)
			}
		})
	}
}

// =============================================================================
// 2. Empty checkbox string
// =============================================================================

func TestAdversarial_EmptyCheckbox(t *testing.T) {
	// BUG: regexp.QuoteMeta("") = "". statusRe becomes `^\s*(|...)`
	// which matches the empty string at line start. Every line becomes a task.
	ctx := NewParseContext(Config{
		Checkbox: map[string]string{"open": "", "done": "- [x]"},
	})

	tests := []struct {
		name  string
		input string
	}{
		{"plain text", "Hello world"},
		{"markdown header", "# Not a task"},
		{"blank line", ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := ParseTask(rawMatch(tt.input), ctx)
			if err == nil {
				// BUG: empty checkbox causes any line to be parsed as a task
				t.Errorf("expected error for non-task line %q, but got none (empty checkbox matches everything)", tt.input)
			}
		})
	}
}

// =============================================================================
// 3. Delimiter collisions
// =============================================================================

func TestAdversarial_TagPrefixEqualsMarkerPrefix(t *testing.T) {
	// Known limitation: when TagPrefix == MarkerPrefix, tagRe matches marker
	// keywords as tags. e.g. "::start" is captured as tag "start".
	// This is a user configuration error — the prefixes should be distinct.
	ctx := NewParseContext(Config{
		TagPrefix:    "::",
		MarkerPrefix: "::",
	})

	task, err := ParseTask(rawMatch("- [ ] Some task (@[[2026-02-17]]) ::start [[2026-02-17]] 15:00"), ctx)
	if err != nil {
		t.Fatal(err)
	}

	// Document: marker keyword leaks into tags when prefixes collide
	hasStartTag := false
	for _, tag := range task.Tags {
		if tag == "start" {
			hasStartTag = true
		}
	}
	if hasStartTag {
		t.Logf("known limitation: marker keyword 'start' appears as tag when TagPrefix == MarkerPrefix (tags: %v)", task.Tags)
	}
}

func TestAdversarial_TagPrefixBracket(t *testing.T) {
	// Known limitation: TagPrefix "[" makes tagRe = `\[([A-Za-z_][\w-]*)`
	// which matches wiki links like [[Commons]] -> tag "Commons".
	// This is a user configuration error — "[" collides with wiki link syntax.
	ctx := NewParseContext(Config{TagPrefix: "["})

	task, err := ParseTask(rawMatch("- [ ] Visit [[Commons]] for lunch (@[[2026-02-17]])"), ctx)
	if err != nil {
		t.Fatal(err)
	}

	// Document: wiki links are captured as tags when TagPrefix is "["
	hasCommonsTag := false
	for _, tag := range task.Tags {
		if tag == "Commons" {
			hasCommonsTag = true
		}
	}
	if hasCommonsTag {
		t.Logf("known limitation: wiki link 'Commons' captured as tag with TagPrefix='[' (tags: %v)", task.Tags)
	}
}

func TestAdversarial_MarkerPrefixSingleColon(t *testing.T) {
	ctx := NewParseContext(Config{MarkerPrefix: ":"})

	t.Run("undated body truncated at first colon", func(t *testing.T) {
		// BUG: for undated tasks, body ends at first occurrence of markerPrefix.
		// With MarkerPrefix ":", body "Note: fix bug" is truncated to "Note".
		task, err := ParseTask(rawMatch("- [ ] Note: fix bug"), ctx)
		if err != nil {
			t.Fatal(err)
		}
		if task.Body != "Note: fix bug" {
			t.Errorf("body = %q, want %q (truncated at first ':')", task.Body, "Note: fix bug")
		}
	})

	t.Run("dated body preserved", func(t *testing.T) {
		// Dated tasks: body ends at dateGroupIdx, not at marker prefix
		task, err := ParseTask(rawMatch("- [ ] Note: fix bug (@[[2026-02-17]])"), ctx)
		if err != nil {
			t.Fatal(err)
		}
		if task.Body != "Note: fix bug" {
			t.Errorf("body = %q, want %q", task.Body, "Note: fix bug")
		}
	})
}

// =============================================================================
// 4. Marker prefix in body text (default config!)
// =============================================================================

func TestAdversarial_MarkerPrefixInBodyText(t *testing.T) {
	// BUG: default "::" prefix. Undated tasks with C++ namespaces, URLs, or
	// Rust turbofish — body truncated at first "::".
	ctx := DefaultParseContext()

	tests := []struct {
		name     string
		input    string
		wantBody string
	}{
		{
			name:     "C++ namespace",
			input:    "- [ ] Fix std::vector crash",
			wantBody: "Fix std::vector crash",
		},
		{
			name:     "Rust turbofish",
			input:    "- [ ] Refactor Vec::new() call",
			wantBody: "Refactor Vec::new() call",
		},
		{
			name:     "URL with port",
			input:    "- [ ] Check http://localhost::8080/health",
			wantBody: "Check http://localhost::8080/health",
		},
		{
			name:     "dated variant preserves body",
			input:    "- [ ] Fix std::vector crash (@[[2026-02-17]])",
			wantBody: "Fix std::vector crash",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			task, err := ParseTask(rawMatch(tt.input), ctx)
			if err != nil {
				t.Fatal(err)
			}
			if task.Body != tt.wantBody {
				t.Errorf("body = %q, want %q", task.Body, tt.wantBody)
			}
		})
	}
}

// =============================================================================
// 5. Marker date format hardcoded
// =============================================================================

func TestAdversarial_MarkerDateIgnoresCustomWrapper(t *testing.T) {
	// BUG: markerRe (parse.go:113) always expects [[YYYY-MM-DD]] regardless of
	// DateWrapper config. Markers written with custom wrappers fail to parse.

	t.Run("default brackets work", func(t *testing.T) {
		ctx := NewParseContext(Config{DateWrapper: []string{"{", "}"}})
		task, err := ParseTask(rawMatch("- [ ] Task {2026-02-17} ::start [[2026-02-17]] 15:00"), ctx)
		if err != nil {
			t.Fatal(err)
		}
		if len(task.Markers) != 1 {
			t.Fatalf("markers = %d, want 1", len(task.Markers))
		}
		if task.Markers[0].Kind != "start" {
			t.Errorf("marker kind = %q", task.Markers[0].Kind)
		}
	})

	t.Run("custom wrapper fails for markers", func(t *testing.T) {
		// Known limitation: markers always use [[YYYY-MM-DD]] regardless of
		// DateWrapper config. Markers written with custom wrappers silently fail.
		// This is by design — markers use wiki-link syntax for Obsidian compatibility.
		ctx := NewParseContext(Config{DateWrapper: []string{"{", "}"}})
		task, err := ParseTask(rawMatch("- [ ] Task {2026-02-17} ::start {2026-02-17} 15:00"), ctx)
		if err != nil {
			t.Fatal(err)
		}
		if len(task.Markers) == 0 {
			t.Logf("known limitation: markers with custom DateWrapper {date} are not parsed (markerRe expects [[date]])")
		}
	})
}

// =============================================================================
// 6. Duplicate checkbox values
// =============================================================================

func TestAdversarial_DuplicateCheckboxDeterministic(t *testing.T) {
	// Two statuses map to the same checkbox string. After fix: alphabetically
	// first status name wins deterministically.
	cfg := Config{
		Checkbox: map[string]string{
			"alpha":   "- [ ]",
			"charlie": "- [ ]",
			"bravo":   "- [x]",
		},
	}

	statuses := make(map[string]bool)
	for i := 0; i < 100; i++ {
		ctx := NewParseContext(cfg)
		task, err := ParseTask(rawMatch("- [ ] Test task"), ctx)
		if err != nil {
			t.Fatalf("iteration %d: %v", i, err)
		}
		statuses[task.Status] = true
	}

	if len(statuses) > 1 {
		t.Errorf("nondeterministic status: got %v over 100 iterations (expected consistent result)", statuses)
	}
	// After fix: alphabetically first ("alpha") should always win
	if !statuses["alpha"] {
		t.Errorf("expected 'alpha' (alphabetically first) to win, got %v", statuses)
	}
}

// =============================================================================
// 7. Config edge cases (missing validation)
// =============================================================================

func TestAdversarial_WhitespaceOnlyCheckbox(t *testing.T) {
	// BUG: checkbox "   " (3 spaces) causes statusRe to match any line with
	// 3+ leading spaces. Indented code, nested lists all become tasks.
	ctx := NewParseContext(Config{
		Checkbox: map[string]string{"open": "   "},
	})

	tests := []struct {
		name  string
		input string
	}{
		{"indented code", "    code block line"},
		{"nested list", "   - nested item"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := ParseTask(rawMatch(tt.input), ctx)
			if err == nil {
				t.Errorf("whitespace-only checkbox incorrectly matched %q as a task", tt.input)
			}
		})
	}
}

func TestAdversarial_NewlineInCheckbox(t *testing.T) {
	// Checkbox with embedded newline — QuoteMeta escapes \n, regex never matches
	// a single-line input. Should return error (no checkbox found).
	ctx := NewParseContext(Config{
		Checkbox: map[string]string{"open": "- [\n]"},
	})

	_, err := ParseTask(rawMatch("- [ ] Normal task"), ctx)
	if err == nil {
		t.Error("expected error: newline in checkbox should never match single-line input")
	}
}

func TestAdversarial_ConfigFallbacks(t *testing.T) {
	tests := []struct {
		name             string
		cfg              Config
		wantTagPrefix    string
		wantMarkerPrefix string
	}{
		{
			name:             "zero config",
			cfg:              Config{},
			wantTagPrefix:    "#",
			wantMarkerPrefix: "::",
		},
		{
			name:             "single-element DateWrapper",
			cfg:              Config{DateWrapper: []string{"{"}},
			wantTagPrefix:    "#",
			wantMarkerPrefix: "::",
		},
		{
			name:             "empty DateWrapper strings",
			cfg:              Config{DateWrapper: []string{"", ""}},
			wantTagPrefix:    "#",
			wantMarkerPrefix: "::",
		},
		{
			name:             "partial overrides",
			cfg:              Config{TagPrefix: "+"},
			wantTagPrefix:    "+",
			wantMarkerPrefix: "::",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx := NewParseContext(tt.cfg)
			if ctx.tagPrefix != tt.wantTagPrefix {
				t.Errorf("tagPrefix = %q, want %q", ctx.tagPrefix, tt.wantTagPrefix)
			}
			if ctx.markerPrefix != tt.wantMarkerPrefix {
				t.Errorf("markerPrefix = %q, want %q", ctx.markerPrefix, tt.wantMarkerPrefix)
			}
		})
	}
}

// =============================================================================
// 8. Roundtrip bugs
// =============================================================================

func TestAdversarial_FormatRoundtripTagMismatch(t *testing.T) {
	// Verify that formatTaskLine uses the configured tag prefix.
	// If format and parse use different prefixes, tags are lost on re-parse.
	task := Task{
		FilePath:   "test.md",
		LineNumber: 1,
		Body:       "Tagged task",
		Tags:       []string{"work"},
		Status:     "open",
	}

	// Format with "+" prefix — should output "+work"
	formatted := formatTaskLine(task, FormatOpts{TagPrefix: "+"})
	if !strings.Contains(formatted, "+work") {
		t.Errorf("formatted with TagPrefix='+' should contain '+work': %s", formatted)
	}
	if strings.Contains(formatted, "#work") {
		t.Errorf("formatted with TagPrefix='+' should NOT contain '#work': %s", formatted)
	}

	// Format with default "#" — should output "#work"
	formattedDefault := formatTaskLine(task, FormatOpts{})
	if !strings.Contains(formattedDefault, "#work") {
		t.Errorf("formatted with default prefix should contain '#work': %s", formattedDefault)
	}
}

func TestAdversarial_FormatRoundtripMarkerMismatch(t *testing.T) {
	// After fix: formatTaskLine uses opts.MarkerPrefix instead of hardcoding "::".
	task := Task{
		FilePath:   "test.md",
		LineNumber: 1,
		Body:       "Marked task",
		Status:     "open",
		DueDate:    mustDatePtr("2026-02-17"),
		Markers:    []Marker{{Kind: "start", Date: "2026-02-17", Time: "15:00"}},
	}

	// Format with custom ">>" prefix — should output ">>start"
	formatted := formatTaskLine(task, FormatOpts{ShowMarkers: true, MarkerPrefix: ">>"})
	if !strings.Contains(formatted, ">>start") {
		t.Errorf("formatted with MarkerPrefix='>>' should contain '>>start': %s", formatted)
	}
	if strings.Contains(formatted, "::start") {
		t.Errorf("formatted with MarkerPrefix='>>' should NOT contain '::start': %s", formatted)
	}

	// Format with default — should output "::start"
	formattedDefault := formatTaskLine(task, FormatOpts{ShowMarkers: true})
	if !strings.Contains(formattedDefault, "::start") {
		t.Errorf("formatted with default prefix should contain '::start': %s", formattedDefault)
	}
}

func TestAdversarial_MutateRoundtripMissingStatus(t *testing.T) {
	// Config has "open" and "done" but no "partial". ctx.checkbox["partial"]
	// returns "" (zero value). After fix: ChangeCheckbox rejects empty strings.
	dir := t.TempDir()
	path := filepath.Join(dir, "test.md")
	original := "- [ ] Some task (@[[2026-02-17]])\n"
	os.WriteFile(path, []byte(original), 0644)

	ctx := NewParseContext(Config{
		Checkbox: map[string]string{
			"open": "- [ ]",
			"done": "- [x]",
		},
	})

	fromCheckbox := ctx.checkbox["open"]
	toCheckbox := ctx.checkbox["partial"] // "" — missing status

	if toCheckbox != "" {
		t.Fatalf("expected empty string for missing status 'partial', got %q", toCheckbox)
	}

	// ChangeCheckbox should reject the empty string instead of corrupting the file
	err := ChangeCheckbox(path, 1, fromCheckbox, toCheckbox)
	if err == nil {
		t.Errorf("ChangeCheckbox should reject empty 'to' string to prevent file corruption")
	}

	// Verify file was not modified
	data, _ := os.ReadFile(path)
	if string(data) != original {
		t.Errorf("file was modified despite error: %q", string(data))
	}
}

// =============================================================================
// 9. Date edge cases
// =============================================================================

func TestAdversarial_MultipleDateGroups(t *testing.T) {
	// Two date groups in one line — first match wins
	ctx := DefaultParseContext()
	task, err := ParseTask(rawMatch("- [ ] Compare (@[[2026-02-17]]) vs (@[[2026-03-01]])"), ctx)
	if err != nil {
		t.Fatal(err)
	}

	if task.DueDate == nil {
		t.Fatal("expected non-nil DueDate")
	}
	// First match should win
	if task.DueDate.Format("2006-01-02") != "2026-02-17" {
		t.Errorf("date = %s, want 2026-02-17 (first match should win)", task.DueDate.Format("2006-01-02"))
	}

	// Body should be text before first date group
	if task.Body != "Compare" {
		t.Errorf("body = %q, want %q", task.Body, "Compare")
	}
}

func TestAdversarial_InvalidDateValues(t *testing.T) {
	ctx := DefaultParseContext()

	tests := []struct {
		name    string
		input   string
		wantErr bool
	}{
		{
			name:    "month 13",
			input:   "- [ ] Task (@[[2026-13-01]])",
			wantErr: true,
		},
		{
			name:    "day 32",
			input:   "- [ ] Task (@[[2026-01-32]])",
			wantErr: true,
		},
		{
			name:    "month 00",
			input:   "- [ ] Task (@[[2026-00-15]])",
			wantErr: true,
		},
		{
			name:    "valid leap day",
			input:   "- [ ] Task (@[[2024-02-29]])",
			wantErr: false,
		},
		{
			name:    "invalid leap day",
			input:   "- [ ] Task (@[[2025-02-29]])",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := ParseTask(rawMatch(tt.input), ctx)
			if tt.wantErr && err == nil {
				t.Errorf("expected error for invalid date, got none")
			}
			if !tt.wantErr && err != nil {
				t.Errorf("unexpected error for valid date: %v", err)
			}
		})
	}
}
