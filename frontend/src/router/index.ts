import { createRouter, createWebHashHistory } from 'vue-router'

import routes from './routes'

const router = createRouter({
  history: createWebHashHistory(import.meta.env.BASE_URL),
  routes,
})

// Auto-redirect to wizard on first use (no nodes and no API key configured)
let wizardChecked = false
router.beforeEach(async (to, _from, next) => {
  if (wizardChecked || to.name === 'Wizard') {
    return next()
  }
  wizardChecked = true

  try {
    // Lazy-import to avoid circular dependency
    const { useCloudStore } = await import('@/stores')
    const cloudStore = useCloudStore()

    // Load config if not yet loaded
    if (!cloudStore.configLoaded) {
      await cloudStore.loadConfig().catch(() => {})
    }
    await cloudStore.refreshInstances(true).catch(() => {})

    // Check if user has no API key and no instances
    const hasConfig = cloudStore.config.apiKey?.trim()
    const hasInstances = cloudStore.instances.length > 0

    if (!hasConfig && !hasInstances) {
      return next({ name: 'Wizard' })
    }
  } catch {
    // If check fails, just proceed normally
  }

  next()
})

export default router
