package ssh

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	gossh "golang.org/x/crypto/ssh"
)

const knownHostsRelPath = "data/cloud/ssh-known-hosts.json"

var sshHostKeysMu sync.Mutex

type hostKeyRecord struct {
	PublicKey string `json:"publicKey"`
	AddedAt   string `json:"addedAt"`
}

func defaultKnownHostsPath() string {
	basePath := strings.TrimSpace(os.Getenv("PRIVATEDEPLOY_BASE_PATH"))
	if basePath == "" {
		basePath, _ = os.Getwd()
	}
	return filepath.Join(basePath, knownHostsRelPath)
}

func trustOnFirstUseHostKeyCallback(storePath string) gossh.HostKeyCallback {
	path := strings.TrimSpace(storePath)
	if path == "" {
		path = defaultKnownHostsPath()
	}

	return func(hostname string, remoteAddr net.Addr, key gossh.PublicKey) error {
		storeKey := normalizedHostKeyStoreKey(hostname, remoteAddr)
		if storeKey == "" {
			return fmt.Errorf("missing SSH host identifier")
		}

		authorizedKey := strings.TrimSpace(string(gossh.MarshalAuthorizedKey(key)))
		if authorizedKey == "" {
			return fmt.Errorf("missing SSH host public key for %s", storeKey)
		}

		sshHostKeysMu.Lock()
		defer sshHostKeysMu.Unlock()

		records, err := loadHostKeyRecords(path)
		if err != nil {
			return err
		}

		if existing, ok := records[storeKey]; ok {
			if existing.PublicKey != authorizedKey {
				return fmt.Errorf("SSH host key mismatch for %s", storeKey)
			}
			return nil
		}

		records[storeKey] = hostKeyRecord{
			PublicKey: authorizedKey,
			AddedAt:   time.Now().UTC().Format(time.RFC3339),
		}
		if err := saveHostKeyRecords(path, records); err != nil {
			return err
		}

		return nil
	}
}

func normalizedHostKeyStoreKey(hostname string, remoteAddr net.Addr) string {
	value := strings.TrimSpace(hostname)
	if value == "" && remoteAddr != nil {
		value = strings.TrimSpace(remoteAddr.String())
	}
	return strings.ToLower(value)
}

func loadHostKeyRecords(path string) (map[string]hostKeyRecord, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]hostKeyRecord{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read SSH host key store: %w", err)
	}
	if len(data) == 0 {
		return map[string]hostKeyRecord{}, nil
	}

	records := map[string]hostKeyRecord{}
	if err := json.Unmarshal(data, &records); err != nil {
		return nil, fmt.Errorf("parse SSH host key store: %w", err)
	}
	return records, nil
}

func saveHostKeyRecords(path string, records map[string]hostKeyRecord) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create SSH host key store dir: %w", err)
	}

	data, err := json.MarshalIndent(records, "", "  ")
	if err != nil {
		return fmt.Errorf("encode SSH host key store: %w", err)
	}

	if err := os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("write SSH host key store: %w", err)
	}
	return nil
}
