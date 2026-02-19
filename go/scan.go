package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type RawMatch struct {
	Path       string
	LineNumber int
	Text       string
}

const scanPattern = `\- \[.\]`

type rgMessage struct {
	Type string `json:"type"`
	Data struct {
		Path struct {
			Text string `json:"text"`
		} `json:"path"`
		Lines struct {
			Text string `json:"text"`
		} `json:"lines"`
		LineNumber int `json:"line_number"`
	} `json:"data"`
}

func Scan(notesPath string) ([]RawMatch, error) {
	cmd := exec.Command("rg", "--json", "-e", scanPattern, notesPath)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("creating stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		// rg binary not found
		if errors.Is(err, exec.ErrNotFound) {
			return nil, fmt.Errorf("rg (ripgrep) not found on PATH")
		}
		return nil, fmt.Errorf("starting rg: %w", err)
	}

	var matches []RawMatch
	scanner := bufio.NewScanner(stdout)
	// Increase buffer for very long lines (e.g., tasks with many deferrals)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for scanner.Scan() {
		var msg rgMessage
		if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
			continue
		}
		if msg.Type != "match" {
			continue
		}
		matches = append(matches, RawMatch{
			Path:       msg.Data.Path.Text,
			LineNumber: msg.Data.LineNumber,
			Text:       msg.Data.Lines.Text,
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("reading rg output: %w", err)
	}

	// rg exit 1 = no matches, exit 2 = error
	if err := cmd.Wait(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 {
			return nil, nil // no matches
		}
		// exit code 2 or other = real error
		return nil, fmt.Errorf("rg exited with error: %w", err)
	}

	return matches, nil
}

// ScanProjects finds markdown files with "project" in frontmatter tags and a due date,
// returning them as Task entries.
func ScanProjects(notesPath string) ([]Task, error) {
	// Use rg to quickly find candidate files containing "- project"
	cmd := exec.Command("rg", "-l", "-e", "- project", "--glob", "*.md", notesPath)
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 {
			return nil, nil // no matches
		}
		return nil, fmt.Errorf("rg project scan: %w", err)
	}

	var tasks []Task
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		filePath := strings.TrimSpace(line)
		if filePath == "" {
			continue
		}

		fm, err := ParseFrontmatter(filePath)
		if err != nil || fm == nil {
			continue
		}

		// Must have "project" tag and a due date
		hasProject := false
		for _, tag := range fm.Tags {
			if tag == "project" {
				hasProject = true
				break
			}
		}
		if !hasProject || fm.Due == "" {
			continue
		}

		// Skip completed projects
		s := strings.ToLower(fm.Status)
		if s == "completed" || s == "done" {
			continue
		}

		// Parse due date: "YYYY-MM-DD" or "YYYY-MM-DD HH:MM"
		var dueDate time.Time
		var dueTime string
		parts := strings.SplitN(fm.Due, " ", 2)
		dueDate, err = time.Parse("2006-01-02", parts[0])
		if err != nil {
			continue // unparseable date, skip
		}
		if len(parts) == 2 {
			dueTime = strings.TrimSpace(parts[1])
		}

		// Body = filename without extension
		body := strings.TrimSuffix(filepath.Base(filePath), ".md")

		tasks = append(tasks, Task{
			FilePath:   filePath,
			LineNumber: 1,
			Body:       body,
			DueDate:    &dueDate,
			DueTime:    dueTime,
			Tags:       fm.Tags,
			Status:     "open",
		})
	}

	return tasks, nil
}
