import { beforeEach, describe, expect, it, vi } from 'vitest'

const messageMock = vi.hoisted(() => ({
  error: vi.fn(),
  success: vi.fn(),
  warn: vi.fn(),
}))

vi.mock('@/utils', () => ({
  message: messageMock,
}))

vi.mock('../components/ImportNodesModal.vue', () => ({
  default: { name: 'ImportNodesModal' },
}))

vi.mock('../components/ManualNodeModal.vue', () => ({
  default: { name: 'ManualNodeModal' },
}))

import { useCloudViewManualNodes } from '../useCloudViewManualNodes'

import type { ManagedCloudNode, ManualNodeSkipEntry } from '@/stores/cloud'
import type { ManualNodeInput } from '@/stores/cloud/types'
import type { CloudNode } from '@/types/cloud'

type ModalProps = Record<string, any>
type ModalContent = {
  component?: unknown
  props?: Record<string, any>
}

const translate = (key: string, params?: Record<string, unknown>) => (
  params ? `${key}:${JSON.stringify(params)}` : key
)

const managedNode = (overrides: Partial<ManagedCloudNode> = {}): ManagedCloudNode => ({
  instanceId: 'node-1',
  label: 'Tokyo edge',
  ipv4: '203.0.113.10',
  ssPort: 8388,
  ssPassword: 'secret',
  ...overrides,
})

const createHarness = () => {
  const cloudStore = {
    addManualNode: vi.fn<(_: ManualNodeInput) => Promise<ManagedCloudNode>>()
      .mockResolvedValue(managedNode()),
    addManualNodes: vi.fn<(_: ManualNodeInput[]) => Promise<{ added: ManagedCloudNode[]; skipped: ManualNodeSkipEntry[] }>>()
      .mockResolvedValue({ added: [managedNode()], skipped: [] }),
    updateManualNode: vi.fn<(_: string, __: ManualNodeInput) => Promise<ManagedCloudNode>>()
      .mockResolvedValue(managedNode()),
    applyNodeToProfile: vi.fn<(_: CloudNode) => Promise<unknown>>()
      .mockResolvedValue(undefined),
  }
  let modalProps: ModalProps = {}
  let modalContent: ModalContent = {}
  const modalApi = {
    setProps: vi.fn((options: ModalProps) => {
      modalProps = options
      return modalApi
    }),
    setContent: vi.fn((component: unknown, props?: Record<string, any>) => {
      modalContent = { component, props }
      return modalApi
    }),
    open: vi.fn(),
  }

  const composable = useCloudViewManualNodes({
    cloudStore,
    modalApi,
    translate,
  })

  return {
    cloudStore,
    composable,
    get modalContent() {
      return modalContent
    },
    modalApi,
    get modalProps() {
      return modalProps
    },
  }
}

describe('useCloudViewManualNodes', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('opens the add modal and submits a normalized manual node', async () => {
    const harness = createHarness()

    harness.composable.openManualNodeModal()
    harness.modalContent.props?.['onUpdate:form']({
      label: ' Tokyo edge ',
      ipv4: ' 203.0.113.10 ',
      ipv6: '',
      ssPort: '8388',
      ssPassword: ' secret ',
      hysteriaPort: '',
      hysteriaPassword: '',
      vlessPort: '',
      vlessUUID: '',
      vlessPublicKey: '',
      vlessShortId: '',
      trojanPort: '',
      trojanPassword: '',
    })

    await expect(harness.modalProps.onOk()).resolves.toBe(true)

    expect(harness.modalApi.setProps).toHaveBeenCalledWith(expect.objectContaining({
      title: 'cloud.manual.addTitle',
      submitText: 'common.save',
    }))
    expect(harness.modalApi.open).toHaveBeenCalledTimes(1)
    expect(harness.cloudStore.addManualNode).toHaveBeenCalledWith(expect.objectContaining({
      label: 'Tokyo edge',
      ipv4: '203.0.113.10',
      ssPort: 8388,
      ssPassword: 'secret',
    }))
    expect(harness.cloudStore.applyNodeToProfile).toHaveBeenCalledWith(managedNode())
    expect(messageMock.success).toHaveBeenCalledWith('cloud.manual.addSuccess')
  })

  it('reports validation errors without calling the store', async () => {
    const harness = createHarness()

    harness.composable.openManualNodeModal()

    await expect(harness.modalProps.onOk()).resolves.toBe(false)

    expect(harness.cloudStore.addManualNode).not.toHaveBeenCalled()
    expect(messageMock.error).toHaveBeenCalledWith('cloud.errors.manualLabelRequired')
  })

  it('opens the edit modal and updates the selected manual node', async () => {
    const harness = createHarness()

    harness.composable.openEditManualNode({
      instanceId: 'existing-node',
      label: 'Existing',
      ipv6: '2001:db8::10',
      port: 8388,
      password: 'legacy-pass',
    })

    expect(harness.modalContent.props?.form).toMatchObject({
      label: 'Existing',
      ipv6: '2001:db8::10',
      ssPort: '8388',
      ssPassword: 'legacy-pass',
    })

    harness.modalContent.props?.['onUpdate:form']({
      ...harness.modalContent.props.form,
      label: 'Updated',
      ipv4: '203.0.113.50',
    })

    await expect(harness.modalProps.onOk()).resolves.toBe(true)

    expect(harness.cloudStore.updateManualNode).toHaveBeenCalledWith(
      'existing-node',
      expect.objectContaining({
        label: 'Updated',
        ipv4: '203.0.113.50',
        ssPort: 8388,
        ssPassword: 'legacy-pass',
      }),
    )
    expect(messageMock.success).toHaveBeenCalledWith('cloud.manual.updateSuccess')
  })

  it('validates import modal input before storing nodes', async () => {
    const harness = createHarness()

    harness.composable.openImportModal()

    await expect(harness.modalProps.onOk()).resolves.toBe(false)
    expect(messageMock.error).toHaveBeenCalledWith('cloud.errors.importEmpty')

    harness.modalContent.props?.['onUpdate:form']({ raw: 'not a supported import' })
    await expect(harness.modalProps.onOk()).resolves.toBe(false)

    expect(harness.cloudStore.addManualNodes).not.toHaveBeenCalled()
    expect(messageMock.error).toHaveBeenLastCalledWith('cloud.errors.importInvalid')
  })

  it('imports valid node lists and warns about skipped duplicates', async () => {
    const harness = createHarness()
    harness.cloudStore.addManualNodes.mockResolvedValueOnce({
      added: [managedNode({ instanceId: 'imported-node', label: 'Imported' })],
      skipped: [
        { reason: 'ipv4', identifier: '203.0.113.10' },
      ],
    })
    harness.cloudStore.applyNodeToProfile.mockRejectedValueOnce(new Error('profile apply failed'))

    harness.composable.openImportModal()
    harness.modalContent.props?.['onUpdate:form']({
      raw: JSON.stringify([{
        label: 'Imported',
        ipv4: '203.0.113.10',
        ssPort: 8388,
        ssPassword: 'secret',
      }]),
    })

    await expect(harness.modalProps.onOk()).resolves.toBe(true)

    expect(harness.cloudStore.addManualNodes).toHaveBeenCalledWith([
      expect.objectContaining({
        label: 'Imported',
        ipv4: '203.0.113.10',
        ssPort: 8388,
        ssPassword: 'secret',
      }),
    ])
    expect(messageMock.warn).toHaveBeenCalledWith(
      'cloud.manual.importSkippedList:{"count":1,"labels":"cloud.manual.importSkippedIpv4:{\\"value\\":\\"203.0.113.10\\"}"}',
    )
    expect(messageMock.success).toHaveBeenCalledWith('cloud.manual.importSuccess:{"count":1}')
  })

  it('surfaces store errors from imports', async () => {
    const harness = createHarness()
    harness.cloudStore.addManualNodes.mockRejectedValueOnce(new Error('duplicate'))

    harness.composable.openImportModal()
    harness.modalContent.props?.['onUpdate:form']({
      raw: 'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@203.0.113.10:8388#Imported',
    })

    await expect(harness.modalProps.onOk()).resolves.toBe(false)

    expect(messageMock.error).toHaveBeenCalledWith('cloud.errors.manualDuplicate')
  })
})
