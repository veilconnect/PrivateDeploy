import { fileURLToPath, URL } from 'node:url'

import vue from '@vitejs/plugin-vue'
import { defineConfig, loadEnv } from 'vite'

const frontendRoot = fileURLToPath(new URL('.', import.meta.url))

// https://vitejs.dev/config/
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, frontendRoot, 'VITE_')
  const appTitle = env.VITE_APP_TITLE || process.env.VITE_APP_TITLE || 'PrivateDeploy'

  return {
    base: './',
    plugins: [
      vue(),
      {
        name: 'privatedeploy-html-env-defaults',
        transformIndexHtml(html) {
          return html.replaceAll('%VITE_APP_TITLE%', appTitle)
        },
      },
    ],
    define: {
      'import.meta.env.VITE_APP_TITLE': JSON.stringify(appTitle),
    },
    resolve: {
      alias: {
        '@': fileURLToPath(new URL('./src', import.meta.url)),
        '@wails': fileURLToPath(new URL('./src/bridge/wailsjs', import.meta.url)),
        vue: 'vue/dist/vue.esm-bundler.js',
      },
    },
    build: {
      chunkSizeWarningLimit: 4096, // 4MB
      // __ROLLUP_MANUAL_CHUNKS__
    },
  }
})
