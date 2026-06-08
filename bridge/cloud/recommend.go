package cloud

import (
	"sort"
	"strings"
)

// RegionScore holds the scored result for a single region.
type RegionScore struct {
	Region    Region   `json:"region"`
	LatencyMs float64  `json:"latencyMs"`
	ReachabilityRisk   string   `json:"reachabilityRisk"`   // low, medium, high, critical
	AIAccess  bool     `json:"aiAccess"`  // can reach OpenAI, Claude, etc.
	Score     float64  `json:"score"`     // 0-100
	Reasons   []string `json:"reasons"`
}

// reachabilityRiskMap classifies regions by reachability risk level.
var reachabilityRiskMap = map[string]string{
	// Low risk — generally stable
	"sgp": "low", "nrt": "low", "icn": "low", "tpe": "low",
	"bom": "low", "syd": "low", "mel": "low",
	// Medium risk — occasionally targeted
	"lax": "medium", "sjc": "medium", "sea": "medium",
	"ams": "medium", "fra": "medium", "lhr": "medium",
	"hkg": "medium", "par": "medium",
	// High risk — frequently blocked
	"ewr": "high", "ord": "high", "dfw": "high",
	"mia": "high", "atl": "high", "yto": "high",
	"cdg": "high",
	// Critical — very unstable
}

// aiAccessibleRegions are regions from which AI services are typically reachable.
var aiAccessibleRegions = map[string]bool{
	"sgp": true, "nrt": true, "icn": true, "syd": true,
	"lax": true, "sjc": true, "sea": true, "ewr": true,
	"ord": true, "dfw": true, "mia": true, "atl": true,
	"yto": true, "lhr": true, "fra": true, "ams": true,
	"cdg": true, "par": true, "mel": true,
}

// continentForRegion maps region IDs to continents for diversity scoring.
var continentForRegion = map[string]string{
	"sgp": "Asia", "nrt": "Asia", "icn": "Asia", "hkg": "Asia",
	"tpe": "Asia", "bom": "Asia",
	"syd": "Oceania", "mel": "Oceania",
	"lax": "NorthAmerica", "sjc": "NorthAmerica", "sea": "NorthAmerica",
	"ewr": "NorthAmerica", "ord": "NorthAmerica", "dfw": "NorthAmerica",
	"mia": "NorthAmerica", "atl": "NorthAmerica", "yto": "NorthAmerica",
	"lhr": "Europe", "fra": "Europe", "ams": "Europe",
	"cdg": "Europe", "par": "Europe",
}

// ScoreRegions scores and ranks regions for deployment suitability.
// latencies maps region ID → latency in milliseconds (from frontend testing).
func ScoreRegions(regions []Region, latencies map[string]float64) []RegionScore {
	results := make([]RegionScore, 0, len(regions))
	seenContinents := make(map[string]bool)

	// First pass: score without diversity
	type scored struct {
		rs        RegionScore
		continent string
	}
	scoredList := make([]scored, 0, len(regions))

	for _, r := range regions {
		rs := RegionScore{
			Region:    r,
			LatencyMs: latencies[r.ID],
			ReachabilityRisk:   getReachabilityRisk(r.ID),
			AIAccess:  aiAccessibleRegions[r.ID],
		}

		var score float64
		var reasons []string

		// Latency score: 40% weight
		latencyScore := scoreLatency(rs.LatencyMs)
		score += latencyScore * 0.40
		if latencyScore >= 80 {
			reasons = append(reasons, "低延迟")
		}

		// reachability risk: 30% weight
		riskScore := scoreReachabilityRisk(rs.ReachabilityRisk)
		score += riskScore * 0.30
		if riskScore >= 80 {
			reasons = append(reasons, "可达性风险低")
		} else if riskScore <= 30 {
			reasons = append(reasons, "可达性风险高")
		}

		// AI access: 20% weight
		if rs.AIAccess {
			score += 100 * 0.20
			reasons = append(reasons, "可访问 AI 服务")
		}

		rs.Score = score
		rs.Reasons = reasons

		continent := continentForRegion[r.ID]
		if continent == "" {
			continent = r.Continent
		}
		scoredList = append(scoredList, scored{rs: rs, continent: continent})
	}

	// Sort by score descending for diversity calculation
	sort.Slice(scoredList, func(i, j int) bool {
		return scoredList[i].rs.Score > scoredList[j].rs.Score
	})

	// Second pass: add diversity bonus (10% weight)
	for i := range scoredList {
		continent := scoredList[i].continent
		if continent != "" && !seenContinents[continent] {
			seenContinents[continent] = true
			scoredList[i].rs.Score += 100 * 0.10
			scoredList[i].rs.Reasons = append(scoredList[i].rs.Reasons, "Geographic redundancy")
		}
		results = append(results, scoredList[i].rs)
	}

	// Final sort by score
	sort.Slice(results, func(i, j int) bool {
		return results[i].Score > results[j].Score
	})

	return results
}

func getReachabilityRisk(regionID string) string {
	id := strings.ToLower(regionID)
	if risk, ok := reachabilityRiskMap[id]; ok {
		return risk
	}
	return "medium"
}

func scoreLatency(ms float64) float64 {
	if ms <= 0 {
		return 50 // no data, neutral score
	}
	if ms < 100 {
		return 100
	}
	if ms < 200 {
		return 80
	}
	if ms < 400 {
		return 60
	}
	return 30
}

func scoreReachabilityRisk(risk string) float64 {
	switch risk {
	case "low":
		return 100
	case "medium":
		return 70
	case "high":
		return 30
	case "critical":
		return 0
	default:
		return 50
	}
}
