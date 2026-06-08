import { ref } from 'vue'

import {
  GetAvailablePort,
  StartLoadBalancer,
  StopLoadBalancer,
} from '@/bridge'
import { logError, logInfo } from '@/utils/logger'

import { unregisterConfigWriteHook, registerConfigWriteHook } from '../kernelApi'
import { injectLoadBalanceConfig } from './smartRouting'

type CreateCloudLoadBalanceDeps = {
  kernelApi: {
    running: boolean
    restartCore: () => Promise<void>
    startCore: () => Promise<void>
  }
}

export const createCloudLoadBalance = ({
  kernelApi,
}: CreateCloudLoadBalanceDeps) => {
  const loadBalanceEnabled = ref(false)
  const loadBalancePorts = ref<number[]>([])
  const loadBalanceListenPort = ref(0)

  const lbConfigHook = async (config: Record<string, any>) => {
    if (!loadBalanceEnabled.value) return

    const basePort = await GetAvailablePort()
    logInfo(
      `[CloudStore] LB hook: config has ${(config?.outbounds || []).length} outbounds, ${(config?.inbounds || []).length} inbounds`,
    )

    const ports = injectLoadBalanceConfig(config, basePort)
    loadBalancePorts.value = ports

    logInfo(`[CloudStore] LB hook: injected ${ports.length} ports (base ${basePort})`)
    if (ports.length >= 2) {
      logInfo(`[CloudStore] LB: injected ${ports.length} per-node inbounds (base port ${basePort})`)
    }
  }

  const startLoadBalance = async () => {
    loadBalanceEnabled.value = true
    registerConfigWriteHook(lbConfigHook)

    if (kernelApi.running) {
      await kernelApi.restartCore()
    } else {
      await kernelApi.startCore()
    }

    await new Promise((resolve) => setTimeout(resolve, 3_000))

    if (loadBalancePorts.value.length < 2) {
      logError('[CloudStore] LB: not enough nodes for load balancing')
      loadBalanceEnabled.value = false
      unregisterConfigWriteHook(lbConfigHook)
      return
    }

    const lbPort = await GetAvailablePort()
    const portsJSON = JSON.stringify(loadBalancePorts.value)
    const { flag, data } = await StartLoadBalancer(lbPort, portsJSON)
    if (!flag) {
      logError('[CloudStore] LB start failed:', data)
      loadBalanceEnabled.value = false
      unregisterConfigWriteHook(lbConfigHook)
      return
    }

    loadBalanceListenPort.value = lbPort
    logInfo(
      `[CloudStore] Load balancer started on port ${lbPort} with ${loadBalancePorts.value.length} upstreams`,
    )
  }

  const stopLoadBalance = async () => {
    loadBalanceEnabled.value = false
    unregisterConfigWriteHook(lbConfigHook)
    await StopLoadBalancer()
    loadBalanceListenPort.value = 0
    loadBalancePorts.value = []
    logInfo('[CloudStore] Load balancer stopped')
  }

  return {
    loadBalanceEnabled,
    loadBalanceListenPort,
    startLoadBalance,
    stopLoadBalance,
  }
}
