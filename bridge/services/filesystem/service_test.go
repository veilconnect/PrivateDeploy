package filesystem

import (
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
