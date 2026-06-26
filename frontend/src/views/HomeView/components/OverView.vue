<script setup lang="ts">
import { computed, onUnmounted, ref } from 'vue'
import { useI18n } from 'vue-i18n'

import { ClipboardSetText } from '@/bridge'
import { ModeOptions } from '@/constant/kernel'
import { useEnvStore, useAppStore, useKernelApiStore } from '@/stores'
import { formatBytes, handleChangeMode, message } from '@/utils'

import { useModal } from '@/components/Modal'

import CommonController from './CommonController.vue'
import ConnectionsController from './ConnectionsController.vue'
import LogsController from './LogsController.vue'

const statistics = ref({
  upload: 0,
  download: 0,
  downloadTotal: 0,
  uploadTotal: 0,
  connections: [] as any[],
  inuse: 0,
})

const { t } = useI18n()
const [Modal, modalApi] = useModal({})
const appStore = useAppStore()
const envStore = useEnvStore()
const kernelApiStore = useKernelApiStore()

const proxyCopyHost = '127.0.0.1'
const proxyListenHost = computed(() => (kernelApiStore.config['allow-lan'] ? '0.0.0.0' : proxyCopyHost))

const proxyPorts = computed(() => [
  {
    key: 'mixed',
    label: t('home.overview.proxyPorts.mixed'),
    port: kernelApiStore.config['mixed-port'],
    protocol: '',
  },
  {
    key: 'http',
    label: t('home.overview.proxyPorts.http'),
    port: kernelApiStore.config.port,
    protocol: 'http',
  },
  {
    key: 'socks',
    label: t('home.overview.proxyPorts.socks'),
    port: kernelApiStore.config['socks-port'],
    protocol: 'socks5',
  },
])

const enabledProxyPorts = computed(() => proxyPorts.value.filter((item) => item.port > 0))

const proxyPortSummary = computed(() => {
  if (!enabledProxyPorts.value.length) return t('home.overview.proxyPorts.none')
  return enabledProxyPorts.value
    .map((item) => `${item.label} ${item.port}`)
    .join(' · ')
})

const copyProxyEndpoint = async (entry: (typeof proxyPorts.value)[number]) => {
  if (!entry.port) {
    message.error('home.overview.needPort')
    return
  }
  const endpoint = entry.protocol
    ? `${entry.protocol}://${proxyCopyHost}:${entry.port}`
    : `${proxyCopyHost}:${entry.port}`
  await ClipboardSetText(endpoint)
  message.success('common.copied')
}

const copyAllProxyEndpoints = async () => {
  if (!enabledProxyPorts.value.length) {
    message.error('home.overview.needPort')
    return
  }
  await ClipboardSetText(
    enabledProxyPorts.value
      .map((entry) => {
        const endpoint = entry.protocol
          ? `${entry.protocol}://${proxyCopyHost}:${entry.port}`
          : `${proxyCopyHost}:${entry.port}`
        return `${entry.label}: ${endpoint}`
      })
      .join('\n'),
  )
  message.success('common.copied')
}

const handleRestartKernel = async () => {
  try {
    await kernelApiStore.restartCore()
  } catch (error: any) {
    console.error(error)
    message.error(error)
  }
}

const handleStopKernel = async () => {
  try {
    await kernelApiStore.stopCore()
  } catch (error: any) {
    console.error(error)
    message.error(error)
  }
}

const handleShowApiLogs = () => {
  modalApi.setProps({
    title: 'Logs',
    cancelText: 'common.close',
    width: '90',
    height: '90',
    submit: false,
    maskClosable: true,
  })
  modalApi.setContent(LogsController).open()
}

const handleShowApiConnections = () => {
  modalApi.setProps({
    title: 'home.overview.connections',
    cancelText: 'common.close',
    width: '90',
    height: '90',
    submit: false,
    maskClosable: true,
  })
  modalApi.setContent(ConnectionsController).open()
}

const handleShowSettings = () => {
  modalApi.setProps({
    title: 'home.overview.settings',
    cancelText: 'common.close',
    width: '90',
    submit: false,
    maskClosable: true,
  })
  modalApi.setContent(CommonController).open()
}

const onTunSwitchChange = async (enable: boolean) => {
  try {
    await kernelApiStore.updateConfig('tun', { enable })
  } catch (error: any) {
    kernelApiStore.config.tun.enable = !kernelApiStore.config.tun.enable
    console.error(error)
    message.error(error)
  }
}

const onSystemProxySwitchChange = async (enable: boolean) => {
  try {
    await envStore.switchSystemProxy(enable)
  } catch (error: any) {
    console.error(error)
    message.error(error)
    envStore.systemProxy = !envStore.systemProxy
  }
}

const unregisterMemoryHandler = kernelApiStore.onMemory((data) => {
  statistics.value.inuse = data.inuse
})

const unregisterTrafficHandler = kernelApiStore.onTraffic((data) => {
  const { up, down } = data
  statistics.value.upload = up
  statistics.value.download = down
})

const unregisterConnectionsHandler = kernelApiStore.onConnections((data) => {
  statistics.value.downloadTotal = data.downloadTotal
  statistics.value.uploadTotal = data.uploadTotal
  statistics.value.connections = data.connections || []
})

onUnmounted(() => {
  unregisterMemoryHandler()
  unregisterTrafficHandler()
  unregisterConnectionsHandler()
})
</script>

<template>
  <div>
    <div class="flex items-center rounded-8 px-8 py-4" style="background-color: var(--card-bg)">
      <Button @click="handleShowSettings" type="text" size="small" icon="settings" />
      <Switch
        v-model="envStore.systemProxy"
        @change="onSystemProxySwitchChange"
        size="small"
        border="square"
        class="ml-4"
      >
        {{ t('home.overview.systemProxy') }}
      </Switch>
      <Switch
        v-model="kernelApiStore.config.tun.enable"
        @change="onTunSwitchChange"
        size="small"
        border="square"
        class="ml-8"
      >
        {{ t('home.overview.tunMode') }}
      </Switch>
      <CustomAction :actions="appStore.customActions.core_state" />
      <Button
        @click="handleShowApiLogs"
        v-tips="'home.overview.viewlog'"
        type="text"
        size="small"
        icon="log"
        class="ml-auto"
      />
      <Button
        @click="handleRestartKernel"
        v-tips="'home.overview.restart'"
        :loading="kernelApiStore.restarting"
        type="text"
        size="small"
        icon="restart"
      />
      <Button
        @click="handleStopKernel"
        v-tips="'home.overview.stop'"
        :loading="kernelApiStore.stopping"
        type="text"
        size="small"
        icon="stop"
      />
    </div>
    <div class="flex flex-wrap mt-20 gap-12">
      <Card class="flex-[1.6] proxy-ports-card">
        <template #title>
          <div class="flex items-center gap-8 min-w-0">
            <span class="font-bold text-16">{{ t('home.overview.proxyPorts.title') }}</span>
            <Tag :color="enabledProxyPorts.length ? 'green' : 'red'" size="small">
              {{ enabledProxyPorts.length ? t('common.enabled') : t('common.disabled') }}
            </Tag>
          </div>
        </template>
        <template #extra>
          <Button
            @click="copyAllProxyEndpoints"
            type="text"
            size="small"
            icon="link"
            v-tips="'home.overview.proxyPorts.copyAll'"
          />
        </template>
        <div class="proxy-ports-panel py-8">
          <div class="proxy-ports-summary" :title="proxyPortSummary">
            {{ proxyPortSummary }}
          </div>
          <div class="proxy-ports-grid">
            <button
              v-for="entry in proxyPorts"
              :key="entry.key"
              type="button"
              class="proxy-port-tile"
              :class="{ 'proxy-port-tile--disabled': !entry.port }"
              :title="entry.port ? `${proxyCopyHost}:${entry.port}` : t('common.disabled')"
              @click="copyProxyEndpoint(entry)"
            >
              <span class="proxy-port-label">{{ entry.label }}</span>
              <span class="proxy-port-value">{{ entry.port || 'Off' }}</span>
            </button>
          </div>
          <div class="proxy-ports-listen">
            <span>{{ t('home.overview.proxyPorts.listen') }}</span>
            <span class="font-mono">{{ proxyListenHost }}</span>
            <Tag :color="kernelApiStore.config['allow-lan'] ? 'cyan' : 'default'" size="small">
              {{
                kernelApiStore.config['allow-lan']
                  ? t('home.overview.proxyPorts.lanOn')
                  : t('home.overview.proxyPorts.localOnly')
              }}
            </Tag>
          </div>
        </div>
      </Card>
      <Card :title="t('kernel.mode')" class="flex-1 min-w-120">
        <div class="py-8">
          <Select
            v-model="kernelApiStore.config.mode"
            :options="ModeOptions.map(m => ({ label: t(m.label), value: m.value }))"
            @change="handleChangeMode"
            size="small"
          />
        </div>
      </Card>
      <Card :title="t('home.overview.realtimeTraffic')" class="flex-1 min-w-140">
        <div class="py-8 text-12">
          ↑ {{ formatBytes(statistics.upload) }}/s ↓ {{ formatBytes(statistics.download) }}/s
        </div>
      </Card>
      <Card :title="t('home.overview.totalTraffic')" class="flex-1 min-w-140">
        <div class="py-8 text-12">
          ↑ {{ formatBytes(statistics.uploadTotal) }} ↓ {{ formatBytes(statistics.downloadTotal) }}
        </div>
      </Card>
      <Card
        @click="handleShowApiConnections"
        :title="t('home.overview.connections')"
        class="flex-1 min-w-120 cursor-pointer"
      >
        <div class="py-8 text-12">
          {{ statistics.connections.length }}
        </div>
      </Card>
      <Card :title="t('home.overview.memory')" class="flex-1 min-w-120">
        <div class="py-8 text-12">
          {{ formatBytes(statistics.inuse) }}
        </div>
      </Card>
    </div>
  </div>

  <Modal />
</template>

<style lang="less" scoped>
.proxy-ports-card {
  min-width: 280px;
}

.proxy-ports-panel {
  min-width: 0;
}

.proxy-ports-summary {
  min-height: 18px;
  margin-bottom: 8px;
  overflow: hidden;
  color: var(--text-secondary-color);
  font-size: 12px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.proxy-ports-grid {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 6px;
}

.proxy-port-tile {
  display: flex;
  min-width: 0;
  min-height: 56px;
  flex-direction: column;
  align-items: flex-start;
  justify-content: center;
  gap: 4px;
  padding: 8px;
  border: 1px solid var(--border-color);
  border-radius: 6px;
  background: color-mix(in srgb, var(--card-bg) 88%, var(--primary-color) 12%);
  color: var(--card-color);
  cursor: pointer;
  transition:
    border-color 0.2s,
    background 0.2s;

  &:hover {
    border-color: var(--primary-color);
    background: color-mix(in srgb, var(--card-bg) 78%, var(--primary-color) 22%);
  }

  &:focus-visible {
    outline: 2px solid var(--primary-color);
    outline-offset: 2px;
  }
}

.proxy-port-tile--disabled {
  background: transparent;
  color: var(--text-tertiary-color);
}

.proxy-port-label {
  max-width: 100%;
  overflow: hidden;
  color: var(--text-secondary-color);
  font-size: 11px;
  line-height: 1.1;
  text-overflow: ellipsis;
  text-transform: uppercase;
  white-space: nowrap;
}

.proxy-port-value {
  max-width: 100%;
  overflow: hidden;
  font-family: var(--font-family-mono, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace);
  font-size: 20px;
  font-weight: 700;
  line-height: 1.1;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.proxy-ports-listen {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px;
  margin-top: 8px;
  color: var(--text-secondary-color);
  font-size: 12px;
}
</style>
