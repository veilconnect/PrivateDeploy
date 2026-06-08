<script setup lang="ts">
import { useI18n } from 'vue-i18n'

import type { IconType } from '@/components/Icon/index.vue'

const { t } = useI18n()

type DeployMethod = 'ssh' | 'cloud' | 'manual'

interface MethodOption {
  key: DeployMethod
  icon: IconType
  title: string
  desc: string
}

defineEmits<{
  (event: 'select', method: DeployMethod): void
}>()

const methods: MethodOption[] = [
  { key: 'ssh' as const, icon: 'link', title: 'wizard.method.ssh', desc: 'wizard.method.sshDesc' },
  { key: 'cloud' as const, icon: 'sparkle', title: 'wizard.method.cloud', desc: 'wizard.method.cloudDesc' },
  { key: 'manual' as const, icon: 'edit', title: 'wizard.method.manual', desc: 'wizard.method.manualDesc' },
]
</script>

<template>
  <div class="flex flex-col items-center gap-16 py-16">
    <div class="text-center">
      <h2 class="text-20 font-bold">{{ t('wizard.title') }}</h2>
      <p class="text-14 text-secondary mt-8">{{ t('wizard.subtitle') }}</p>
    </div>

    <div class="method-grid">
      <button
        v-for="m in methods"
        :key="m.key"
        class="method-card"
        @click="$emit('select', m.key)"
      >
        <div class="method-icon">
          <Icon :icon="m.icon" :size="28" />
        </div>
        <div class="text-16 font-bold mt-12">{{ t(m.title) }}</div>
        <div class="text-12 text-secondary mt-6 text-center">{{ t(m.desc) }}</div>
      </button>
    </div>
  </div>
</template>

<style scoped>
.method-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 16px;
  width: 100%;
  max-width: 640px;
}

.method-card {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 24px 16px;
  border-radius: 12px;
  border: 2px solid var(--border-color);
  background: var(--card-bg);
  cursor: pointer;
  transition: border-color 0.2s, box-shadow 0.2s, transform 0.15s;
}

.method-card:hover {
  border-color: var(--primary-color);
  box-shadow: 0 4px 16px color-mix(in srgb, var(--primary-color) 15%, transparent);
  transform: translateY(-2px);
}

.method-icon {
  width: 56px;
  height: 56px;
  border-radius: 16px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: color-mix(in srgb, var(--primary-color) 10%, transparent);
  color: var(--primary-color);
}
</style>
