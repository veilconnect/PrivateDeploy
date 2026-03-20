package bridge

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"sync/atomic"
)

// LoadBalancer is a TCP round-robin proxy that distributes connections
// across multiple upstream SOCKS5 ports (one per cloud node).
type LoadBalancer struct {
	mu        sync.Mutex
	listener  net.Listener
	upstreams []string // e.g. ["127.0.0.1:40001", "127.0.0.1:40002"]
	counter   atomic.Uint64
	running   bool
	stopCh    chan struct{}
}

var globalLB = &LoadBalancer{}

// StartLoadBalancer starts a TCP round-robin load balancer.
// listenPort: the user-facing proxy port
// upstreamPortsJSON: JSON array of upstream port numbers, e.g. "[40001,40002]"
func (a *App) StartLoadBalancer(listenPort int, upstreamPortsJSON string) FlagResult {
	log.Printf("StartLoadBalancer: port=%d upstreams=%s", listenPort, upstreamPortsJSON)

	var ports []int
	if err := json.Unmarshal([]byte(upstreamPortsJSON), &ports); err != nil {
		return FlagResult{false, fmt.Sprintf("invalid ports: %s", err.Error())}
	}
	if len(ports) < 2 {
		return FlagResult{false, "need at least 2 upstream ports for load balancing"}
	}

	upstreams := make([]string, len(ports))
	for i, p := range ports {
		upstreams[i] = fmt.Sprintf("127.0.0.1:%d", p)
	}

	globalLB.mu.Lock()
	defer globalLB.mu.Unlock()

	if globalLB.running {
		// Stop existing
		close(globalLB.stopCh)
		if globalLB.listener != nil {
			globalLB.listener.Close()
		}
		globalLB.running = false
	}

	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", listenPort))
	if err != nil {
		return FlagResult{false, fmt.Sprintf("listen failed: %s", err.Error())}
	}

	globalLB.listener = listener
	globalLB.upstreams = upstreams
	globalLB.counter.Store(0)
	globalLB.stopCh = make(chan struct{})
	globalLB.running = true

	go globalLB.acceptLoop()

	log.Printf("LoadBalancer started on :%d with %d upstreams", listenPort, len(upstreams))
	return FlagResult{true, fmt.Sprintf(`{"port":%d,"upstreams":%d}`, listenPort, len(upstreams))}
}

// StopLoadBalancer stops the load balancer.
func (a *App) StopLoadBalancer() FlagResult {
	globalLB.mu.Lock()
	defer globalLB.mu.Unlock()

	if !globalLB.running {
		return FlagResult{true, "not running"}
	}

	close(globalLB.stopCh)
	globalLB.listener.Close()
	globalLB.running = false
	log.Printf("LoadBalancer stopped")
	return FlagResult{true, "stopped"}
}

// GetLoadBalancerStatus returns the current load balancer status.
func (a *App) GetLoadBalancerStatus() FlagResult {
	globalLB.mu.Lock()
	defer globalLB.mu.Unlock()

	if !globalLB.running {
		return FlagResult{false, `{"running":false}`}
	}

	total := globalLB.counter.Load()
	return FlagResult{true, fmt.Sprintf(`{"running":true,"upstreams":%d,"totalConnections":%d}`,
		len(globalLB.upstreams), total)}
}

func (lb *LoadBalancer) acceptLoop() {
	for {
		conn, err := lb.listener.Accept()
		if err != nil {
			select {
			case <-lb.stopCh:
				return
			default:
				log.Printf("LoadBalancer accept error: %v", err)
				return
			}
		}
		go lb.handleConn(conn)
	}
}

func (lb *LoadBalancer) handleConn(client net.Conn) {
	// Round-robin: pick next upstream
	idx := lb.counter.Add(1) - 1
	upstream := lb.upstreams[idx%uint64(len(lb.upstreams))]

	server, err := net.Dial("tcp", upstream)
	if err != nil {
		log.Printf("LoadBalancer: upstream %s dial failed: %v", upstream, err)
		client.Close()
		return
	}

	// Bidirectional pipe
	go func() {
		io.Copy(server, client)
		server.Close()
	}()
	io.Copy(client, server)
	client.Close()
}
