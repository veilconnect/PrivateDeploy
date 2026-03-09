import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'

// Polyfill localStorage before any module loads (needed for @vue/devtools-kit)
if (typeof globalThis.localStorage === 'undefined') {
  const store: Record<string, string> = {}
  ;(globalThis as any).localStorage = {
    getItem: (key: string) => store[key] ?? null,
    setItem: (key: string, value: string) => { store[key] = value },
    removeItem: (key: string) => { delete store[key] },
    clear: () => { for (const k in store) delete store[k] },
    get length() { return Object.keys(store).length },
    key: (i: number) => Object.keys(store)[i] ?? null,
  }
}

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  test: {
    globals: true,
    environment: 'happy-dom',
    setupFiles: ['./src/__mocks__/setup.ts'],
    alias: {
      '@wails/runtime/runtime': fileURLToPath(new URL('./src/__mocks__/wails-runtime.ts', import.meta.url)),
      '@wails/go/bridge/App': fileURLToPath(new URL('./src/__mocks__/wails-app.ts', import.meta.url)),
    },
    deps: {
      optimizer: {
        web: {
          include: ['@vue/devtools-kit'],
        },
      },
    },
  },
})
