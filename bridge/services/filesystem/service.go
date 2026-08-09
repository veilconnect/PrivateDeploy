package filesystem

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// Mode represents the encoding used when reading or writing files.
type Mode string

const (
	ModeBinary Mode = "Binary"
	ModeText   Mode = "Text"
)

// Options configures how file contents are processed.
type Options struct {
	Mode Mode
}

// DirEntry captures minimal metadata about a directory entry.
type DirEntry struct {
	Name  string
	Size  int64
	IsDir bool
}

// Service wraps renderer-accessible filesystem helpers rooted at a base
// directory. All actual I/O goes through secureBackend. In particular,
// AbsolutePath is only a display/compatibility helper and is never used as an
// authorization token for a later pathname-based open.
type Service struct {
	basePath string
	backend  secureBackend
}

// NewService creates a new filesystem service rooted at basePath.
func NewService(basePath string) *Service {
	basePath = filepath.Clean(basePath)
	return &Service{basePath: basePath, backend: newSecureBackend(basePath)}
}

// relative converts a renderer path into a clean path relative to basePath.
// It performs only lexical authorization; the backend enforces the no-link
// boundary atomically with each operation.
func (s *Service) relative(p string) (string, error) {
	if s == nil || s.backend == nil {
		return "", errors.New("filesystem service is not initialized")
	}
	if strings.IndexByte(p, 0) >= 0 {
		return "", errors.New("invalid path: contains NUL byte")
	}
	var fullPath string
	if filepath.IsAbs(p) {
		fullPath = filepath.Clean(p)
	} else {
		fullPath = filepath.Clean(filepath.Join(s.basePath, p))
	}
	rel, err := filepath.Rel(s.basePath, fullPath)
	if err != nil {
		return "", fmt.Errorf("invalid path: %w", err)
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return "", fmt.Errorf("access denied: path outside base directory: %s", p)
	}
	return filepath.Clean(rel), nil
}

// resolve returns a compatibility absolute path after validating every
// currently existing component. Callers must still use Service methods for
// I/O because a pathname cannot carry the backend's race-free guarantee.
func (s *Service) resolve(p string) (string, error) {
	rel, err := s.relative(p)
	if err != nil {
		return "", err
	}
	if err := s.backend.validate(rel); err != nil {
		return "", err
	}
	if rel == "." {
		return s.basePath, nil
	}
	return filepath.Join(s.basePath, rel), nil
}

// OpenRead opens a regular file without following symbolic links. On Linux the
// returned handle was opened relative to the anchored base directory FD, so a
// concurrent symlink swap cannot redirect it outside the data root.
func (s *Service) OpenRead(filePath string) (*os.File, error) {
	rel, err := s.relative(filePath)
	if err != nil {
		return nil, err
	}
	if rel == "." {
		return nil, errors.New("access denied: application data root is not a regular file")
	}
	return s.backend.openRead(rel)
}

// ValidateReadPath performs a fail-fast boundary check before a caller starts
// unrelated work. OpenRead remains the authoritative race-free operation.
func (s *Service) ValidateReadPath(filePath string) error {
	rel, err := s.relative(filePath)
	if err != nil {
		return err
	}
	if rel == "." {
		return errors.New("access denied: application data root is not a regular file")
	}
	return s.backend.validate(rel)
}

// WriteStreamAtomic streams a complete new regular file into the data root.
// The target is published by an atomic rename only after the callback, chmod,
// and fsync have all succeeded; failures leave the previous target untouched.
func (s *Service) WriteStreamAtomic(filePath string, mode os.FileMode, write func(io.Writer) error) error {
	if write == nil {
		return errors.New("write callback is required")
	}
	rel, err := s.relative(filePath)
	if err != nil {
		return err
	}
	if rel == "." {
		return errors.New("access denied: cannot replace the application data root")
	}
	if mode.Perm() == 0 {
		mode = 0o600
	}
	return s.backend.writeAtomic(rel, mode.Perm(), write)
}

// ValidateWritePath performs a cheap fail-fast check for callers that do work
// (such as an HTTP request) before they can stream into WriteStreamAtomic. The
// write itself still performs the authoritative race-free validation.
func (s *Service) ValidateWritePath(filePath string) error {
	rel, err := s.relative(filePath)
	if err != nil {
		return err
	}
	if rel == "." {
		return errors.New("access denied: cannot replace the application data root")
	}
	return s.backend.validate(rel)
}

// WriteFile writes the provided content to the given path atomically.
func (s *Service) WriteFile(filePath string, content string, opts Options) error {
	data, err := s.decodeContent(content, opts)
	if err != nil {
		return err
	}
	return s.WriteStreamAtomic(filePath, 0o600, func(writer io.Writer) error {
		_, err := writer.Write(data)
		return err
	})
}

// ReadFile reads a regular file with the requested mode.
func (s *Service) ReadFile(filePath string, opts Options) (string, error) {
	file, err := s.OpenRead(filePath)
	if err != nil {
		return "", err
	}
	defer file.Close()
	data, err := io.ReadAll(file)
	if err != nil {
		return "", err
	}
	switch opts.Mode {
	case "", ModeText:
		return string(data), nil
	case ModeBinary:
		return base64.StdEncoding.EncodeToString(data), nil
	default:
		return "", fmt.Errorf("unsupported IO mode: %s", opts.Mode)
	}
}

// MoveFile renames a file or directory without following any path links.
func (s *Service) MoveFile(source, target string) error {
	sourceRel, err := s.relative(source)
	if err != nil {
		return err
	}
	if sourceRel == "." {
		return errors.New("access denied: cannot move the application data root")
	}
	targetRel, err := s.relative(target)
	if err != nil {
		return err
	}
	if targetRel == "." {
		return errors.New("access denied: cannot replace the application data root")
	}
	return s.backend.rename(sourceRel, targetRel)
}

// RemoveFile deletes a file or directory recursively without following links.
func (s *Service) RemoveFile(filePath string) error {
	rel, err := s.relative(filePath)
	if err != nil {
		return err
	}
	if rel == "." {
		return errors.New("access denied: cannot remove the application data root")
	}
	return s.backend.removeAll(rel)
}

// CopyFile copies a regular file to an atomically published target.
func (s *Service) CopyFile(source, target string) error {
	sourceFile, err := s.OpenRead(source)
	if err != nil {
		return err
	}
	defer sourceFile.Close()
	return s.WriteStreamAtomic(target, 0o600, func(writer io.Writer) error {
		_, err := io.Copy(writer, sourceFile)
		return err
	})
}

// MakeDir ensures a real directory hierarchy exists below the data root.
func (s *Service) MakeDir(dirPath string) error {
	rel, err := s.relative(dirPath)
	if err != nil {
		return err
	}
	return s.backend.mkdirAll(rel, 0o700)
}

// ReadDir lists directory entries using an anchored directory handle.
func (s *Service) ReadDir(dirPath string) ([]DirEntry, error) {
	rel, err := s.relative(dirPath)
	if err != nil {
		return nil, err
	}
	files, err := s.backend.readDir(rel)
	if err != nil {
		return nil, err
	}
	result := make([]DirEntry, 0, len(files))
	for _, file := range files {
		info, err := file.Info()
		if err != nil {
			continue
		}
		result = append(result, DirEntry{Name: info.Name(), Size: info.Size(), IsDir: info.IsDir()})
	}
	return result, nil
}

// AbsolutePath resolves a display path against the base directory. It must not
// be followed by os.Open/os.WriteFile in security-sensitive code; use OpenRead
// or WriteStreamAtomic instead.
func (s *Service) AbsolutePath(filePath string) (string, error) {
	return s.resolve(filePath)
}

func archiveEntryRelative(targetRel, entryName string) (string, error) {
	if strings.IndexByte(entryName, 0) >= 0 {
		return "", fmt.Errorf("unsafe archive entry: %s", entryName)
	}
	// Treat backslashes as separators on every platform. Otherwise an archive
	// prepared on Unix could become a traversal only when extracted on Windows.
	normalized := strings.ReplaceAll(entryName, "\\", "/")
	cleanName := path.Clean(normalized)
	if cleanName == "." || strings.HasPrefix(cleanName, "/") || cleanName == ".." || strings.HasPrefix(cleanName, "../") {
		return "", fmt.Errorf("unsafe archive entry: %s", entryName)
	}
	if filepath.VolumeName(filepath.FromSlash(cleanName)) != "" {
		return "", fmt.Errorf("unsafe archive entry: %s", entryName)
	}
	return filepath.Join(targetRel, filepath.FromSlash(cleanName)), nil
}

func privateArchiveFileMode(mode os.FileMode) os.FileMode {
	if mode.Perm()&0o111 != 0 {
		return 0o700
	}
	return 0o600
}

// UnzipZIPFile extracts regular files and directories from a zip archive.
func (s *Service) UnzipZIPFile(source, target string) error {
	archiveFile, err := s.OpenRead(source)
	if err != nil {
		return err
	}
	defer archiveFile.Close()
	archiveInfo, err := archiveFile.Stat()
	if err != nil {
		return err
	}
	archive, err := zip.NewReader(archiveFile, archiveInfo.Size())
	if err != nil {
		return err
	}
	targetRel, err := s.relative(target)
	if err != nil {
		return err
	}
	if err := s.backend.mkdirAll(targetRel, 0o700); err != nil {
		return err
	}
	for _, entry := range archive.File {
		entryRel, err := archiveEntryRelative(targetRel, entry.Name)
		if err != nil {
			return err
		}
		mode := entry.Mode()
		if mode.IsDir() {
			if err := s.backend.mkdirAll(entryRel, 0o700); err != nil {
				return err
			}
			continue
		}
		if mode&os.ModeSymlink != 0 || !mode.IsRegular() {
			return fmt.Errorf("unsafe zip entry type: %s", entry.Name)
		}
		err = s.backend.writeAtomic(entryRel, privateArchiveFileMode(mode), func(writer io.Writer) error {
			sourceFile, openErr := entry.Open()
			if openErr != nil {
				return openErr
			}
			defer sourceFile.Close()
			_, copyErr := io.Copy(writer, sourceFile)
			return copyErr
		})
		if err != nil {
			return err
		}
	}
	return nil
}

// UnzipTarGZFile extracts only regular files and directories. Links, devices,
// and other special tar records are rejected rather than materialized.
func (s *Service) UnzipTarGZFile(source, target string) error {
	archiveFile, err := s.OpenRead(source)
	if err != nil {
		return err
	}
	defer archiveFile.Close()
	gzipReader, err := gzip.NewReader(archiveFile)
	if err != nil {
		return err
	}
	defer gzipReader.Close()
	targetRel, err := s.relative(target)
	if err != nil {
		return err
	}
	if err := s.backend.mkdirAll(targetRel, 0o700); err != nil {
		return err
	}
	tarReader := tar.NewReader(gzipReader)
	for {
		header, nextErr := tarReader.Next()
		if errors.Is(nextErr, io.EOF) {
			return nil
		}
		if nextErr != nil {
			return nextErr
		}
		entryRel, err := archiveEntryRelative(targetRel, header.Name)
		if err != nil {
			return err
		}
		switch header.Typeflag {
		case tar.TypeDir:
			if err := s.backend.mkdirAll(entryRel, 0o700); err != nil {
				return err
			}
		case tar.TypeReg, tar.TypeRegA:
			mode := privateArchiveFileMode(os.FileMode(header.Mode))
			if err := s.backend.writeAtomic(entryRel, mode, func(writer io.Writer) error {
				_, copyErr := io.Copy(writer, tarReader)
				return copyErr
			}); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unsafe tar entry type for %s", header.Name)
		}
	}
}

// UnzipGZFile decompresses a gz archive to one atomically published file.
func (s *Service) UnzipGZFile(source, target string) error {
	archiveFile, err := s.OpenRead(source)
	if err != nil {
		return err
	}
	defer archiveFile.Close()
	gzipReader, err := gzip.NewReader(archiveFile)
	if err != nil {
		return err
	}
	defer gzipReader.Close()
	return s.WriteStreamAtomic(target, 0o600, func(writer io.Writer) error {
		_, err := io.Copy(writer, gzipReader)
		return err
	})
}

// FileExists checks whether a non-symlink path exists below the data root.
func (s *Service) FileExists(filePath string) (bool, error) {
	rel, err := s.relative(filePath)
	if err != nil {
		return false, err
	}
	return s.backend.exists(rel)
}

func (s *Service) decodeContent(content string, opts Options) ([]byte, error) {
	switch opts.Mode {
	case "", ModeText:
		return []byte(content), nil
	case ModeBinary:
		data, err := base64.StdEncoding.DecodeString(content)
		if err != nil {
			return nil, err
		}
		return data, nil
	default:
		return nil, fmt.Errorf("unsupported IO mode: %s", opts.Mode)
	}
}
