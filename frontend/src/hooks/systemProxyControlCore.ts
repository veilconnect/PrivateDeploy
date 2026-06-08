import { confirm, message } from '@/utils'

type AppSettingsDeps = {
  app: {
    autoSetSystemProxy: boolean
    systemProxyPolicyInitialized: boolean
  }
}

type EnvDeps = {
  capabilities: {
    systemProxySupported: boolean
  }
  systemProxyState: string
  restorePreviousSystemProxy: (clearBackup?: boolean) => Promise<boolean>
  setSystemProxyIfSafe: () => Promise<boolean>
  updateSystemProxyStatus: () => Promise<unknown>
}

export type SystemProxyControlDeps = {
  appSettingsStore: AppSettingsDeps
  envStore: EnvDeps
}

const toErrorMessage = (error: unknown) => {
  if (error instanceof Error) return error.message
  return String(error)
}

export const syncSystemProxyStatus = async (envStore: EnvDeps) => {
  await envStore.updateSystemProxyStatus().catch((error) => {
    console.error('[SystemProxy] Failed to sync status:', error)
  })
}

export const enableSystemProxyAutomation = async (
  deps: SystemProxyControlDeps,
  options: {
    forcePrompt?: boolean
    kernelRunning?: boolean
  } = {},
) => {
  const { appSettingsStore, envStore } = deps
  const forcePrompt = options.forcePrompt ?? true
  const kernelRunning = options.kernelRunning ?? false

  await syncSystemProxyStatus(envStore)

  if (!envStore.capabilities.systemProxySupported) {
    message.info('settings.systemProxy.status.unsupported')
    return false
  }

  if (appSettingsStore.app.autoSetSystemProxy) {
    return true
  }

  let shouldEnable = true
  if (forcePrompt) {
    shouldEnable = await confirm(
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
  }

  appSettingsStore.app.systemProxyPolicyInitialized = true
  appSettingsStore.app.autoSetSystemProxy = shouldEnable

  if (!shouldEnable) {
    message.info('settings.systemProxy.firstLaunchDisabled')
    return false
  }

  if (!kernelRunning) {
    message.success('settings.systemProxy.firstLaunchEnabled')
    return true
  }

  try {
    const applied = await envStore.setSystemProxyIfSafe()
    await syncSystemProxyStatus(envStore)

    if (!applied) {
      message.warn('settings.systemProxy.autoSkippedExisting')
      return true
    }

    message.success('settings.systemProxy.firstLaunchEnabled')
    return true
  } catch (error) {
    console.error('[SystemProxy] Failed to enable automation:', error)
    message.error(toErrorMessage(error))
    return false
  }
}

export const disableSystemProxyAutomation = async (deps: SystemProxyControlDeps) => {
  const { appSettingsStore, envStore } = deps

  await syncSystemProxyStatus(envStore)

  if (!envStore.capabilities.systemProxySupported) {
    appSettingsStore.app.autoSetSystemProxy = false
    appSettingsStore.app.systemProxyPolicyInitialized = true
    return false
  }

  const shouldDisable = await confirm(
    'settings.systemProxy.disableConfirmTitle',
    'settings.systemProxy.disableConfirmMessage',
    {
      type: 'text',
      okText: 'common.disable',
      cancelText: 'common.cancel',
    },
  )
    .then(() => true)
    .catch(() => false)

  if (!shouldDisable) return true

  appSettingsStore.app.autoSetSystemProxy = false
  appSettingsStore.app.systemProxyPolicyInitialized = true

  try {
    const restored = await envStore.restorePreviousSystemProxy(true)
    await syncSystemProxyStatus(envStore)

    if (restored) {
      message.success('settings.systemProxy.restoreSuccess')
    } else {
      message.info('settings.systemProxy.firstLaunchDisabled')
    }
    return true
  } catch (error) {
    console.error('[SystemProxy] Failed to disable automation:', error)
    message.error('settings.systemProxy.restoreFailed')
    return false
  }
}

export const maybePromptToEnableSystemProxyBeforeConnect = async (
  deps: SystemProxyControlDeps,
) => {
  const { appSettingsStore, envStore } = deps

  await syncSystemProxyStatus(envStore)

  if (!envStore.capabilities.systemProxySupported) return false
  if (appSettingsStore.app.autoSetSystemProxy) return true
  if (appSettingsStore.app.systemProxyPolicyInitialized) return false
  if (envStore.systemProxyState !== 'disabled') return false

  return enableSystemProxyAutomation(deps, {
    forcePrompt: true,
    kernelRunning: false,
  })
}
