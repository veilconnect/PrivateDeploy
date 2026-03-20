import {
  KillProcess,
  ProcessInfo,
  ReadFile,
  RemoveFile,
  WriteFile,
} from '@/bridge'
import { CorePidFilePath } from '@/constant/kernel'
import { message } from '@/utils'

import type { Ref } from 'vue'

type CreateKernelApiLifecycleManagerDeps = {
  corePid: Ref<number>
  running: Ref<boolean>
  stopping: Ref<boolean>
  restarting: Ref<boolean>
  coreStateLoading: Ref<boolean>
  refreshConfig: () => Promise<void>
  refreshProviderProxies: () => Promise<void>
  startCore: (profile?: IProfile) => Promise<void>
  getRuntimeProfile: () => IProfile | undefined
  isAutoStartKernelEnabled: () => boolean
  isAutoSetSystemProxyEnabled: () => boolean
  restoreSystemProxyAfterUnexpectedExit: () => Promise<unknown>
  updateSystemProxyStatus: () => Promise<unknown>
  setSystemProxyIfSafe: () => Promise<boolean>
  restorePreviousSystemProxy: (clearBackup?: boolean) => Promise<unknown>
  onBeforeCoreStopTrigger: () => Promise<unknown>
  onCoreStartedTrigger: () => Promise<unknown>
  onCoreStoppedTrigger: () => Promise<unknown>
  startCoreWebsockets: () => void
  stopCoreWebsockets: () => void
}

export const createKernelApiLifecycleManager = ({
  corePid,
  running,
  stopping,
  restarting,
  coreStateLoading,
  refreshConfig,
  refreshProviderProxies,
  startCore,
  getRuntimeProfile,
  isAutoStartKernelEnabled,
  isAutoSetSystemProxyEnabled,
  restoreSystemProxyAfterUnexpectedExit,
  updateSystemProxyStatus,
  setSystemProxyIfSafe,
  restorePreviousSystemProxy,
  onBeforeCoreStopTrigger,
  onCoreStartedTrigger,
  onCoreStoppedTrigger,
  startCoreWebsockets,
  stopCoreWebsockets,
}: CreateKernelApiLifecycleManagerDeps) => {
  let isCoreStartedByThisInstance = false
  let { promise: coreStoppedPromise, resolve: coreStoppedResolver } = Promise.withResolvers<null>()

  const updateCoreState = async () => {
    corePid.value = Number(await ReadFile(CorePidFilePath).catch(() => -1))
    const processName = corePid.value === -1 ? '' : await ProcessInfo(corePid.value).catch(() => '')
    running.value = processName.startsWith('sing-box')

    coreStateLoading.value = false

    if (running.value) {
      startCoreWebsockets()
      await Promise.all([refreshConfig(), refreshProviderProxies()])
    } else if (isAutoStartKernelEnabled()) {
      await restoreSystemProxyAfterUnexpectedExit().catch(() => undefined)
      await startCore()
    } else {
      await restoreSystemProxyAfterUnexpectedExit().catch(() => undefined)
    }

    await updateSystemProxyStatus().catch(() => undefined)
  }

  const onCoreStarted = async (pid: number) => {
    await WriteFile(CorePidFilePath, String(pid))

    corePid.value = pid
    running.value = true
    isCoreStartedByThisInstance = true
    coreStoppedPromise = new Promise((resolve) => {
      coreStoppedResolver = resolve
    })

    await Promise.all([refreshConfig(), refreshProviderProxies()])

    if (isAutoSetSystemProxyEnabled()) {
      try {
        const applied = await setSystemProxyIfSafe()
        if (!applied) {
          message.warn('settings.systemProxy.autoSkippedExisting')
        }
      } catch (error) {
        message.error(error as string)
      }
    }
    await onCoreStartedTrigger()

    startCoreWebsockets()
  }

  const onCoreStopped = async () => {
    await RemoveFile(CorePidFilePath)

    corePid.value = -1
    running.value = false

    if (isAutoSetSystemProxyEnabled()) {
      await restorePreviousSystemProxy(true).catch(() => undefined)
    }
    await onCoreStoppedTrigger()

    coreStoppedResolver(null)

    stopCoreWebsockets()
  }

  const stopCore = async () => {
    if (!running.value) throw 'The core is not running'

    stopping.value = true
    try {
      await onBeforeCoreStopTrigger()
      await KillProcess(corePid.value)
      await (isCoreStartedByThisInstance ? coreStoppedPromise : onCoreStopped())
    } finally {
      stopping.value = false
    }
  }

  const restartCore = async (
    cleanupTask?: () => Promise<any>,
    keepRuntimeProfile = true,
  ) => {
    restarting.value = true
    try {
      if (running.value) {
        await stopCore()
      }
      await cleanupTask?.()
      await startCore(keepRuntimeProfile ? getRuntimeProfile() : undefined)
    } finally {
      restarting.value = false
    }
  }

  return {
    onCoreStarted,
    onCoreStopped,
    restartCore,
    stopCore,
    updateCoreState,
  }
}
