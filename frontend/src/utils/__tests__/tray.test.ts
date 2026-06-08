import { beforeEach, describe, expect, it, vi } from 'vitest'

import { Color, Theme } from '@/enums/app'
import { ClashMode } from '@/enums/kernel'

const mocks = vi.hoisted(() => ({
  eventsOff: vi.fn(),
  eventsOn: vi.fn(),
  exitApp: vi.fn(),
  handleChangeMode: vi.fn(),
  handleUseProxy: vi.fn(),
  menuClick: undefined as undefined | ((id: string) => void),
  notify: vi.fn(),
  restartApp: vi.fn(),
  showMainWindow: vi.fn(),
  updateTray: vi.fn(),
  updateTrayMenus: vi.fn(),
  appSettingsStore: {
    app: {
      addGroupToMenu: true,
      addPluginToMenu: true,
      color: 'default',
      kernel: {
        sortByDelay: true,
        unAvailable: false,
      },
      lang: 'en',
      theme: 'auto',
    },
    locales: [
      { label: 'English', value: 'en' },
      { label: '中文', value: 'zh' },
    ],
    themeMode: 'dark',
  },
  envStore: {
    capabilities: {
      showMainWindowFromTray: true,
      systemProxySupported: true,
      traySupported: true,
    },
    clearSystemProxy: vi.fn(),
    isDarwin: false,
    isLinux: true,
    setSystemProxy: vi.fn(),
    systemProxy: true,
  },
  kernelApiStore: {
    config: {
      mode: 'rule',
      tun: {
        enable: true,
      },
    },
    proxies: {},
    restartCore: vi.fn(),
    running: true,
    startCore: vi.fn(),
    stopCore: vi.fn(),
    updateConfig: vi.fn(),
  },
  pluginsStore: {
    manualTrigger: vi.fn(),
    plugins: [],
  },
}))

vi.mock('@/bridge', () => ({
  EventsOff: mocks.eventsOff,
  EventsOn: mocks.eventsOn,
  Notify: mocks.notify,
  RestartApp: mocks.restartApp,
  ShowMainWindow: mocks.showMainWindow,
  UpdateTray: mocks.updateTray,
  UpdateTrayMenus: mocks.updateTrayMenus,
}))

vi.mock('@/lang', () => ({
  default: {
    global: {
      t: (key: string) => `tx:${key}`,
    },
  },
}))

vi.mock('@/stores', () => ({
  useAppSettingsStore: () => mocks.appSettingsStore,
  useEnvStore: () => mocks.envStore,
  useKernelApiStore: () => mocks.kernelApiStore,
  usePluginsStore: () => mocks.pluginsStore,
}))

vi.mock('@/utils', () => ({
  APP_TITLE: 'PrivateDeploy',
  APP_VERSION: '2.0.0',
  debounce: (fn: (...args: unknown[]) => unknown) => fn,
  exitApp: mocks.exitApp,
  handleChangeMode: mocks.handleChangeMode,
  handleUseProxy: mocks.handleUseProxy,
}))

import { updateTrayMenus } from '../tray'

interface TestMenu {
  checked?: boolean
  children?: TestMenu[]
  event?: string
  hidden?: boolean
  text?: string
}

const findMenu = (menus: TestMenu[], text: string): TestMenu | undefined => {
  for (const menu of menus) {
    if (menu.text === text) return menu
    const child = menu.children ? findMenu(menu.children, text) : undefined
    if (child) return child
  }
  return undefined
}

const clickMenu = (menu: TestMenu | undefined) => {
  expect(menu?.event).toEqual(expect.any(String))
  mocks.menuClick?.(menu!.event!)
}

const buildProxies = () => ({
  Auto: {
    all: ['Node A', 'Node B', 'Dead Node', 'direct'],
    name: 'Auto',
    now: 'Node B',
    type: 'Selector',
  },
  'Dead Node': {
    history: [{ delay: 0 }],
    name: 'Dead Node',
  },
  GLOBAL: {
    all: ['Node A'],
    name: 'GLOBAL',
    now: 'Node A',
    type: 'Selector',
  },
  'Node A': {
    history: [{ delay: 50 }],
    name: 'Node A',
  },
  'Node B': {
    history: [{ delay: 20 }],
    name: 'Node B',
  },
  direct: {
    history: [],
    name: 'direct',
  },
})

describe('tray utilities', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.menuClick = undefined

    mocks.eventsOn.mockImplementation((_name: string, callback: (id: string) => void) => {
      mocks.menuClick = callback
    })
    mocks.handleChangeMode.mockResolvedValue(undefined)
    mocks.handleUseProxy.mockResolvedValue(undefined)
    mocks.pluginsStore.manualTrigger.mockResolvedValue(undefined)

    mocks.appSettingsStore.app.addGroupToMenu = true
    mocks.appSettingsStore.app.addPluginToMenu = true
    mocks.appSettingsStore.app.color = Color.Default
    mocks.appSettingsStore.app.kernel.sortByDelay = true
    mocks.appSettingsStore.app.kernel.unAvailable = false
    mocks.appSettingsStore.app.lang = 'en'
    mocks.appSettingsStore.app.theme = Theme.Auto
    mocks.appSettingsStore.themeMode = 'dark'

    mocks.envStore.capabilities.showMainWindowFromTray = true
    mocks.envStore.capabilities.systemProxySupported = true
    mocks.envStore.capabilities.traySupported = true
    mocks.envStore.isDarwin = false
    mocks.envStore.isLinux = true
    mocks.envStore.systemProxy = true

    mocks.kernelApiStore.config.mode = ClashMode.Rule
    mocks.kernelApiStore.config.tun.enable = true
    mocks.kernelApiStore.proxies = buildProxies()
    mocks.kernelApiStore.running = true

    mocks.pluginsStore.plugins = [
      {
        disabled: false,
        id: 'plugin-1',
        menus: {
          'Run cleanup': 'cleanup',
        },
        name: 'Maintenance',
      },
      {
        disabled: true,
        id: 'plugin-disabled',
        menus: {
          Hidden: 'hidden',
        },
        name: 'Hidden Plugin',
      },
    ]
  })

  it('skips updates when the environment does not support tray menus', async () => {
    mocks.envStore.capabilities.traySupported = false

    await updateTrayMenus()

    expect(mocks.updateTray).not.toHaveBeenCalled()
    expect(mocks.updateTrayMenus).not.toHaveBeenCalled()
  })

  it('updates tray icon, menus, and dispatches generated menu events', async () => {
    await updateTrayMenus()

    expect(mocks.updateTray).toHaveBeenCalledWith({
      icon: 'data/.cache/imgs/tray_tun_dark.png',
      title: 'PrivateDeploy',
      tooltip: 'PrivateDeploy 2.0.0',
    })
    expect(mocks.eventsOff).toHaveBeenCalledWith('onMenuItemClick')
    expect(mocks.eventsOn).toHaveBeenCalledWith('onMenuItemClick', expect.any(Function))

    const menus = mocks.updateTrayMenus.mock.calls[0][0] as TestMenu[]
    expect(findMenu(menus, 'tx:tray.showMainWindow')?.hidden).toBe(false)
    expect(findMenu(menus, 'tx:tray.stopKernel')?.hidden).toBe(false)
    expect(findMenu(menus, 'tx:tray.startKernel')?.hidden).toBe(true)
    expect(findMenu(menus, 'tx:tray.setSystemProxy')?.hidden).toBe(true)
    expect(findMenu(menus, 'tx:tray.clearSystemProxy')?.hidden).toBe(false)
    expect(findMenu(menus, 'tx:Dead Node')).toBeUndefined()
    expect(findMenu(menus, 'tx:Node B')?.checked).toBe(true)

    clickMenu(findMenu(menus, 'tx:tray.showMainWindow'))
    expect(mocks.showMainWindow).toHaveBeenCalled()

    clickMenu(findMenu(menus, 'tx:kernel.global'))
    expect(mocks.handleChangeMode).toHaveBeenCalledWith(ClashMode.Global)

    clickMenu(findMenu(menus, 'tx:Node A'))
    expect(mocks.handleUseProxy).toHaveBeenCalledWith(
      expect.objectContaining({ name: 'Auto' }),
      expect.objectContaining({ name: 'Node A' }),
    )

    clickMenu(findMenu(menus, 'tx:tray.disableTunMode'))
    expect(mocks.kernelApiStore.updateConfig).toHaveBeenCalledWith('tun', { enable: false })

    clickMenu(findMenu(menus, 'tx:settings.theme.dark'))
    expect(mocks.appSettingsStore.app.theme).toBe(Theme.Dark)

    clickMenu(findMenu(menus, 'tx:settings.color.green'))
    expect(mocks.appSettingsStore.app.color).toBe(Color.Green)

    clickMenu(findMenu(menus, 'tx:中文'))
    expect(mocks.appSettingsStore.app.lang).toBe('zh')
  })

  it('runs plugin menu events and reports plugin failures', async () => {
    mocks.pluginsStore.manualTrigger.mockRejectedValueOnce(new Error('plugin failed'))

    await updateTrayMenus()

    const menus = mocks.updateTrayMenus.mock.calls[0][0] as TestMenu[]
    clickMenu(findMenu(menus, 'tx:Run cleanup'))
    await Promise.resolve()

    expect(mocks.pluginsStore.manualTrigger).toHaveBeenCalledWith('plugin-1', 'cleanup')
    expect(mocks.notify).toHaveBeenCalledWith('Error', 'plugin failed')
    expect(findMenu(menus, 'tx:Hidden Plugin')).toBeUndefined()
  })

  it('uses platform-specific title and icon variants', async () => {
    mocks.envStore.isDarwin = true
    mocks.envStore.isLinux = false
    mocks.envStore.systemProxy = false
    mocks.kernelApiStore.config.tun.enable = false
    mocks.kernelApiStore.running = false

    await updateTrayMenus()

    expect(mocks.updateTray).toHaveBeenCalledWith({
      icon: 'data/.cache/icons/tray_normal_dark.ico',
      title: '',
      tooltip: 'PrivateDeploy 2.0.0',
    })

    const menus = mocks.updateTrayMenus.mock.calls[0][0] as TestMenu[]
    expect(findMenu(menus, 'tx:tray.startKernel')?.hidden).toBe(false)
    expect(findMenu(menus, 'tx:tray.restartKernel')?.hidden).toBe(true)
  })
})
