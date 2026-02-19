package main

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

type dateBucket struct {
	Label  string
	Cutoff time.Time
}

func buildBuckets(now time.Time) []dateBucket {
	today := extractDate(now)
	return []dateBucket{
		{Label: "# Overdue", Cutoff: today.Add(-100 * 365 * 24 * time.Hour)},
		{Label: "# Today", Cutoff: today},
		{Label: "# Tomorrow", Cutoff: today.Add(24 * time.Hour)},
		{Label: "# This Week", Cutoff: today.Add(2 * 24 * time.Hour)},
		{Label: "# This Month", Cutoff: today.Add(8 * 24 * time.Hour)},
		{Label: "# This Year", Cutoff: today.Add(31 * 24 * time.Hour)},
		{Label: "# Far Off", Cutoff: today.Add(366 * 24 * time.Hour)},
	}
}

func inBucket(date time.Time, idx int, buckets []dateBucket) bool {
	if idx == len(buckets)-1 {
		return date.After(buckets[idx].Cutoff)
	}
	return (date.Equal(buckets[idx].Cutoff) || date.After(buckets[idx].Cutoff)) &&
		date.Before(buckets[idx+1].Cutoff)
}

type FormatOpts struct {
	ShowMarkers bool
	TagFilter   []string // only show tasks matching these tags (OR logic)
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

	buckets := buildBuckets(now)
	var b strings.Builder
	interval := 0
	lastInterval := -1

	for _, t := range dated {
		date := extractDate(*t.DueDate)

		for i := interval; i < len(buckets); i++ {
			if inBucket(date, i, buckets) {
				interval = i
				break
			}
		}

		if interval != lastInterval {
			if lastInterval != -1 {
				b.WriteString("\n")
			}
			b.WriteString(buckets[interval].Label)
			b.WriteString("\n")
			lastInterval = interval
		}

		b.WriteString(formatTaskLine(t, opts))
		b.WriteString("\n")
	}

	// Append undated tasks under # Someday
	if len(undated) > 0 {
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		b.WriteString("# Someday\n")
		for _, t := range undated {
			b.WriteString(formatTaskLine(t, opts))
			b.WriteString("\n")
		}
	}

	return b.String()
}
