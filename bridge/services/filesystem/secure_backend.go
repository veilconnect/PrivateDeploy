package filesystem

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// secureBackend performs every renderer-accessible filesystem operation below
// an already-selected application data root.  Linux uses directory file
// descriptors for this interface so a path can never be redirected by a
// concurrent symlink swap between validation and use.
type secureBackend interface {
	validate(rel string) error
	openRead(rel string) (*os.File, error)
	writeAtomic(rel string, mode os.FileMode, write func(io.Writer) error) error
	mkdirAll(rel string, mode os.FileMode) error
	readDir(rel string) ([]os.DirEntry, error)
	rename(sourceRel, targetRel string) error
	removeAll(rel string) error
	exists(rel string) (bool, error)
}

func relComponents(rel string) []string {
	if rel == "." || rel == "" {
		return nil
	}
	return strings.Split(filepath.ToSlash(rel), "/")
}

func randomSecureComponent(prefix, suffix string) (string, error) {
	var token [16]byte
	if _, err := rand.Read(token[:]); err != nil {
		return "", fmt.Errorf("generate secure temporary name: %w", err)
	}
	return prefix + hex.EncodeToString(token[:]) + suffix, nil
}
