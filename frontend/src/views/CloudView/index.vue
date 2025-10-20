<script setup lang="ts">
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'

import { ClipboardSetText } from '@/bridge'
import { useCloudStore, useKernelApiStore } from '@/stores'
import { confirm, formatDate, formatRelativeTime, message } from '@/utils'
import { logError } from '@/utils/logger'

import type { VultrNode, VultrPlan, VultrRegion } from '@/types/cloud'

const { t } = useI18n()
const cloudStore = useCloudStore()
const kernelApiStore = useKernelApiStore()

const form = reactive({
  label: defaultLabel(),
  region: '',
  plan: '',
})

const loadingMeta = computed(() => cloudStore.loadingPlans || cloudStore.loadingRegions)
const hasApiKey = computed(() => cloudStore.config.apiKey.trim().length > 0)

function formatRegion(region: VultrRegion) {
  const cityKey = `cloud.regions.${region.city}`
  const countryKey = `cloud.regions.${region.country}`

  const city = t(cityKey) !== cityKey ? t(cityKey) : region.city
  const country = t(countryKey) !== countryKey ? t(countryKey) : region.country

  return `${city}, ${country}`
}

const providerOptions = computed(() =>
  cloudStore.availableProviders.map((provider) => ({
    label: provider.displayName,
    value: provider.name,
  })),
)

const regionOptions = computed(() =>
  cloudStore.regions.map((region: VultrRegion) => ({
    label: formatRegion(region),
    value: region.id,
  })),
)

type StatusKey = 'unknown' | 'pending' | 'applying' | 'connected' | 'error'

const statusLabels = computed<Record<StatusKey, string>>(() => ({
  unknown: t('cloud.status.unknown'),
  pending: t('cloud.status.pending'),
  applying: t('cloud.status.applying'),
  connected: t('cloud.status.connected'),
  error: t('cloud.status.error'),
}))

type TagColor = 'cyan' | 'green' | 'red' | 'default' | 'primary'
const statusColors: Record<StatusKey, TagColor> = {
  unknown: 'default',
  pending: 'green',
  applying: 'cyan',
  connected: 'primary',
  error: 'red',
}

const getStatusLabel = (status?: string) => statusLabels.value[(status || 'unknown') as StatusKey]
const getStatusColor = (status?: string): TagColor => statusColors[(status || 'unknown') as StatusKey]

const availablePlanIds = computed(() => cloudStore.availability[form.region] || [])

const planOptions = computed(() => {
  // 强制响应式依赖
  const availabilityData = cloudStore.availability
  const currentRegion = form.region

  console.log('[CloudView] planOptions computed - region:', currentRegion, 'availability:', availabilityData[currentRegion])

  if (!currentRegion) {
    return cloudStore.plans.map((plan: VultrPlan) => ({
      label: formatPlan(plan),
      value: plan.id,
    }))
  }

  // 获取当前区域的可用套餐ID列表
  const ids = availabilityData[currentRegion] || []

  console.log('[CloudView] Available plan IDs for region:', ids)

  // 如果有可用性数据,只显示该区域可用的套餐
  if (ids.length > 0) {
    const source = cloudStore.plans.filter((plan: VultrPlan) => ids.includes(plan.id))
    console.log('[CloudView] Filtered plans:', source.length, 'out of', cloudStore.plans.length)
    return source.map((plan: VultrPlan) => ({
      label: formatPlan(plan),
      value: plan.id,
    }))
  }

  // 如果没有可用性数据,暂时显示所有套餐
  // (在部署时会再次验证,如果不可用会报错)
  console.log('[CloudView] No availability data, showing all plans:', cloudStore.plans.length)
  return cloudStore.plans.map((plan: VultrPlan) => ({
    label: formatPlan(plan),
    value: plan.id,
  }))
})

const regionMap = computed(() => new Map(cloudStore.regions.map((r) => [r.id, formatRegion(r)])))
const planMap = computed(() => {
  const map = new Map(cloudStore.plans.map((p) => [p.id, formatPlan(p)]))
  console.log('[CloudView] planMap updated, size:', map.size, 'plans:', cloudStore.plans.length)
  if (cloudStore.plans.length > 0) {
    const firstPlan = cloudStore.plans[0]
    console.log('[CloudView] First plan:', firstPlan.id, 'formatted:', formatPlan(firstPlan))
  }
  return map
})

const tableData = computed(() =>
  cloudStore.instances.map((node) => ({
    ...node,
    id: node.instanceId,
  })),
)

const applyingNodeId = ref('')

const disableDeploy = computed(
  () => !hasApiKey.value || !form.region || !form.plan || !form.label.trim(),
)

function defaultLabel() {
  return `vultr-${Date.now().toString(36)}`
}

function formatPlan(plan: VultrPlan) {
  const ram = plan.ram >= 1024 ? `${(plan.ram / 1024).toFixed(1)}GB` : `${plan.ram}MB`
  const disk = plan.disk >= 1024 ? `${(plan.disk / 1024).toFixed(1)}TB` : `${plan.disk}GB`
  const bandwidth = plan.bandwidth >= 1024 ? `${(plan.bandwidth / 1024).toFixed(1)}TB` : `${plan.bandwidth}GB`

  const meta = [
    `${plan.vcpu_count} ${t('cloud.format.vcpu')}`,
    `${ram} ${t('cloud.format.ram')}`,
    `${disk} ${t('cloud.format.disk')}`,
    `${bandwidth} ${t('cloud.format.bandwidth')}`
  ]

  // Add price if available
  if (plan.monthlyCost && plan.monthlyCost > 0) {
    meta.push(`$${plan.monthlyCost.toFixed(2)}${t('cloud.format.monthly')}`)
  }

  return plan.description ? `${plan.description} · ${meta.join(' · ')}` : `${plan.id} · ${meta.join(' · ')}`
}

const pickPlanForRegion = (region: string) => {
  const ids = cloudStore.availability[region] || []
  const fallback = ids.find((id) => cloudStore.plans.some((plan) => plan.id === id))
  if (fallback) return fallback
  return cloudStore.plans[0]?.id || ''
}

const ensurePlanForRegion = (region: string) => {
  if (!region) return
  const ids = cloudStore.availability[region]
  if (!ids || ids.length === 0) return
  if (!ids.includes(form.plan)) {
    const replacement = ids.find((id) => cloudStore.plans.some((plan) => plan.id === id)) || ''
    if (replacement) {
      form.plan = replacement
    }
  }
}

const columns = [
  { title: 'cloud.table.label', key: 'label', width: '13%' },
  { title: 'cloud.table.region', key: 'region', width: '10%' },
  { title: 'cloud.table.plan', key: 'plan', width: '13%' },
  { title: 'cloud.table.ipAddresses', key: 'ipAddresses', width: '15%' },
  { title: 'cloud.table.protocols', key: 'protocols', width: '20%' },
  { title: 'cloud.table.status', key: 'status', width: '8%' },
  { title: 'cloud.table.createdAt', key: 'createdAt', width: '10%' },
  { title: 'cloud.table.actions', key: 'actions', width: '11%' },
]

const applyDefaults = async () => {
  if (!form.region) {
    form.region = cloudStore.config.defaultRegion || cloudStore.regions[0]?.id || ''
  }
  if (form.region) {
    await cloudStore.ensureRegionAvailability(form.region)
    if (!form.plan) {
      form.plan = cloudStore.config.defaultPlan || pickPlanForRegion(form.region)
    } else {
      ensurePlanForRegion(form.region)
    }
  } else if (!form.plan) {
    form.plan = cloudStore.config.defaultPlan || cloudStore.plans[0]?.id || ''
  }
}

watch(
  () => [cloudStore.regions.length, cloudStore.plans.length, cloudStore.config.defaultPlan, cloudStore.config.defaultRegion],
  applyDefaults,
)

watch(
  () => form.region,
  async (value, oldValue) => {
    console.log('[CloudView] Region changed:', oldValue, '->', value)
    cloudStore.config.defaultRegion = value
    if (value && value !== oldValue) {
      console.log('[CloudView] Forcing availability reload for region:', value)
      // 强制重新加载可用性数据
      await cloudStore.ensureRegionAvailability(value, true)
      console.log('[CloudView] Availability loaded:', cloudStore.availability[value])
      ensurePlanForRegion(value)
    }
  },
)

watch(
  () => form.plan,
  (value) => {
    if (!value) return
    cloudStore.config.defaultPlan = value
  },
)

onMounted(async () => {
  try {
    // Load available providers and get current provider
    await Promise.allSettled([cloudStore.loadProviders(), cloudStore.getCurrentProvider()])

    await cloudStore.loadConfig()
    if (cloudStore.config.apiKey) {
      // Load regions and plans in parallel
      await Promise.allSettled([cloudStore.fetchRegions(), cloudStore.fetchPlans()])

      // First refresh: use silent mode to avoid blocking UI on slow networks
      cloudStore.refreshInstances(true).catch((e) => {
        logError('[CloudView] Initial refresh failed:', e)
      })

      // Start background refresh (silent, updates every 30 seconds)
      const refreshInterval = setInterval(() => {
        if (cloudStore.config.apiKey) {
          cloudStore.refreshInstances(true).catch((e) => logError('[CloudView] Background refresh failed:', e))
        }
      }, 30000)

      // Clean up interval when component unmounts
      onUnmounted(() => clearInterval(refreshInterval))
    } else {
      await Promise.allSettled([cloudStore.fetchRegions(), cloudStore.fetchPlans()])
    }
    await applyDefaults()
  } catch (error) {
    logError('[CloudView] onMounted error:', error)
    // Ensure loading state is reset on error
    cloudStore.loadingInstances = false
    handleError(error)
  }
})

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
    messageText = t('cloud.errors.apiKeyRequired')
  }

  message.error(messageText)
}

const handleProviderChange = async () => {
  try {
    await cloudStore.switchProvider(cloudStore.currentProvider)
    message.success(t('cloud.provider.switched'))
  } catch (error) {
    logError('[CloudView] Failed to switch provider:', error)
    handleError(error)
  }
}

const handleSaveConfig = async () => {
  if (!hasApiKey.value) {
    message.error(t('cloud.errors.apiKeyRequired'))
    return
  }
  try {
    await cloudStore.saveConfig()
    message.success('common.success')
    await fetchMeta()
  } catch (error) {
    handleError(error)
  }
}

const fetchMeta = async () => {
  if (!hasApiKey.value) {
    message.error(t('cloud.errors.apiKeyRequired'))
    return
  }
  try {
    await Promise.all([cloudStore.fetchRegions(), cloudStore.fetchPlans()])
    applyDefaults()
  } catch (error) {
    handleError(error)
  }
}

const handleRefreshInstances = async () => {
  if (!hasApiKey.value) {
    message.error(t('cloud.errors.apiKeyRequired'))
    return
  }
  try {
    await cloudStore.refreshInstances()
  } catch (error) {
    handleError(error)
  }
}

const handleDeploy = async () => {
  if (disableDeploy.value) {
    message.error(t('cloud.errors.formIncomplete'))
    return
  }
  try {
    await cloudStore.ensureRegionAvailability(form.region)
    const ids = availablePlanIds.value
    if (ids.length && !ids.includes(form.plan)) {
      ensurePlanForRegion(form.region)
      if (!ids.includes(form.plan)) {
        message.error(t('cloud.errors.planUnavailable'))
        return
      }
    }
    await cloudStore.createInstance({
      label: form.label.trim(),
      region: form.region,
      plan: form.plan,
    })
    message.success('common.success')
    form.label = defaultLabel()
    await cloudStore.refreshInstances()
  } catch (error) {
    handleError(error)
  }
}

const handleUseNode = async (node: VultrNode | Record<string, any>) => {
  const target = node as VultrNode
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
    // Use silent refresh to avoid showing loading state
    cloudStore.refreshInstances(true).catch((e) => logError('[CloudView] Silent refresh after apply failed:', e))
    message.success(t('cloud.nodes.applied'))
    message.info(t('cloud.nodes.applyTip'))
  } catch (error) {
    cloudStore.markNodeStatus(target.instanceId, 'error')
    handleError(error)
  } finally {
    applyingNodeId.value = ''
  }
}

const isPublicIPv4 = (ip: string): boolean => {
  if (!ip) return false
  const octets = ip.split('.')
  if (octets.length !== 4) return false

  const first = parseInt(octets[0], 10)
  const second = parseInt(octets[1], 10)

  // CGNAT range: 100.64.0.0/10 (100.64.0.0 - 100.127.255.255)
  if (first === 100 && second >= 64 && second <= 127) return false

  // Private ranges
  if (first === 10) return false // 10.0.0.0/8
  if (first === 192 && second === 168) return false // 192.168.0.0/16
  if (first === 172 && second >= 16 && second <= 31) return false // 172.16.0.0/12

  return true
}

const copyValue = async (value: string) => {
  if (!value) return
  try {
    await ClipboardSetText(value)
    message.success('common.copied')
  } catch (error) {
    handleError(error)
  }
}

const ensureNode = (node: VultrNode | Record<string, any>): VultrNode => node as VultrNode

const getPreferredAddress = (node: VultrNode | Record<string, any>): string | undefined => {
  const target = ensureNode(node)
  if (isPublicIPv4(target.ipv4)) return target.ipv4
  if (target.ipv6) return target.ipv6
  return undefined
}

const wrapHostForUri = (host: string): string => {
  if (!host.includes(':')) return host
  return host.startsWith('[') ? host : `[${host}]`
}

const buildShadowsocksLink = (node: VultrNode | Record<string, any>): string | null => {
  const target = ensureNode(node)
  const port = target.ssPort || target.port
  const password = target.ssPassword || target.password
  const host = getPreferredAddress(target)
  if (!port || !password || !host) return null
  const encoded = btoa(`aes-256-gcm:${password}@${wrapHostForUri(host)}:${port}`)
  return `ss://${encoded}#${encodeURIComponent(target.label)}`
}

const buildHysteriaLink = (node: VultrNode | Record<string, any>): string | null => {
  const target = ensureNode(node)
  if (!target.hysteriaPort || !target.hysteriaPassword) return null
  const host = getPreferredAddress(target)
  if (!host) return null
  const query = new URLSearchParams({ sni: 'www.bing.com', insecure: '1' })
  return `hysteria2://${encodeURIComponent(target.hysteriaPassword)}@${wrapHostForUri(host)}:${target.hysteriaPort}?${query.toString()}#${encodeURIComponent(target.label)}`
}

const buildVlessLink = (node: VultrNode | Record<string, any>): string | null => {
  const target = ensureNode(node)
  if (!target.vlessPort || !target.vlessUUID || !target.vlessPublicKey || !target.vlessShortId) return null
  const host = getPreferredAddress(target)
  if (!host) return null
  const query = new URLSearchParams({
    encryption: 'none',
    flow: 'xtls-rprx-vision',
    security: 'reality',
    'reality-public-key': target.vlessPublicKey,
    'reality-short-id': target.vlessShortId,
    sni: 'www.microsoft.com',
    fp: 'chrome',
  })
  return `vless://${target.vlessUUID}@${wrapHostForUri(host)}:${target.vlessPort}?${query.toString()}#${encodeURIComponent(target.label)}`
}

const buildTrojanLink = (node: VultrNode | Record<string, any>): string | null => {
  const target = ensureNode(node)
  if (!target.trojanPort || !target.trojanPassword) return null
  const host = getPreferredAddress(target)
  if (!host) return null
  const query = new URLSearchParams({ security: 'tls', sni: 'www.microsoft.com', allowInsecure: '1' })
  return `trojan://${encodeURIComponent(target.trojanPassword)}@${wrapHostForUri(host)}:${target.trojanPort}?${query.toString()}#${encodeURIComponent(target.label)}`
}

const hasShadowsocks = (node: VultrNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return Boolean((target.ssPort || target.port) && (target.ssPassword || target.password))
}
const hasHysteria = (node: VultrNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return Boolean(target.hysteriaPort && target.hysteriaPassword)
}
const hasVless = (node: VultrNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return Boolean(target.vlessPort && target.vlessUUID && target.vlessPublicKey && target.vlessShortId)
}
const hasTrojan = (node: VultrNode | Record<string, any>): boolean => {
  const target = ensureNode(node)
  return Boolean(target.trojanPort && target.trojanPassword)
}

const copyProtocolLink = async (link: string | null) => {
  if (!link) {
    message.error(t('cloud.errors.protocolUnavailable'))
    return
  }
  await copyValue(link)
}

const copyShadowsocksLink = async (node: VultrNode | Record<string, any>) => {
  await copyProtocolLink(buildShadowsocksLink(node))
}

const copyHysteriaLink = async (node: VultrNode | Record<string, any>) => {
  await copyProtocolLink(buildHysteriaLink(node))
}

const copyVlessLink = async (node: VultrNode | Record<string, any>) => {
  await copyProtocolLink(buildVlessLink(node))
}

const copyTrojanLink = async (node: VultrNode | Record<string, any>) => {
  await copyProtocolLink(buildTrojanLink(node))
}

const copyNodeConfig = async (record: VultrNode | Record<string, any>) => {
  const node = ensureNode(record)
  const links = [
    { label: 'Shadowsocks', url: buildShadowsocksLink(node) },
    { label: 'Hysteria2', url: buildHysteriaLink(node) },
    { label: 'VLESS-Reality', url: buildVlessLink(node) },
    { label: 'Trojan', url: buildTrojanLink(node) },
  ].filter((item) => item.url) as Array<{ label: string; url: string }>

  if (!links.length) {
    message.error(t('cloud.errors.noProtocols'))
    return
  }

  const payload = links.map((item) => `${item.label}: ${item.url}`).join('\n')
  await copyValue(payload)
}

const handleDestroy = async (record: VultrNode | Record<string, any>) => {
  const node = record as VultrNode
  try {
    await confirm('common.warning', t('cloud.confirmDestroy', { label: node.label }))
  } catch (error) {
    return
  }
  try {
    await cloudStore.destroyInstance(node.instanceId)
    message.success('common.success')
  } catch (error) {
    handleError(error)
  }
}
</script>

<template>
  <div class="cloud-view grid gap-16">
    <Card :title="t('cloud.provider.title')">
      <div class="flex items-center gap-8 py-8">
        <span class="text-14">{{ t('cloud.provider.label') }}:</span>
        <Select
          v-model="cloudStore.currentProvider"
          :options="providerOptions"
          @change="handleProviderChange"
          size="small"
          auto-size
        />
      </div>
    </Card>

    <Card :title="t('cloud.credentials.title')">
      <div class="flex flex-col gap-12 py-8">
        <div class="flex flex-wrap items-center gap-8">
          <Input
            v-model="cloudStore.config.apiKey"
            :auto-size="true"
            :placeholder="t('cloud.credentials.placeholder')"
            class="flex-1 min-w-240"
          />
          <Button
            @click="handleSaveConfig"
            type="primary"
            :loading="cloudStore.savingConfig"
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
        </div>
        <div class="text-12 text-secondary">
          {{ t('cloud.credentials.hint') }}
        </div>
      </div>
    </Card>

    <Card :title="t('cloud.create.title')">
      <div class="flex flex-col gap-12 py-8">
        <div class="flex flex-wrap items-center gap-8">
          <Select
            v-model="form.region"
            :options="regionOptions"
            :placeholder="t('cloud.create.regionPlaceholder')"
            auto-size
            :disabled="!regionOptions.length"
          />
          <Select
            v-model="form.plan"
            :options="planOptions"
            :placeholder="t('cloud.create.planPlaceholder')"
            auto-size
            :disabled="!planOptions.length"
          />
          <Input
            v-model="form.label"
            :auto-size="true"
            :placeholder="t('cloud.create.labelPlaceholder')"
            class="flex-1 min-w-200"
          />
        </div>
        <div class="flex items-center gap-8">
          <Button
            @click="handleDeploy"
            type="primary"
            :loading="cloudStore.creatingInstance"
            :disabled="disableDeploy"
          >
            {{ t('cloud.create.deploy') }}
          </Button>
          <Button
            @click="handleRefreshInstances"
            type="link"
            :loading="cloudStore.loadingInstances"
            :disabled="!hasApiKey"
          >
            {{ t('cloud.create.refresh') }}
          </Button>
        </div>
      </div>
    </Card>

    <Card :title="t('cloud.nodes.title')">
      <div v-if="cloudStore.loadingInstances" class="py-32 text-center text-14">
        {{ t('cloud.nodes.loading') }}
      </div>
      <div v-else-if="!tableData.length" class="py-32">
        <Empty>
          <template #description>{{ t('cloud.nodes.empty') }}</template>
        </Empty>
      </div>
      <div v-else class="py-8">
        <Table :columns="columns" :data-source="tableData">
          <template #region="{ record }">
            <div>{{ regionMap.get(record.region) || record.region }}</div>
          </template>
          <template #plan="{ record }">
            <div>{{ planMap.get(record.plan) || record.plan }}</div>
          </template>
          <template #status="{ record }">
            <div class="flex items-center gap-4">
              <span class="capitalize">{{ record.status }}</span>
              <Tag :color="getStatusColor(record.statusText)" size="small">
                {{ getStatusLabel(record.statusText) }}
              </Tag>
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
          <template #createdAt="{ record }">
            <div class="flex flex-col" style="font-size: 11px">
              <span>{{ formatDate(record.createdAt, 'YYYY-MM-DD') }}</span>
              <span class="text-secondary">{{ formatRelativeTime(record.createdAt) }}</span>
            </div>
          </template>
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
              <Button @click="copyNodeConfig(record)" type="text" size="small" v-tips="'cloud.nodes.copyLink'">📋</Button>
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
    </Card>
  </div>
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
</style>
