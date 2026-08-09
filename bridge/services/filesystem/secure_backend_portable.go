//go:build !linux

package filesystem

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
)

// portableSecureBackend cannot rely on Linux openat/openat2 semantics. It
// serializes operations issued through this service and validates every path
// component before and after opening. This is deliberately fail-closed for
// links and reparse points while retaining support for macOS and Windows.
type portableSecureBackend struct {
	basePath string
	mu       sync.Mutex
	baseErr  error
}

func newSecureBackend(basePath string) secureBackend {
	backend := &portableSecureBackend{basePath: basePath}
	if err := os.MkdirAll(basePath, 0o700); err != nil {
		backend.baseErr = fmt.Errorf("create application data root: %w", err)
		return backend
	}
	info, err := os.Lstat(basePath)
	if err != nil {
		backend.baseErr = err
	} else if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		backend.baseErr = errors.New("application data root must be a real directory")
	}
	return backend
}

func (b *portableSecureBackend) fullPath(rel string) string {
	if rel == "." || rel == "" {
		return b.basePath
	}
	return filepath.Join(b.basePath, rel)
}

func (b *portableSecureBackend) validateUnlocked(rel string) error {
	if b.baseErr != nil {
		return b.baseErr
	}
	current := b.basePath
	components := relComponents(rel)
	for _, component := range components {
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("inspect path component: %w", err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return errors.New("access denied: symbolic links are not allowed")
		}
	}
	return nil
}

func (b *portableSecureBackend) validate(rel string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.validateUnlocked(rel)
}

func (b *portableSecureBackend) mkdirAllUnlocked(rel string, mode os.FileMode) error {
	if b.baseErr != nil {
		return b.baseErr
	}
	current := b.basePath
	for _, component := range relComponents(rel) {
		current = filepath.Join(current, component)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			if err := os.Mkdir(current, mode.Perm()); err != nil && !errors.Is(err, os.ErrExist) {
				return err
			}
			info, err = os.Lstat(current)
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return errors.New("access denied: path component is not a real directory")
		}
	}
	return b.validateUnlocked(rel)
}

func (b *portableSecureBackend) openRead(rel string) (*os.File, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := b.validateUnlocked(rel); err != nil {
		return nil, err
	}
	fullPath := b.fullPath(rel)
	file, err := os.Open(fullPath)
	if err != nil {
		return nil, err
	}
	openedInfo, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, err
	}
	pathInfo, err := os.Lstat(fullPath)
	if err != nil || pathInfo.Mode()&os.ModeSymlink != 0 || !os.SameFile(openedInfo, pathInfo) || !openedInfo.Mode().IsRegular() {
		file.Close()
		return nil, errors.New("access denied: file changed while it was being opened")
	}
	if err := b.validateUnlocked(rel); err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}

func (b *portableSecureBackend) writeAtomic(rel string, mode os.FileMode, write func(io.Writer) error) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	components := relComponents(rel)
	if len(components) == 0 {
		return errors.New("operation on the application data root is not allowed")
	}
	parentRel := "."
	if len(components) > 1 {
		parentRel = filepath.Join(components[:len(components)-1]...)
	}
	if err := b.mkdirAllUnlocked(parentRel, 0o700); err != nil {
		return err
	}
	target := b.fullPath(rel)
	if info, err := os.Lstat(target); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return errors.New("access denied: target is not a regular file")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(target), ".privatedeploy-*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := write(temporary); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Chmod(mode.Perm()); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := b.validateUnlocked(parentRel); err != nil {
		return err
	}
	if info, err := os.Lstat(target); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return errors.New("access denied: symbolic links are not allowed")
	}
	return os.Rename(temporaryPath, target)
}

func (b *portableSecureBackend) mkdirAll(rel string, mode os.FileMode) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.mkdirAllUnlocked(rel, mode)
}

func (b *portableSecureBackend) readDir(rel string) ([]os.DirEntry, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := b.validateUnlocked(rel); err != nil {
		return nil, err
	}
	fullPath := b.fullPath(rel)
	file, err := os.Open(fullPath)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	openedInfo, err := file.Stat()
	if err != nil || !openedInfo.IsDir() {
		return nil, errors.New("path is not a directory")
	}
	pathInfo, err := os.Lstat(fullPath)
	if err != nil || pathInfo.Mode()&os.ModeSymlink != 0 || !os.SameFile(openedInfo, pathInfo) {
		return nil, errors.New("access denied: directory changed while it was being opened")
	}
	return file.ReadDir(-1)
}

func (b *portableSecureBackend) rename(sourceRel, targetRel string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := b.validateUnlocked(sourceRel); err != nil {
		return err
	}
	targetComponents := relComponents(targetRel)
	parentRel := "."
	if len(targetComponents) > 1 {
		parentRel = filepath.Join(targetComponents[:len(targetComponents)-1]...)
	}
	if err := b.mkdirAllUnlocked(parentRel, 0o700); err != nil {
		return err
	}
	if err := b.validateUnlocked(targetRel); err != nil {
		return err
	}
	return os.Rename(b.fullPath(sourceRel), b.fullPath(targetRel))
}

func (b *portableSecureBackend) removeAll(rel string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := b.validateUnlocked(rel); err != nil {
		return err
	}
	target := b.fullPath(rel)
	info, err := os.Lstat(target)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return errors.New("access denied: symbolic links are not allowed")
	}
	parent := filepath.Dir(target)
	quarantineName, err := randomSecureComponent(".privatedeploy-remove-", "")
	if err != nil {
		return err
	}
	quarantine := filepath.Join(parent, quarantineName)
	if err := os.Rename(target, quarantine); err != nil {
		return err
	}
	return os.RemoveAll(quarantine)
}

func (b *portableSecureBackend) exists(rel string) (bool, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := b.validateUnlocked(rel); err != nil {
		return false, err
	}
	info, err := os.Lstat(b.fullPath(rel))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return false, errors.New("access denied: symbolic links are not allowed")
	}
	return true, nil
}
