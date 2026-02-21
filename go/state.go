package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const defaultStateDir = ".local/state/task"
const stateFile = "current_task"

type CurrentTask struct {
	StartTime  int64  // unix timestamp
	Name       string // task body
	FilePath   string
	LineNumber int
}

// resolveStateDir returns the state directory, using the provided override
// or falling back to ~/.local/state/task.
func resolveStateDir(override string) string {
	if override != "" {
		return expandHome(override)
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, defaultStateDir)
}

func statePathFor(stateDir string) string {
	return filepath.Join(resolveStateDir(stateDir), stateFile)
}

// Backward-compatible: uses default state dir
func statePath() string {
	return statePathFor("")
}

func ReadCurrentTask() (*CurrentTask, error) {
	return ReadCurrentTaskFrom("")
}

func ReadCurrentTaskFrom(stateDir string) (*CurrentTask, error) {
	data, err := os.ReadFile(statePathFor(stateDir))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	line := strings.TrimRight(string(data), "\n\r")
	parts := strings.SplitN(line, "\t", 4)
	if len(parts) < 4 {
		return nil, fmt.Errorf("malformed current_task: %q", line)
	}
	ts, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return nil, fmt.Errorf("bad timestamp: %w", err)
	}
	ln, err := strconv.Atoi(parts[3])
	if err != nil {
		return nil, fmt.Errorf("bad line number: %w", err)
	}
	return &CurrentTask{
		StartTime:  ts,
		Name:       parts[1],
		FilePath:   parts[2],
		LineNumber: ln,
	}, nil
}

func WriteCurrentTask(ct CurrentTask) error {
	return WriteCurrentTaskTo("", ct)
}

func WriteCurrentTaskTo(stateDir string, ct CurrentTask) error {
	dir := filepath.Dir(statePathFor(stateDir))
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	line := fmt.Sprintf("%d\t%s\t%s\t%d\n", ct.StartTime, ct.Name, ct.FilePath, ct.LineNumber)
	return os.WriteFile(statePathFor(stateDir), []byte(line), 0644)
}

func ClearCurrentTask() error {
	return ClearCurrentTaskFrom("")
}

func ClearCurrentTaskFrom(stateDir string) error {
	err := os.Remove(statePathFor(stateDir))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

func FormatMarker(kind string, now time.Time) string {
	return fmt.Sprintf("::%-s [[%s]] %s ", kind, now.Format("2006-01-02"), now.Format("15:04"))
}
