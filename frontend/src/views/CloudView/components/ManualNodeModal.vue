<script setup lang="ts">
import { nextTick, reactive, watch } from 'vue'
import { useI18n } from 'vue-i18n'

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
</script>

<template>
  <div class="manual-node-form flex flex-col gap-6">
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
</style>
