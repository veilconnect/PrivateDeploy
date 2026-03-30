import { EventsOff, EventsOn } from '@wails/runtime/runtime'
import { computed, onMounted, onUnmounted, ref, watch, type ComputedRef } from 'vue'

import { NODE_HISTORY_WINDOW_MS } from '@/stores/cloud/constants'
import { message } from '@/utils'
import { checkAllNodesHealth, getHealthSummary, scheduleHealthChecks } from '@/utils/healthCheck'
import { logInfo } from '@/utils/logger'
import { initOfflineMode } from '@/utils/offline'
import { type ConnectivityDataPoint, type LatencyDataPoint } from '@/utils/visualization'

import { formatSpeedFailureReason, isSpeedTimeoutError } from './cloudViewPresentation'

import type { ManagedCloudNode, NodeHistoryMap } from '@/stores/cloud'
import type { ConnectivityResult } from '@/types/cloud'

type TranslateFn = (key: string, params?: Record<string, unknown>) => string

type CloudStoreLike = {
  instances: ManagedCloudNode[]
  nodeHistory: NodeHistoryMap
  refreshInstances: (silent?: boolean, force?: boolean) => Promise<unknown>
}

type UseCloudViewMonitoringDeps = {
  cloudStore: CloudStoreLike
  tableData: ComputedRef<ManagedCloudNode[]>
  translate: TranslateFn
  handleTestAllSpeed: () => void | Promise<unknown>
}

type ChartEndpointStatus = {
  key: string
  label: string
  status: string
}

const endpointLabelMap: Record<string, string> = {
  'shadowsocks-tcp': 'SS TCP',
  'shadowsocks-udp': 'SS UDP',
  hysteria2: 'Hysteria2',
  'vless-reality': 'VLESS Reality',
  trojan: 'Trojan',
}

const buildEndpointStatuses = (result?: ConnectivityResult): ChartEndpointStatus[] => {
  if (!result) {
    return []
  }

  const targetStatus = result.targetStatus || {}
  const targetEntries = Object.entries(targetStatus)
  if (targetEntries.length > 0) {
    return targetEntries.map(([key, status]) => ({
      key,
      label: endpointLabelMap[key] || key,
      status,
    }))
  }

  return Object.entries(result.portsOpen || {}).map(([key, open]) => ({
    key,
    label: `Port ${key}`,
    status: open ? 'open' : 'closed',
  }))
}

const getRecentNodeHistory = (
  history: NodeHistoryMap,
  instanceId: string,
  now: number = Date.now(),
) => {
  const record = history[instanceId]
  if (!record) {
    return {
      connectivity: [],
      speed: [],
    }
  }

  const cutoff = now - NODE_HISTORY_WINDOW_MS
  return {
    connectivity: (record.connectivity || []).filter((entry) => entry.timestamp >= cutoff),
    speed: (record.speed || []).filter((entry) => entry.timestamp >= cutoff),
  }
}

export const useCloudViewMonitoring = ({
  cloudStore,
  tableData,
  translate,
  handleTestAllSpeed,
}: UseCloudViewMonitoringDeps) => {
  const viewingChartNode = ref<ManagedCloudNode | null>(null)
  const showChartsModal = ref(false)
  const showKeyboardHelp = ref(false)
  const sshDeployProgress = ref<Array<{ id: string; stage: string; message: string }>>([])

  const resetSSHDeployProgress = () => {
    sshDeployProgress.value = []
  }

  const handleViewCharts = (node: ManagedCloudNode) => {
    viewingChartNode.value = node
    showChartsModal.value = true
  }

  const closeChartsModal = () => {
    showChartsModal.value = false
    viewingChartNode.value = null
  }

  watch(showChartsModal, (open) => {
    if (!open) {
      viewingChartNode.value = null
    }
  })

  const connectivityChartData = computed<ConnectivityDataPoint[]>(() => {
    const node = viewingChartNode.value
    if (!node) return []

    const recent = getRecentNodeHistory(cloudStore.nodeHistory, node.instanceId)
    if (recent.connectivity.length > 0) {
      return recent.connectivity.map((entry) => ({
        timestamp: entry.timestamp,
        status: entry.status,
      }))
    }

    const status = node.lastConnectivityResult?.status || node.connectivityStatus
    return status
      ? [{
          timestamp: Date.now(),
          status,
        }]
      : []
  })

  const latencyChartData = computed<LatencyDataPoint[]>(() => {
    const node = viewingChartNode.value
    if (!node) {
      return []
    }

    return getRecentNodeHistory(cloudStore.nodeHistory, node.instanceId).speed
      .filter((entry) => (entry.status === 'ok' || entry.status === 'partial') && typeof entry.speedMbps === 'number')
      .map((entry) => ({
        timestamp: entry.timestamp,
        latency: entry.speedMbps!,
      }))
  })

  const chartCurrentStatusLabel = computed(() => {
    return translate(`cloud.connectivity.${chartCurrentStatusKey.value}`)
  })

  const chartCurrentStatusKey = computed(() => {
    const node = viewingChartNode.value
    if (!node) {
      return 'unknown'
    }

    const connectivityHistory = getRecentNodeHistory(cloudStore.nodeHistory, node.instanceId).connectivity
    const latestConnectivity = connectivityHistory[connectivityHistory.length - 1]
    return node.lastConnectivityResult?.status || node.connectivityStatus || latestConnectivity?.status || 'unknown'
  })

  const chartLatestSpeedLabel = computed(() => {
    const node = viewingChartNode.value
    if (!node) {
      return translate('cloud.charts.noMeasurement')
    }
    if (node.speedTesting) {
      return translate('cloud.speed.testing')
    }
    if (typeof node.speedMbps === 'number') {
      return node.speedMbps < 0
        ? (node.speedError
            ? (isSpeedTimeoutError(node.speedError)
                ? translate('cloud.speed.timeout')
                : translate('cloud.speed.failedWithReason', {
                    reason: formatSpeedFailureReason(node.speedError, translate),
                  }))
            : translate('cloud.speed.timeout'))
        : (node.speedError
            ? translate('cloud.speed.mbpsPartial', { speed: node.speedMbps })
            : translate('cloud.speed.mbps', { speed: node.speedMbps }))
    }
    if (typeof node.speedMs === 'number') {
      return node.speedMs < 0
        ? translate('cloud.speed.timeout')
        : translate('cloud.speed.ms', { ms: node.speedMs })
    }

    const speedHistory = getRecentNodeHistory(cloudStore.nodeHistory, node.instanceId).speed
    const latestSpeedEntry = speedHistory[speedHistory.length - 1]
    if ((latestSpeedEntry?.status === 'ok' || latestSpeedEntry?.status === 'partial') && typeof latestSpeedEntry.speedMbps === 'number') {
      return latestSpeedEntry.status === 'partial'
        ? translate('cloud.speed.mbpsPartial', { speed: latestSpeedEntry.speedMbps })
        : translate('cloud.speed.mbps', { speed: latestSpeedEntry.speedMbps })
    }
    if (latestSpeedEntry?.status === 'timeout') {
      return translate('cloud.speed.timeout')
    }
    if (latestSpeedEntry?.status === 'error') {
      const reason = formatSpeedFailureReason(latestSpeedEntry.error, translate)
      return isSpeedTimeoutError(latestSpeedEntry.error)
        ? translate('cloud.speed.timeout')
        : translate('cloud.speed.failedWithReason', { reason })
    }

    return translate('cloud.charts.noMeasurement')
  })

  const chartEndpointStatuses = computed<ChartEndpointStatus[]>(() => {
    const node = viewingChartNode.value
    if (!node) {
      return []
    }

    const connectivityHistory = getRecentNodeHistory(cloudStore.nodeHistory, node.instanceId).connectivity
    const lastHistoryEntry = connectivityHistory[connectivityHistory.length - 1]
    return buildEndpointStatuses(node.lastConnectivityResult || (
      lastHistoryEntry ? {
        ip: node.ipv4 || node.ipv6 || '',
        icmpReachable: lastHistoryEntry.status === 'reachable',
        portsOpen: lastHistoryEntry.portsOpen || {},
        targetStatus: lastHistoryEntry.targetStatus,
        status: lastHistoryEntry.status,
      } as ConnectivityResult : undefined
    ))
  })

  const handleKeyDown = (event: KeyboardEvent) => {
    if (event.key === '?' && !event.ctrlKey && !event.metaKey && !event.altKey) {
      event.preventDefault()
      showKeyboardHelp.value = true
      return
    }

    if (event.key === 'Escape' && showKeyboardHelp.value) {
      event.preventDefault()
      showKeyboardHelp.value = false
      return
    }

    if ((event.ctrlKey || event.metaKey) && event.key === 't') {
      event.preventDefault()
      if (tableData.value.length > 0) {
        void handleTestAllSpeed()
      }
    }

    if ((event.ctrlKey || event.metaKey) && event.key === 'r') {
      event.preventDefault()
      void cloudStore.refreshInstances(false, true)
      message.info(translate('cloud.quickActions.refreshing'))
    }

    if ((event.ctrlKey || event.metaKey) && event.key === 'f') {
      event.preventDefault()
      const searchInput = document.querySelector('input[placeholder*="Search"]') as HTMLInputElement | null
      searchInput?.focus()
    }
  }

  const handleHealthChanged = (nodeId: string, healthy: boolean, failures: number) => {
    const node = cloudStore.instances.find((item) => item.instanceId === nodeId)
    if (!node) {
      return
    }

    node.connectivityStatus = healthy ? 'reachable' : 'blocked'
    if (!healthy) {
      logInfo(`[CloudView] Health changed: ${nodeId} unhealthy (${failures} failures)`)
    }
  }

  const handleHealthAlert = (nodeId: string, failures: number) => {
    const node = cloudStore.instances.find((item) => item.instanceId === nodeId)
    const label = node?.label || nodeId
    message.error(`节点 ${label} 连续 ${failures} 次健康检查失败`)
  }

  const handleSSHDeployProgress = (instanceId: string, stage: string, msg: string) => {
    logInfo(`[SSH Deploy] ${instanceId}: [${stage}] ${msg}`)
    sshDeployProgress.value = [
      ...sshDeployProgress.value.filter((item) => item.id !== instanceId),
      { id: instanceId, stage, message: msg },
    ]
  }

  let cleanupOfflineMode = () => {}
  let stopHealthChecks = () => {}

  onMounted(() => {
    cleanupOfflineMode = initOfflineMode()
    stopHealthChecks = scheduleHealthChecks(() => {
      const allNodes = cloudStore.instances
      if (allNodes.length === 0) {
        return
      }

      const healthResults = checkAllNodesHealth(allNodes)
      const summary = getHealthSummary(healthResults)

      logInfo(`[CloudView] Health check: ${summary.healthy}/${summary.total} healthy nodes (avg score: ${summary.avgScore})`)

      if (summary.criticalIssues > 0) {
        logInfo(`[CloudView] Warning: ${summary.criticalIssues} nodes have critical health issues`)
      }
    }, 5 * 60 * 1000)

    window.addEventListener('keydown', handleKeyDown)
    EventsOn('cloud:health:changed', handleHealthChanged)
    EventsOn('cloud:health:alert', handleHealthAlert)
    EventsOn('cloud:ssh:progress', handleSSHDeployProgress)
  })

  onUnmounted(() => {
    window.removeEventListener('keydown', handleKeyDown)
    stopHealthChecks()
    cleanupOfflineMode()
    EventsOff('cloud:health:changed')
    EventsOff('cloud:health:alert')
    EventsOff('cloud:ssh:progress')
  })

  return {
    closeChartsModal,
    chartCurrentStatusKey,
    chartCurrentStatusLabel,
    chartEndpointStatuses,
    chartLatestSpeedLabel,
    connectivityChartData,
    handleViewCharts,
    latencyChartData,
    resetSSHDeployProgress,
    showChartsModal,
    showKeyboardHelp,
    viewingChartNode,
  }
}
