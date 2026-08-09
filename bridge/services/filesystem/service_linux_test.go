//go:build linux

package filesystem

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
)

// This is a regression test for the classic check-then-open race: another
// goroutine repeatedly replaces an authorized directory name with a symlink to
// an outside directory while every read/write/remove operation is running.
// Failures caused by the changing path are expected; crossing the root is not.
func TestConcurrentSymlinkSwapNeverEscapesBase(t *testing.T) {
	service := tempService(t)
	outside := t.TempDir()
	active := filepath.Join(service.basePath, "swap")
	holding := filepath.Join(service.basePath, "swap-holding")
	if err := os.Mkdir(active, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(active, "read.txt"), []byte("inside"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(active, "delete.txt"), []byte("inside-delete"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "read.txt"), []byte("outside-secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	outsideDelete := filepath.Join(outside, "delete.txt")
	if err := os.WriteFile(outsideDelete, []byte("must-survive"), 0o600); err != nil {
		t.Fatal(err)
	}

	stop := make(chan struct{})
	var swapper sync.WaitGroup
	swapper.Add(1)
	go func() {
		defer swapper.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			if err := os.Rename(active, holding); err != nil {
				runtime.Gosched()
				continue
			}
			if err := os.Symlink(outside, active); err == nil {
				runtime.Gosched()
				_ = os.Remove(active)
			}
			_ = os.Rename(holding, active)
		}
	}()

	for index := 0; index < 600; index++ {
		_ = service.WriteFile("swap/written.txt", "inside-write", Options{})
		if contents, err := service.ReadFile("swap/read.txt", Options{}); err == nil && contents != "inside" {
			close(stop)
			swapper.Wait()
			t.Fatalf("read crossed the application root: %q", contents)
		}
		_ = service.RemoveFile("swap/delete.txt")
		if _, err := os.Lstat(filepath.Join(outside, "written.txt")); !errors.Is(err, os.ErrNotExist) {
			close(stop)
			swapper.Wait()
			t.Fatalf("write crossed the application root: %v", err)
		}
		if contents, err := os.ReadFile(outsideDelete); err != nil || string(contents) != "must-survive" {
			close(stop)
			swapper.Wait()
			t.Fatalf("remove crossed the application root: contents=%q err=%v", contents, err)
		}
	}
	close(stop)
	swapper.Wait()
}

func TestWriteStreamAtomicFailurePreservesPreviousFile(t *testing.T) {
	service := tempService(t)
	if err := service.WriteFile("target.txt", "previous", Options{}); err != nil {
		t.Fatal(err)
	}
	wantErr := errors.New("interrupted")
	err := service.WriteStreamAtomic("target.txt", 0o600, func(writer io.Writer) error {
		_, _ = writer.Write([]byte("partial replacement"))
		return wantErr
	})
	if !errors.Is(err, wantErr) {
		t.Fatalf("WriteStreamAtomic error = %v, want %v", err, wantErr)
	}
	contents, err := os.ReadFile(filepath.Join(service.basePath, "target.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "previous" {
		t.Fatalf("failed stream partially replaced target: %q", contents)
	}
}
