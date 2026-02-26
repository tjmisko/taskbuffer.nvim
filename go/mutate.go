package main

import (
	"fmt"
	"os"
	"regexp"
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

// CheckOffTask changes `- [ ]` to `- [x]` on a specific line (uses default checkboxes).
func CheckOffTask(filePath string, lineNumber int) error {
	return ChangeCheckbox(filePath, lineNumber, "- [ ]", "- [x]")
}

// CheckOffTaskWith changes the checkbox from `from` to `to` on a specific line.
func CheckOffTaskWith(filePath string, lineNumber int, from, to string) error {
	return ChangeCheckbox(filePath, lineNumber, from, to)
}

// ChangeCheckbox replaces one checkbox state with another on a specific line.
func ChangeCheckbox(filePath string, lineNumber int, from, to string) error {
	if from == "" {
		return fmt.Errorf("ChangeCheckbox: empty 'from' checkbox string")
	}
	if to == "" {
		return fmt.Errorf("ChangeCheckbox: empty 'to' checkbox string")
	}
	data, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("reading %s: %w", filePath, err)
	}
	lines := strings.Split(string(data), "\n")
	idx := lineNumber - 1
	if idx < 0 || idx >= len(lines) {
		return fmt.Errorf("line %d out of range (file has %d lines)", lineNumber, len(lines))
	}
	lines[idx] = strings.Replace(lines[idx], from, to, 1)
	return os.WriteFile(filePath, []byte(strings.Join(lines, "\n")), 0644)
}

// RemoveLastMarker removes the last occurrence of a ::kind marker from a line.
func RemoveLastMarker(filePath string, lineNumber int, kind string) error {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("reading %s: %w", filePath, err)
	}
	lines := strings.Split(string(data), "\n")
	idx := lineNumber - 1
	if idx < 0 || idx >= len(lines) {
		return fmt.Errorf("line %d out of range (file has %d lines)", lineNumber, len(lines))
	}

	// Match ::kind [[DATE]] TIME (time is optional)
	pattern := fmt.Sprintf(`\s*::%s\s+\[\[\d{4}-\d{2}-\d{2}\]\]\s*(\d{2}:\d{2})?`, regexp.QuoteMeta(kind))
	re := regexp.MustCompile(pattern)

	line := lines[idx]
	locs := re.FindAllStringIndex(line, -1)
	if len(locs) == 0 {
		return nil // no marker to remove
	}
	// Remove the last match
	last := locs[len(locs)-1]
	lines[idx] = line[:last[0]] + line[last[1]:]
	lines[idx] = strings.TrimRight(lines[idx], " \t")

	return os.WriteFile(filePath, []byte(strings.Join(lines, "\n")), 0644)
}

// InsertAfterHeader finds a markdown header line and inserts text on the next line.
// If the header is not found, the text is appended to the end of the file.
func InsertAfterHeader(filePath, header, text string) error {
	data, err := os.ReadFile(filePath)
	if err != nil {
		if os.IsNotExist(err) {
			return os.WriteFile(filePath, []byte(header+"\n"+text+"\n"), 0644)
		}
		return fmt.Errorf("reading %s: %w", filePath, err)
	}

	lines := strings.Split(string(data), "\n")
	headerIdx := -1
	for i, line := range lines {
		if strings.TrimSpace(line) == strings.TrimSpace(header) {
			headerIdx = i
			break
		}
	}

	if headerIdx == -1 {
		// Header not found, append header + text
		content := string(data)
		if !strings.HasSuffix(content, "\n") {
			content += "\n"
		}
		content += "\n" + header + "\n" + text + "\n"
		return os.WriteFile(filePath, []byte(content), 0644)
	}

	// Insert after header (and after any existing tasks below the header)
	insertIdx := headerIdx + 1
	result := make([]string, 0, len(lines)+1)
	result = append(result, lines[:insertIdx]...)
	result = append(result, text)
	result = append(result, lines[insertIdx:]...)

	return os.WriteFile(filePath, []byte(strings.Join(result, "\n")), 0644)
}

// AppendToFile appends a line of text to the end of a file, creating it if needed.
func AppendToFile(filePath, text string) error {
	data, err := os.ReadFile(filePath)
	if err != nil {
		if os.IsNotExist(err) {
			return os.WriteFile(filePath, []byte(text+"\n"), 0644)
		}
		return fmt.Errorf("reading %s: %w", filePath, err)
	}

	content := string(data)
	if !strings.HasSuffix(content, "\n") {
		content += "\n"
	}
	content += text + "\n"
	return os.WriteFile(filePath, []byte(content), 0644)
}
