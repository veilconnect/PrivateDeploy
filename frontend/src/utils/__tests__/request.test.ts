import { afterEach, describe, expect, it, vi } from 'vitest'

import { Request } from '../request'

const response = (options: {
  status?: number
  json?: unknown
  text?: string
}): Response =>
  ({
    status: options.status ?? 200,
    json: vi.fn().mockResolvedValue(options.json),
    text: vi.fn().mockResolvedValue(options.text ?? ''),
  }) as unknown as Response

describe('Request', () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('adds base URLs, query strings, bearer auth, and before-request hooks', async () => {
    const fetchMock = vi.fn().mockResolvedValue(response({ json: { ok: true } }))
    const beforeRequest = vi.fn()
    vi.stubGlobal('fetch', fetchMock)

    const client = new Request({
      base: 'https://api.example.test',
      bearer: 'secret-token',
      beforeRequest,
    })

    await expect(client.get('/nodes', { page: 2, q: 'tokyo edge' })).resolves.toEqual({
      ok: true,
    })

    expect(beforeRequest).toHaveBeenCalledTimes(1)
    expect(fetchMock).toHaveBeenCalledWith(
      'https://api.example.test/nodes?page=2&q=tokyo+edge',
      expect.objectContaining({
        method: 'GET',
        headers: { Authorization: 'Bearer secret-token' },
      }),
    )
  })

  it('serializes write bodies and supports empty responses', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(response({ json: { created: true } }))
      .mockResolvedValueOnce(response({ status: 204 }))
    vi.stubGlobal('fetch', fetchMock)

    const client = new Request()

    await expect(client.post('/nodes', { label: 'sg-edge' })).resolves.toEqual({
      created: true,
    })
    await expect(client.delete('/nodes/sg-edge')).resolves.toBeNull()

    expect(fetchMock.mock.calls[0][1]).toMatchObject({
      method: 'POST',
      body: JSON.stringify({ label: 'sg-edge' }),
    })
    expect(fetchMock.mock.calls[1][1]).toMatchObject({ method: 'DELETE' })
  })

  it('parses text and yaml response modes', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(response({ text: 'plain text' }))
      .mockResolvedValueOnce(response({ text: 'enabled: true\nregion: nrt\n' }))
    vi.stubGlobal('fetch', fetchMock)

    await expect(new Request({ responseType: 'TEXT' }).get('/readme')).resolves.toBe('plain text')
    await expect(new Request({ responseType: 'YAML' }).get('/config')).resolves.toEqual({
      enabled: true,
      region: 'nrt',
    })
  })

  it('surfaces gateway and auth error messages from JSON bodies', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(response({
      status: 503,
      json: { message: 'cloud provider unavailable' },
    })))

    await expect(new Request().get('/nodes')).rejects.toBe('cloud provider unavailable')
  })
})
