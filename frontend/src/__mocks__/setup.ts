// Global test setup: provide localStorage/sessionStorage stubs
// Must run before @vue/devtools-kit is loaded
const store: Record<string, string> = {}
const storageImpl = {
  getItem: (key: string) => store[key] ?? null,
  setItem: (key: string, value: string) => { store[key] = value },
  removeItem: (key: string) => { delete store[key] },
  clear: () => { for (const k in store) delete store[k] },
  get length() { return Object.keys(store).length },
  key: (i: number) => Object.keys(store)[i] ?? null,
}

// Assign to both globalThis and global
Object.defineProperty(globalThis, 'localStorage', { value: storageImpl, writable: true, configurable: true })
Object.defineProperty(globalThis, 'sessionStorage', { value: storageImpl, writable: true, configurable: true })
