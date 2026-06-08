import type { ManualNodeSkipEntry } from '@/stores/cloud'
import type { ManualNodeInput } from '@/stores/cloud/types'

type TranslateFn = (key: string, params?: Record<string, unknown>) => string

export type ManualFormState = {
  label: string
  ipv4: string
  ipv6: string
  ssPort: string
  ssPassword: string
  hysteriaPort: string
  hysteriaPassword: string
  vlessPort: string
  vlessUUID: string
  vlessPublicKey: string
  vlessShortId: string
  trojanPort: string
  trojanPassword: string
}

export type ImportFormState = {
  raw: string
}

const toOptionalNumber = (value: string) => {
  if (!value) return undefined
  const num = Number(value)
  if (!Number.isFinite(num)) return undefined
  const port = Math.trunc(num)
  if (port <= 0 || port > 65535) return undefined
  return port
}

export const resetManualForm = (form: ManualFormState) => {
  form.label = ''
  form.ipv4 = ''
  form.ipv6 = ''
  form.ssPort = ''
  form.ssPassword = ''
  form.hysteriaPort = ''
  form.hysteriaPassword = ''
  form.vlessPort = ''
  form.vlessUUID = ''
  form.vlessPublicKey = ''
  form.vlessShortId = ''
  form.trojanPort = ''
  form.trojanPassword = ''
}

export const resetImportForm = (form: ImportFormState) => {
  form.raw = ''
}

export const mapManualError = (error: unknown, translate: TranslateFn) => {
  const messageText = error instanceof Error ? error.message : String(error)
  if (messageText === 'label-required') {
    return translate('cloud.errors.manualLabelRequired')
  }
  if (messageText === 'address-required') {
    return translate('cloud.errors.manualAddressRequired')
  }
  if (messageText === 'protocol-required') {
    return translate('cloud.errors.manualProtocolRequired')
  }
  if (messageText === 'duplicate') {
    return translate('cloud.errors.manualDuplicate')
  }
  if (messageText === 'manual-node-not-found') {
    return translate('cloud.errors.importInvalid')
  }
  return messageText
}

export const formatSkippedImportEntry = (entry: ManualNodeSkipEntry, translate: TranslateFn) => {
  if (entry.reason === 'ipv4') {
    return translate('cloud.manual.importSkippedIpv4', { value: entry.identifier })
  }
  if (entry.reason === 'ipv6') {
    return translate('cloud.manual.importSkippedIpv6', { value: entry.identifier })
  }
  return translate('cloud.manual.importSkippedLabel', { value: entry.identifier })
}

export const getManualInputFromForm = (form: ManualFormState): ManualNodeInput => {
  const label = form.label.trim()
  if (!label) {
    throw new Error('label-required')
  }

  const ipv4 = form.ipv4.trim()
  const ipv6 = form.ipv6.trim()
  if (!ipv4 && !ipv6) {
    throw new Error('address-required')
  }

  const input: ManualNodeInput = {
    label,
    ipv4: ipv4 || undefined,
    ipv6: ipv6 || undefined,
    ssPort: toOptionalNumber(form.ssPort) ?? undefined,
    ssPassword: form.ssPassword.trim() || undefined,
    hysteriaPort: toOptionalNumber(form.hysteriaPort) ?? undefined,
    hysteriaPassword: form.hysteriaPassword.trim() || undefined,
    vlessPort: toOptionalNumber(form.vlessPort) ?? undefined,
    vlessUUID: form.vlessUUID.trim() || undefined,
    vlessPublicKey: form.vlessPublicKey.trim() || undefined,
    vlessShortId: form.vlessShortId.trim() || undefined,
    trojanPort: toOptionalNumber(form.trojanPort) ?? undefined,
    trojanPassword: form.trojanPassword.trim() || undefined,
  }

  const hasProtocol =
    (input.ssPort && input.ssPassword) ||
    (input.hysteriaPort && input.hysteriaPassword) ||
    (input.vlessPort && input.vlessUUID && input.vlessPublicKey) ||
    (input.trojanPort && input.trojanPassword)

  if (!hasProtocol) {
    throw new Error('protocol-required')
  }

  return input
}

export const populateManualFormFromNode = (
  form: ManualFormState,
  node: Record<string, any>,
) => {
  form.label = node.label || ''
  form.ipv4 = node.ipv4 || ''
  form.ipv6 = node.ipv6 || ''
  form.ssPort = node.ssPort ? String(node.ssPort) : node.port ? String(node.port) : ''
  form.ssPassword = node.ssPassword || node.password || ''
  form.hysteriaPort = node.hysteriaPort ? String(node.hysteriaPort) : ''
  form.hysteriaPassword = node.hysteriaPassword || ''
  form.vlessPort = node.vlessPort ? String(node.vlessPort) : ''
  form.vlessUUID = node.vlessUUID || ''
  form.vlessPublicKey = node.vlessPublicKey || ''
  form.vlessShortId = node.vlessShortId || ''
  form.trojanPort = node.trojanPort ? String(node.trojanPort) : ''
  form.trojanPassword = node.trojanPassword || ''
}
