import { describe, expect, it } from 'vitest'

import {
  isNumber,
  isValidBase64,
  isValidIPv4,
  isValidIPv6,
  isValidJson,
  isValidPaylodYAML,
  isValidRulesJson,
  isValidSubJson,
  isValidSubYAML,
} from '../is'

describe('validation utilities', () => {
  it('validates base64 strings exactly', () => {
    expect(isValidBase64('c2VjcmV0')).toBe(true)
    expect(isValidBase64('')).toBe(false)
    expect(isValidBase64('  ')).toBe(false)
    expect(isValidBase64('not base64')).toBe(false)
  })

  it('recognizes subscription and rules payload formats', () => {
    expect(isValidSubYAML('proxies:\n  - name: node\n')).toBe(true)
    expect(isValidSubYAML('proxy-groups: []')).toBe(false)
    expect(isValidSubJson('{"outbounds":[{"type":"direct"}]}')).toBe(true)
    expect(isValidSubJson('{"inbounds":[]}')).toBe(false)
    expect(isValidPaylodYAML('payload:\n  - example.com\n')).toBe(true)
    expect(isValidRulesJson('{"rules":[{"type":"field"}]}')).toBe(true)
  })

  it('validates IP address formats', () => {
    expect(isValidIPv4('203.0.113.10')).toBe(true)
    expect(isValidIPv4('256.0.0.1')).toBe(false)
    expect(isValidIPv6('2001:db8::1')).toBe(true)
    expect(isValidIPv6('[2001:db8::1]')).toBe(true)
    expect(isValidIPv6('not-ipv6')).toBe(false)
  })

  it('checks JSON and numeric values', () => {
    expect(isValidJson('{"ok":true}')).toBe(true)
    expect(isValidJson('null')).toBe(false)
    expect(isValidJson('not-json')).toBe(false)
    expect(isNumber(1)).toBe(true)
    expect(isNumber(Number.NaN)).toBe(true)
    expect(isNumber('1')).toBe(false)
  })
})
