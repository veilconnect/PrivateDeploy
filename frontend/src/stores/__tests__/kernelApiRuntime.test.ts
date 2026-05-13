import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { Inbound } from '@/enums/kernel'

const mocks = vi.hoisted(() => ({
  absolutePath: vi.fn(),
  copyFile: vi.fn(),
  destroyToast: vi.fn(),
  download: vi.fn(),
  exec: vi.fn(),
  fileExists: vi.fn(),
  getAvailablePort: vi.fn(),
  getGitHubApiAuthorization: vi.fn(),
  getKernelAssetFileName: vi.fn(),
  getKernelFileName: vi.fn(),
  httpCancel: vi.fn(),
  httpGet: vi.fn(),
  log: vi.fn(),
  makeDir: vi.fn(),
  messageInfo: vi.fn(),
  moveFile: vi.fn(),
  removeFile: vi.fn(),
  unzipTarGZFile: vi.fn(),
  unzipZIPFile: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  AbsolutePath: mocks.absolutePath,
  CopyFile: mocks.copyFile,
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

vi.mock('@/bridge/app', () => ({
  GetAvailablePort: mocks.getAvailablePort,
}))

vi.mock('@/utils', () => ({
  getGitHubApiAuthorization: mocks.getGitHubApiAuthorization,
  getKernelAssetFileName: mocks.getKernelAssetFileName,
  getKernelFileName: mocks.getKernelFileName,
  message: {
    info: mocks.messageInfo,
  },
}))

import {
  ensureKernelCoreExecutable,
  pruneMissingKernelCloudSubscriptions,
  reassignKernelProfilePorts,
} from '../kernelApiRuntime'

const profile = (overrides: Record<string, unknown> = {}) => ({
  dns: { rules: [] },
  experimental: {
    clash_api: {
      external_controller: '127.0.0.1:3000',
      secret: '',
    },
  },
  id: 'profile-1',
  inbounds: [],
  mixin: '',
  outbounds: [],
  route: { rule_set: [], rules: [] },
  script: '',
  ...overrides,
}) as unknown as IProfile

describe('kernel api runtime helpers', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.absolutePath.mockImplementation(async (path: string) => `/abs/${path}`)
    mocks.copyFile.mockResolvedValue(undefined)
    mocks.download.mockResolvedValue(undefined)
    mocks.exec.mockResolvedValue('')
    mocks.fileExists.mockResolvedValue(false)
    mocks.getAvailablePort
      .mockResolvedValueOnce(3000)
      .mockResolvedValueOnce(3001)
      .mockResolvedValueOnce(3002)
      .mockResolvedValueOnce(3003)
      .mockResolvedValue(3999)
    mocks.getGitHubApiAuthorization.mockReturnValue('token gh')
    mocks.getKernelAssetFileName.mockReturnValue('sing-box-1.2.3-linux-amd64.tar.gz')
    mocks.getKernelFileName.mockImplementation((isAlpha = false) => (isAlpha ? 'sing-box-latest' : 'sing-box'))
    mocks.httpGet.mockResolvedValue({
      body: {
        assets: [
          {
            browser_download_url: 'https://download.test/sing-box.tar.gz',
            name: 'sing-box-1.2.3-linux-amd64.tar.gz',
          },
        ],
        name: 'v1.2.3',
      },
    })
    mocks.makeDir.mockResolvedValue(undefined)
    mocks.messageInfo.mockReturnValue({ destroy: mocks.destroyToast })
    mocks.moveFile.mockResolvedValue(undefined)
    mocks.removeFile.mockResolvedValue(undefined)
    mocks.unzipTarGZFile.mockResolvedValue(undefined)
    mocks.unzipZIPFile.mockResolvedValue(undefined)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('returns true when the requested core executable already exists', async () => {
    mocks.fileExists.mockResolvedValueOnce(true)

    await expect(ensureKernelCoreExecutable({
      corePath: 'data/sing-box/sing-box',
      isAlpha: false,
      log: mocks.log,
    })).resolves.toBe(true)

    expect(mocks.copyFile).not.toHaveBeenCalled()
    expect(mocks.httpGet).not.toHaveBeenCalled()
  })

  it('restores a missing core executable from the opposite branch fallback', async () => {
    mocks.fileExists
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(true)
      .mockResolvedValueOnce(true)

    await expect(ensureKernelCoreExecutable({
      corePath: 'data/sing-box/sing-box-latest',
      isAlpha: true,
      log: mocks.log,
    })).resolves.toBe(true)

    expect(mocks.copyFile).toHaveBeenCalledWith('data/sing-box/sing-box', 'data/sing-box/sing-box-latest')
    expect(mocks.exec).toHaveBeenCalledWith('chmod', ['+x', '/abs/data/sing-box/sing-box-latest'])
    expect(mocks.log).toHaveBeenCalledWith('[KernelApi] Restored core executable from fallback')
  })

  it('downloads and installs a missing core executable when no fallback exists', async () => {
    vi.spyOn(Date, 'now').mockReturnValue(123)
    mocks.fileExists
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(true)

    await expect(ensureKernelCoreExecutable({
      corePath: 'data/sing-box/sing-box',
      isAlpha: false,
      log: mocks.log,
    })).resolves.toBe(true)

    expect(mocks.httpGet).toHaveBeenCalledWith(
      'https://api.github.com/repos/SagerNet/sing-box/releases/latest',
      { Authorization: 'token gh' },
    )
    expect(mocks.messageInfo).toHaveBeenCalledWith(
      'kernel.errors.autoDownloadingCore',
      600000,
      expect.any(Function),
    )
    expect(mocks.download).toHaveBeenCalledWith(
      'https://download.test/sing-box.tar.gz',
      'data/.cache/sing-box-1.2.3-linux-amd64.tar.gz',
      undefined,
      undefined,
      { CancelId: 'kernel-auto-download-123' },
    )
    expect(mocks.unzipTarGZFile).toHaveBeenCalledWith(
      'data/.cache/sing-box-1.2.3-linux-amd64.tar.gz',
      'data/.cache',
    )
    expect(mocks.moveFile).toHaveBeenCalledWith(
      'data/.cache/sing-box-1.2.3-linux-amd64/sing-box',
      'data/sing-box/sing-box',
    )
    expect(mocks.destroyToast).toHaveBeenCalled()
  })

  it('reassigns conflicting inbound ports and a conflicting controller port', async () => {
    const target = profile({
      inbounds: [
        {
          enable: true,
          id: 'mixed',
          mixed: { listen: { listen: '127.0.0.1', listen_port: 3000 } },
          tag: 'mixed-in',
          type: Inbound.Mixed,
        },
        {
          enable: true,
          http: { listen: { listen: '127.0.0.1', listen_port: 3000 } },
          id: 'http',
          tag: 'http-in',
          type: Inbound.Http,
        },
        {
          enable: true,
          id: 'socks',
          socks: { listen: { listen: '127.0.0.1', listen_port: 3000 } },
          tag: 'socks-in',
          type: Inbound.Socks,
        },
      ],
    })

    const result = await reassignKernelProfilePorts(target)

    expect(result).toMatchObject({
      changed: true,
      ports: {
        http: 3002,
        mixed: 3001,
        socks: 3003,
      },
    })
    expect(result.ports.controller).toEqual(expect.any(Number))

    expect(target.inbounds.map((item) => item.type)).toEqual([
      Inbound.Mixed,
      Inbound.Http,
      Inbound.Socks,
    ])
    expect((target.inbounds.find((item) => item.type === Inbound.Mixed) as any).mixed.listen.listen_port).toBe(3001)
    expect(target.experimental.clash_api.external_controller).toBe(
      `127.0.0.1:${result.ports.controller}`,
    )
  })

  it('prunes missing cloud subscription outbounds and group members', async () => {
    mocks.fileExists
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(true)
    const target = profile({
      outbounds: [
        { id: 'cloud-a', tag: 'Cloud A' },
        {
          id: 'selector',
          outbounds: [
            { id: 'cloud-a', tag: 'Cloud A' },
            { id: 'cloud-b', tag: 'Cloud B' },
            { id: 'manual', tag: 'Manual' },
          ],
        },
      ],
    })

    await expect(pruneMissingKernelCloudSubscriptions(target)).resolves.toEqual({
      changed: true,
      removed: ['cloud-a'],
    })

    expect(target.outbounds).toEqual([
      {
        id: 'selector',
        outbounds: [
          { id: 'cloud-b', tag: 'Cloud B' },
          { id: 'manual', tag: 'Manual' },
        ],
      },
    ])
  })
})
