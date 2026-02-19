package main

import (
	"fmt"
	"os"
	"strings"
)

// AppendToLine appends text to the end of a specific line in a file.
func AppendToLine(filePath string, lineNumber int, text string) error {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("reading %s: %w", filePath, err)
	}
	lines := strings.Split(string(data), "\n")
	idx := lineNumber - 1
	if idx < 0 || idx >= len(lines) {
		return fmt.Errorf("line %d out of range (file has %d lines)", lineNumber, len(lines))
	}
	lines[idx] = strings.TrimRight(lines[idx], " \t") + " " + text
	return os.WriteFile(filePath, []byte(strings.Join(lines, "\n")), 0644)
}

// CheckOffTask changes `- [ ]` to `- [x]` on a specific line.
func CheckOffTask(filePath string, lineNumber int) error {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("reading %s: %w", filePath, err)
	}
	lines := strings.Split(string(data), "\n")
	idx := lineNumber - 1
	if idx < 0 || idx >= len(lines) {
		return fmt.Errorf("line %d out of range (file has %d lines)", lineNumber, len(lines))
	}
	lines[idx] = strings.Replace(lines[idx], "- [ ]", "- [x]", 1)
	return os.WriteFile(filePath, []byte(strings.Join(lines, "\n")), 0644)
}
