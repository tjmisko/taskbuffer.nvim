package main

import (
	"bufio"
	"os"
	"strings"
	"sync"

	"gopkg.in/yaml.v3"
)

// Frontmatter represents parsed YAML frontmatter from a markdown file.
type Frontmatter struct {
	Tags   []string `yaml:"tags"`
	Due    string   `yaml:"due"`    // "YYYY-MM-DD" or "YYYY-MM-DD HH:MM"
	Status string   `yaml:"status"` // e.g. "active", "completed", "done"
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

	// Parse YAML
	var fm Frontmatter
	if err := yaml.Unmarshal([]byte(strings.Join(lines, "\n")), &fm); err != nil {
		return nil, nil // malformed YAML, skip silently
	}

	return &fm, nil
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
