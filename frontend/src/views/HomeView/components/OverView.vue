<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useI18n } from 'vue-i18n'

import { ModeOptions } from '@/constant/kernel'
import { useEnvStore, useAppStore, useKernelApiStore, useCloudStore } from '@/stores'
import { formatBytes, handleChangeMode, message } from '@/utils'
import { logError } from '@/utils/logger'

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
const cloudStore = useCloudStore()

const cloudNodes = computed(() =>
  cloudStore.instances.map((node: any) => ({
    ...node,
    id: node.instanceId || node.id,
    label: node.label || node.instanceId || node.id,
    status: node.status || node.statusText || 'unknown',
  })),
)

onMounted(async () => {
  try {
    if (!cloudStore.availableProviders.length) {
      await cloudStore.loadProviders()
    }
    if (!cloudStore.configLoaded) {
      await cloudStore.loadConfig()
    }
    if (!cloudStore.loadingInstances && !cloudStore.instances.length) {
      await cloudStore.refreshInstances(true)
    }
  } catch (error) {
    logError('[OverView] Failed to prepare cloud data:', error)
  }
})

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
    <div class="flex mt-20 gap-12">
      <Card :title="t('kernel.mode')" class="flex-1">
        <div class="py-8">
          <Select
            v-model="kernelApiStore.config.mode"
            :options="ModeOptions.map(m => ({ label: t(m.label), value: m.value }))"
            @change="handleChangeMode"
            size="small"
          />
        </div>
      </Card>
      <Card :title="t('home.overview.realtimeTraffic')" class="flex-1">
        <div class="py-8 text-12">
          ↑ {{ formatBytes(statistics.upload) }}/s ↓ {{ formatBytes(statistics.download) }}/s
        </div>
      </Card>
      <Card :title="t('home.overview.totalTraffic')" class="flex-1">
        <div class="py-8 text-12">
          ↑ {{ formatBytes(statistics.uploadTotal) }} ↓ {{ formatBytes(statistics.downloadTotal) }}
        </div>
      </Card>
      <Card
        @click="handleShowApiConnections"
        :title="t('home.overview.connections')"
        class="flex-1 cursor-pointer"
      >
        <div class="py-8 text-12">
          {{ statistics.connections.length }}
        </div>
      </Card>
      <Card :title="t('home.overview.memory')" class="flex-1">
        <div class="py-8 text-12">
          {{ formatBytes(statistics.inuse) }}
        </div>
      </Card>
    </div>
    <Card v-if="cloudNodes.length" :title="t('home.overview.cloudNodes')" class="mt-20">
      <div class="flex flex-col gap-8 py-8 text-12">
        <div
          v-for="node in cloudNodes"
          :key="node.id"
          class="flex items-center gap-8"
          style="border-bottom: 1px solid var(--divider-color); padding-bottom: 8px"
        >
          <div class="font-bold">{{ node.label }}</div>
          <Tag size="small" color="primary">{{ node.status }}</Tag>
          <span v-if="node.ipv4" class="font-mono text-secondary">IPv4: {{ node.ipv4 }}</span>
          <span v-if="node.ipv6" class="font-mono text-secondary">IPv6: {{ node.ipv6 }}</span>
        </div>
      </div>
    </Card>
  </div>

  <Modal />
</template>
