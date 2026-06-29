package handlers

import (
	"sync"
	"time"

	"privatedeploy/api/models"
)

// InMemoryVPNManager is a lightweight VPN manager for API compatibility.
type InMemoryVPNManager struct {
	mu          sync.RWMutex
	status      string
	profileID   string
	connected   time.Time
	upload      int64
	download    int64
	uploadSpd   int64
	downloadSpd int64
}

// NewInMemoryVPNManager creates a new in-memory VPN manager.
func NewInMemoryVPNManager() *InMemoryVPNManager {
	return &InMemoryVPNManager{
		status: "disconnected",
	}
}

func (m *InMemoryVPNManager) Start(profileID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.status = "connected"
	m.profileID = profileID
	m.connected = time.Now()
	m.uploadSpd = 128 * 1024
	m.downloadSpd = 512 * 1024
	return nil
}

func (m *InMemoryVPNManager) Stop() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.status = "disconnected"
	m.profileID = ""
	m.connected = time.Time{}
	m.uploadSpd = 0
	m.downloadSpd = 0
	return nil
}

func (m *InMemoryVPNManager) Restart() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.profileID == "" {
		m.profileID = "default"
	}
	m.status = "connected"
	m.connected = time.Now()
	m.uploadSpd = 128 * 1024
	m.downloadSpd = 512 * 1024
	return nil
}

func (m *InMemoryVPNManager) ResetStats() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.upload = 0
	m.download = 0
	return nil
}

func (m *InMemoryVPNManager) GetStatus() (*models.VPNStatus, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Simulate traffic increments while connected.
	if m.status == "connected" {
		m.upload += m.uploadSpd / 2
		m.download += m.downloadSpd / 2
	}

	return &models.VPNStatus{
		Status:         m.status,
		ProfileID:      m.profileID,
		ActiveProfile:  m.profileID,
		ConnectedAt:    m.connected,
		UploadBytes:    m.upload,
		DownloadBytes:  m.download,
		UploadSpeed:    m.uploadSpd,
		DownloadSpeed:  m.downloadSpd,
		ConnectionTime: connectionDurationSeconds(m.connected),
	}, nil
}

func (m *InMemoryVPNManager) GetStats() (*models.VPNStats, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.status == "connected" {
		m.upload += m.uploadSpd / 3
		m.download += m.downloadSpd / 3
	}

	return &models.VPNStats{
		UploadBytes:    m.upload,
		DownloadBytes:  m.download,
		UploadSpeed:    m.uploadSpd,
		DownloadSpeed:  m.downloadSpd,
		ConnectionTime: connectionDurationSeconds(m.connected),
	}, nil
}

func connectionDurationSeconds(start time.Time) int64 {
	if start.IsZero() {
		return 0
	}
	return int64(time.Since(start).Seconds())
}
