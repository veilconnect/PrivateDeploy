import { reactive } from 'vue'

import { message } from '@/utils'

export type NotificationType = 'success' | 'error' | 'warning' | 'info'
export type NotificationCategory =
  | 'deployment'
  | 'connectivity'
  | 'rotation'
  | 'system'
  | 'quota'

export interface NotificationRecord {
  id: string
  type: NotificationType
  category: NotificationCategory
  title: string
  message: string
  timestamp: number
  read: boolean
}

// Notification history store
const notificationHistory = reactive<NotificationRecord[]>([])
const maxHistorySize = 50 // Keep last 50 notifications

// Notification settings
export const notificationSettings = reactive({
  enabled: true,
  showDeployment: true,
  showConnectivity: true,
  showRotation: true,
  showSystem: true,
  showQuota: true,
  playSound: false, // Future: sound notifications
  desktopNotifications: false, // Future: desktop notifications via Wails
})

/**
 * Create a notification with history tracking
 */
export const notify = (
  type: NotificationType,
  category: NotificationCategory,
  title: string,
  messageText: string,
  options?: {
    duration?: number
    skipHistory?: boolean
  }
) => {
  // Check if this category is enabled
  const categoryKey = `show${category.charAt(0).toUpperCase() + category.slice(1)}` as keyof typeof notificationSettings
  if (!notificationSettings.enabled || !notificationSettings[categoryKey]) {
    return
  }

  // Show toast notification
  const toastMessage = title ? `${title}: ${messageText}` : messageText
  switch (type) {
    case 'success':
      message.success(toastMessage, options?.duration)
      break
    case 'error':
      message.error(toastMessage, options?.duration)
      break
    case 'warning':
      message.warn(toastMessage, options?.duration)
      break
    case 'info':
      message.info(toastMessage, options?.duration)
      break
  }

  // Add to history (unless skipped)
  if (!options?.skipHistory) {
    const record: NotificationRecord = {
      id: `${Date.now()}-${Math.random().toString(36).substring(7)}`,
      type,
      category,
      title,
      message: messageText,
      timestamp: Date.now(),
      read: false,
    }

    notificationHistory.unshift(record)

    // Trim history if it exceeds max size
    if (notificationHistory.length > maxHistorySize) {
      notificationHistory.splice(maxHistorySize)
    }
  }
}

/**
 * Notification shortcuts for common scenarios
 */
export const notifications = {
  // Deployment notifications
  deploymentStarted: (nodeName: string) => {
    notify('info', 'deployment', 'Deployment Started', `Creating node: ${nodeName}`)
  },

  deploymentComplete: (nodeName: string) => {
    notify('success', 'deployment', 'Deployment Complete', `Node ${nodeName} is ready`)
  },

  deploymentFailed: (nodeName: string, error: string) => {
    notify('error', 'deployment', 'Deployment Failed', `${nodeName}: ${error}`)
  },

  // Connectivity notifications
  connectivityTested: (nodeName: string, status: string) => {
    const type = status === 'reachable' ? 'success' : status === 'blocked' ? 'error' : 'warning'
    notify(type, 'connectivity', 'Connectivity Test', `${nodeName}: ${status}`)
  },

  connectivityBlocked: (nodeName: string) => {
    notify('error', 'connectivity', 'Node Blocked', `${nodeName} is completely blocked`)
  },

  connectivityRestored: (nodeName: string) => {
    notify('success', 'connectivity', 'Connectivity Restored', `${nodeName} is now reachable`)
  },

  allNodesTestComplete: (reachable: number, total: number) => {
    const type = reachable === total ? 'success' : reachable === 0 ? 'error' : 'warning'
    notify(type, 'connectivity', 'All Nodes Tested', `${reachable}/${total} nodes reachable`)
  },

  // IP Rotation notifications
  rotationStarted: (nodeName: string) => {
    notify('info', 'rotation', 'IP Rotation', `Starting IP rotation for ${nodeName}`)
  },

  rotationComplete: (nodeName: string) => {
    notify('success', 'rotation', 'IP Rotation Complete', `${nodeName} has a new IP address`)
  },

  rotationFailed: (nodeName: string, error: string) => {
    notify('error', 'rotation', 'IP Rotation Failed', `${nodeName}: ${error}`)
  },

  // System notifications
  cacheRefreshed: (dataType: string) => {
    notify('info', 'system', 'Data Refreshed', `${dataType} data updated`, { skipHistory: true })
  },

  apiKeyUpdated: () => {
    notify('success', 'system', 'API Key Updated', 'Cloud provider credentials saved')
  },

  configSaved: () => {
    notify('success', 'system', 'Configuration Saved', 'Cloud configuration saved successfully')
  },

  providerSwitched: (provider: string) => {
    notify('info', 'system', 'Provider Changed', `Switched to ${provider}`)
  },

  // Generic notifications
  info: (title: string, message: string) => {
    notify('info', 'system', title, message)
  },

  error: (title: string, message: string) => {
    notify('error', 'system', title, message)
  },

  // Quota warnings
  quotaWarning: (percentage: number) => {
    notify('warning', 'quota', 'API Quota Warning', `${percentage}% of API quota used`)
  },

  quotaExceeded: () => {
    notify('error', 'quota', 'API Quota Exceeded', 'API rate limit reached')
  },
}

/**
 * Get notification history
 */
export const getNotificationHistory = () => notificationHistory

/**
 * Clear notification history
 */
export const clearNotificationHistory = () => {
  notificationHistory.splice(0)
}

/**
 * Mark notification as read
 */
export const markNotificationRead = (id: string) => {
  const notification = notificationHistory.find(n => n.id === id)
  if (notification) {
    notification.read = true
  }
}

/**
 * Mark all notifications as read
 */
export const markAllNotificationsRead = () => {
  notificationHistory.forEach(n => n.read = true)
}

/**
 * Get unread notification count
 */
export const getUnreadCount = () => {
  return notificationHistory.filter(n => !n.read).length
}

/**
 * Filter notifications by category
 */
export const getNotificationsByCategory = (category: NotificationCategory) => {
  return notificationHistory.filter(n => n.category === category)
}

/**
 * Filter notifications by type
 */
export const getNotificationsByType = (type: NotificationType) => {
  return notificationHistory.filter(n => n.type === type)
}

/**
 * Save notification settings to localStorage
 */
export const saveNotificationSettings = () => {
  try {
    localStorage.setItem('notificationSettings', JSON.stringify(notificationSettings))
  } catch (error) {
    console.error('Failed to save notification settings:', error)
  }
}

/**
 * Load notification settings from localStorage
 */
export const loadNotificationSettings = () => {
  try {
    const saved = localStorage.getItem('notificationSettings')
    if (saved) {
      const settings = JSON.parse(saved)
      Object.assign(notificationSettings, settings)
    }
  } catch (error) {
    console.error('Failed to load notification settings:', error)
  }
}

// Auto-load settings on import
loadNotificationSettings()
