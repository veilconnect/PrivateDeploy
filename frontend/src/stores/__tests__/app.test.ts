import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  absolutePath: vi.fn(),
  alert: vi.fn(),
  browserOpenURL: vi.fn(),
  destroyMessage: vi.fn(),
  download: vi.fn(),
  getGitHubApiAuthorization: vi.fn(),
  httpCancel: vi.fn(),
  httpGet: vi.fn(),
  ignoredError: vi.fn(),
  makeDir: vi.fn(),
  messageError: vi.fn(),
  messageInfo: vi.fn(),
  messageSuccess: vi.fn(),
  moveFile: vi.fn(),
  removeFile: vi.fn(),
  sampleID: vi.fn(),
  unzipZIPFile: vi.fn(),
  updateMessage: vi.fn(),
  envStore: {
    env: {
      appName: 'PrivateDeploy',
      arch: 'amd64',
      os: 'linux',
    },
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
  HttpCancel: mocks.httpCancel,
  HttpGet: mocks.httpGet,
  MakeDir: mocks.makeDir,
  MoveFile: mocks.moveFile,
  RemoveFile: mocks.removeFile,
  UnzipZIPFile: mocks.unzipZIPFile,
}))

vi.mock('@/utils', () => ({
  APP_TITLE: 'PrivateDeploy',
  APP_VERSION: '1.0.0',
  APP_VERSION_API: 'https://api.github.test/releases/latest',
  alert: mocks.alert,
  getGitHubApiAuthorization: mocks.getGitHubApiAuthorization,
  ignoredError: (...args: unknown[]) => mocks.ignoredError(...args),
  message: {
    error: mocks.messageError,
    info: mocks.messageInfo,
    success: mocks.messageSuccess,
  },
  sampleID: mocks.sampleID,
}))

vi.mock('../env', () => ({
  useEnvStore: () => mocks.envStore,
}))

import { useAppStore } from '../app'

describe('app store', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    setActivePinia(createPinia())

    mocks.envStore.env = {
      appName: 'PrivateDeploy',
      arch: 'amd64',
      os: 'linux',
    }
    mocks.absolutePath.mockResolvedValue('/abs/data')
    mocks.alert.mockResolvedValue(undefined)
    mocks.download.mockImplementation(async (_url, _path, _options, onProgress) => {
      onProgress?.(50, 100)
    })
    mocks.getGitHubApiAuthorization.mockReturnValue('token gh')
    mocks.httpGet.mockResolvedValue({
      body: {
        assets: [
          {
            browser_download_url: 'https://download.test/PrivateDeploy-linux-amd64.zip',
            name: 'PrivateDeploy-linux-amd64.zip',
          },
        ],
        tag_name: '1.1.0',
      },
    })
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
    mocks.sampleID
      .mockReturnValueOnce('action-1')
      .mockReturnValueOnce('action-2')
      .mockReturnValue('action-next')
    mocks.unzipZIPFile.mockResolvedValue(undefined)
  })

  it('manages custom action registration and removal', () => {
    const store = useAppStore()
    const actionA = { label: 'A' }
    const actionB = () => undefined

    const remove = store.addCustomActions('title_bar', [actionA, actionB])

    expect(store.customActions.title_bar).toEqual([
      { id: 'action-1', label: 'A' },
      expect.objectContaining({ id: 'action-2' }),
    ])

    store.removeCustomActions('title_bar', 'action-1')
    expect(store.customActions.title_bar.map((action) => action.id)).toEqual(['action-2'])

    remove()
    expect(store.customActions.title_bar).toEqual([])
    expect(() => store.addCustomActions('missing', { label: 'bad' })).toThrow(
      'Target does not exist: missing',
    )
  })

  it('checks for updates and reports the result', async () => {
    const store = useAppStore()

    await store.checkForUpdates(true)

    expect(mocks.httpGet).toHaveBeenCalledWith('https://api.github.test/releases/latest', {
      Authorization: 'token gh',
    })
    expect(store.remoteVersion).toBe('1.1.0')
    expect(store.updatable).toBe(true)
    expect(store.checkForUpdatesLoading).toBe(false)
    expect(mocks.messageInfo).toHaveBeenCalledWith('about.newVersion')
  })

  it('downloads and installs desktop updates on non-Darwin platforms', async () => {
    const store = useAppStore()
    await store.checkForUpdates()

    await store.downloadApp()

    expect(mocks.messageInfo).toHaveBeenCalledWith('common.downloading', 600000, expect.any(Function))
    expect(mocks.makeDir).toHaveBeenCalledWith('data/.cache')
    expect(mocks.download).toHaveBeenCalledWith(
      'https://download.test/PrivateDeploy-linux-amd64.zip',
      'data/.cache/gui.zip',
      undefined,
      expect.any(Function),
      { CancelId: 'data/.cache/gui.zip' },
    )
    expect(mocks.updateMessage).toHaveBeenCalledWith('t:common.downloading50.00%')
    expect(mocks.moveFile).toHaveBeenCalledWith('PrivateDeploy', 'PrivateDeploy.bak')
    expect(mocks.unzipZIPFile).toHaveBeenCalledWith('data/.cache/gui.zip', '.')
    expect(mocks.moveFile).toHaveBeenCalledWith('PrivateDeploy', 'PrivateDeploy')
    expect(mocks.removeFile).toHaveBeenCalledWith('data/.cache/gui.zip')
    expect(mocks.messageSuccess).toHaveBeenCalledWith('about.updateSuccessfulRestart')
    expect(store.restartable).toBe(true)
    expect(store.downloading).toBe(false)
  })

  it('uses the replacement flow on Darwin and surfaces update errors', async () => {
    const store = useAppStore()
    mocks.envStore.env.os = 'darwin'
    mocks.httpGet.mockResolvedValueOnce({
      body: {
        assets: [
          {
            browser_download_url: 'https://download.test/PrivateDeploy-darwin-amd64.zip',
            name: 'PrivateDeploy-darwin-amd64.zip',
          },
        ],
        tag_name: '1.1.0',
      },
    })
    await store.checkForUpdates()

    await store.downloadApp()

    expect(mocks.unzipZIPFile).toHaveBeenCalledWith('data/.cache/gui.zip', 'data')
    expect(mocks.alert).toHaveBeenCalledWith('common.success', 'about.updateSuccessfulReplace')
    expect(mocks.browserOpenURL).toHaveBeenCalledWith('/abs/data')

    mocks.httpGet.mockResolvedValueOnce({ body: { message: 'rate limited' } })
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => undefined)

    await store.checkForUpdates(true)

    expect(mocks.messageError).toHaveBeenCalledWith('rate limited')
    expect(store.checkForUpdatesLoading).toBe(false)
    errorSpy.mockRestore()
  })
})
