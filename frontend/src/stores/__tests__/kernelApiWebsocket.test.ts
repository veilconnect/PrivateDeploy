import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  connectCalls: [] as string[],
  disconnectCalls: [] as string[],
  instances: [] as any[],
  intervalIds: [] as number[],
  nextIntervalId: 1,
}))

vi.mock('@/utils', () => ({
  setIntervalImmediately: (fn: () => void) => {
    fn()
    const id = mocks.nextIntervalId
    mocks.nextIntervalId += 1
    mocks.intervalIds.push(id)
    return id
  },
  WebSockets: class {
    public base = ''
    public bearer = ''
    public groups: any[][] = []
    public options: { beforeConnect?: () => void }

    constructor(options: { beforeConnect?: () => void }) {
      this.options = options
      mocks.instances.push(this)
    }

    createWS(configs: any[]) {
      this.groups.push(configs)
      return {
        connect: () => {
          this.options.beforeConnect?.call(this)
          mocks.connectCalls.push(configs.map((item) => item.name).join(','))
        },
        disconnect: () => {
          mocks.disconnectCalls.push(configs.map((item) => item.name).join(','))
        },
      }
    }
  },
}))

import { createKernelApiWebsocketManager } from '../kernelApiWebsocket'

describe('kernel api websocket manager', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.connectCalls.length = 0
    mocks.disconnectCalls.length = 0
    mocks.instances.length = 0
    mocks.intervalIds.length = 0
    mocks.nextIntervalId = 1
  })

  it('creates websocket groups, connects streams, and dispatches events', () => {
    const memory = vi.fn()
    const traffic = vi.fn()
    const connections = vi.fn()
    const logs = vi.fn()
    const manager = createKernelApiWebsocketManager({
      getControllerInfo: () => ({ base: 'ws://127.0.0.1:9090', bearer: 'secret' }),
    })

    const unregisterMemory = manager.onMemory(memory)
    manager.onTraffic(traffic)
    manager.onConnections(connections)
    const unregisterLogs = manager.onLogs(logs)

    manager.init()
    manager.connectLongLived()

    const instance = mocks.instances[0]
    expect(instance.base).toBe('ws://127.0.0.1:9090')
    expect(instance.bearer).toBe('secret')
    expect(mocks.connectCalls).toEqual([
      'Logs',
      'Memory,Traffic,Connections',
    ])

    const longLived = instance.groups[0]
    const shortLived = instance.groups[1]
    longLived.find((item: any) => item.name === 'Memory').cb({ inuse: 10 })
    longLived.find((item: any) => item.name === 'Traffic').cb({ up: 1 })
    longLived.find((item: any) => item.name === 'Connections').cb({ connections: [] })
    shortLived.find((item: any) => item.name === 'Logs').cb({ payload: 'log line' })

    expect(memory).toHaveBeenCalledWith({ inuse: 10 })
    expect(traffic).toHaveBeenCalledWith({ up: 1 })
    expect(connections).toHaveBeenCalledWith({ connections: [] })
    expect(logs).toHaveBeenCalledWith({ payload: 'log line' })

    unregisterMemory()
    longLived.find((item: any) => item.name === 'Memory').cb({ inuse: 20 })
    expect(memory).toHaveBeenCalledTimes(1)

    unregisterLogs()
    expect(mocks.disconnectCalls).toContain('Logs')

    manager.destroy()
    expect(mocks.disconnectCalls).toContain('Memory,Traffic,Connections')
  })

  it('reinitializes by destroying existing websocket streams first', () => {
    const manager = createKernelApiWebsocketManager({
      getControllerInfo: () => ({ base: 'ws://127.0.0.1:20123', bearer: '' }),
    })

    manager.init()
    manager.connectLongLived()
    manager.init()

    expect(mocks.instances).toHaveLength(2)
    expect(mocks.disconnectCalls).toContain('Memory,Traffic,Connections')
  })
})
