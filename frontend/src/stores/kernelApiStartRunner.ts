import { RemoveFile } from '@/bridge'
import { CoreCacheFilePath } from '@/constant/kernel'
import { message } from '@/utils'

import {
  pruneMissingKernelCloudSubscriptions,
  reassignKernelProfilePorts,
} from './kernelApiRuntime'

type RunKernelStartAttemptsDeps = {
  isAlpha: boolean
  profileToUse: IProfile
  writeConfig: () => Promise<void>
  runCoreProcess: (isAlpha: boolean) => Promise<number | void>
  onCoreStarted: (pid: number) => Promise<void>
  log: (message: string) => void
  onPortsAdjusted: (ports: Record<string, number>) => void
}

export const runKernelStartAttempts = async ({
  isAlpha,
  profileToUse,
  writeConfig,
  runCoreProcess,
  onCoreStarted,
  log,
  onPortsAdjusted,
}: RunKernelStartAttemptsDeps) => {
  let portsAdjusted = false
  let missingCloudSubscriptionsPruned = false
  const maxAttempts = 5
  const backoffDelays = [0, 500, 1000, 2000, 3000]

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    if (attempt > 1 && backoffDelays[attempt - 1] > 0) {
      log(`[KernelApi] Waiting ${backoffDelays[attempt - 1]}ms before retry ${attempt}/${maxAttempts}`)
      await new Promise((resolve) => setTimeout(resolve, backoffDelays[attempt - 1]))
    }

    try {
      await writeConfig()

      const pid = await runCoreProcess(isAlpha)
      if (pid) {
        await onCoreStarted(pid)
      }

      log(`[KernelApi] Core started successfully on attempt ${attempt}`)
      return { missingCloudSubscriptionsPruned, portsAdjusted }
    } catch (error) {
      const messageText = String(error ?? '').toLowerCase()
      log(`[KernelApi] startCore attempt ${attempt}/${maxAttempts} failed: ${String(error ?? '')}`)

      const cacheError =
        messageText.includes('initialize cache-file') || messageText.includes('cache-file')
      if (cacheError && attempt < maxAttempts) {
        await RemoveFile(CoreCacheFilePath).catch(() => undefined)
        message.warn('kernel.errors.cacheResetting')
        log('[KernelApi] Cache file removed, retrying...')
        continue
      }

      const portConflict =
        messageText.includes('address already in use') ||
        messageText.includes('bind: address already in use')
      if (portConflict && attempt < maxAttempts) {
        log('[KernelApi] Port conflict detected, reassigning ports...')
        const result = await reassignKernelProfilePorts(profileToUse)
        if (result.changed) {
          portsAdjusted = true
          onPortsAdjusted(result.ports)
          log(`[KernelApi] Ports reassigned: ${JSON.stringify(result.ports)}`)
          message.warn('kernel.errors.portResetting')
          continue
        }
        log('[KernelApi] Port reassignment returned no changes')
      }

      const missingCloudSubscriptionFile =
        messageText.includes('no such file or directory') &&
        messageText.includes('data/subscribes/cloud-')

      if (missingCloudSubscriptionFile && attempt < maxAttempts) {
        const result = await pruneMissingKernelCloudSubscriptions(profileToUse)
        if (result.changed) {
          missingCloudSubscriptionsPruned = true
          log(`[KernelApi] Removed missing cloud subscriptions: ${result.removed.join(', ')}`)
          continue
        }
      }

      if (attempt === maxAttempts) {
        log(`[KernelApi] All ${maxAttempts} attempts failed, giving up`)
      }
      throw error
    }
  }

  throw new Error('kernel-start-unreachable')
}
