package health

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"privatedeploy/bridge/cloud"
)

// HealthResult holds the health check result for a single node.
type HealthResult struct {
	NodeID     string       `json:"nodeId"`
	Healthy    bool         `json:"healthy"`
	LatencyMs  float64      `json:"latencyMs"`
	PortsOpen  map[int]bool `json:"portsOpen"`
	LastCheck  time.Time    `json:"lastCheck"`
	Failures   int          `json:"consecutiveFailures"`
}

// Monitor performs periodic health checks on managed nodes.
type Monitor struct {
	mu       sync.RWMutex
	interval time.Duration
	results  map[string]*HealthResult
	stopCh   chan struct{}
	running  bool

	// eventEmitter pushes events to the Wails frontend.
	eventEmitter func(event string, data ...interface{})
}

// NewMonitor creates a new health monitor.
func NewMonitor(interval time.Duration) *Monitor {
	if interval <= 0 {
		interval = 5 * time.Minute
	}
	return &Monitor{
		interval: interval,
		results:  make(map[string]*HealthResult),
		stopCh:   make(chan struct{}),
	}
}

// SetEventEmitter sets the callback for pushing events.
func (m *Monitor) SetEventEmitter(fn func(event string, data ...interface{})) {
	m.eventEmitter = fn
}

func (m *Monitor) emit(event string, data ...interface{}) {
	if m.eventEmitter != nil {
		m.eventEmitter(event, data...)
	}
}

// Start begins the periodic health check loop.
func (m *Monitor) Start(provider cloud.CloudProvider) {
	m.mu.Lock()
	if m.running {
		m.mu.Unlock()
		return
	}
	m.running = true
	m.stopCh = make(chan struct{})
	m.mu.Unlock()

	go func() {
		// Initial check
		m.checkAll(provider)

		ticker := time.NewTicker(m.interval)
		defer ticker.Stop()

		for {
			select {
			case <-ticker.C:
				m.checkAll(provider)
			case <-m.stopCh:
				log.Println("[HealthMonitor] Stopped")
				return
			}
		}
	}()

	log.Printf("[HealthMonitor] Started with interval %s", m.interval)
}

// Stop terminates the health check loop.
func (m *Monitor) Stop() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.running {
		close(m.stopCh)
		m.running = false
	}
}

// IsRunning returns whether the monitor is active.
func (m *Monitor) IsRunning() bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.running
}

// GetResults returns a snapshot of all health results.
func (m *Monitor) GetResults() map[string]*HealthResult {
	m.mu.RLock()
	defer m.mu.RUnlock()
	copy := make(map[string]*HealthResult, len(m.results))
	for k, v := range m.results {
		r := *v
		copy[k] = &r
	}
	return copy
}

// GetResultsJSON returns the results as JSON.
func (m *Monitor) GetResultsJSON() (string, error) {
	results := m.GetResults()
	data, err := json.Marshal(results)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// SetInterval changes the check interval (takes effect on next tick).
func (m *Monitor) SetInterval(d time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.interval = d
}

func (m *Monitor) checkAll(provider cloud.CloudProvider) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	instances, err := provider.ListInstances(ctx)
	if err != nil {
		log.Printf("[HealthMonitor] Failed to list instances: %v", err)
		return
	}

	var wg sync.WaitGroup
	for _, inst := range instances {
		if inst.IPv4 == "" && inst.IPv6 == "" {
			continue
		}
		wg.Add(1)
		go func(instance cloud.Instance) {
			defer wg.Done()
			m.checkNode(instance)
		}(inst)
	}
	wg.Wait()
}

func (m *Monitor) checkNode(instance cloud.Instance) {
	ip := instance.IPv4
	if ip == "" {
		ip = instance.IPv6
	}

	ports := collectPorts(instance)

	// Check each port
	portsOpen := make(map[int]bool, len(ports))
	var latencySum float64
	successCount := 0

	for _, port := range ports {
		addr := net.JoinHostPort(ip, fmt.Sprintf("%d", port))
		start := time.Now()
		conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
		elapsed := time.Since(start).Seconds() * 1000

		if err != nil {
			portsOpen[port] = false
		} else {
			portsOpen[port] = true
			latencySum += elapsed
			successCount++
			conn.Close()
		}
	}

	healthy := successCount > 0
	var avgLatency float64
	if successCount > 0 {
		avgLatency = latencySum / float64(successCount)
	}

	m.mu.Lock()
	prev, existed := m.results[instance.ID]
	failures := 0
	if existed && !healthy {
		failures = prev.Failures + 1
	}

	result := &HealthResult{
		NodeID:    instance.ID,
		Healthy:   healthy,
		LatencyMs: avgLatency,
		PortsOpen: portsOpen,
		LastCheck: time.Now(),
		Failures:  failures,
	}
	m.results[instance.ID] = result
	m.mu.Unlock()

	// Emit events on status changes
	if existed {
		if prev.Healthy && !healthy {
			log.Printf("[HealthMonitor] Node %s became unhealthy (failures: %d)", instance.ID, failures)
			m.emit("cloud:health:changed", instance.ID, false, failures)
		} else if !prev.Healthy && healthy {
			log.Printf("[HealthMonitor] Node %s recovered", instance.ID)
			m.emit("cloud:health:changed", instance.ID, true, 0)
		}
	}

	// Alert on 3 consecutive failures
	if failures >= 3 && (failures%3 == 0) {
		log.Printf("[HealthMonitor] ALERT: Node %s has %d consecutive failures", instance.ID, failures)
		m.emit("cloud:health:alert", instance.ID, failures)
	}
}

func collectPorts(inst cloud.Instance) []int {
	ports := make([]int, 0, 4)
	if inst.SSPort > 0 {
		ports = append(ports, inst.SSPort)
	}
	if inst.HysteriaPort > 0 {
		ports = append(ports, inst.HysteriaPort)
	}
	if inst.VLESSPort > 0 {
		ports = append(ports, inst.VLESSPort)
	}
	if inst.TrojanPort > 0 {
		ports = append(ports, inst.TrojanPort)
	}
	return ports
}
