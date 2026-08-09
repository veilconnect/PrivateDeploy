package filesystem

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestRendererOperationsRejectSymlinkBoundary(t *testing.T) {
	service := tempService(t)
	outside := t.TempDir()
	outsideSecret := filepath.Join(outside, "secret.txt")
	if err := os.WriteFile(outsideSecret, []byte("outside"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(service.basePath, "escape")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if err := service.WriteFile("safe.txt", "safe", Options{}); err != nil {
		t.Fatal(err)
	}

	checks := []struct {
		name string
		run  func() error
	}{
		{"write", func() error { return service.WriteFile("escape/write.txt", "bad", Options{}) }},
		{"read", func() error { _, err := service.ReadFile("escape/secret.txt", Options{}); return err }},
		{"copy source", func() error { return service.CopyFile("escape/secret.txt", "copy.txt") }},
		{"copy target", func() error { return service.CopyFile("safe.txt", "escape/copy.txt") }},
		{"move target", func() error { return service.MoveFile("safe.txt", "escape/moved.txt") }},
		{"remove", func() error { return service.RemoveFile("escape/secret.txt") }},
		{"mkdir", func() error { return service.MakeDir("escape/new-dir") }},
		{"read dir", func() error { _, err := service.ReadDir("escape"); return err }},
		{"exists", func() error { _, err := service.FileExists("escape/secret.txt"); return err }},
	}
	for _, check := range checks {
		t.Run(check.name, func(t *testing.T) {
			if err := check.run(); err == nil {
				t.Fatal("operation unexpectedly followed a symlink")
			}
		})
	}

	contents, err := os.ReadFile(outsideSecret)
	if err != nil || string(contents) != "outside" {
		t.Fatalf("outside file changed: contents=%q err=%v", contents, err)
	}
	for _, unexpected := range []string{"write.txt", "copy.txt", "moved.txt", "new-dir"} {
		if _, err := os.Lstat(filepath.Join(outside, unexpected)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("operation created outside path %q: %v", unexpected, err)
		}
	}
}

func TestArchiveAndGZOperationsStayWithinBoundary(t *testing.T) {
	service := tempService(t)
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(service.basePath, "escape")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	var zipPayload bytes.Buffer
	zipWriter := zip.NewWriter(&zipPayload)
	zipEntry, err := zipWriter.Create("file.txt")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = zipEntry.Write([]byte("zip"))
	if err := zipWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(service.basePath, "payload.zip"), zipPayload.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}

	var tarPayload bytes.Buffer
	gzipWriter := gzip.NewWriter(&tarPayload)
	tarWriter := tar.NewWriter(gzipWriter)
	if err := tarWriter.WriteHeader(&tar.Header{Name: "file.txt", Mode: 0o600, Size: 3}); err != nil {
		t.Fatal(err)
	}
	_, _ = tarWriter.Write([]byte("tar"))
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gzipWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(service.basePath, "payload.tar.gz"), tarPayload.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}

	var gzPayload bytes.Buffer
	singleGzip := gzip.NewWriter(&gzPayload)
	_, _ = singleGzip.Write([]byte("gzip"))
	if err := singleGzip.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(service.basePath, "payload.gz"), gzPayload.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}

	for name, extract := range map[string]func() error{
		"zip":    func() error { return service.UnzipZIPFile("payload.zip", "escape") },
		"tar.gz": func() error { return service.UnzipTarGZFile("payload.tar.gz", "escape") },
		"gz":     func() error { return service.UnzipGZFile("payload.gz", "escape/output.txt") },
	} {
		t.Run(name, func(t *testing.T) {
			if err := extract(); err == nil {
				t.Fatal("archive operation unexpectedly followed a symlink")
			}
		})
	}
	entries, err := os.ReadDir(outside)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("archive extraction wrote outside the root: %v", entries)
	}
}

func TestArchivesRejectTraversalAndSpecialFiles(t *testing.T) {
	service := tempService(t)

	archivePath := filepath.Join(service.basePath, "traversal.zip")
	archiveFile, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	zipWriter := zip.NewWriter(archiveFile)
	entry, err := zipWriter.Create("../outside.txt")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = entry.Write([]byte("bad"))
	_ = zipWriter.Close()
	_ = archiveFile.Close()
	if err := service.UnzipZIPFile("traversal.zip", "extract"); err == nil {
		t.Fatal("zip traversal entry was accepted")
	}

	var payload bytes.Buffer
	gzipWriter := gzip.NewWriter(&payload)
	tarWriter := tar.NewWriter(gzipWriter)
	if err := tarWriter.WriteHeader(&tar.Header{Name: "link", Typeflag: tar.TypeSymlink, Linkname: "../../outside"}); err != nil {
		t.Fatal(err)
	}
	_ = tarWriter.Close()
	_ = gzipWriter.Close()
	if err := os.WriteFile(filepath.Join(service.basePath, "link.tar.gz"), payload.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := service.UnzipTarGZFile("link.tar.gz", "extract"); err == nil {
		t.Fatal("tar symlink entry was accepted")
	}
}
