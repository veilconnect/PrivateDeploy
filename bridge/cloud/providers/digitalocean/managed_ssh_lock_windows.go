//go:build windows

package digitalocean

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows"
)

type managedSSHKeyProcessLock struct {
	file       *os.File
	overlapped windows.Overlapped
}

func acquireManagedSSHKeyProcessLock(ctx context.Context, path string) (*managedSSHKeyProcessLock, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("create managed SSH lock directory: %w", err)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open managed SSH lock: %w", err)
	}
	lock := &managedSSHKeyProcessLock{file: file}
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
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
			return nil, fmt.Errorf("lock managed SSH key: %w", err)
		}
		select {
		case <-ctx.Done():
			_ = file.Close()
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
}

func (lock *managedSSHKeyProcessLock) Close() error {
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
