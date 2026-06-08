import { beforeEach, describe, expect, it, vi } from 'vitest'

const bridgeMocks = vi.hoisted(() => ({
  ExitApp: vi.fn(),
  RestartApp: vi.fn(),
  WindowReloadApp: vi.fn(),
}))

const utilityMocks = vi.hoisted(() => ({
  handleChangeMode: vi.fn(),
  message: {
    error: vi.fn(),
    success: vi.fn(),
  },
}))

const storeMocks = vi.hoisted(() => {
  const appSettings = {
    app: {
      color: '',
      lang: '',
      theme: '',
    },
    loadLocales: vi.fn(),
    locales: [
      { label: 'English', value: 'en' },
      { label: '简体中文', value: 'zh' },
    ],
  }
  const plugin = {
    id: 'plugin-1',
    menus: {
      'Menu A': 'menuA',
    },
    name: 'Plugin One',
    running: false,
    triggers: ['on::manual'],
  }

  return {
    appSettings,
    appStore: { showAbout: false },
    cloudStore: { refreshInstances: vi.fn() },
    envStore: {
      clearSystemProxy: vi.fn(),
      setSystemProxy: vi.fn(),
    },
    kernelStore: {
      restartCore: vi.fn(),
      startCore: vi.fn(),
      stopCore: vi.fn(),
      updateConfig: vi.fn(),
    },
    plugin,
    pluginsStore: {
      manualTrigger: vi.fn(),
      plugins: [plugin],
    },
    rulesetsStore: {
      updateRulesets: vi.fn(),
    },
  }
})

vi.mock('@/bridge', () => ({
  ExitApp: bridgeMocks.ExitApp,
  RestartApp: bridgeMocks.RestartApp,
  WindowReloadApp: bridgeMocks.WindowReloadApp,
}))

vi.mock('@/lang', () => ({
  default: {
    global: {
      t: (key: string) => key,
    },
  },
}))

vi.mock('@/stores', () => ({
  useAppSettingsStore: () => storeMocks.appSettings,
  useAppStore: () => storeMocks.appStore,
  useCloudStore: () => storeMocks.cloudStore,
  useEnvStore: () => storeMocks.envStore,
  useKernelApiStore: () => storeMocks.kernelStore,
  usePluginsStore: () => storeMocks.pluginsStore,
  useRulesetsStore: () => storeMocks.rulesetsStore,
}))

vi.mock('@/utils', () => ({
  handleChangeMode: utilityMocks.handleChangeMode,
  message: utilityMocks.message,
}))

import { Color, PluginTriggerEvent, Theme } from '@/enums/app'
import { ClashMode } from '@/enums/kernel'

import { getCommands } from '../command'

const findCommand = (cmd: string) => {
  const command = getCommands().find((item) => item.cmd === cmd)
  expect(command, `Missing command ${cmd}`).toBeTruthy()
  return command!
}

describe('command utilities', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    storeMocks.appSettings.app.color = ''
    storeMocks.appSettings.app.lang = ''
    storeMocks.appSettings.app.theme = ''
    storeMocks.appStore.showAbout = false
    storeMocks.plugin.running = false
    storeMocks.pluginsStore.manualTrigger.mockResolvedValue(undefined)
  })

  it('flattens nested command groups with translated labels and composed command paths', () => {
    const commands = getCommands()

    expect(commands).toEqual(expect.arrayContaining([
      expect.objectContaining({
        cmd: 'Kernel: Start Core',
        label: 'tray.kernel: tray.startKernel',
        handler: storeMocks.kernelStore.startCore,
      }),
      expect.objectContaining({
        cmd: 'APP: Theme: Dark',
        label: 'APP: settings.theme.name: settings.theme.dark',
      }),
      expect.objectContaining({
        cmd: 'Plugins: plugin-1: menuA',
        label: 'tray.plugins: Plugin One: Menu A',
      }),
    ]))
  })

  it('binds kernel, proxy, app, cloud, and ruleset command handlers', async () => {
    await findCommand('Kernel: Enable Tun').handler?.()
    await findCommand('Kernel: Allow Lan').handler?.()
    await findCommand('Kernel: Kernel Mode: Rule').handler?.()
    await findCommand('System Proxy: Set System Proxy').handler?.()
    await findCommand('Deploy: Refresh Nodes').handler?.()
    await findCommand('Rulesets: Update Rulesets').handler?.()

    expect(storeMocks.kernelStore.updateConfig).toHaveBeenCalledWith('tun', { enable: true })
    expect(storeMocks.kernelStore.updateConfig).toHaveBeenCalledWith('allow-lan', true)
    expect(utilityMocks.handleChangeMode).toHaveBeenCalledWith(ClashMode.Rule)
    expect(storeMocks.envStore.setSystemProxy).toHaveBeenCalledTimes(1)
    expect(storeMocks.cloudStore.refreshInstances).toHaveBeenCalledTimes(1)
    expect(storeMocks.rulesetsStore.updateRulesets).toHaveBeenCalledTimes(1)

    await findCommand('APP: Language: Load language files').handler?.()
    findCommand('APP: Language: en').handler?.()
    findCommand('APP: Theme: Dark').handler?.()
    findCommand('APP: Color: Purple').handler?.()
    findCommand('APP: About APP').handler?.()

    expect(storeMocks.appSettings.loadLocales).toHaveBeenCalledWith(true)
    expect(utilityMocks.message.success).toHaveBeenCalledWith('common.success')
    expect(storeMocks.appSettings.app.lang).toBe('en')
    expect(storeMocks.appSettings.app.theme).toBe(Theme.Dark)
    expect(storeMocks.appSettings.app.color).toBe(Color.Purple)
    expect(storeMocks.appStore.showAbout).toBe(true)
  })

  it('runs app bridge commands and plugin commands', async () => {
    await findCommand('APP: Reload Window').handler?.()
    await findCommand('APP: Restart APP').handler?.()
    await findCommand('APP: Exit APP').handler?.()

    expect(bridgeMocks.WindowReloadApp).toHaveBeenCalledTimes(1)
    expect(bridgeMocks.RestartApp).toHaveBeenCalledTimes(1)
    expect(bridgeMocks.ExitApp).toHaveBeenCalledTimes(1)

    await findCommand('Plugins: plugin-1: on::manual').handler?.()

    expect(storeMocks.pluginsStore.manualTrigger).toHaveBeenCalledWith('plugin-1', PluginTriggerEvent.OnManual)
    expect(storeMocks.plugin.running).toBe(false)

    storeMocks.pluginsStore.manualTrigger.mockRejectedValueOnce(new Error('menu failed'))
    await findCommand('Plugins: plugin-1: menuA').handler?.()

    expect(utilityMocks.message.error).toHaveBeenCalledWith('menu failed')
    expect(storeMocks.plugin.running).toBe(false)
  })
})
