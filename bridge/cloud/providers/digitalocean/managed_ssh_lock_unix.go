//go:build !windows

package digitalocean

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/unix"
)

type managedSSHKeyProcessLock struct {
	file *os.File
}

func acquireManagedSSHKeyProcessLock(ctx context.Context, path string) (*managedSSHKeyProcessLock, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("create managed SSH lock directory: %w", err)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open managed SSH lock: %w", err)
	}
	_ = file.Chmod(0o600)
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		err = unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB)
		if err == nil {
			return &managedSSHKeyProcessLock{file: file}, nil
		}
		if !errors.Is(err, unix.EWOULDBLOCK) && !errors.Is(err, unix.EAGAIN) {
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
	err := unix.Flock(int(lock.file.Fd()), unix.LOCK_UN)
	closeErr := lock.file.Close()
	lock.file = nil
	if err != nil {
		return err
	}
	return closeErr
}
