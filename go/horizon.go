package main

import (
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// HorizonSpec is the user-facing config for a single time horizon.
type HorizonSpec struct {
	Label   string      `json:"label"`
	After   interface{} `json:"after,omitempty"` // float64 (JSON int), string, or nil
	Undated bool        `json:"undated,omitempty"`
	Order   *int        `json:"order,omitempty"`
}

// ResolvedHorizon is a horizon with its cutoff date computed.
type ResolvedHorizon struct {
	Label   string
	Cutoff  time.Time
	Undated bool
	Order   int
}

// defaultHorizonSpecs returns the built-in horizon configuration matching the
// original hardcoded buildBuckets behavior.
func defaultHorizonSpecs() []HorizonSpec {
	return []HorizonSpec{
		{Label: "# Overdue", After: "past"},
		{Label: "# Today", After: float64(0)},
		{Label: "# Tomorrow", After: float64(1)},
		{Label: "# This Week", After: float64(2)},
		{Label: "# This Month", After: float64(8)},
		{Label: "# This Year", After: "31d"},
		{Label: "# Far Off", After: "366d"},
		{Label: "# Someday", Undated: true},
	}
}

var horizonDurationRe = regexp.MustCompile(`^(-?\d+)([dwmy])$`)

// parseDuration parses a duration string like "2d", "1w", "1m", "1y" into a
// day count. Units: d=1, w=7, m=30, y=365.
func parseDuration(s string) (int, error) {
	m := horizonDurationRe.FindStringSubmatch(s)
	if m == nil {
		return 0, fmt.Errorf("invalid duration string: %q", s)
	}
	n, _ := strconv.Atoi(m[1])
	switch m[2] {
	case "d":
		return n, nil
	case "w":
		return n * 7, nil
	case "m":
		return n * 30, nil
	case "y":
		return n * 365, nil
	}
	return 0, fmt.Errorf("unknown duration unit: %s", m[2])
}

// resolveCalendarKeyword resolves a calendar keyword to a cutoff time.
// Cutoffs are start-of-next-period (exclusive upper boundary).
func resolveCalendarKeyword(kw string, today time.Time, weekStart time.Weekday) (time.Time, error) {
	switch kw {
	case "past":
		return today.AddDate(-100, 0, 0), nil
	case "yesterday":
		return today.AddDate(0, 0, -1), nil
	case "end_of_week":
		// Find the day after the last day of the current week.
		// If weekStart is Monday, the week ends on Sunday.
		// We want start of the day after the last day.
		weekEnd := weekStart - 1
		if weekEnd < 0 {
			weekEnd = time.Saturday
		}
		daysUntilEnd := int(weekEnd-today.Weekday()+7) % 7
		if daysUntilEnd == 0 {
			daysUntilEnd = 7
		}
		return today.AddDate(0, 0, daysUntilEnd+1), nil
	case "end_of_month":
		y, m, _ := today.Date()
		return time.Date(y, m+1, 1, 0, 0, 0, 0, today.Location()), nil
	case "end_of_quarter":
		y, m, _ := today.Date()
		qMonth := ((m-1)/3)*3 + 4 // first month of next quarter
		return time.Date(y, qMonth, 1, 0, 0, 0, 0, today.Location()), nil
	case "end_of_year":
		return time.Date(today.Year()+1, 1, 1, 0, 0, 0, 0, today.Location()), nil
	default:
		return time.Time{}, fmt.Errorf("unknown calendar keyword: %q", kw)
	}
}

// parseWeekday parses a weekday name to time.Weekday. Defaults to Monday.
func parseWeekday(s string) time.Weekday {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "sunday":
		return time.Sunday
	case "monday":
		return time.Monday
	case "tuesday":
		return time.Tuesday
	case "wednesday":
		return time.Wednesday
	case "thursday":
		return time.Thursday
	case "friday":
		return time.Friday
	case "saturday":
		return time.Saturday
	default:
		return time.Monday
	}
}

// parseAfterValue resolves the polymorphic "after" field to a cutoff time.
// Accepts float64 (day offset), string (duration or calendar keyword), or nil.
func parseAfterValue(val interface{}, now time.Time, weekStart time.Weekday) (time.Time, error) {
	today := extractDate(now)
	switch v := val.(type) {
	case float64:
		days := int(v)
		return today.AddDate(0, 0, days), nil
	case int:
		return today.AddDate(0, 0, v), nil
	case string:
		// Try duration string first
		if days, err := parseDuration(v); err == nil {
			return today.AddDate(0, 0, days), nil
		}
		// Try calendar keyword
		return resolveCalendarKeyword(v, today, weekStart)
	case nil:
		return time.Time{}, fmt.Errorf("after value is nil")
	default:
		return time.Time{}, fmt.Errorf("unsupported after type: %T", val)
	}
}

// ResolveHorizons resolves a list of HorizonSpecs into ResolvedHorizons.
// If specs is nil or empty, defaults are used. Invalid specs produce a warning
// on stderr and fall back to defaults.
func ResolveHorizons(specs []HorizonSpec, now time.Time, weekStart time.Weekday, overlap string) ([]ResolvedHorizon, error) {
	if len(specs) == 0 {
		specs = defaultHorizonSpecs()
	}

	var dated []ResolvedHorizon
	var undated []ResolvedHorizon
	var parseErrors []string

	for i, s := range specs {
		if s.Undated {
			order := len(specs) + i // undated sorts after dated by default
			if s.Order != nil {
				order = *s.Order
			}
			undated = append(undated, ResolvedHorizon{
				Label:   s.Label,
				Undated: true,
				Order:   order,
			})
			continue
		}

		cutoff, err := parseAfterValue(s.After, now, weekStart)
		if err != nil {
			parseErrors = append(parseErrors, fmt.Sprintf("horizon %q: %v", s.Label, err))
			continue
		}

		order := i
		if s.Order != nil {
			order = *s.Order
		}
		dated = append(dated, ResolvedHorizon{
			Label:  s.Label,
			Cutoff: cutoff,
			Order:  order,
		})
	}

	// If we had parse errors and ended up with no valid dated horizons,
	// fall back to defaults entirely.
	if len(parseErrors) > 0 {
		for _, e := range parseErrors {
			fmt.Fprintf(os.Stderr, "taskbuffer: warning: %s\n", e)
		}
		if len(dated) == 0 {
			return ResolveHorizons(defaultHorizonSpecs(), now, weekStart, overlap)
		}
	}

	// For "sorted" overlap, sort by cutoff ascending
	if overlap == "" || overlap == "sorted" {
		sort.Slice(dated, func(i, j int) bool {
			return dated[i].Cutoff.Before(dated[j].Cutoff)
		})
		// Reassign order based on sorted position
		for i := range dated {
			dated[i].Order = i
		}
	}

	// Combine dated + undated
	result := append(dated, undated...)
	return result, nil
}
