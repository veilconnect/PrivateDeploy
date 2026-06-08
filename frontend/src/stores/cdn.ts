import { defineStore } from 'pinia'
import { computed, ref } from 'vue'

import {
  ClearCdn,
  ClearCdnCustomDomain,
  DeleteCdnWorkerForNode,
  DeployCdnWorkerForNode,
  EventsOff,
  EventsOn,
  GetCdnState,
  ListCdnZones,
  SetCdnCustomDomain,
  VerifyCdnToken,
} from '@/bridge'

import type { CdnDeployment, CdnState, CdnStatus, CdnZone } from '@/types/cloud'

const emptyState = (): CdnState => ({
  status: 'disabled',
  deployments: {},
})

// useCdnStore tracks Cloudflare CDN front state. Mirrors the mobile
// CdnProvider — verify a token, list/create/delete Workers per cloud node,
// surface workers.dev subdomain and the lastError for the UI.
//
// Workers are deployed Go-side via the Wails bridge so the raw API token
// never touches the renderer process.
export const useCdnStore = defineStore('cdn', () => {
  const state = ref<CdnState>(emptyState())
  const verifying = ref(false)
  const deployingFor = ref<string | null>(null)
  const deletingFor = ref<string | null>(null)
  const initialized = ref(false)
  const zones = ref<CdnZone[]>([])
  const zonesLoading = ref(false)
  const zonesLoadedAt = ref<number | null>(null)
  const savingCustomDomain = ref(false)

  const status = computed<CdnStatus>(() => state.value.status)
  const isConfigured = computed(() => status.value !== 'disabled')
  const isVerified = computed(() => status.value === 'verified')
  const lastError = computed(() => state.value.lastError ?? '')
  const accountId = computed(() => state.value.accountId ?? '')
  const accountEmail = computed(() => state.value.accountEmail ?? '')
  const workersSubdomain = computed(() => state.value.workersSubdomain ?? '')
  const workersDevExample = computed(() => state.value.workersDevExample ?? '')
  const deployments = computed(() => state.value.deployments ?? {})
  const customDomain = computed(() => state.value.customDomain ?? null)
  // customDomainHostPattern is the per-node host shape: each deployed Worker
  // is bound to <subdomain>-<6hex-script-hash>.<zone>, so we can't show a
  // single concrete host the way we used to. Used only by the preview text
  // in Settings; deployment records carry the real customHost.
  const customDomainHostPattern = computed(() => {
    const c = state.value.customDomain
    if (!c) return ''
    return `${c.subdomain}-<node>.${c.zoneName}`
  })

  const deploymentFor = (nodeId: string): CdnDeployment | null => {
    return deployments.value[nodeId] ?? null
  }

  const refresh = async () => {
    state.value = (await GetCdnState()) ?? emptyState()
    initialized.value = true
  }

  const ensureLoaded = async () => {
    if (!initialized.value) {
      await refresh()
    }
  }

  const verify = async (token: string): Promise<boolean> => {
    if (verifying.value) return false
    verifying.value = true
    try {
      const { ok, state: next } = await VerifyCdnToken(token)
      state.value = next
      // Always invalidate the zone cache on a successful verify. Either
      // the account changed (cached zones belong to a different account
      // and would 404 on attach) or the token was rotated for the same
      // account (zones may have been added/removed out-of-band). Either
      // way the cached list is suspect and the next picker render
      // should re-fetch.
      if (ok) {
        zones.value = []
        zonesLoadedAt.value = null
      }
      return ok
    } finally {
      verifying.value = false
    }
  }

  const clear = async () => {
    state.value = await ClearCdn()
    zones.value = []
    zonesLoadedAt.value = null
  }

  const deploy = async (nodeId: string): Promise<boolean> => {
    if (deployingFor.value) return false
    deployingFor.value = nodeId
    try {
      const { ok, state: next } = await DeployCdnWorkerForNode(nodeId)
      state.value = next
      return ok
    } finally {
      deployingFor.value = null
    }
  }

  const remove = async (nodeId: string): Promise<boolean> => {
    if (deletingFor.value) return false
    deletingFor.value = nodeId
    try {
      const { ok, state: next } = await DeleteCdnWorkerForNode(nodeId)
      state.value = next
      return ok
    } finally {
      deletingFor.value = null
    }
  }

  // refreshZones lists CF zones the verified token can see. Cheap (one CF
  // GET) but we cache the result so the picker doesn't refetch on every
  // panel re-open. Throws if the token isn't verified — the UI should not
  // call this until isVerified is true.
  const refreshZones = async (): Promise<CdnZone[]> => {
    if (zonesLoading.value) return zones.value
    zonesLoading.value = true
    try {
      zones.value = await ListCdnZones()
      zonesLoadedAt.value = Date.now()
      return zones.value
    } finally {
      zonesLoading.value = false
    }
  }

  const setCustomDomain = async (
    zoneId: string,
    subdomain: string,
  ): Promise<boolean> => {
    if (savingCustomDomain.value) return false
    savingCustomDomain.value = true
    try {
      const { ok, state: next } = await SetCdnCustomDomain(zoneId, subdomain)
      state.value = next
      return ok
    } finally {
      savingCustomDomain.value = false
    }
  }

  const clearCustomDomain = async (): Promise<void> => {
    if (savingCustomDomain.value) return
    savingCustomDomain.value = true
    try {
      state.value = await ClearCdnCustomDomain()
    } finally {
      savingCustomDomain.value = false
    }
  }

  // Subscribe to Go-side state updates (multi-window, Worker-deploy progress).
  let unsubscribed = false
  const handle = (next: CdnState) => {
    if (unsubscribed) return
    if (next && typeof next === 'object') {
      state.value = next
    }
  }
  EventsOn('cdn:state', handle)
  const dispose = () => {
    unsubscribed = true
    EventsOff('cdn:state')
  }

  return {
    state,
    status,
    isConfigured,
    isVerified,
    lastError,
    accountId,
    accountEmail,
    workersSubdomain,
    workersDevExample,
    deployments,
    customDomain,
    customDomainHostPattern,
    zones,
    zonesLoading,
    zonesLoadedAt,
    savingCustomDomain,
    verifying,
    deployingFor,
    deletingFor,
    initialized,
    deploymentFor,
    refresh,
    refreshZones,
    setCustomDomain,
    clearCustomDomain,
    ensureLoaded,
    verify,
    clear,
    deploy,
    remove,
    dispose,
  }
})
