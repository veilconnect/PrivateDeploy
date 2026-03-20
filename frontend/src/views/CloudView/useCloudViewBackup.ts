import { message } from '@/utils'
import { createBackup, downloadBackup, parseBackup } from '@/utils/backup'

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
      downloadBackup(backupString)
      message.success(translate('cloud.backup.exported'))
    } catch (error) {
      message.error(translate('cloud.backup.exportFailed'))
      handleError(error)
    }
  }

  const handleRestoreConfig = async () => {
    try {
      const input = document.createElement('input')
      input.type = 'file'
      input.accept = '.json'
      input.onchange = async (event) => {
        const file = (event.target as HTMLInputElement).files?.[0]
        if (!file) {
          return
        }

        const reader = new FileReader()
        reader.onload = async (loadEvent) => {
          try {
            const backupString = loadEvent.target?.result as string
            const backup = parseBackup(backupString)

            if (backup.cloudConfig) {
              cloudStore.config = backup.cloudConfig
              await cloudStore.saveConfig()
            }

            message.success(translate('cloud.backup.imported'))
            await fetchMeta()
          } catch (error) {
            message.error(translate('cloud.backup.importFailed'))
            handleError(error)
          }
        }
        reader.readAsText(file)
      }
      input.click()
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
