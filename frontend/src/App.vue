<script setup lang="ts">
import { ref } from 'vue'

import { EventsOn, WindowHide, IsStartup } from '@/bridge'
import { NavigationBar, TitleBar } from '@/components'
import * as Stores from '@/stores'
import { exitApp, sampleID, sleep, message } from '@/utils'
import AboutView from '@/views/AboutView.vue'
import CommandView from '@/views/CommandView.vue'
import SplashView from '@/views/SplashView.vue'

const loading = ref(true)
const percent = ref(0)
const hasError = ref(false)

const envStore = Stores.useEnvStore()
const appStore = Stores.useAppStore()
const pluginsStore = Stores.usePluginsStore()
const profilesStore = Stores.useProfilesStore()
const rulesetsStore = Stores.useRulesetsStore()
const appSettings = Stores.useAppSettingsStore()
const kernelApiStore = Stores.useKernelApiStore()
const subscribesStore = Stores.useSubscribesStore()
const scheduledTasksStore = Stores.useScheduledTasksStore()
const cloudStore = Stores.useCloudStore()

EventsOn('onLaunchApp', async (args: string[]) => {
  const url = new URL(args[0])
  if (url.pathname.startsWith('//import-remote-profile')) {
    const _url = url.searchParams.get('url')
    const _name = decodeURIComponent(url.hash).slice(1) || sampleID()

    if (!_url) {
      message.error('URL missing')
      return
    }

    try {
      await subscribesStore.importSubscribe(_name, _url)
      message.success('common.success')
    } catch {
      message.error('URL missing')
    }
  }
})

EventsOn('onBeforeExitApp', async () => {
  if (appSettings.app.exitOnClose) {
    exitApp()
  } else {
    WindowHide()
  }
})

EventsOn('onExitApp', () => exitApp())

window.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    const closeFn = appStore.modalStack.at(-1)
    closeFn?.()
  }
})

envStore.setupEnv().then(async () => {
  const showError = (err: string) => {
    hasError.value = true
    message.error(err)
  }

  await Promise.all([
    appSettings.setupAppSettings(),
    profilesStore.setupProfiles(),
    subscribesStore.setupSubscribes(),
    rulesetsStore.setupRulesets(),
    pluginsStore.setupPlugins(),
    scheduledTasksStore.setupScheduledTasks(),
  ])

  const startTime = performance.now()
  percent.value = 20
  if (await IsStartup()) {
    await pluginsStore.onStartupTrigger().catch(showError)
  }

  percent.value = 40
  await pluginsStore.onReadyTrigger().catch(showError)

  // Auto-apply cloud nodes on startup
  percent.value = 60
  let autoApplyPromise: Promise<void> | undefined
  try {
    await cloudStore.loadConfig()
    if (cloudStore.config.apiKey) {
      await Promise.allSettled([cloudStore.fetchRegions(), cloudStore.fetchPlans()])
      autoApplyPromise = cloudStore
        .refreshInstances(true)
        .then(() => cloudStore.applyAllNodesToProfile())
        .then(() => undefined)
        .catch((error) => {
          console.error('[App] Failed to auto-apply cloud nodes:', error)
        })
    }
  } catch (error) {
    console.error('[App] Failed to prepare cloud data:', error)
  }

  const duration = performance.now() - startTime
  percent.value = duration < 500 ? 80 : 100

  await sleep(Math.max(0, 1000 - duration))

  loading.value = false
  await kernelApiStore.updateCoreState()

  percent.value = 100
  try {
    if (!kernelApiStore.running && autoApplyPromise) {
      await autoApplyPromise
    }
  } catch (error) {
    console.error('[App] Failed while waiting cloud auto-apply:', error)
  }
})
</script>

<template>
  <SplashView v-if="loading">
    <Progress
      :percent="percent"
      :status="hasError ? 'danger' : 'primary'"
      :radius="10"
      type="circle"
    />
  </SplashView>
  <template v-else>
    <TitleBar />
    <div class="flex-1 overflow-y-auto flex flex-col p-8">
      <NavigationBar />
      <div class="flex flex-col overflow-y-auto mt-8 px-8 h-full">
        <RouterView #="{ Component }">
          <KeepAlive>
            <component :is="Component" />
          </KeepAlive>
        </RouterView>
      </div>
    </div>
  </template>

  <Modal
    v-model:open="appStore.showAbout"
    :cancel="false"
    :submit="false"
    mask-closable
    min-width="50"
  >
    <AboutView />
  </Modal>

  <Menu
    v-model="appStore.menuShow"
    :position="appStore.menuPosition"
    :menu-list="appStore.menuList"
  />

  <Tips
    v-model="appStore.tipsShow"
    :position="appStore.tipsPosition"
    :message="appStore.tipsMessage"
  />

  <CommandView v-if="!loading" />
</template>
