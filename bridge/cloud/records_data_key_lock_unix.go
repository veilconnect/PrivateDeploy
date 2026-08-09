//go:build !windows

package cloud

import (
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

type recordsDataKeyProcessLock struct {
	file *os.File
}

func acquireRecordsDataKeyProcessLock(path string) (*recordsDataKeyProcessLock, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("create records encryption lock directory: %w", err)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open records encryption lock: %w", err)
	}
	_ = file.Chmod(0o600)
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX); err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("lock records encryption key: %w", err)
	}
	return &recordsDataKeyProcessLock{file: file}, nil
}

func (lock *recordsDataKeyProcessLock) Close() error {
	if lock == nil || lock.file == nil {
		return nil
	}
	err := unix.Flock(int(lock.file.Fd()), unix.LOCK_UN)
	closeErr := lock.file.Close()
	lock.file = nil
	if err != nil {
		return err
	}
	return closeErr
}
