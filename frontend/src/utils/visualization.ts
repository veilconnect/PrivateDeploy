/**
 * Visualization utilities for connectivity and latency charts
 */

export interface ConnectivityDataPoint {
  timestamp: number
  status: 'reachable' | 'blocked' | 'icmp_blocked' | 'testing' | 'unknown'
}

export interface LatencyDataPoint {
  timestamp: number
  latency: number
}

/**
 * Generate SVG path for connectivity timeline
 * @param data - Array of connectivity data points
 * @param width - Chart width in pixels
 * @param height - Chart height in pixels
 * @returns SVG path string
 */
export function generateConnectivityTimelinePath(
  data: ConnectivityDataPoint[],
  width: number = 200,
  height: number = 40
): string {
  if (data.length === 0) return ''

  const points = data.map((point, index) => {
    const x = (index / (data.length - 1 || 1)) * width
    const y = height / 2
    return { x, y, status: point.status }
  })

  return points.map(p => `${p.x},${p.y}`).join(' ')
}

/**
 * Get color for connectivity status
 */
export function getConnectivityStatusColor(status: string): string {
  const colorMap: Record<string, string> = {
    reachable: '#52c41a',
    icmp_blocked: '#13c2c2',
    blocked: '#ff4d4f',
    testing: '#d9d9d9',
    unknown: '#d9d9d9',
  }
  return colorMap[status] || '#d9d9d9'
}

/**
 * Generate SVG path for latency line chart
 * @param data - Array of latency data points
 * @param width - Chart width in pixels
 * @param height - Chart height in pixels
 * @returns SVG path string
 */
export function generateLatencyLinePath(
  data: LatencyDataPoint[],
  width: number = 200,
  height: number = 40
): string {
  if (data.length === 0) return ''

  const maxLatency = Math.max(...data.map(d => d.latency), 1)
  const minLatency = Math.min(...data.map(d => d.latency), 0)
  const range = maxLatency - minLatency || 1

  const points = data.map((point, index) => {
    const x = (index / (data.length - 1 || 1)) * width
    const normalizedLatency = (point.latency - minLatency) / range
    const y = height - normalizedLatency * height
    return `${x},${y}`
  })

  return `M ${points.join(' L ')}`
}

/**
 * Get latency color based on value
 */
export function getLatencyColor(latency: number): string {
  if (latency < 100) return '#52c41a' // green
  if (latency < 200) return '#faad14' // orange
  if (latency < 500) return '#ff7a45' // light red
  return '#ff4d4f' // red
}

/**
 * Format latency for display
 */
export function formatLatency(latency: number): string {
  if (latency < 1000) {
    return `${Math.round(latency)}ms`
  }
  return `${(latency / 1000).toFixed(2)}s`
}

/**
 * Generate connectivity status history (mock data for now)
 * In production, this would come from backend tracking
 */
export function generateMockConnectivityHistory(
  currentStatus: string,
  hours: number = 24
): ConnectivityDataPoint[] {
  const data: ConnectivityDataPoint[] = []
  const now = Date.now()
  const interval = (hours * 60 * 60 * 1000) / 48 // 48 data points

  for (let i = 0; i < 48; i++) {
    data.push({
      timestamp: now - (48 - i) * interval,
      status: currentStatus as any,
    })
  }

  return data
}

/**
 * Calculate connectivity uptime percentage
 */
export function calculateUptime(data: ConnectivityDataPoint[]): number {
  if (data.length === 0) return 0

  const reachableCount = data.filter(
    d => d.status === 'reachable' || d.status === 'icmp_blocked'
  ).length

  return (reachableCount / data.length) * 100
}
