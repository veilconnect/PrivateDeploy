//go:build linux

package filesystem

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"

	"golang.org/x/sys/unix"
)

type linuxSecureBackend struct {
	baseFD  int
	baseErr error
}

func newSecureBackend(basePath string) secureBackend {
	backend := &linuxSecureBackend{baseFD: -1}
	if err := os.MkdirAll(basePath, 0o700); err != nil {
		backend.baseErr = fmt.Errorf("create application data root: %w", err)
		return backend
	}
	fd, err := unix.Open(basePath, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		backend.baseErr = fmt.Errorf("open application data root securely: %w", err)
		return backend
	}
	backend.baseFD = fd
	runtime.SetFinalizer(backend, (*linuxSecureBackend).close)
	return backend
}

func (b *linuxSecureBackend) close() {
	if b != nil && b.baseFD >= 0 {
		_ = unix.Close(b.baseFD)
		b.baseFD = -1
	}
}

func (b *linuxSecureBackend) dupBase() (int, error) {
	if b == nil {
		return -1, errors.New("filesystem backend is not initialized")
	}
	if b.baseErr != nil {
		return -1, b.baseErr
	}
	if b.baseFD < 0 {
		return -1, errors.New("application data root is closed")
	}
	fd, err := unix.Dup(b.baseFD)
	if err != nil {
		return -1, fmt.Errorf("duplicate application data root descriptor: %w", err)
	}
	unix.CloseOnExec(fd)
	return fd, nil
}

func (b *linuxSecureBackend) openDir(rel string, create bool, mode os.FileMode) (int, error) {
	fd, err := b.dupBase()
	if err != nil {
		return -1, err
	}
	for _, component := range relComponents(rel) {
		next, openErr := unix.Openat(fd, component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if errors.Is(openErr, unix.ENOENT) && create {
			mkdirErr := unix.Mkdirat(fd, component, uint32(mode.Perm()))
			if mkdirErr != nil && !errors.Is(mkdirErr, unix.EEXIST) {
				_ = unix.Close(fd)
				return -1, fmt.Errorf("create directory component securely: %w", mkdirErr)
			}
			next, openErr = unix.Openat(fd, component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		}
		if openErr != nil {
			_ = unix.Close(fd)
			return -1, fmt.Errorf("open directory component securely: %w", openErr)
		}
		_ = unix.Close(fd)
		fd = next
	}
	return fd, nil
}

func (b *linuxSecureBackend) openParent(rel string, create bool) (int, string, error) {
	components := relComponents(rel)
	if len(components) == 0 {
		return -1, "", errors.New("operation on the application data root is not allowed")
	}
	parentRel := "."
	if len(components) > 1 {
		parentRel = filepath.Join(components[:len(components)-1]...)
	}
	fd, err := b.openDir(parentRel, create, 0o700)
	if err != nil {
		return -1, "", err
	}
	return fd, components[len(components)-1], nil
}

func symlinkMode(mode uint32) bool {
	return mode&unix.S_IFMT == unix.S_IFLNK
}

func directoryMode(mode uint32) bool {
	return mode&unix.S_IFMT == unix.S_IFDIR
}

func regularMode(mode uint32) bool {
	return mode&unix.S_IFMT == unix.S_IFREG
}

func (b *linuxSecureBackend) validate(rel string) error {
	components := relComponents(rel)
	if len(components) == 0 {
		fd, err := b.dupBase()
		if err == nil {
			_ = unix.Close(fd)
		}
		return err
	}

	fd, err := b.dupBase()
	if err != nil {
		return err
	}
	defer func() { _ = unix.Close(fd) }()
	for index, component := range components {
		var stat unix.Stat_t
		err = unix.Fstatat(fd, component, &stat, unix.AT_SYMLINK_NOFOLLOW)
		if errors.Is(err, unix.ENOENT) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("inspect path component securely: %w", err)
		}
		if symlinkMode(stat.Mode) {
			return errors.New("access denied: symbolic links are not allowed")
		}
		if index == len(components)-1 {
			return nil
		}
		if !directoryMode(stat.Mode) {
			return errors.New("path component is not a directory")
		}
		next, openErr := unix.Openat(fd, component, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if openErr != nil {
			return fmt.Errorf("open path component securely: %w", openErr)
		}
		_ = unix.Close(fd)
		fd = next
	}
	return nil
}

func (b *linuxSecureBackend) openRead(rel string) (*os.File, error) {
	parentFD, name, err := b.openParent(rel, false)
	if err != nil {
		return nil, err
	}
	defer unix.Close(parentFD)

	fd, err := unix.Openat(parentFD, name, unix.O_RDONLY|unix.O_NONBLOCK|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("open file securely: %w", err)
	}
	var stat unix.Stat_t
	if err := unix.Fstat(fd, &stat); err != nil {
		_ = unix.Close(fd)
		return nil, fmt.Errorf("inspect opened file: %w", err)
	}
	if !regularMode(stat.Mode) {
		_ = unix.Close(fd)
		return nil, errors.New("access denied: path is not a regular file")
	}
	return os.NewFile(uintptr(fd), name), nil
}

func (b *linuxSecureBackend) writeAtomic(rel string, mode os.FileMode, write func(io.Writer) error) (returnErr error) {
	parentFD, name, err := b.openParent(rel, true)
	if err != nil {
		return err
	}
	defer unix.Close(parentFD)

	var targetStat unix.Stat_t
	err = unix.Fstatat(parentFD, name, &targetStat, unix.AT_SYMLINK_NOFOLLOW)
	if err == nil {
		if symlinkMode(targetStat.Mode) {
			return errors.New("access denied: symbolic links are not allowed")
		}
		if !regularMode(targetStat.Mode) {
			return errors.New("access denied: target is not a regular file")
		}
	} else if !errors.Is(err, unix.ENOENT) {
		return fmt.Errorf("inspect target securely: %w", err)
	}

	temporaryName, err := randomSecureComponent(".privatedeploy-", ".tmp")
	if err != nil {
		return fmt.Errorf("create secure temporary name: %w", err)
	}
	fd, err := unix.Openat(parentFD, temporaryName, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, uint32(mode.Perm()))
	if err != nil {
		return fmt.Errorf("create temporary file securely: %w", err)
	}
	file := os.NewFile(uintptr(fd), temporaryName)
	defer func() {
		_ = file.Close()
		_ = unix.Unlinkat(parentFD, temporaryName, 0)
	}()

	if err := write(file); err != nil {
		return err
	}
	if err := file.Chmod(mode.Perm()); err != nil {
		return fmt.Errorf("set private file permissions: %w", err)
	}
	if err := file.Sync(); err != nil {
		return fmt.Errorf("sync file contents: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close temporary file: %w", err)
	}

	// Recheck for a symlink to preserve the API's no-symlink contract. Even if
	// an attacker swaps one in immediately after this check, renameat replaces
	// the link itself and never follows it.
	err = unix.Fstatat(parentFD, name, &targetStat, unix.AT_SYMLINK_NOFOLLOW)
	if err == nil && symlinkMode(targetStat.Mode) {
		return errors.New("access denied: symbolic links are not allowed")
	}
	if err != nil && !errors.Is(err, unix.ENOENT) {
		return fmt.Errorf("recheck target securely: %w", err)
	}
	if err := unix.Renameat(parentFD, temporaryName, parentFD, name); err != nil {
		return fmt.Errorf("publish file atomically: %w", err)
	}
	_ = unix.Fsync(parentFD)
	return nil
}

func (b *linuxSecureBackend) mkdirAll(rel string, mode os.FileMode) error {
	fd, err := b.openDir(rel, true, mode)
	if err != nil {
		return err
	}
	return unix.Close(fd)
}

func (b *linuxSecureBackend) readDir(rel string) ([]os.DirEntry, error) {
	fd, err := b.openDir(rel, false, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), filepath.Base(rel))
	defer file.Close()
	entries, err := file.ReadDir(-1)
	if err != nil {
		return nil, fmt.Errorf("read directory securely: %w", err)
	}
	return entries, nil
}

func inspectRenameEntry(parentFD int, name string) error {
	var stat unix.Stat_t
	if err := unix.Fstatat(parentFD, name, &stat, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	if symlinkMode(stat.Mode) {
		return errors.New("access denied: symbolic links are not allowed")
	}
	return nil
}

func (b *linuxSecureBackend) rename(sourceRel, targetRel string) error {
	sourceParent, sourceName, err := b.openParent(sourceRel, false)
	if err != nil {
		return err
	}
	defer unix.Close(sourceParent)
	if err := inspectRenameEntry(sourceParent, sourceName); err != nil {
		return fmt.Errorf("inspect move source securely: %w", err)
	}

	targetParent, targetName, err := b.openParent(targetRel, true)
	if err != nil {
		return err
	}
	defer unix.Close(targetParent)
	if err := inspectRenameEntry(targetParent, targetName); err != nil && !errors.Is(err, unix.ENOENT) {
		return fmt.Errorf("inspect move target securely: %w", err)
	}
	if err := unix.Renameat(sourceParent, sourceName, targetParent, targetName); err != nil {
		return fmt.Errorf("move path securely: %w", err)
	}
	_ = unix.Fsync(sourceParent)
	if sourceParent != targetParent {
		_ = unix.Fsync(targetParent)
	}
	return nil
}

func removeEntry(parentFD int, name string) error {
	for attempts := 0; attempts < 32; attempts++ {
		var stat unix.Stat_t
		err := unix.Fstatat(parentFD, name, &stat, unix.AT_SYMLINK_NOFOLLOW)
		if errors.Is(err, unix.ENOENT) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("inspect removal target securely: %w", err)
		}
		if !directoryMode(stat.Mode) {
			err = unix.Unlinkat(parentFD, name, 0)
			if errors.Is(err, unix.EISDIR) || errors.Is(err, unix.EPERM) {
				continue
			}
			if err != nil && !errors.Is(err, unix.ENOENT) {
				return fmt.Errorf("remove file securely: %w", err)
			}
			return nil
		}

		dirFD, openErr := unix.Openat(parentFD, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if errors.Is(openErr, unix.ENOENT) || errors.Is(openErr, unix.ENOTDIR) || errors.Is(openErr, unix.ELOOP) {
			continue
		}
		if openErr != nil {
			return fmt.Errorf("open directory for removal securely: %w", openErr)
		}
		dirFile := os.NewFile(uintptr(dirFD), name)
		entries, readErr := dirFile.ReadDir(-1)
		if readErr != nil {
			_ = dirFile.Close()
			return fmt.Errorf("read directory for removal: %w", readErr)
		}
		for _, entry := range entries {
			if err := removeEntry(dirFD, entry.Name()); err != nil {
				_ = dirFile.Close()
				return err
			}
		}
		_ = dirFile.Close()

		err = unix.Unlinkat(parentFD, name, unix.AT_REMOVEDIR)
		if errors.Is(err, unix.ENOTEMPTY) || errors.Is(err, unix.EEXIST) || errors.Is(err, unix.ENOTDIR) || errors.Is(err, unix.ENOENT) {
			if errors.Is(err, unix.ENOENT) {
				return nil
			}
			continue
		}
		if err != nil {
			return fmt.Errorf("remove directory securely: %w", err)
		}
		return nil
	}
	return errors.New("path changed too frequently during secure removal")
}

func (b *linuxSecureBackend) removeAll(rel string) error {
	parentFD, name, err := b.openParent(rel, false)
	if err != nil {
		if errors.Is(err, unix.ENOENT) {
			return nil
		}
		return err
	}
	defer unix.Close(parentFD)
	var stat unix.Stat_t
	if err := unix.Fstatat(parentFD, name, &stat, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		if errors.Is(err, unix.ENOENT) {
			return nil
		}
		return err
	}
	if symlinkMode(stat.Mode) {
		return errors.New("access denied: symbolic links are not allowed")
	}
	return removeEntry(parentFD, name)
}

func (b *linuxSecureBackend) exists(rel string) (bool, error) {
	if rel == "." {
		if err := b.validate(rel); err != nil {
			return false, err
		}
		return true, nil
	}
	parentFD, name, err := b.openParent(rel, false)
	if err != nil {
		if errors.Is(err, unix.ENOENT) {
			return false, nil
		}
		return false, err
	}
	defer unix.Close(parentFD)
	var stat unix.Stat_t
	err = unix.Fstatat(parentFD, name, &stat, unix.AT_SYMLINK_NOFOLLOW)
	if errors.Is(err, unix.ENOENT) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if symlinkMode(stat.Mode) {
		return false, errors.New("access denied: symbolic links are not allowed")
	}
	return true, nil
}
