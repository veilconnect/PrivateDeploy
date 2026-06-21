package cloud

import (
	"encoding/json"
	"strings"
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
