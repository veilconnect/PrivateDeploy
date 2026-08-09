import { loadFromOfflineCache } from '@/utils/offline'

import type { ManagedCloudNode } from '@/stores/cloud/types'
import type { CloudConfig, CloudProvider } from '@/types/cloud'

export type StartupCloudState = {
  currentProvider: CloudProvider
  config: CloudConfig
  instances: ManagedCloudNode[]
  getCurrentProvider: () => Promise<void>
  loadConfig: (options?: { startAutoRefresh?: boolean }) => Promise<void>
  loadManualNodes: () => Promise<ManagedCloudNode[]>
}

type OfflineNodeLoader = () => ManagedCloudNode[] | null

const defaultOfflineNodeLoader: OfflineNodeLoader = () =>
  loadFromOfflineCache<ManagedCloudNode[]>('nodes')

// Initial navigation must be decided exclusively from local state. A provider
// inventory request can legitimately take 45 seconds and is retried elsewhere;
// awaiting it in a router guard leaves RouterView empty for minutes and makes a
// healthy WebView look blank. Any uncertainty is fail-open (show the workspace)
// so a temporary config/read failure is never mistaken for first use.
export const shouldRedirectToWizard = async (
  cloud: StartupCloudState,
  loadOfflineNodes: OfflineNodeLoader = defaultOfflineNodeLoader,
): Promise<boolean> => {
  try {
    // The backend persists the active provider per data root. Synchronise that
    // choice before loading the corresponding local credential/config slot.
    await cloud.getCurrentProvider()
    await cloud.loadConfig({ startAutoRefresh: false })

    // Manual nodes are stored in a local file rather than the provider API.
    // Loading them here is bounded filesystem work and prevents an existing
    // manual-only setup from being redirected to the first-run wizard.
    await cloud.loadManualNodes()

    const cachedNodes = loadOfflineNodes()
    const hasLocalNodes = cloud.instances.length > 0 || Boolean(cachedNodes?.length)
    const providerDoesNotRequireAPIKey =
      cloud.currentProvider === 'ssh' || cloud.currentProvider === 'manual'
    const hasLocalConfig = providerDoesNotRequireAPIKey || Boolean(cloud.config.apiKey?.trim())

    return !hasLocalConfig && !hasLocalNodes
  } catch {
    // A local read can fail transiently (locked secret store, renderer/backend
    // startup race, damaged cache). Showing the normal workspace preserves all
    // recovery paths; redirecting would falsely claim the user's data is gone.
    return false
  }
}
