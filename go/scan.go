package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type RawMatch struct {
	Path       string
	LineNumber int
	Text       string
}

const defaultScanPattern = `\- \[.\]`

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

// deduplicatePaths resolves symlinks, sorts by length, and removes paths
// whose prefix is already in the list (e.g., /a and /a/b → /a).
func deduplicatePaths(paths []string) []string {
	resolved := make([]string, 0, len(paths))
	for _, p := range paths {
		r, err := filepath.EvalSymlinks(p)
		if err != nil {
			r = p // keep original if symlink resolution fails
		}
		resolved = append(resolved, r)
	}

	sort.Slice(resolved, func(i, j int) bool {
		return len(resolved[i]) < len(resolved[j])
	})

	var kept []string
	for _, p := range resolved {
		nested := false
		for _, k := range kept {
			if strings.HasPrefix(p, k+"/") || p == k {
				nested = true
				break
			}
		}
		if !nested {
			kept = append(kept, p)
		}
	}
	return kept
}

// expandGlobs separates glob patterns from plain paths, expands globs,
// and returns a combined deduplicated list.
func expandGlobs(paths []string) []string {
	var result []string
	for _, p := range paths {
		if strings.ContainsAny(p, "*?") {
			matches, err := filepath.Glob(p)
			if err == nil {
				result = append(result, matches...)
			}
		} else {
			result = append(result, p)
		}
	}
	return deduplicatePaths(result)
}

// Scan searches one or more directories for task lines using ripgrep.
// If ctx is non-nil, its scanPattern is used; otherwise the default pattern is used.
func Scan(ctx *ParseContext, notesPaths ...string) ([]RawMatch, error) {
	paths := expandGlobs(notesPaths)
	if len(paths) == 0 {
		return nil, nil
	}

	pattern := defaultScanPattern
	if ctx != nil && ctx.scanPattern != "" {
		pattern = ctx.scanPattern
	}

	args := []string{"--json", "-e", pattern}
	args = append(args, paths...)
	cmd := exec.Command("rg", args...)

	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("creating stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		if errors.Is(err, exec.ErrNotFound) {
			return nil, fmt.Errorf("rg (ripgrep) not found on PATH")
		}
		return nil, fmt.Errorf("starting rg: %w", err)
	}

	var matches []RawMatch
	scanner := bufio.NewScanner(stdout)
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

	if err := cmd.Wait(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			code := exitErr.ExitCode()
			if code == 1 {
				return nil, nil // no matches
			}
			if code == 2 && stderrBuf.Len() == 0 {
				return nil, nil // no searchable files (e.g. empty directory)
			}
		}
		return nil, fmt.Errorf("rg exited with error: %w", err)
	}

	return matches, nil
}

// ScanProjects finds markdown files with "project" in frontmatter tags and a due date,
// returning them as Task entries.
func ScanProjects(notesPaths ...string) ([]Task, error) {
	paths := expandGlobs(notesPaths)
	if len(paths) == 0 {
		return nil, nil
	}

	args := []string{"-l", "-e", "- project", "--glob", "*.md"}
	args = append(args, paths...)
	cmd := exec.Command("rg", args...)
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

		s := strings.ToLower(fm.Status)
		if s == "completed" || s == "done" {
			continue
		}

		var dueDate time.Time
		var dueTime string
		parts := strings.SplitN(fm.Due, " ", 2)
		dueDate, err = time.Parse("2006-01-02", parts[0])
		if err != nil {
			continue
		}
		if len(parts) == 2 {
			dueTime = strings.TrimSpace(parts[1])
		}

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
