import { logError, logInfo } from './logger'

export interface BackupData {
  version: string
  timestamp: number
  cloudConfig?: any
  nodes?: any[]
  settings?: any
  notifications?: any
}

/**
 * Create a backup of current data
 */
export async function createBackup(data: Omit<BackupData, 'version' | 'timestamp'>): Promise<string> {
  const backup: BackupData = {
    version: '1.0.0',
    timestamp: Date.now(),
    ...data,
  }

  return JSON.stringify(backup, null, 2)
}

/**
 * Parse backup data
 */
export function parseBackup(backupString: string): BackupData {
  try {
    const backup = JSON.parse(backupString) as BackupData

    // Validate backup structure
    if (!backup.version || !backup.timestamp) {
      throw new Error('Invalid backup format: missing version or timestamp')
    }

    return backup
  } catch (error) {
    logError('Failed to parse backup', error)
    throw new Error('Invalid backup file format')
  }
}

/**
 * Download backup as file
 */
export function downloadBackup(backupString: string, filename?: string) {
  const blob = new Blob([backupString], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')

  link.href = url
  link.download = filename || `privatedeploy-backup-${Date.now()}.json`
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)

  URL.revokeObjectURL(url)
  logInfo('Backup downloaded successfully')
}

/**
 * Read backup file
 */
export function readBackupFile(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()

    reader.onload = (e) => {
      const content = e.target?.result as string
      resolve(content)
    }

    reader.onerror = () => {
      reject(new Error('Failed to read backup file'))
    }

    reader.readAsText(file)
  })
}

/**
 * Validate backup compatibility
 */
export function isBackupCompatible(backup: BackupData): boolean {
  // Check version compatibility
  const backupVersion = backup.version.split('.').map(Number)
  const currentVersion = [1, 0, 0] // Current version

  // Major version must match
  if (backupVersion[0] !== currentVersion[0]) {
    return false
  }

  return true
}

/**
 * Auto-backup to localStorage
 */
export function autoBackup(data: Omit<BackupData, 'version' | 'timestamp'>) {
  try {
    const backup = {
      version: '1.0.0',
      timestamp: Date.now(),
      ...data,
    }

    localStorage.setItem('auto-backup', JSON.stringify(backup))
    localStorage.setItem('auto-backup-timestamp', String(Date.now()))
    logInfo('Auto-backup saved to localStorage')
  } catch (error) {
    logError('Failed to create auto-backup', error)
  }
}

/**
 * Load auto-backup from localStorage
 */
export function loadAutoBackup(): BackupData | null {
  try {
    const backupString = localStorage.getItem('auto-backup')
    if (!backupString) {
      return null
    }

    return parseBackup(backupString)
  } catch (error) {
    logError('Failed to load auto-backup', error)
    return null
  }
}

/**
 * Get auto-backup age in milliseconds
 */
export function getAutoBackupAge(): number | null {
  const timestamp = localStorage.getItem('auto-backup-timestamp')
  if (!timestamp) {
    return null
  }

  return Date.now() - Number(timestamp)
}

/**
 * Clear auto-backup
 */
export function clearAutoBackup() {
  localStorage.removeItem('auto-backup')
  localStorage.removeItem('auto-backup-timestamp')
  logInfo('Auto-backup cleared')
}
