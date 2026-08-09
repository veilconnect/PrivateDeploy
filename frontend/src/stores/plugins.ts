import { defineStore } from 'pinia'
import { computed, ref, watch } from 'vue'
import { parse, stringify } from 'yaml'

import { HttpGet, ReadFile, RemoveFile, WriteFile } from '@/bridge'
import { PluginHubFilePath, PluginsFilePath } from '@/constant/app'
import { PluginTrigger, PluginTriggerEvent } from '@/enums/app'
import { useAppSettingsStore } from '@/stores'
import {
  debounce,
  ignoredError,
  updateTrayMenus,
  isNumber,
  omitArray,
  deepClone,
  confirm,
  asyncPool,
} from '@/utils'

import {
  clearPluginTrustConsent,
  confirmPluginFullTrust,
  fetchAllowedPluginCode,
  hasPluginTrustConsent,
  markPluginTrustConsent,
  sha256Hex,
} from './pluginSecurity'

import type { Plugin, Subscription } from '@/types/app'

const PluginsCache: Recordable<{ plugin: Plugin; code: string }> = {}

// Startup hooks run after the workspace is visible, but they still execute in
// registration order. Bound each plugin independently so one plugin that
// returns a never-settling promise cannot prevent every later startup plugin
// from running. Hooks whose callers rely on completion/cancellation semantics
// (shutdown, before-stop, manual execution, and transforms) deliberately keep
// their existing unbounded behaviour.
export const STARTUP_PLUGIN_EXECUTION_TIMEOUT_MS = 5_000

const waitForPluginWithTimeout = <T>(
  execution: Promise<T>,
  timeoutMs: number,
  pluginName: string,
): Promise<T> =>
  new Promise<T>((resolve, reject) => {
    let settled = false
    const timer = window.setTimeout(() => {
      if (settled) return
      settled = true
      reject(new Error(`${pluginName} timed out after ${timeoutMs}ms`))
    }, timeoutMs)

    execution.then(
      (value) => {
        if (settled) return
        settled = true
        window.clearTimeout(timer)
        resolve(value)
      },
      (error) => {
        if (settled) return
        settled = true
        window.clearTimeout(timer)
        reject(error)
      },
    )
  })

const PluginsTriggerMap: {
  [key in PluginTrigger]: {
    fnName: PluginTriggerEvent
    observers: string[]
  }
} = {
  [PluginTrigger.OnManual]: {
    fnName: PluginTriggerEvent.OnManual,
    observers: [],
  },
  [PluginTrigger.OnSubscribe]: {
    fnName: PluginTriggerEvent.OnSubscribe,
    observers: [],
  },
  [PluginTrigger.OnGenerate]: {
    fnName: PluginTriggerEvent.OnGenerate,
    observers: [],
  },
  [PluginTrigger.OnStartup]: {
    fnName: PluginTriggerEvent.OnStartup,
    observers: [],
  },
  [PluginTrigger.OnShutdown]: {
    fnName: PluginTriggerEvent.OnShutdown,
    observers: [],
  },
  [PluginTrigger.OnReady]: {
    fnName: PluginTriggerEvent.OnReady,
    observers: [],
  },
  [PluginTrigger.OnCoreStarted]: {
    fnName: PluginTriggerEvent.OnCoreStarted,
    observers: [],
  },
  [PluginTrigger.OnCoreStopped]: {
    fnName: PluginTriggerEvent.OnCoreStopped,
    observers: [],
  },
  [PluginTrigger.OnBeforeCoreStart]: {
    fnName: PluginTriggerEvent.OnBeforeCoreStart,
    observers: [],
  },
  [PluginTrigger.OnBeforeCoreStop]: {
    fnName: PluginTriggerEvent.OnBeforeCoreStop,
    observers: [],
  },
}

export const usePluginsStore = defineStore('plugins', () => {
  const appSettingsStore = useAppSettingsStore()

  const plugins = ref<Plugin[]>([])
  const pluginHub = ref<Plugin[]>([])

  const sanitizePluginHub = (value: unknown): Plugin[] => {
    if (!Array.isArray(value)) return []
    return value.map((item) => {
      const plugin = deepClone(item) as Plugin
      if (plugin && typeof plugin === 'object') clearPluginTrustConsent(plugin)
      return plugin
    })
  }

  const setupPlugins = async () => {
    // setupPlugins may be re-run after settings/import changes. Rebuild the
    // execution registry from the persisted list so removed or unconfirmed
    // plugins cannot survive in module-level caches from an earlier setup.
    for (const id of Object.keys(PluginsCache)) delete PluginsCache[id]
    for (const trigger of Object.values(PluginsTriggerMap)) trigger.observers = []

    const data = await ignoredError(ReadFile, PluginsFilePath)
    data && (plugins.value = parse(data))

    const list = await ignoredError(ReadFile, PluginHubFilePath)
    list && (pluginHub.value = sanitizePluginHub(JSON.parse(list)))

    for (let i = 0; i < plugins.value.length; i++) {
      const { id, triggers, path, context, hasUI, tags } = plugins.value[i]

      // Persisted plugins from versions before the trust disclosure must not
      // enter the execution cache or register trigger observers until the
      // user has accepted the current disclosure version.
      if (!(await ensurePluginTrustConsent(plugins.value[i]))) continue

      const code = await ignoredError(ReadFile, path)
      if (code) {
        // Verify the on-disk code against the pinned hash. A mismatch (possible
        // tampering) keeps the plugin out of the execution cache so it can't
        // run. A plugin with no pin yet establishes its baseline here (TOFU).
        let trusted = true
        if (plugins.value[i].codeHash) {
          trusted = (await sha256Hex(code)) === plugins.value[i].codeHash
          if (!trusted) {
            console.error(
              `[plugins] ${id}: code hash mismatch — refusing to load (possible tampering)`,
            )
          }
        } else {
          plugins.value[i].codeHash = await sha256Hex(code)
        }
        if (trusted) {
          PluginsCache[id] = { plugin: plugins.value[i], code }
          triggers.forEach((trigger) => {
            PluginsTriggerMap[trigger].observers.push(id)
          })
        }
      }

      if (!context) {
        plugins.value[i].context = {
          profiles: {},
          subscriptions: {},
          rulesets: {},
          plugins: {},
          scheduledtasks: {},
        }
      }

      if (hasUI === undefined) {
        plugins.value[i].hasUI = false
      }

      if (tags === undefined) {
        plugins.value[i].tags = []
      }
    }

    pluginHub.value.forEach((plugin) => {
      if (plugin.tags === undefined) {
        plugin.tags = []
      }
    })
  }

  const getPluginMetadata = (plugin: Plugin) => {
    let configuration = appSettingsStore.app.pluginSettings[plugin.id]
    if (!configuration) {
      configuration = {}
      plugin.configuration.forEach(({ key, value }) => (configuration[key] = value))
    }
    return { ...plugin, ...configuration }
  }

  const isPluginUnavailable = (cache: any) => {
    return (
      !cache ||
      !cache.plugin ||
      cache.plugin.disabled ||
      (cache.plugin.install && !cache.plugin.installed)
    )
  }

  const reloadPlugin = async (plugin: Plugin, code = '', reloadTrigger = false) => {
    const { path } = plugin
    // An explicit `code` argument is a deliberate edit from the in-app editor;
    // an empty one means re-read the on-disk file (the "reload" action).
    const isExplicitEdit = code !== ''
    if (!code) {
      code = await ReadFile(path)
    }
    // Enforce the SHA-256 pin before the code enters the execution cache.
    // Without this, a tampered on-disk file would run on reload, defeating the
    // load-time pin. A deliberate editor edit re-establishes the pin; a passive
    // reload whose code drifted from the pin must be re-approved.
    const newHash = await sha256Hex(code)
    const stored = plugins.value.find((p) => p.id === plugin.id)
    const pinned = stored?.codeHash ?? plugin.codeHash
    if (!isExplicitEdit && pinned && pinned !== newHash) {
      const ok = await confirm('Tips', 'plugins.codeChanged').catch(() => false)
      if (!ok) throw `Plugin [${plugin.name}] code changed; reload rejected.`
    }
    plugin.codeHash = newHash
    if (stored) {
      stored.codeHash = newHash
      savePlugins()
    }
    PluginsCache[plugin.id] = { plugin, code }
    reloadTrigger && updatePluginTrigger(plugin)
  }

  const updatePluginTrigger = (plugin: Plugin, isUpdate = true) => {
    const triggers = Object.keys(PluginsTriggerMap) as PluginTrigger[]
    triggers.forEach((trigger) => {
      PluginsTriggerMap[trigger].observers = PluginsTriggerMap[trigger].observers.filter(
        (v) => v !== plugin.id,
      )
    })
    if (isUpdate) {
      // Maintain execution order consistent with the plugins list
      const pluginIndex = plugins.value.findIndex((p) => p.id === plugin.id)
      plugin.triggers.forEach((trigger) => {
        const observers = PluginsTriggerMap[trigger].observers
        // Insert at the correct position to preserve plugin list order
        const insertAt = observers.findIndex((id) => {
          const idx = plugins.value.findIndex((p) => p.id === id)
          return idx === -1 || idx > pluginIndex
        })
        if (insertAt === -1) {
          observers.push(plugin.id)
        } else {
          observers.splice(insertAt, 0, plugin.id)
        }
      })
    }
  }

  const persistPlugins = async () => {
    const p = omitArray(plugins.value, ['updating', 'loading', 'running'])
    await WriteFile(PluginsFilePath, stringify(p))
  }

  const savePlugins = debounce(persistPlugins, 100)

  // Plugins whose full-trust dialog was declined in this session. Prevents an
  // event-driven trigger sweep (startup, core start, subscribe, …) from
  // re-prompting on every event; an explicitly user-initiated action
  // (installing, running manually) always prompts again via `reprompt`.
  const trustConsentDeclined = new Set<string>()

  // Single choke point for the full-trust informed consent. EVERY path that
  // installs a plugin (Plugin-Hub Install button, manual File/Http form) or
  // lets one execute (trigger sweeps, manual runs) funnels through here:
  //  - a plugin that already confirmed the current consent version passes;
  //  - anything else — including plugins installed before the consent
  //    mechanism existed, whose persisted record has no consent field —
  //    gets the same complete disclosure dialog first;
  //  - accepting persists the confirmed version so the dialog is one-time;
  //  - declining means the plugin must not register/execute.
  const ensurePluginTrustConsent = async (
    plugin: Plugin,
    options: { reprompt?: boolean; okText?: string; message?: string } = {},
  ): Promise<boolean> => {
    if (hasPluginTrustConsent(plugin)) return true
    if (!options.reprompt && trustConsentDeclined.has(plugin.id)) return false
    const accepted = await confirmPluginFullTrust(confirm, plugin, {
      okText: options.okText,
      message: options.message,
    })
    if (!accepted) {
      trustConsentDeclined.add(plugin.id)
      return false
    }
    trustConsentDeclined.delete(plugin.id)
    markPluginTrustConsent(plugin)
    const stored = plugins.value.find((p) => p.id === plugin.id)
    if (stored) {
      if (stored !== plugin) markPluginTrustConsent(stored)
      // Consent is a security decision, so it must reach durable storage
      // before any plugin code is registered or executed. Do not use the
      // debounced best-effort settings writer for this transition.
      await persistPlugins()
    }
    return true
  }

  const addPlugin = async (plugin: Plugin) => {
    // Informed consent BEFORE any code is fetched or pinned: plugins run as
    // fully trusted code (files, network, native commands — no sandbox), so
    // adding one must be an explicit, eyes-open decision. Cancelling aborts
    // the add entirely. See pluginSecurity.ts for the trust model.
    // The object may originate in Plugin-Hub JSON, an import, or a manual
    // caller. Never honor a consent marker supplied by that untrusted object.
    clearPluginTrustConsent(plugin)
    const accepted = await ensurePluginTrustConsent(plugin, { reprompt: true })
    if (!accepted) throw 'common.canceled'

    plugins.value.push(plugin)
    try {
      await _doUpdatePlugin(plugin)
      await savePlugins()
      updatePluginTrigger(plugin)
    } catch (error) {
      plugins.value.pop()
      throw error
    }
  }

  const deletePlugin = async (id: string) => {
    const idx = plugins.value.findIndex((v) => v.id === id)
    if (idx === -1) return
    const plugin = plugins.value.splice(idx, 1)[0]
    try {
      await savePlugins()
      delete PluginsCache[id]
      updatePluginTrigger(plugin, false)
    } catch (error) {
      plugins.value.splice(idx, 0, plugin)
      throw error
    }
    plugin.path.startsWith('data') && RemoveFile(plugin.path)
    // Remove configuration
    if (appSettingsStore.app.pluginSettings[plugin.id]) {
      if (await confirm('Tips', 'plugins.removeConfiguration').catch(() => 0)) {
        delete appSettingsStore.app.pluginSettings[plugin.id]
      }
    }
  }

  const editPlugin = async (id: string, newPlugin: Plugin) => {
    const idx = plugins.value.findIndex((v) => v.id === id)
    if (idx === -1) return
    // New metadata is untrusted. Strip any supplied marker first, then inherit
    // only an exact-current marker already stored locally for this identity.
    // Capture before clearing because some internal updates pass the same
    // object as both the old and new record.
    const inheritLocalConsent = hasPluginTrustConsent(plugins.value[idx])
    clearPluginTrustConsent(newPlugin)
    if (inheritLocalConsent) markPluginTrustConsent(newPlugin)
    const plugin = plugins.value.splice(idx, 1, newPlugin)[0]
    try {
      await savePlugins()
      updatePluginTrigger(newPlugin)
    } catch (error) {
      plugins.value.splice(idx, 1, plugin)
      throw error
    }
  }

  const _doUpdatePlugin = async (plugin: Plugin) => {
    const isFromPluginHub = plugin.id.startsWith('plugin-')
    if (isFromPluginHub) {
      const newPlugin = pluginHub.value.find((v) => v.id === plugin.id)
      if (!newPlugin) throw 'Plugin not found. Please update the Plugin-Hub.'

      const [major_now, minor_now, patch_now] = (plugin.version || '').substring(1).split('.')
      const [major_new, minor_new, patch_new] = (newPlugin.version || '').substring(1).split('.')

      if (major_now !== major_new) {
        await editPlugin(plugin.id, deepClone(newPlugin))
        const userSettigns = appSettingsStore.app.pluginSettings[plugin.id]
        if (userSettigns) {
          appSettingsStore.app.pluginSettings[plugin.id] = newPlugin.configuration.reduce(
            (p, c) => {
              const value_now = userSettigns[c.key]
              const value_new = c.value
              const type_now = Array.isArray(value_now) ? 'array' : typeof value_now
              const type_new = Array.isArray(value_new) ? 'array' : typeof value_new
              return {
                ...p,
                [c.key]: type_now === type_new ? value_now : value_new,
              }
            },
            {},
          )
        }
      } else if (minor_now !== minor_new || patch_now !== patch_new) {
        plugin.version = newPlugin.version
        await editPlugin(plugin.id, plugin)
      }
    }

    let code = ''

    if (plugin.type === 'File') {
      code = await ReadFile(plugin.path).catch(() => '')
    }

    if (plugin.type === 'Http') {
      code = await fetchAllowedPluginCode(plugin.url)
    }

    // Pin the code by SHA-256. First install records the hash (trust-on-first-
    // use); a later change to the fetched/loaded code must be re-approved
    // before it replaces the trusted copy.
    if (code) {
      const newHash = await sha256Hex(code)
      if (plugin.codeHash && plugin.codeHash !== newHash) {
        const ok = await confirm('Tips', 'plugins.codeChanged').catch(() => false)
        if (!ok) throw `Plugin [${plugin.name}] code changed; update rejected.`
      }
      plugin.codeHash = newHash
    }

    if (plugin.type !== 'File') {
      await WriteFile(plugin.path, code)
    }

    PluginsCache[plugin.id] = { plugin, code }
  }

  const updatePlugin = async (id: string) => {
    const plugin = plugins.value.find((v) => v.id === id)
    if (!plugin) throw id + ' Not Found'
    if (plugin.disabled) throw plugin.name + ' is Disabled'
    try {
      plugin.updating = true
      await _doUpdatePlugin(plugin)
      return `Plugin [${plugin.name}] updated successfully.`
    } finally {
      plugin.updating = false
    }
  }

  const updatePlugins = async () => {
    let needSave = false

    const update = async (plugin: Plugin) => {
      try {
        plugin.updating = true
        await _doUpdatePlugin(plugin)
        needSave = true
      } finally {
        plugin.updating = false
      }
    }

    await asyncPool(
      5,
      plugins.value.filter((v) => !v.disabled),
      update,
    )

    if (needSave) savePlugins()
  }

  const pluginHubLoading = ref(false)
  const findPluginInHubById = (id: string) => pluginHub.value.find((v) => v.id === id)
  const isDeprecated = (plugin: Plugin) => {
    if (!plugin.id.startsWith('plugin-')) return false
    return !findPluginInHubById(plugin.id)
  }
  const hasNewPluginVersion = (plugin: Plugin) => {
    const p = findPluginInHubById(plugin.id)
    if (!p) return false
    return p.version !== plugin.version
  }
  const updatePluginHub = async () => {
    pluginHubLoading.value = true
    try {
      const { body: body1 } = await HttpGet<string>(
        'https://raw.githubusercontent.com/GUI-for-Cores/Plugin-Hub/main/plugins/generic.json',
      )
      const { body: body2 } = await HttpGet<string>(
        'https://raw.githubusercontent.com/GUI-for-Cores/Plugin-Hub/main/plugins/gfs.json',
      )
      pluginHub.value = sanitizePluginHub([...JSON.parse(body1), ...JSON.parse(body2)])
      await WriteFile(PluginHubFilePath, JSON.stringify(pluginHub.value))
    } finally {
      pluginHubLoading.value = false
    }
  }

  const getPluginById = (id: string) => plugins.value.find((v) => v.id === id)

  const getPluginCodefromCache = (id: string) => PluginsCache[id]?.code

  const onSubscribeTrigger = async (proxies: Record<string, any>[], subscription: Subscription) => {
    const { fnName, observers } = PluginsTriggerMap[PluginTrigger.OnSubscribe]

    let result = proxies

    for (let i = 0; i < observers.length; i++) {
      const pluginId = observers[i]
      const cache = PluginsCache[pluginId]

      if (isPluginUnavailable(cache)) continue
      // Pre-consent plugins (installed before the consent mechanism, or a
      // bumped consent version) must confirm the full-trust disclosure before
      // their first execution; a decline skips them without failing the sweep.
      if (!(await ensurePluginTrustConsent(cache.plugin))) continue

      const metadata = getPluginMetadata(cache.plugin)
      try {
        const fn = new window.AsyncFunction(`const Plugin = ${JSON.stringify(metadata)};
          ${cache.code};
          return await ${fnName}(${JSON.stringify(result)}, ${JSON.stringify(subscription)})
        `) as <T>(params: T) => Promise<T>
        result = await fn(result)
      } catch (error: any) {
        throw `${cache.plugin.name} : ` + (error.message || error)
      }

      if (!Array.isArray(result)) {
        throw `${cache.plugin.name} : Wrong result`
      }
    }

    return result
  }

  const noParamsTrigger = async (
    trigger: PluginTrigger,
    options: { interruptOnError?: boolean; pluginTimeoutMs?: number } = {},
  ) => {
    const { interruptOnError = false, pluginTimeoutMs } = options
    const { fnName, observers } = PluginsTriggerMap[trigger]
    if (observers.length === 0) return

    for (let i = 0; i < observers.length; i++) {
      const pluginId = observers[i]
      const cache = PluginsCache[pluginId]

      if (isPluginUnavailable(cache)) continue
      // Pre-consent plugins (installed before the consent mechanism, or a
      // bumped consent version) must confirm the full-trust disclosure before
      // their first execution; a decline skips them without failing the sweep.
      if (!(await ensurePluginTrustConsent(cache.plugin))) continue

      const metadata = getPluginMetadata(cache.plugin)
      try {
        const fn = new window.AsyncFunction(
          `const Plugin = ${JSON.stringify(metadata)}; ${cache.code}; return await ${fnName}()`,
        )
        const execution = Promise.resolve(fn())
        const exitCode = pluginTimeoutMs
          ? await waitForPluginWithTimeout(execution, pluginTimeoutMs, cache.plugin.name)
          : await execution
        if (isNumber(exitCode) && exitCode !== cache.plugin.status) {
          cache.plugin.status = exitCode
          editPlugin(cache.plugin.id, cache.plugin)
        }
      } catch (error: any) {
        const msg = `${cache.plugin.name} : ` + (error.message || error)
        if (interruptOnError) {
          throw msg
        }
        console.error(msg)
      }
    }
  }

  const onGenerateTrigger = async (params: Record<string, any>, profile: IProfile) => {
    const { fnName, observers } = PluginsTriggerMap[PluginTrigger.OnGenerate]
    if (observers.length === 0) return params

    for (let i = 0; i < observers.length; i++) {
      const pluginId = observers[i]
      const cache = PluginsCache[pluginId]

      if (isPluginUnavailable(cache)) continue
      // Pre-consent plugins (installed before the consent mechanism, or a
      // bumped consent version) must confirm the full-trust disclosure before
      // their first execution; a decline skips them without failing the sweep.
      if (!(await ensurePluginTrustConsent(cache.plugin))) continue

      const metadata = getPluginMetadata(cache.plugin)
      try {
        const fn = new window.AsyncFunction(
          `const Plugin = ${JSON.stringify(metadata)}; ${cache.code}; return await ${fnName}(${JSON.stringify(params)}, ${JSON.stringify(profile)})`,
        )
        params = await fn()
      } catch (error: any) {
        throw `${cache.plugin.name} : ` + (error.message || error)
      }

      if (!params) throw `${cache.plugin.name} : Wrong result`
    }

    return params as Record<string, any>
  }

  const onBeforeCoreStartTrigger = async (params: Record<string, any>, profile: IProfile) => {
    const { fnName, observers } = PluginsTriggerMap[PluginTrigger.OnBeforeCoreStart]
    if (observers.length === 0) return params

    for (let i = 0; i < observers.length; i++) {
      const pluginId = observers[i]
      const cache = PluginsCache[pluginId]

      if (isPluginUnavailable(cache)) continue
      // Pre-consent plugins (installed before the consent mechanism, or a
      // bumped consent version) must confirm the full-trust disclosure before
      // their first execution; a decline skips them without failing the sweep.
      if (!(await ensurePluginTrustConsent(cache.plugin))) continue

      const metadata = getPluginMetadata(cache.plugin)
      try {
        const fn = new window.AsyncFunction(
          `const Plugin = ${JSON.stringify(metadata)}; ${cache.code}; return await ${fnName}(${JSON.stringify(params)}, ${JSON.stringify(profile)})`,
        )
        params = await fn()
      } catch (error: any) {
        throw `${cache.plugin.name} : ` + (error.message || error)
      }

      if (!params) throw `${cache.plugin.name} : Wrong result`
    }

    return params as Record<string, any>
  }

  const manualTrigger = async (id: string, event: PluginTriggerEvent, ...args: any[]) => {
    const plugin = getPluginById(id)
    if (!plugin) throw id + ' Not Found'

    // A manual run is user-initiated, so always re-offer the dialog even if
    // it was declined earlier in the session.
    const accepted = await ensurePluginTrustConsent(plugin, { reprompt: true })
    if (!accepted) throw 'common.canceled'

    // A legacy plugin declined during startup was deliberately kept out of
    // the cache and trigger maps. Once it is explicitly approved, load and
    // register it before this manual execution.
    if (!PluginsCache[plugin.id]) await reloadPlugin(plugin, '', true)
    const cache = PluginsCache[plugin.id]

    if (!cache) throw `${plugin.name} is Missing source code`
    if (cache.plugin.disabled) throw `${plugin.name} is Disabled`

    const metadata = getPluginMetadata(plugin)
    const _args = args.map((arg) => JSON.stringify(arg))
    try {
      const fn = new window.AsyncFunction(
        `const Plugin = ${JSON.stringify(metadata)};
        ${cache.code};
        return await ${event}(${_args.join(',')})`,
      )
      const exitCode = await fn()
      if (isNumber(exitCode) && exitCode !== plugin.status) {
        plugin.status = exitCode
        editPlugin(id, plugin)
      }
      return exitCode
    } catch (error: any) {
      throw `${cache.plugin.name} : ` + (error.message || error)
    }
  }

  const _watchDisabled = computed(() =>
    plugins.value
      .map((v) => v.disabled)
      .sort()
      .join(),
  )

  const _watchMenus = computed(() =>
    plugins.value
      .map((v) => Object.entries(v.menus).map((v) => v[0] + v[1]))
      .sort()
      .join(),
  )

  watch([_watchMenus, _watchDisabled], () => {
    if (appSettingsStore.app.addPluginToMenu) {
      updateTrayMenus()
    }
  })

  return {
    plugins,
    setupPlugins,
    savePlugins,
    addPlugin,
    editPlugin,
    deletePlugin,
    updatePlugin,
    updatePlugins,
    getPluginById,
    reloadPlugin,
    onSubscribeTrigger,
    onGenerateTrigger,
    onStartupTrigger: () =>
      noParamsTrigger(PluginTrigger.OnStartup, {
        pluginTimeoutMs: STARTUP_PLUGIN_EXECUTION_TIMEOUT_MS,
      }),
    onShutdownTrigger: () =>
      noParamsTrigger(PluginTrigger.OnShutdown, { interruptOnError: true }),
    onReadyTrigger: () =>
      noParamsTrigger(PluginTrigger.OnReady, {
        pluginTimeoutMs: STARTUP_PLUGIN_EXECUTION_TIMEOUT_MS,
      }),
    onCoreStartedTrigger: () => noParamsTrigger(PluginTrigger.OnCoreStarted),
    onCoreStoppedTrigger: () => noParamsTrigger(PluginTrigger.OnCoreStopped),
    onBeforeCoreStopTrigger: () =>
      noParamsTrigger(PluginTrigger.OnBeforeCoreStop, { interruptOnError: true }),
    onBeforeCoreStartTrigger,
    manualTrigger,
    updatePluginTrigger,
    getPluginCodefromCache,
    getPluginMetadata,
    ensurePluginTrustConsent,

    pluginHub,
    pluginHubLoading,
    updatePluginHub,
    hasNewPluginVersion,
    findPluginInHubById,
    isDeprecated,
  }
})
