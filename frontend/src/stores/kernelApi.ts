import { defineStore } from 'pinia'
import { computed, ref, watch } from 'vue'

import { getProxies, getConfigs, setConfigs } from '@/api/kernel'
import {
  ProcessInfo,
  KillProcess,
  ExecBackground,
  Exec,
  ReadFile,
  WriteFile,
  RemoveFile,
  FileExists,
  CopyFile,
  AbsolutePath,
  MakeDir,
  MoveFile,
  UnzipZIPFile,
  UnzipTarGZFile,
  Download,
  HttpGet,
  HttpCancel,
} from '@/bridge'
import { GetAvailablePort } from '@/bridge/app'
import {
  CoreConfigFilePath,
  CoreCacheFilePath,
  CorePidFilePath,
  CoreStopOutputKeyword,
  CoreWorkingDirectory,
} from '@/constant/kernel'
import {
  DefaultExperimental,
  DefaultInboundMixed,
  DefaultInboundHttp,
  DefaultInboundSocks,
} from '@/constant/profile'
import { Branch } from '@/enums/app'
import { Inbound, TunStack } from '@/enums/kernel'
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
  restoreProfile,
  deepClone,
  message,
  getKernelRuntimeArgs,
  getKernelRuntimeEnv,
  getKernelAssetFileName,
  getGitHubApiAuthorization,
} from '@/utils'

import {
  addCloudNodeToKernelGroups,
  addProxyToKernelGroups,
  removeProxyFromKernelGroups,
} from './kernelApiProxyGroups'
import { createKernelApiWebsocketManager } from './kernelApiWebsocket'

import type {
  CoreApiConfig,
  CoreApiProxy,
} from '@/types/kernel'

export type ProxyType = 'mixed' | 'http' | 'socks'
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

const StableReleaseURL = 'https://api.github.com/repos/SagerNet/sing-box/releases/latest'
const AlphaReleaseURL = 'https://api.github.com/repos/SagerNet/sing-box/releases?per_page=2'

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

  const refreshConfig = async () => {
    const _config = await getConfigs()

    config.value = {
      ..._config,
      tun: config.value.tun,
    }

    if (!runtimeProfile) {
      const txt = await ReadFile(CoreConfigFilePath)
      runtimeProfile = restoreProfile(JSON.parse(txt))
      const profile = profilesStore.getProfileById(appSettingsStore.app.kernel.profile)
      if (profile) {
        const _profile = deepClone(profile)
        runtimeProfile.inbounds.forEach((inbound) => {
          const _in = _profile.inbounds.find((v) => v.tag === inbound.tag)
          if (_in) {
            inbound.id = _in.id
          }
        })
        const tunInbound = _profile.inbounds.find((v) => v.type === Inbound.Tun)
        if (tunInbound && !runtimeProfile.inbounds.find((v) => v.type === Inbound.Tun)) {
          tunInbound.enable = false
          runtimeProfile.inbounds.push(tunInbound)
        }
        runtimeProfile.id = _profile.id
        runtimeProfile.outbounds = _profile.outbounds
        runtimeProfile.experimental = _profile.experimental
        runtimeProfile.dns = _profile.dns
        runtimeProfile.route = _profile.route
        runtimeProfile.mixin = _profile.mixin
        runtimeProfile.script = _profile.script
      }
    }

    const mixed = runtimeProfile.inbounds.find((v) => v.mixed)
    const http = runtimeProfile.inbounds.find((v) => v.http)
    const socks = runtimeProfile.inbounds.find((v) => v.socks)
    const tun = runtimeProfile.inbounds.find((v) => v.tun)
    config.value['mixed-port'] = mixed?.mixed?.listen.listen_port || 0
    config.value['port'] = http?.http?.listen.listen_port || 0
    config.value['socks-port'] = socks?.socks?.listen.listen_port || 0
    config.value['allow-lan'] = [
      mixed?.mixed?.listen.listen,
      http?.http?.listen.listen,
      socks?.socks?.listen.listen,
    ].some((address) => address === '0.0.0.0' || address === '::')

    config.value.tun.enable = !!tun?.enable
    config.value.tun.device = tun?.tun?.interface_name || ''
    config.value.tun.stack = tun?.tun?.stack || ''
    config.value['interface-name'] = runtimeProfile.route.default_interface
  }

  const updateConfig = async (field: string, value: any) => {
    if (field === 'mode') {
      await setConfigs({ mode: value })
      await refreshConfig()
      return
    }

    const patchInboundPort = (type: 'mixed' | 'socks' | 'http', port: number) => {
      if (!runtimeProfile) return
      let inbound = runtimeProfile.inbounds.find((v) => v.type === type)
      if (inbound) {
        inbound[type]!.listen.listen_port = port
      } else {
        const _type = DefaultInboundMixed()!
        _type.listen.listen_port = port
        inbound = {
          id: type + '-in',
          tag: type + '-in',
          type: type,
          enable: true,
          [type]: _type,
        }
        runtimeProfile.inbounds.push(inbound)
      }
      inbound.enable = port !== 0
    }

    const patchInboundAddress = (allowLan: boolean) => {
      if (!runtimeProfile) return
      runtimeProfile.inbounds.forEach((inbound) => {
        if (inbound.type === Inbound.Tun) return
        inbound[inbound.type]!.listen.listen = allowLan ? '0.0.0.0' : '127.0.0.1'
      })
    }

    const patchInboundTun = (options: {
      enable: boolean
      stack: string
      device: string
      interface_name: string
    }) => {
      if (!runtimeProfile) return
      const inbound = runtimeProfile.inbounds.find((v) => v.type === Inbound.Tun)
      if (!inbound) throw 'home.overview.needTun'
      options = { ...config.value.tun, ...options }
      inbound.enable = options.enable
      inbound.tun!.stack = options.stack || TunStack.Mixed
      inbound.tun!.interface_name = options.device || ''
      if (options.interface_name) {
        runtimeProfile.route.default_interface = options.interface_name
      }
      runtimeProfile.route.auto_detect_interface = !options.interface_name
    }

    const fieldHandlerMap: Recordable<() => void> = {
      http: () => patchInboundPort(Inbound.Http, value),
      socks: () => patchInboundPort(Inbound.Socks, value),
      mixed: () => patchInboundPort(Inbound.Mixed, value),
      'allow-lan': () => patchInboundAddress(value),
      tun: () => patchInboundTun(value),
      'tun-stack': () => patchInboundTun(value),
      'tun-device': () => patchInboundTun(value),
      'interface-name': () => patchInboundTun(value),
    }

    fieldHandlerMap[field]?.()

    await restartCore()
    await envStore.updateSystemProxyStatus()
  }

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
  let isCoreStartedByThisInstance = false
  let { promise: coreStoppedPromise, resolve: coreStoppedResolver } = Promise.withResolvers()
  let startCoreTask: Promise<void> | null = null
  let restartCoreTask: Promise<void> | null = null

  const updateCoreState = async () => {
    corePid.value = Number(await ReadFile(CorePidFilePath).catch(() => -1))
    const processName = corePid.value === -1 ? '' : await ProcessInfo(corePid.value).catch(() => '')
    running.value = processName.startsWith('sing-box')

    coreStateLoading.value = false

    if (running.value) {
      coreWebsockets.init()
      coreWebsockets.connectLongLived()
      await Promise.all([refreshConfig(), refreshProviderProxies()])
    } else if (appSettingsStore.app.autoStartKernel) {
      await envStore.restoreSystemProxyAfterUnexpectedExit().catch(() => undefined)
      await startCore()
    } else {
      await envStore.restoreSystemProxyAfterUnexpectedExit().catch(() => undefined)
    }

    await envStore.updateSystemProxyStatus().catch(() => undefined)
  }

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
          onCoreStopped()
          reject(output)
        },
        { StopOutputKeyword: CoreStopOutputKeyword, Env: getKernelRuntimeEnv(isAlpha) },
      ).catch((e) => reject(e))
    })
  }

  const onCoreStarted = async (pid: number) => {
    await WriteFile(CorePidFilePath, String(pid))

    corePid.value = pid
    running.value = true
    isCoreStartedByThisInstance = true
    coreStoppedPromise = new Promise((r) => (coreStoppedResolver = r))

    await Promise.all([refreshConfig(), refreshProviderProxies()])

    if (appSettingsStore.app.autoSetSystemProxy) {
      try {
        const applied = await envStore.setSystemProxyIfSafe()
        if (!applied) {
          message.warn('settings.systemProxy.autoSkippedExisting')
        }
      } catch (err) {
        message.error(err as string)
      }
    }
    await pluginsStore.onCoreStartedTrigger()

    coreWebsockets.init()
    coreWebsockets.connectLongLived()
  }

  const onCoreStopped = async () => {
    await RemoveFile(CorePidFilePath)

    corePid.value = -1
    running.value = false

    if (appSettingsStore.app.autoSetSystemProxy) {
      await envStore.restorePreviousSystemProxy(true).catch(() => undefined)
    }
    await pluginsStore.onCoreStoppedTrigger()

    coreStoppedResolver(null)

    coreWebsockets.destroy()
  }

  const ensureCoreExecutable = async (isAlpha: boolean, corePath: string) => {
    const exists = await FileExists(corePath).catch(() => false)
    if (exists) return true

    const fallbackPath = `${CoreWorkingDirectory}/${getKernelFileName(!isAlpha)}`
    const fallbackExists = await FileExists(fallbackPath).catch(() => false)
    if (fallbackExists) {
      logsStore.recordKernelLog(
        `[KernelApi] Missing core "${corePath}", trying fallback "${fallbackPath}"`,
      )
      await CopyFile(fallbackPath, corePath)
      if (!corePath.endsWith('.exe')) {
        await Exec('chmod', ['+x', await AbsolutePath(corePath)]).catch(() => undefined)
      }

      const restored = await FileExists(corePath).catch(() => false)
      if (restored) {
        logsStore.recordKernelLog(`[KernelApi] Restored core executable from fallback`)
        return true
      }
    }

    logsStore.recordKernelLog(`[KernelApi] Missing core "${corePath}", auto downloading...`)

    const releaseUrl = isAlpha ? AlphaReleaseURL : StableReleaseURL
    const { body } = await HttpGet<Record<string, any>>(releaseUrl, {
      Authorization: getGitHubApiAuthorization(),
    })
    if (body.message) throw body.message

    const release = isAlpha ? body.find((v: any) => v?.prerelease === true) : body
    if (!release) throw 'Release not found'

    const version = String(release.name || release.tag_name || '').replace(/^v/, '')
    if (!version) throw 'Release version not found'

    const assetName = getKernelAssetFileName(version)
    const asset = release.assets?.find((v: any) => v?.name === assetName)
    if (!asset) throw 'Asset Not Found:' + assetName

    const cacheDir = 'data/.cache'
    const cacheFile = `${cacheDir}/${assetName}`
    const cancelId = `kernel-auto-download-${Date.now()}`
    const toast = message.info('common.downloading', 10 * 60 * 1_000, () => {
      HttpCancel(cancelId)
    })

    try {
      await MakeDir(CoreWorkingDirectory).catch(() => undefined)
      await MakeDir(cacheDir).catch(() => undefined)
      await Download(asset.browser_download_url, cacheFile, undefined, undefined, {
        CancelId: cancelId,
      })
    } finally {
      toast.destroy()
    }

    const extractedCoreFileName = getKernelFileName()
    await RemoveFile(corePath).catch(() => undefined)

    if (assetName.endsWith('.zip')) {
      await UnzipZIPFile(cacheFile, cacheDir)
      const extractedDir = `${cacheDir}/${assetName.replace('.zip', '')}`
      await MoveFile(`${extractedDir}/${extractedCoreFileName}`, corePath)
      await RemoveFile(extractedDir).catch(() => undefined)
    } else if (assetName.endsWith('.tar.gz')) {
      await UnzipTarGZFile(cacheFile, cacheDir)
      const extractedDir = `${cacheDir}/${assetName.replace('.tar.gz', '')}`
      await MoveFile(`${extractedDir}/${extractedCoreFileName}`, corePath)
      await RemoveFile(extractedDir).catch(() => undefined)
    } else {
      throw `Unsupported asset format: ${assetName}`
    }

    await RemoveFile(cacheFile).catch(() => undefined)

    if (!corePath.endsWith('.exe')) {
      await Exec('chmod', ['+x', await AbsolutePath(corePath)]).catch(() => undefined)
    }

    return await FileExists(corePath).catch(() => false)
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
      const coreReady = await ensureCoreExecutable(isAlpha, corePath).catch((error) => {
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
      let lastError: any = null
      const profileToUse = deepClone(profile)
      let portsAdjusted = false
      let missingCloudSubscriptionsPruned = false

      const reassignProfilePorts = async (target: IProfile) => {
      const usedPorts = new Set<number>()
      const collectPort = (value?: number) => {
        if (typeof value === 'number' && value > 0) {
          usedPorts.add(value)
        }
      }

      target.inbounds.forEach((inbound) => {
        const block = inbound[inbound.type as keyof typeof inbound]
        const listen = (block as any)?.listen
        collectPort((listen?.listen_port as number | undefined) ?? undefined)
      })

      target.experimental = target.experimental || DefaultExperimental()

      const ensureInbound = (
        type: Inbound,
        factory: () => IInbound['mixed'] | IInbound['http'] | IInbound['socks'],
      ) => {
        let inbound = target.inbounds.find((item) => item.type === type)
        if (!inbound) {
          inbound = {
            id: `${type}-auto`,
            type,
            tag: `${type}-in`,
            enable: true,
            [type]: factory(),
          } as IInbound
          target.inbounds.push(inbound)
        }
        return inbound
      }

      const allocatePort = async () => {
        for (let attempt = 0; attempt < 10; attempt++) {
          const port = await GetAvailablePort()
          if (!usedPorts.has(port)) {
            usedPorts.add(port)
            return port
          }
        }
        const fallback = await GetAvailablePort()
        usedPorts.add(fallback)
        return fallback
      }

      const changes: Record<string, number> = {}

      const updateInboundPort = async (type: Inbound) => {
        const inbound = ensureInbound(type, () => {
          switch (type) {
            case Inbound.Http:
              return DefaultInboundHttp()
            case Inbound.Socks:
              return DefaultInboundSocks()
            default:
              return DefaultInboundMixed()
          }
        })
        const block: any = inbound[type]
        if (!block) return
        block.listen = block.listen || { listen: '127.0.0.1', listen_port: 0 }
        block.listen.listen = block.listen.listen || '127.0.0.1'

        // Prefer the existing configured port if it's not conflicting with other inbounds
        const currentPort = block.listen.listen_port
        if (currentPort > 0 && !usedPorts.has(currentPort)) {
          usedPorts.add(currentPort)
          inbound.enable = true
          return
        }

        // Only allocate a random port if the configured port conflicts
        const newPort = await allocatePort()
        block.listen.listen_port = newPort
        inbound.enable = true
        changes[type] = newPort
      }

      await updateInboundPort(Inbound.Mixed)
      await updateInboundPort(Inbound.Http)
      await updateInboundPort(Inbound.Socks)

      const controller = target.experimental?.clash_api?.external_controller
      if (controller) {
        let host = '127.0.0.1'
        let rawPort = ''

        if (controller.includes('://')) {
          try {
            const parsed = new URL(controller)
            host = parsed.hostname ? parsed.hostname : host
            rawPort = parsed.port || ''
          } catch {
            // ignore parsing failure
          }
        } else if (controller.startsWith('[')) {
          const closing = controller.indexOf(']')
          if (closing !== -1) {
            host = controller.slice(0, closing + 1)
            rawPort = controller.slice(closing + 1)
          }
        } else {
          const idx = controller.lastIndexOf(':')
          if (idx !== -1) {
            host = controller.slice(0, idx)
            rawPort = controller.slice(idx + 1)
          } else {
            host = controller
          }
        }

        const existingPort = Number(rawPort)
        if (existingPort > 0 && !usedPorts.has(existingPort)) {
          // Keep the existing controller port
          usedPorts.add(existingPort)
        } else {
          // Only reassign if conflicting
          collectPort(existingPort)
          const newPort = await allocatePort()
          const trimmedHost = host?.trim()?.length ? host.trim() : '127.0.0.1'
          target.experimental.clash_api.external_controller = `${trimmedHost}:${newPort}`
          changes.controller = newPort
        }
      }

      return { changed: Object.keys(changes).length > 0, ports: changes }
    }

      const pruneMissingCloudSubscriptions = async (target: IProfile) => {
      const cloudSubscriptionIDs = new Set<string>()
      const addCloudID = (id?: string) => {
        if (typeof id === 'string' && id.startsWith('cloud-')) {
          cloudSubscriptionIDs.add(id)
        }
      }

      target.outbounds?.forEach((outbound: any) => {
        addCloudID(outbound?.id)
        if (Array.isArray(outbound?.outbounds)) {
          outbound.outbounds.forEach((item: any) => addCloudID(item?.id))
        }
      })

      if (!cloudSubscriptionIDs.size) {
        return { changed: false, removed: [] as string[] }
      }

      const removed: string[] = []
      for (const id of cloudSubscriptionIDs) {
        const exists = await FileExists(`data/subscribes/${id}.json`).catch(() => false)
        if (!exists) {
          removed.push(id)
        }
      }

      if (!removed.length) {
        return { changed: false, removed }
      }

      const removedSet = new Set(removed)
      let changed = false

      const nextOutbounds = (target.outbounds || []).filter((outbound: any) => {
        if (typeof outbound?.id === 'string' && removedSet.has(outbound.id)) {
          changed = true
          return false
        }
        return true
      })

      nextOutbounds.forEach((outbound: any) => {
        if (!Array.isArray(outbound?.outbounds)) return
        const before = outbound.outbounds.length
        outbound.outbounds = outbound.outbounds.filter(
          (item: any) => !(typeof item?.id === 'string' && removedSet.has(item.id)),
        )
        if (before !== outbound.outbounds.length) {
          changed = true
        }
      })

      if (changed) {
        target.outbounds = nextOutbounds
      }

      return { changed, removed }
    }

      try {
        const maxAttempts = 5  // 增加到5次
        const backoffDelays = [0, 500, 1000, 2000, 3000]  // 退避延迟（毫秒）

        for (let attempt = 1; attempt <= maxAttempts; attempt++) {
          // 如果不是第一次尝试，等待一段时间
          if (attempt > 1 && backoffDelays[attempt - 1] > 0) {
            logsStore.recordKernelLog(
              `[KernelApi] Waiting ${backoffDelays[attempt - 1]}ms before retry ${attempt}/${maxAttempts}`,
            )
            await new Promise(resolve => setTimeout(resolve, backoffDelays[attempt - 1]))
          }

          try {
            await generateConfigFile(profileToUse, async (config) => {
              const result = await pluginsStore.onBeforeCoreStartTrigger(config, profileToUse)
              // Allow registered hooks to modify config (e.g., load balance injection)
              for (const hook of _configWriteHooks) {
                await hook(result || config)
              }
              return result
            })

            const pid = await runCoreProcess(isAlpha)
            if (pid) {
              await onCoreStarted(pid)
            }
            lastError = null
            logsStore.recordKernelLog(`[KernelApi] Core started successfully on attempt ${attempt}`)
            break
          } catch (error) {
            lastError = error
            const messageText = String(error ?? '').toLowerCase()
            logsStore.recordKernelLog(
              `[KernelApi] startCore attempt ${attempt}/${maxAttempts} failed: ${String(error ?? '')}`,
            )

            const cacheError =
              messageText.includes('initialize cache-file') || messageText.includes('cache-file')
            if (cacheError && attempt < maxAttempts) {
              await RemoveFile(CoreCacheFilePath).catch(() => undefined)
              message.warn('kernel.errors.cacheResetting')
              logsStore.recordKernelLog('[KernelApi] Cache file removed, retrying...')
              continue
            }

            const portConflict =
              messageText.includes('address already in use') ||
              messageText.includes('bind: address already in use')
            if (portConflict && attempt < maxAttempts) {
              logsStore.recordKernelLog('[KernelApi] Port conflict detected, reassigning ports...')
              const result = await reassignProfilePorts(profileToUse)
              if (result.changed) {
                portsAdjusted = true
                const ports = result.ports
                if (ports[Inbound.Mixed]) {
                  config.value['mixed-port'] = ports[Inbound.Mixed]
                }
                if (ports[Inbound.Http]) {
                  config.value['port'] = ports[Inbound.Http]
                }
                if (ports[Inbound.Socks]) {
                  config.value['socks-port'] = ports[Inbound.Socks]
                }
                logsStore.recordKernelLog(`[KernelApi] Ports reassigned: ${JSON.stringify(ports)}`)
                message.warn('kernel.errors.portResetting')
                continue
              } else {
                logsStore.recordKernelLog('[KernelApi] Port reassignment returned no changes')
              }
            }

            const missingCloudSubscriptionFile =
              messageText.includes('no such file or directory') &&
              messageText.includes('data/subscribes/cloud-')

            if (missingCloudSubscriptionFile && attempt < maxAttempts) {
              const result = await pruneMissingCloudSubscriptions(profileToUse)
              if (result.changed) {
                missingCloudSubscriptionsPruned = true
                logsStore.recordKernelLog(
                  `[KernelApi] Removed missing cloud subscriptions: ${result.removed.join(', ')}`,
                )
                continue
              }
            }

            // 如果是最后一次尝试，或者不是可重试的错误，抛出异常
            if (attempt === maxAttempts) {
              logsStore.recordKernelLog(`[KernelApi] All ${maxAttempts} attempts failed, giving up`)
            }
            throw error
          }
        }
      } finally {
        starting.value = false
      }

      if (lastError) {
        throw lastError
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

  const stopCore = async () => {
    if (!running.value) throw 'The core is not running'

    stopping.value = true
    try {
      await pluginsStore.onBeforeCoreStopTrigger()
      await KillProcess(corePid.value)
      await (isCoreStartedByThisInstance ? coreStoppedPromise : onCoreStopped())
    } finally {
      stopping.value = false
    }
  }

  const restartCore = async (cleanupTask?: () => Promise<any>, keepRuntimeProfile = true) => {
    if (restartCoreTask) {
      logsStore.recordKernelLog('[KernelApi] restartCore joined existing restart attempt')
      return restartCoreTask
    }

    const restartTask = (async () => {
      restarting.value = true
      try {
        if (running.value) {
          await stopCore()
        }
        await cleanupTask?.()
        await startCore(keepRuntimeProfile ? runtimeProfile : undefined)
      } finally {
        restarting.value = false
      }
    })()

    restartCoreTask = restartTask
    try {
      await restartTask
    } finally {
      if (restartCoreTask === restartTask) {
        restartCoreTask = null
      }
    }
  }

  const getProxyPort = ():
    | {
        port: number
        proxyType: ProxyType
      }
    | undefined => {
    const { port, 'socks-port': socksPort, 'mixed-port': mixedPort } = config.value

    if (mixedPort) {
      return {
        port: mixedPort,
        proxyType: 'mixed',
      }
    }
    if (port) {
      return {
        port,
        proxyType: 'http',
      }
    }
    if (socksPort) {
      return {
        port: socksPort,
        proxyType: 'socks',
      }
    }
    return undefined
  }

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
