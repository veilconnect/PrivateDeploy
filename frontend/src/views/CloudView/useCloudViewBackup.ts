import { ExportCloudBackup, ImportCloudBackup } from '@/bridge'
import { message } from '@/utils'
import { createBackup, parseBackup } from '@/utils/backup'

import type { CloudConfig } from '@/types/cloud'

type TranslateFn = (key: string, params?: Record<string, unknown>) => string

type CloudStoreLike = {
  config: CloudConfig
  saveConfig: () => Promise<void>
}

type UseCloudViewBackupDeps = {
  cloudStore: CloudStoreLike
  fetchMeta: () => Promise<unknown>
  handleError: (error: unknown) => void
  translate: TranslateFn
}

export const useCloudViewBackup = ({
  cloudStore,
  fetchMeta,
  handleError,
  translate,
}: UseCloudViewBackupDeps) => {
  const handleBackupConfig = async () => {
    try {
      const backupString = await createBackup({
        cloudConfig: cloudStore.config,
      })
      const path = await ExportCloudBackup(backupString)
      if (!path) {
        return
      }
      message.success(translate('cloud.backup.exported'))
    } catch (error) {
      message.error(translate('cloud.backup.exportFailed'))
      handleError(error)
    }
  }

  const handleRestoreConfig = async () => {
    try {
      const backupString = await ImportCloudBackup()
      if (!backupString) {
        return
      }

      const backup = parseBackup(backupString)

      if (backup.cloudConfig) {
        Object.assign(cloudStore.config, backup.cloudConfig)
        await cloudStore.saveConfig()
      }

      message.success(translate('cloud.backup.imported'))
      await fetchMeta()
    } catch (error) {
      message.error(translate('cloud.backup.importFailed'))
      handleError(error)
    }
  }

  return {
    handleBackupConfig,
    handleRestoreConfig,
  }
}
