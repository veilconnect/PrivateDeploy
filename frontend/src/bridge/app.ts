import * as App from '@wails/go/bridge/App'

import type { TrayContent } from '@/types/app'
import type { CloudConfig, CloudPlan, CloudProvider, CloudRegion, MultiDeployResult, SSHServerInfo } from '@/types/cloud'

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

export const GetCloudConfig = async (): Promise<CloudConfig> => {
  return await App.GetCloudConfigTyped() as CloudConfig
}

export const SaveCloudConfig = async (config: CloudConfig): Promise<void> => {
  await App.SaveCloudConfigTyped(config as any)
}

export const ExportCloudBackup = async (content: string): Promise<string> => {
  return await App.ExportCloudBackup(content)
}

export const ImportCloudBackup = async (): Promise<string> => {
  return await App.ImportCloudBackup()
}

export const ListCloudProviders = async (): Promise<Array<{ name: string; displayName: string }>> => {
  return await App.ListCloudProvidersTyped() as Array<{ name: string; displayName: string }>
}

export const GetCloudProvider = async (): Promise<{ name: string; displayName: string }> => {
  return await App.GetCloudProviderTyped() as { name: string; displayName: string }
}

export const SetCloudProvider = async (provider: CloudProvider): Promise<{ name: string; displayName: string }> => {
  return await App.SetCloudProviderTyped(provider) as { name: string; displayName: string }
}

export const ListCloudInstances = async (): Promise<Array<Record<string, any>>> => {
  return await App.ListCloudInstancesTyped()
}

export const CreateCloudInstance = async (options: Record<string, any>): Promise<Record<string, any>> => {
  return await App.CreateCloudInstanceTyped(options as any)
}

export const DestroyCloudInstance = async (instanceId: string): Promise<void> => {
  await App.DestroyCloudInstanceTyped(instanceId)
}

export const ListCloudRegions = async (): Promise<CloudRegion[]> => {
  return await App.ListCloudRegionsTyped() as CloudRegion[]
}

export const ListCloudPlans = async (): Promise<CloudPlan[]> => {
  return await App.ListCloudPlansTyped() as CloudPlan[]
}

export const ListCloudAvailability = async (region: string): Promise<string[]> => {
  return await App.ListCloudAvailabilityTyped(region)
}

export const TestAllCloudRegions = App.TestAllCloudRegions

export const TestCloudRegionLatency = App.TestCloudRegionLatency

export const GetFastestCloudRegion = App.GetFastestCloudRegion

export const GetAvailablePort = App.GetAvailablePort

export const StartLoadBalancer = App.StartLoadBalancer

export const StopLoadBalancer = App.StopLoadBalancer

export const GetLoadBalancerStatus = App.GetLoadBalancerStatus

export const CleanInvalidCloudNodes = App.CleanInvalidCloudNodes

export const TestSSHConnection = async (config: Record<string, string>): Promise<SSHServerInfo> => {
  return await App.TestSSHConnectionTyped(config) as SSHServerInfo
}

export const CreateMultipleCloudInstances = async (
  configs: Array<Record<string, any>>,
): Promise<MultiDeployResult[]> => {
  return await App.CreateMultipleCloudInstancesTyped(configs as any) as MultiDeployResult[]
}

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
