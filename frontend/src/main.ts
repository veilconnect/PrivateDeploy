import { SignalFrontendReady } from '@wails/go/bridge/App'
import { createPinia } from 'pinia'
import { createApp } from 'vue'

import './assets/main.less'
import './assets/globalMethods'

import App from './App.vue'
import components from './components'
import directives from './directives'
import i18n from './lang'
import router from './router'
import { signalFrontendReadyAfterMount } from './utils/frontendReady'
import { migrateSensitiveBrowserStorage } from './utils/sensitiveData'

try {
  migrateSensitiveBrowserStorage()
} catch (error) {
  console.error('[Startup] Failed to migrate sensitive browser storage:', error)
}

const app = createApp(App)

window.appInstance = app

app.use(createPinia())
app.use(router)
app.use(i18n)
app.use(components)
app.use(directives)

app.mount('#app')

void signalFrontendReadyAfterMount(SignalFrontendReady, undefined, () => router.isReady()).catch(
  (error) => {
    console.error('[Startup] Frontend mounted-state signal failed:', error)
  },
)
