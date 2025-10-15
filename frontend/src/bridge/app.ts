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

export const GetVultrConfig = App.GetVultrConfig

export const SaveVultrConfig = App.SaveVultrConfig

export const ListVultrRegions = App.ListVultrRegions

export const ListVultrPlans = App.ListVultrPlans

export const ListVultrInstances = App.ListVultrInstances

export const ListVultrAvailability = App.ListVultrAvailability

export const CreateVultrInstance = App.CreateVultrInstance

export const DestroyVultrInstance = App.DestroyVultrInstance
