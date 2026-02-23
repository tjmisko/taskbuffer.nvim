package main

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

func inHorizon(date time.Time, idx int, horizons []ResolvedHorizon) bool {
	if idx == len(horizons)-1 {
		return date.After(horizons[idx].Cutoff) || date.Equal(horizons[idx].Cutoff)
	}
	return (date.Equal(horizons[idx].Cutoff) || date.After(horizons[idx].Cutoff)) &&
		date.Before(horizons[idx+1].Cutoff)
}

// firstMatchHorizon finds the first horizon (in list order) where date >= cutoff.
// User controls priority by ordering horizons in their config.
func firstMatchHorizon(date time.Time, horizons []ResolvedHorizon) int {
	for i, h := range horizons {
		if h.Undated {
			continue
		}
		if date.Equal(h.Cutoff) || date.After(h.Cutoff) {
			return i
		}
	}
	// Fallback: last dated horizon
	for i := len(horizons) - 1; i >= 0; i-- {
		if !horizons[i].Undated {
			return i
		}
	}
	return 0
}

// narrowestHorizon finds the horizon with the tightest date range containing the date.
func narrowestHorizon(date time.Time, datedHorizons []ResolvedHorizon) int {
	bestIdx := -1
	bestSpan := time.Duration(1<<63 - 1) // max duration

	for i, h := range datedHorizons {
		if h.Undated {
			continue
		}
		inRange := false
		var span time.Duration
		if i == len(datedHorizons)-1 || datedHorizons[i+1].Undated {
			if date.Equal(h.Cutoff) || date.After(h.Cutoff) {
				inRange = true
				span = time.Duration(1<<62 - 1) // unbounded upper
			}
		} else {
			if (date.Equal(h.Cutoff) || date.After(h.Cutoff)) && date.Before(datedHorizons[i+1].Cutoff) {
				inRange = true
				span = datedHorizons[i+1].Cutoff.Sub(h.Cutoff)
			}
		}
		if inRange && span < bestSpan {
			bestSpan = span
			bestIdx = i
		}
	}

	if bestIdx == -1 {
		// Fallback: last dated horizon
		for i := len(datedHorizons) - 1; i >= 0; i-- {
			if !datedHorizons[i].Undated {
				return i
			}
		}
		return 0
	}
	return bestIdx
}

type FormatOpts struct {
	ShowMarkers   bool
	IgnoreUndated bool
	TagFilter     []string           // only show tasks matching these tags (OR logic)
	Horizons      []ResolvedHorizon  // resolved horizons; nil → defaults
	Overlap       string             // "sorted", "first_match", "narrowest"
}

func formatTaskLine(t Task, opts FormatOpts) string {
	var b strings.Builder

	// Location
	fmt.Fprintf(&b, "%s:%d:1:", t.FilePath, t.LineNumber)

	// Date
	if t.DueDate != nil {
		fmt.Fprintf(&b, "\t[[%s]]", t.DueDate.Format("2006-01-02"))
	} else {
		b.WriteString("\t          ")
	}

	// Time column — 7 chars between pipes
	if t.DueTime != "" {
		fmt.Fprintf(&b, " | %s |", t.DueTime)
	} else {
		b.WriteString("\t |       |")
	}

	// Duration column — 5 chars between pipes
	if t.Duration != "" {
		padding := 4 - len(t.Duration)
		if padding < 0 {
			padding = 0
		}
		fmt.Fprintf(&b, "%s%s |", strings.Repeat(" ", padding), t.Duration)
	} else {
		b.WriteString("     |")
	}

	// Body
	fmt.Fprintf(&b, "\t %s \t", t.Body)

	// Tags (before markers, after body tab)
	if len(t.Tags) > 0 {
		b.WriteString(" ")
		for i, tag := range t.Tags {
			if i > 0 {
				b.WriteString(" ")
			}
			b.WriteString("#")
			b.WriteString(tag)
		}
	}

	// Markers
	if opts.ShowMarkers {
		for _, m := range t.Markers {
			fmt.Fprintf(&b, " ::%s [[%s]]", m.Kind, m.Date)
			if m.Time != "" {
				fmt.Fprintf(&b, " %s", m.Time)
			}
		}
	}

	return b.String()
}

func taskMatchesTags(t Task, tags []string) bool {
	for _, filter := range tags {
		for _, tag := range t.Tags {
			if tag == filter {
				return true
			}
		}
	}
	return false
}

func FormatTaskfile(tasks []Task, now time.Time, opts FormatOpts) string {
	// Filter by tags if specified
	if len(opts.TagFilter) > 0 {
		var filtered []Task
		for _, t := range tasks {
			if taskMatchesTags(t, opts.TagFilter) {
				filtered = append(filtered, t)
			}
		}
		tasks = filtered
	}

	// Resolve horizons if not provided
	horizons := opts.Horizons
	if len(horizons) == 0 {
		horizons, _ = ResolveHorizons(nil, now, time.Monday, "sorted")
	}

	// Split horizons into dated and undated
	var datedHorizons []ResolvedHorizon
	var undatedHorizon *ResolvedHorizon
	for i := range horizons {
		if horizons[i].Undated {
			h := horizons[i]
			undatedHorizon = &h
		} else {
			datedHorizons = append(datedHorizons, horizons[i])
		}
	}

	// Separate dated and undated tasks
	var dated, undated []Task
	for _, t := range tasks {
		if t.DueDate != nil {
			dated = append(dated, t)
		} else {
			undated = append(undated, t)
		}
	}

	// Sort dated tasks by date, then file path, then line number
	sort.Slice(dated, func(i, j int) bool {
		if !dated[i].DueDate.Equal(*dated[j].DueDate) {
			return dated[i].DueDate.Before(*dated[j].DueDate)
		}
		if dated[i].FilePath != dated[j].FilePath {
			return dated[i].FilePath < dated[j].FilePath
		}
		return dated[i].LineNumber < dated[j].LineNumber
	})

	// Sort undated tasks by file path, then line number
	sort.Slice(undated, func(i, j int) bool {
		if undated[i].FilePath != undated[j].FilePath {
			return undated[i].FilePath < undated[j].FilePath
		}
		return undated[i].LineNumber < undated[j].LineNumber
	})

	overlap := opts.Overlap
	if overlap == "" {
		overlap = "sorted"
	}

	var b strings.Builder
	interval := 0
	lastInterval := -1

	for _, t := range dated {
		date := extractDate(*t.DueDate)

		switch overlap {
		case "first_match":
			interval = firstMatchHorizon(date, datedHorizons)
		case "narrowest":
			interval = narrowestHorizon(date, datedHorizons)
		default: // "sorted"
			for i := interval; i < len(datedHorizons); i++ {
				if inHorizon(date, i, datedHorizons) {
					interval = i
					break
				}
			}
		}

		if interval != lastInterval {
			if lastInterval != -1 {
				b.WriteString("\n")
			}
			b.WriteString(datedHorizons[interval].Label)
			b.WriteString("\n")
			lastInterval = interval
		}

		b.WriteString(formatTaskLine(t, opts))
		b.WriteString("\n")
	}

	// Append undated tasks
	undatedLabel := "# Someday"
	if undatedHorizon != nil {
		undatedLabel = undatedHorizon.Label
	}

	if len(undated) > 0 && !opts.IgnoreUndated {
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		b.WriteString(undatedLabel)
		b.WriteString("\n")
		for _, t := range undated {
			b.WriteString(formatTaskLine(t, opts))
			b.WriteString("\n")
		}
	}

	return b.String()
}
