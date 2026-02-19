package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"
)

// tagList implements flag.Value for repeatable --tag flags.
type tagList []string

func (t *tagList) String() string { return strings.Join(*t, ",") }
func (t *tagList) Set(val string) error {
	*t = append(*t, val)
	return nil
}

// Verbose controls whether parse warnings are printed to stderr.
var Verbose bool

const defaultNotesPath = "~/Documents/Notes"

func extractDate(timeIn time.Time) time.Time {
	year, month, day := timeIn.Date()
	return time.Date(year, month, day, 0, 0, 0, 0, time.Local)
}

func expandHome(path string) string {
	if len(path) >= 2 && path[:2] == "~/" {
		home, err := os.UserHomeDir()
		if err != nil {
			return path
		}
		return home + path[1:]
	}
	return path
}

func cmdList(notesPath string, args []string) error {
	var tags tagList
	var showMarkers bool

	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	fs.Var(&tags, "tag", "filter by tag (repeatable, OR logic)")
	fs.BoolVar(&showMarkers, "markers", false, "show :: markers")
	if err := fs.Parse(args); err != nil {
		return err
	}

	matches, err := Scan(notesPath)
	if err != nil {
		return fmt.Errorf("scan: %w", err)
	}

	allTasks := ParseTasks(matches)
	MergeFrontmatterTags(allTasks)

	projectTasks, err := ScanProjects(notesPath)
	if err != nil {
		return fmt.Errorf("scan projects: %w", err)
	}
	allTasks = append(allTasks, projectTasks...)

	var tasks []Task
	for _, t := range allTasks {
		if t.Status == "open" {
			tasks = append(tasks, t)
		}
	}

	now := time.Now().In(time.Local)
	opts := FormatOpts{
		ShowMarkers: showMarkers,
		TagFilter:   tags,
	}
	fmt.Print(FormatTaskfile(tasks, now, opts))
	return nil
}

func cmdDo(notesPath string) error {
	now := time.Now().In(time.Local)
	today := now.Format("2006-01-02")

	// If a task is already running, stop it first
	existing, err := ReadCurrentTask()
	if err != nil {
		return err
	}
	if existing != nil {
		if err := cmdStop(); err != nil {
			return fmt.Errorf("stopping current task: %w", err)
		}
	}

	// Scan for today's open tasks
	matches, err := Scan(notesPath)
	if err != nil {
		return fmt.Errorf("scan: %w", err)
	}
	allTasks := ParseTasks(matches)
	var todayTasks []Task
	for _, t := range allTasks {
		if t.Status == "open" && t.DueDate != nil && t.DueDate.Format("2006-01-02") == today {
			todayTasks = append(todayTasks, t)
		}
	}
	if len(todayTasks) == 0 {
		fmt.Println("No tasks due today.")
		return nil
	}

	// Build fzf input: index\tbody
	var fzfInput strings.Builder
	for i, t := range todayTasks {
		fmt.Fprintf(&fzfInput, "%d\t%s\n", i, t.Body)
	}

	// Run fzf for selection
	cmd := exec.Command("fzf", "--with-nth=2..", "--delimiter=\t")
	cmd.Stdin = strings.NewReader(fzfInput.String())
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		// fzf returns exit 130 on Ctrl-C / no selection
		fmt.Println("No task selected.")
		return nil
	}

	// Parse selection
	selection := strings.TrimRight(string(out), "\n\r")
	parts := strings.SplitN(selection, "\t", 2)
	var idx int
	fmt.Sscanf(parts[0], "%d", &idx)
	if idx < 0 || idx >= len(todayTasks) {
		return fmt.Errorf("invalid selection index: %d", idx)
	}
	task := todayTasks[idx]

	// Write ::start marker to source file
	marker := FormatMarker("start", now)
	if err := AppendToLine(task.FilePath, task.LineNumber, marker); err != nil {
		return fmt.Errorf("writing start marker: %w", err)
	}

	// Save current task state
	ct := CurrentTask{
		StartTime:  now.Unix(),
		Name:       task.Body,
		FilePath:   task.FilePath,
		LineNumber: task.LineNumber,
	}
	if err := WriteCurrentTask(ct); err != nil {
		return fmt.Errorf("saving state: %w", err)
	}

	fmt.Printf("Started: %s\n", task.Body)
	return nil
}

func cmdStop() error {
	now := time.Now().In(time.Local)

	ct, err := ReadCurrentTask()
	if err != nil {
		return err
	}
	if ct == nil {
		fmt.Println("No task running.")
		return nil
	}

	marker := FormatMarker("stop", now)
	if err := AppendToLine(ct.FilePath, ct.LineNumber, marker); err != nil {
		return fmt.Errorf("writing stop marker: %w", err)
	}

	if err := ClearCurrentTask(); err != nil {
		return err
	}

	fmt.Printf("Stopped: %s\n", ct.Name)
	return nil
}

func cmdComplete() error {
	now := time.Now().In(time.Local)

	ct, err := ReadCurrentTask()
	if err != nil {
		return err
	}
	if ct == nil {
		fmt.Println("No task running.")
		return nil
	}

	marker := FormatMarker("complete", now)
	if err := AppendToLine(ct.FilePath, ct.LineNumber, marker); err != nil {
		return fmt.Errorf("writing complete marker: %w", err)
	}
	if err := CheckOffTask(ct.FilePath, ct.LineNumber); err != nil {
		return fmt.Errorf("checking off task: %w", err)
	}

	if err := ClearCurrentTask(); err != nil {
		return err
	}

	fmt.Printf("Completed: %s\n", ct.Name)
	return nil
}

func cmdCurrent() error {
	ct, err := ReadCurrentTask()
	if err != nil {
		return err
	}
	if ct == nil {
		return nil
	}
	fmt.Println(ct.Name)
	return nil
}

func cmdTags(notesPath string) error {
	matches, err := Scan(notesPath)
	if err != nil {
		return fmt.Errorf("scan: %w", err)
	}

	allTasks := ParseTasks(matches)
	MergeFrontmatterTags(allTasks)

	projectTasks, err := ScanProjects(notesPath)
	if err != nil {
		return fmt.Errorf("scan projects: %w", err)
	}
	allTasks = append(allTasks, projectTasks...)

	seen := make(map[string]bool)
	for _, t := range allTasks {
		if t.Status != "open" {
			continue
		}
		for _, tag := range t.Tags {
			seen[tag] = true
		}
	}

	tags := make([]string, 0, len(seen))
	for tag := range seen {
		tags = append(tags, tag)
	}
	sort.Strings(tags)

	for _, tag := range tags {
		fmt.Println(tag)
	}
	return nil
}

func main() {
	notesPath := expandHome(defaultNotesPath)
	if envPath := os.Getenv("NOTES_PATH"); envPath != "" {
		notesPath = expandHome(envPath)
	}

	// Strip -v / --verbose from anywhere in args before subcommand parsing
	filtered := make([]string, 0, len(os.Args))
	filtered = append(filtered, os.Args[0])
	for _, a := range os.Args[1:] {
		if a == "-v" || a == "--verbose" {
			Verbose = true
		} else {
			filtered = append(filtered, a)
		}
	}

	cmd := "list"
	if len(filtered) > 1 {
		cmd = filtered[1]
	}

	var err error
	// Extra args after the subcommand (e.g., --tag, --markers)
	subArgs := []string{}
	if len(filtered) > 2 {
		subArgs = filtered[2:]
	}

	switch cmd {
	case "list":
		err = cmdList(notesPath, subArgs)
	case "do", "start":
		err = cmdDo(notesPath)
	case "stop", "pause":
		err = cmdStop()
	case "complete", "done":
		err = cmdComplete()
	case "current":
		err = cmdCurrent()
	case "tags":
		err = cmdTags(notesPath)
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", cmd)
		fmt.Fprintf(os.Stderr, "usage: task [list|do|stop|complete|current|tags]\n")
		os.Exit(1)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
