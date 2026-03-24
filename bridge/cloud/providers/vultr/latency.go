package vultr

import (
	"context"
	"fmt"
	"net"
	"sort"
	"sync"
	"time"

	"privatedeploy/bridge/cloud"
)

// RegionLatency 区域延迟测试结果
type RegionLatency = cloud.RegionLatency

// 预设的测试IP映射表
var testIPMap = map[string]struct {
	IP   string
	Name string
}{
	"bom": {"207.148.77.101", "孟买"},
	"sgp": {"45.32.100.168", "新加坡"},
	"nrt": {"139.180.132.194", "东京"},
	"icn": {"45.76.178.200", "首尔"},
	"fra": {"108.61.210.117", "法兰克福"},
	"lax": {"108.61.219.200", "洛杉矶"},
	"yto": {"149.248.2.101", "多伦多"},
	"lhr": {"45.76.113.28", "伦敦"},
	"cdg": {"95.179.139.229", "巴黎"},
	"ams": {"108.61.198.102", "阿姆斯特丹"},
	"syd": {"108.61.212.117", "悉尼"},
	"sjc": {"45.32.48.10", "硅谷"},
	"sea": {"108.61.194.105", "西雅图"},
	"ord": {"45.32.203.95", "芝加哥"},
	"ewr": {"45.76.1.68", "纽约"},
	"atl": {"45.63.115.219", "亚特兰大"},
	"dfw": {"108.61.224.175", "达拉斯"},
}

// TestRegionLatency 测试单个区域的延迟
func (p *Provider) TestRegionLatency(ctx context.Context, regionCode string) (*RegionLatency, error) {
	testInfo, exists := testIPMap[regionCode]
	if !exists {
		return nil, fmt.Errorf("unknown region code: %s", regionCode)
	}

	result := &RegionLatency{
		Code: regionCode,
		Name: testInfo.Name,
		IP:   testInfo.IP,
	}

	// 执行 TCP 连接测试 (使用 HTTP 端口 80)
	// 使用 TCP 而不是 ICMP，避免权限问题
	var totalLatency time.Duration
	successCount := 0
	const testCount = 5

	for i := 0; i < testCount; i++ {
		start := time.Now()

		// 设置超时时间为 2 秒（优化性能）
		conn, err := net.DialTimeout("tcp", testInfo.IP+":80", 2*time.Second)

		if err == nil {
			latency := time.Since(start)
			totalLatency += latency
			successCount++
			conn.Close()
		}

		// 避免测试过快
		if i < testCount-1 {
			time.Sleep(200 * time.Millisecond)
		}
	}

	// 计算结果
	if successCount == 0 {
		result.Status = "timeout"
		result.Loss = 100
		result.Latency = 0
		return result, nil
	}

	avgLatency := totalLatency / time.Duration(successCount)
	result.Latency = float64(avgLatency.Milliseconds())
	result.Loss = float64(testCount-successCount) * 100.0 / float64(testCount)
	result.Status = "ok"

	return result, nil
}

// TestAllRegions 测试所有区域（并发）
func (p *Provider) TestAllRegions(ctx context.Context) ([]*RegionLatency, error) {
	// 获取所有区域代码
	regions := []string{"bom", "sgp", "nrt", "icn", "fra", "lax", "yto", "lhr", "cdg", "ams", "syd"}

	// 使用并发测试加快速度
	results := make([]*RegionLatency, len(regions))
	var wg sync.WaitGroup
	var mu sync.Mutex

	for i, region := range regions {
		wg.Add(1)
		go func(idx int, regionCode string) {
			defer wg.Done()

			result, err := p.TestRegionLatency(ctx, regionCode)
			if err != nil {
				// 出错时创建一个失败结果
				result = &RegionLatency{
					Code:   regionCode,
					Name:   testIPMap[regionCode].Name,
					Status: "error",
					Loss:   100,
				}
			}

			mu.Lock()
			results[idx] = result
			mu.Unlock()
		}(i, region)
	}

	wg.Wait()

	// 按延迟排序（timeout 的放最后）
	sort.Slice(results, func(i, j int) bool {
		if results[i].Status == "timeout" || results[i].Status == "error" {
			return false
		}
		if results[j].Status == "timeout" || results[j].Status == "error" {
			return true
		}
		return results[i].Latency < results[j].Latency
	})

	return results, nil
}

// GetFastestRegion 获取延迟最低的可用区域
func (p *Provider) GetFastestRegion(ctx context.Context) (*RegionLatency, error) {
	results, err := p.TestAllRegions(ctx)
	if err != nil {
		return nil, err
	}

	// 返回第一个状态为 ok 的区域
	for _, result := range results {
		if result.Status == "ok" {
			return result, nil
		}
	}

	return nil, fmt.Errorf("no available region found")
}
