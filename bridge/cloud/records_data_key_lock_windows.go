//go:build windows

package cloud

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows"
)

type recordsDataKeyProcessLock struct {
	file       *os.File
	overlapped windows.Overlapped
}

func acquireRecordsDataKeyProcessLock(path string) (*recordsDataKeyProcessLock, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("create records encryption lock directory: %w", err)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open records encryption lock: %w", err)
	}
	lock := &recordsDataKeyProcessLock{file: file}
	for {
		err = windows.LockFileEx(
			windows.Handle(file.Fd()),
			windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
			0,
			1,
			0,
			&lock.overlapped,
		)
		if err == nil {
			return lock, nil
		}
		if !errors.Is(err, windows.ERROR_LOCK_VIOLATION) {
			_ = file.Close()
			return nil, fmt.Errorf("lock records encryption key: %w", err)
		}
		time.Sleep(25 * time.Millisecond)
	}
}

func (lock *recordsDataKeyProcessLock) Close() error {
	if lock == nil || lock.file == nil {
		return nil
	}
	err := windows.UnlockFileEx(windows.Handle(lock.file.Fd()), 0, 1, 0, &lock.overlapped)
	closeErr := lock.file.Close()
	lock.file = nil
	if err != nil {
		return err
	}
	return closeErr
}
