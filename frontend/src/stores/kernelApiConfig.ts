import { getConfigs, setConfigs } from '@/api/kernel'
import { ReadFile } from '@/bridge'
import { CoreConfigFilePath } from '@/constant/kernel'
import { DefaultInboundMixed } from '@/constant/profile'
import { Inbound, TunStack } from '@/enums/kernel'
import { deepClone, restoreProfile } from '@/utils'

import type { CoreApiConfig } from '@/types/kernel'
import type { Ref } from 'vue'

export type ProxyType = 'mixed' | 'http' | 'socks'

type CreateKernelApiConfigManagerDeps = {
  config: Ref<CoreApiConfig>
  getRuntimeProfile: () => IProfile | undefined
  setRuntimeProfile: (profile: IProfile | undefined) => void
  getSelectedProfile: () => IProfile | undefined
  restartCore: () => Promise<void>
  updateSystemProxyStatus: () => Promise<unknown>
}

export const createKernelApiConfigManager = ({
  config,
  getRuntimeProfile,
  setRuntimeProfile,
  getSelectedProfile,
  restartCore,
  updateSystemProxyStatus,
}: CreateKernelApiConfigManagerDeps) => {
  const refreshConfig = async () => {
    const nextConfig = await getConfigs()

    config.value = {
      ...nextConfig,
      tun: config.value.tun,
    }

    let runtimeProfile = getRuntimeProfile()
    if (!runtimeProfile) {
      const txt = await ReadFile(CoreConfigFilePath)
      runtimeProfile = restoreProfile(JSON.parse(txt))

      const profile = getSelectedProfile()
      if (profile) {
        const selectedProfile = deepClone(profile)
        runtimeProfile.inbounds.forEach((inbound) => {
          const matched = selectedProfile.inbounds.find((item) => item.tag === inbound.tag)
          if (matched) {
            inbound.id = matched.id
          }
        })

        const tunInbound = selectedProfile.inbounds.find((item) => item.type === Inbound.Tun)
        if (tunInbound && !runtimeProfile.inbounds.find((item) => item.type === Inbound.Tun)) {
          tunInbound.enable = false
          runtimeProfile.inbounds.push(tunInbound)
        }

        runtimeProfile.id = selectedProfile.id
        runtimeProfile.outbounds = selectedProfile.outbounds
        runtimeProfile.experimental = selectedProfile.experimental
        runtimeProfile.dns = selectedProfile.dns
        runtimeProfile.route = selectedProfile.route
        runtimeProfile.mixin = selectedProfile.mixin
        runtimeProfile.script = selectedProfile.script
      }

      setRuntimeProfile(runtimeProfile)
    }

    const mixed = runtimeProfile.inbounds.find((item) => item.mixed)
    const http = runtimeProfile.inbounds.find((item) => item.http)
    const socks = runtimeProfile.inbounds.find((item) => item.socks)
    const tun = runtimeProfile.inbounds.find((item) => item.tun)

    config.value['mixed-port'] = mixed?.mixed?.listen.listen_port || 0
    config.value.port = http?.http?.listen.listen_port || 0
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

    const runtimeProfile = getRuntimeProfile()

    const patchInboundPort = (type: 'mixed' | 'socks' | 'http', port: number) => {
      if (!runtimeProfile) return
      let inbound = runtimeProfile.inbounds.find((item) => item.type === type)
      if (inbound) {
        inbound[type]!.listen.listen_port = port
      } else {
        const mixedInbound = DefaultInboundMixed()!
        mixedInbound.listen.listen_port = port
        inbound = {
          id: `${type}-in`,
          tag: `${type}-in`,
          type,
          enable: true,
          [type]: mixedInbound,
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

      const inbound = runtimeProfile.inbounds.find((item) => item.type === Inbound.Tun)
      if (!inbound) throw 'home.overview.needTun'

      const merged = { ...config.value.tun, ...options }
      inbound.enable = merged.enable
      inbound.tun!.stack = merged.stack || TunStack.Mixed
      inbound.tun!.interface_name = merged.device || ''
      if (merged.interface_name) {
        runtimeProfile.route.default_interface = merged.interface_name
      }
      runtimeProfile.route.auto_detect_interface = !merged.interface_name
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
    await updateSystemProxyStatus()
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

  return {
    getProxyPort,
    refreshConfig,
    updateConfig,
  }
}
