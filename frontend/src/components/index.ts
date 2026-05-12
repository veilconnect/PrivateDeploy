import { defineAsyncComponent } from 'vue'

import type { Plugin, App, Component } from 'vue'

export { default as TitleBar } from './TitleBar.vue'
export { default as NavigationBar } from './NavigationBar.vue'
export { default as WorkspaceHeader } from './WorkspaceHeader.vue'

const Components = import.meta.glob<Component>(['./*/index.vue', '!./CodeViewer/index.vue'], {
  eager: true,
  import: 'default',
})

export default {
  install: (app: App) => {
    for (const path in Components) {
      const name = path.split('/')[1]
      app.component(name, Components[path])
    }
    app.component('CodeViewer', defineAsyncComponent(() => import('./CodeViewer/index.vue')))
  },
} as Plugin
