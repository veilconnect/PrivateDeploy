package filesystem

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func tempService(t *testing.T) *Service {
	t.Helper()
	dir := t.TempDir()
	return NewService(dir)
}

func TestNewService_CleansPath(t *testing.T) {
	s := NewService("/tmp/test/../test")
	if s.basePath != "/tmp/test" {
		t.Errorf("expected cleaned path, got %s", s.basePath)
	}
}

func TestResolve_RelativePath(t *testing.T) {
	s := tempService(t)
	got, err := s.resolve("subdir/file.txt")
	if err != nil {
		t.Fatal(err)
	}
	expected := filepath.Join(s.basePath, "subdir/file.txt")
	if got != expected {
		t.Errorf("expected %s, got %s", expected, got)
	}
}

func TestResolve_TraversalBlocked(t *testing.T) {
	s := tempService(t)
	_, err := s.resolve("../../etc/passwd")
	if err == nil {
		t.Error("expected error for directory traversal")
	}
}

func TestResolve_AbsolutePathOutsideBase(t *testing.T) {
	s := tempService(t)
	_, err := s.resolve("/etc/passwd")
	if err == nil {
		t.Error("expected error for absolute path outside base")
	}
}

func TestWriteFile_Text(t *testing.T) {
	s := tempService(t)
	err := s.WriteFile("test.txt", "hello world", Options{Mode: ModeText})
	if err != nil {
		t.Fatal(err)
	}

	content, err := os.ReadFile(filepath.Join(s.basePath, "test.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "hello world" {
		t.Errorf("expected 'hello world', got %q", string(content))
	}
	info, err := os.Stat(filepath.Join(s.basePath, "test.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("sensitive app files must be private: got %o, want 600", got)
	}
}

func TestResolve_RejectsSymlinkEscape(t *testing.T) {
	s := tempService(t)
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(s.basePath, "escape")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if err := s.WriteFile("escape/secret.txt", "blocked", Options{Mode: ModeText}); err == nil {
		t.Fatal("expected symlink path to be rejected")
	}
	if _, err := os.Stat(filepath.Join(outside, "secret.txt")); !os.IsNotExist(err) {
		t.Fatalf("write escaped base directory: %v", err)
	}
}

func TestWriteFile_Binary(t *testing.T) {
	s := tempService(t)
	encoded := base64.StdEncoding.EncodeToString([]byte("binary data"))
	err := s.WriteFile("test.bin", encoded, Options{Mode: ModeBinary})
	if err != nil {
		t.Fatal(err)
	}

	content, err := os.ReadFile(filepath.Join(s.basePath, "test.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "binary data" {
		t.Errorf("expected 'binary data', got %q", string(content))
	}
}

func TestWriteFile_CreatesSubdirs(t *testing.T) {
	s := tempService(t)
	err := s.WriteFile("a/b/c/deep.txt", "nested", Options{Mode: ModeText})
	if err != nil {
		t.Fatal(err)
	}

	content, err := os.ReadFile(filepath.Join(s.basePath, "a/b/c/deep.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "nested" {
		t.Errorf("expected 'nested', got %q", string(content))
	}
}

func TestReadFile_Text(t *testing.T) {
	s := tempService(t)
	os.WriteFile(filepath.Join(s.basePath, "read.txt"), []byte("read me"), 0644)

	content, err := s.ReadFile("read.txt", Options{Mode: ModeText})
	if err != nil {
		t.Fatal(err)
	}
	if content != "read me" {
		t.Errorf("expected 'read me', got %q", content)
	}
}

func TestReadFile_Binary(t *testing.T) {
	s := tempService(t)
	os.WriteFile(filepath.Join(s.basePath, "read.bin"), []byte("raw"), 0644)

	content, err := s.ReadFile("read.bin", Options{Mode: ModeBinary})
	if err != nil {
		t.Fatal(err)
	}
	decoded, _ := base64.StdEncoding.DecodeString(content)
	if string(decoded) != "raw" {
		t.Errorf("expected 'raw', got %q", string(decoded))
	}
}

func TestReadFile_NotFound(t *testing.T) {
	s := tempService(t)
	_, err := s.ReadFile("nonexistent.txt", Options{})
	if err == nil {
		t.Error("expected error for nonexistent file")
	}
}

func TestMoveFile(t *testing.T) {
	s := tempService(t)
	s.WriteFile("original.txt", "data", Options{})

	err := s.MoveFile("original.txt", "moved.txt")
	if err != nil {
		t.Fatal(err)
	}

	// Original should not exist
	if _, err := os.Stat(filepath.Join(s.basePath, "original.txt")); !os.IsNotExist(err) {
		t.Error("original file should not exist after move")
	}

	// Target should exist
	content, err := s.ReadFile("moved.txt", Options{})
	if err != nil {
		t.Fatal(err)
	}
	if content != "data" {
		t.Errorf("expected 'data', got %q", content)
	}
}

func TestRemoveFile(t *testing.T) {
	s := tempService(t)
	s.WriteFile("delete-me.txt", "bye", Options{})

	err := s.RemoveFile("delete-me.txt")
	if err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(filepath.Join(s.basePath, "delete-me.txt")); !os.IsNotExist(err) {
		t.Error("file should not exist after remove")
	}
}

func TestRemoveFile_TraversalBlocked(t *testing.T) {
	s := tempService(t)
	err := s.RemoveFile("../../etc/passwd")
	if err == nil {
		t.Error("expected error for directory traversal in remove")
	}
}

func TestRemoveFile_RejectsApplicationDataRoot(t *testing.T) {
	s := tempService(t)
	marker := filepath.Join(s.basePath, "keep.txt")
	if err := os.WriteFile(marker, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"", "."} {
		if err := s.RemoveFile(path); err == nil {
			t.Fatalf("RemoveFile(%q) unexpectedly accepted the data root", path)
		}
	}
	if _, err := os.Stat(marker); err != nil {
		t.Fatalf("data root contents were changed: %v", err)
	}
}

func TestMoveFile_RejectsApplicationDataRoot(t *testing.T) {
	s := tempService(t)
	if err := s.MoveFile(".", "moved-root"); err == nil {
		t.Fatal("moving the application data root was accepted")
	}
	if err := s.WriteFile("source.txt", "keep", Options{}); err != nil {
		t.Fatal(err)
	}
	if err := s.MoveFile("source.txt", "."); err == nil {
		t.Fatal("replacing the application data root was accepted")
	}
}

func TestUnzipZIPFile_RejectsExistingSymlinkComponent(t *testing.T) {
	s := tempService(t)
	outside := t.TempDir()
	target := filepath.Join(s.basePath, "extract")
	if err := os.MkdirAll(target, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(target, "escape")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	archivePath := filepath.Join(s.basePath, "payload.zip")
	archiveFile, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(archiveFile)
	entry, err := writer.Create("escape/written.txt")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = entry.Write([]byte("blocked"))
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := archiveFile.Close(); err != nil {
		t.Fatal(err)
	}

	if err := s.UnzipZIPFile("payload.zip", "extract"); err == nil {
		t.Fatal("zip extraction followed an existing symlink")
	}
	if _, err := os.Stat(filepath.Join(outside, "written.txt")); !os.IsNotExist(err) {
		t.Fatalf("zip escaped the data root: %v", err)
	}
}

func TestUnzipTarGZFile_RejectsExistingSymlinkComponent(t *testing.T) {
	s := tempService(t)
	outside := t.TempDir()
	target := filepath.Join(s.basePath, "extract")
	if err := os.MkdirAll(target, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(target, "escape")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	var payload bytes.Buffer
	gzipWriter := gzip.NewWriter(&payload)
	tarWriter := tar.NewWriter(gzipWriter)
	contents := []byte("blocked")
	if err := tarWriter.WriteHeader(&tar.Header{
		Name: "escape/written.txt",
		Mode: 0o600,
		Size: int64(len(contents)),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := tarWriter.Write(contents); err != nil {
		t.Fatal(err)
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gzipWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(s.basePath, "payload.tar.gz"), payload.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := s.UnzipTarGZFile("payload.tar.gz", "extract"); err == nil {
		t.Fatal("tar extraction followed an existing symlink")
	}
	if _, err := os.Stat(filepath.Join(outside, "written.txt")); !os.IsNotExist(err) {
		t.Fatalf("tar escaped the data root: %v", err)
	}
}

func TestWriteReadRoundtrip(t *testing.T) {
	s := tempService(t)

	// Text roundtrip
	s.WriteFile("rt.txt", "roundtrip", Options{Mode: ModeText})
	got, _ := s.ReadFile("rt.txt", Options{Mode: ModeText})
	if got != "roundtrip" {
		t.Errorf("text roundtrip failed: got %q", got)
	}

	// Binary roundtrip
	original := []byte{0x00, 0xff, 0x42}
	encoded := base64.StdEncoding.EncodeToString(original)
	s.WriteFile("rt.bin", encoded, Options{Mode: ModeBinary})
	gotB64, _ := s.ReadFile("rt.bin", Options{Mode: ModeBinary})
	decoded, _ := base64.StdEncoding.DecodeString(gotB64)
	if len(decoded) != 3 || decoded[2] != 0x42 {
		t.Errorf("binary roundtrip failed: got %v", decoded)
	}
}
