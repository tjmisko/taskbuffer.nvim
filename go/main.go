package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strconv"
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

// sourceList implements flag.Value for repeatable --source flags.
type sourceList []string

func (s *sourceList) String() string { return strings.Join(*s, ",") }
func (s *sourceList) Set(val string) error {
	*s = append(*s, val)
	return nil
}

// Config holds runtime configuration passed via --config JSON.
type Config struct {
	StateDir     string            `json:"state_dir"`
	DateFormat   string            `json:"date_format"`
	TimeFormat   string            `json:"time_format"`
	DateWrapper  []string          `json:"date_wrapper"`
	MarkerPrefix string            `json:"marker_prefix"`
	TagPrefix    string            `json:"tag_prefix"`
	Checkbox     map[string]string `json:"checkbox"`
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

// resolveNotesPaths determines the source directories from --source flags,
// NOTES_PATH env, or the default.
func resolveNotesPaths(sources sourceList) []string {
	if len(sources) > 0 {
		result := make([]string, len(sources))
		for i, s := range sources {
			result[i] = expandHome(s)
		}
		return result
	}
	if envPath := os.Getenv("NOTES_PATH"); envPath != "" {
		return []string{expandHome(envPath)}
	}
	return []string{expandHome(defaultNotesPath)}
}

func parseConfig(configJSON string) Config {
	var cfg Config
	if configJSON != "" {
		json.Unmarshal([]byte(configJSON), &cfg)
	}
	return cfg
}

func cmdList(notesPaths []string, args []string) error {
	var tags tagList
	var showMarkers bool

	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	fs.Var(&tags, "tag", "filter by tag (repeatable, OR logic)")
	fs.BoolVar(&showMarkers, "markers", false, "show :: markers")
	if err := fs.Parse(args); err != nil {
		return err
	}

	matches, err := Scan(notesPaths...)
	if err != nil {
		return fmt.Errorf("scan: %w", err)
	}

	allTasks := ParseTasks(matches)
	MergeFrontmatterTags(allTasks)

	projectTasks, err := ScanProjects(notesPaths...)
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

func cmdDo(notesPaths []string, cfg Config) error {
	now := time.Now().In(time.Local)
	today := now.Format("2006-01-02")

	existing, err := ReadCurrentTaskFrom(cfg.StateDir)
	if err != nil {
		return err
	}
	if existing != nil {
		if err := cmdStopWithConfig(cfg); err != nil {
			return fmt.Errorf("stopping current task: %w", err)
		}
	}

	matches, err := Scan(notesPaths...)
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

	var fzfInput strings.Builder
	for i, t := range todayTasks {
		fmt.Fprintf(&fzfInput, "%d\t%s\n", i, t.Body)
	}

	cmd := exec.Command("fzf", "--with-nth=2..", "--delimiter=\t")
	cmd.Stdin = strings.NewReader(fzfInput.String())
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		fmt.Println("No task selected.")
		return nil
	}

	selection := strings.TrimRight(string(out), "\n\r")
	parts := strings.SplitN(selection, "\t", 2)
	var idx int
	fmt.Sscanf(parts[0], "%d", &idx)
	if idx < 0 || idx >= len(todayTasks) {
		return fmt.Errorf("invalid selection index: %d", idx)
	}
	task := todayTasks[idx]

	marker := FormatMarker("start", now)
	if err := AppendToLine(task.FilePath, task.LineNumber, marker); err != nil {
		return fmt.Errorf("writing start marker: %w", err)
	}

	ct := CurrentTask{
		StartTime:  now.Unix(),
		Name:       task.Body,
		FilePath:   task.FilePath,
		LineNumber: task.LineNumber,
	}
	if err := WriteCurrentTaskTo(cfg.StateDir, ct); err != nil {
		return fmt.Errorf("saving state: %w", err)
	}

	fmt.Printf("Started: %s\n", task.Body)
	return nil
}

func cmdStopWithConfig(cfg Config) error {
	now := time.Now().In(time.Local)

	ct, err := ReadCurrentTaskFrom(cfg.StateDir)
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

	if err := ClearCurrentTaskFrom(cfg.StateDir); err != nil {
		return err
	}

	fmt.Printf("Stopped: %s\n", ct.Name)
	return nil
}

func cmdStop() error {
	return cmdStopWithConfig(Config{})
}

func cmdCompleteWithConfig(cfg Config) error {
	now := time.Now().In(time.Local)

	ct, err := ReadCurrentTaskFrom(cfg.StateDir)
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

	if err := ClearCurrentTaskFrom(cfg.StateDir); err != nil {
		return err
	}

	fmt.Printf("Completed: %s\n", ct.Name)
	return nil
}

func cmdComplete() error {
	return cmdCompleteWithConfig(Config{})
}

func cmdCurrent(cfg Config) error {
	ct, err := ReadCurrentTaskFrom(cfg.StateDir)
	if err != nil {
		return err
	}
	if ct == nil {
		return nil
	}
	fmt.Println(ct.Name)
	return nil
}

func cmdTags(notesPaths []string) error {
	matches, err := Scan(notesPaths...)
	if err != nil {
		return fmt.Errorf("scan: %w", err)
	}

	allTasks := ParseTasks(matches)
	MergeFrontmatterTags(allTasks)

	projectTasks, err := ScanProjects(notesPaths...)
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

// cmdDefer adds a ::deferral marker and preserves the original date.
func cmdDefer(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: task defer <filepath> <linenum>")
	}
	filePath := args[0]
	lineNum, err := strconv.Atoi(args[1])
	if err != nil {
		return fmt.Errorf("bad line number: %w", err)
	}

	now := time.Now().In(time.Local)

	// Read the line to check for existing ::original marker
	data, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("reading %s: %w", filePath, err)
	}
	lines := strings.Split(string(data), "\n")
	idx := lineNum - 1
	if idx < 0 || idx >= len(lines) {
		return fmt.Errorf("line %d out of range", lineNum)
	}

	line := lines[idx]

	// If no ::original marker, copy the current date as ::original
	if !strings.Contains(line, "::original") {
		// Extract the current due date from the line
		dateMatch := dateRe.FindStringSubmatch(line)
		if dateMatch != nil {
			originalMarker := fmt.Sprintf(" ::original [[%s]]", dateMatch[1])
			line = strings.TrimRight(line, " \t") + originalMarker
		}
	}

	// Append ::deferral marker
	deferralMarker := FormatMarker("deferral", now)
	line = strings.TrimRight(line, " \t") + " " + deferralMarker
	lines[idx] = line

	return os.WriteFile(filePath, []byte(strings.Join(lines, "\n")), 0644)
}

// cmdIrrelevant marks a task as irrelevant: changes checkbox to [-] and appends marker.
func cmdIrrelevant(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: task irrelevant <filepath> <linenum>")
	}
	filePath := args[0]
	lineNum, err := strconv.Atoi(args[1])
	if err != nil {
		return fmt.Errorf("bad line number: %w", err)
	}

	now := time.Now().In(time.Local)
	marker := FormatMarker("irrelevant", now)

	if err := ChangeCheckbox(filePath, lineNum, "- [ ]", "- [-]"); err != nil {
		return err
	}
	return AppendToLine(filePath, lineNum, marker)
}

// cmdPartial marks a task as partial: changes checkbox to [~] and appends marker.
func cmdPartial(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: task partial <filepath> <linenum>")
	}
	filePath := args[0]
	lineNum, err := strconv.Atoi(args[1])
	if err != nil {
		return fmt.Errorf("bad line number: %w", err)
	}

	now := time.Now().In(time.Local)
	marker := FormatMarker("partial", now)

	if err := ChangeCheckbox(filePath, lineNum, "- [ ]", "- [~]"); err != nil {
		return err
	}
	return AppendToLine(filePath, lineNum, marker)
}

// cmdUnset undoes an irrelevant or partial: removes last marker and restores checkbox.
func cmdUnset(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: task unset <filepath> <linenum>")
	}
	filePath := args[0]
	lineNum, err := strconv.Atoi(args[1])
	if err != nil {
		return fmt.Errorf("bad line number: %w", err)
	}

	// Read the line to determine which kind of marker to remove
	data, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("reading %s: %w", filePath, err)
	}
	lines := strings.Split(string(data), "\n")
	idx := lineNum - 1
	if idx < 0 || idx >= len(lines) {
		return fmt.Errorf("line %d out of range", lineNum)
	}

	line := lines[idx]

	// Try irrelevant first, then partial
	if strings.Contains(line, "::irrelevant") {
		if err := RemoveLastMarker(filePath, lineNum, "irrelevant"); err != nil {
			return err
		}
		return ChangeCheckbox(filePath, lineNum, "- [-]", "- [ ]")
	}
	if strings.Contains(line, "::partial") {
		if err := RemoveLastMarker(filePath, lineNum, "partial"); err != nil {
			return err
		}
		return ChangeCheckbox(filePath, lineNum, "- [~]", "- [ ]")
	}

	return nil
}

// cmdCheck quick check-off: changes [ ] to [x] without markers.
func cmdCheck(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: task check <filepath> <linenum>")
	}
	filePath := args[0]
	lineNum, err := strconv.Atoi(args[1])
	if err != nil {
		return fmt.Errorf("bad line number: %w", err)
	}

	return CheckOffTask(filePath, lineNum)
}

// cmdCompleteAt completes a specific task by filepath/line (not the "current" running task).
func cmdCompleteAt(args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: task complete-at <filepath> <linenum>")
	}
	filePath := args[0]
	lineNum, err := strconv.Atoi(args[1])
	if err != nil {
		return fmt.Errorf("bad line number: %w", err)
	}

	now := time.Now().In(time.Local)
	marker := FormatMarker("complete", now)

	if err := AppendToLine(filePath, lineNum, marker); err != nil {
		return err
	}
	return CheckOffTask(filePath, lineNum)
}

// cmdCreate creates a new task line in a file.
func cmdCreate(args []string) error {
	fs := flag.NewFlagSet("create", flag.ContinueOnError)
	file := fs.String("file", "", "target file (overrides inbox default)")
	header := fs.String("header", "", "insert below this markdown header")
	inboxFile := fs.String("inbox-file", "", "default inbox file from config")
	inboxHeader := fs.String("inbox-header", "", "default inbox header from config")
	if err := fs.Parse(args); err != nil {
		return err
	}

	body := strings.Join(fs.Args(), " ")
	if body == "" {
		return fmt.Errorf("usage: task create [--file FILE] [--header HEADER] <body>")
	}

	taskLine := "- [ ] " + body

	// Determine target file
	targetFile := *file
	if targetFile == "" {
		targetFile = *inboxFile
	}
	if targetFile == "" {
		return fmt.Errorf("no target file specified (use --file or configure inbox)")
	}
	targetFile = expandHome(targetFile)

	// Ensure parent directory exists
	dir := strings.TrimRight(targetFile, "/")
	if lastSlash := strings.LastIndex(dir, "/"); lastSlash > 0 {
		os.MkdirAll(dir[:lastSlash], 0755)
	}

	// Determine header
	targetHeader := *header
	if targetHeader == "" {
		targetHeader = *inboxHeader
	}

	if targetHeader != "" {
		return InsertAfterHeader(targetFile, targetHeader, taskLine)
	}
	return AppendToFile(targetFile, taskLine)
}

func main() {
	// Parse global flags first
	var sources sourceList
	var configJSON string

	filtered := make([]string, 0, len(os.Args))
	filtered = append(filtered, os.Args[0])
	for _, a := range os.Args[1:] {
		if a == "-v" || a == "--verbose" {
			Verbose = true
		} else {
			filtered = append(filtered, a)
		}
	}

	// Extract --source and --config flags from anywhere before subcommand parsing
	globalFS := flag.NewFlagSet("global", flag.ContinueOnError)
	globalFS.Var(&sources, "source", "notes source directory (repeatable)")
	globalFS.StringVar(&configJSON, "config", "", "JSON config string")

	// Find subcommand position: first arg that doesn't start with -
	subCmdIdx := 1
	for subCmdIdx < len(filtered) {
		arg := filtered[subCmdIdx]
		if !strings.HasPrefix(arg, "-") {
			break
		}
		// Skip the value of --source and --config flags
		if arg == "--source" || arg == "--config" {
			subCmdIdx += 2
			continue
		}
		if strings.HasPrefix(arg, "--source=") || strings.HasPrefix(arg, "--config=") {
			subCmdIdx++
			continue
		}
		subCmdIdx++
	}

	// Parse global flags (everything before subcommand)
	if subCmdIdx > 1 {
		globalFS.Parse(filtered[1:subCmdIdx])
	}

	notesPaths := resolveNotesPaths(sources)
	cfg := parseConfig(configJSON)

	cmd := "list"
	if subCmdIdx < len(filtered) {
		cmd = filtered[subCmdIdx]
	}

	subArgs := []string{}
	if subCmdIdx+1 < len(filtered) {
		subArgs = filtered[subCmdIdx+1:]
	}

	var err error
	switch cmd {
	case "list":
		err = cmdList(notesPaths, subArgs)
	case "do", "start":
		err = cmdDo(notesPaths, cfg)
	case "stop", "pause":
		err = cmdStopWithConfig(cfg)
	case "complete", "done":
		err = cmdCompleteWithConfig(cfg)
	case "current":
		err = cmdCurrent(cfg)
	case "tags":
		err = cmdTags(notesPaths)
	case "defer":
		err = cmdDefer(subArgs)
	case "irrelevant":
		err = cmdIrrelevant(subArgs)
	case "partial":
		err = cmdPartial(subArgs)
	case "unset":
		err = cmdUnset(subArgs)
	case "check":
		err = cmdCheck(subArgs)
	case "complete-at":
		err = cmdCompleteAt(subArgs)
	case "create":
		err = cmdCreate(subArgs)
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", cmd)
		fmt.Fprintf(os.Stderr, "usage: task [list|do|stop|complete|current|tags|defer|irrelevant|partial|unset|check|complete-at|create]\n")
		os.Exit(1)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
