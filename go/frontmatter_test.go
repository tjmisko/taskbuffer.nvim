package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseFrontmatterTags_WithTags(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ntags:\n  - sspi\n  - project\n---\n# Content\n"), 0644)

	tags, err := ParseFrontmatterTags(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(tags) != 2 || tags[0] != "sspi" || tags[1] != "project" {
		t.Errorf("tags = %v, want [sspi project]", tags)
	}
}

func TestParseFrontmatterTags_NoFrontmatter(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("# Just a heading\nSome content\n"), 0644)

	tags, err := ParseFrontmatterTags(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(tags) != 0 {
		t.Errorf("tags = %v, want empty", tags)
	}
}

func TestParseFrontmatterTags_EmptyTags(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ntags: []\n---\n"), 0644)

	tags, err := ParseFrontmatterTags(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(tags) != 0 {
		t.Errorf("tags = %v, want empty", tags)
	}
}

func TestParseFrontmatterTags_NoTagsField(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ntitle: My Note\n---\n"), 0644)

	tags, err := ParseFrontmatterTags(f)
	if err != nil {
		t.Fatal(err)
	}
	if len(tags) != 0 {
		t.Errorf("tags = %v, want empty", tags)
	}
}

func TestParseFrontmatterTags_Cached(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ntags:\n  - cached\n---\n"), 0644)

	tags1, _ := ParseFrontmatterTags(f)
	// Overwrite file — cached result should still be returned
	os.WriteFile(f, []byte("---\ntags:\n  - different\n---\n"), 0644)
	tags2, _ := ParseFrontmatterTags(f)

	if len(tags1) != 1 || tags1[0] != "cached" {
		t.Errorf("first call: tags = %v", tags1)
	}
	if len(tags2) != 1 || tags2[0] != "cached" {
		t.Errorf("second call should be cached: tags = %v", tags2)
	}
}

func TestMergeFrontmatterTags_MergesAndDeduplicates(t *testing.T) {
	ResetFrontmatterCache()
	dir := t.TempDir()
	f := filepath.Join(dir, "test.md")
	os.WriteFile(f, []byte("---\ntags:\n  - project\n  - sspi\n---\n"), 0644)

	tasks := []Task{
		{FilePath: f, Tags: []string{"sspi", "inline"}},
	}
	MergeFrontmatterTags(tasks)

	// Should have sspi, inline, project (sspi not duplicated)
	if len(tasks[0].Tags) != 3 {
		t.Fatalf("tags count = %d, want 3: %v", len(tasks[0].Tags), tasks[0].Tags)
	}
	tagSet := make(map[string]bool)
	for _, tag := range tasks[0].Tags {
		tagSet[tag] = true
	}
	for _, want := range []string{"sspi", "inline", "project"} {
		if !tagSet[want] {
			t.Errorf("missing tag %q in %v", want, tasks[0].Tags)
		}
	}
}
