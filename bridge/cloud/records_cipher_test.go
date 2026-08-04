package cloud

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
)

func TestEncodeRecordsRoundTrip(t *testing.T) {
	t.Setenv(secretStoreDirEnv, t.TempDir())

	original := map[string]map[string]string{
		"node-1": {"password": "s3cr3t", "uuid": "abc-123"},
	}

	blob, err := EncodeRecords(original)
	if err != nil {
		t.Fatalf("EncodeRecords: %v", err)
	}
	if !IsEncryptedRecordsFile(blob) {
		t.Fatal("expected blob to be in encrypted envelope format")
	}
	if strings.Contains(string(blob), "s3cr3t") {
		t.Fatal("plaintext credential leaked into encrypted blob")
	}

	var decoded map[string]map[string]string
	if err := DecodeRecords(blob, &decoded); err != nil {
		t.Fatalf("DecodeRecords: %v", err)
	}
	if decoded["node-1"]["password"] != "s3cr3t" || decoded["node-1"]["uuid"] != "abc-123" {
		t.Fatalf("round trip mismatch: %+v", decoded)
	}
}

func TestEncodeRecordsRejectsAndPreservesMalformedExistingDEK(t *testing.T) {
	for _, malformed := range []string{
		"not-base64%%",
		base64.StdEncoding.EncodeToString([]byte("too-short")),
	} {
		malformed := malformed
		t.Run(malformed, func(t *testing.T) {
			t.Setenv(secretStoreDirEnv, t.TempDir())
			if err := SaveSecret(recordsDEKConfigPath, recordsDEKProvider, malformed); err != nil {
				t.Fatalf("seed malformed DEK: %v", err)
			}

			if _, err := EncodeRecords(map[string]string{"secret": "value"}); err == nil || !strings.Contains(err.Error(), "corrupt") {
				t.Fatalf("EncodeRecords error = %v, want corrupt-key failure", err)
			}

			got, err := LoadSecret(recordsDEKConfigPath, recordsDEKProvider)
			if err != nil {
				t.Fatalf("reload malformed DEK: %v", err)
			}
			if got != malformed {
				t.Fatalf("malformed DEK was overwritten: got %q, want %q", got, malformed)
			}
		})
	}
}

func TestDecodeRecordsReadsLegacyPlaintext(t *testing.T) {
	t.Setenv(secretStoreDirEnv, t.TempDir())

	legacy := map[string]string{"k": "v"}
	plain, err := json.MarshalIndent(legacy, "", "  ")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if IsEncryptedRecordsFile(plain) {
		t.Fatal("legacy plaintext should not be detected as encrypted")
	}

	var decoded map[string]string
	if err := DecodeRecords(plain, &decoded); err != nil {
		t.Fatalf("DecodeRecords legacy: %v", err)
	}
	if decoded["k"] != "v" {
		t.Fatalf("legacy decode mismatch: %+v", decoded)
	}
}

func TestDecodeRecordsEmpty(t *testing.T) {
	var decoded map[string]string
	if err := DecodeRecords(nil, &decoded); err != nil {
		t.Fatalf("DecodeRecords(nil): %v", err)
	}
}

func TestDecodeRecordsFailsWhenKeyMissing(t *testing.T) {
	// Encode with a key in store A.
	t.Setenv(secretStoreDirEnv, t.TempDir())
	blob, err := EncodeRecords(map[string]string{"k": "v"})
	if err != nil {
		t.Fatalf("EncodeRecords: %v", err)
	}

	// Simulate a lost key (fresh secret store with no DEK). Decode must error
	// rather than mint a new key and silently fail to decrypt.
	t.Setenv(secretStoreDirEnv, t.TempDir())
	var decoded map[string]string
	if err := DecodeRecords(blob, &decoded); err == nil {
		t.Fatal("expected DecodeRecords to fail when the data key is missing")
	}
}

func TestConcurrentFirstEncodeRecordsSharePersistedKey(t *testing.T) {
	t.Setenv(secretStoreDirEnv, t.TempDir())

	const recordCount = 128
	type record struct {
		ID     int    `json:"id"`
		Secret string `json:"secret"`
	}
	type result struct {
		blob []byte
		err  error
	}

	start := make(chan struct{})
	results := make([]result, recordCount)
	var wg sync.WaitGroup
	wg.Add(recordCount)
	for i := 0; i < recordCount; i++ {
		i := i
		go func() {
			defer wg.Done()
			<-start
			results[i].blob, results[i].err = EncodeRecords(record{
				ID:     i,
				Secret: fmt.Sprintf("secret-%d", i),
			})
		}()
	}
	close(start)
	wg.Wait()

	// Every independently encoded record must be decryptable with the single
	// DEK that remains in the shared secret slot after first initialization.
	for i, result := range results {
		if result.err != nil {
			t.Fatalf("EncodeRecords(%d): %v", i, result.err)
		}

		var decoded record
		if err := DecodeRecords(result.blob, &decoded); err != nil {
			t.Fatalf("DecodeRecords(%d): %v", i, err)
		}
		if decoded.ID != i || decoded.Secret != fmt.Sprintf("secret-%d", i) {
			t.Fatalf("record %d round trip mismatch: %+v", i, decoded)
		}
	}
}
