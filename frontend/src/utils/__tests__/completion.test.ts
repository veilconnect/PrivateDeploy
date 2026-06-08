import { beforeEach, describe, expect, it, vi } from 'vitest'

const autocompleteMocks = vi.hoisted(() => ({
  completeFromList: vi.fn((items: any[]) => ({
    kind: 'list-source',
    items,
  })),
  snippetCompletion: vi.fn((template: string, completion: Record<string, any>) => ({
    ...completion,
    template,
  })),
}))

const javascriptMocks = vi.hoisted(() => ({
  localCompletionSource: vi.fn(),
  scopeCompletionSource: vi.fn((scope: Record<string, any>) => ({
    kind: 'scope-source',
    scope,
  })),
  snippets: [
    { label: 'function', type: 'keyword' },
  ],
}))

vi.mock('@codemirror/autocomplete', () => ({
  completeFromList: autocompleteMocks.completeFromList,
  snippetCompletion: autocompleteMocks.snippetCompletion,
}))

vi.mock('@codemirror/lang-javascript', () => ({
  localCompletionSource: javascriptMocks.localCompletionSource,
  scopeCompletionSource: javascriptMocks.scopeCompletionSource,
  snippets: javascriptMocks.snippets,
}))

vi.mock('@/lang', () => ({
  default: {
    global: {
      t: (key: string) => `t:${key}`,
    },
  },
}))

import { PluginTriggerEvent } from '@/enums/app'

import { getCompletions } from '../completion'

describe('completion utilities', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    javascriptMocks.localCompletionSource.mockReturnValue({
      options: [{ label: 'localName' }],
    })
  })

  it('builds scope, snippet, and local completion sources', () => {
    const pluginScope = { name: 'demo-plugin' }
    const completions = getCompletions(pluginScope)

    expect(completions).toHaveLength(3)
    expect(javascriptMocks.scopeCompletionSource).toHaveBeenCalledWith(expect.objectContaining({
      Plugin: pluginScope,
    }))
    expect(completions[0]).toEqual(expect.objectContaining({
      kind: 'scope-source',
      scope: expect.objectContaining({ Plugin: pluginScope }),
    }))
    expect(completions[1]).toEqual(expect.objectContaining({
      kind: 'list-source',
    }))
  })

  it('creates plugin trigger and helper snippets with translated details', () => {
    getCompletions({ name: 'demo-plugin' })

    const snippetItems = autocompleteMocks.completeFromList.mock.calls[0][0]
    expect(snippetItems[0]).toEqual({ label: 'function', type: 'keyword' })
    expect(snippetItems.map((item: any) => item.label)).toEqual(expect.arrayContaining([
      PluginTriggerEvent.OnInstall,
      PluginTriggerEvent.OnManual,
      PluginTriggerEvent.OnSubscribe,
      PluginTriggerEvent.OnBeforeCoreStart,
      'StartServer',
      'Download',
      'ExecBackground',
    ]))
    expect(snippetItems.find((item: any) => item.label === PluginTriggerEvent.OnInstall)).toEqual(expect.objectContaining({
      detail: 't:plugin.trigger t:common.install',
      template: expect.stringContaining(`const ${PluginTriggerEvent.OnInstall} = async () =>`),
      type: 'keyword',
    }))
  })

  it('delegates non-explicit local word completions to CodeMirror', () => {
    const localSource = getCompletions()[2] as (context: any) => any

    expect(localSource({
      explicit: false,
      matchBefore: () => ({ from: 7, text: 'loc' }),
    })).toEqual({
      from: 7,
      options: [{ label: 'localName' }],
    })
    expect(javascriptMocks.localCompletionSource).toHaveBeenCalled()

    expect(localSource({
      explicit: true,
      matchBefore: () => ({ from: 0, text: '' }),
    })).toBeNull()
    expect(localSource({
      explicit: false,
      matchBefore: () => null,
    })).toBeNull()
  })
})
