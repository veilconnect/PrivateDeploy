import { defineStore } from 'pinia'
import { ref, watch } from 'vue'

import { GetEnv } from '@/bridge'
import { useAppSettingsStore, useKernelApiStore } from '@/stores'
import { updateTrayMenus, SetSystemProxy, GetSystemProxy } from '@/utils'

import type { ProxyType } from './kernelApi'

export const useEnvStore = defineStore('env', () => {
  const env = ref({
    appName: '',
    appVersion: '',
    basePath: '',
    os: '',
    arch: '',
  })

  const systemProxy = ref(false)

  const getAppProxyServerList = () => {
    const kernelApiStore = useKernelApiStore()
    const { port, 'mixed-port': mixedPort, 'socks-port': socksPort } = kernelApiStore.config

    const list = [
      `http://127.0.0.1:${port}`,
      `http://127.0.0.1:${mixedPort}`,

      `socks5://127.0.0.1:${mixedPort}`,
      `socks5://127.0.0.1:${socksPort}`,

      `socks=127.0.0.1:${mixedPort}`,
      `socks=127.0.0.1:${socksPort}`,
    ]

    return list.filter((item) => !item.endsWith(':0'))
  }

  const isAppManagedProxy = (proxyServer: string) => {
    if (!proxyServer) return false
    return getAppProxyServerList().includes(proxyServer)
  }

  const parseSavedProxy = (
    proxyServer: string,
  ):
    | {
        server: string
        proxyType: ProxyType
      }
    | undefined => {
    const value = proxyServer.trim()
    if (!value) return undefined

    if (value.startsWith('socks=')) {
      return {
        server: value.slice('socks='.length),
        proxyType: 'socks',
      }
    }
    if (
      value.startsWith('socks://') ||
      value.startsWith('socks4://') ||
      value.startsWith('socks5://')
    ) {
      return {
        server: value.replace(/^[a-z0-9]+:\/\//, ''),
        proxyType: 'socks',
      }
    }
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return {
        server: value.replace(/^[a-z0-9]+:\/\//, ''),
        proxyType: 'http',
      }
    }

    return {
      server: value,
      proxyType: 'http',
    }
  }

  const setSystemProxyInternal = async (allowOverrideExistingProxy: boolean) => {
    const appSettingsStore = useAppSettingsStore()
    const proxyPort = useKernelApiStore().getProxyPort()
    if (!proxyPort) throw 'home.overview.needPort'

    const currentProxy = await GetSystemProxy()
    const currentIsAppManaged = isAppManagedProxy(currentProxy)

    if (currentProxy && !currentIsAppManaged && !allowOverrideExistingProxy) {
      return false
    }

    if (currentProxy && !currentIsAppManaged && !appSettingsStore.app.systemProxyBackup) {
      appSettingsStore.app.systemProxyBackup = currentProxy
    }

    await SetSystemProxy(true, '127.0.0.1:' + proxyPort.port, proxyPort.proxyType)

    appSettingsStore.app.systemProxyManaged = true
    systemProxy.value = true
    return true
  }

  const setupEnv = async () => {
    const _env = await GetEnv()
    env.value = _env
  }

  const updateSystemProxyStatus = async () => {
    const proxyServer = await GetSystemProxy()

    if (!proxyServer) {
      systemProxy.value = false
    } else {
      systemProxy.value = isAppManagedProxy(proxyServer)
    }

    return systemProxy.value
  }

  const setSystemProxyIfSafe = async () => {
    return setSystemProxyInternal(false)
  }

  const setSystemProxy = async () => {
    await setSystemProxyInternal(true)
  }

  const clearSystemProxy = async () => {
    const appSettingsStore = useAppSettingsStore()
    await SetSystemProxy(false, '')
    appSettingsStore.app.systemProxyManaged = false
    systemProxy.value = false
  }

  const restorePreviousSystemProxy = async (clearBackup = true) => {
    const appSettingsStore = useAppSettingsStore()
    const backup = appSettingsStore.app.systemProxyBackup.trim()

    if (!backup) {
      if (!appSettingsStore.app.systemProxyManaged) return false

      await SetSystemProxy(false, '')
      appSettingsStore.app.systemProxyManaged = false
      if (clearBackup) {
        appSettingsStore.app.systemProxyBackup = ''
      }
      systemProxy.value = false
      return true
    }

    const parsed = parseSavedProxy(backup)
    if (!parsed) return false

    await SetSystemProxy(true, parsed.server, parsed.proxyType)

    appSettingsStore.app.systemProxyManaged = false
    if (clearBackup) {
      appSettingsStore.app.systemProxyBackup = ''
    }
    await updateSystemProxyStatus()
    return true
  }

  const restoreSystemProxyAfterUnexpectedExit = async () => {
    const appSettingsStore = useAppSettingsStore()
    if (!appSettingsStore.app.systemProxyManaged) return false

    const currentProxy = await GetSystemProxy()
    if (!isAppManagedProxy(currentProxy)) {
      appSettingsStore.app.systemProxyManaged = false
      appSettingsStore.app.systemProxyBackup = ''
      await updateSystemProxyStatus()
      return false
    }

    return restorePreviousSystemProxy(true)
  }

  const switchSystemProxy = async (enable: boolean) => {
    if (enable) await setSystemProxy()
    else await clearSystemProxy()
  }

  watch(systemProxy, updateTrayMenus)

  return {
    env,
    setupEnv,
    systemProxy,
    setSystemProxy,
    setSystemProxyIfSafe,
    clearSystemProxy,
    restorePreviousSystemProxy,
    restoreSystemProxyAfterUnexpectedExit,
    switchSystemProxy,
    updateSystemProxyStatus,
  }
})
