package catalog

import (
	"context"
	cryptorand "crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"privatedeploy/bridge/cloud"
)

type contaboCredentials struct {
	ClientID     string
	ClientSecret string
	Username     string
	Password     string
}

func (p *Provider) contaboCredentials(cfg *cloud.ProviderConfig) (contaboCredentials, error) {
	if cfg == nil {
		return contaboCredentials{}, cloud.ErrInvalidConfig
	}
	extra := cfg.Extra
	obj := parseAPIKeyObject(cfg.APIKey)

	creds := contaboCredentials{
		ClientID: firstNonEmpty(
			strings.TrimSpace(extra["clientId"]),
			strings.TrimSpace(extra["client_id"]),
			strings.TrimSpace(extra["oauthClientId"]),
			lookupMapValue(obj, "clientid", "client_id", "oauthclientid"),
		),
		ClientSecret: firstNonEmpty(
			strings.TrimSpace(extra["clientSecret"]),
			strings.TrimSpace(extra["client_secret"]),
			strings.TrimSpace(extra["oauthClientSecret"]),
			lookupMapValue(obj, "clientsecret", "client_secret", "oauthclientsecret"),
		),
		Username: firstNonEmpty(
			strings.TrimSpace(extra["username"]),
			strings.TrimSpace(extra["user"]),
			strings.TrimSpace(extra["apiUser"]),
			strings.TrimSpace(extra["api_user"]),
			lookupMapValue(obj, "username", "user", "apiuser", "api_user"),
		),
		Password: firstNonEmpty(
			strings.TrimSpace(extra["password"]),
			strings.TrimSpace(extra["apiPassword"]),
			strings.TrimSpace(extra["api_password"]),
			lookupMapValue(obj, "password", "apipassword", "api_password"),
		),
	}

	if creds.ClientID == "" || creds.ClientSecret == "" || creds.Username == "" || creds.Password == "" {
		parts := strings.SplitN(strings.TrimSpace(cfg.APIKey), "|", 4)
		if len(parts) == 4 {
			if creds.ClientID == "" {
				creds.ClientID = strings.TrimSpace(parts[0])
			}
			if creds.ClientSecret == "" {
				creds.ClientSecret = strings.TrimSpace(parts[1])
			}
			if creds.Username == "" {
				creds.Username = strings.TrimSpace(parts[2])
			}
			if creds.Password == "" {
				creds.Password = strings.TrimSpace(parts[3])
			}
		}
	}

	if creds.ClientID == "" || creds.ClientSecret == "" || creds.Username == "" || creds.Password == "" {
		return contaboCredentials{}, fmt.Errorf("contabo credentials are incomplete: use API key format 'client_id|client_secret|username|password' or provide values in extra")
	}
	return creds, nil
}

func (p *Provider) contaboAccessToken(ctx context.Context, cfg *cloud.ProviderConfig) (string, error) {
	p.tokenMu.Lock()
	if strings.TrimSpace(p.token) != "" && time.Now().Before(p.tokenExpiry) {
		token := p.token
		p.tokenMu.Unlock()
		return token, nil
	}
	p.tokenMu.Unlock()

	creds, err := p.contaboCredentials(cfg)
	if err != nil {
		return "", err
	}

	form := url.Values{}
	form.Set("client_id", creds.ClientID)
	form.Set("client_secret", creds.ClientSecret)
	form.Set("username", creds.Username)
	form.Set("password", creds.Password)
	form.Set("grant_type", "password")

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, contaboAuthTokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := p.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("%w: %v", cloud.ErrAPIRequestFailed, err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("contabo token request failed: status=%d body=%s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var payload struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return "", err
	}
	token := strings.TrimSpace(payload.AccessToken)
	if token == "" {
		return "", fmt.Errorf("contabo token response missing access_token")
	}
	exp := time.Now().Add(30 * time.Minute)
	if payload.ExpiresIn > 120 {
		exp = time.Now().Add(time.Duration(payload.ExpiresIn-60) * time.Second)
	}

	p.tokenMu.Lock()
	p.token = token
	p.tokenExpiry = exp
	p.tokenMu.Unlock()

	return token, nil
}

func pseudoUUIDv4() string {
	buf := make([]byte, 16)
	if _, err := cryptorand.Read(buf); err != nil {
		now := time.Now().UnixNano()
		return fmt.Sprintf("pd-%x", now)
	}
	buf[6] = (buf[6] & 0x0f) | 0x40
	buf[8] = (buf[8] & 0x3f) | 0x80
	hexRaw := hex.EncodeToString(buf)
	return fmt.Sprintf("%s-%s-%s-%s-%s", hexRaw[0:8], hexRaw[8:12], hexRaw[12:16], hexRaw[16:20], hexRaw[20:32])
}
