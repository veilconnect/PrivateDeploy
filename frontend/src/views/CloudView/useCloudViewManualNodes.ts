import { reactive, ref } from 'vue'

import { message } from '@/utils'

import ImportNodesModal from './components/ImportNodesModal.vue'
import ManualNodeModal from './components/ManualNodeModal.vue'
import {
  formatSkippedImportEntry,
  getManualInputFromForm,
  mapManualError,
  populateManualFormFromNode,
  resetImportForm,
  resetManualForm,
  type ImportFormState,
  type ManualFormState,
} from './manualNodeForm'
import { parseImportedNodes } from './manualNodeParser'

import type { ManagedCloudNode, ManualNodeSkipEntry } from '@/stores/cloud'
import type { ManualNodeInput } from '@/stores/cloud/types'
import type { CloudNode } from '@/types/cloud'

type TranslateFn = (key: string, params?: Record<string, unknown>) => string

type ModalApiLike = {
  setProps: (options: Record<string, unknown>) => ModalApiLike
  setContent: <C extends new (...args: any) => any>(
    component: C,
    props?: InstanceType<C>['$props'],
    slots?: InstanceType<C>['$slots'],
    replace?: boolean,
  ) => ModalApiLike
  open: () => void
}

type CloudStoreLike = {
  addManualNode: (input: ManualNodeInput) => Promise<ManagedCloudNode>
  addManualNodes: (inputs: ManualNodeInput[]) => Promise<{ added: ManagedCloudNode[]; skipped: ManualNodeSkipEntry[] }>
  updateManualNode: (instanceId: string, input: ManualNodeInput) => Promise<ManagedCloudNode>
  applyNodeToProfile: (node: CloudNode) => Promise<unknown>
}

type UseCloudViewManualNodesDeps = {
  cloudStore: CloudStoreLike
  modalApi: ModalApiLike
  translate: TranslateFn
}

export const useCloudViewManualNodes = ({
  cloudStore,
  modalApi,
  translate,
}: UseCloudViewManualNodesDeps) => {
  const manualForm = reactive<ManualFormState>({
    label: '',
    ipv4: '',
    ipv6: '',
    ssPort: '',
    ssPassword: '',
    hysteriaPort: '',
    hysteriaPassword: '',
    vlessPort: '',
    vlessUUID: '',
    vlessPublicKey: '',
    vlessShortId: '',
    trojanPort: '',
    trojanPassword: '',
  })

  const importForm = reactive<ImportFormState>({
    raw: '',
  })

  const manualEditingId = ref('')

  const handleManualSubmit = async () => {
    try {
      const input = getManualInputFromForm(manualForm)
      const node = await cloudStore.addManualNode(input)
      await cloudStore.applyNodeToProfile(node)
      message.success(translate('cloud.manual.addSuccess'))
      return true
    } catch (error) {
      message.error(mapManualError(error, translate))
      return false
    }
  }

  const handleManualUpdate = async () => {
    const id = manualEditingId.value
    if (!id) {
      return false
    }

    try {
      const input = getManualInputFromForm(manualForm)
      const node = await cloudStore.updateManualNode(id, input)
      await cloudStore.applyNodeToProfile(node)
      message.success(translate('cloud.manual.updateSuccess'))
      return true
    } catch (error) {
      message.error(mapManualError(error, translate))
      return false
    }
  }

  const handleImportSubmit = async () => {
    const raw = importForm.raw.trim()
    if (!raw) {
      message.error(translate('cloud.errors.importEmpty'))
      return false
    }

    let inputs: ManualNodeInput[]
    try {
      inputs = parseImportedNodes(raw)
    } catch {
      message.error(translate('cloud.errors.importInvalid'))
      return false
    }

    if (!inputs.length) {
      message.error(translate('cloud.errors.importInvalid'))
      return false
    }

    try {
      const { added, skipped } = await cloudStore.addManualNodes(inputs)
      if (!added.length) {
        message.error(translate('cloud.errors.importInvalid'))
        return false
      }

      await Promise.all(added.map((node) => cloudStore.applyNodeToProfile(node).catch(() => undefined)))
      if (skipped.length) {
        const detail = skipped
          .map((entry) => formatSkippedImportEntry(entry, translate))
          .join('; ')
        message.warn(translate('cloud.manual.importSkippedList', { count: skipped.length, labels: detail }))
      }
      message.success(translate('cloud.manual.importSuccess', { count: added.length }))
      return true
    } catch (error) {
      message.error(mapManualError(error, translate))
      return false
    }
  }

  const openManualNodeModal = () => {
    resetManualForm(manualForm)
    manualEditingId.value = ''
    modalApi
      .setProps({
        title: translate('cloud.manual.addTitle'),
        cancelText: 'common.cancel',
        submitText: 'common.save',
        onOk: handleManualSubmit,
      })
      .setContent(ManualNodeModal, {
        form: manualForm,
        'onUpdate:form': (value: ManualFormState) => Object.assign(manualForm, value),
      })
      .open()
  }

  const openImportModal = () => {
    resetImportForm(importForm)
    modalApi
      .setProps({
        title: translate('cloud.manual.importTitle'),
        cancelText: 'common.cancel',
        submitText: 'common.import',
        onOk: handleImportSubmit,
      })
      .setContent(ImportNodesModal, {
        form: importForm,
        'onUpdate:form': (value: ImportFormState) => {
          importForm.raw = typeof value?.raw === 'string' ? value.raw : ''
        },
      })
      .open()
  }

  const openEditManualNode = (record: CloudNode | Record<string, unknown>) => {
    const node = record as CloudNode
    manualEditingId.value = node.instanceId
    populateManualFormFromNode(manualForm, record as Record<string, unknown>)
    modalApi
      .setProps({
        title: translate('cloud.manual.editTitle'),
        cancelText: 'common.cancel',
        submitText: 'common.save',
        onOk: handleManualUpdate,
      })
      .setContent(ManualNodeModal, {
        form: manualForm,
        'onUpdate:form': (value: ManualFormState) => Object.assign(manualForm, value),
      })
      .open()
  }

  return {
    openEditManualNode,
    openImportModal,
    openManualNodeModal,
  }
}
