package models

import "time"

// VPNStatus represents VPN connection status returned by a VPNManager.
type VPNStatus struct {
	Status         string    `json:"status"` // connected, disconnected, connecting
	ProfileID      string    `json:"profileId,omitempty"`
	ActiveProfile  string    `json:"active_profile,omitempty"`
	ConnectedAt    time.Time `json:"connectedAt,omitempty"`
	UploadBytes    int64     `json:"upload_bytes"`
	DownloadBytes  int64     `json:"download_bytes"`
	UploadSpeed    int64     `json:"upload_speed"`
	DownloadSpeed  int64     `json:"download_speed"`
	ConnectionTime int64     `json:"connection_time"`
}

// VPNStats represents VPN traffic statistics returned by a VPNManager.
type VPNStats struct {
	UploadBytes    int64 `json:"upload_bytes"`
	DownloadBytes  int64 `json:"download_bytes"`
	UploadSpeed    int64 `json:"upload_speed"`
	DownloadSpeed  int64 `json:"download_speed"`
	ConnectionTime int64 `json:"connection_time"`
}
