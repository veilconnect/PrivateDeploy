import { defineStore } from 'pinia'
import { computed, ref, watch } from 'vue'

import { getProxies } from '@/api/kernel'
import { ExecBackground } from '@/bridge'
import {
  CoreStopOutputKeyword,
  CoreWorkingDirectory,
} from '@/constant/kernel'
import { Branch } from '@/enums/app'
import { Inbound } from '@/enums/kernel'
import {
  useAppSettingsStore,
  useProfilesStore,
  useLogsStore,
  useEnvStore,
  usePluginsStore,
} from '@/stores'
import {
  generateConfigFile,
  updateTrayMenus,
  getKernelFileName,
  deepClone,
  message,
  getKernelRuntimeArgs,
  getKernelRuntimeEnv,
} from '@/utils'

import {
  createKernelApiConfigManager,
} from './kernelApiConfig'
import {
  createKernelApiLifecycleManager,
} from './kernelApiLifecycle'
import {
  addCloudNodeToKernelGroups,
  addProxyToKernelGroups,
  removeProxyFromKernelGroups,
} from './kernelApiProxyGroups'
import {
  ensureKernelCoreExecutable,
} from './kernelApiRuntime'
import { runKernelStartAttempts } from './kernelApiStartRunner'
import { createKernelApiWebsocketManager } from './kernelApiWebsocket'

import type {
  CoreApiConfig,
  CoreApiProxy,
} from '@/types/kernel'
export type { ProxyType } from './kernelApiConfig'
export type ConfigWriteHook = (config: Record<string, any>) => void | Promise<void>

// Hooks that modify the sing-box config before it is written to disk.
// Used by the cloud store to inject load balance inbounds/routes.
const _configWriteHooks: ConfigWriteHook[] = []

export const registerConfigWriteHook = (hook: ConfigWriteHook) => {
  _configWriteHooks.push(hook)
}

export const unregisterConfigWriteHook = (hook: ConfigWriteHook) => {
  const idx = _configWriteHooks.indexOf(hook)
  if (idx >= 0) _configWriteHooks.splice(idx, 1)
}

export const useKernelApiStore = defineStore('kernelApi', () => {
  const envStore = useEnvStore()
  const logsStore = useLogsStore()
  const pluginsStore = usePluginsStore()
  const profilesStore = useProfilesStore()
  const appSettingsStore = useAppSettingsStore()

  /** RESTful API */
  const config = ref<CoreApiConfig>({
    port: 0,
    'mixed-port': 0,
    'socks-port': 0,
    'interface-name': '',
    'allow-lan': false,
    mode: '',
    tun: {
      enable: false,
      stack: 'System',
      device: '',
    },
  })

  let runtimeProfile: IProfile | undefined

  const proxies = ref<Record<string, CoreApiProxy>>({})

  const refreshProviderProxies = async () => {
    const { proxies: b } = await getProxies()
    proxies.value = b
  }

  const coreWebsockets = createKernelApiWebsocketManager({
    getControllerInfo: () => {
      let base = 'ws://127.0.0.1:20123'
      let bearer = ''
      const profile = profilesStore.getProfileById(appSettingsStore.app.kernel.profile)
      if (profile) {
        const controller = profile.experimental.clash_api.external_controller || '127.0.0.1:20123'
        const [, port = 20123] = controller.split(':')
        base = `ws://127.0.0.1:${port}`
        bearer = profile.experimental.clash_api.secret
      }
      return { base, bearer }
    },
  })

  /* Bridge API */
  const corePid = ref(-1)
  const running = ref(false)
  const starting = ref(false)
  const stopping = ref(false)
  const restarting = ref(false)
  const coreStateLoading = ref(true)
  let startCoreTask: Promise<void> | null = null
  let restartCoreTask: Promise<void> | null = null

  const { getProxyPort, refreshConfig, updateConfig } = createKernelApiConfigManager({
    config,
    getRuntimeProfile: () => runtimeProfile,
    setRuntimeProfile: (profile) => {
      runtimeProfile = profile
    },
    getSelectedProfile: () => profilesStore.getProfileById(appSettingsStore.app.kernel.profile),
    restartCore: () => restartCore(),
    updateSystemProxyStatus: () => envStore.updateSystemProxyStatus(),
  })

  const lifecycleManager = createKernelApiLifecycleManager({
    corePid,
    running,
    stopping,
    restarting,
    coreStateLoading,
    refreshConfig,
    refreshProviderProxies,
    startCore: (profile) => startCore(profile),
    getRuntimeProfile: () => runtimeProfile,
    isAutoStartKernelEnabled: () => appSettingsStore.app.autoStartKernel,
    isAutoSetSystemProxyEnabled: () => appSettingsStore.app.autoSetSystemProxy,
    restoreSystemProxyAfterUnexpectedExit: () => envStore.restoreSystemProxyAfterUnexpectedExit(),
    updateSystemProxyStatus: () => envStore.updateSystemProxyStatus(),
    setSystemProxyIfSafe: () => envStore.setSystemProxyIfSafe(),
    restorePreviousSystemProxy: (clearBackup) => envStore.restorePreviousSystemProxy(clearBackup),
    onBeforeCoreStopTrigger: () => pluginsStore.onBeforeCoreStopTrigger(),
    onCoreStartedTrigger: () => pluginsStore.onCoreStartedTrigger(),
    onCoreStoppedTrigger: () => pluginsStore.onCoreStoppedTrigger(),
    startCoreWebsockets: () => {
      coreWebsockets.init()
      coreWebsockets.connectLongLived()
    },
    stopCoreWebsockets: () => coreWebsockets.destroy(),
  })

  const runCoreProcess = (isAlpha: boolean) => {
    return new Promise<number | void>((resolve, reject) => {
      let output: string
      const pid = ExecBackground(
        CoreWorkingDirectory + '/' + getKernelFileName(isAlpha),
        getKernelRuntimeArgs(isAlpha),
        (out) => {
          output = out
          logsStore.recordKernelLog(out)
          if (out.toLowerCase().includes(CoreStopOutputKeyword)) {
            resolve(pid)
          }
        },
        () => {
          lifecycleManager.onCoreStopped()
          reject(output)
        },
        { StopOutputKeyword: CoreStopOutputKeyword, Env: getKernelRuntimeEnv(isAlpha) },
      ).catch((e) => reject(e))
    })
  }

  const startCore = async (_profile?: IProfile) => {
    if (startCoreTask) {
      logsStore.recordKernelLog('[KernelApi] startCore joined existing start attempt')
      return startCoreTask
    }

    const startTask = (async () => {
      if (running.value) throw 'The core is already running'
      if (starting.value) {
        logsStore.recordKernelLog(
          '[KernelApi] startCore ignored because another start attempt is in progress',
        )
        return
      }

      logsStore.clearKernelLog()

      const { profile: profileID, branch } = appSettingsStore.app.kernel
      const profile = _profile || profilesStore.getProfileById(profileID)
      if (!profile) throw 'Choose a profile first'

      if (!_profile) {
        runtimeProfile = undefined
      }

      const isAlpha = branch === Branch.Alpha
      const corePath = `${CoreWorkingDirectory}/${getKernelFileName(isAlpha)}`
      const coreReady = await ensureKernelCoreExecutable({
        isAlpha,
        corePath,
        log: (entry) => logsStore.recordKernelLog(entry),
      }).catch((error) => {
        logsStore.recordKernelLog(
          `[KernelApi] Failed to prepare core executable: ${String(error ?? '')}`,
        )
        return false
      })
      if (!coreReady) {
        message.error('kernel.errors.coreMissing')
        return
      }

      starting.value = true
      const profileToUse = deepClone(profile)
      let portsAdjusted = false
      let missingCloudSubscriptionsPruned = false

      try {
        const result = await runKernelStartAttempts({
          isAlpha,
          profileToUse,
          writeConfig: async () => {
            await generateConfigFile(profileToUse, async (generatedConfig) => {
              const result = await pluginsStore.onBeforeCoreStartTrigger(generatedConfig, profileToUse)
              for (const hook of _configWriteHooks) {
                await hook(result || generatedConfig)
              }
              return result
            })
          },
          runCoreProcess,
          onCoreStarted: lifecycleManager.onCoreStarted,
          log: (entry) => logsStore.recordKernelLog(entry),
          onPortsAdjusted: (ports) => {
            if (ports[Inbound.Mixed]) {
              config.value['mixed-port'] = ports[Inbound.Mixed]
            }
            if (ports[Inbound.Http]) {
              config.value['port'] = ports[Inbound.Http]
            }
            if (ports[Inbound.Socks]) {
              config.value['socks-port'] = ports[Inbound.Socks]
            }
          },
        })

        portsAdjusted = result.portsAdjusted
        missingCloudSubscriptionsPruned = result.missingCloudSubscriptionsPruned
      } finally {
        starting.value = false
      }

      if ((portsAdjusted || missingCloudSubscriptionsPruned) && profileToUse.id) {
        await profilesStore.editProfile(profileToUse.id, deepClone(profileToUse))
      }
    })()

    startCoreTask = startTask
    try {
      await startTask
    } finally {
      if (startCoreTask === startTask) {
        startCoreTask = null
      }
    }
  }

  const stopCore = lifecycleManager.stopCore

  const restartCore = async (cleanupTask?: () => Promise<any>, keepRuntimeProfile = true) => {
    if (restartCoreTask) {
      logsStore.recordKernelLog('[KernelApi] restartCore joined existing restart attempt')
      return restartCoreTask
    }

    const restartTask = lifecycleManager.restartCore(cleanupTask, keepRuntimeProfile)

    restartCoreTask = restartTask
    try {
      await restartTask
    } finally {
      if (restartCoreTask === restartTask) {
        restartCoreTask = null
      }
    }
  }

  const updateCoreState = lifecycleManager.updateCoreState

  const watchSources = computed(() => {
    const source = [config.value.mode, config.value.tun.enable]
    if (!appSettingsStore.app.addGroupToMenu) return source.join('')

    const { unAvailable, sortByDelay } = appSettingsStore.app.kernel

    const proxySignature = Object.values(proxies.value)
      .map((group) => group.name + group.now)
      .sort()
      .join()

    return source.concat([proxySignature, unAvailable, sortByDelay]).join('')
  })

  watch([watchSources, running], updateTrayMenus)

  /**
   * Optimistically remove a subscription from all proxy groups
   * This provides immediate UI feedback without waiting for kernel restart
   */
  const removeProxyFromGroups = (subscriptionId: string) => {
    proxies.value = removeProxyFromKernelGroups(proxies.value, subscriptionId)
  }

  /**
   * Optimistically add a subscription to all selector and urltest groups
   * This provides immediate UI feedback without waiting for kernel restart
   */
  const addProxyToGroups = (subscriptionId: string) => {
    proxies.value = addProxyToKernelGroups(proxies.value, subscriptionId)
  }

  /**
   * Add all proxy nodes from a cloud deployment to proxy groups for instant UI feedback
   * Generates node tags based on CloudNode configuration (multi-protocol support)
   */
  const addCloudNodeToGroups = (node: any) => {
    proxies.value = addCloudNodeToKernelGroups(proxies.value, node)
  }

  return {
    startCore,
    stopCore,
    restartCore,
    updateCoreState,
    pid: corePid,
    running,
    starting,
    stopping,
    restarting,
    coreStateLoading,
    config,
    proxies,
    refreshConfig,
    updateConfig,
    refreshProviderProxies,
    removeProxyFromGroups,
    addProxyToGroups,
    addCloudNodeToGroups,
    getProxyPort,

    onLogs: coreWebsockets.onLogs,
    onMemory: coreWebsockets.onMemory,
    onTraffic: coreWebsockets.onTraffic,
    onConnections: coreWebsockets.onConnections,

    // Deprecated
    startKernel: (...args: any[]) => {
      console.warn('[Deprecated] "startKernel" is deprecated. Please use "startCore" instead.')
      startCore(...args)
    },
    stopKernel: () => {
      console.warn('[Deprecated] "stopKernel" is deprecated. Please use "stopCore" instead.')
      stopCore()
    },
    restartKernel: (...args: any[]) => {
      console.warn('[Deprecated] "restartKernel" is deprecated. Please use "restartCore" instead.')
      restartCore(...args)
    },
  }
})
