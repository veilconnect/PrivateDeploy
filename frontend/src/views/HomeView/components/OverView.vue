<script setup lang="ts">
import { computed, onUnmounted, ref } from 'vue'
import { useI18n } from 'vue-i18n'

import { ModeOptions } from '@/constant/kernel'
import {
  useEnvStore,
  useAppStore,
  useAppSettingsStore,
  useKernelApiStore,
  useProfilesStore,
} from '@/stores'
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
const profilesStore = useProfilesStore()
const appSettingsStore = useAppSettingsStore()

// Local proxy (mixed) port the app listens on — shown so users know what to
// point their browser/system proxy at, and editable inline.
const proxyPort = computed(() => kernelApiStore.config['mixed-port'] || 0)
const portEditing = ref(false)
const portDraft = ref(0)
const portApplying = ref(false)

const startEditPort = () => {
  portDraft.value = proxyPort.value
  portEditing.value = true
}

const applyPort = async () => {
  const next = Number(portDraft.value)
  if (!Number.isInteger(next) || next < 1 || next > 65535) {
    message.error('端口需为 1-65535 的整数 / Port must be 1-65535')
    return
  }
  if (next === proxyPort.value) {
    portEditing.value = false
    return
  }
  const rp = profilesStore.getProfileById(appSettingsStore.app.kernel.profile)
  const mixed = rp?.inbounds?.find((i: any) => i.type === 'mixed')
  if (!rp || !mixed?.mixed?.listen) {
    message.error('当前无运行中的 mixed 入站,无法改端口 / No active mixed inbound')
    return
  }
  portApplying.value = true
  try {
    mixed.mixed.listen.listen_port = next
    await profilesStore.editProfile(rp.id, rp)
    await kernelApiStore.restartCore()
    portEditing.value = false
    message.success(`代理端口已改为 ${next} / Proxy port changed to ${next}`)
  } catch (error: any) {
    console.error(error)
    message.error(error)
  } finally {
    portApplying.value = false
  }
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
      <Card :title="t('kernel.inbounds.listen.listen_port')" class="flex-1">
        <div
          v-if="!portEditing"
          v-tips="'点击修改端口 / Click to edit'"
          class="py-8 text-12 cursor-pointer"
          @click="startEditPort"
        >
          127.0.0.1:{{ proxyPort }}
        </div>
        <div v-else class="py-8 flex items-center gap-4">
          <Input v-model="portDraft" type="number" size="small" style="width: 70px" />
          <Button @click="applyPort" :loading="portApplying" type="primary" size="small" icon="selected" />
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
  </div>

  <Modal />
</template>
