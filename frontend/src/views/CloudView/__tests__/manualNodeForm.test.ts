import { describe, expect, it } from 'vitest'

import {
  formatSkippedImportEntry,
  getManualInputFromForm,
  mapManualError,
  populateManualFormFromNode,
  resetImportForm,
  resetManualForm,
  type ImportFormState,
  type ManualFormState,
} from '../manualNodeForm'

const translate = (key: string, params?: Record<string, unknown>) => (
  params ? `${key}:${JSON.stringify(params)}` : key
)

const form = (overrides: Partial<ManualFormState> = {}): ManualFormState => ({
  label: 'edge',
  ipv4: '203.0.113.10',
  ipv6: '',
  ssPort: '8388',
  ssPassword: 'secret',
  hysteriaPort: '',
  hysteriaPassword: '',
  vlessPort: '',
  vlessUUID: '',
  vlessPublicKey: '',
  vlessShortId: '',
  trojanPort: '',
  trojanPassword: '',
  ...overrides,
})

describe('manual node form helpers', () => {
  it('resets manual and import form state', () => {
    const manual = form({
      label: 'dirty',
      ipv6: '2001:db8::1',
      hysteriaPort: '443',
      hysteriaPassword: 'hysteria',
      vlessPort: '8443',
      vlessUUID: 'uuid',
      vlessPublicKey: 'pk',
      vlessShortId: 'sid',
      trojanPort: '9443',
      trojanPassword: 'trojan',
    })
    const importState: ImportFormState = { raw: 'ss://example' }

    resetManualForm(manual)
    resetImportForm(importState)

    expect(manual).toEqual(form({
      label: '',
      ipv4: '',
      ssPort: '',
      ssPassword: '',
    }))
    expect(importState.raw).toBe('')
  })

  it('maps known manual errors and skipped import entries', () => {
    expect(mapManualError(new Error('label-required'), translate)).toBe('cloud.errors.manualLabelRequired')
    expect(mapManualError(new Error('address-required'), translate)).toBe('cloud.errors.manualAddressRequired')
    expect(mapManualError(new Error('protocol-required'), translate)).toBe('cloud.errors.manualProtocolRequired')
    expect(mapManualError(new Error('duplicate'), translate)).toBe('cloud.errors.manualDuplicate')
    expect(mapManualError(new Error('manual-node-not-found'), translate)).toBe('cloud.errors.importInvalid')
    expect(mapManualError('provider-error', translate)).toBe('provider-error')

    expect(formatSkippedImportEntry({ reason: 'ipv4', identifier: '203.0.113.10' }, translate)).toBe(
      'cloud.manual.importSkippedIpv4:{"value":"203.0.113.10"}',
    )
    expect(formatSkippedImportEntry({ reason: 'ipv6', identifier: '2001:db8::1' }, translate)).toBe(
      'cloud.manual.importSkippedIpv6:{"value":"2001:db8::1"}',
    )
    expect(formatSkippedImportEntry({ reason: 'label', identifier: 'edge' }, translate)).toBe(
      'cloud.manual.importSkippedLabel:{"value":"edge"}',
    )
  })

  it('normalizes valid manual inputs and rejects incomplete forms', () => {
    expect(getManualInputFromForm(form({
      label: ' edge ',
      ipv4: ' 203.0.113.10 ',
      ssPort: '8388.9',
      ssPassword: ' secret ',
      hysteriaPort: '70000',
      hysteriaPassword: 'ignored',
    }))).toMatchObject({
      label: 'edge',
      ipv4: '203.0.113.10',
      ssPort: 8388,
      ssPassword: 'secret',
      hysteriaPort: undefined,
      hysteriaPassword: 'ignored',
    })

    expect(() => getManualInputFromForm(form({ label: '   ' }))).toThrow('label-required')
    expect(() => getManualInputFromForm(form({ ipv4: '', ipv6: '' }))).toThrow('address-required')
    expect(() => getManualInputFromForm(form({
      ssPort: '',
      ssPassword: '',
      hysteriaPort: '443',
      hysteriaPassword: '',
    }))).toThrow('protocol-required')
  })

  it('populates forms from existing node records', () => {
    const manual = form({ label: '', ipv4: '', ssPort: '', ssPassword: '' })

    populateManualFormFromNode(manual, {
      label: 'imported',
      ipv6: '2001:db8::1',
      port: 8388,
      password: 'legacy',
      hysteriaPort: 443,
      hysteriaPassword: 'hy',
      vlessPort: 8443,
      vlessUUID: 'uuid',
      vlessPublicKey: 'pk',
      vlessShortId: 'sid',
      trojanPort: 9443,
      trojanPassword: 'trojan',
    })

    expect(manual).toMatchObject({
      label: 'imported',
      ipv4: '',
      ipv6: '2001:db8::1',
      ssPort: '8388',
      ssPassword: 'legacy',
      hysteriaPort: '443',
      vlessPort: '8443',
      trojanPort: '9443',
    })
  })
})
