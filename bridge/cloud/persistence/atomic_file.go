// Package persistence contains the durable local-storage primitives shared by
// cloud providers. It deliberately has no dependency on the cloud package so
// both cloud itself and provider subpackages can use it without import cycles.
package persistence

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
)

const privateFileMode os.FileMode = 0o600

type atomicWriteOps struct {
	createTemp func(string, string) (*os.File, error)
	rename     func(string, string) error
	syncDir    func(string) error
}

var realAtomicWriteOps = atomicWriteOps{
	createTemp: os.CreateTemp,
	rename:     os.Rename,
	syncDir:    syncDirectory,
}

// WritePrivateFileAtomic durably replaces path with data while keeping both
// the temporary and final file private (0600).
//
// The temporary file is created in the destination directory so rename is an
// atomic same-filesystem operation. The file contents are synced before the
// rename, then the directory is synced so the replacement itself is durable
// across a crash or power loss.
func WritePrivateFileAtomic(path string, data []byte) error {
	return writePrivateFileAtomic(path, data, realAtomicWriteOps)
}

// CreatePrivateFileExclusive durably creates path with private permissions and
// fails with os.ErrExist when another process already created it. It is used
// for billable-operation journals where "first writer wins" must hold across
// multiple desktop processes, not merely goroutines in one process.
func CreatePrivateFileExclusive(path string, data []byte) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, privateFileMode)
	if err != nil {
		return err
	}
	pathCreated := true
	closed := false
	defer func() {
		if !closed {
			_ = file.Close()
		}
		if pathCreated {
			_ = os.Remove(path)
		}
	}()

	if err := file.Chmod(privateFileMode); err != nil {
		return fmt.Errorf("set private file permissions: %w", err)
	}
	if n, err := file.Write(data); err != nil {
		return fmt.Errorf("write private file: %w", err)
	} else if n != len(data) {
		return fmt.Errorf("write private file: wrote %d of %d bytes: %w", n, len(data), io.ErrShortWrite)
	}
	if err := file.Sync(); err != nil {
		return fmt.Errorf("sync private file: %w", err)
	}
	if err := file.Close(); err != nil {
		closed = true
		return fmt.Errorf("close private file: %w", err)
	}
	closed = true
	if err := syncDirectory(filepath.Dir(path)); err != nil {
		return fmt.Errorf("sync destination directory: %w", err)
	}
	pathCreated = false
	return nil
}

func writePrivateFileAtomic(path string, data []byte, ops atomicWriteOps) error {
	dir := filepath.Dir(path)
	base := filepath.Base(path)

	tmp, err := ops.createTemp(dir, "."+base+".tmp-*")
	if err != nil {
		return fmt.Errorf("create temporary file: %w", err)
	}
	tmpPath := tmp.Name()
	closed := false
	defer func() {
		if !closed {
			_ = tmp.Close()
		}
		_ = os.Remove(tmpPath)
	}()

	// os.CreateTemp creates 0600 files, but enforce the invariant explicitly so
	// a custom platform implementation cannot accidentally broaden it.
	if err := tmp.Chmod(privateFileMode); err != nil {
		return fmt.Errorf("set temporary file permissions: %w", err)
	}
	if n, err := tmp.Write(data); err != nil {
		return fmt.Errorf("write temporary file: %w", err)
	} else if n != len(data) {
		return fmt.Errorf("write temporary file: wrote %d of %d bytes: %w", n, len(data), io.ErrShortWrite)
	}
	if err := tmp.Sync(); err != nil {
		return fmt.Errorf("sync temporary file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		closed = true
		return fmt.Errorf("close temporary file: %w", err)
	}
	closed = true

	if err := ops.rename(tmpPath, path); err != nil {
		return fmt.Errorf("replace destination file: %w", err)
	}
	if err := ops.syncDir(dir); err != nil {
		return fmt.Errorf("sync destination directory: %w", err)
	}
	return nil
}

func syncDirectory(path string) error {
	// Windows does not expose a portable directory-fsync operation through
	// os.File. The file itself is still synced before atomic replacement. On
	// Unix systems, where power-loss directory durability requires it, sync the
	// containing directory after rename.
	if runtime.GOOS == "windows" {
		return nil
	}

	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
