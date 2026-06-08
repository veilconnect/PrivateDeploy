package handlers

import (
	"errors"
	"fmt"
	"strings"
)

var ErrVPNUnsupported = errors.New("vpn control is not available in this build")

// UnsupportedVPNManager surfaces an explicit capability error instead of
// returning simulated VPN state.
type UnsupportedVPNManager struct {
	reason string
}

func NewUnsupportedVPNManager(reason string) *UnsupportedVPNManager {
	trimmed := strings.TrimSpace(reason)
	if trimmed == "" {
		trimmed = "no runtime-integrated VPN backend is configured"
	}
	return &UnsupportedVPNManager{reason: trimmed}
}

func (m *UnsupportedVPNManager) unsupportedError() error {
	return fmt.Errorf("%w: %s", ErrVPNUnsupported, m.reason)
}

func (m *UnsupportedVPNManager) Start(profileID string) error {
	return m.unsupportedError()
}

func (m *UnsupportedVPNManager) Stop() error {
	return m.unsupportedError()
}

func (m *UnsupportedVPNManager) Restart() error {
	return m.unsupportedError()
}

func (m *UnsupportedVPNManager) ResetStats() error {
	return m.unsupportedError()
}

func (m *UnsupportedVPNManager) GetStatus() (*VPNStatus, error) {
	return nil, m.unsupportedError()
}

func (m *UnsupportedVPNManager) GetStats() (*VPNStats, error) {
	return nil, m.unsupportedError()
}
