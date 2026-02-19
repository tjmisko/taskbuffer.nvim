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
	Status     string // "open", "done", "irrelevant"
	Markers    []Marker
}

type Marker struct {
	Kind string // "start", "stop", "complete", "deferral", "original", "irrelevant", "partial"
	Date string // "YYYY-MM-DD"
	Time string // "HH:MM" or ""
}

var (
	statusRe   = regexp.MustCompile(`^\s*- \[([ x\-])\]`)
	dateRe     = regexp.MustCompile(`\(@\[\[(?:[^|\]]*\|)?(?:.*/)?(\d{4}-\d{2}-\d{2})\]\]\s*(\d{2}:\d{2})?\)`)
	durationRe = regexp.MustCompile(`<(\d+)m>`)
	tagRe      = regexp.MustCompile(`#([A-Za-z_][\w-]*)`)
	markerRe   = regexp.MustCompile(`(\w+)\s+\[\[(?:[^|\]]*\|)?(?:.*/)?(\d{4}-\d{2}-\d{2})\]\]\s*(\d{2}:\d{2})?`)
)

func ParseTask(match RawMatch) (Task, error) {
	line := strings.TrimLeft(match.Text, " \t")
	line = strings.TrimRight(line, "\n\r")

	// 1. Extract status
	statusMatch := statusRe.FindStringSubmatch(line)
	if statusMatch == nil {
		return Task{}, fmt.Errorf("no checkbox found in line: %s", line)
	}
	var status string
	switch statusMatch[1] {
	case " ":
		status = "open"
	case "x":
		status = "done"
	case "-":
		status = "irrelevant"
	default:
		return Task{}, fmt.Errorf("unknown checkbox status: %s", statusMatch[1])
	}

	// 2. Extract date group (optional)
	var dueDate *time.Time
	var dueTime string
	dateMatch := dateRe.FindStringSubmatch(line)
	dateGroupFull := dateRe.FindString(line)
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
	durMatch := durationRe.FindStringSubmatch(line)
	if durMatch != nil {
		duration = durMatch[1] + "m"
	}

	// 4. Extract markers — split on :: and parse each segment
	var markers []Marker
	afterDateGroup := ""
	if dateGroupIdx >= 0 {
		afterDateGroup = line[dateGroupIdx+len(dateGroupFull):]
	} else {
		// No date group: markers start after first ::
		if idx := strings.Index(line, "::"); idx >= 0 {
			afterDateGroup = line[idx:]
		}
	}
	markerSegments := strings.Split(afterDateGroup, "::")
	for _, seg := range markerSegments {
		seg = strings.TrimSpace(seg)
		if seg == "" {
			continue
		}
		mm := markerRe.FindStringSubmatch(seg)
		if mm != nil {
			markers = append(markers, Marker{
				Kind: mm[1],
				Date: mm[2],
				Time: mm[3],
			})
		}
	}

	// 5. Extract tags from the body portion (before date group) and after
	allTags := tagRe.FindAllStringSubmatch(line, -1)
	var tags []string
	for _, t := range allTags {
		tags = append(tags, t[1])
	}

	// 6. Extract body
	checkboxEnd := strings.Index(line, statusMatch[0]) + len(statusMatch[0])
	var bodyPart string
	if dateGroupIdx >= 0 {
		bodyPart = line[checkboxEnd:dateGroupIdx]
	} else {
		// Undated: body is everything after checkbox, before markers
		bodyEnd := len(line)
		if idx := strings.Index(line, "::"); idx >= 0 {
			bodyEnd = idx
		}
		bodyPart = line[checkboxEnd:bodyEnd]
	}
	// Remove duration tag from body
	if durMatch != nil {
		bodyPart = strings.Replace(bodyPart, "<"+durMatch[1]+"m>", "", 1)
	}
	// Remove tags from body
	bodyPart = tagRe.ReplaceAllString(bodyPart, "")
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

func ParseTasks(matches []RawMatch) []Task {
	var tasks []Task
	for _, m := range matches {
		t, err := ParseTask(m)
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
