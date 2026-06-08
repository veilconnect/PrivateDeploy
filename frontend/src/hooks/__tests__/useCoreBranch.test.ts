import { beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick } from 'vue'

import { Branch } from '@/enums/app'

const mocks = vi.hoisted(() => ({
  absolutePath: vi.fn(),
  browserOpenURL: vi.fn(),
  confirm: vi.fn(),
  destroyMessage: vi.fn(),
  download: vi.fn(),
  exec: vi.fn(),
  fileExists: vi.fn(),
  getGitHubApiAuthorization: vi.fn(),
  getKernelAssetFileName: vi.fn(),
  grantTUNPermission: vi.fn(),
  httpCancel: vi.fn(),
  httpGet: vi.fn(),
  ignoredError: vi.fn(),
  makeDir: vi.fn(),
  messageError: vi.fn(),
  messageInfo: vi.fn(),
  messageSuccess: vi.fn(),
  moveFile: vi.fn(),
  removeFile: vi.fn(),
  unzipTarGZFile: vi.fn(),
  unzipZIPFile: vi.fn(),
  updateMessage: vi.fn(),
  appSettingsStore: {
    app: {
      kernel: {
        branch: 'main',
      },
    },
  },
  envStore: {
    capabilities: {
      kernelGrantPermissionSupported: true,
    },
  },
  kernelApiStore: {
    running: true,
    restartCore: vi.fn(),
  },
}))

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key: string) => `t:${key}`,
  }),
}))

vi.mock('@/bridge', () => ({
  AbsolutePath: mocks.absolutePath,
  BrowserOpenURL: mocks.browserOpenURL,
  Download: mocks.download,
  Exec: mocks.exec,
  FileExists: mocks.fileExists,
  HttpCancel: mocks.httpCancel,
  HttpGet: mocks.httpGet,
  MakeDir: mocks.makeDir,
  MoveFile: mocks.moveFile,
  RemoveFile: mocks.removeFile,
  UnzipTarGZFile: mocks.unzipTarGZFile,
  UnzipZIPFile: mocks.unzipZIPFile,
}))

vi.mock('@/stores', () => ({
  useAppSettingsStore: () => mocks.appSettingsStore,
  useEnvStore: () => mocks.envStore,
  useKernelApiStore: () => mocks.kernelApiStore,
}))

vi.mock('@/utils', () => ({
  GrantTUNPermission: mocks.grantTUNPermission,
  confirm: mocks.confirm,
  debounce: (fn: (...args: unknown[]) => unknown) => fn,
  getGitHubApiAuthorization: mocks.getGitHubApiAuthorization,
  getKernelAssetFileName: mocks.getKernelAssetFileName,
  getKernelFileName: (isAlpha = false) => (isAlpha ? 'sing-box-latest' : 'sing-box'),
  ignoredError: (...args: unknown[]) => mocks.ignoredError(...args),
  message: {
    error: mocks.messageError,
    info: mocks.messageInfo,
    success: mocks.messageSuccess,
  },
}))

import { useCoreBranch } from '../useCoreBranch'

const stableRelease = {
  body: {
    name: 'v1.2.4',
    tag_name: 'v1.2.4',
    assets: [
      {
        browser_download_url: 'https://download.test/sing-box.tar.gz',
        name: 'sing-box-v1.2.4-linux-amd64.tar.gz',
        uploader: { type: 'Bot' },
      },
    ],
  },
}

const settle = async () => {
  await Promise.resolve()
  await Promise.resolve()
  await nextTick()
  await Promise.resolve()
}

describe('useCoreBranch', () => {
  beforeEach(() => {
    vi.clearAllMocks()

    mocks.appSettingsStore.app.kernel.branch = Branch.Main
    mocks.envStore.capabilities.kernelGrantPermissionSupported = true
    mocks.kernelApiStore.running = true
    mocks.kernelApiStore.restartCore.mockResolvedValue(undefined)

    mocks.absolutePath.mockImplementation(async (path: string) => `/abs/${path}`)
    mocks.confirm.mockResolvedValue(undefined)
    mocks.download.mockImplementation(async (_url, _path, _options, onProgress) => {
      onProgress?.(25, 100)
    })
    mocks.exec.mockImplementation(async (cmd: string, args?: string[]) => {
      if (cmd.startsWith('data/sing-box/') && args?.[0] === 'version') {
        return 'sing-box version 1.2.3\nEnvironment: test'
      }
      return ''
    })
    mocks.fileExists.mockResolvedValue(false)
    mocks.getGitHubApiAuthorization.mockReturnValue('token gh')
    mocks.getKernelAssetFileName.mockImplementation((version: string) => {
      return `sing-box-${version}-linux-amd64.tar.gz`
    })
    mocks.httpGet.mockResolvedValue(stableRelease)
    mocks.ignoredError.mockImplementation(async (fn: (...args: unknown[]) => Promise<unknown>, ...args) => {
      try {
        return await fn(...args)
      } catch {
        return undefined
      }
    })
    mocks.makeDir.mockResolvedValue(undefined)
    mocks.messageInfo.mockReturnValue({
      destroy: mocks.destroyMessage,
      update: mocks.updateMessage,
    })
    mocks.moveFile.mockResolvedValue(undefined)
    mocks.removeFile.mockResolvedValue(undefined)
    mocks.unzipTarGZFile.mockResolvedValue(undefined)
    mocks.unzipZIPFile.mockResolvedValue(undefined)
  })

  it('refreshes local and remote versions on setup', async () => {
    const branch = useCoreBranch()

    await settle()

    expect(mocks.exec).toHaveBeenCalledWith('data/sing-box/sing-box', ['version'])
    expect(mocks.httpGet).toHaveBeenCalledWith(
      'https://api.github.com/repos/SagerNet/sing-box/releases/latest',
      { Authorization: 'token gh' },
    )
    expect(branch.localVersion.value).toBe('1.2.3')
    expect(branch.remoteVersion.value).toBe('1.2.4')
    expect(branch.versionDetail.value).toBe('sing-box version 1.2.3\nEnvironment: test')
    expect(branch.updatable.value).toBe(true)
    expect(branch.grantable.value).toBe(true)
    expect(branch.restartable.value).toBe(false)
  })

  it('downloads and installs a stable tarball asset', async () => {
    const branch = useCoreBranch()
    await settle()

    await branch.downloadCore()

    const cacheFile = 'data/.cache/sing-box-v1.2.4-linux-amd64.tar.gz'
    expect(mocks.makeDir).toHaveBeenCalledWith('data/sing-box')
    expect(mocks.download).toHaveBeenCalledWith(
      'https://download.test/sing-box.tar.gz',
      cacheFile,
      undefined,
      expect.any(Function),
      { CancelId: cacheFile },
    )
    expect(mocks.updateMessage).toHaveBeenCalledWith('t:common.downloading25.00%')
    expect(mocks.moveFile).toHaveBeenCalledWith(
      'data/sing-box/sing-box',
      'data/sing-box/sing-box.bak',
    )
    expect(mocks.unzipTarGZFile).toHaveBeenCalledWith(cacheFile, 'data/.cache')
    expect(mocks.moveFile).toHaveBeenCalledWith(
      'data/.cache/sing-box-v1.2.4-linux-amd64/sing-box',
      'data/sing-box/sing-box',
    )
    expect(mocks.removeFile).toHaveBeenCalledWith('data/.cache/sing-box-v1.2.4-linux-amd64')
    expect(mocks.removeFile).toHaveBeenCalledWith(cacheFile)
    expect(mocks.exec).toHaveBeenCalledWith('chmod', ['+x', '/abs/data/sing-box/sing-box'])
    expect(branch.restartable.value).toBe(true)
    expect(mocks.messageSuccess).toHaveBeenCalledWith('common.success')
  })

  it('uses prerelease metadata for alpha branches and opens the alpha release page', async () => {
    mocks.appSettingsStore.app.kernel.branch = Branch.Alpha
    mocks.httpGet.mockResolvedValue({
      body: [
        { name: 'v1.2.4', prerelease: false },
        { name: 'v1.3.0-alpha.1', prerelease: true },
      ],
    })

    const branch = useCoreBranch(true)
    await settle()

    expect(mocks.exec).toHaveBeenCalledWith('data/sing-box/sing-box-latest', ['version'])
    expect(mocks.httpGet).toHaveBeenCalledWith(
      'https://api.github.com/repos/SagerNet/sing-box/releases?per_page=2',
      { Authorization: 'token gh' },
    )
    expect(branch.remoteVersion.value).toBe('1.3.0-alpha.1')

    branch.openReleasePage()

    expect(mocks.browserOpenURL).toHaveBeenCalledWith(
      'https://github.com/SagerNet/sing-box/releases',
    )
  })

  it('runs permission grants and rollback through the running kernel branch', async () => {
    mocks.kernelApiStore.restartCore.mockImplementation(async (beforeRestart?: () => Promise<void>) => {
      await beforeRestart?.()
    })
    const branch = useCoreBranch()
    await settle()

    await branch.grantCorePermission()
    await branch.rollbackCore()
    branch.openReleasePage()

    expect(mocks.grantTUNPermission).toHaveBeenCalledWith('data/sing-box/sing-box')
    expect(mocks.confirm).toHaveBeenCalledWith('common.warning', 'settings.kernel.rollback')
    expect(mocks.kernelApiStore.restartCore).toHaveBeenCalledWith(expect.any(Function))
    expect(mocks.moveFile).toHaveBeenCalledWith(
      'data/sing-box/sing-box.bak',
      'data/sing-box/sing-box',
    )
    expect(mocks.browserOpenURL).toHaveBeenCalledWith(
      'https://github.com/SagerNet/sing-box/releases/latest',
    )
    expect(mocks.messageSuccess).toHaveBeenCalledWith('common.success')
  })

  it('surfaces remote and download failures when requested', async () => {
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => undefined)
    mocks.httpGet.mockResolvedValue({ body: { message: 'rate limited' } })
    const branch = useCoreBranch()
    await settle()

    await branch.refreshRemoteVersion(true)
    await branch.downloadCore()

    expect(branch.remoteVersion.value).toBe('')
    expect(mocks.messageError).toHaveBeenCalledWith('rate limited')
    logSpy.mockRestore()
  })
})
