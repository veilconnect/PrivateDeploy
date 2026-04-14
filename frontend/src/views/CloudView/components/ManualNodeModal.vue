<script setup lang="ts">
import { nextTick, reactive, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'

import { parseImportedNodes } from '../manualNodeParser'

interface ManualNodeFormState {
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

const props = defineProps<{
  form: ManualNodeFormState
}>()
const emit = defineEmits<{
  (event: 'update:form', value: ManualNodeFormState): void
}>()

const { t } = useI18n()

const localForm = reactive<ManualNodeFormState>({ ...props.form })
const pasteUri = ref('')
const pasteError = ref('')

let syncing = false

watch(
  () => props.form,
  (value) => {
    syncing = true
    Object.assign(localForm, value)
    void nextTick(() => {
      syncing = false
    })
  },
  { deep: true, immediate: true },
)

watch(
  localForm,
  (value) => {
    if (syncing) return
    emit('update:form', { ...value })
  },
  { deep: true },
)

const handlePasteImport = () => {
  const raw = pasteUri.value.trim()
  if (!raw) return

  pasteError.value = ''

  let nodes
  try {
    nodes = parseImportedNodes(raw)
  } catch {
    pasteError.value = t('cloud.manual.pasteInvalid')
    return
  }

  if (!nodes.length) {
    pasteError.value = t('cloud.manual.pasteInvalid')
    return
  }

  const node = nodes[0]
  localForm.label = node.label || ''
  localForm.ipv4 = node.ipv4 || ''
  localForm.ipv6 = node.ipv6 || ''
  localForm.ssPort = node.ssPort ? String(node.ssPort) : ''
  localForm.ssPassword = node.ssPassword || ''
  localForm.hysteriaPort = node.hysteriaPort ? String(node.hysteriaPort) : ''
  localForm.hysteriaPassword = node.hysteriaPassword || ''
  localForm.vlessPort = node.vlessPort ? String(node.vlessPort) : ''
  localForm.vlessUUID = node.vlessUUID || ''
  localForm.vlessPublicKey = node.vlessPublicKey || ''
  localForm.vlessShortId = node.vlessShortId || ''
  localForm.trojanPort = node.trojanPort ? String(node.trojanPort) : ''
  localForm.trojanPassword = node.trojanPassword || ''

  pasteUri.value = ''
  emit('update:form', { ...localForm })
}
</script>

<template>
  <div class="manual-node-form flex flex-col gap-6">
    <!-- Paste URI quick import -->
    <div class="paste-section">
      <label class="form-label">{{ t('cloud.manual.pasteLabel') }}</label>
      <div class="flex gap-2 items-start">
        <textarea
          v-model="pasteUri"
          class="paste-input"
          rows="2"
          spellcheck="false"
          :placeholder="t('cloud.manual.pastePlaceholder')"
          @keydown.enter.ctrl="handlePasteImport"
          @keydown.enter.meta="handlePasteImport"
        />
        <Button type="primary" size="small" @click="handlePasteImport" :disabled="!pasteUri.trim()">
          {{ t('cloud.manual.pasteButton') }}
        </Button>
      </div>
      <div v-if="pasteError" class="text-12 text-red-500 mt-2">{{ pasteError }}</div>
    </div>

    <Divider />

    <div class="grid gap-6 md:grid-cols-2">
      <div class="form-field">
        <label class="form-label">{{ t('cloud.manual.label') }}</label>
        <Input v-model="localForm.label" placeholder="example-node" auto-size />
      </div>
      <div class="form-field">
        <label class="form-label">{{ t('cloud.manual.ipv4') }}</label>
        <Input v-model="localForm.ipv4" placeholder="203.0.113.10" auto-size />
      </div>
      <div class="form-field">
        <label class="form-label">{{ t('cloud.manual.ipv6') }}</label>
        <Input v-model="localForm.ipv6" placeholder="2404:6800:4004:815::200e" auto-size />
      </div>
      <div class="form-field">
        <label class="form-label">{{ t('cloud.manual.ssPort') }}</label>
        <Input v-model="localForm.ssPort" placeholder="443" auto-size />
      </div>
      <div class="form-field md:col-span-2">
        <label class="form-label">{{ t('cloud.manual.ssPassword') }}</label>
        <Input v-model="localForm.ssPassword" placeholder="password" auto-size />
      </div>
    </div>

    <Divider>{{ t('cloud.manual.optionalProtocols') }}</Divider>

    <div class="grid gap-6 md:grid-cols-2">
      <div class="form-field">
        <label class="form-label">Hysteria2 Port</label>
        <Input v-model="localForm.hysteriaPort" placeholder="8443" auto-size />
      </div>
      <div class="form-field">
        <label class="form-label">Hysteria2 Password</label>
        <Input v-model="localForm.hysteriaPassword" placeholder="password" auto-size />
      </div>
      <div class="form-field">
        <label class="form-label">VLESS Port</label>
        <Input v-model="localForm.vlessPort" placeholder="443" auto-size />
      </div>
      <div class="form-field">
        <label class="form-label">VLESS UUID</label>
        <Input v-model="localForm.vlessUUID" placeholder="UUID" auto-size />
      </div>
      <div class="form-field">
        <label class="form-label">VLESS Public Key</label>
        <Input v-model="localForm.vlessPublicKey" placeholder="Base64 Public Key" auto-size />
      </div>
      <div class="form-field">
        <label class="form-label">VLESS Short ID</label>
        <Input v-model="localForm.vlessShortId" placeholder="Short ID" auto-size />
      </div>
      <div class="form-field">
        <label class="form-label">Trojan Port</label>
        <Input v-model="localForm.trojanPort" placeholder="443" auto-size />
      </div>
      <div class="form-field">
        <label class="form-label">Trojan Password</label>
        <Input v-model="localForm.trojanPassword" placeholder="password" auto-size />
      </div>
    </div>

    <div class="text-12 text-secondary">
      {{ t('cloud.manual.addDescription') }}
    </div>
  </div>
</template>

<style scoped>
.form-field {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.form-label {
  font-size: 12px;
  color: var(--text-secondary-color);
}

.paste-section {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.paste-input {
  flex: 1;
  padding: 6px 10px;
  border-radius: 8px;
  border: 1px solid var(--border-color);
  background: transparent;
  font-family: var(
    --font-family-mono,
    ui-monospace,
    SFMono-Regular,
    Menlo,
    Monaco,
    Consolas,
    'Liberation Mono',
    'Courier New',
    monospace
  );
  font-size: 12px;
  color: var(--text-primary-color);
  resize: none;
}

.paste-input:focus {
  outline: none;
  border-color: var(--primary-color);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--primary-color) 20%, transparent);
}
</style>
