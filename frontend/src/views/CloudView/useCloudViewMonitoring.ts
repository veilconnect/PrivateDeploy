import { EventsOff, EventsOn } from '@wails/runtime/runtime'
import { computed, onMounted, onUnmounted, ref, type ComputedRef } from 'vue'

import { message } from '@/utils'
import { checkAllNodesHealth, getHealthSummary, scheduleHealthChecks } from '@/utils/healthCheck'
import { logInfo } from '@/utils/logger'
import { initOfflineMode } from '@/utils/offline'
import { generateMockConnectivityHistory, type ConnectivityDataPoint, type LatencyDataPoint } from '@/utils/visualization'

import type { ManagedCloudNode } from '@/stores/cloud'

type TranslateFn = (key: string, params?: Record<string, unknown>) => string

type CloudStoreLike = {
  instances: ManagedCloudNode[]
  refreshInstances: (silent?: boolean, force?: boolean) => Promise<unknown>
}

type UseCloudViewMonitoringDeps = {
  cloudStore: CloudStoreLike
  tableData: ComputedRef<ManagedCloudNode[]>
  translate: TranslateFn
  handleTestAllSpeed: () => void | Promise<unknown>
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

  const connectivityChartData = computed<ConnectivityDataPoint[]>(() => {
    if (!viewingChartNode.value) return []

    return generateMockConnectivityHistory(
      viewingChartNode.value.connectivityStatus || 'unknown',
      24,
    )
  })

  const latencyChartData = computed<LatencyDataPoint[]>(() => {
    if (!viewingChartNode.value) return []

    const data: LatencyDataPoint[] = []
    const now = Date.now()
    const interval = (24 * 60 * 60 * 1000) / 48
    const baseLatency = 100

    for (let i = 0; i < 48; i++) {
      const variance = (Math.random() - 0.5) * 40
      data.push({
        timestamp: now - (48 - i) * interval,
        latency: Math.max(0, baseLatency + variance),
      })
    }

    return data
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
    connectivityChartData,
    handleViewCharts,
    latencyChartData,
    resetSSHDeployProgress,
    showChartsModal,
    showKeyboardHelp,
    viewingChartNode,
  }
}
