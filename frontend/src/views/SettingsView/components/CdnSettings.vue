<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useI18n } from 'vue-i18n'

import { BrowserOpenURL, ClipboardSetText } from '@/bridge'
import { useCdnStore } from '@/stores'
import { confirm, message } from '@/utils'

const { t } = useI18n()
const cdnStore = useCdnStore()

const tokenInput = ref('')
const showStep3 = computed(() => cdnStore.isVerified)

const statusLabel = computed(() => {
  switch (cdnStore.status) {
    case 'verified':
      return t('cdn.status.verified')
    case 'unverified':
      return t('cdn.status.unverified')
    default:
      return t('cdn.status.disabled')
  }
})

const statusType = computed(() => {
  switch (cdnStore.status) {
    case 'verified':
      return 'success'
    case 'unverified':
      return 'warning'
    default:
      return 'default'
  }
})

const handleVerify = async () => {
  const token = tokenInput.value.trim()
  if (!token) {
    message.error('cdn.tokenInput.placeholder')
    return
  }
  const ok = await cdnStore.verify(token)
  if (ok) {
    tokenInput.value = ''
    message.success('cdn.status.verified')
  } else if (cdnStore.lastError) {
    message.error(cdnStore.lastError)
  }
}

const handleClear = async () => {
  try {
    await confirm('common.warning', t('cdn.confirm.clear'))
  } catch {
    return
  }
  await cdnStore.clear()
  tokenInput.value = ''
  message.success('common.success')
}

const handleCopyExample = async () => {
  if (!cdnStore.workersDevExample) return
  try {
    await ClipboardSetText(cdnStore.workersDevExample)
    message.success('common.copied')
  } catch (err: any) {
    message.error(err?.message || String(err))
  }
}

onMounted(async () => {
  if (!cdnStore.initialized) {
    try {
      await cdnStore.refresh()
    } catch (err: any) {
      message.error(err?.message || String(err))
    }
  }
})
</script>

<template>
  <div>
    <div class="px-16 py-8">
      <div class="text-18 font-bold pt-8 pb-4 flex items-center gap-8">
        {{ t('cdn.title') }}
        <Tag :type="statusType">{{ statusLabel }}</Tag>
      </div>
      <div class="text-12 opacity-70 pb-12">{{ t('cdn.subtitle') }}</div>
      <div class="text-12 pb-12">
        <Button
          type="text"
          icon="link"
          size="small"
          @click="BrowserOpenURL('https://github.com/anthropics/PrivateDeploy/blob/main/docs/cdn-acceleration/README.md')"
        >
          {{ t('cdn.docsLink') }}
        </Button>
      </div>
    </div>

    <div class="px-16 py-8">
      <div class="text-14 font-bold pt-4 pb-8">{{ t('cdn.setup.step1') }}</div>
      <div class="text-12 opacity-70 pb-8">{{ t('cdn.setup.step1Body') }}</div>
      <Button
        type="text"
        size="small"
        icon="link"
        @click="BrowserOpenURL('https://dash.cloudflare.com/profile/api-tokens')"
      >
        dash.cloudflare.com/profile/api-tokens
      </Button>
    </div>

    <div class="px-16 py-8">
      <div class="text-14 font-bold pt-4 pb-8">{{ t('cdn.setup.step2') }}</div>
      <div class="text-12 opacity-70 pb-8">{{ t('cdn.setup.step2Body') }}</div>
      <div class="flex items-center gap-8 flex-wrap">
        <Input
          v-model="tokenInput"
          editable
          :placeholder="t('cdn.tokenInput.placeholder')"
          class="flex-1"
          style="min-width: 240px"
          type="password"
        />
        <Button
          type="primary"
          :loading="cdnStore.verifying"
          :disabled="cdnStore.verifying || tokenInput.trim().length === 0"
          @click="handleVerify"
        >
          {{ cdnStore.verifying ? t('cdn.tokenInput.verifying') : t('cdn.tokenInput.verify') }}
        </Button>
        <Button v-if="cdnStore.isConfigured" type="text" @click="handleClear">
          {{ t('cdn.tokenInput.clear') }}
        </Button>
      </div>
      <div v-if="cdnStore.lastError" class="text-12 mt-8" style="color: var(--danger-color, #d33)">
        {{ cdnStore.lastError }}
      </div>
    </div>

    <div v-if="cdnStore.isVerified" class="px-16 py-8">
      <div class="text-14 font-bold pt-4 pb-8">{{ t('cdn.account.email') }}</div>
      <div class="text-13 pb-8">{{ cdnStore.accountEmail || '—' }}</div>
      <div class="text-14 font-bold pt-4 pb-8">{{ t('cdn.account.workersSubdomain') }}</div>
      <div v-if="cdnStore.workersSubdomain" class="text-13 pb-8 font-mono">
        *.{{ cdnStore.workersSubdomain }}.workers.dev
      </div>
      <div v-else class="text-12 pb-8" style="color: var(--warning-color, #c80)">
        {{ t('cdn.account.noSubdomain') }}
      </div>
      <div v-if="cdnStore.workersDevExample">
        <div class="text-14 font-bold pt-4 pb-8">{{ t('cdn.account.example') }}</div>
        <div class="flex items-center gap-8">
          <code class="text-12">{{ cdnStore.workersDevExample }}</code>
          <Button type="text" size="small" icon="link" @click="handleCopyExample" />
        </div>
      </div>
    </div>

    <div v-if="showStep3" class="px-16 py-8">
      <div class="text-14 font-bold pt-4 pb-8">{{ t('cdn.setup.step3') }}</div>
      <div class="text-12 opacity-70 pb-4">{{ t('cdn.setup.step3Body') }}</div>
    </div>
  </div>
</template>
