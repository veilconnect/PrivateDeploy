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

// Service wraps common filesystem helpers rooted at a base directory.
type Service struct {
	basePath string
}

// NewService creates a new filesystem service rooted at basePath.
func NewService(basePath string) *Service {
	return &Service{basePath: filepath.Clean(basePath)}
}

// resolve converts a path to an absolute path and ensures it's within basePath.
// This prevents directory traversal attacks and unauthorized file access.
func (s *Service) resolve(p string) (string, error) {
	var fullPath string
	if filepath.IsAbs(p) {
		fullPath = filepath.Clean(p)
	} else {
		fullPath = filepath.Clean(filepath.Join(s.basePath, p))
	}

	// Ensure the resolved path is within basePath
	// Use Rel to check if the path would escape basePath
	rel, err := filepath.Rel(s.basePath, fullPath)
	if err != nil {
		return "", fmt.Errorf("invalid path: %w", err)
	}

	// Check if the relative path tries to escape (contains "..")
	if strings.HasPrefix(rel, ".."+string(filepath.Separator)) || rel == ".." {
		return "", fmt.Errorf("access denied: path outside base directory: %s", p)
	}

	// Also check for absolute paths outside basePath
	if filepath.IsAbs(p) && !strings.HasPrefix(fullPath, s.basePath) {
		return "", fmt.Errorf("access denied: absolute path outside base directory: %s", p)
	}

	return fullPath, nil
}

// WriteFile writes the provided content to the given path.
func (s *Service) WriteFile(path string, content string, opts Options) error {
	fullPath, err := s.resolve(path)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(fullPath), 0o750); err != nil {
		return err
	}

	data, err := s.decodeContent(content, opts)
	if err != nil {
		return err
	}

	return os.WriteFile(fullPath, data, 0o644)
}

// ReadFile reads a file with the requested mode.
func (s *Service) ReadFile(path string, opts Options) (string, error) {
	fullPath, err := s.resolve(path)
	if err != nil {
		return "", err
	}

	data, err := os.ReadFile(fullPath)
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

// MoveFile renames a file or directory.
func (s *Service) MoveFile(source, target string) error {
	fullSource, err := s.resolve(source)
	if err != nil {
		return err
	}

	fullTarget, err := s.resolve(target)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(fullTarget), 0o750); err != nil {
		return err
	}

	return os.Rename(fullSource, fullTarget)
}

// RemoveFile deletes a file or directory recursively.
func (s *Service) RemoveFile(path string) error {
	fullPath, err := s.resolve(path)
	if err != nil {
		return err
	}
	return os.RemoveAll(fullPath)
}

// CopyFile copies a file from source to destination.
func (s *Service) CopyFile(source, target string) error {
	fullSource, err := s.resolve(source)
	if err != nil {
		return err
	}

	fullTarget, err := s.resolve(target)
	if err != nil {
		return err
	}

	srcFile, err := os.Open(fullSource)
	if err != nil {
		return err
	}
	defer srcFile.Close()

	if err := os.MkdirAll(filepath.Dir(fullTarget), 0o750); err != nil {
		return err
	}

	dstFile, err := os.Create(fullTarget)
	if err != nil {
		return err
	}
	defer dstFile.Close()

	_, err = io.Copy(dstFile, srcFile)
	return err
}

// MakeDir ensures a directory exists.
func (s *Service) MakeDir(path string) error {
	fullPath, err := s.resolve(path)
	if err != nil {
		return err
	}
	return os.MkdirAll(fullPath, 0o750)
}

// ReadDir lists directory entries with minimal metadata.
func (s *Service) ReadDir(path string) ([]DirEntry, error) {
	fullPath, err := s.resolve(path)
	if err != nil {
		return nil, err
	}

	files, err := os.ReadDir(fullPath)
	if err != nil {
		return nil, err
	}

	result := make([]DirEntry, 0, len(files))
	for _, file := range files {
		info, err := file.Info()
		if err != nil {
			continue
		}
		result = append(result, DirEntry{
			Name:  info.Name(),
			Size:  info.Size(),
			IsDir: info.IsDir(),
		})
	}

	return result, nil
}

// AbsolutePath resolves the provided path against the base directory.
func (s *Service) AbsolutePath(path string) (string, error) {
	return s.resolve(path)
}

// UnzipZIPFile extracts a zip archive to the target directory.
func (s *Service) UnzipZIPFile(source, target string) error {
	fullSource, err := s.resolve(source)
	if err != nil {
		return err
	}

	fullTarget, err := s.resolve(target)
	if err != nil {
		return err
	}

	archive, err := zip.OpenReader(fullSource)
	if err != nil {
		return err
	}
	defer archive.Close()

	cleanOutputPath := fullTarget + string(os.PathSeparator)

	for _, f := range archive.File {
		filePath := filepath.Join(fullTarget, f.Name)

		if !strings.HasPrefix(filePath, cleanOutputPath) {
			continue
		}

		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(filePath, 0o750); err != nil {
				return err
			}
			continue
		}

		if err := os.MkdirAll(filepath.Dir(filePath), 0o750); err != nil {
			return err
		}

		src, err := f.Open()
		if err != nil {
			return err
		}

		dst, err := os.OpenFile(filePath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, f.Mode())
		if err != nil {
			src.Close()
			return err
		}

		if _, err := io.Copy(dst, src); err != nil {
			src.Close()
			dst.Close()
			return err
		}

		src.Close()
		dst.Close()
	}

	return nil
}

// UnzipTarGZFile extracts a tar.gz archive.
func (s *Service) UnzipTarGZFile(source, target string) error {
	fullSource, err := s.resolve(source)
	if err != nil {
		return err
	}

	fullTarget, err := s.resolve(target)
	if err != nil {
		return err
	}

	gzipFile, err := os.Open(fullSource)
	if err != nil {
		return err
	}
	defer gzipFile.Close()

	gzipReader, err := gzip.NewReader(gzipFile)
	if err != nil {
		return err
	}
	defer gzipReader.Close()

	tarReader := tar.NewReader(gzipReader)
	cleanOutputPath := fullTarget + string(os.PathSeparator)

	for {
		header, err := tarReader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}

		filePath := filepath.Join(fullTarget, header.Name)
		if !strings.HasPrefix(filePath, cleanOutputPath) {
			continue
		}

		if header.Typeflag == tar.TypeDir {
			if err := os.MkdirAll(filePath, 0o750); err != nil {
				return err
			}
			continue
		}

		if err := os.MkdirAll(filepath.Dir(filePath), 0o750); err != nil {
			return err
		}

		dstFile, err := os.OpenFile(filePath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, header.FileInfo().Mode())
		if err != nil {
			return err
		}

		if _, err := io.Copy(dstFile, tarReader); err != nil {
			dstFile.Close()
			return err
		}
		dstFile.Close()
	}

	return nil
}

// UnzipGZFile decompresses a gz archive to a single file.
func (s *Service) UnzipGZFile(source, target string) error {
	fullSource, err := s.resolve(source)
	if err != nil {
		return err
	}

	fullTarget, err := s.resolve(target)
	if err != nil {
		return err
	}

	gzipFile, err := os.Open(fullSource)
	if err != nil {
		return err
	}
	defer gzipFile.Close()

	outputFile, err := os.Create(fullTarget)
	if err != nil {
		return err
	}
	defer outputFile.Close()

	gzipReader, err := gzip.NewReader(gzipFile)
	if err != nil {
		return err
	}
	defer gzipReader.Close()

	_, err = io.Copy(outputFile, gzipReader)
	return err
}

// FileExists checks if the path exists.
func (s *Service) FileExists(path string) (bool, error) {
	fullPath, err := s.resolve(path)
	if err != nil {
		return false, err
	}

	_, err = os.Stat(fullPath)
	if err == nil {
		return true, nil
	}
	if os.IsNotExist(err) {
		return false, nil
	}
	return false, err
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
