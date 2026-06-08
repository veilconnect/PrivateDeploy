import { beforeEach, describe, expect, it, vi } from 'vitest'

import { Branch } from '@/enums/app'

const mocks = vi.hoisted(() => ({
  absolutePath: vi.fn(),
  confirm: vi.fn(),
  deleteConnection: vi.fn(),
  exec: vi.fn(),
  exitApp: vi.fn(),
  getConnections: vi.fn(),
  ignoredError: vi.fn(),
  messageInfo: vi.fn(),
  messageSuccess: vi.fn(),
  readFile: vi.fn(),
  useProxy: vi.fn(),
  writeFile: vi.fn(),
  appSettingsStore: {
    app: {
      autoSetSystemProxy: true,
      closeKernelOnExit: true,
      kernel: {
        autoClose: true,
        branch: 'main',
        main: {
          args: ['$CORE_BASE_PATH/config.json', '$APP_BASE_PATH/profile'],
          env: {
            ENABLE_DEPRECATED_LEGACY_DNS_SERVERS: 'false',
            NUMBER_VALUE: 1,
            PATH: '$APP_BASE_PATH/bin',
          },
        },
        alpha: {
          args: ['$CORE_BASE_PATH/alpha.json'],
          env: {
            ALPHA_PATH: '$CORE_BASE_PATH/alpha',
          },
        },
      },
    },
  },
  appStore: {
    isAppExiting: false,
  },
  envStore: {
    env: {
      appName: 'PrivateDeploy.exe',
      arch: 'amd64',
      basePath: 'C:\\PrivateDeploy',
      os: 'windows',
    },
    restorePreviousSystemProxy: vi.fn(),
  },
  kernelApiStore: {
    config: {
      mode: 'rule',
    },
    getProxyPort: vi.fn(),
    refreshProviderProxies: vi.fn(),
    running: false,
    stopCore: vi.fn(),
    updateConfig: vi.fn(),
  },
  pluginsStore: {
    onShutdownTrigger: vi.fn(),
  },
}))

vi.mock('@/api/kernel', () => ({
  deleteConnection: mocks.deleteConnection,
  getConnections: mocks.getConnections,
  useProxy: mocks.useProxy,
}))

vi.mock('@/bridge', () => ({
  AbsolutePath: mocks.absolutePath,
  Exec: mocks.exec,
  ExitApp: mocks.exitApp,
  ReadFile: mocks.readFile,
  WriteFile: mocks.writeFile,
}))

vi.mock('@/lang', () => ({
  default: {
    global: {
      t: (key: string, values?: Record<string, string>) => {
        return values?.reason ? `${key}:${values.reason}` : key
      },
    },
  },
}))

vi.mock('@/stores', () => ({
  useAppSettingsStore: () => mocks.appSettingsStore,
  useAppStore: () => mocks.appStore,
  useEnvStore: () => mocks.envStore,
  useKernelApiStore: () => mocks.kernelApiStore,
  usePluginsStore: () => mocks.pluginsStore,
}))

vi.mock('@/utils', () => ({
  confirm: mocks.confirm,
  ignoredError: (...args: unknown[]) => mocks.ignoredError(...args),
  message: {
    info: mocks.messageInfo,
    success: mocks.messageSuccess,
  },
}))

import {
  CheckPermissions,
  CreateSchTask,
  DeleteSchTask,
  GetSystemOrKernelProxy,
  GetSystemProxy,
  GrantTUNPermission,
  QuerySchTask,
  SetSystemProxy,
  SwitchPermissions,
  addToRuleSet,
  getKernelAssetFileName,
  getKernelFileName,
  getKernelRuntimeArgs,
  getKernelRuntimeEnv,
  handleChangeMode,
  handleUseProxy,
} from '../helper'

describe('helper utilities', () => {
  beforeEach(() => {
    vi.clearAllMocks()

    mocks.appSettingsStore.app.closeKernelOnExit = true
    mocks.appSettingsStore.app.autoSetSystemProxy = true
    mocks.appSettingsStore.app.kernel.autoClose = true
    mocks.appSettingsStore.app.kernel.branch = Branch.Main
    mocks.appSettingsStore.app.kernel.main = {
      args: ['$CORE_BASE_PATH/config.json', '$APP_BASE_PATH/profile'],
      env: {
        ENABLE_DEPRECATED_LEGACY_DNS_SERVERS: 'false',
        NUMBER_VALUE: 1,
        PATH: '$APP_BASE_PATH/bin',
      },
    }
    mocks.appSettingsStore.app.kernel.alpha = {
      args: ['$CORE_BASE_PATH/alpha.json'],
      env: {
        ALPHA_PATH: '$CORE_BASE_PATH/alpha',
      },
    }
    mocks.appStore.isAppExiting = false
    mocks.envStore.env = {
      appName: 'PrivateDeploy.exe',
      arch: 'amd64',
      basePath: 'C:\\PrivateDeploy',
      os: 'windows',
    }
    mocks.kernelApiStore.config.mode = 'rule'
    mocks.kernelApiStore.getProxyPort.mockReturnValue(undefined)
    mocks.kernelApiStore.refreshProviderProxies.mockResolvedValue(undefined)
    mocks.kernelApiStore.running = false
    mocks.kernelApiStore.stopCore.mockResolvedValue(undefined)
    mocks.kernelApiStore.updateConfig.mockReturnValue(undefined)
    mocks.pluginsStore.onShutdownTrigger.mockResolvedValue(undefined)

    mocks.absolutePath.mockImplementation(async (path: string) => `/abs/${path}`)
    mocks.confirm.mockResolvedValue(undefined)
    mocks.deleteConnection.mockResolvedValue(null)
    mocks.exec.mockResolvedValue('')
    mocks.getConnections.mockResolvedValue({ connections: [] })
    mocks.ignoredError.mockImplementation(async (fn: (...args: unknown[]) => Promise<unknown>, ...args) => {
      try {
        return await fn(...args)
      } catch {
        return undefined
      }
    })
    mocks.messageInfo.mockReturnValue({ destroy: vi.fn() })
    mocks.messageSuccess.mockReturnValue(undefined)
    mocks.readFile.mockResolvedValue(undefined)
    mocks.useProxy.mockResolvedValue(undefined)
    mocks.writeFile.mockResolvedValue(undefined)
  })

  it('manages Windows admin flags and Linux TUN permissions', async () => {
    await SwitchPermissions(true)
    await SwitchPermissions(false)

    expect(mocks.exec).toHaveBeenCalledWith(
      'reg',
      expect.arrayContaining(['add', '/d', 'RunAsAdmin']),
      { Convert: true },
    )
    expect(mocks.exec).toHaveBeenCalledWith(
      'reg',
      expect.arrayContaining(['delete', 'C:\\PrivateDeploy\\PrivateDeploy.exe']),
      { Convert: true },
    )

    mocks.exec.mockResolvedValueOnce('Layers    REG_SZ    RunAsAdmin')
    await expect(CheckPermissions()).resolves.toBe(true)

    mocks.exec.mockRejectedValueOnce(new Error('missing registry key'))
    await expect(CheckPermissions()).resolves.toBe(false)

    mocks.envStore.env.os = 'linux'
    await GrantTUNPermission('data/sing-box/sing-box')

    expect(mocks.exec).toHaveBeenCalledWith('pkexec', [
      'setcap',
      'cap_net_bind_service,cap_net_admin,cap_dac_override=+ep',
      '/abs/data/sing-box/sing-box',
    ])
  })

  it('writes system proxy settings for Windows and GNOME desktops', async () => {
    await SetSystemProxy(true, '127.0.0.1:7890', 'socks')

    expect(mocks.exec).toHaveBeenCalledWith(
      'reg',
      expect.arrayContaining(['ProxyEnable', '/d', '1']),
    )
    expect(mocks.exec).toHaveBeenCalledWith(
      'reg',
      expect.arrayContaining(['ProxyServer', '/d', 'socks=127.0.0.1:7890']),
    )

    mocks.exec.mockClear()
    mocks.envStore.env.os = 'linux'
    mocks.exec.mockResolvedValueOnce('GNOME')

    await SetSystemProxy(true, '127.0.0.1:7890', 'http')

    expect(mocks.exec).toHaveBeenCalledWith('sh', ['-c', 'echo $XDG_CURRENT_DESKTOP'])
    expect(mocks.exec).toHaveBeenCalledWith(
      'gsettings',
      ['set', 'org.gnome.system.proxy', 'mode', 'manual'],
    )
    expect(mocks.exec).toHaveBeenCalledWith(
      'gsettings',
      ['set', 'org.gnome.system.proxy.http', 'port', '7890'],
    )
    expect(mocks.exec).toHaveBeenCalledWith(
      'gsettings',
      ['set', 'org.gnome.system.proxy.socks', 'port', '0'],
    )
  })

  it('parses system proxy settings across supported desktops', async () => {
    mocks.exec
      .mockResolvedValueOnce('ProxyEnable    REG_DWORD    0x1')
      .mockResolvedValueOnce('ProxyServer    REG_SZ    127.0.0.1:7890')

    await expect(GetSystemProxy()).resolves.toBe('http://127.0.0.1:7890')

    mocks.envStore.env.os = 'darwin'
    mocks.exec.mockResolvedValueOnce([
      'HTTPEnable : 0',
      'SOCKSEnable : 1',
      'SOCKSProxy : 127.0.0.1',
      'SOCKSPort : 7891',
    ].join('\n'))

    await expect(GetSystemProxy()).resolves.toBe('socks5://127.0.0.1:7891')

    mocks.envStore.env.os = 'linux'
    mocks.exec
      .mockResolvedValueOnce('KDE')
      .mockResolvedValueOnce('1')
      .mockResolvedValueOnce('"http://127.0.0.1 7892"\n')

    await expect(GetSystemProxy()).resolves.toBe('http://127.0.0.1:7892')
  })

  it('prefers running kernel proxy ports and expands kernel runtime settings', async () => {
    mocks.kernelApiStore.running = true
    mocks.kernelApiStore.getProxyPort.mockReturnValue({ port: 7892, proxyType: 'socks' })

    await expect(GetSystemOrKernelProxy()).resolves.toBe('socks5://127.0.0.1:7892')

    mocks.envStore.env.os = 'windows'
    expect(getKernelFileName()).toBe('sing-box.exe')
    expect(getKernelFileName(true)).toBe('sing-box-latest.exe')
    expect(getKernelAssetFileName('v1.2.3')).toBe('sing-box-v1.2.3-windows-amd64.zip')

    mocks.envStore.env = {
      appName: 'PrivateDeploy',
      arch: 'amd64',
      basePath: '/opt/private-deploy',
      os: 'linux',
    }

    expect(getKernelRuntimeEnv()).toEqual({
      ENABLE_DEPRECATED_LEGACY_DNS_SERVERS: 'true',
      ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER: 'true',
      PATH: '/opt/private-deploy/bin',
    })
    expect(getKernelRuntimeArgs()).toEqual([
      'data/sing-box/config.json',
      '/opt/private-deploy/profile',
    ])
    expect(getKernelRuntimeEnv(true)).toEqual({
      ALPHA_PATH: 'data/sing-box/alpha',
      ENABLE_DEPRECATED_LEGACY_DNS_SERVERS: 'true',
      ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER: 'true',
    })
    expect(getKernelRuntimeArgs(true)).toEqual(['data/sing-box/alpha.json'])
  })

  it('updates proxy selections and closes matching connections', async () => {
    mocks.getConnections.mockResolvedValue({
      connections: [
        { chains: ['Auto', 'Main Proxy'], id: 'conn-1' },
        { chains: ['Direct'], id: 'conn-2' },
      ],
    })

    await handleUseProxy(
      { name: 'Main Proxy', now: 'Old Node', type: 'Selector' },
      { name: 'New Node' },
    )

    expect(mocks.useProxy).toHaveBeenCalledWith('Main%20Proxy', 'New Node')
    expect(mocks.deleteConnection).toHaveBeenCalledWith('conn-1')
    expect(mocks.deleteConnection).not.toHaveBeenCalledWith('conn-2')
    expect(mocks.kernelApiStore.refreshProviderProxies).toHaveBeenCalled()

    await handleChangeMode('global')

    expect(mocks.kernelApiStore.updateConfig).toHaveBeenCalledWith('mode', 'global')
    expect(mocks.deleteConnection).toHaveBeenCalledWith('conn-2')
  })

  it('writes scheduler commands and appends unique rule-set payloads', async () => {
    await QuerySchTask('PrivateDeployStart')
    await CreateSchTask('PrivateDeployStart', 'task.xml')
    await DeleteSchTask('PrivateDeployStart')

    expect(mocks.exec).toHaveBeenCalledWith(
      'Schtasks',
      ['/Query', '/TN', 'PrivateDeployStart', '/XML'],
      { Convert: true },
    )
    expect(mocks.exec).toHaveBeenCalledWith(
      'SchTasks',
      ['/Create', '/F', '/TN', 'PrivateDeployStart', '/XML', 'task.xml'],
      { Convert: true },
    )
    expect(mocks.exec).toHaveBeenCalledWith(
      'SchTasks',
      ['/Delete', '/F', '/TN', 'PrivateDeployStart'],
      { Convert: true },
    )

    mocks.readFile.mockResolvedValue(JSON.stringify({
      rules: [
        {
          domain: ['existing.example'],
          ip_cidr: ['10.0.0.0/8'],
        },
      ],
      version: 1,
    }))

    await addToRuleSet('direct', [
      { domain: ['existing.example', 'new.example'] },
      { ip_cidr: ['192.0.2.0/24'] },
      { process_path: ['/usr/bin/private-deploy'] },
      { domain_suffix: ['example.org'] },
    ])

    expect(mocks.writeFile).toHaveBeenCalledWith(
      'data/rulesets/direct.json',
      expect.any(String),
    )
    expect(JSON.parse(mocks.writeFile.mock.calls[0][1])).toEqual({
      rules: [
        {
          domain: ['existing.example', 'new.example'],
          domain_suffix: ['example.org'],
          ip_cidr: ['10.0.0.0/8', '192.0.2.0/24'],
          process_path: ['/usr/bin/private-deploy'],
        },
      ],
      version: 1,
    })
  })
})
