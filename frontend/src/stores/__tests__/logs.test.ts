import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it } from 'vitest'

import { useLogsStore } from '../logs'

describe('logs store', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('records and clears kernel and scheduled task logs', () => {
    const store = useLogsStore()

    expect(store.isEmpty).toBe(true)
    expect(store.isTasksLogEmpty).toBe(true)

    store.recordKernelLog('core started')
    store.recordKernelLog('proxy ready')
    store.recordScheduledTasksLog({
      endTime: 2,
      name: 'nightly',
      result: ['ok'],
      startTime: 1,
    })

    expect(store.kernelLogs).toEqual(['proxy ready', 'core started'])
    expect(store.scheduledtasksLogs[0]).toMatchObject({ name: 'nightly', result: ['ok'] })
    expect(store.isEmpty).toBe(false)
    expect(store.isTasksLogEmpty).toBe(false)

    store.clearKernelLog()
    expect(store.kernelLogs).toEqual([])
    expect(store.isEmpty).toBe(true)
  })
})
