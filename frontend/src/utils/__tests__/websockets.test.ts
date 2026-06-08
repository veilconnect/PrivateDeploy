import { afterEach, describe, expect, it, vi } from 'vitest'

import { WebSockets } from '../websockets'

class FakeWebSocket {
  static instances: FakeWebSocket[] = []

  public onmessage: ((event: { data: string }) => void) | null = null
  public onerror: (() => void) | null = null
  public onclose: (() => void) | null = null
  public close = vi.fn(() => {
    this.onclose?.()
  })

  constructor(public url: string) {
    FakeWebSocket.instances.push(this)
  }
}

describe('WebSockets', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
    FakeWebSocket.instances = []
  })

  it('creates authenticated sockets and dispatches parsed messages', () => {
    vi.stubGlobal('WebSocket', FakeWebSocket)
    const beforeConnect = vi.fn()
    const onNodes = vi.fn()
    const params = { topic: 'cloud nodes' }

    const sockets = new WebSockets({
      base: 'wss://api.example.test',
      bearer: 'secret-token',
      beforeConnect,
    }).createWS([
      { name: 'nodes', url: '/ws/nodes', params, cb: onNodes },
    ])

    expect(beforeConnect).toHaveBeenCalledTimes(1)

    sockets.connect()
    sockets.connect()

    expect(FakeWebSocket.instances).toHaveLength(1)
    expect(FakeWebSocket.instances[0].url).toBe(
      'wss://api.example.test/ws/nodes?topic=cloud+nodes&token=secret-token',
    )
    expect(params).toEqual({ topic: 'cloud nodes', token: 'secret-token' })

    FakeWebSocket.instances[0].onmessage?.({ data: '{"status":"ok"}' })
    expect(onNodes).toHaveBeenCalledWith({ status: 'ok' })
  })

  it('reconnects after errors and closes active sockets on disconnect', () => {
    vi.stubGlobal('WebSocket', FakeWebSocket)
    const onMessage = vi.fn()
    const sockets = new WebSockets({ base: 'wss://api.example.test' }).createWS([
      { name: 'events', url: '/ws/events', cb: onMessage },
    ])

    sockets.connect()
    expect(FakeWebSocket.instances).toHaveLength(1)

    FakeWebSocket.instances[0].onerror?.()
    sockets.connect()
    expect(FakeWebSocket.instances).toHaveLength(2)

    sockets.disconnect()
    expect(FakeWebSocket.instances[1].close).toHaveBeenCalledTimes(1)

    sockets.connect()
    expect(FakeWebSocket.instances).toHaveLength(3)
  })

  it('keeps disconnected entries from opening until ready is restored', () => {
    vi.stubGlobal('WebSocket', FakeWebSocket)
    const sockets = new WebSockets({}).createWS([
      { name: 'events', url: '/ws/events', cb: vi.fn() },
    ])

    sockets.disconnect()
    sockets.connect()

    expect(FakeWebSocket.instances).toHaveLength(0)
  })
})
