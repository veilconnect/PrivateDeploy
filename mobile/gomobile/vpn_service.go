package gomobile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/option"
)

// VPNService 提供移动端可调用的 VPN 服务接口
// 该接口通过 gomobile bind 暴露给 Android 和 iOS
type VPNService struct {
	mu       sync.RWMutex
	instance *box.Box
	config   *option.Options
	ctx      context.Context
	cancel   context.CancelFunc
	running  bool
	stats    *TrafficStats
}

// TrafficStats 流量统计数据
type TrafficStats struct {
	UploadBytes   int64  `json:"upload_bytes"`
	DownloadBytes int64  `json:"download_bytes"`
	UploadSpeed   int64  `json:"upload_speed"`   // bytes per second
	DownloadSpeed int64  `json:"download_speed"` // bytes per second
	ConnectedAt   int64  `json:"connected_at"`   // Unix timestamp
}

// NewVPNService 创建新的 VPN 服务实例
func NewVPNService() *VPNService {
	return &VPNService{
		stats: &TrafficStats{},
	}
}

// Start 启动 VPN 服务
// configJSON: JSON 格式的 sing-box 配置
// 返回: 错误信息，成功返回 nil
func (s *VPNService) Start(configJSON string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.running {
		return errors.New("VPN is already running")
	}

	// 解析配置
	var options option.Options
	if err := json.Unmarshal([]byte(configJSON), &options); err != nil {
		return fmt.Errorf("failed to parse config: %w", err)
	}

	// 创建上下文
	s.ctx, s.cancel = context.WithCancel(context.Background())

	// 创建 sing-box 实例
	instance, err := box.New(box.Options{
		Context: s.ctx,
		Options: options,
	})
	if err != nil {
		s.cancel()
		return fmt.Errorf("failed to create VPN instance: %w", err)
	}

	// 启动服务
	if err := instance.Start(); err != nil {
		s.cancel()
		return fmt.Errorf("failed to start VPN: %w", err)
	}

	s.instance = instance
	s.config = &options
	s.running = true
	s.stats.ConnectedAt = time.Now().Unix()

	// 启动流量统计
	go s.updateStats()

	return nil
}

// Stop 停止 VPN 服务
func (s *VPNService) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.running {
		return errors.New("VPN is not running")
	}

	// 停止实例
	if s.instance != nil {
		if err := s.instance.Close(); err != nil {
			return fmt.Errorf("failed to stop VPN: %w", err)
		}
	}

	// 取消上下文
	if s.cancel != nil {
		s.cancel()
	}

	s.instance = nil
	s.running = false

	return nil
}

// IsRunning 检查 VPN 是否正在运行
func (s *VPNService) IsRunning() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.running
}

// GetStats 获取流量统计信息
// 返回: JSON 格式的统计数据
func (s *VPNService) GetStats() string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	data, _ := json.Marshal(s.stats)
	return string(data)
}

// UpdateConfig 更新 VPN 配置（需要重启才能生效）
func (s *VPNService) UpdateConfig(configJSON string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// 解析配置
	var options option.Options
	if err := json.Unmarshal([]byte(configJSON), &options); err != nil {
		return fmt.Errorf("failed to parse config: %w", err)
	}

	s.config = &options

	// 如果正在运行，需要重启
	if s.running {
		return errors.New("VPN is running, please stop and start again to apply new config")
	}

	return nil
}

// Restart 重启 VPN 服务（使用当前配置）
func (s *VPNService) Restart() error {
	if err := s.Stop(); err != nil {
		return err
	}

	time.Sleep(500 * time.Millisecond) // 短暂延迟

	if s.config == nil {
		return errors.New("no config available")
	}

	configJSON, err := json.Marshal(s.config)
	if err != nil {
		return err
	}

	return s.Start(string(configJSON))
}

// GetVersion 获取版本信息
func (s *VPNService) GetVersion() string {
	return "PrivateDeploy VPN Core 1.0.0"
}

// updateStats 定期更新流量统计
func (s *VPNService) updateStats() {
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	var lastUpload, lastDownload int64
	lastUpdate := time.Now()

	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			s.mu.Lock()
			if s.instance != nil {
				// TODO: 从 sing-box 获取实际流量统计
				// 当前为示例数据，实际需要调用 sing-box 的统计接口
				now := time.Now()
				elapsed := now.Sub(lastUpdate).Seconds()

				// 计算速度
				if elapsed > 0 {
					s.stats.UploadSpeed = int64(float64(s.stats.UploadBytes-lastUpload) / elapsed)
					s.stats.DownloadSpeed = int64(float64(s.stats.DownloadBytes-lastDownload) / elapsed)
				}

				lastUpload = s.stats.UploadBytes
				lastDownload = s.stats.DownloadBytes
				lastUpdate = now
			}
			s.mu.Unlock()
		}
	}
}

// ResetStats 重置流量统计
func (s *VPNService) ResetStats() {
	s.mu.Lock()
	defer s.mu.Unlock()

	connectedAt := s.stats.ConnectedAt
	s.stats = &TrafficStats{
		ConnectedAt: connectedAt,
	}
}

// GetStatus 获取 VPN 状态信息
func (s *VPNService) GetStatus() string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	status := map[string]interface{}{
		"running":      s.running,
		"connected_at": s.stats.ConnectedAt,
		"uptime":       0,
	}

	if s.running && s.stats.ConnectedAt > 0 {
		status["uptime"] = time.Now().Unix() - s.stats.ConnectedAt
	}

	data, _ := json.Marshal(status)
	return string(data)
}
