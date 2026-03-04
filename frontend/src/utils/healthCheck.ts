import { logInfo } from './logger'

import type { ManagedCloudNode } from '@/stores/cloud'

export interface HealthCheckResult {
  nodeId: string
  healthy: boolean
  score: number
  issues: string[]
  recommendations: string[]
  lastCheck: number
}

export interface HealthMetrics {
  connectivity: 'good' | 'degraded' | 'poor' | 'unknown'
  latency: number | null
  uptime: number // percentage
  lastConnectivityCheck?: number
}

/**
 * Perform health check on a single node
 */
export function checkNodeHealth(
  node: ManagedCloudNode,
  metrics?: HealthMetrics
): HealthCheckResult {
  const issues: string[] = []
  const recommendations: string[] = []
  let score = 100

  // Check connectivity status
  if (node.connectivityStatus === 'blocked') {
    issues.push('Node is completely blocked')
    recommendations.push('Consider rotating IP or deploying to different region')
    score -= 50
  } else if (node.connectivityStatus === 'icmp_blocked') {
    issues.push('ICMP is blocked but ports are accessible')
    score -= 10
  } else if (node.connectivityStatus === 'unknown') {
    issues.push('Connectivity status unknown')
    recommendations.push('Run connectivity test')
    score -= 20
  }

  // Check latency if available
  if (metrics?.latency) {
    if (metrics.latency > 500) {
      issues.push(`High latency: ${metrics.latency}ms`)
      recommendations.push('Consider deploying closer region')
      score -= 20
    } else if (metrics.latency > 200) {
      issues.push(`Elevated latency: ${metrics.latency}ms`)
      score -= 10
    }
  }

  // Check if node has required protocols configured
  const hasProtocols = !!(
    (node.ssPort && node.ssPassword) ||
    (node.hysteriaPort && node.hysteriaPassword) ||
    (node.vlessPort && node.vlessUUID) ||
    (node.trojanPort && node.trojanPassword)
  )

  if (!hasProtocols) {
    issues.push('No protocols configured')
    score -= 30
  }

  // Check IP addresses
  if (!node.ipv4 && !node.ipv6) {
    issues.push('No IP addresses available')
    score -= 40
  }

  // Check node age (very old nodes might be stale)
  if (node.createdAt) {
    const ageMs = Date.now() - new Date(node.createdAt).getTime()
    const ageDays = ageMs / (1000 * 60 * 60 * 24)

    if (ageDays > 90) {
      issues.push(`Node is ${Math.round(ageDays)} days old`)
      recommendations.push('Consider rotating IP periodically')
      score -= 5
    }
  }

  // Check uptime if available
  if (metrics?.uptime !== undefined) {
    if (metrics.uptime < 95) {
      issues.push(`Low uptime: ${metrics.uptime.toFixed(1)}%`)
      recommendations.push('Check node stability')
      score -= Math.round((100 - metrics.uptime) / 2)
    }
  }

  return {
    nodeId: node.instanceId,
    healthy: score >= 70,
    score: Math.max(0, Math.min(100, score)),
    issues,
    recommendations,
    lastCheck: Date.now(),
  }
}

/**
 * Perform health check on all nodes
 */
export function checkAllNodesHealth(nodes: ManagedCloudNode[]): HealthCheckResult[] {
  return nodes.map(node => checkNodeHealth(node))
}

/**
 * Get unhealthy nodes
 */
export function getUnhealthyNodes(
  healthResults: HealthCheckResult[]
): HealthCheckResult[] {
  return healthResults.filter(result => !result.healthy)
}

/**
 * Get health summary
 */
export interface HealthSummary {
  total: number
  healthy: number
  unhealthy: number
  avgScore: number
  criticalIssues: number
}

export function getHealthSummary(healthResults: HealthCheckResult[]): HealthSummary {
  const total = healthResults.length
  const healthy = healthResults.filter(r => r.healthy).length
  const unhealthy = total - healthy
  const avgScore = total > 0
    ? healthResults.reduce((sum, r) => sum + r.score, 0) / total
    : 0
  const criticalIssues = healthResults.filter(r => r.score < 50).length

  return {
    total,
    healthy,
    unhealthy,
    avgScore: Math.round(avgScore),
    criticalIssues,
  }
}

/**
 * Schedule periodic health checks
 */
export function scheduleHealthChecks(
  checkFn: () => void,
  intervalMs: number = 5 * 60 * 1000 // 5 minutes
): () => void {
  logInfo(`[HealthCheck] Scheduling periodic checks every ${intervalMs / 1000}s`)

  const timer = setInterval(() => {
    logInfo('[HealthCheck] Running scheduled health check')
    checkFn()
  }, intervalMs)

  // Return cleanup function
  return () => {
    clearInterval(timer)
    logInfo('[HealthCheck] Stopped periodic health checks')
  }
}

/**
 * Auto-remediation suggestions
 */
export function getRemediationActions(result: HealthCheckResult): string[] {
  const actions: string[] = []

  if (result.issues.includes('Node is completely blocked')) {
    actions.push('Rotate IP address')
    actions.push('Deploy new node in different region')
  }

  if (result.issues.some(i => i.includes('High latency'))) {
    actions.push('Test connectivity to verify latency')
    actions.push('Consider deploying to closer region')
  }

  if (result.issues.includes('No protocols configured')) {
    actions.push('Configure at least one protocol')
  }

  if (result.issues.includes('Connectivity status unknown')) {
    actions.push('Run connectivity test')
  }

  return actions
}
