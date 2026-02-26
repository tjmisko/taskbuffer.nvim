package main

import (
	"fmt"
	"log"
	"regexp"
	"strings"
	"time"
)

type Task struct {
	FilePath   string
	LineNumber int
	Body       string
	DueDate    *time.Time // nil means undated
	DueTime    string     // "" or "HH:MM"
	Duration   string     // "" or "30m", "90m", etc.
	Tags       []string
	Status     string // "open", "done", "irrelevant", "partial"
	Markers    []Marker
}

type Marker struct {
	Kind string // "start", "stop", "complete", "deferral", "original", "irrelevant", "partial"
	Date string // "YYYY-MM-DD"
	Time string // "HH:MM" or ""
}

// ParseContext holds compiled regexes built from Config for config-driven parsing.
type ParseContext struct {
	statusMap     map[string]string // checkbox_char -> status_name (e.g., " " -> "open")
	statusRe      *regexp.Regexp    // matches any configured checkbox at line start
	dateRe        *regexp.Regexp    // date group with configured wrappers
	tagRe         *regexp.Regexp    // tag with configured prefix
	markerRe      *regexp.Regexp    // markers with configured prefix
	markerStartRe *regexp.Regexp    // matches marker prefix + keyword + [[, for finding marker boundaries
	durationRe    *regexp.Regexp    // unchanged: <Nm>
	markerPrefix  string            // for splitting marker segments
	tagPrefix     string            // for output formatting
	scanPattern   string            // rg pattern for scanning
	checkbox      map[string]string // status_name -> checkbox string (for mutations)
}

// NewParseContext builds a ParseContext from a Config, falling back to defaults
// for zero-valued fields.
func NewParseContext(cfg Config) *ParseContext {
	ctx := &ParseContext{
		durationRe: regexp.MustCompile(`<(\d+)m>`),
	}

	// Checkbox config
	checkbox := cfg.Checkbox
	if len(checkbox) == 0 {
		checkbox = map[string]string{
			"open":       "- [ ]",
			"done":       "- [x]",
			"irrelevant": "- [-]",
			"partial":    "- [~]",
		}
	}

	// Validate: reject empty or whitespace-only checkbox strings
	for statusName, cb := range checkbox {
		if strings.TrimSpace(cb) == "" {
			delete(checkbox, statusName)
		}
	}

	ctx.checkbox = checkbox

	// Build statusMap with deterministic duplicate resolution: when multiple
	// status names map to the same checkbox string, the alphabetically first
	// status name wins.
	ctx.statusMap = make(map[string]string)
	for statusName, cb := range checkbox {
		if existing, ok := ctx.statusMap[cb]; ok {
			if statusName < existing {
				ctx.statusMap[cb] = statusName
			}
		} else {
			ctx.statusMap[cb] = statusName
		}
	}

	var escapedCheckboxes []string
	seen := make(map[string]bool)
	for _, cb := range checkbox {
		escaped := regexp.QuoteMeta(cb)
		if !seen[escaped] {
			seen[escaped] = true
			escapedCheckboxes = append(escapedCheckboxes, escaped)
		}
	}

	// Sort by length descending so longer patterns match before shorter prefixes.
	// This prevents "- " from shadowing "- [ ]" in regex alternation.
	sortByLengthDesc(escapedCheckboxes)

	// Build statusRe: match any configured checkbox at line start (with optional leading whitespace)
	statusPattern := `^\s*(` + strings.Join(escapedCheckboxes, "|") + `)`
	ctx.statusRe = regexp.MustCompile(statusPattern)

	// Build scan pattern for rg: match any checkbox
	var scanParts []string
	scanSeen := make(map[string]bool)
	for _, cb := range checkbox {
		escaped := regexp.QuoteMeta(cb)
		if !scanSeen[escaped] {
			scanSeen[escaped] = true
			scanParts = append(scanParts, escaped)
		}
	}
	sortByLengthDesc(scanParts)
	ctx.scanPattern = strings.Join(scanParts, "|")

	// Tag prefix
	ctx.tagPrefix = cfg.TagPrefix
	if ctx.tagPrefix == "" {
		ctx.tagPrefix = "#"
	}
	tagPrefixEscaped := regexp.QuoteMeta(ctx.tagPrefix)
	ctx.tagRe = regexp.MustCompile(tagPrefixEscaped + `([A-Za-z_][\w-]*)`)

	// Date wrapper
	dateOpen := `\(@\[\[`
	dateClose := `\]\]\s*(\d{2}:\d{2})?\)`
	if len(cfg.DateWrapper) == 2 && cfg.DateWrapper[0] != "" && cfg.DateWrapper[1] != "" {
		dateOpen = regexp.QuoteMeta(cfg.DateWrapper[0])
		dateClose = regexp.QuoteMeta(cfg.DateWrapper[1])
		// Insert the time capture group before the closing wrapper
		dateClose = `\s*(\d{2}:\d{2})?` + dateClose
	}
	ctx.dateRe = regexp.MustCompile(dateOpen + `(?:[^|\]]*\|)?(?:.*/)?(\d{4}-\d{2}-\d{2})` + dateClose)

	// Marker prefix
	ctx.markerPrefix = cfg.MarkerPrefix
	if ctx.markerPrefix == "" {
		ctx.markerPrefix = "::"
	}
	markerPrefixEscaped := regexp.QuoteMeta(ctx.markerPrefix)
	ctx.markerRe = regexp.MustCompile(`(\w+)\s+\[\[(?:[^|\]]*\|)?(?:.*/)?(\d{4}-\d{2}-\d{2})\]\]\s*(\d{2}:\d{2})?`)
	// markerStartRe matches the marker prefix followed by a keyword and [[ — used to find
	// where markers begin in a line (avoids false positives from prefix appearing in body text).
	ctx.markerStartRe = regexp.MustCompile(markerPrefixEscaped + `\s*\w+\s+\[\[`)

	return ctx
}

// sortStrings sorts a string slice in place alphabetically.
func sortStrings(ss []string) {
	for i := 1; i < len(ss); i++ {
		for j := i; j > 0 && ss[j] < ss[j-1]; j-- {
			ss[j], ss[j-1] = ss[j-1], ss[j]
		}
	}
}

// sortByLengthDesc sorts a string slice by length descending, breaking ties alphabetically.
// This ensures longer patterns appear first in regex alternation (longest-match semantics).
func sortByLengthDesc(ss []string) {
	for i := 1; i < len(ss); i++ {
		for j := i; j > 0 && (len(ss[j]) > len(ss[j-1]) || (len(ss[j]) == len(ss[j-1]) && ss[j] < ss[j-1])); j-- {
			ss[j], ss[j-1] = ss[j-1], ss[j]
		}
	}
}

// DefaultParseContext returns a ParseContext with default config values.
func DefaultParseContext() *ParseContext {
	return NewParseContext(Config{})
}

// Keep package-level vars for backward compat in tests that use dateRe directly (e.g., cmdDefer).
var (
	defaultDateRe = regexp.MustCompile(`\(@\[\[(?:[^|\]]*\|)?(?:.*/)?(\d{4}-\d{2}-\d{2})\]\]\s*(\d{2}:\d{2})?\)`)
)

func ParseTask(match RawMatch, ctx *ParseContext) (Task, error) {
	line := strings.TrimLeft(match.Text, " \t")
	line = strings.TrimRight(line, "\n\r")

	// 1. Extract status using config-driven regex
	statusMatch := ctx.statusRe.FindStringSubmatch(line)
	if statusMatch == nil {
		return Task{}, fmt.Errorf("no checkbox found in line: %s", line)
	}
	checkboxStr := statusMatch[1]
	status, ok := ctx.statusMap[checkboxStr]
	if !ok {
		return Task{}, fmt.Errorf("unknown checkbox: %s", checkboxStr)
	}

	// 2. Extract date group (optional)
	var dueDate *time.Time
	var dueTime string
	dateMatch := ctx.dateRe.FindStringSubmatch(line)
	dateGroupFull := ctx.dateRe.FindString(line)
	dateGroupIdx := -1
	if dateMatch != nil {
		dateStr := dateMatch[1]
		if dateStr == "" {
			return Task{}, fmt.Errorf("empty date in line: %s", line)
		}
		d, err := time.Parse("2006-01-02", dateStr)
		if err != nil {
			return Task{}, fmt.Errorf("unparseable date %q: %w", dateStr, err)
		}
		dueDate = &d
		dueTime = dateMatch[2]
		dateGroupIdx = strings.Index(line, dateGroupFull)
	}

	// 3. Extract duration
	var duration string
	durMatch := ctx.durationRe.FindStringSubmatch(line)
	if durMatch != nil {
		duration = durMatch[1] + "m"
	}

	// 4. Extract markers — split on marker prefix and parse each segment
	var markers []Marker
	afterDateGroup := ""
	if dateGroupIdx >= 0 {
		afterDateGroup = line[dateGroupIdx+len(dateGroupFull):]
	} else {
		// No date group: find first real marker (prefix + keyword + [[date]])
		// to avoid false positives from prefix appearing in body text.
		if loc := ctx.markerStartRe.FindStringIndex(line); loc != nil {
			afterDateGroup = line[loc[0]:]
		}
	}
	markerSegments := strings.Split(afterDateGroup, ctx.markerPrefix)
	for _, seg := range markerSegments {
		seg = strings.TrimSpace(seg)
		if seg == "" {
			continue
		}
		mm := ctx.markerRe.FindStringSubmatch(seg)
		if mm != nil {
			markers = append(markers, Marker{
				Kind: mm[1],
				Date: mm[2],
				Time: mm[3],
			})
		}
	}

	// 5. Extract tags from the body portion (before date group) and after
	allTags := ctx.tagRe.FindAllStringSubmatch(line, -1)
	var tags []string
	for _, t := range allTags {
		tags = append(tags, t[1])
	}

	// 6. Extract body
	checkboxEnd := strings.Index(line, statusMatch[1]) + len(statusMatch[1])
	var bodyPart string
	if dateGroupIdx >= 0 {
		bodyPart = line[checkboxEnd:dateGroupIdx]
	} else {
		// Undated: body is everything after checkbox, before first real marker
		bodyEnd := len(line)
		if loc := ctx.markerStartRe.FindStringIndex(line); loc != nil {
			bodyEnd = loc[0]
		}
		bodyPart = line[checkboxEnd:bodyEnd]
	}
	// Remove duration tag from body
	if durMatch != nil {
		bodyPart = strings.Replace(bodyPart, "<"+durMatch[1]+"m>", "", 1)
	}
	// Remove tags from body
	bodyPart = ctx.tagRe.ReplaceAllString(bodyPart, "")
	body := strings.TrimSpace(bodyPart)

	return Task{
		FilePath:   match.Path,
		LineNumber: match.LineNumber,
		Body:       body,
		DueDate:    dueDate,
		DueTime:    dueTime,
		Duration:   duration,
		Tags:       tags,
		Status:     status,
		Markers:    markers,
	}, nil
}

func ParseTasks(matches []RawMatch, ctx *ParseContext) []Task {
	var tasks []Task
	for _, m := range matches {
		t, err := ParseTask(m, ctx)
		if err != nil {
			if Verbose {
				log.Printf("warning: skipping line %s:%d: %v", m.Path, m.LineNumber, err)
			}
			continue
		}
		tasks = append(tasks, t)
	}
	return tasks
}
