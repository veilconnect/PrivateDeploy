<script setup lang="ts">
import { ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRouter } from 'vue-router'

import StepCredentials from './components/StepCredentials.vue'
import StepDeploy from './components/StepDeploy.vue'
import StepMethod from './components/StepMethod.vue'

const { t } = useI18n()
const router = useRouter()

const currentStep = ref(1)
const deployMethod = ref<'ssh' | 'cloud' | 'manual'>('ssh')
const deployConfig = ref<Record<string, any>>({})

const handleMethodSelect = (method: 'ssh' | 'cloud' | 'manual') => {
  deployMethod.value = method
  currentStep.value = 2
}

const handleCredentialsNext = (config: Record<string, any>) => {
  deployConfig.value = config
  currentStep.value = 3
}

const handleDone = () => {
  router.push('/')
}

const handleBack = () => {
  if (currentStep.value > 1) {
    currentStep.value -= 1
  }
}
</script>

<template>
  <div class="wizard-view flex flex-col items-center py-24 px-8">
    <!-- Step indicator -->
    <div class="flex items-center gap-8 mb-20">
      <template v-for="step in 3" :key="step">
        <div
          class="step-dot"
          :class="step <= currentStep ? 'step-dot--active' : ''"
        >
          {{ step }}
        </div>
        <div v-if="step < 3" class="step-line" :class="step < currentStep ? 'step-line--active' : ''" />
      </template>
    </div>

    <!-- Step content -->
    <div class="wizard-content">
      <StepMethod v-if="currentStep === 1" @select="handleMethodSelect" />
      <StepCredentials
        v-else-if="currentStep === 2"
        :method="deployMethod"
        @next="handleCredentialsNext"
        @back="handleBack"
      />
      <StepDeploy
        v-else-if="currentStep === 3"
        :config="deployConfig"
        @done="handleDone"
        @back="handleBack"
      />
    </div>

    <!-- Skip link -->
    <div v-if="currentStep < 3" class="mt-20">
      <Button @click="handleDone" type="text" size="small">
        {{ t('wizard.skip') || '跳过向导，直接进入' }}
      </Button>
    </div>
  </div>
</template>

<style scoped>
.wizard-view {
  min-height: 100%;
}

.wizard-content {
  width: 100%;
  max-width: 680px;
}

.step-dot {
  width: 32px;
  height: 32px;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  font-weight: 600;
  background: color-mix(in srgb, var(--border-color) 60%, transparent);
  color: var(--secondary-color, #999);
  transition: background 0.2s, color 0.2s;
}

.step-dot--active {
  background: var(--primary-color);
  color: #fff;
}

.step-line {
  width: 48px;
  height: 3px;
  border-radius: 2px;
  background: color-mix(in srgb, var(--border-color) 60%, transparent);
  transition: background 0.2s;
}

.step-line--active {
  background: var(--primary-color);
}
</style>
