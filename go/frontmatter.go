package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"gopkg.in/yaml.v3"
)

// Frontmatter represents parsed YAML frontmatter from a markdown file.
// Raw holds the full map for configurable key access; Tags is always
// extracted from the "tags" key for convenience.
type Frontmatter struct {
	Raw  map[string]interface{}
	Tags []string
}

// GetString returns the string value for a key from the raw frontmatter map.
// Handles YAML v3's automatic time.Time parsing of date-like strings.
func (fm *Frontmatter) GetString(key string) string {
	if fm == nil || fm.Raw == nil {
		return ""
	}
	v, ok := fm.Raw[key]
	if !ok {
		return ""
	}
	switch val := v.(type) {
	case string:
		return val
	case int:
		return fmt.Sprintf("%d", val)
	case float64:
		return fmt.Sprintf("%g", val)
	case time.Time:
		// YAML v3 parses bare dates (e.g. "2026-04-01") as time.Time.
		// Format back to date string, including time if non-zero.
		if val.Hour() == 0 && val.Minute() == 0 && val.Second() == 0 {
			return val.Format("2006-01-02")
		}
		return val.Format("2006-01-02 15:04")
	default:
		return ""
	}
}

// GetStringSlice returns a []string for a key from the raw frontmatter map.
func (fm *Frontmatter) GetStringSlice(key string) []string {
	if fm == nil || fm.Raw == nil {
		return nil
	}
	v, ok := fm.Raw[key]
	if !ok {
		return nil
	}
	switch val := v.(type) {
	case []interface{}:
		result := make([]string, 0, len(val))
		for _, item := range val {
			if s, ok := item.(string); ok {
				result = append(result, s)
			}
		}
		return result
	default:
		return nil
	}
}

type frontmatterCache struct {
	mu    sync.Mutex
	cache map[string]*Frontmatter
}

var fmCache = frontmatterCache{cache: make(map[string]*Frontmatter)}

// ParseFrontmatter reads and caches the full YAML frontmatter from a markdown file.
func ParseFrontmatter(filePath string) (*Frontmatter, error) {
	fmCache.mu.Lock()
	if fm, ok := fmCache.cache[filePath]; ok {
		fmCache.mu.Unlock()
		return fm, nil
	}
	fmCache.mu.Unlock()

	fm, err := parseFrontmatterFromFile(filePath)
	if err != nil {
		return nil, err
	}

	fmCache.mu.Lock()
	fmCache.cache[filePath] = fm
	fmCache.mu.Unlock()

	return fm, nil
}

// ParseFrontmatterTags reads YAML frontmatter from a markdown file
// and returns the tags list. Delegates to ParseFrontmatter.
func ParseFrontmatterTags(filePath string) ([]string, error) {
	fm, err := ParseFrontmatter(filePath)
	if err != nil {
		return nil, err
	}
	if fm == nil {
		return nil, nil
	}
	return fm.Tags, nil
}

// ResetFrontmatterCache clears the cache (useful for testing).
func ResetFrontmatterCache() {
	fmCache.mu.Lock()
	fmCache.cache = make(map[string]*Frontmatter)
	fmCache.mu.Unlock()
}

func parseFrontmatterFromFile(filePath string) (*Frontmatter, error) {
	f, err := os.Open(filePath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)

	// First line must be ---
	if !scanner.Scan() || strings.TrimSpace(scanner.Text()) != "---" {
		return nil, nil // no frontmatter
	}

	// Collect lines until closing ---
	var lines []string
	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "---" {
			break
		}
		lines = append(lines, line)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(lines) == 0 {
		return nil, nil
	}

	// Parse YAML into raw map
	var raw map[string]interface{}
	if err := yaml.Unmarshal([]byte(strings.Join(lines, "\n")), &raw); err != nil {
		return nil, nil // malformed YAML, skip silently
	}

	fm := &Frontmatter{Raw: raw}

	// Extract tags from the "tags" key (always hardcoded)
	if tagsRaw, ok := raw["tags"]; ok {
		if tagSlice, ok := tagsRaw.([]interface{}); ok {
			for _, item := range tagSlice {
				if s, ok := item.(string); ok {
					fm.Tags = append(fm.Tags, s)
				}
			}
		}
	}

	return fm, nil
}

// MergeFrontmatterTags reads frontmatter tags for each task's file
// and appends them to the task's Tags slice (deduplicating).
func MergeFrontmatterTags(tasks []Task) {
	for i := range tasks {
		fmTags, err := ParseFrontmatterTags(tasks[i].FilePath)
		if err != nil || len(fmTags) == 0 {
			continue
		}
		existing := make(map[string]bool, len(tasks[i].Tags))
		for _, t := range tasks[i].Tags {
			existing[t] = true
		}
		for _, t := range fmTags {
			if !existing[t] {
				tasks[i].Tags = append(tasks[i].Tags, t)
				existing[t] = true
			}
		}
	}
}

// MergeFrontmatterDue inherits due dates from frontmatter for tasks that
// have no inline due date. Respects FrontmatterConfig settings.
func MergeFrontmatterDue(tasks []Task, fmCfg FrontmatterConfig, goDateFmt string, dateErrors *[]DateError) {
	if !fmCfg.InheritDueResolved() {
		return
	}

	for i := range tasks {
		if tasks[i].DueDate != nil {
			continue
		}

		fm, err := ParseFrontmatter(tasks[i].FilePath)
		if err != nil || fm == nil {
			continue
		}

		dueStr := fm.GetString(fmCfg.DueKeyResolved())
		if dueStr == "" {
			continue
		}

		// Check required tags
		reqTags := fmCfg.RequireTagsResolved()
		if len(reqTags) > 0 {
			fmTagSet := make(map[string]bool, len(fm.Tags))
			for _, t := range fm.Tags {
				fmTagSet[t] = true
			}
			allPresent := true
			for _, rt := range reqTags {
				if !fmTagSet[rt] {
					allPresent = false
					break
				}
			}
			if !allPresent {
				continue
			}
		}

		// Parse due date
		parts := strings.SplitN(dueStr, " ", 2)
		dueDate, err := time.Parse(goDateFmt, parts[0])
		if err != nil {
			collectDateError(dateErrors, DateError{
				FilePath: tasks[i].FilePath,
				DateStr:  parts[0],
				Context:  "frontmatter due",
				Err:      err,
			})
			continue
		}
		tasks[i].DueDate = &dueDate
		if len(parts) == 2 {
			tasks[i].DueTime = strings.TrimSpace(parts[1])
		}
	}
}

// FilterCompletedFrontmatterTasks removes tasks from files whose frontmatter
// indicates completion, but only tasks that have no inline due date (DueDate == nil).
// Run this BEFORE MergeFrontmatterDue so inherited-only tasks get filtered out.
func FilterCompletedFrontmatterTasks(tasks []Task, fmCfg FrontmatterConfig) []Task {
	dueKey := fmCfg.DueKeyResolved()
	statusKey := fmCfg.StatusKeyResolved()
	doneValues := fmCfg.DoneValuesResolved()

	if len(doneValues) == 0 {
		return tasks
	}

	doneSet := make(map[string]bool, len(doneValues))
	for _, v := range doneValues {
		doneSet[strings.ToLower(v)] = true
	}

	// Build set of completed file paths (files with due + done status)
	completedFiles := make(map[string]bool)
	// Cache lookups per file to avoid redundant parsing
	checkedFiles := make(map[string]bool)

	result := make([]Task, 0, len(tasks))
	for _, t := range tasks {
		if t.DueDate != nil {
			// Has inline date -- always keep
			result = append(result, t)
			continue
		}

		// Check if file is completed
		if _, checked := checkedFiles[t.FilePath]; !checked {
			checkedFiles[t.FilePath] = true
			fm, err := ParseFrontmatter(t.FilePath)
			if err == nil && fm != nil {
				fmDue := fm.GetString(dueKey)
				fmStatus := strings.ToLower(fm.GetString(statusKey))
				if fmDue != "" && doneSet[fmStatus] {
					completedFiles[t.FilePath] = true
				}
			}
		}

		if completedFiles[t.FilePath] {
			continue // exclude undated task from completed file
		}
		result = append(result, t)
	}
	return result
}
