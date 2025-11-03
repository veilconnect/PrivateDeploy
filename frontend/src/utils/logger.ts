const formatArgs = (args: unknown[]) =>
  args.map((arg) => {
    if (arg instanceof Error) {
      return `${arg.message}\n${arg.stack || ''}`.trim()
    }
    if (typeof arg === 'object') {
      try {
        return JSON.stringify(arg)
      } catch {
        return String(arg)
      }
    }
    return String(arg)
  })

const logToRuntime = (level: 'Log' | 'LogInfo' | 'LogError' | 'LogWarning', message: string) => {
  const runtime = (window as any)?.runtime
  const method = runtime?.[level]
  if (typeof method === 'function') {
    method.call(runtime, message)
  }
}

const emitLog = (level: 'info' | 'warn' | 'error', args: unknown[]) => {
  const formatted = formatArgs(args)
  const prefix = '[PrivateDeploy]'
  const joined = `${prefix} ${formatted.join(' ')}`
  switch (level) {
    case 'error':
      console.error(prefix, ...formatted)
      logToRuntime('LogError', joined)
      break
    case 'warn':
      console.warn(prefix, ...formatted)
      logToRuntime('LogWarning', joined)
      break
    default:
      console.info(prefix, ...formatted)
      logToRuntime('LogInfo', joined)
  }
}

export const logError = (...args: unknown[]) => emitLog('error', args)

export const logInfo = (...args: unknown[]) => emitLog('info', args)

export const logWarn = (...args: unknown[]) => emitLog('warn', args)
