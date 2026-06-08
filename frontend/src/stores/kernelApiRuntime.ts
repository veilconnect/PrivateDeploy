import {
  AbsolutePath,
  CopyFile,
  Download,
  Exec,
  FileExists,
  HttpCancel,
  HttpGet,
  MakeDir,
  MoveFile,
  RemoveFile,
  UnzipTarGZFile,
  UnzipZIPFile,
} from '@/bridge'
import { GetAvailablePort } from '@/bridge/app'
import { CoreWorkingDirectory } from '@/constant/kernel'
import {
  DefaultExperimental,
  DefaultInboundHttp,
  DefaultInboundMixed,
  DefaultInboundSocks,
} from '@/constant/profile'
import { Inbound } from '@/enums/kernel'
import {
  getGitHubApiAuthorization,
  getKernelAssetFileName,
  getKernelFileName,
  message,
} from '@/utils'

const StableReleaseURL = 'https://api.github.com/repos/SagerNet/sing-box/releases/latest'
const AlphaReleaseURL = 'https://api.github.com/repos/SagerNet/sing-box/releases?per_page=2'

export const ensureKernelCoreExecutable = async ({
  isAlpha,
  corePath,
  log,
}: {
  isAlpha: boolean
  corePath: string
  log: (message: string) => void
}) => {
  const exists = await FileExists(corePath).catch(() => false)
  if (exists) return true

  const fallbackPath = `${CoreWorkingDirectory}/${getKernelFileName(!isAlpha)}`
  const fallbackExists = await FileExists(fallbackPath).catch(() => false)
  if (fallbackExists) {
    log(`[KernelApi] Missing core "${corePath}", trying fallback "${fallbackPath}"`)
    await CopyFile(fallbackPath, corePath)
    if (!corePath.endsWith('.exe')) {
      await Exec('chmod', ['+x', await AbsolutePath(corePath)]).catch(() => undefined)
    }

    const restored = await FileExists(corePath).catch(() => false)
    if (restored) {
      log('[KernelApi] Restored core executable from fallback')
      return true
    }
  }

  log(`[KernelApi] Missing core "${corePath}", auto downloading...`)

  const releaseUrl = isAlpha ? AlphaReleaseURL : StableReleaseURL
  const { body } = await HttpGet<Record<string, any>>(releaseUrl, {
    Authorization: getGitHubApiAuthorization(),
  })
  if (body.message) throw body.message

  const release = isAlpha ? body.find((item: any) => item?.prerelease === true) : body
  if (!release) throw 'Release not found'

  const version = String(release.name || release.tag_name || '').replace(/^v/, '')
  if (!version) throw 'Release version not found'

  const assetName = getKernelAssetFileName(version)
  const asset = release.assets?.find((item: any) => item?.name === assetName)
  if (!asset) throw 'Asset Not Found:' + assetName

  const cacheDir = 'data/.cache'
  const cacheFile = `${cacheDir}/${assetName}`
  const cancelId = `kernel-auto-download-${Date.now()}`
  const toast = message.info('kernel.errors.autoDownloadingCore', 10 * 60 * 1_000, () => {
    HttpCancel(cancelId)
  })

  try {
    await MakeDir(CoreWorkingDirectory).catch(() => undefined)
    await MakeDir(cacheDir).catch(() => undefined)
    await Download(asset.browser_download_url, cacheFile, undefined, undefined, {
      CancelId: cancelId,
    })
  } finally {
    toast.destroy()
  }

  const extractedCoreFileName = getKernelFileName()
  await RemoveFile(corePath).catch(() => undefined)

  if (assetName.endsWith('.zip')) {
    await UnzipZIPFile(cacheFile, cacheDir)
    const extractedDir = `${cacheDir}/${assetName.replace('.zip', '')}`
    await MoveFile(`${extractedDir}/${extractedCoreFileName}`, corePath)
    await RemoveFile(extractedDir).catch(() => undefined)
  } else if (assetName.endsWith('.tar.gz')) {
    await UnzipTarGZFile(cacheFile, cacheDir)
    const extractedDir = `${cacheDir}/${assetName.replace('.tar.gz', '')}`
    await MoveFile(`${extractedDir}/${extractedCoreFileName}`, corePath)
    await RemoveFile(extractedDir).catch(() => undefined)
  } else {
    throw `Unsupported asset format: ${assetName}`
  }

  await RemoveFile(cacheFile).catch(() => undefined)

  if (!corePath.endsWith('.exe')) {
    await Exec('chmod', ['+x', await AbsolutePath(corePath)]).catch(() => undefined)
  }

  return await FileExists(corePath).catch(() => false)
}

export const reassignKernelProfilePorts = async (target: IProfile) => {
  const usedPorts = new Set<number>()
  const collectPort = (value?: number) => {
    if (typeof value === 'number' && value > 0) {
      usedPorts.add(value)
    }
  }

  target.inbounds.forEach((inbound) => {
    const block = inbound[inbound.type as keyof typeof inbound]
    const listen = (block as any)?.listen
    collectPort((listen?.listen_port as number | undefined) ?? undefined)
  })

  target.experimental = target.experimental || DefaultExperimental()

  const ensureInbound = (
    type: Inbound,
    factory: () => IInbound['mixed'] | IInbound['http'] | IInbound['socks'],
  ) => {
    let inbound = target.inbounds.find((item) => item.type === type)
    if (!inbound) {
      inbound = {
        id: `${type}-auto`,
        type,
        tag: `${type}-in`,
        enable: true,
        [type]: factory(),
      } as IInbound
      target.inbounds.push(inbound)
    }
    return inbound
  }

  const allocatePort = async () => {
    for (let attempt = 0; attempt < 10; attempt++) {
      const port = await GetAvailablePort()
      if (!usedPorts.has(port)) {
        usedPorts.add(port)
        return port
      }
    }
    const fallback = await GetAvailablePort()
    usedPorts.add(fallback)
    return fallback
  }

  const changes: Record<string, number> = {}

  const updateInboundPort = async (type: Inbound) => {
    const inbound = ensureInbound(type, () => {
      switch (type) {
        case Inbound.Http:
          return DefaultInboundHttp()
        case Inbound.Socks:
          return DefaultInboundSocks()
        default:
          return DefaultInboundMixed()
      }
    })
    const block: any = inbound[type]
    if (!block) return

    block.listen = block.listen || { listen: '127.0.0.1', listen_port: 0 }
    block.listen.listen = block.listen.listen || '127.0.0.1'

    const currentPort = block.listen.listen_port
    if (currentPort > 0 && !usedPorts.has(currentPort)) {
      usedPorts.add(currentPort)
      inbound.enable = true
      return
    }

    const newPort = await allocatePort()
    block.listen.listen_port = newPort
    inbound.enable = true
    changes[type] = newPort
  }

  await updateInboundPort(Inbound.Mixed)
  await updateInboundPort(Inbound.Http)
  await updateInboundPort(Inbound.Socks)

  const controller = target.experimental?.clash_api?.external_controller
  if (controller) {
    let host = '127.0.0.1'
    let rawPort = ''

    if (controller.includes('://')) {
      try {
        const parsed = new URL(controller)
        host = parsed.hostname ? parsed.hostname : host
        rawPort = parsed.port || ''
      } catch {
        // ignore parsing failure
      }
    } else if (controller.startsWith('[')) {
      const closing = controller.indexOf(']')
      if (closing !== -1) {
        host = controller.slice(0, closing + 1)
        rawPort = controller.slice(closing + 1)
      }
    } else {
      const idx = controller.lastIndexOf(':')
      if (idx !== -1) {
        host = controller.slice(0, idx)
        rawPort = controller.slice(idx + 1)
      } else {
        host = controller
      }
    }

    const existingPort = Number(rawPort)
    if (existingPort > 0 && !usedPorts.has(existingPort)) {
      usedPorts.add(existingPort)
    } else {
      collectPort(existingPort)
      const newPort = await allocatePort()
      const trimmedHost = host?.trim()?.length ? host.trim() : '127.0.0.1'
      target.experimental.clash_api.external_controller = `${trimmedHost}:${newPort}`
      changes.controller = newPort
    }
  }

  return { changed: Object.keys(changes).length > 0, ports: changes }
}

export const pruneMissingKernelCloudSubscriptions = async (target: IProfile) => {
  const cloudSubscriptionIDs = new Set<string>()
  const addCloudID = (id?: string) => {
    if (typeof id === 'string' && id.startsWith('cloud-')) {
      cloudSubscriptionIDs.add(id)
    }
  }

  target.outbounds?.forEach((outbound: any) => {
    addCloudID(outbound?.id)
    if (Array.isArray(outbound?.outbounds)) {
      outbound.outbounds.forEach((item: any) => addCloudID(item?.id))
    }
  })

  if (!cloudSubscriptionIDs.size) {
    return { changed: false, removed: [] as string[] }
  }

  const removed: string[] = []
  for (const id of cloudSubscriptionIDs) {
    const exists = await FileExists(`data/subscribes/${id}.json`).catch(() => false)
    if (!exists) {
      removed.push(id)
    }
  }

  if (!removed.length) {
    return { changed: false, removed }
  }

  const removedSet = new Set(removed)
  let changed = false

  const nextOutbounds = (target.outbounds || []).filter((outbound: any) => {
    if (typeof outbound?.id === 'string' && removedSet.has(outbound.id)) {
      changed = true
      return false
    }
    return true
  })

  nextOutbounds.forEach((outbound: any) => {
    if (!Array.isArray(outbound?.outbounds)) return
    const before = outbound.outbounds.length
    outbound.outbounds = outbound.outbounds.filter(
      (item: any) => !(typeof item?.id === 'string' && removedSet.has(item.id)),
    )
    if (before !== outbound.outbounds.length) {
      changed = true
    }
  })

  if (changed) {
    target.outbounds = nextOutbounds
  }

  return { changed, removed }
}
