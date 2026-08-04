package persistence

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestWritePrivateFileAtomicReplacesContentWithPrivatePermissions(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	if err := os.WriteFile(path, []byte("old"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := WritePrivateFileAtomic(path, []byte("new")); err != nil {
		t.Fatalf("WritePrivateFileAtomic: %v", err)
	}

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "new" {
		t.Fatalf("content = %q, want new", got)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if gotMode := info.Mode().Perm(); gotMode != privateFileMode {
			t.Fatalf("mode = %04o, want %04o", gotMode, privateFileMode)
		}
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.Contains(entry.Name(), ".tmp-") {
			t.Fatalf("temporary file was not cleaned up: %s", entry.Name())
		}
	}
}

func TestWritePrivateFileAtomicRenameFailurePreservesOriginal(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "records.json")
	if err := os.WriteFile(path, []byte("original"), privateFileMode); err != nil {
		t.Fatal(err)
	}

	wantErr := errors.New("injected rename failure")
	ops := realAtomicWriteOps
	ops.rename = func(_, _ string) error { return wantErr }
	if err := writePrivateFileAtomic(path, []byte("replacement"), ops); !errors.Is(err, wantErr) {
		t.Fatalf("error = %v, want injected failure", err)
	}

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "original" {
		t.Fatalf("failed replacement changed original to %q", got)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != filepath.Base(path) {
		t.Fatalf("unexpected files after failed replacement: %+v", entries)
	}
}

func TestWritePrivateFileAtomicSyncsDirectoryAfterRename(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "secret")
	renamed := false
	synced := false
	ops := realAtomicWriteOps
	ops.rename = func(oldPath, newPath string) error {
		if err := os.Rename(oldPath, newPath); err != nil {
			return err
		}
		renamed = true
		return nil
	}
	ops.syncDir = func(got string) error {
		if !renamed {
			t.Fatal("directory sync happened before rename")
		}
		if got != dir {
			t.Fatalf("synced directory = %q, want %q", got, dir)
		}
		synced = true
		return nil
	}

	if err := writePrivateFileAtomic(path, []byte("secret"), ops); err != nil {
		t.Fatalf("writePrivateFileAtomic: %v", err)
	}
	if !synced {
		t.Fatal("destination directory was not synced")
	}
}
