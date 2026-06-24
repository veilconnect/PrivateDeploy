package vultr

import (
	"encoding/base64"
	"testing"
)

func TestDecodeUserDataPayload(t *testing.T) {
	encoded := base64.StdEncoding.EncodeToString([]byte("#!/bin/bash\necho hi"))

	if got := decodeUserDataPayload(map[string]any{
		"user_data": encoded,
	}); got != encoded {
		t.Fatalf("unexpected direct payload: %q", got)
	}

	if got := decodeUserDataPayload(map[string]any{
		"user_data": map[string]any{"data": encoded},
	}); got != encoded {
		t.Fatalf("unexpected nested payload: %q", got)
	}
}
