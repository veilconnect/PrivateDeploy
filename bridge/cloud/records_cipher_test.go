package cloud

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
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

func TestRecordsDataKeyProcessHelper(t *testing.T) {
	helperID := os.Getenv("PRIVATEDEPLOY_RECORDS_DEK_HELPER_ID")
	if helperID == "" {
		return
	}
	exchangeDir := os.Getenv("PRIVATEDEPLOY_RECORDS_DEK_HELPER_DIR")
	if exchangeDir == "" {
		t.Fatal("missing helper exchange directory")
	}
	if err := os.WriteFile(filepath.Join(exchangeDir, "ready-"+helperID), []byte("ready"), 0o600); err != nil {
		t.Fatal(err)
	}
	goPath := filepath.Join(exchangeDir, "go")
	deadline := time.Now().Add(10 * time.Second)
	for {
		if _, err := os.Stat(goPath); err == nil {
			break
		} else if !os.IsNotExist(err) {
			t.Fatal(err)
		}
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for parent process barrier")
		}
		time.Sleep(time.Millisecond)
	}

	blob, err := EncodeRecords(map[string]string{"id": helperID, "secret": "secret-" + helperID})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(exchangeDir, "blob-"+helperID), blob, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestConcurrentProcessesFirstEncodeRecordsSharePersistedKey(t *testing.T) {
	secretDir := t.TempDir()
	exchangeDir := t.TempDir()

	baseEnv := make([]string, 0, len(os.Environ())+3)
	for _, entry := range os.Environ() {
		if strings.HasPrefix(entry, secretStoreDirEnv+"=") ||
			strings.HasPrefix(entry, "PRIVATEDEPLOY_RECORDS_DEK_HELPER_ID=") ||
			strings.HasPrefix(entry, "PRIVATEDEPLOY_RECORDS_DEK_HELPER_DIR=") {
			continue
		}
		baseEnv = append(baseEnv, entry)
	}
	baseEnv = append(baseEnv,
		secretStoreDirEnv+"="+secretDir,
		"PRIVATEDEPLOY_RECORDS_DEK_HELPER_DIR="+exchangeDir,
	)

	const processCount = 6
	type processResult struct {
		output bytes.Buffer
		err    error
	}
	results := make([]processResult, processCount)
	var wg sync.WaitGroup
	for i := 0; i < processCount; i++ {
		i := i
		cmd := exec.Command(os.Args[0], "-test.run=^TestRecordsDataKeyProcessHelper$", "-test.count=1")
		cmd.Env = append(append([]string{}, baseEnv...), fmt.Sprintf("PRIVATEDEPLOY_RECORDS_DEK_HELPER_ID=%d", i))
		cmd.Stdout = &results[i].output
		cmd.Stderr = &results[i].output
		wg.Add(1)
		go func() {
			defer wg.Done()
			results[i].err = cmd.Run()
		}()
	}

	deadline := time.Now().Add(10 * time.Second)
	for {
		entries, err := os.ReadDir(exchangeDir)
		if err != nil {
			t.Fatal(err)
		}
		ready := 0
		for _, entry := range entries {
			if strings.HasPrefix(entry.Name(), "ready-") {
				ready++
			}
		}
		if ready == processCount {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("only %d/%d helper processes reached the barrier", ready, processCount)
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err := os.WriteFile(filepath.Join(exchangeDir, "go"), []byte("go"), 0o600); err != nil {
		t.Fatal(err)
	}
	wg.Wait()

	t.Setenv(secretStoreDirEnv, secretDir)
	for i, result := range results {
		if result.err != nil {
			t.Fatalf("helper process %d: %v\n%s", i, result.err, result.output.String())
		}
		blob, err := os.ReadFile(filepath.Join(exchangeDir, fmt.Sprintf("blob-%d", i)))
		if err != nil {
			t.Fatal(err)
		}
		var decoded map[string]string
		if err := DecodeRecords(blob, &decoded); err != nil {
			t.Fatalf("decrypt helper process %d blob: %v", i, err)
		}
		if decoded["id"] != fmt.Sprintf("%d", i) || decoded["secret"] != fmt.Sprintf("secret-%d", i) {
			t.Fatalf("helper process %d decoded %#v", i, decoded)
		}
	}
}
