<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'

import StepCredentials from './components/StepCredentials.vue'
import StepDeploy from './components/StepDeploy.vue'
import StepMethod from './components/StepMethod.vue'

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
  router.push('/subscriptions')
}

const handleBack = () => {
  if (currentStep.value > 1) {
    currentStep.value -= 1
  }
}
</script>

<template>
  <div class="wizard-view flex flex-col items-center min-h-full py-12 px-4">
    <!-- Step indicator -->
    <div class="flex items-center gap-2 mb-8">
      <template v-for="step in 3" :key="step">
        <div
          class="w-8 h-8 rounded-full flex items-center justify-center text-sm font-medium transition-colors"
          :class="step <= currentStep ? 'bg-primary text-white' : 'bg-secondary/30 text-secondary'"
        >
          {{ step }}
        </div>
        <div v-if="step < 3" class="w-12 h-0.5" :class="step < currentStep ? 'bg-primary' : 'bg-secondary/30'" />
      </template>
    </div>

    <!-- Step content -->
    <div class="w-full max-w-2xl">
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
    <div v-if="currentStep < 3" class="mt-8">
      <button class="text-xs text-secondary hover:text-primary underline" @click="handleDone">
        跳过向导，直接进入
      </button>
    </div>
  </div>
</template>
