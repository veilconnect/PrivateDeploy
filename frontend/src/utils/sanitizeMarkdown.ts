const allowedMarkdownTags = new Set([
  'A', 'BLOCKQUOTE', 'BR', 'CODE', 'DEL', 'EM', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6',
  'HR', 'LI', 'OL', 'P', 'PRE', 'STRONG', 'TABLE', 'TBODY', 'TD', 'TH', 'THEAD', 'TR', 'UL',
])

/**
 * Reduce rendered Markdown to a small inert HTML subset before it reaches
 * Vue's v-html boundary. Confirm content can contain cloud/provider strings
 * and plugin-supplied text, so every attribute is removed and only explicit
 * HTTP(S) links are restored.
 */
export const sanitizeMarkdownHtml = (html: string): string => {
  const documentNode = new DOMParser().parseFromString(html, 'text/html')
  for (const element of Array.from(documentNode.body.querySelectorAll('*'))) {
    if (!allowedMarkdownTags.has(element.tagName)) {
      element.replaceWith(...Array.from(element.childNodes))
      continue
    }

    const rawHref = element.tagName === 'A' ? element.getAttribute('href')?.trim() : undefined
    for (const attribute of Array.from(element.attributes)) {
      element.removeAttribute(attribute.name)
    }
    if (element.tagName !== 'A' || !rawHref || !/^https?:\/\//i.test(rawHref)) continue

    try {
      const url = new URL(rawHref)
      if (url.protocol !== 'https:' && url.protocol !== 'http:') continue
      element.setAttribute('href', url.href)
      element.setAttribute('target', '_blank')
      element.setAttribute('rel', 'noopener noreferrer')
    } catch {
      // Malformed links remain inert anchor text.
    }
  }
  return documentNode.body.innerHTML
}
