import { computed, ref, type Ref } from 'vue'

import { ClipboardSetText } from '@/bridge'
import { useCdnStore } from '@/stores'
import { confirm, message } from '@/utils'
import { logError, logInfo } from '@/utils/logger'
import { getRecommendedNodes } from '@/utils/recommendation'

import { buildNodeProtocolLinks, hasCdnRelay } from './cloudNodeDisplay'

import type { ManagedCloudNode } from '@/stores/cloud'
import type { CloudNodeStatus } from '@/stores/cloud/constants'
import type { CloudNode, RegionLatency } from '@/types/cloud'

type TranslateFn = (key: string, params?: Record<string, unknown>) => string

type CloudStoreLike = {
  instances: ManagedCloudNode[]
  loadBalanceEnabled: boolean
  markNodeStatus: (instanceId: string, status: CloudNodeStatus) => void
  applyNodeToProfile: (node: CloudNode) => Promise<unknown>
  refreshInstances: (silent?: boolean, force?: boolean) => Promise<unknown>
  rotateIP: (instanceId: string) => Promise<{ instanceId: string }>
  redeployInstance: (instanceId: string) => Promise<{ instanceId: string }>
  destroyInstance: (instanceId: string) => Promise<unknown>
  testNodeSpeedTest: (instanceId: string) => Promise<unknown>
  testAllNodesSpeed: () => Promise<unknown>
  startLoadBalance: () => Promise<unknown>
  stopLoadBalance: () => Promise<unknown>
}

type KernelApiStoreLike = {
  running: boolean
  restartCore: () => Promise<unknown>
  startCore: () => Promise<unknown>
}

type UseCloudViewActionsDeps = {
  cloudStore: CloudStoreLike
  kernelApiStore: KernelApiStoreLike
  latencyResults: Ref<RegionLatency[]>
  translate: TranslateFn
  handleError: (error: unknown) => void
  formatNodeRegion: (regionId: string) => string
  isManualNode: (node: CloudNode | Record<string, any>) => boolean
}

export const useCloudViewActions = ({
  cloudStore,
  kernelApiStore,
  latencyResults,
  translate,
  handleError,
  formatNodeRegion,
  isManualNode,
}: UseCloudViewActionsDeps) => {
  const selectedNodeIds = ref<Set<string>>(new Set())
  const batchOperating = ref(false)
  const applyingNodeId = ref('')
  const rotatingNodeId = ref('')
  const redeployingNodeId = ref('')
  const speedTestAllLoading = ref(false)
  const loadBalanceLoading = ref(false)
  const cdnStore = useCdnStore()

  const copyText = async (value: string) => {
    if (!value) return
    try {
      await ClipboardSetText(value)
      message.success('common.copied')
    } catch (error) {
      handleError(error)
    }
  }

  const toggleNodeSelection = (nodeId: string) => {
    if (selectedNodeIds.value.has(nodeId)) {
      selectedNodeIds.value.delete(nodeId)
    } else {
      selectedNodeIds.value.add(nodeId)
    }
    selectedNodeIds.value = new Set(selectedNodeIds.value)
  }

  const clearSelection = () => {
    selectedNodeIds.value.clear()
    selectedNodeIds.value = new Set(selectedNodeIds.value)
  }

  const handleShowRecommendations = () => {
    const allNodes = cloudStore.instances
    if (allNodes.length === 0) {
      message.info(translate('cloud.recommendations.noNodes'))
      return
    }

    const latencyMap = new Map<string, number>()
    if (latencyResults.value.length > 0) {
      latencyResults.value.forEach((result) => {
        if (result.status === 'ok') {
          latencyMap.set(result.code, result.latency)
        }
      })
    }

    const recommendations = getRecommendedNodes(allNodes, {
      preferLowLatency: true,
      preferLowRisk: true,
      preferReachable: true,
      preferRecent: false,
    }, latencyMap)

    const topNodes = recommendations.slice(0, 5)
    if (topNodes.length === 0) {
      message.info(translate('cloud.recommendations.noneAvailable'))
      return
    }

    const recommendationText = topNodes.map((result, index) => {
      const { node, score, reasons, antiBlockingScore } = result
      const ipv4 = node.ipv4 || 'N/A'
      const region = node.region ? formatNodeRegion(node.region) : 'N/A'
      return `${index + 1}. ${node.label} (${region})\n   Score: ${score}/100\n   Anti-blocking: ${antiBlockingScore ?? 'N/A'}/100\n   IP: ${ipv4}\n   ${reasons.join(', ')}`
    }).join('\n\n')

    logInfo('=== Recommended Nodes ===\n' + recommendationText)
    message.success(translate('cloud.recommendations.title') + ': Check console for details')
  }

  const handleBatchTestConnectivity = async () => {
    if (selectedNodeIds.value.size === 0) {
      message.info(translate('cloud.batch.noSelection'))
      return
    }

    batchOperating.value = true
    try {
      const promises = Array.from(selectedNodeIds.value).map((id) => cloudStore.testNodeSpeedTest(id))
      await Promise.all(promises)
      message.success(translate('cloud.batch.testComplete', { count: selectedNodeIds.value.size }))
    } catch (error) {
      handleError(error)
    } finally {
      batchOperating.value = false
    }
  }

  const handleBatchRotateIP = async () => {
    if (selectedNodeIds.value.size === 0) {
      message.info(translate('cloud.batch.noSelection'))
      return
    }

    const confirmed = await confirm(
      translate('cloud.batch.rotateIP'),
      translate('cloud.batch.rotateConfirm', { count: selectedNodeIds.value.size }),
    )
    if (!confirmed) return

    batchOperating.value = true
    let successCount = 0
    let failCount = 0

    try {
      for (const nodeId of selectedNodeIds.value) {
        try {
          await cloudStore.rotateIP(nodeId)
          successCount++
        } catch (error) {
          failCount++
          logError(`[CloudView] Failed to rotate IP for ${nodeId}:`, error)
        }
      }

      if (successCount > 0) {
        message.success(translate('cloud.batch.rotateComplete', { success: successCount, fail: failCount }))
      } else {
        message.error(translate('cloud.batch.allFailed'))
      }

      clearSelection()
      await cloudStore.refreshInstances(true)
    } catch (error) {
      handleError(error)
    } finally {
      batchOperating.value = false
    }
  }

  const handleBatchDestroy = async () => {
    if (selectedNodeIds.value.size === 0) {
      message.info(translate('cloud.batch.noSelection'))
      return
    }

    const confirmed = await confirm(
      translate('cloud.batch.destroy'),
      translate('cloud.batch.destroyConfirm', { count: selectedNodeIds.value.size }),
    )
    if (!confirmed) return

    batchOperating.value = true
    let successCount = 0
    let failCount = 0

    try {
      for (const nodeId of selectedNodeIds.value) {
        try {
          await cloudStore.destroyInstance(nodeId)
          successCount++
        } catch (error) {
          failCount++
          logError(`[CloudView] Failed to destroy ${nodeId}:`, error)
        }
      }

      if (successCount > 0) {
        message.success(translate('cloud.batch.destroyComplete', { success: successCount, fail: failCount }))
      } else {
        message.error(translate('cloud.batch.allFailed'))
      }

      clearSelection()
      await cloudStore.refreshInstances(true)
    } catch (error) {
      handleError(error)
    } finally {
      batchOperating.value = false
    }
  }

  const handleUseNode = async (node: CloudNode | Record<string, any>) => {
    const target = node as CloudNode
    cloudStore.markNodeStatus(target.instanceId, 'applying')
    applyingNodeId.value = target.instanceId
    try {
      await cloudStore.applyNodeToProfile(target)
      if (kernelApiStore.running) {
        await kernelApiStore.restartCore()
      } else {
        await kernelApiStore.startCore()
      }
      cloudStore.markNodeStatus(target.instanceId, 'connected')
      cloudStore.refreshInstances(true).catch((error) => {
        logError('[CloudView] Silent refresh after apply failed:', error)
      })
      message.success(translate('cloud.nodes.applied'))
      message.info(translate('cloud.nodes.applyTip'))
    } catch (error) {
      cloudStore.markNodeStatus(target.instanceId, 'error')
      handleError(error)
    } finally {
      applyingNodeId.value = ''
    }
  }

  const copyNodeConfig = async (record: CloudNode | Record<string, any>) => {
    const node = record as CloudNode
    const deployment = cdnStore.deploymentFor(node.instanceId)
    const links = buildNodeProtocolLinks(record, deployment)
    if (!links.length) {
      message.error(translate('cloud.errors.noProtocols'))
      return
    }

    const payload = links.map((item) => `${item.label}: ${item.url}`).join('\n')
    await copyText(payload)
  }

  const handleDeployCdn = async (record: CloudNode | Record<string, any>) => {
    const node = record as CloudNode
    if (!hasCdnRelay(node)) {
      message.error(translate('cdn.node.requiresRelay'))
      return
    }
    if (!cdnStore.isVerified) {
      message.error(translate('cdn.error.tokenNotVerified'))
      return
    }
    const ok = await cdnStore.deploy(node.instanceId)
    if (ok) {
      message.success('common.success')
    } else if (cdnStore.lastError) {
      message.error(cdnStore.lastError)
    }
  }

  const handleDeleteCdn = async (record: CloudNode | Record<string, any>) => {
    const node = record as CloudNode
    try {
      await confirm('common.warning', translate('cdn.confirm.delete', { label: node.label }))
    } catch {
      return
    }
    const ok = await cdnStore.remove(node.instanceId)
    if (ok) {
      message.success('common.success')
    } else if (cdnStore.lastError) {
      message.error(cdnStore.lastError)
    }
  }

  const handleRotateIP = async (record: CloudNode | Record<string, any>) => {
    const node = record as CloudNode
    if (isManualNode(node)) {
      message.error(translate('cloud.nodes.rotateIPBlocked'))
      return
    }

    try {
      await confirm('common.warning', translate('cloud.nodes.rotateIPConfirm'))
    } catch {
      return
    }

    rotatingNodeId.value = node.instanceId
    try {
      const newNode = await cloudStore.rotateIP(node.instanceId)
      message.success(translate('cloud.nodes.rotateIPSuccess'))
      logInfo('[CloudView] IP rotated successfully. New node:', newNode.instanceId)
    } catch (error) {
      handleError(error)
    } finally {
      rotatingNodeId.value = ''
    }
  }

  const handleRepairNode = async (record: CloudNode | Record<string, any>) => {
    const node = record as CloudNode
    if (isManualNode(node)) {
      message.error(translate('cloud.nodes.repairBlocked'))
      return
    }

    try {
      await confirm('common.warning', translate('cloud.nodes.repairConfirm', { label: node.label }))
    } catch {
      return
    }

    redeployingNodeId.value = node.instanceId
    try {
      const repaired = await cloudStore.redeployInstance(node.instanceId)
      const sameNode = repaired.instanceId === node.instanceId
      message.success(translate(sameNode ? 'cloud.nodes.repairSuccess' : 'cloud.nodes.redeploySuccess'))
      logInfo('[CloudView] Repair/redeploy submitted. Node:', repaired.instanceId)
    } catch (error) {
      handleError(error)
    } finally {
      redeployingNodeId.value = ''
    }
  }

  const handleDestroy = async (record: CloudNode | Record<string, any>) => {
    const node = record as CloudNode
    try {
      const messageText = isManualNode(node)
        ? translate('cloud.manual.confirmRemove', { label: node.label })
        : translate('cloud.confirmDestroy', { label: node.label })
      await confirm('common.warning', messageText)
    } catch {
      return
    }

    try {
      await cloudStore.destroyInstance(node.instanceId)
      message.success('common.success')
    } catch (error) {
      handleError(error)
    }
  }

  const handleCopyNodeConfig = async (node: ManagedCloudNode) => {
    try {
      const ipv4 = node.ipv4 || 'N/A'
      const ipv6 = node.ipv6 || 'N/A'
      const protocols: string[] = []

      if (node.ssPort && node.ssPassword) {
        protocols.push(`Shadowsocks: ${ipv4}:${node.ssPort} (${node.ssPassword})`)
      }
      if (node.hysteriaPort && node.hysteriaPassword) {
        protocols.push(`Hysteria2: ${ipv4}:${node.hysteriaPort} (${node.hysteriaPassword})`)
      }
      if (node.vlessPort && node.vlessUUID) {
        protocols.push(`VLESS: ${ipv4}:${node.vlessPort} (UUID: ${node.vlessUUID})`)
      }
      if (node.trojanPort && node.trojanPassword) {
        protocols.push(`Trojan: ${ipv4}:${node.trojanPort} (${node.trojanPassword})`)
      }

      const configText = `
Node: ${node.label}
Region: ${node.region ? formatNodeRegion(node.region) : 'N/A'}
IPv4: ${ipv4}
IPv6: ${ipv6}

Protocols:
${protocols.join('\n')}
`.trim()

      await ClipboardSetText(configText)
      message.success(translate('cloud.quickActions.configCopied'))
    } catch (error) {
      logError('CopyNodeConfig', error)
      message.error(translate('cloud.quickActions.copyFailed'))
    }
  }

  const handleQuickTestConnectivity = async (node: ManagedCloudNode) => {
    try {
      message.info(translate('cloud.quickActions.testingConnectivity'))
      await cloudStore.testNodeSpeedTest(node.instanceId)
      const ms = node.speedMs
      const statusText = ms != null && ms >= 0 ? `${ms}ms` : translate('cloud.speed.timeout')
      message.success(translate('cloud.quickActions.testComplete', { status: statusText }))
    } catch (error) {
      logError('QuickTestConnectivity', error)
      message.error(translate('cloud.quickActions.testFailed'))
    }
  }

  const handleTestAllSpeed = async () => {
    speedTestAllLoading.value = true
    try {
      await cloudStore.testAllNodesSpeed()
      message.success(translate('cloud.speed.testAllComplete'))
    } catch (error) {
      handleError(error)
    } finally {
      speedTestAllLoading.value = false
    }
  }

  const handleToggleLoadBalance = async () => {
    loadBalanceLoading.value = true
    try {
      if (cloudStore.loadBalanceEnabled) {
        await cloudStore.stopLoadBalance()
      } else {
        await cloudStore.startLoadBalance()
        if (!cloudStore.loadBalanceEnabled) {
          message.error(translate('cloud.loadBalance.startFailed'))
        }
      }
    } catch (error) {
      handleError(error)
    } finally {
      loadBalanceLoading.value = false
    }
  }

  const tableContextMenu = computed(() => [
    {
      label: translate('cloud.quickActions.useNode'),
      handler: (record: ManagedCloudNode) => handleUseNode(record),
    },
    {
      label: translate('cloud.quickActions.copyConfig'),
      handler: (record: ManagedCloudNode) => handleCopyNodeConfig(record),
    },
    {
      label: translate('cloud.quickActions.testConnectivity'),
      handler: (record: ManagedCloudNode) => handleQuickTestConnectivity(record),
    },
    {
      label: translate('cloud.quickActions.rotateIP'),
      handler: (record: ManagedCloudNode) => handleRotateIP(record),
      hidden: (record: ManagedCloudNode) => isManualNode(record) || record.connectivityStatus !== 'blocked',
    },
    {
      label: translate('cloud.quickActions.repair'),
      handler: (record: ManagedCloudNode) => handleRepairNode(record),
      hidden: (record: ManagedCloudNode) => isManualNode(record),
    },
    {
      label: translate('cdn.node.deploy'),
      handler: (record: ManagedCloudNode) => handleDeployCdn(record),
      hidden: (record: ManagedCloudNode) =>
        !hasCdnRelay(record) || Boolean(cdnStore.deploymentFor(record.instanceId)),
    },
    {
      label: translate('cdn.node.delete'),
      handler: (record: ManagedCloudNode) => handleDeleteCdn(record),
      hidden: (record: ManagedCloudNode) => !cdnStore.deploymentFor(record.instanceId),
    },
    {
      label: translate('cloud.quickActions.destroy'),
      handler: (record: ManagedCloudNode) => handleDestroy(record),
    },
  ])

  return {
    applyingNodeId,
    batchOperating,
    cdnStore,
    clearSelection,
    copyNodeConfig,
    handleBatchDestroy,
    handleBatchRotateIP,
    handleBatchTestConnectivity,
    handleDeleteCdn,
    handleDeployCdn,
    handleRepairNode,
    handleDestroy,
    handleRotateIP,
    handleShowRecommendations,
    handleTestAllSpeed,
    handleToggleLoadBalance,
    handleUseNode,
    loadBalanceLoading,
    redeployingNodeId,
    rotatingNodeId,
    selectedNodeIds,
    speedTestAllLoading,
    tableContextMenu,
    toggleNodeSelection,
  }
}
