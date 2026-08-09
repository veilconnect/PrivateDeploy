package cloud

import (
	"errors"
	"strings"
	"testing"
)

func TestSanitizeCreateOperationErrorRedactsSecretsAndPreservesCause(t *testing.T) {
	const (
		extraSecret  = "EXTRA-SECRET-VALUE"
		bearerSecret = "bearer.secret-token"
		apiSecret    = "API-SECRET-99"
	)
	original := errors.Join(
		ErrCreateOutcomePending,
		errors.New("provider rejected password="+extraSecret+
			"; Authorization: Bearer "+bearerSecret+
			"; api_key="+apiSecret+"\n\x1b[31munsafe"),
	)
	safe := SanitizeCreateOperationError(original, &CreateInstanceOptions{
		Extra: map[string]string{"customAuth": extraSecret},
	})
	if !errors.Is(safe, ErrCreateOutcomePending) {
		t.Fatalf("sanitized error lost pending sentinel: %v", safe)
	}
	message := safe.Error()
	for index, secret := range []string{extraSecret, bearerSecret, apiSecret} {
		if strings.Contains(message, secret) {
			t.Fatalf("sanitized error leaked test credential #%d", index+1)
		}
	}
	if strings.ContainsAny(message, "\n\r\t\x1b") {
		t.Fatalf("sanitized error retained control characters: %q", message)
	}
	if !strings.Contains(message, "provider rejected") || !strings.Contains(message, "[REDACTED]") {
		t.Fatalf("sanitized error lost useful context: %q", message)
	}
}

func TestSanitizeCreateOperationErrorCapsOutput(t *testing.T) {
	safe := SanitizeCreateOperationError(errors.New(strings.Repeat("a", 2000)), nil)
	if safe == nil || len(safe.Error()) > maxCreateOperationErrorBytes+len("… (truncated)") {
		t.Fatalf("sanitized error was not bounded: len=%d", len(safe.Error()))
	}
}
