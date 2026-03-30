import { useAppSettingsStore, useEnvStore, useKernelApiStore } from '@/stores'

import {
  disableSystemProxyAutomation,
  enableSystemProxyAutomation,
  maybePromptToEnableSystemProxyBeforeConnect,
} from './systemProxyControlCore'

export const useSystemProxyControl = () => {
  const appSettingsStore = useAppSettingsStore()
  const envStore = useEnvStore()
  const kernelApiStore = useKernelApiStore()
  const deps = {
    appSettingsStore,
    envStore,
  }

  const enableAutomation = async (forcePrompt = true) => {
    return enableSystemProxyAutomation(deps, {
      forcePrompt,
      kernelRunning: kernelApiStore.running,
    })
  }

  const disableAutomation = async () => {
    return disableSystemProxyAutomation(deps)
  }

  const maybePromptToEnableBeforeConnect = async () => {
    return maybePromptToEnableSystemProxyBeforeConnect(deps)
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
