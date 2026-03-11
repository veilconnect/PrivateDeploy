package utils

import (
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const testSecret = "test-secret-key-for-unit-tests"

// --- GenerateToken ---

func TestGenerateToken_ValidInputsReturnToken(t *testing.T) {
	token, err := GenerateToken(1, "alice", testSecret, time.Hour)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if token == "" {
		t.Fatal("expected non-empty token")
	}
	// JWT format: three dot-separated base64 segments
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("expected 3 JWT segments, got %d", len(parts))
	}
}

func TestGenerateToken_EmptyUsernameAllowed(t *testing.T) {
	_, err := GenerateToken(0, "", testSecret, time.Hour)
	if err != nil {
		t.Fatalf("unexpected error for empty username: %v", err)
	}
}

func TestGenerateToken_EmptySecretAllowed(t *testing.T) {
	// GenerateToken with an empty secret should still produce a token;
	// security enforcement lives in ValidateToken.
	_, err := GenerateToken(1, "alice", "", time.Hour)
	if err != nil {
		t.Fatalf("unexpected error for empty secret: %v", err)
	}
}

// --- ValidateToken: happy path ---

func TestValidateToken_ValidTokenReturnsCorrectClaims(t *testing.T) {
	token, err := GenerateToken(42, "bob", testSecret, time.Hour)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}

	claims, err := ValidateToken(token, testSecret)
	if err != nil {
		t.Fatalf("validate: %v", err)
	}
	if claims.UserID != 42 {
		t.Errorf("UserID: want 42, got %d", claims.UserID)
	}
	if claims.Username != "bob" {
		t.Errorf("Username: want bob, got %s", claims.Username)
	}
}

// --- ValidateToken: expired token ---

func TestValidateToken_ExpiredTokenRejected(t *testing.T) {
	token, err := GenerateToken(1, "alice", testSecret, -time.Second)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}

	_, err = ValidateToken(token, testSecret)
	if err == nil {
		t.Fatal("expected error for expired token, got nil")
	}
}

// --- ValidateToken: wrong secret ---

func TestValidateToken_WrongSecretRejected(t *testing.T) {
	token, err := GenerateToken(1, "alice", testSecret, time.Hour)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}

	_, err = ValidateToken(token, "wrong-secret")
	if err == nil {
		t.Fatal("expected error for wrong secret, got nil")
	}
}

// --- ValidateToken: algorithm confusion (non-HMAC signing method) ---

func TestValidateToken_NonHMACSigningMethodRejected(t *testing.T) {
	// Craft a token signed with RS256 using jwt.UnsafeAllowNoneSignatureType
	// is unavailable for RS256 without a real key, so we use "none" method directly.
	// The safest way to test the guard is to forge a token with alg=none.
	claims := Claims{
		UserID:   1,
		Username: "attacker",
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    jwtIssuer,
			Audience:  jwt.ClaimStrings{jwtIssuer},
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			NotBefore: jwt.NewNumericDate(time.Now()),
		},
	}
	// Build a raw "none"-algorithm token without the jwt library helper
	// to avoid compile-time import restrictions.
	unsignedToken := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	legitimateToken, _ := unsignedToken.SignedString([]byte(testSecret))

	// Replace the header with one declaring alg=RS256 but keep the
	// HS256 signature — the library will still reject it because our
	// key-func checks the *jwt.SigningMethodHMAC type assertion.
	parts := strings.SplitN(legitimateToken, ".", 3)
	if len(parts) != 3 {
		t.Fatal("malformed reference token")
	}

	// Forge a header that claims RS256.
	forgeddHeader := "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9" // {"alg":"RS256","typ":"JWT"}
	forgedToken := forgeddHeader + "." + parts[1] + "." + parts[2]

	_, err := ValidateToken(forgedToken, testSecret)
	if err == nil {
		t.Fatal("expected error for non-HMAC signing method, got nil")
	}
}

// --- ValidateToken: issuer / audience enforcement ---

func TestValidateToken_WrongIssuerRejected(t *testing.T) {
	// Manually craft a token with a different issuer using the same secret.
	claims := jwt.RegisteredClaims{
		Issuer:    "evil-issuer",
		Audience:  jwt.ClaimStrings{jwtIssuer},
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		IssuedAt:  jwt.NewNumericDate(time.Now()),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := token.SignedString([]byte(testSecret))
	if err != nil {
		t.Fatalf("sign: %v", err)
	}

	_, err = ValidateToken(signed, testSecret)
	if err == nil {
		t.Fatal("expected error for wrong issuer, got nil")
	}
}

func TestValidateToken_WrongAudienceRejected(t *testing.T) {
	claims := jwt.RegisteredClaims{
		Issuer:    jwtIssuer,
		Audience:  jwt.ClaimStrings{"wrong-audience"},
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		IssuedAt:  jwt.NewNumericDate(time.Now()),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := token.SignedString([]byte(testSecret))
	if err != nil {
		t.Fatalf("sign: %v", err)
	}

	_, err = ValidateToken(signed, testSecret)
	if err == nil {
		t.Fatal("expected error for wrong audience, got nil")
	}
}

// --- ValidateToken: malformed / empty input ---

func TestValidateToken_EmptyStringRejected(t *testing.T) {
	_, err := ValidateToken("", testSecret)
	if err == nil {
		t.Fatal("expected error for empty token string, got nil")
	}
}

func TestValidateToken_GarbageStringRejected(t *testing.T) {
	_, err := ValidateToken("not.a.jwt", testSecret)
	if err == nil {
		t.Fatal("expected error for garbage token, got nil")
	}
}

func TestValidateToken_TamperedPayloadRejected(t *testing.T) {
	token, err := GenerateToken(1, "alice", testSecret, time.Hour)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}

	// Flip one character in the payload segment
	parts := strings.SplitN(token, ".", 3)
	payload := []byte(parts[1])
	payload[0] ^= 0x01
	tampered := parts[0] + "." + string(payload) + "." + parts[2]

	_, err = ValidateToken(tampered, testSecret)
	if err == nil {
		t.Fatal("expected error for tampered payload, got nil")
	}
}

// --- Round-trip identity ---

func TestGenerateValidateRoundTrip_PreservesAllFields(t *testing.T) {
	const (
		wantUserID   uint   = 99
		wantUsername string = "charlie"
	)
	token, err := GenerateToken(wantUserID, wantUsername, testSecret, 30*time.Minute)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}

	claims, err := ValidateToken(token, testSecret)
	if err != nil {
		t.Fatalf("validate: %v", err)
	}
	if claims.UserID != wantUserID {
		t.Errorf("UserID mismatch: want %d, got %d", wantUserID, claims.UserID)
	}
	if claims.Username != wantUsername {
		t.Errorf("Username mismatch: want %s, got %s", wantUsername, claims.Username)
	}
	if claims.Issuer != jwtIssuer {
		t.Errorf("Issuer mismatch: want %s, got %s", jwtIssuer, claims.Issuer)
	}
}
