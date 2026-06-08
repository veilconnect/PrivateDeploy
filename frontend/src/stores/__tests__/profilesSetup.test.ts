import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  readFile: vi.fn(),
  readDir: vi.fn(),
  moveFile: vi.fn(),
  writeFile: vi.fn(),
}))

vi.mock('@/bridge', () => ({
  ReadFile: mocks.readFile,
  ReadDir: mocks.readDir,
  MoveFile: mocks.moveFile,
  WriteFile: mocks.writeFile,
}))

import { useProfilesStore } from '@/stores/profiles'

describe('profiles setup', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    setActivePinia(createPinia())

    mocks.readFile.mockResolvedValue('')
    mocks.readDir.mockRejectedValue(new Error('directory does not exist'))
    mocks.moveFile.mockResolvedValue(undefined)
    mocks.writeFile.mockResolvedValue(undefined)
  })

  it('does not block first launch when the cache directory is missing', async () => {
    const store = useProfilesStore()

    await expect(store.setupProfiles()).resolves.toBeUndefined()
    expect(store.profiles).toEqual([])
  })
})
