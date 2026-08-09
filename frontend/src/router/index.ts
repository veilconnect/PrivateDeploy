import { createRouter, createWebHashHistory } from 'vue-router'

import { useCloudStore } from '@/stores/cloud'

import routes from './routes'
import { shouldRedirectToWizard } from './startupGuard'

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
    const cloudStore = useCloudStore()
    if (await shouldRedirectToWizard(cloudStore)) {
      return next({ name: 'Wizard' })
    }
  } catch {
    // If check fails, just proceed normally
  }

  next()
})

export default router
