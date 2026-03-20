import * as App from '@wails/go/bridge/App'

import type { TrayContent } from '@/types/app'

export const RestartApp = App.RestartApp

export const ExitApp = App.ExitApp

export const ShowMainWindow = App.ShowMainWindow

export const UpdateTray = async (tray: TrayContent) => {
  const { icon = '', title = '', tooltip = '' } = tray
  await App.UpdateTray({ icon, title, tooltip })
}

export const UpdateTrayMenus = App.UpdateTrayMenus

export const GetEnv = App.GetEnv

export const IsStartup = App.IsStartup

export const GetInterfaces = async () => {
  const { flag, data } = await App.GetInterfaces()
  if (!flag) {
    throw data
  }
  return data.split('|')
}

export const GetCloudConfig = App.GetCloudConfig

export const SaveCloudConfig = App.SaveCloudConfig

export const ListCloudProviders = App.ListCloudProviders

export const GetCloudProvider = App.GetCloudProvider

export const SetCloudProvider = App.SetCloudProvider

export const ListCloudInstances = App.ListCloudInstances

export const CreateCloudInstance = App.CreateCloudInstance

export const DestroyCloudInstance = App.DestroyCloudInstance

export const ListCloudRegions = App.ListCloudRegions

export const ListCloudPlans = App.ListCloudPlans

export const ListCloudAvailability = App.ListCloudAvailability

export const TestAllCloudRegions = App.TestAllCloudRegions

export const TestCloudRegionLatency = App.TestCloudRegionLatency

export const GetFastestCloudRegion = App.GetFastestCloudRegion

export const GetAvailablePort = App.GetAvailablePort

export const StartLoadBalancer = App.StartLoadBalancer

export const StopLoadBalancer = App.StopLoadBalancer

export const GetLoadBalancerStatus = App.GetLoadBalancerStatus

export const CleanInvalidCloudNodes = App.CleanInvalidCloudNodes

export const TestSSHConnection = App.TestSSHConnection

export const CreateMultipleCloudInstances = App.CreateMultipleCloudInstances

export const ScoreCloudRegions = App.ScoreCloudRegions

export const StartHealthMonitor = App.StartHealthMonitor

export const StopHealthMonitor = App.StopHealthMonitor

export const GetHealthStatus = App.GetHealthStatus

export const TestNodeSpeed = async (
  ip: string,
  probe: number[] | import('@/types/cloud').ConnectivityProbeRequest
): Promise<{ latencyMs: number; port: number; status: string }> => {
  const portsJSON = JSON.stringify(probe)
  const { flag, data } = await App.TestNodeSpeed(ip, portsJSON)
  const result = JSON.parse(data)
  if (!flag && result.status === 'timeout') {
    return result
  }
  if (!flag) {
    throw new Error(data)
  }
  return result
}

export const TestNodeDirectSpeed = async (
  outbounds: Array<Record<string, any>>,
  timeoutSec?: number,
): Promise<{ speedMbps: number; bytes: number; elapsedMs: number; status: string }> => {
  const outboundsJSON = JSON.stringify(outbounds)
  const { flag, data } = await App.TestNodeDirectSpeed(outboundsJSON, timeoutSec || 15)
  const result = JSON.parse(data)
  if (!flag && result.status === 'error') {
    return result
  }
  if (!flag) {
    throw new Error(data)
  }
  return result
}

export const TestDownloadSpeed = async (
  proxyURL: string,
  testURL?: string,
  timeoutSec?: number,
): Promise<{ speedMbps: number; bytes: number; elapsedMs: number; status: string }> => {
  const { flag, data } = await App.TestDownloadSpeed(proxyURL, testURL || '', timeoutSec || 15)
  const result = JSON.parse(data)
  if (!flag && result.status === 'error') {
    return result
  }
  if (!flag) {
    throw new Error(data)
  }
  return result
}

export const TestConnectivity = async (
  ip: string,
  probe: number[] | import('@/types/cloud').ConnectivityProbeRequest
): Promise<import('@/types/cloud').ConnectivityResult> => {
  const portsJSON = JSON.stringify(probe)
  const { flag, data } = await App.TestConnectivity(ip, portsJSON)
  if (!flag) {
    throw new Error(data)
  }
  return JSON.parse(data)
}
