//go:build !windows

package bridge

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/unix"
)

type cloudOperationFileLock struct {
	file *os.File
}

func acquireCloudOperationFileLock(ctx context.Context, path string) (*cloudOperationFileLock, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("create cloud operation lock directory: %w", err)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open cloud operation lock: %w", err)
	}
	_ = file.Chmod(0o600)

	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		err = unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB)
		if err == nil {
			return &cloudOperationFileLock{file: file}, nil
		}
		if !errors.Is(err, unix.EWOULDBLOCK) && !errors.Is(err, unix.EAGAIN) {
			_ = file.Close()
			return nil, fmt.Errorf("lock cloud operation: %w", err)
		}
		select {
		case <-ctx.Done():
			_ = file.Close()
			return nil, ctx.Err()
		case <-ticker.C:
		}
	}
}

func (lock *cloudOperationFileLock) Close() error {
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
