<script setup lang="ts">
import { nextTick, reactive, watch } from 'vue'
import { useI18n } from 'vue-i18n'

interface ImportFormState {
  raw: string
}

const props = defineProps<{
  form: ImportFormState
}>()
const emit = defineEmits<{
  (event: 'update:form', value: ImportFormState): void
}>()

const { t } = useI18n()

const localForm = reactive<ImportFormState>({ ...props.form })

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
  () => localForm.raw,
  (value) => {
    if (syncing) return
    emit('update:form', { raw: value })
  },
)
</script>

<template>
  <div class="import-node-modal flex flex-col gap-6">
    <div class="form-field">
      <label class="form-label">{{ t('cloud.manual.importPlaceholder') }}</label>
      <textarea
        v-model="localForm.raw"
        class="import-textarea"
        rows="8"
        spellcheck="false"
        placeholder='[{"label":"example","ipv4":"203.0.113.10","ssPort":443,"ssPassword":"password"}]'
      />
    </div>
    <div class="text-12 text-secondary">
      {{ t('cloud.manual.importHint') }}
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

.import-textarea {
  width: 100%;
  padding: 8px 12px;
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
  resize: vertical;
}

.import-textarea:focus {
  outline: none;
  border-color: var(--primary-color);
  box-shadow: 0 0 0 2px color-mix(in srgb, var(--primary-color) 20%, transparent);
}
</style>
