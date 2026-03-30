import { useAppSettingsStore, useEnvStore, useKernelApiStore } from '@/stores'
import { confirm, message } from '@/utils'

const toErrorMessage = (error: unknown) => {
  if (error instanceof Error) return error.message
  return String(error)
}

export const useSystemProxyControl = () => {
  const appSettingsStore = useAppSettingsStore()
  const envStore = useEnvStore()
  const kernelApiStore = useKernelApiStore()

  const syncStatus = async () => {
    await envStore.updateSystemProxyStatus().catch((error) => {
      console.error('[SystemProxy] Failed to sync status:', error)
    })
  }

  const enableAutomation = async (forcePrompt = true) => {
    await syncStatus()

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

    if (!kernelApiStore.running) {
      message.success('settings.systemProxy.firstLaunchEnabled')
      return true
    }

    try {
      const applied = await envStore.setSystemProxyIfSafe()
      await syncStatus()

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

  const disableAutomation = async () => {
    await syncStatus()

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
      await syncStatus()

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

  const maybePromptToEnableBeforeConnect = async () => {
    await syncStatus()

    if (!envStore.capabilities.systemProxySupported) return false
    if (appSettingsStore.app.autoSetSystemProxy) return true
    if (appSettingsStore.app.systemProxyPolicyInitialized) return false
    if (envStore.systemProxyState !== 'disabled') return false

    return enableAutomation(true)
  }

  const handleProxyStatusAction = async () => {
    await setAutomationEnabled(!appSettingsStore.app.autoSetSystemProxy, { forcePrompt: true })
  }

  const setAutomationEnabled = async (
    enabled: boolean,
    options: {
      forcePrompt?: boolean
    } = {},
  ) => {
    if (enabled) {
      await enableAutomation(options.forcePrompt ?? true)
    } else {
      await disableAutomation()
    }

    return appSettingsStore.app.autoSetSystemProxy
  }

  return {
    disableAutomation,
    enableAutomation,
    handleProxyStatusAction,
    maybePromptToEnableBeforeConnect,
    setAutomationEnabled,
  }
}
