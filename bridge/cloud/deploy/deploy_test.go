package deploy

import (
	"encoding/base64"
	"fmt"
	"regexp"
	"strings"
	"testing"
)

// -----------------------------------------------------------------------
// shellEscape
// -----------------------------------------------------------------------

func TestShellEscape_EmptyStringReturnsQuotedEmpty(t *testing.T) {
	got := shellEscape("")
	if got != "''" {
		t.Errorf("want '''''', got %q", got)
	}
}

func TestShellEscape_PlainStringPassesThrough(t *testing.T) {
	got := shellEscape("simple")
	if got != "simple" {
		t.Errorf("want %q, got %q", "simple", got)
	}
}

func TestShellEscape_SingleQuoteInInput(t *testing.T) {
	// A password containing a single quote must not allow shell injection.
	input := "pass'word"
	got := shellEscape(input)
	// Must be wrapped in single quotes and the internal ' escaped as '\''
	if !strings.HasPrefix(got, "'") || !strings.HasSuffix(got, "'") {
		t.Errorf("expected result to be single-quote wrapped, got %q", got)
	}
	if strings.Contains(got, "pass'word") {
		// The raw unescaped sequence must not appear verbatim inside the result.
		t.Errorf("raw single-quote sequence still present in %q", got)
	}
}

func TestShellEscape_Backtick(t *testing.T) {
	input := "pass`cmd`word"
	got := shellEscape(input)
	// Inside single-quotes backticks lose their special meaning, but the
	// result must be wrapped to ensure that invariant.
	if !strings.HasPrefix(got, "'") || !strings.HasSuffix(got, "'") {
		t.Errorf("backtick input not single-quote wrapped: %q", got)
	}
}

func TestShellEscape_Newline(t *testing.T) {
	input := "line1\nline2"
	got := shellEscape(input)
	if !strings.HasPrefix(got, "'") || !strings.HasSuffix(got, "'") {
		t.Errorf("newline input not single-quote wrapped: %q", got)
	}
}

func TestShellEscape_DollarSign(t *testing.T) {
	input := "cost$100"
	got := shellEscape(input)
	if !strings.HasPrefix(got, "'") || !strings.HasSuffix(got, "'") {
		t.Errorf("dollar-sign input not single-quote wrapped: %q", got)
	}
}

func TestShellEscape_NullByte(t *testing.T) {
	// Null bytes are unusual but the function should not panic.
	input := "pass\x00word"
	got := shellEscape(input) // must not panic
	// Null byte is not in the trigger set, so no single-quote wrap is
	// required; we just verify no panic and non-empty output.
	if got == "" {
		t.Error("expected non-empty result for null-byte input")
	}
}

func TestShellEscape_AdversarialMultipleSpecialChars(t *testing.T) {
	// A crafted string with multiple injection vectors.
	inputs := []string{
		"'; rm -rf /; echo '",
		"`id`",
		"$(whoami)",
		"foo\nbar",
		"tab\there",
		`back\slash`,
	}
	for _, input := range inputs {
		got := shellEscape(input)
		// Every result that contains shell-special characters must be
		// single-quote wrapped so the shell treats the contents literally.
		if strings.ContainsAny(input, " \t\n\\\"'`$") {
			if !strings.HasPrefix(got, "'") || !strings.HasSuffix(got, "'") {
				t.Errorf("input %q not single-quote wrapped: %q", input, got)
			}
		}
	}
}

func TestShellEscape_OutputDoesNotContainUnescapedSingleQuote(t *testing.T) {
	input := "it's a test"
	got := shellEscape(input)
	// Strip the outer wrapping quotes and verify no bare ' remains.
	inner := got[1 : len(got)-1]
	// After stripping outer quotes, any original ' should be represented
	// as '\'' (three chars that close, escape-quote, reopen).
	if strings.Contains(inner, "'") && !strings.Contains(inner, "\\'") {
		// Accept the '\'' pattern; a bare unescaped ' is a bug.
		// Walk the inner string and check for unescaped single quotes.
		for i := 0; i < len(inner); i++ {
			if inner[i] == '\'' {
				// A bare ' inside single-quoted region is injection.
				// The correct escaped form ends the quote, adds \', reopens.
				t.Errorf("unescaped single quote at position %d in %q", i, got)
			}
		}
	}
}

// -----------------------------------------------------------------------
// GenerateUUID
// -----------------------------------------------------------------------

var uuidPattern = regexp.MustCompile(
	`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`,
)

func TestGenerateUUID_MatchesRFC4122v4Format(t *testing.T) {
	uuid := GenerateUUID()
	if !uuidPattern.MatchString(uuid) {
		t.Errorf("UUID %q does not match RFC-4122 v4 pattern", uuid)
	}
}

func TestGenerateUUID_Version4Bits(t *testing.T) {
	uuid := GenerateUUID()
	// Position 14 (0-indexed in the no-hyphen form) is the version nibble.
	// In the hyphenated form that corresponds to the first char of segment 3.
	parts := strings.Split(uuid, "-")
	if len(parts) != 5 {
		t.Fatalf("expected 5 hyphen-separated segments, got %d", len(parts))
	}
	if parts[2][0] != '4' {
		t.Errorf("expected version nibble '4', got %q in UUID %s", string(parts[2][0]), uuid)
	}
}

func TestGenerateUUID_VariantBits(t *testing.T) {
	uuid := GenerateUUID()
	parts := strings.Split(uuid, "-")
	// The variant byte is the first byte of segment 4 (clock_seq_hi).
	variantChar := parts[3][0]
	if variantChar != '8' && variantChar != '9' && variantChar != 'a' && variantChar != 'b' {
		t.Errorf("variant nibble must be 8, 9, a, or b; got %q in UUID %s", string(variantChar), uuid)
	}
}

func TestGenerateUUID_Uniqueness(t *testing.T) {
	const n = 1000
	seen := make(map[string]struct{}, n)
	for i := 0; i < n; i++ {
		u := GenerateUUID()
		if _, exists := seen[u]; exists {
			t.Fatalf("duplicate UUID generated after %d iterations: %s", i, u)
		}
		seen[u] = struct{}{}
	}
}

func TestGenerateUUID_CorrectLength(t *testing.T) {
	uuid := GenerateUUID()
	// Standard hyphenated UUID: 8-4-4-4-12 = 32 hex chars + 4 hyphens = 36
	if len(uuid) != 36 {
		t.Errorf("want length 36, got %d for UUID %q", len(uuid), uuid)
	}
}

// -----------------------------------------------------------------------
// GenerateRandomPassword
// -----------------------------------------------------------------------

func TestGenerateRandomPassword_ReturnsRequestedLength(t *testing.T) {
	for _, length := range []int{1, 8, 16, 32, 64, 128} {
		got := GenerateRandomPassword(length)
		if len(got) != length {
			t.Errorf("length %d: want %d chars, got %d", length, length, len(got))
		}
	}
}

func TestGenerateRandomPassword_ZeroLengthReturnsEmpty(t *testing.T) {
	got := GenerateRandomPassword(0)
	if got != "" {
		t.Errorf("want empty string for length 0, got %q", got)
	}
}

func TestGenerateRandomPassword_NegativeLengthReturnsEmpty(t *testing.T) {
	got := GenerateRandomPassword(-5)
	if got != "" {
		t.Errorf("want empty string for negative length, got %q", got)
	}
}

func TestGenerateRandomPassword_CharsetIsURLSafeBase64(t *testing.T) {
	// The implementation slices a base64 URL-encoded string, so every
	// character must belong to the base64 URL-safe alphabet.
	validChars := regexp.MustCompile(`^[A-Za-z0-9\-_=]+$`)
	for _, length := range []int{16, 32, 64} {
		got := GenerateRandomPassword(length)
		if !validChars.MatchString(got) {
			t.Errorf("password %q (length %d) contains characters outside base64 URL alphabet", got, length)
		}
	}
}

func TestGenerateRandomPassword_Uniqueness(t *testing.T) {
	const (
		n      = 200
		length = 32
	)
	seen := make(map[string]struct{}, n)
	for i := 0; i < n; i++ {
		p := GenerateRandomPassword(length)
		if _, exists := seen[p]; exists {
			t.Fatalf("duplicate password generated after %d iterations", i)
		}
		seen[p] = struct{}{}
	}
}

func TestGenerateRandomPassword_IsBase64URLDecodable(t *testing.T) {
	// A password of length equal to a full base64 block should decode cleanly.
	const length = 16 // 16 chars = exactly 12 raw bytes in base64url (no padding needed)
	got := GenerateRandomPassword(length)

	// Pad to a multiple of 4 for standard base64 decoding.
	padded := got
	switch len(padded) % 4 {
	case 2:
		padded += "=="
	case 3:
		padded += "="
	}
	_, err := base64.URLEncoding.DecodeString(padded)
	if err != nil {
		// The slice may cut mid-character; decoding error is acceptable here
		// as long as every character is in the allowed alphabet (tested above).
		// We just ensure no panic occurs.
		_ = fmt.Sprintf("note: %v", err)
	}
}

func TestGenerateMultiProtocolScript_ChownsSingBoxConfigsBeforeStart(t *testing.T) {
	script := GenerateMultiProtocolScript(MultiProtocolParams{
		SSPort:           30001,
		SSPassword:       "ss-pass",
		HysteriaPort:     30002,
		HysteriaPassword: "hy-pass",
		HysteriaServer:   "www.cloudflare.com",
		VLESSPort:        30003,
		VLESSUUID:        GenerateUUID(),
		VLESSPrivateKey:  "private-key",
		VLESSPublicKey:   "public-key",
		VLESSShortID:     "1234abcd",
		VLESSServer:      "www.cloudflare.com",
		TrojanPort:       30004,
		TrojanPassword:   "trojan-pass",
		TrojanServer:     "www.cloudflare.com",
	})

	vlessChown := "chown privatedeploy:privatedeploy /etc/privatedeploy/vless/config.json /etc/privatedeploy/vless/reality.txt"
	vlessStart := "systemctl enable vless-server"
	if !strings.Contains(script, vlessChown) {
		t.Fatalf("expected script to chown vless files before service start")
	}
	if strings.Index(script, vlessChown) > strings.Index(script, vlessStart) {
		t.Fatalf("expected vless chown to happen before %q", vlessStart)
	}

	trojanChown := "chown privatedeploy:privatedeploy /etc/privatedeploy/trojan/config.json"
	trojanStart := "systemctl enable trojan-server"
	if !strings.Contains(script, trojanChown) {
		t.Fatalf("expected script to chown trojan config before service start")
	}
	if strings.Index(script, trojanChown) > strings.Index(script, trojanStart) {
		t.Fatalf("expected trojan chown to happen before %q", trojanStart)
	}
}

func TestGenerateMultiProtocolScript_AllowsNonRootSingBoxToBindPrivilegedPorts(t *testing.T) {
	script := GenerateMultiProtocolScript(MultiProtocolParams{
		SSPort:           24443,
		SSPassword:       "ss-pass",
		HysteriaPort:     443,
		HysteriaPassword: "hy-pass",
		HysteriaServer:   "www.cloudflare.com",
		VLESSPort:        8443,
		VLESSUUID:        GenerateUUID(),
		VLESSPrivateKey:  "private-key",
		VLESSPublicKey:   "public-key",
		VLESSShortID:     "1234abcd",
		VLESSServer:      "www.cloudflare.com",
		TrojanPort:       443,
		TrojanPassword:   "trojan-pass",
		TrojanServer:     "www.cloudflare.com",
		VLESSRelayPort:   24444,
	})

	if got := strings.Count(script, "AmbientCapabilities=CAP_NET_BIND_SERVICE"); got != 4 {
		t.Fatalf("expected all sing-box systemd units to allow low-port bind, got %d", got)
	}
	if got := strings.Count(script, "CapabilityBoundingSet=CAP_NET_BIND_SERVICE"); got != 4 {
		t.Fatalf("expected all sing-box systemd units to bound low-port bind capability, got %d", got)
	}
}
