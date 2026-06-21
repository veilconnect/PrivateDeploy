package cloud

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// Node records hold full protocol credentials (passwords, UUIDs, Reality keys)
// for every provisioned VPS. Previously they were persisted as plaintext JSON
// (protected only by 0600 file permissions). These helpers encrypt the records
// at rest with AES-256-GCM under a per-install data-encryption key kept in the
// same OS secret backend used for cloud API keys (keychain / credential manager
// on macOS+Windows, a 0600 file-backed store on Linux).
//
// Legacy plaintext record files are still readable (DecodeRecords detects the
// envelope and falls back to plain JSON), and are transparently re-encrypted
// the next time the caller saves.

const (
	// recordsEnvelopeMagic prefixes encrypted record blobs so DecodeRecords can
	// distinguish them from legacy plaintext JSON (which starts with '{' or '[').
	recordsEnvelopeMagic = "PDENCv1:"

	// recordsDEKConfigPath / recordsDEKProvider form the stable lookup slot for
	// the shared records data-encryption key in the secret backend.
	recordsDEKConfigPath = "privatedeploy-node-records"
	recordsDEKProvider   = "__records_dek__"
)

// errRecordsKeyMissing indicates the records data-encryption key is not present
// in the secret backend. On the decode path this is fatal (we must not mint a
// new key, which would guarantee a decrypt failure and silently orphan records).
var errRecordsKeyMissing = errors.New("records encryption key not found in secret store")

// recordsDataKey loads the 32-byte AES key used to seal node records from the OS
// secret backend. When createIfMissing is true (encode path) it mints and
// persists one if absent; when false (decode path) it returns
// errRecordsKeyMissing rather than creating a new (useless) key.
func recordsDataKey(createIfMissing bool) ([]byte, error) {
	// Use the same accessor layer as cloud API keys so the DEK honours the
	// PRIVATEDEPLOY_SECRET_STORE_DIR override (headless / tests) and the
	// platform keychain everywhere else.
	if encoded, err := loadProviderAPIKey(recordsDEKConfigPath, recordsDEKProvider); err == nil {
		key, decErr := base64.StdEncoding.DecodeString(encoded)
		if decErr == nil && len(key) == 32 {
			return key, nil
		}
		if !createIfMissing {
			return nil, fmt.Errorf("%w: stored key is corrupt", errRecordsKeyMissing)
		}
		// A corrupt key entry on the encode path: fall through and mint a fresh one.
	} else if errors.Is(err, errSecretNotFound) {
		if !createIfMissing {
			return nil, errRecordsKeyMissing
		}
	} else {
		return nil, err
	}

	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, fmt.Errorf("failed to generate records encryption key: %w", err)
	}
	if err := saveProviderAPIKey(recordsDEKConfigPath, recordsDEKProvider, base64.StdEncoding.EncodeToString(key)); err != nil {
		return nil, fmt.Errorf("failed to persist records encryption key: %w", err)
	}
	return key, nil
}

// EncodeRecords marshals v to JSON and returns an encrypted, file-writable
// blob. The blob is the magic prefix followed by base64(nonce||ciphertext).
func EncodeRecords(v any) ([]byte, error) {
	plain, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return nil, err
	}

	key, err := recordsDataKey(true)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	sealed := gcm.Seal(nonce, nonce, plain, nil)

	out := make([]byte, 0, len(recordsEnvelopeMagic)+base64.StdEncoding.EncodedLen(len(sealed)))
	out = append(out, recordsEnvelopeMagic...)
	out = append(out, []byte(base64.StdEncoding.EncodeToString(sealed))...)
	return out, nil
}

// DecodeRecords unmarshals a record blob into v. It transparently handles both
// the encrypted envelope and legacy plaintext JSON.
func DecodeRecords(data []byte, v any) error {
	if len(data) == 0 {
		return nil
	}

	if !isEncryptedRecords(data) {
		// Legacy plaintext JSON.
		return json.Unmarshal(data, v)
	}

	sealed, err := base64.StdEncoding.DecodeString(string(data[len(recordsEnvelopeMagic):]))
	if err != nil {
		return fmt.Errorf("corrupt encrypted records blob: %w", err)
	}

	// Decode must not mint a new key: if the key is gone, fail loudly rather
	// than create a fresh one that cannot possibly decrypt existing records.
	key, err := recordsDataKey(false)
	if err != nil {
		return err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return err
	}
	if len(sealed) < gcm.NonceSize() {
		return errors.New("corrupt encrypted records blob: too short")
	}
	nonce, ciphertext := sealed[:gcm.NonceSize()], sealed[gcm.NonceSize():]
	plain, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return fmt.Errorf("failed to decrypt records: %w", err)
	}
	return json.Unmarshal(plain, v)
}

// IsEncryptedRecordsFile reports whether on-disk data is already in the
// encrypted envelope format (used to decide whether a re-encrypting rewrite is
// warranted).
func IsEncryptedRecordsFile(data []byte) bool {
	return isEncryptedRecords(data)
}

func isEncryptedRecords(data []byte) bool {
	if len(data) < len(recordsEnvelopeMagic) {
		return false
	}
	return string(data[:len(recordsEnvelopeMagic)]) == recordsEnvelopeMagic
}
