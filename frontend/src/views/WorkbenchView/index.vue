<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRouter } from 'vue-router'

import { useCloudStore, useAppSettingsStore, useKernelApiStore, useProfilesStore } from '@/stores'
import { formatRelativeTime, message } from '@/utils'
import { formatSpeedFailureReason, isSpeedTimeoutError } from '@/views/CloudView/cloudViewPresentation'
import GroupsController from '@/views/HomeView/components/GroupsController.vue'
import KernelLogs from '@/views/HomeView/components/KernelLogs.vue'
import OverView from '@/views/HomeView/components/OverView.vue'

import { useModal } from '@/components/Modal'

import type { CloudNode } from '@/types/cloud'

const { t } = useI18n()
const router = useRouter()
const [Modal, modalApi] = useModal({})

const cloudStore = useCloudStore()
const appSettingsStore = useAppSettingsStore()
const kernelApiStore = useKernelApiStore()
const profilesStore = useProfilesStore()

const runtimeTab = ref('groups')

const profileOptions = computed(() =>
  profilesStore.profiles.map((profile) => ({
    label: profile.name,
    value: profile.id,
  })),
)

const selectedProfileId = computed({
  get: () => appSettingsStore.app.kernel.profile,
  set: (value: string) => {
    void handleSelectProfile(value)
  },
})

const currentProfileName = computed(() => {
  const profile = profilesStore.getProfileById(appSettingsStore.app.kernel.profile)
  return profile?.name || t('workbench.emptyProfile')
})

const lastRefreshLabel = computed(() => {
  if (!cloudStore.instancesUpdatedAt) {
    return t('workbench.notSynced')
  }
  return formatRelativeTime(cloudStore.instancesUpdatedAt)
})

const cloudNodes = computed(() =>
  [...cloudStore.instances].sort((a, b) => {
    const statusOrder: Record<string, number> = {
      connected: 0,
      applying: 1,
      pending: 2,
      error: 3,
      unknown: 4,
    }
    const statusDiff =
      (statusOrder[a.statusText || 'unknown'] ?? 9) - (statusOrder[b.statusText || 'unknown'] ?? 9)
    if (statusDiff !== 0) return statusDiff
    return (b.createdAt || '').localeCompare(a.createdAt || '')
  }),
)

const nodeStatsLabel = computed(() => {
  const total = cloudNodes.value.length
  const connected = cloudNodes.value.filter((node) => node.statusText === 'connected').length
  return t('workbench.nodeSummary', { total, connected })
})

const runtimeTabs = [
  { key: 'groups', tab: 'workbench.runtime.groups' },
  { key: 'overview', tab: 'workbench.runtime.overview' },
]

const statusTagColor = (status?: string) => {
  const colorMap: Record<string, 'primary' | 'green' | 'cyan' | 'red' | 'default'> = {
    connected: 'primary',
    pending: 'green',
    applying: 'cyan',
    error: 'red',
    unknown: 'default',
  }
  return colorMap[status || 'unknown'] || 'default'
}

const connectivityTagColor = (status?: string) => {
  const colorMap: Record<string, 'green' | 'cyan' | 'red' | 'default'> = {
    reachable: 'green',
    icmp_blocked: 'cyan',
    blocked: 'red',
    testing: 'default',
    unknown: 'default',
  }
  return colorMap[status || 'unknown'] || 'default'
}

const openSettingsTab = (tab: string) => {
  router.push({ name: 'Settings', query: { tab } })
}

const handleStartKernel = async () => {
  try {
    await kernelApiStore.startCore()
  } catch (error: any) {
    console.error(error)
    message.error(error.message || error)
  }
}

const handleStopKernel = async () => {
  try {
    await kernelApiStore.stopCore()
  } catch (error: any) {
    console.error(error)
    message.error(error.message || error)
  }
}

const handleShowKernelLogs = () => {
  modalApi.setProps({
    title: 'home.overview.viewlog',
    width: '90',
    height: '90',
    submit: false,
    cancelText: 'common.close',
    maskClosable: true,
  })
  modalApi.setContent(KernelLogs).open()
}

const handleRefreshNodes = async () => {
  try {
    if (!cloudStore.configLoaded) {
      await cloudStore.loadConfig()
    }
    await cloudStore.refreshInstances(false, true)
    message.success('common.success')
  } catch (error: any) {
    console.error(error)
    message.error(error.message || error)
  }
}

const handleUseNode = async (node: CloudNode) => {
  try {
    await cloudStore.applyNodeToProfile(node)
    if (kernelApiStore.running) {
      await kernelApiStore.restartCore()
    } else {
      await kernelApiStore.startCore()
    }
    message.success(t('cloud.nodes.applied'))
  } catch (error: any) {
    console.error(error)
    message.error(error.message || error)
  }
}

const handleTestNode = async (node: CloudNode) => {
  try {
    await cloudStore.testNodeSpeedTest(node.instanceId)
  } catch (error: any) {
    console.error(error)
    message.error(error.message || error)
  }
}

const speedTestAllLoading = ref(false)
const handleTestAllSpeed = async () => {
  speedTestAllLoading.value = true
  try {
    await cloudStore.testAllNodesSpeed()
    message.success(t('cloud.speed.testAllComplete'))
  } catch (error: any) {
    console.error(error)
    message.error(error.message || error)
  } finally {
    speedTestAllLoading.value = false
  }
}

const loadBalanceLoading = ref(false)
const handleToggleLoadBalance = async () => {
  loadBalanceLoading.value = true
  try {
    if (cloudStore.loadBalanceEnabled) {
      await cloudStore.stopLoadBalance()
    } else {
      await cloudStore.startLoadBalance()
      if (!cloudStore.loadBalanceEnabled) {
        message.error(t('cloud.loadBalance.startFailed'))
      }
    }
  } catch (error: any) {
    console.error(error)
    message.error(error.message || error)
  } finally {
    loadBalanceLoading.value = false
  }
}

const handleSelectProfile = async (profileId: string) => {
  if (!profileId || appSettingsStore.app.kernel.profile === profileId) return
  appSettingsStore.app.kernel.profile = profileId
  if (kernelApiStore.running) {
    try {
      await kernelApiStore.restartCore(undefined, false)
    } catch (error: any) {
      console.error(error)
      message.error(error.message || error)
    }
  }
}

const bootstrapWorkbench = async () => {
  try {
    await Promise.allSettled([cloudStore.loadProviders(), cloudStore.getCurrentProvider()])
    if (!cloudStore.configLoaded) {
      await cloudStore.loadConfig().catch(() => undefined)
    }
    if (cloudStore.config.apiKey?.trim()) {
      await Promise.allSettled([
        cloudStore.fetchRegions().catch(() => undefined),
        cloudStore.fetchPlans().catch(() => undefined),
      ])
      await cloudStore.refreshInstances(true).catch(() => undefined)
    }
  } catch (error) {
    console.error('[Workbench] bootstrap failed:', error)
  }
}

onMounted(() => {
  bootstrapWorkbench().catch((error) => console.error(error))
})
</script>

<template>
  <div class="workbench flex flex-col gap-16">
    <Card class="workbench-bar">
      <div class="flex flex-wrap items-center gap-12">
        <div class="min-w-240 flex-1">
          <div class="text-12 text-secondary">{{ t('workbench.profileLabel') }}</div>
          <div class="flex items-center gap-8 mt-6">
            <Select
              v-if="profileOptions.length"
              v-model="selectedProfileId"
              :options="profileOptions"
              auto-size
            />
          </div>
        </div>

        <div class="ml-auto flex items-center gap-8">
          <Button
            v-if="kernelApiStore.running"
            @click="handleStopKernel"
            :loading="kernelApiStore.stopping"
            icon="stop"
            type="primary"
          >
            {{ t('workbench.disconnect') }}
          </Button>
          <Button
            v-else
            @click="handleStartKernel"
            :loading="kernelApiStore.starting"
            icon="play"
            type="primary"
          >
            {{ t('workbench.connect') }}
          </Button>
          <Button @click="handleShowKernelLogs" type="text" icon="log">
            {{ t('workbench.viewLogs') }}
          </Button>
        </div>
      </div>
    </Card>

    <Card>
      <div class="flex items-center justify-between gap-12 flex-wrap">
        <div>
          <div class="text-18 font-bold">{{ t('workbench.nodesTitle') }}</div>
          <div class="text-12 text-secondary mt-4">
            {{ currentProfileName }} · {{ nodeStatsLabel }} · {{ t('cloud.nodes.lastSynced', { time: lastRefreshLabel }) }}
          </div>
        </div>

        <div class="flex items-center gap-8">
          <Button @click="handleTestAllSpeed" :loading="speedTestAllLoading" :disabled="!cloudNodes.length" type="text">
            {{ t('cloud.speed.testAll') }}
          </Button>
          <Button
            @click="handleToggleLoadBalance"
            :loading="loadBalanceLoading"
            :disabled="cloudNodes.length < 2 && !cloudStore.loadBalanceEnabled"
            :type="cloudStore.loadBalanceEnabled ? 'primary' : 'text'"
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
          <Button @click="handleRefreshNodes" :loading="cloudStore.loadingInstances" type="text" icon="refresh">
            {{ t('cloud.create.refresh') }}
          </Button>
          <Button @click="openSettingsTab('cloud')" type="text" icon="settings2">
            {{ t('router.subscriptions') }}
          </Button>
        </div>
      </div>

      <div v-if="cloudStore.loadBalanceEnabled && cloudStore.loadBalanceListenPort" class="text-12 text-primary mt-4">
        {{ t('cloud.loadBalance.running', { port: cloudStore.loadBalanceListenPort }) }}
      </div>

      <div v-if="cloudNodes.length" class="mt-12">
        <div
          v-for="node in cloudNodes"
          :key="node.instanceId"
          class="node-row flex flex-wrap items-center gap-12"
        >
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-8 flex-wrap">
              <div class="text-14 font-bold truncate">{{ node.label }}</div>
              <Tag :color="statusTagColor(node.statusText)">
                {{ t(`cloud.status.${node.statusText || 'unknown'}`) }}
              </Tag>
              <Tag v-if="node.speedTesting" color="default">
                {{ t('cloud.speed.testing') }}
              </Tag>
              <template v-else-if="node.speedMbps != null">
                <Tag v-if="node.speedMbps < 0" color="red" :title="node.speedError || ''">
                  {{
                    isSpeedTimeoutError(node.speedError)
                      ? t('cloud.speed.timeout')
                      : t('cloud.speed.failedWithReason', { reason: formatSpeedFailureReason(node.speedError, t) })
                  }}
                </Tag>
                <Tag
                  v-else
                  :color="node.speedMbps > 50 ? 'green' : node.speedMbps > 10 ? 'cyan' : 'red'"
                  :title="node.speedError || ''"
                >
                  {{ node.speedError ? t('cloud.speed.mbpsPartial', { speed: node.speedMbps }) : t('cloud.speed.mbps', { speed: node.speedMbps }) }}
                </Tag>
              </template>
              <Tag v-else-if="node.speedMs != null" :color="node.speedMs < 0 ? 'red' : node.speedMs < 200 ? 'green' : node.speedMs < 500 ? 'cyan' : 'red'">
                {{ node.speedMs < 0 ? t('cloud.speed.timeout') : t('cloud.speed.ms', { ms: node.speedMs }) }}
              </Tag>
              <Tag v-else :color="connectivityTagColor(node.connectivityStatus)">
                {{ t(`cloud.connectivity.${node.connectivityStatus || 'unknown'}`) }}
              </Tag>
              <Tag v-if="node.provider" color="default">{{ node.provider }}</Tag>
            </div>
            <div class="text-12 text-secondary mt-4 break-all">
              {{ node.region || t('workbench.regionUnknown') }} · {{ node.ipv4 || node.ipv6 || t('workbench.noAddress') }}
            </div>
          </div>

          <div class="ml-auto flex items-center gap-8">
            <Button @click="handleTestNode(node)" :loading="node.speedTesting" type="text" size="small">
              {{ t('cloud.connectivity.testButton') }}
            </Button>
            <Button @click="handleUseNode(node)" type="primary" size="small">
              {{ t('cloud.nodes.apply') }}
            </Button>
          </div>
        </div>
      </div>

      <Empty v-else class="mt-20">
        <template #description>
          <div class="flex flex-col items-center gap-12">
            <div class="text-16 font-bold">{{ t('workbench.emptyNodes') }}</div>
            <div class="text-12 text-secondary max-w-360 text-center">{{ t('workbench.emptyNodesHint') }}</div>
            <div class="flex gap-12 mt-4">
              <Button @click="openSettingsTab('cloud')" type="primary" icon="link">
                {{ t('workbench.emptyImport') }}
              </Button>
              <Button @click="router.push({ name: 'Wizard' })" type="primary" icon="play">
                {{ t('workbench.emptyDeploy') }}
              </Button>
            </div>
          </div>
        </template>
      </Empty>
    </Card>

    <Card v-if="kernelApiStore.running && !kernelApiStore.coreStateLoading">
      <div class="flex items-center justify-between gap-12">
        <div class="text-18 font-bold">{{ t('workbench.runtimeTitle') }}</div>
        <Button @click="handleShowKernelLogs" type="text" icon="log">
          {{ t('workbench.viewLogs') }}
        </Button>
      </div>

      <div class="mt-16">
        <Tabs v-model:active-key="runtimeTab" :items="runtimeTabs">
          <template #groups>
            <GroupsController />
          </template>

          <template #overview>
            <OverView />
          </template>
        </Tabs>
      </div>
    </Card>
  </div>

  <Modal />
</template>

<style scoped>
.workbench-bar {
  background: color-mix(in srgb, var(--card-bg) 92%, transparent);
}

.node-row {
  padding: 14px 0;
  border-bottom: 1px solid color-mix(in srgb, var(--border-color) 72%, transparent);
}

.node-row:last-child {
  border-bottom: 0;
}
</style>
