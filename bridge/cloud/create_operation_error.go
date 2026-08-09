package cloud

import (
	"errors"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"
)

const maxCreateOperationErrorBytes = 500

var createOperationErrorRedactionPatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?is)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----`),
	regexp.MustCompile(`(?is)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*`),
	regexp.MustCompile(`(?i)\bAuthorization\s*[:=]\s*(Basic|Bearer|Token)?\s*[^\s,;]+`),
	regexp.MustCompile(`(?i)\bBearer\s+[A-Za-z0-9\-._~+/=]+`),
	regexp.MustCompile(`(?i)["']?(password|passwd|pwd|passphrase|api[_-]?key|token|secret|credential)["']?\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;]+)`),
	regexp.MustCompile(`(?i)\bhttps?://[^\s/@:]+:[^\s/@]+@`),
}

// sanitizedCreateOperationError preserves the original error chain for
// errors.Is/errors.As decisions while exposing only a credential-free Error
// string to persistence, logs, IPC, and renderer-facing results.
type sanitizedCreateOperationError struct {
	cause   error
	message string
}

func (err *sanitizedCreateOperationError) Error() string { return err.message }
func (err *sanitizedCreateOperationError) Unwrap() error { return err.cause }

// SanitizeCreateOperationError removes request secrets and common credential
// shapes from a cloud-create error. Every non-empty Extra value is sensitive:
// providers use this open-ended map for SSH auth, tokens, and private keys, and
// guessing from the key name is unsafe. The returned wrapper retains the
// original chain so callers can still test ErrCreateOutcomePending.
func SanitizeCreateOperationError(err error, opts *CreateInstanceOptions) error {
	if err == nil {
		return nil
	}
	var alreadySafe *sanitizedCreateOperationError
	if errors.As(err, &alreadySafe) && alreadySafe == err {
		return err
	}

	message := err.Error()
	secrets := make([]string, 0)
	if opts != nil {
		for _, value := range opts.Extra {
			if value == "" || strings.TrimSpace(value) == "" {
				continue
			}
			secrets = append(secrets, value)
			if trimmed := strings.TrimSpace(value); trimmed != value {
				secrets = append(secrets, trimmed)
			}
		}
	}
	// Replace longer values first so an overlapping short value cannot leave a
	// recognizable suffix of a longer credential behind.
	sort.Slice(secrets, func(i, j int) bool { return len(secrets[i]) > len(secrets[j]) })
	for _, secret := range secrets {
		message = strings.ReplaceAll(message, secret, "[REDACTED]")
	}
	for _, pattern := range createOperationErrorRedactionPatterns {
		message = pattern.ReplaceAllString(message, "[REDACTED]")
	}

	message = strings.ToValidUTF8(message, "�")
	message = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, message)
	message = strings.Join(strings.Fields(message), " ")
	if message == "" {
		message = "cloud create failed"
	}
	if len(message) > maxCreateOperationErrorBytes {
		cut := maxCreateOperationErrorBytes
		for cut > 0 && !utf8.ValidString(message[:cut]) {
			cut--
		}
		message = message[:cut] + "… (truncated)"
	}
	return &sanitizedCreateOperationError{cause: err, message: message}
}

func createOperationErrorMessage(err error, opts *CreateInstanceOptions) string {
	safe := SanitizeCreateOperationError(err, opts)
	if safe == nil {
		return ""
	}
	return safe.Error()
}
