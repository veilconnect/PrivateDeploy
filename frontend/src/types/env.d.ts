export interface PlatformCapabilities {
  traySupported: boolean
  showMainWindowFromTray: boolean
  systemProxySupported: boolean
  startupLaunchSupported: boolean
  startupDelaySupported: boolean
  adminElevationSupported: boolean
  configurableWebviewGpuPolicy: boolean
  kernelGrantPermissionSupported: boolean
}

export interface RuntimeEnv {
  appName: string
  appVersion: string
  basePath: string
  os: string
  arch: string
  capabilities: PlatformCapabilities
}
