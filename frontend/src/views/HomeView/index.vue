<script setup lang="ts">
import { useI18n } from 'vue-i18n'

import { useAppSettingsStore, useProfilesStore, useKernelApiStore } from '@/stores'
import { APP_TITLE, message } from '@/utils'

import { useModal } from '@/components/Modal'

import GroupsController from './components/GroupsController.vue'
import KernelLogs from './components/KernelLogs.vue'
import OverView from './components/OverView.vue'
import QuickStart from './components/QuickStart.vue'

const { t } = useI18n()
const [Modal, modalApi] = useModal({})

const appSettingsStore = useAppSettingsStore()
const profilesStore = useProfilesStore()
const kernelApiStore = useKernelApiStore()

const handleStartKernel = async () => {
  try {
    await kernelApiStore.startCore()
  } catch (error: any) {
    console.error(error)
    message.error(error.message || error)
  }
}

const handleShowQuickStart = () => {
  modalApi.setProps({ title: 'subscribes.enterLink' })
  modalApi.setContent(QuickStart).open()
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
</script>

<template>
  <div class="relative overflow-hidden h-full">
    <div
      v-if="(!kernelApiStore.running && !kernelApiStore.stopping) || kernelApiStore.starting"
      class="w-full h-[90%] flex flex-col items-center justify-center"
    >
      <img src="@/assets/logo.png" draggable="false" class="w-128 mb-16" />

      <template v-if="profilesStore.profiles.length === 0">
        <p>{{ t('home.noProfile', [APP_TITLE]) }}</p>
        <Button @click="handleShowQuickStart" type="primary">{{ t('home.quickStart') }}</Button>
      </template>

      <template v-else>
        <div class="flex gap-8 mb-32">
          <Card
            v-for="p in profilesStore.profiles.slice(0, profilesStore.profiles.length > 4 ? 3 : 4)"
            :key="p.id"
            :selected="appSettingsStore.app.kernel.profile === p.id"
            @click="appSettingsStore.app.kernel.profile = p.id"
          >
            <div
              class="w-128 h-full flex items-center justify-center py-24 text-center cursor-pointer font-bold text-12"
            >
              {{ p.name }}
            </div>
          </Card>
          <Dropdown v-if="profilesStore.profiles.length > 4" placement="top">
            <Card class="h-full">
              <div
                class="w-128 h-full flex items-center justify-center py-24 text-center cursor-pointer font-bold text-12"
              >
                ...
              </div>
            </Card>
            <template #overlay>
              <div class="flex flex-col py-8">
                <Button
                  v-for="p in profilesStore.profiles.slice(3)"
                  :key="p.id"
                  @click="appSettingsStore.app.kernel.profile = p.id"
                >
                  <div class="min-w-32 w-full flex items-center justify-between">
                    {{ p.name }}
                    <Icon v-if="appSettingsStore.app.kernel.profile === p.id" icon="selected" />
                  </div>
                </Button>
              </div>
            </template>
          </Dropdown>
          <Card @click="handleShowQuickStart">
            <div
              class="w-128 h-full flex items-center justify-center py-24 text-center cursor-pointer font-bold text-12"
            >
              {{ t('home.quickStart') }}
            </div>
          </Card>
        </div>
        <Button @click="handleStartKernel" :loading="kernelApiStore.starting" type="primary">
          {{ t('home.overview.start') }}
        </Button>
        <Button @click="handleShowKernelLogs" type="link" size="small" class="mt-4">
          {{ t('home.overview.viewlog') }}
        </Button>
      </template>
    </div>

    <template v-else-if="!kernelApiStore.coreStateLoading">
      <div class="h-full overflow-y-auto">
        <OverView />
        <Divider>
          <span class="text-14 font-bold">{{ t('home.controller.name') }}</span>
        </Divider>
        <GroupsController />
      </div>
    </template>
  </div>

  <Modal />
</template>
