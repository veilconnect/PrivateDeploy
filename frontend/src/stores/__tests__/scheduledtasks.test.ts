import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { stringify } from 'yaml'

import { ScheduledTasksType } from '@/enums/app'

const mocks = vi.hoisted(() => ({
  cronInstances: [] as Array<{ cron: string; callback: () => void; stop: ReturnType<typeof vi.fn> }>,
  notify: vi.fn(),
  readFile: vi.fn(),
  recordScheduledTasksLog: vi.fn(),
  rulesetsUpdate: vi.fn(),
  pluginsManualTrigger: vi.fn(),
  pluginsUpdate: vi.fn(),
  subscribesUpdate: vi.fn(),
  writeFile: vi.fn(),
}))

vi.mock('croner', () => ({
  Cron: class {
    public stop = vi.fn()

    constructor(cron: string, callback: () => void) {
      mocks.cronInstances.push({ callback, cron, stop: this.stop })
    }
  },
}))

vi.mock('@/bridge', () => ({
  Notify: mocks.notify,
  ReadFile: mocks.readFile,
  WriteFile: mocks.writeFile,
}))

vi.mock('@/stores', () => ({
  useLogsStore: () => ({
    recordScheduledTasksLog: mocks.recordScheduledTasksLog,
  }),
  usePluginsStore: () => ({
    manualTrigger: mocks.pluginsManualTrigger,
    updatePlugin: mocks.pluginsUpdate,
  }),
  useRulesetsStore: () => ({
    updateRuleset: mocks.rulesetsUpdate,
  }),
  useSubscribesStore: () => ({
    updateSubscribe: mocks.subscribesUpdate,
  }),
}))

vi.mock('@/utils', () => ({
  ignoredError: async (fn: (...args: unknown[]) => Promise<unknown>, ...args: unknown[]) => {
    try {
      return await fn(...args)
    } catch {
      return undefined
    }
  },
  stringifyNoFolding: (value: unknown) => stringify(value),
}))

import { useScheduledTasksStore } from '../scheduledtasks'

import type { ScheduledTask } from '@/types/app'

const task = (overrides: Partial<ScheduledTask> = {}): ScheduledTask => ({
  cron: '*/5 * * * *',
  disabled: false,
  id: 'task-1',
  lastTime: 0,
  name: 'Task 1',
  notification: true,
  plugins: [],
  rulesets: [],
  script: '',
  subscriptions: ['sub-1'],
  type: ScheduledTasksType.UpdateSubscription,
  ...overrides,
})

describe('scheduled tasks store', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    setActivePinia(createPinia())
    mocks.cronInstances.length = 0

    mocks.notify.mockResolvedValue(undefined)
    mocks.readFile.mockRejectedValue(new Error('missing'))
    mocks.recordScheduledTasksLog.mockReturnValue(undefined)
    mocks.rulesetsUpdate.mockResolvedValue('ruleset updated')
    mocks.pluginsManualTrigger.mockResolvedValue('plugin ran')
    mocks.pluginsUpdate.mockResolvedValue('plugin updated')
    mocks.subscribesUpdate.mockResolvedValue('subscription updated')
    mocks.writeFile.mockResolvedValue(undefined)
    Object.defineProperty(window, 'AsyncFunction', {
      configurable: true,
      value: function AsyncFunctionMock(script: string) {
        return async () => `script:${script}`
      },
    })
  })

  it('loads enabled cron jobs from disk', async () => {
    mocks.readFile.mockResolvedValueOnce(stringify([
      task(),
      task({ disabled: true, id: 'disabled', name: 'Disabled' }),
    ]))

    const store = useScheduledTasksStore()
    await store.setupScheduledTasks()

    expect(store.scheduledtasks.map((item) => item.id)).toEqual(['task-1', 'disabled'])
    expect(mocks.cronInstances).toHaveLength(1)
    expect(mocks.cronInstances[0].cron).toBe('*/5 * * * *')
  })

  it('adds, edits, deletes, and rolls back cron jobs on failed writes', async () => {
    const store = useScheduledTasksStore()
    const first = task()

    await store.addScheduledTask(first)
    expect(store.getScheduledTaskById('task-1')).toEqual(first)
    expect(mocks.cronInstances).toHaveLength(1)

    await store.editScheduledTask('task-1', task({ cron: '0 * * * *', name: 'Edited' }))
    expect(mocks.cronInstances[0].stop).toHaveBeenCalled()
    expect(mocks.cronInstances[1].cron).toBe('0 * * * *')

    await store.deleteScheduledTask('task-1')
    expect(mocks.cronInstances[1].stop).toHaveBeenCalled()
    expect(store.scheduledtasks).toEqual([])

    mocks.writeFile.mockRejectedValueOnce(new Error('invalid cron'))
    await expect(store.addScheduledTask(task({ id: 'bad' }))).rejects.toThrow('invalid cron')
    expect(store.getScheduledTaskById('bad')).toBeUndefined()
    expect(mocks.cronInstances[2].stop).toHaveBeenCalled()
  })

  it('runs task functions, records logs, and sends notifications', async () => {
    vi.spyOn(Date, 'now')
      .mockReturnValueOnce(100)
      .mockReturnValueOnce(110)
      .mockReturnValueOnce(150)
    mocks.subscribesUpdate
      .mockResolvedValueOnce('sub-1 updated')
      .mockRejectedValueOnce(new Error('sub-2 failed'))
    const store = useScheduledTasksStore()
    store.scheduledtasks.push(task({ subscriptions: ['sub-1', 'sub-2'] }))

    await store.runScheduledTask('task-1')
    await Promise.resolve()

    expect(mocks.subscribesUpdate).toHaveBeenCalledWith('sub-1')
    expect(mocks.subscribesUpdate).toHaveBeenCalledWith('sub-2')
    expect(mocks.notify).toHaveBeenCalledWith('Task 1', 'sub-1 updated\nsub-2 failed')
    expect(mocks.recordScheduledTasksLog).toHaveBeenCalledWith({
      endTime: 150,
      name: 'Task 1',
      result: ['sub-1 updated', 'sub-2 failed'],
      startTime: 110,
    })
    expect(store.getScheduledTaskById('task-1')?.lastTime).toBe(100)
  })

  it('builds runners for rulesets, plugins, manual plugins, and scripts', async () => {
    const store = useScheduledTasksStore()

    await expect(store.getTaskFn(task({
      rulesets: ['ruleset-1'],
      type: ScheduledTasksType.UpdateRuleset,
    }))()).resolves.toEqual(['ruleset updated'])
    await expect(store.getTaskFn(task({
      plugins: ['plugin-1'],
      type: ScheduledTasksType.UpdatePlugin,
    }))()).resolves.toEqual(['plugin updated'])
    await expect(store.getTaskFn(task({
      plugins: ['plugin-1'],
      type: ScheduledTasksType.RunPlugin,
    }))()).resolves.toEqual(['plugin ran'])
    await expect(store.getTaskFn(task({
      script: 'return 42',
      type: ScheduledTasksType.RunScript,
    }))()).resolves.toEqual(['script:return 42'])

    expect(mocks.pluginsManualTrigger).toHaveBeenCalledWith('plugin-1', 'onTask')
  })
})
