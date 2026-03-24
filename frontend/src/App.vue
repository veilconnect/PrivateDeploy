<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRoute } from 'vue-router'

import { EventsOn, WindowHide, WindowShow, WindowUnminimise, IsStartup } from '@/bridge'
import { TitleBar, WorkspaceHeader } from '@/components'
import * as Stores from '@/stores'
import { confirm, exitApp, sampleID, sleep, message } from '@/utils'
import { ensureBuiltinPresets } from '@/utils/builtinPresets'
import AboutView from '@/views/AboutView.vue'
import CommandView from '@/views/CommandView.vue'
import SplashView from '@/views/SplashView.vue'

const loading = ref(true)
const percent = ref(0)
const hasError = ref(false)
const route = useRoute()

const envStore = Stores.useEnvStore()
const appStore = Stores.useAppStore()
const pluginsStore = Stores.usePluginsStore()
const profilesStore = Stores.useProfilesStore()
const rulesetsStore = Stores.useRulesetsStore()
const appSettings = Stores.useAppSettingsStore()
const kernelApiStore = Stores.useKernelApiStore()
const subscribesStore = Stores.useSubscribesStore()
const cloudStore = Stores.useCloudStore()
const showWorkspaceHeader = computed(() => route.name !== 'Wizard')

const revealMainWindow = async () => {
  await sleep(50)
  WindowShow()
  WindowUnminimise()
  await sleep(150)
  WindowShow()
  WindowUnminimise()
}

const showStartupError = (error: unknown) => {
  hasError.value = true
  console.error('[App] Startup failed:', error)
  message.error(error instanceof Error ? error.message : String(error))
}

const maybePromptSystemProxyPolicy = async () => {
  if (!envStore.capabilities.systemProxySupported || appSettings.app.systemProxyPolicyInitialized) {
    return
  }

  const enableAutoProxy = await confirm(
    'settings.systemProxy.firstLaunchTitle',
    'settings.systemProxy.firstLaunchMessage',
    {
      type: 'text',
      okText: 'common.enable',
      cancelText: 'common.disable',
    },
  )
    .then(() => true)
    .catch(() => false)

  appSettings.app.autoSetSystemProxy = enableAutoProxy
  appSettings.app.systemProxyPolicyInitialized = true
  message.info(
    enableAutoProxy
      ? 'settings.systemProxy.firstLaunchEnabled'
      : 'settings.systemProxy.firstLaunchDisabled',
  )
}

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

const bootstrapApp = async () => {
  let autoApplyPromise: Promise<void> | undefined

  try {
    await envStore.setupEnv()
    await appSettings.setupAppSettings()
    await subscribesStore.setupSubscribes()
    await rulesetsStore.setupRulesets()
    await profilesStore.setupProfiles()
    await ensureBuiltinPresets()
    await pluginsStore.setupPlugins()

    const startTime = performance.now()
    percent.value = 20
    if (await IsStartup()) {
      await pluginsStore.onStartupTrigger().catch(showStartupError)
    }

    percent.value = 40
    await pluginsStore.onReadyTrigger().catch(showStartupError)

    // Auto-apply cloud nodes on startup
    percent.value = 60
    try {
      await cloudStore.loadConfig()
      if (cloudStore.config.apiKey) {
        await Promise.allSettled([cloudStore.fetchRegions(), cloudStore.fetchPlans()])
      }
      autoApplyPromise = cloudStore
        .refreshInstances(true)
        .then(() => cloudStore.applyAllNodesToProfile())
        .then(() => undefined)
        .catch((error) => {
          console.error('[App] Failed to auto-apply cloud nodes:', error)
        })
    } catch (error) {
      console.error('[App] Failed to prepare cloud data:', error)
    }

    const duration = performance.now() - startTime
    percent.value = duration < 500 ? 80 : 100
    await sleep(Math.max(0, 1000 - duration))
  } catch (error) {
    showStartupError(error)
  } finally {
    loading.value = false
    percent.value = 100

    await revealMainWindow().catch((error) => {
      console.error('[App] Failed to reveal main window:', error)
    })

    await kernelApiStore.updateCoreState().catch((error) => {
      console.error('[App] Failed to update core state:', error)
    })

    if (!hasError.value) {
      await maybePromptSystemProxyPolicy()
    }

    try {
      if (!kernelApiStore.running && autoApplyPromise) {
        await autoApplyPromise
      }
    } catch (error) {
      console.error('[App] Failed while waiting cloud auto-apply:', error)
    }
  }
}

bootstrapApp()
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
    <div class="flex-1 overflow-y-auto flex flex-col px-8 pb-8 pt-6">
      <WorkspaceHeader v-if="showWorkspaceHeader" />
      <div class="flex flex-col overflow-y-auto h-full px-8">
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
