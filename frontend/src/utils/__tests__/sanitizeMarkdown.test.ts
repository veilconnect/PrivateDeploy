import { describe, expect, it } from 'vitest'

import { sanitizeMarkdownHtml } from '../sanitizeMarkdown'

describe('sanitizeMarkdownHtml', () => {
  it('removes executable elements, event handlers, styles, and unsafe URLs', () => {
    const sanitized = sanitizeMarkdownHtml(`
      <p style="background:url(javascript:alert(1))" onclick="alert(1)">safe</p>
      <img src=x onerror="alert(2)">
      <script>alert(3)</script>
      <svg><a href="javascript:alert(4)">svg-link</a></svg>
      <a href="javascript:alert(5)" onmouseover="alert(6)">bad-link</a>
      <a href="data:text/html,boom">data-link</a>
    `)

    expect(sanitized).not.toMatch(/<(?:script|img|svg)\b/i)
    expect(sanitized).not.toMatch(/\bon\w+\s*=/i)
    expect(sanitized).not.toContain('style=')
    expect(sanitized).not.toContain('javascript:')
    expect(sanitized).not.toContain('data:text/html')
    expect(sanitized).toContain('safe')
    expect(sanitized).toContain('bad-link')
  })

  it('preserves only explicit HTTP(S) links with opener protection', () => {
    const sanitized = sanitizeMarkdownHtml(`
      <a href="https://example.com/docs?q=1" title="removed">docs</a>
      <a href="/relative">relative</a>
    `)
    const documentNode = new DOMParser().parseFromString(sanitized, 'text/html')
    const links = Array.from(documentNode.querySelectorAll('a'))

    expect(links[0]?.getAttribute('href')).toBe('https://example.com/docs?q=1')
    expect(links[0]?.getAttribute('target')).toBe('_blank')
    expect(links[0]?.getAttribute('rel')).toBe('noopener noreferrer')
    expect(links[0]?.hasAttribute('title')).toBe(false)
    expect(links[1]?.hasAttribute('href')).toBe(false)
  })
})
