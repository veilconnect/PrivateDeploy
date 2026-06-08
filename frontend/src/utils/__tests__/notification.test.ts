import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  message: {
    error: vi.fn(),
    info: vi.fn(),
    success: vi.fn(),
    warn: vi.fn(),
  },
}))

vi.mock('@/utils', () => ({
  message: mocks.message,
}))

import {
  clearNotificationHistory,
  getNotificationHistory,
  getNotificationsByCategory,
  getNotificationsByType,
  getUnreadCount,
  loadNotificationSettings,
  markAllNotificationsRead,
  markNotificationRead,
  notificationSettings,
  notifications,
  notify,
  saveNotificationSettings,
} from '../notification'

const resetSettings = () => {
  Object.assign(notificationSettings, {
    desktopNotifications: false,
    enabled: true,
    playSound: false,
    showConnectivity: true,
    showDeployment: true,
    showQuota: true,
    showRotation: true,
    showSystem: true,
  })
}

describe('notification utilities', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    localStorage.clear()
    clearNotificationHistory()
    resetSettings()
  })

  it('routes toast messages, records bounded history, and respects disabled categories', () => {
    notify('success', 'deployment', 'Deployment Complete', 'Node sg-1 is ready', {
      duration: 1200,
    })

    expect(mocks.message.success).toHaveBeenCalledWith(
      'Deployment Complete: Node sg-1 is ready',
      1200,
    )
    expect(getNotificationHistory()[0]).toMatchObject({
      category: 'deployment',
      message: 'Node sg-1 is ready',
      read: false,
      title: 'Deployment Complete',
      type: 'success',
    })

    notify('info', 'system', '', 'Background refresh finished', { skipHistory: true })

    expect(mocks.message.info).toHaveBeenCalledWith('Background refresh finished', undefined)
    expect(getNotificationHistory()).toHaveLength(1)

    mocks.message.success.mockClear()
    notificationSettings.showDeployment = false
    notify('success', 'deployment', 'Ignored', 'Category disabled')

    expect(mocks.message.success).not.toHaveBeenCalled()
    expect(getNotificationHistory()).toHaveLength(1)

    notificationSettings.showDeployment = true
    for (let i = 0; i < 55; i += 1) {
      notify('info', 'system', 'Event', `Item ${i}`)
    }

    expect(getNotificationHistory()).toHaveLength(50)
    expect(getNotificationHistory()[0].message).toBe('Item 54')
  })

  it('exposes shortcuts for deployment, connectivity, rotation, system, and quota events', () => {
    notifications.deploymentStarted('sg-1')
    notifications.deploymentComplete('sg-1')
    notifications.deploymentFailed('sg-1', 'quota exceeded')
    notifications.connectivityTested('sg-1', 'reachable')
    notifications.connectivityTested('sg-2', 'blocked')
    notifications.connectivityTested('sg-3', 'unknown')
    notifications.connectivityBlocked('sg-2')
    notifications.connectivityRestored('sg-1')
    notifications.allNodesTestComplete(3, 3)
    notifications.allNodesTestComplete(0, 3)
    notifications.allNodesTestComplete(2, 3)
    notifications.rotationStarted('sg-1')
    notifications.rotationComplete('sg-1')
    notifications.rotationFailed('sg-1', 'provider error')
    notifications.cacheRefreshed('Node')
    notifications.apiKeyUpdated()
    notifications.configSaved()
    notifications.providerSwitched('Vultr')
    notifications.info('Heads up', 'Maintenance window')
    notifications.error('Failure', 'Command failed')
    notifications.quotaWarning(80)
    notifications.quotaExceeded()

    expect(mocks.message.info).toHaveBeenCalledWith(
      'Deployment Started: Creating node: sg-1',
      undefined,
    )
    expect(mocks.message.success).toHaveBeenCalledWith(
      'Deployment Complete: Node sg-1 is ready',
      undefined,
    )
    expect(mocks.message.error).toHaveBeenCalledWith(
      'Deployment Failed: sg-1: quota exceeded',
      undefined,
    )
    expect(mocks.message.warn).toHaveBeenCalledWith(
      'Connectivity Test: sg-3: unknown',
      undefined,
    )
    expect(mocks.message.warn).toHaveBeenCalledWith(
      'All Nodes Tested: 2/3 nodes reachable',
      undefined,
    )
    expect(mocks.message.error).toHaveBeenCalledWith(
      'API Quota Exceeded: API rate limit reached',
      undefined,
    )
    expect(getNotificationHistory()).toHaveLength(21)
    expect(getNotificationsByCategory('connectivity')).toHaveLength(8)
    expect(getNotificationsByType('error').length).toBeGreaterThan(0)
  })

  it('marks, counts, filters, and clears notification history', () => {
    notify('info', 'system', 'First', 'Message one')
    notify('error', 'quota', 'Second', 'Message two')

    const [latest, oldest] = getNotificationHistory()
    expect(getUnreadCount()).toBe(2)
    expect(getNotificationsByCategory('quota')).toEqual([latest])
    expect(getNotificationsByType('info')).toEqual([oldest])

    markNotificationRead(latest.id)
    expect(latest.read).toBe(true)
    expect(getUnreadCount()).toBe(1)

    markNotificationRead('missing-id')
    markAllNotificationsRead()
    expect(getUnreadCount()).toBe(0)

    clearNotificationHistory()
    expect(getNotificationHistory()).toHaveLength(0)
  })

  it('persists notification settings and handles malformed storage safely', () => {
    notificationSettings.enabled = false
    notificationSettings.showQuota = false

    saveNotificationSettings()

    notificationSettings.enabled = true
    notificationSettings.showQuota = true
    loadNotificationSettings()

    expect(notificationSettings.enabled).toBe(false)
    expect(notificationSettings.showQuota).toBe(false)

    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => undefined)
    localStorage.setItem('notificationSettings', '{bad json')

    loadNotificationSettings()

    expect(errorSpy).toHaveBeenCalledWith(
      'Failed to load notification settings:',
      expect.any(SyntaxError),
    )

    const originalSetItem = localStorage.setItem
    localStorage.setItem = vi.fn(() => {
      throw new Error('quota exceeded')
    })

    saveNotificationSettings()

    expect(errorSpy).toHaveBeenCalledWith(
      'Failed to save notification settings:',
      expect.any(Error),
    )

    localStorage.setItem = originalSetItem
    errorSpy.mockRestore()
  })
})
