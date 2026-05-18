<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { useI18n } from 'vue-i18n'

import { ExportCloudBackup, TestAllCloudRegions } from '@/bridge'
import { useCloudStore, useKernelApiStore } from '@/stores'
import { NODE_HISTORY_RETENTION_MS } from '@/stores/cloud/constants'
import { formatDate, formatRelativeTime, message } from '@/utils'
import { logError, logInfo } from '@/utils/logger'
import { isOnline } from '@/utils/offline'

import ConnectivityChart from '@/components/ConnectivityChart.vue'
import LatencyChart from '@/components/LatencyChart.vue'
import { useModal } from '@/components/Modal'

import {
  getDeploymentSteps as getNodeDeploymentSteps,
  getDeploymentSummary as getNodeDeploymentSummary,
  hasHysteria,
  hasShadowsocks,
  hasTrojan,
  hasVless,
  isPublicIPv4,
  shouldShowDeploymentProgress,
} from './cloudNodeDisplay'
import {
  buildPlanOptions,
  buildRegionOptions,
  formatSpeedFailureReason,
  formatNodeRegion as formatNodeRegionLabel,
  formatPlan as formatCloudPlan,
  formatRegion as formatCloudRegion,
  getConnectivityColor,
  getConnectivityLabel,
  isSpeedTimeoutError,
  getStatusColor,
  getStatusLabel,
} from './cloudViewPresentation'
import MultiDeployModal from './components/MultiDeployModal.vue'
import SSHConfigForm from './components/SSHConfigForm.vue'
import { useCloudViewActions } from './useCloudViewActions'
import { useCloudViewBackup } from './useCloudViewBackup'
import { useCloudViewManualNodes } from './useCloudViewManualNodes'
import { defaultCloudLabel, useCloudViewMeta } from './useCloudViewMeta'
import { useCloudViewMonitoring } from './useCloudViewMonitoring'
import { useCloudViewTable } from './useCloudViewTable'

import type { ManagedCloudNode } from '@/stores/cloud'
import type { CloudNode, RegionLatency } from '@/types/cloud'

const { t } = useI18n()
const cloudStore = useCloudStore()
const kernelApiStore = useKernelApiStore()
const [Modal, modalApi] = useModal({
  minWidth: '52',
  maskClosable: true,
})

const form = reactive({
  label: defaultCloudLabel(cloudStore.currentProvider),
  region: '',
  plan: '',
})

const loadingMeta = computed(() => cloudStore.loadingPlans || cloudStore.loadingRegions)
const hasApiKey = computed(() => cloudStore.config.apiKey.trim().length > 0)

// Latency testing state
const testingLatency = ref(false)
const latencyResults = ref<RegionLatency[]>([])
const showLatencyResults = ref(false)

// SSH deploy state
const isSSHProvider = computed(() => cloudStore.currentProvider === 'ssh')
const showMultiDeployModal = ref(false)
const multiDeployModalRef = ref<{
  canDeploy: boolean
  handleDeploy: () => Promise<unknown[] | null>
} | null>(null)

const handleSSHDeploy = async (extra: Record<string, string>) => {
  try {
    resetSSHDeployProgress()
    await cloudStore.createSSHInstance(extra)
    message.success('SSH 节点部署完成')
  } catch (err: any) {
    message.error('SSH 部署失败: ' + (err.message || String(err)))
  }
}

const multiDeploySubmitDisabled = computed(() => !(multiDeployModalRef.value?.canDeploy ?? false))

const handleMultiDeploySubmit = async () => {
  const results = await multiDeployModalRef.value?.handleDeploy()
  if (!results) {
    return false
  }

  await cloudStore.refreshInstances(true)
  message.success('批量部署完成')
  return true
}

const providerOptions = computed(() =>
  cloudStore.availableProviders.map((provider) => ({
    label: provider.displayName,
    value: provider.name,
  })),
)

const regionOptions = computed(() =>
  buildRegionOptions(cloudStore.regions, latencyResults.value, cloudStore.currentProvider, t),
)

const availablePlanIds = computed(() => cloudStore.availability[form.region] || [])

const planOptions = computed(() =>
  buildPlanOptions(cloudStore.plans, cloudStore.availability, form.region, t),
)

const isManualNode = (node: CloudNode | Record<string, any>) => (node as any).provider === 'manual'

const regionMap = computed(() => new Map(
  cloudStore.regions.map((r) => [r.id, formatCloudRegion(r, cloudStore.currentProvider, t)]),
))
const planMap = computed(() => {
  const map = new Map()
  for (const p of cloudStore.plans) {
    try {
      map.set(p.id, formatCloudPlan(p, t))
    } catch (error) {
      console.error('[CloudView] Error formatting plan:', p.id, error)
      // Fallback to plan ID if formatting fails
      map.set(p.id, p.id)
    }
  }
  console.log('[CloudView] planMap updated, size:', map.size, 'plans:', cloudStore.plans.length)
  return map
})

// Function to translate region ID or name in node list
function formatNodeRegion(regionId: string): string {
  return formatNodeRegionLabel(regionId, regionMap.value, t)
}

const {
  clearFilters,
  columns,
  filterConnectivity,
  filterStatus,
  hasActiveFilters,
  searchQuery,
  sortBy,
  sortOrder,
  tableData,
} = useCloudViewTable(cloudStore, formatNodeRegion)

const lastInstancesUpdateRelative = computed(() => {
  if (!cloudStore.instancesUpdatedAt) {
    return ''
  }
  return formatRelativeTime(cloudStore.instancesUpdatedAt)
})

const lastInstancesUpdateExact = computed(() => {
  if (!cloudStore.instancesUpdatedAt) {
    return ''
  }
  return formatDate(cloudStore.instancesUpdatedAt, 'YYYY-MM-DD HH:mm:ss')
})

const disableDeploy = computed(
  () => !hasApiKey.value || !form.region || !form.plan || !form.label.trim(),
)

const handleError = (error: unknown) => {
  let messageText = error instanceof Error ? error.message : String(error)
  logError('[Cloud Deploy]', error)
  logError('[Cloud Deploy]', messageText)

  // 检测并翻译 Vultr API 错误信息
  const lowerMessage = messageText.toLowerCase()

  // "requires a plan with at least X MB memory"
  const memoryMatch = messageText.match(/at least (\d+)\s*MB memory/i)
  if (memoryMatch) {
    const required = memoryMatch[1]
    messageText = t('cloud.errors.memoryTooLow', { required })
  }
  // "plan is not available in the selected region"
  else if (lowerMessage.includes('plan') && lowerMessage.includes('not available') && lowerMessage.includes('region')) {
    messageText = t('cloud.errors.planUnavailable')
  }
  // "API key" 相关错误
  else if (lowerMessage.includes('api key') || lowerMessage.includes('apikey')) {
    const missingHints = ['missing', 'empty', 'require', 'not configured', 'cannot be empty']
    const invalidHints = ['invalid', 'unauthorized', 'forbidden']
    const isMissingKey = missingHints.some((hint) => lowerMessage.includes(hint))
    const isInvalidKey = invalidHints.some((hint) => lowerMessage.includes(hint))

    if (isMissingKey) {
      messageText = t('cloud.errors.apiKeyRequired')
    } else if (isInvalidKey) {
      messageText = t('cloud.errors.apiKeyInvalid')
    }
  }

  message.error(messageText)
}

const {
  ensurePlanForRegion,
  fetchMeta,
  handleProviderChange,
  handleRefreshInstances,
  handleSaveConfig,
  handleTestLatency,
} = useCloudViewMeta({
  cloudStore,
  form,
  hasApiKey,
  testingLatency,
  latencyResults,
  showLatencyResults,
  handleError,
  translate: t,
  testAllCloudRegions: TestAllCloudRegions,
})

const { handleBackupConfig, handleRestoreConfig } = useCloudViewBackup({
  cloudStore,
  fetchMeta,
  handleError,
  translate: t,
})

const { openEditManualNode, openImportModal, openManualNodeModal } = useCloudViewManualNodes({
  cloudStore,
  modalApi,
  translate: t,
})

const {
  applyingNodeId,
  batchOperating,
  cdnStore,
  clearSelection,
  copyNodeConfig,
  handleBatchDestroy,
  handleBatchRotateIP,
  handleBatchTestConnectivity,
  handleDestroy,
  handleRepairNode,
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
} = useCloudViewActions({
  cloudStore,
  kernelApiStore,
  latencyResults,
  translate: t,
  handleError,
  formatNodeRegion,
  isManualNode,
})

const {
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
} = useCloudViewMonitoring({
  cloudStore,
  tableData,
  translate: t,
  handleTestAllSpeed,
})

const handleDeploy = async () => {
  logInfo('[CloudView] handleDeploy invoked', {
    provider: cloudStore.currentProvider,
    hasApiKey: hasApiKey.value,
    label: form.label,
    region: form.region,
    plan: form.plan,
    disabled: disableDeploy.value,
  })
  if (disableDeploy.value) {
    logInfo('[CloudView] handleDeploy blocked: form incomplete')
    message.error(t('cloud.errors.formIncomplete'))
    return
  }
  try {
    message.info(t('cloud.create.deployingHint'))
    logInfo('[CloudView] handleDeploy ensuring region availability', { region: form.region })
    await cloudStore.ensureRegionAvailability(form.region)
    const ids = availablePlanIds.value
    if (ids.length && !ids.includes(form.plan)) {
      ensurePlanForRegion(form.region)
      if (!ids.includes(form.plan)) {
        logInfo('[CloudView] handleDeploy blocked: selected plan unavailable after refresh', {
          region: form.region,
          plan: form.plan,
          availablePlanIds: ids,
        })
        message.error(t('cloud.errors.planUnavailable'))
        return
      }
    }
    logInfo('[CloudView] handleDeploy calling createInstance', {
      label: form.label.trim(),
      region: form.region,
      plan: form.plan,
    })
    await cloudStore.createInstance({
      label: form.label.trim(),
      region: form.region,
      plan: form.plan,
    })
    logInfo('[CloudView] handleDeploy createInstance completed')
    message.success('common.success')
    form.label = defaultCloudLabel(cloudStore.currentProvider)
    await cloudStore.refreshInstances(true)
  } catch (error) {
    handleError(error)
  }
}

const getDeploymentSteps = (node: CloudNode | Record<string, any>) => getNodeDeploymentSteps(node, t)

const getDeploymentSummary = (node: CloudNode | Record<string, any>) => getNodeDeploymentSummary(node, t)

const nodeHistoryRetentionDays = Math.round(NODE_HISTORY_RETENTION_MS / (24 * 60 * 60 * 1000))

const handleExportChartHistory = async () => {
  if (!viewingChartNode.value) {
    return
  }

  try {
    const instanceId = viewingChartNode.value.instanceId
    const history = cloudStore.nodeHistory[instanceId] || { connectivity: [], speed: [] }
    const path = await ExportCloudBackup(JSON.stringify({
      version: 1,
      exportedAt: new Date().toISOString(),
      retentionDays: nodeHistoryRetentionDays,
      node: {
        instanceId,
        label: viewingChartNode.value.label,
        region: viewingChartNode.value.region,
        plan: viewingChartNode.value.plan,
        ipv4: viewingChartNode.value.ipv4 || '',
        ipv6: viewingChartNode.value.ipv6 || '',
      },
      history,
    }, null, 2))
    if (!path) {
      return
    }
    message.success(t('cloud.charts.exported'))
  } catch (error) {
    handleError(error)
  }
}

const handleClearChartHistory = async () => {
  if (!viewingChartNode.value) {
    return
  }
  if (!window.confirm(t('cloud.charts.clearConfirm', { label: viewingChartNode.value.label }))) {
    return
  }

  try {
    await cloudStore.clearNodeHistory(viewingChartNode.value.instanceId)
    message.success(t('cloud.charts.cleared'))
  } catch (error) {
    handleError(error)
  }
}

onMounted(() => {
  // Hydrate CDN state once so per-node Deploy/Delete actions know which
  // workers are already configured. Failures are non-fatal — Cloud view
  // continues to work without CDN UI.
  cdnStore.ensureLoaded().catch((err) => {
    logError('[CloudView] failed to load CDN state:', err)
  })
})
</script>

<template>
  <div class="cloud-view grid gap-16 min-w-0">
    <Card class="min-w-0">
      <template #title>
        <div class="flex flex-wrap items-center gap-8">
          <span>{{ t('cloud.credentials.title') }}</span>
          <span v-if="!isOnline" class="text-12 px-8 py-2 rounded bg-yellow-500/20 text-yellow-600">
            {{ t('cloud.offline.indicator') }}
          </span>
        </div>
      </template>
      <div class="flex flex-col gap-12 py-8">
        <div class="flex flex-wrap items-center gap-8">
          <span id="cloud-provider-label" class="text-14 shrink-0">{{ t('cloud.provider.label') }}:</span>
          <Select
            v-model="cloudStore.currentProvider"
            :options="providerOptions"
            @change="handleProviderChange"
            size="small"
            auto-size
            aria-labelledby="cloud-provider-label"
          />
        </div>
        <div v-if="!isSSHProvider" class="flex flex-col gap-8">
          <Input
            v-model="cloudStore.config.apiKey"
            type="password"
            :show-password="true"
            :auto-size="true"
            :placeholder="t('cloud.credentials.placeholder')"
            class="w-full"
            aria-label="API Key"
          />
          <div class="flex flex-wrap items-center gap-8">
            <Button
              @click="handleSaveConfig"
              type="primary"
              :loading="cloudStore.savingConfig"
              :disabled="!hasApiKey"
            >
              {{ t('cloud.credentials.save') }}
            </Button>
            <Button
              @click="fetchMeta"
              :loading="loadingMeta"
              :disabled="!hasApiKey"
              type="link"
            >
              {{ t('cloud.credentials.syncMeta') }}
            </Button>
            <Button
              @click="handleBackupConfig"
              type="link"
              :disabled="!hasApiKey"
            >
              {{ t('cloud.backup.export') }}
            </Button>
            <Button
              @click="handleRestoreConfig"
              type="link"
            >
              {{ t('cloud.backup.import') }}
            </Button>
          </div>
        </div>
        <!-- SSH Config Form (replaces API key for SSH provider) -->
        <SSHConfigForm v-if="isSSHProvider" @deploy="handleSSHDeploy" />
        <div v-else class="text-12 text-secondary">
          {{ t('cloud.credentials.hint') }}
        </div>
      </div>
    </Card>

    <Card v-if="!isSSHProvider" :title="t('cloud.create.title')" class="min-w-0">
      <div class="flex flex-col gap-12 py-8">
        <div class="flex flex-wrap items-center gap-8">
          <div class="min-w-180 flex-1">
            <Select
              v-model="form.region"
              :options="regionOptions"
              :placeholder="t('cloud.create.regionPlaceholder')"
              :disabled="!regionOptions.length"
              auto-size
            />
          </div>
          <div class="min-w-320 flex-[2]">
            <Select
              v-model="form.plan"
              :options="planOptions"
              :placeholder="t('cloud.create.planPlaceholder')"
              :disabled="!planOptions.length"
              auto-size
            />
          </div>
          <div class="min-w-220 flex-1">
            <Input
              v-model="form.label"
              :auto-size="true"
              :placeholder="t('cloud.create.labelPlaceholder')"
              class="w-full"
            />
          </div>
        </div>
        <div class="flex flex-wrap items-center gap-8">
          <Button
            @click="handleDeploy"
            type="primary"
            :loading="cloudStore.creatingInstance"
            :disabled="disableDeploy"
          >
            {{ t('cloud.create.deploy') }}
          </Button>
          <Button
            @click="() => { showMultiDeployModal = true }"
            type="normal"
            :disabled="!hasApiKey || !cloudStore.regions.length"
          >
            批量部署
          </Button>
          <Button
            @click="handleTestLatency"
            type="normal"
            :loading="testingLatency"
            :disabled="!hasApiKey || testingLatency"
          >
            {{ testingLatency ? t('cloud.latency.testing') : t('cloud.latency.test') }}
          </Button>
          <Button
            @click="handleRefreshInstances"
            type="link"
            :loading="cloudStore.loadingInstances"
            :disabled="!hasApiKey"
          >
            {{ t('cloud.create.refresh') }}
          </Button>
          <Button
            @click="handleTestAllSpeed"
            type="link"
            :loading="speedTestAllLoading"
            :disabled="tableData.length === 0"
          >
            {{ t('cloud.speed.testAll') }}
          </Button>
          <Button
            @click="handleToggleLoadBalance"
            :type="cloudStore.loadBalanceEnabled ? 'primary' : 'link'"
            :loading="loadBalanceLoading"
            :disabled="tableData.length < 2 && !cloudStore.loadBalanceEnabled"
          >
            {{
              loadBalanceLoading
                ? cloudStore.loadBalanceEnabled
                  ? t('cloud.loadBalance.stopping')
                  : t('cloud.loadBalance.starting')
                : cloudStore.loadBalanceEnabled
                  ? t('cloud.loadBalance.disable')
                  : t('cloud.loadBalance.enable')
            }}
          </Button>
          <Button
            @click="handleShowRecommendations"
            type="link"
            :disabled="tableData.length === 0"
          >
            {{ t('cloud.recommendations.showButton') }}
          </Button>
          <Button @click="openManualNodeModal" type="normal">
            {{ t('cloud.manual.add') }}
          </Button>
          <Button @click="openImportModal" type="normal">
            {{ t('cloud.manual.import') }}
          </Button>
        </div>
        <div v-if="cloudStore.creatingInstance" class="text-12 text-tertiary">
          {{ t('cloud.create.deployingProgress') }}
        </div>
        <div v-if="cloudStore.loadBalanceEnabled && cloudStore.loadBalanceListenPort" class="text-12 text-primary">
          {{ t('cloud.loadBalance.running', { port: cloudStore.loadBalanceListenPort }) }}
        </div>
      </div>
    </Card>

    <!-- Multi-Deploy section handled in modal below -->

    <Card :title="t('cloud.nodes.title')" class="min-w-0">
      <div class="flex flex-col gap-12 py-8">
        <div
          v-if="cloudStore.loadingInstances || lastInstancesUpdateRelative"
          class="flex flex-wrap items-center justify-between gap-6 text-12 text-secondary"
        >
          <div class="flex flex-wrap items-center gap-4">
            <span v-if="cloudStore.loadingInstances">{{ t('cloud.nodes.loading') }}</span>
            <span v-if="cloudStore.loadingInstances" class="text-tertiary">
              {{ t('cloud.nodes.loadingHint') }}
            </span>
          </div>
          <div
            v-if="lastInstancesUpdateRelative"
            class="flex items-center gap-2 text-tertiary"
            :title="lastInstancesUpdateExact || ''"
          >
            {{ t('cloud.nodes.lastSynced', { time: lastInstancesUpdateRelative }) }}
          </div>
        </div>

        <div v-if="!tableData.length">
          <div v-if="cloudStore.loadingInstances" class="py-32 text-center text-14">
            <div>{{ t('cloud.nodes.loading') }}</div>
            <div class="mt-6 text-12 text-tertiary">
              {{ t('cloud.nodes.loadingHint') }}
            </div>
          </div>
          <div v-else class="py-32">
            <Empty>
              <template #description>{{ t('cloud.nodes.empty') }}</template>
            </Empty>
          </div>
        </div>

        <!-- Search and Filter Controls -->
        <div v-if="tableData.length || hasActiveFilters" class="flex flex-wrap items-center gap-8">
          <!-- Search Box -->
          <div class="flex-1 min-w-200">
            <Input
              v-model="searchQuery"
              :placeholder="t('cloud.search.placeholder')"
              size="small"
              clearable
            />
          </div>

          <!-- Connectivity Filter -->
          <Select
            v-model="filterConnectivity"
            :options="[
              { label: t('cloud.filter.allConnectivity'), value: 'all' },
              { label: t('cloud.connectivity.reachable'), value: 'reachable' },
              { label: t('cloud.connectivity.icmp_blocked'), value: 'icmp_blocked' },
              { label: t('cloud.connectivity.blocked'), value: 'blocked' },
              { label: t('cloud.connectivity.testing'), value: 'testing' },
              { label: t('cloud.connectivity.unknown'), value: 'unknown' },
            ]"
            :placeholder="t('cloud.filter.connectivity')"
            size="small"
            class="min-w-120"
          />

          <!-- Status Filter -->
          <Select
            v-model="filterStatus"
            :options="[
              { label: t('cloud.filter.allStatus'), value: 'all' },
              { label: t('cloud.status.unknown'), value: 'unknown' },
              { label: t('cloud.status.pending'), value: 'pending' },
              { label: t('cloud.status.applying'), value: 'applying' },
              { label: t('cloud.status.connected'), value: 'connected' },
              { label: t('cloud.status.error'), value: 'error' },
            ]"
            :placeholder="t('cloud.filter.status')"
            size="small"
            class="min-w-120"
          />

          <!-- Sort By -->
          <Select
            v-model="sortBy"
            :options="[
              { label: t('cloud.sort.default'), value: '' },
              { label: t('cloud.table.label'), value: 'label' },
              { label: t('cloud.table.region'), value: 'region' },
              { label: t('cloud.table.status'), value: 'status' },
              { label: t('cloud.table.createdAt'), value: 'createdAt' },
            ]"
            :placeholder="t('cloud.sort.sortBy')"
            size="small"
            class="min-w-140"
          />

          <!-- Sort Order Toggle -->
          <Button
            v-if="sortBy"
            @click="sortOrder = sortOrder === 'asc' ? 'desc' : 'asc'"
            type="text"
            size="small"
            :title="sortOrder === 'asc' ? t('cloud.sort.ascending') : t('cloud.sort.descending')"
          >
            {{ sortOrder === 'asc' ? '↑' : '↓' }}
          </Button>

          <!-- Clear Filters Button -->
          <Button
            v-if="hasActiveFilters || sortBy"
            @click="clearFilters"
            type="text"
            size="small"
          >
            {{ t('cloud.filter.clear') }}
          </Button>

          <!-- Result Count -->
          <span v-if="hasActiveFilters" class="text-12 text-secondary">
            {{ t('cloud.search.results', { count: tableData.length }) }}
          </span>
        </div>

        <!-- Batch operations toolbar -->
        <div v-if="selectedNodeIds.size > 0" class="flex flex-wrap items-center gap-8 p-12 bg-primary/5 rounded">
          <span class="text-14 font-medium">{{ t('cloud.batch.selected', { count: selectedNodeIds.size }) }}</span>
          <Button
            @click="handleBatchTestConnectivity"
            type="normal"
            size="small"
            :loading="batchOperating"
          >
            {{ t('cloud.batch.testConnectivity') }}
          </Button>
          <Button
            @click="handleBatchRotateIP"
            type="normal"
            size="small"
            :loading="batchOperating"
          >
            {{ t('cloud.batch.rotateIP') }}
          </Button>
          <Button
            @click="handleBatchDestroy"
            type="normal"
            size="small"
            :loading="batchOperating"
          >
            {{ t('cloud.batch.destroy') }}
          </Button>
          <Button
            @click="clearSelection"
            type="link"
            size="small"
          >
            {{ t('common.cancel') }}
          </Button>
        </div>

        <div v-else class="py-8">
          <div class="min-w-0 max-w-full overflow-x-auto">
          <Table :columns="columns" :data-source="tableData" :menu="tableContextMenu" @row-click="(record: any) => toggleNodeSelection(record.instanceId)">
            <template #selection="{ record }">
              <div class="flex items-center justify-center" @click.stop>
                <input
                  type="checkbox"
                  :checked="selectedNodeIds.has(record.instanceId)"
                  @change="toggleNodeSelection(record.instanceId)"
                  class="cursor-pointer w-16 h-16"
                />
              </div>
            </template>
            <template #label="{ record }">
              <div>
                <div class="font-bold text-14">{{ record.label }}</div>
                <div class="text-12 text-secondary mt-2">{{ planMap.get(record.plan) || record.plan }}</div>
              </div>
            </template>
            <template #region="{ record }">
            <div>{{ formatNodeRegion(record.region) }}</div>
            </template>
            <template #status="{ record }">
              <div class="flex flex-col gap-2">
                <div class="flex items-center gap-4">
                  <span class="capitalize">{{ record.status }}</span>
                  <Tag :color="getStatusColor(record.statusText)" size="small">
                    {{ getStatusLabel(record.statusText, t) }}
                  </Tag>
                <Tag v-if="isManualNode(record)" color="cyan" size="small">
                  {{ t('cloud.manual.badge') }}
                </Tag>
              </div>
              <div v-if="shouldShowDeploymentProgress(record)" class="deployment-progress">
                <div class="deployment-progress__summary">
                  {{ getDeploymentSummary(record) }}
                </div>
                <div class="deployment-progress__steps">
                  <div
                    v-for="(step, index) in getDeploymentSteps(record)"
                    :key="index"
                    class="deployment-progress__step"
                    :class="`deployment-progress__step--${step.state}`"
                  >
                    <span class="deployment-progress__bullet" />
                    <span class="deployment-progress__label">{{ step.label }}</span>
                  </div>
                </div>
              </div>
              </div>
            </template>
            <template #connectivity="{ record }">
              <div class="flex flex-col items-start gap-2">
                <div v-if="record.speedTesting" class="text-secondary text-12">
                  {{ t('cloud.speed.testing') }}
                </div>
                <div v-else-if="record.speedMbps != null" class="flex items-center gap-4">
                  <template v-if="record.speedMbps < 0">
                    <div class="flex flex-col items-start gap-2">
                      <Tag color="red" size="small">
                        {{ isSpeedTimeoutError(record.speedError) ? t('cloud.speed.timeout') : t('cloud.speed.failed') }}
                      </Tag>
                      <span
                        v-if="record.speedError"
                        class="text-secondary text-12"
                        :title="record.speedError"
                      >
                        {{ formatSpeedFailureReason(record.speedError, t) }}
                      </span>
                    </div>
                  </template>
                  <Tag
                    v-else
                    :color="record.speedMbps > 50 ? 'green' : record.speedMbps > 10 ? 'cyan' : 'red'"
                    size="small"
                    :title="record.speedError || ''"
                  >
                    {{ record.speedError ? t('cloud.speed.mbpsPartial', { speed: record.speedMbps }) : t('cloud.speed.mbps', { speed: record.speedMbps }) }}
                  </Tag>
                </div>
                <div v-else-if="record.speedMs != null" class="flex items-center gap-4">
                  <Tag
                    :color="record.speedMs < 0 ? 'red' : record.speedMs < 200 ? 'green' : record.speedMs < 500 ? 'cyan' : 'red'"
                    size="small"
                  >
                    {{ record.speedMs < 0 ? t('cloud.speed.timeout') : t('cloud.speed.ms', { ms: record.speedMs }) }}
                  </Tag>
                </div>
                <Tag
                  v-else-if="record.connectivityStatus"
                  :color="getConnectivityColor(record.connectivityStatus)"
                  size="small"
                >
                  {{ getConnectivityLabel(record.connectivityStatus, t) }}
                </Tag>
                <span v-else class="text-secondary">-</span>
              </div>
            </template>
          <template #ipAddresses="{ record }">
            <div class="flex flex-col gap-2">
              <div v-if="isPublicIPv4(record.ipv4)" class="flex items-center gap-2" style="font-size: 11px">
                <Tag size="small" color="cyan">v4</Tag>
                <span class="font-mono" style="max-width: 120px; overflow: hidden; text-overflow: ellipsis" :title="record.ipv4">{{ record.ipv4 }}</span>
              </div>
              <div v-if="record.ipv6" class="flex items-center gap-2" style="font-size: 11px">
                <Tag size="small" color="green">v6</Tag>
                <span class="font-mono" style="max-width: 120px; overflow: hidden; text-overflow: ellipsis" :title="record.ipv6">{{ record.ipv6 }}</span>
              </div>
              <div v-if="!isPublicIPv4(record.ipv4) && !record.ipv6">
                <span class="text-secondary">-</span>
              </div>
            </div>
          </template>
          <template #protocols="{ record }">
            <div class="protocol-list">
              <div v-if="hasShadowsocks(record)" class="protocol-item">
                <Tag size="small" color="primary">SS</Tag>
                <span class="protocol-meta">:{{ record.ssPort || record.port }}</span>
              </div>

              <div v-if="hasHysteria(record)" class="protocol-item">
                <Tag size="small" color="cyan">HY2</Tag>
                <span class="protocol-meta">:{{ record.hysteriaPort }}</span>
              </div>

              <div v-if="hasVless(record)" class="protocol-item">
                <Tag size="small" color="green">VLESS</Tag>
                <span class="protocol-meta">:{{ record.vlessPort }}</span>
              </div>

              <div v-if="hasTrojan(record)" class="protocol-item">
                <Tag size="small" color="red">Trojan</Tag>
                <span class="protocol-meta">:{{ record.trojanPort }}</span>
              </div>

              <div v-if="!hasShadowsocks(record) && !hasHysteria(record) && !hasVless(record) && !hasTrojan(record)" class="text-secondary">
                -
              </div>
            </div>
          </template>
          <!-- createdAt merged into sort/filter, no longer a dedicated column -->
          <template #actions="{ record }">
            <div class="flex items-center gap-4">
              <Button
                @click="handleUseNode(record)"
                type="primary"
                size="small"
                :loading="applyingNodeId === record.instanceId"
              >
                {{ t('cloud.nodes.apply') }}
              </Button>
              <Button
                v-if="isManualNode(record)"
                @click="openEditManualNode(record)"
                type="text"
                size="small"
              >
                {{ t('cloud.manual.edit') }}
              </Button>
              <Button @click="copyNodeConfig(record)" type="text" size="small" v-tips="'cloud.nodes.copyLink'">📋</Button>
              <Button @click="handleViewCharts(record as ManagedCloudNode)" type="text" size="small" v-tips="'cloud.charts.view'">📊</Button>
              <Button
                v-if="!isManualNode(record)"
                @click="handleRepairNode(record)"
                type="text"
                size="small"
                :loading="redeployingNodeId === record.instanceId"
              >
                {{ redeployingNodeId === record.instanceId ? t('cloud.nodes.repairing') : t('cloud.nodes.repair') }}
              </Button>
              <Button
                v-if="!isManualNode(record) && record.connectivityStatus === 'blocked'"
                @click="handleRotateIP(record)"
                type="text"
                size="small"
                :loading="rotatingNodeId === record.instanceId"
              >
                {{ rotatingNodeId === record.instanceId ? t('cloud.nodes.rotatingIP') : t('cloud.nodes.rotateIP') }}
              </Button>
              <Button
                @click="handleDestroy(record)"
                type="text"
                size="small"
                :loading="cloudStore.destroyingInstance === record.instanceId"
              >
                {{ t('cloud.nodes.destroy') }}
              </Button>
            </div>
          </template>
        </Table>
          </div>
        </div>
      </div>
    </Card>
  </div>

  <Modal />

  <!-- Multi-Deploy Modal -->
  <Modal
    v-if="showMultiDeployModal"
    v-model:open="showMultiDeployModal"
    submit-text="部署所选节点"
    :submit-disabled="multiDeploySubmitDisabled"
    :on-ok="handleMultiDeploySubmit"
  >
    <template #title>批量部署节点</template>
    <MultiDeployModal
      ref="multiDeployModalRef"
      :regions="cloudStore.regions"
      :latency-results="cloudStore.latencyTestResults"
    />
  </Modal>

  <!-- Charts Modal -->
  <Modal
    v-if="showChartsModal"
    v-model:open="showChartsModal"
    :footer="false"
    :after-close="() => closeChartsModal()"
  >
    <template #title>
      {{ t('cloud.charts.title', { label: viewingChartNode?.label || '' }) }}
    </template>
    <div v-if="viewingChartNode" class="charts-modal-content">
      <div class="chart-toolbar">
        <Button @click="handleExportChartHistory" type="link">
          {{ t('cloud.charts.export') }}
        </Button>
        <Button @click="handleClearChartHistory" type="link">
          {{ t('cloud.charts.clear') }}
        </Button>
      </div>
      <div class="chart-summary-grid">
        <div class="chart-summary-card">
          <span class="chart-summary-label">{{ t('cloud.charts.currentStatus') }}</span>
          <Tag :color="getConnectivityColor(chartCurrentStatusKey)">
            {{ chartCurrentStatusLabel }}
          </Tag>
        </div>
        <div class="chart-summary-card">
          <span class="chart-summary-label">{{ t('cloud.charts.latestSpeed') }}</span>
          <Tag :color="viewingChartNode.speedMbps != null ? (viewingChartNode.speedMbps < 0 ? 'red' : viewingChartNode.speedMbps > 50 ? 'green' : viewingChartNode.speedMbps > 10 ? 'cyan' : 'red') : 'default'">
            {{ chartLatestSpeedLabel }}
          </Tag>
        </div>
      </div>
      <div class="chart-section">
        <ConnectivityChart
          :title="t('cloud.charts.connectivity')"
          :data="connectivityChartData"
          :width="600"
          :height="80"
          :show-uptime="false"
        />
        <div class="chart-caption">{{ t('cloud.charts.connectivityWindow') }}</div>
      </div>
      <div class="chart-section">
        <div class="chart-section-title">{{ t('cloud.charts.endpointStatus') }}</div>
        <div v-if="chartEndpointStatuses.length" class="endpoint-status-list">
          <div v-for="endpoint in chartEndpointStatuses" :key="endpoint.key" class="endpoint-status-item">
            <span class="endpoint-label">{{ endpoint.label }}</span>
            <Tag :color="endpoint.status === 'open' ? 'green' : endpoint.status === 'open_or_filtered' ? 'cyan' : endpoint.status === 'closed' ? 'red' : 'default'">
              {{ endpoint.status }}
            </Tag>
          </div>
        </div>
        <div v-else class="chart-empty-state">
          {{ t('cloud.charts.noMeasurement') }}
        </div>
      </div>
      <div class="chart-section">
        <div class="chart-section-title">{{ t('cloud.charts.speedHistory') }}</div>
        <LatencyChart
          v-if="latencyChartData.length"
          :title="t('cloud.charts.speedHistory')"
          :data="latencyChartData"
          :width="600"
          :height="120"
          unit="Mbps"
        />
        <div v-else class="chart-empty-state">
          {{ t('cloud.charts.noHistory') }}
        </div>
      </div>
      <div class="chart-note">
        <span>{{ t('cloud.charts.note', { days: nodeHistoryRetentionDays }) }}</span>
      </div>
    </div>
  </Modal>

  <!-- Keyboard Shortcuts Help Modal -->
  <Modal v-if="showKeyboardHelp" @close="showKeyboardHelp = false">
    <template #title>
      {{ t('cloud.shortcuts.title') }}
    </template>
    <div class="shortcuts-help">
      <div class="shortcuts-section">
        <h3 class="shortcuts-section-title">{{ t('cloud.shortcuts.general') }}</h3>
        <div class="shortcut-item">
          <kbd>?</kbd>
          <span>{{ t('cloud.shortcuts.showHelp') }}</span>
        </div>
        <div class="shortcut-item">
          <kbd>Esc</kbd>
          <span>{{ t('cloud.shortcuts.closeModal') }}</span>
        </div>
      </div>

      <div class="shortcuts-section">
        <h3 class="shortcuts-section-title">{{ t('cloud.shortcuts.navigation') }}</h3>
        <div class="shortcut-item">
          <kbd>Ctrl</kbd> + <kbd>F</kbd>
          <span>{{ t('cloud.shortcuts.focusSearch') }}</span>
        </div>
        <div class="shortcut-item">
          <kbd>Ctrl</kbd> + <kbd>R</kbd>
          <span>{{ t('cloud.shortcuts.refresh') }}</span>
        </div>
      </div>

      <div class="shortcuts-section">
        <h3 class="shortcuts-section-title">{{ t('cloud.shortcuts.actions') }}</h3>
        <div class="shortcut-item">
          <kbd>Ctrl</kbd> + <kbd>T</kbd>
          <span>{{ t('cloud.shortcuts.testAll') }}</span>
        </div>
      </div>

      <div class="shortcuts-note">
        {{ t('cloud.shortcuts.note') }}
      </div>
    </div>
  </Modal>
</template>

<style lang="less" scoped>
.cloud-view {
  padding: 16px;
}

.text-secondary {
  color: var(--text-secondary-color);
}

.min-w-200 {
  min-width: 200px;
}

.min-w-240 {
  min-width: 240px;
}

.protocol-list {
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  gap: 4px;
}

.protocol-item {
  display: flex;
  align-items: center;
  gap: 2px;
  font-size: 11px;
}

.protocol-header {
  display: flex;
  align-items: center;
  gap: 2px;
}

.protocol-meta {
  display: inline-flex;
  align-items: center;
  font-family: var(--font-family-mono, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace);
  font-size: 10px;
  line-height: 1.2;

  span {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 60px;
  }
}

.deployment-progress {
  font-size: 11px;
  color: var(--text-secondary-color);
}

.deployment-progress__summary {
  font-weight: 600;
}

.deployment-progress__steps {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.deployment-progress__step {
  display: flex;
  align-items: center;
  gap: 6px;
}

.deployment-progress__bullet {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--divider-color);
  flex-shrink: 0;
}

.deployment-progress__step--done .deployment-progress__bullet {
  background: var(--success-color);
}

.deployment-progress__step--current .deployment-progress__bullet {
  background: var(--primary-color);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--primary-color) 20%, transparent);
}

.deployment-progress__step--pending .deployment-progress__label {
  opacity: 0.7;
}

.deployment-progress__label {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* Charts Modal */
.charts-modal-content {
  display: flex;
  flex-direction: column;
  gap: 16px;
  padding: 16px 0;
}

.chart-toolbar {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
}

.chart-summary-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 12px;
}

.chart-summary-card {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 12px;
  border: 1px solid var(--divider-color);
  border-radius: 4px;
  background: var(--bg-content-color);
}

.chart-summary-label {
  font-size: 12px;
  color: var(--text-secondary-color);
}

.chart-section {
  display: flex;
  flex-direction: column;
  gap: 8px;
  border: 1px solid var(--divider-color);
  border-radius: 4px;
  overflow: hidden;
  padding: 12px;
}

.chart-section-title {
  font-size: 12px;
  font-weight: 600;
}

.chart-caption,
.chart-empty-state {
  font-size: 12px;
  color: var(--text-secondary-color);
}

.endpoint-status-list {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 8px 12px;
}

.endpoint-status-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 10px 12px;
  background: #fafafa;
  border-radius: 4px;
}

.endpoint-label {
  font-size: 12px;
}

.chart-note {
  font-size: 12px;
  color: var(--text-secondary-color);
  font-style: italic;
  text-align: center;
  padding: 8px;
  background: #fafafa;
  border-radius: 4px;
}

/* Keyboard Shortcuts Help */
.shortcuts-help {
  display: flex;
  flex-direction: column;
  gap: 24px;
  padding: 16px 0;
}

.shortcuts-section {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.shortcuts-section-title {
  font-size: 14px;
  font-weight: 600;
  color: var(--text-primary-color);
  margin: 0 0 8px 0;
  padding-bottom: 8px;
  border-bottom: 1px solid var(--divider-color);
}

.shortcut-item {
  display: flex;
  align-items: center;
  gap: 16px;
  font-size: 13px;
}

.shortcut-item kbd {
  display: inline-block;
  padding: 4px 8px;
  font-family: monospace;
  font-size: 12px;
  font-weight: 600;
  color: #333;
  background: #f5f5f5;
  border: 1px solid #ccc;
  border-radius: 4px;
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.1);
  min-width: 32px;
  text-align: center;
}

.shortcut-item span {
  flex: 1;
  color: var(--text-secondary-color);
}

.shortcuts-note {
  font-size: 12px;
  color: var(--text-tertiary-color);
  font-style: italic;
  text-align: center;
  padding: 12px;
  background: #fafafa;
  border-radius: 4px;
  margin-top: 8px;
}
</style>
