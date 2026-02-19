package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const stateDir = ".local/state/task"
const stateFile = "current_task"

type CurrentTask struct {
	StartTime  int64  // unix timestamp
	Name       string // task body
	FilePath   string
	LineNumber int
}

func statePath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, stateDir, stateFile)
}

func ReadCurrentTask() (*CurrentTask, error) {
	data, err := os.ReadFile(statePath())
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
	dir := filepath.Dir(statePath())
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	line := fmt.Sprintf("%d\t%s\t%s\t%d\n", ct.StartTime, ct.Name, ct.FilePath, ct.LineNumber)
	return os.WriteFile(statePath(), []byte(line), 0644)
}

func ClearCurrentTask() error {
	err := os.Remove(statePath())
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

func FormatMarker(kind string, now time.Time) string {
	return fmt.Sprintf("::%-s [[%s]] %s ", kind, now.Format("2006-01-02"), now.Format("15:04"))
}
