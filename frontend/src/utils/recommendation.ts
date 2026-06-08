import type { ManagedCloudNode } from '@/stores/cloud'

export interface NodeScore {
  node: ManagedCloudNode
  score: number
  reasons: string[]
  antiBlockingScore?: number
}

export interface RecommendationCriteria {
  preferLowLatency?: boolean
  preferLowRisk?: boolean
  preferReachable?: boolean
  avoidBlocked?: boolean
  preferRecent?: boolean
}

// GFW risk levels (from CloudView)
const gfwRiskLevels: Record<string, 'low' | 'medium' | 'high' | 'critical'> = {
  // Low Risk
  'bom': 'low', 'sgp': 'low', 'nrt': 'low', 'icn': 'low',
  'tpe': 'low', 'syd': 'low',

  // Medium Risk
  'lax': 'medium', 'sjc': 'medium', 'sea': 'medium',
  'ams': 'medium', 'fra': 'medium', 'lhr': 'medium', 'hkg': 'medium',

  // High Risk
  'ewr': 'high', 'ord': 'high', 'dfw': 'high', 'mia': 'high',
  'atl': 'high', 'yto': 'high', 'cdg': 'high',
}

const riskScoreMap = {
  low: 100,
  medium: 75,
  high: 50,
  critical: 25,
}

const countProtocols = (node: ManagedCloudNode) => {
  let count = 0
  if (node.ssPort && node.ssPassword) count++
  if (node.hysteriaPort && node.hysteriaPassword) count++
  if (node.vlessPort && node.vlessUUID && node.vlessPublicKey && node.vlessShortId) count++
  if (node.trojanPort && node.trojanPassword) count++
  return count
}

const calculateAntiBlockingScore = (node: ManagedCloudNode): { score: number; reasons: string[] } => {
  const reasons: string[] = []
  const riskLevel = gfwRiskLevels[node.region || ''] || 'medium'
  let score = riskScoreMap[riskLevel] * 0.35

  const protocolCount = countProtocols(node)
  score += Math.min(100, protocolCount * 25) * 0.30
  if (protocolCount >= 3) {
    reasons.push('Protocol diversity is strong')
  } else if (protocolCount <= 1) {
    reasons.push('Protocol diversity is weak')
  }

  // UDP-capable protocols generally improve censorship resilience in unstable networks.
  let transportBonus = 0
  if (node.hysteriaPort && node.hysteriaPassword) {
    transportBonus += 20
    reasons.push('Hysteria2 (UDP/QUIC) available')
  }
  if (node.vlessPort && node.vlessUUID && node.vlessPublicKey && node.vlessShortId) {
    transportBonus += 15
    reasons.push('VLESS-Reality available')
  }
  score += Math.min(100, transportBonus) * 0.20

  let connectivityScore = 40
  if (node.connectivityStatus === 'reachable') {
    connectivityScore = 100
    reasons.push('Latest connectivity test is reachable')
  } else if (node.connectivityStatus === 'icmp_blocked') {
    connectivityScore = 75
    reasons.push('Ports reachable even when ICMP is blocked')
  } else if (node.connectivityStatus === 'blocked') {
    connectivityScore = 0
    reasons.push('Latest connectivity test is blocked')
  }
  score += connectivityScore * 0.15

  // Favor nodes that survived initial warm-up and have not been too old for long-term bans.
  if (node.createdAt) {
    const ageMs = Date.now() - new Date(node.createdAt).getTime()
    const ageDays = ageMs / (1000 * 60 * 60 * 24)
    if (ageDays >= 2 && ageDays <= 45) {
      score += 6
      reasons.push('Node age is in stable window')
    } else if (ageDays > 120) {
      score -= 6
      reasons.push('Node is relatively old')
    }
  }

  return {
    score: Math.max(0, Math.min(100, Math.round(score))),
    reasons,
  }
}

/**
 * Calculate node recommendation score
 */
export function calculateNodeScore(
  node: ManagedCloudNode,
  criteria: RecommendationCriteria = {},
  latencyMap?: Map<string, number>
): NodeScore {
  let score = 0
  const reasons: string[] = []
  const antiBlocking = calculateAntiBlockingScore(node)
  const weights = {
    latency: criteria.preferLowLatency ? 0.28 : 0.20,
    antiBlocking: criteria.preferLowRisk ? 0.42 : 0.35,
    connectivity: criteria.preferReachable ? 0.20 : 0.15,
    recency: criteria.preferRecent ? 0.10 : 0.05,
  }

  // Normalize weights to sum to 1
  const totalWeight = Object.values(weights).reduce((a, b) => a + b, 0)
  Object.keys(weights).forEach(key => {
    weights[key as keyof typeof weights] /= totalWeight
  })

  // 1. Latency score (lower is better)
  const latency = latencyMap?.get(node.region || '') || 9999
  const latencyScore = Math.max(0, 100 - latency * 0.3)
  score += latencyScore * weights.latency

  if (latency < 50) {
    reasons.push('Excellent latency (<50ms)')
  } else if (latency < 100) {
    reasons.push('Good latency (<100ms)')
  } else if (latency < 200) {
    reasons.push('Acceptable latency (<200ms)')
  }

  // 2. Dynamic anti-blocking score
  score += antiBlocking.score * weights.antiBlocking
  reasons.push(...antiBlocking.reasons.slice(0, 3))

  // 3. Connectivity score
  let connectivityScore = 50 // default
  if (node.connectivityStatus === 'reachable') {
    connectivityScore = 100
    reasons.push('Currently reachable')
  } else if (node.connectivityStatus === 'icmp_blocked') {
    connectivityScore = 75
    reasons.push('ICMP blocked but ports open')
  } else if (node.connectivityStatus === 'blocked') {
    connectivityScore = 0
    reasons.push('Currently blocked')

    // Heavily penalize blocked nodes if avoiding them
    if (criteria.avoidBlocked) {
      score *= 0.1
      reasons.push('Blocked nodes avoided')
    }
  }
  score += connectivityScore * weights.connectivity

  // 4. Recency score (newer nodes might be less likely to be blocked)
  if (node.createdAt) {
    const ageMs = Date.now() - new Date(node.createdAt).getTime()
    const ageDays = ageMs / (1000 * 60 * 60 * 24)

    // Nodes less than 7 days old get bonus
    const recencyScore = Math.max(0, 100 - ageDays * 10)
    score += recencyScore * weights.recency

    if (ageDays < 1) {
      reasons.push('Recently created')
    }
  }

  return {
    node,
    score: Math.round(score),
    reasons,
    antiBlockingScore: antiBlocking.score,
  }
}

/**
 * Get recommended nodes sorted by score
 */
export function getRecommendedNodes(
  nodes: ManagedCloudNode[],
  criteria: RecommendationCriteria = {},
  latencyMap?: Map<string, number>
): NodeScore[] {
  return nodes
    .map(node => calculateNodeScore(node, criteria, latencyMap))
    .sort((a, b) => b.score - a.score)
}

/**
 * Get best node recommendation
 */
export function getBestNode(
  nodes: ManagedCloudNode[],
  criteria: RecommendationCriteria = {},
  latencyMap?: Map<string, number>
): NodeScore | null {
  const recommended = getRecommendedNodes(nodes, criteria, latencyMap)
  return recommended.length > 0 ? recommended[0] : null
}

/**
 * Get recommendation for region selection
 */
export function getRecommendedRegion(
  availableRegions: string[],
  latencyMap: Map<string, number>
): string | null {
  let bestRegion: string | null = null
  let bestScore = -1

  for (const region of availableRegions) {
    const latency = latencyMap.get(region) || 9999
    const riskLevel = gfwRiskLevels[region] || 'medium'
    const riskScore = riskScoreMap[riskLevel]

    // Combined score: 60% risk, 40% latency
    const score = riskScore * 0.6 + Math.max(0, 100 - latency * 0.3) * 0.4

    if (score > bestScore) {
      bestScore = score
      bestRegion = region
    }
  }

  return bestRegion
}
