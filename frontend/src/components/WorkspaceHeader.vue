<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRoute, useRouter } from 'vue-router'

import { useEnvStore, useKernelApiStore } from '@/stores'
import { APP_TITLE } from '@/utils'

const { t } = useI18n()
const route = useRoute()
const router = useRouter()
const envStore = useEnvStore()
const kernelApiStore = useKernelApiStore()

const pageTitle = computed(() => {
  const key = route.meta?.name as string | undefined
  if (!key) {
    return APP_TITLE
  }
  const translated = t(key)
  return translated === key ? APP_TITLE : translated
})

const kernelStateLabel = computed(() => {
  if (kernelApiStore.starting) return t('workbench.status.kernelStarting')
  if (kernelApiStore.stopping) return t('workbench.status.kernelStopping')
  return kernelApiStore.running ? t('workbench.status.kernelRunning') : t('workbench.status.kernelStopped')
})

const kernelStateColor = computed(() => {
  if (kernelApiStore.starting || kernelApiStore.stopping) return 'cyan'
  return kernelApiStore.running ? 'green' : 'default'
})

const proxyStateColor = computed(() => {
  return envStore.systemProxyState === 'managed' ? 'primary' : 'default'
})

const isSettingsPage = computed(() => route.name === 'Settings')

const handleTogglePage = () => {
  if (isSettingsPage.value) {
    router.push({ name: 'Workbench' })
    return
  }
  router.push({ name: 'Settings' })
}
</script>

<template>
  <div
    v-if="route.name !== 'Wizard'"
    class="flex items-center gap-16 rounded-16 px-20 py-16 mb-20 workspace-header"
  >
    <div class="min-w-0">
      <div class="text-18 font-bold leading-none">{{ APP_TITLE }}</div>
      <div class="text-12 text-secondary mt-6 truncate">{{ pageTitle }}</div>
    </div>

    <div class="ml-auto flex items-center gap-8">
      <Tag :color="kernelStateColor">
        {{ kernelStateLabel }}
      </Tag>
      <Tag :color="proxyStateColor">
        {{ t(`settings.systemProxy.status.${envStore.systemProxyState}`) }}
      </Tag>
      <Button
        @click="handleTogglePage"
        :icon="isSettingsPage ? 'overview' : 'settings2'"
        type="primary"
      >
        {{ isSettingsPage ? t('router.workbench') : t('router.settings') }}
      </Button>
    </div>
  </div>
</template>

<style scoped>
.workspace-header {
  background:
    radial-gradient(circle at top left, color-mix(in srgb, var(--primary-color) 12%, transparent), transparent 45%),
    linear-gradient(135deg, color-mix(in srgb, var(--card-bg) 82%, black 18%), var(--card-bg));
  border: 1px solid color-mix(in srgb, var(--border-color) 78%, transparent);
}
</style>
