import { Api } from '@/api/kernel'
import { WebSockets, setIntervalImmediately } from '@/utils'

import type {
  CoreApiConnectionsData,
  CoreApiLogsData,
  CoreApiMemoryData,
  CoreApiTrafficData,
} from '@/types/kernel'

type ControllerInfo = {
  base: string
  bearer: string
}

type CreateKernelApiWebsocketManagerDeps = {
  getControllerInfo: () => ControllerInfo
}

export const createKernelApiWebsocketManager = ({
  getControllerInfo,
}: CreateKernelApiWebsocketManagerDeps) => {
  let websocketInstance: WebSockets | null = null

  const longLivedWS = {
    setup: undefined as (() => void) | undefined,
    cleanup: undefined as (() => void) | undefined,
    timer: -1,
  }
  const shortLivedWS = {
    setup: undefined as (() => void) | undefined,
    cleanup: undefined as (() => void) | undefined,
    timer: -1,
  }
  const onLogsEvents = {
    onFirst: undefined as (() => void) | undefined,
    onEmpty: undefined as (() => void) | undefined,
  }

  const websocketHandlers = {
    logs: [] as ((data: CoreApiLogsData) => void)[],
    memory: [] as ((data: CoreApiMemoryData) => void)[],
    traffic: [] as ((data: CoreApiTrafficData) => void)[],
    connections: [] as ((data: CoreApiConnectionsData) => void)[],
  } as const

  const createHandlerRegister = <S extends C[], C>(
    source: S,
    events: { onFirst?: () => void; onEmpty?: () => void } = {},
  ) => {
    const register = (cb: S[number]) => {
      source.push(cb)
      source.length === 1 && events.onFirst?.()
      const unregister = () => {
        const idx = source.indexOf(cb)
        idx !== -1 && source.splice(idx, 1)
        source.length === 0 && events.onEmpty?.()
      }
      return unregister
    }
    return register
  }

  const createDispatcher = <T>(source: ((data: T) => void)[]) => {
    return (data: T) => {
      source.forEach((cb) => cb(data))
    }
  }

  const destroy = () => {
    longLivedWS.cleanup?.()
    shortLivedWS.cleanup?.()
    websocketInstance = null
  }

  const init = () => {
    destroy()

    websocketInstance = new WebSockets({
      beforeConnect() {
        const { base, bearer } = getControllerInfo()
        this.base = base
        this.bearer = bearer
      },
    })

    const { connect: connectLongLived, disconnect: disconnectLongLived } =
      websocketInstance.createWS([
        {
          name: 'Memory',
          url: Api.Memory,
          cb: createDispatcher(websocketHandlers.memory),
        },
        {
          name: 'Traffic',
          url: Api.Traffic,
          cb: createDispatcher(websocketHandlers.traffic),
        },
        {
          name: 'Connections',
          url: Api.Connections,
          cb: createDispatcher(websocketHandlers.connections),
        },
      ])

    const { connect: connectShortLived, disconnect: disconnectShortLived } =
      websocketInstance.createWS([
        {
          name: 'Logs',
          url: Api.Logs,
          params: { level: 'debug' },
          cb: createDispatcher(websocketHandlers.logs),
        },
      ])

    longLivedWS.setup = () => {
      longLivedWS.timer = setIntervalImmediately(connectLongLived, 3_000)
    }
    longLivedWS.cleanup = () => {
      clearInterval(longLivedWS.timer)
      disconnectLongLived()
      longLivedWS.cleanup = undefined
    }

    shortLivedWS.setup = () => {
      shortLivedWS.timer = setIntervalImmediately(connectShortLived, 3_000)
    }
    shortLivedWS.cleanup = () => {
      clearInterval(shortLivedWS.timer)
      disconnectShortLived()
      shortLivedWS.cleanup = undefined
    }

    onLogsEvents.onFirst = shortLivedWS.setup
    onLogsEvents.onEmpty = shortLivedWS.cleanup

    if (websocketHandlers.logs.length > 0) {
      shortLivedWS.setup?.()
    }
  }

  return {
    connectLongLived: () => longLivedWS.setup?.(),
    destroy,
    init,
    onConnections: createHandlerRegister(websocketHandlers.connections),
    onLogs: createHandlerRegister(websocketHandlers.logs, onLogsEvents),
    onMemory: createHandlerRegister(websocketHandlers.memory),
    onTraffic: createHandlerRegister(websocketHandlers.traffic),
  }
}
