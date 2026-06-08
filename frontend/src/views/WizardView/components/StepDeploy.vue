<script setup lang="ts">
import { EventsOn, EventsOff } from '@wails/runtime/runtime'
import { ref, onMounted, onUnmounted } from 'vue'

import { useCloudStore } from '@/stores'
import { logError } from '@/utils/logger'
import { parseImportedNodes } from '@/views/CloudView/manualNodeParser'

const props = defineProps<{
  config: Record<string, any>
}>()

defineEmits<{
  (event: 'done'): void
  (event: 'back'): void
}>()

const cloudStore = useCloudStore()

type StepState = 'pending' | 'running' | 'done' | 'error'

const steps = ref([
  { label: '连接服务器', state: 'pending' as StepState },
  { label: '安装依赖', state: 'pending' as StepState },
  { label: '部署协议', state: 'pending' as StepState },
  { label: '配置客户端', state: 'pending' as StepState },
  { label: '验证连通', state: 'pending' as StepState },
])

const currentStep = ref(0)
const deployError = ref('')
const deployDone = ref(false)
const progressMessage = ref('')

const stateIcon = (state: StepState) => {
  switch (state) {
    case 'pending': return '○'
    case 'running': return '◌'
    case 'done': return '●'
    case 'error': return '✕'
  }
}

const stateColor = (state: StepState) => {
  switch (state) {
    case 'pending': return 'text-gray-400'
    case 'running': return 'text-blue-500'
    case 'done': return 'text-green-600'
    case 'error': return 'text-red-500'
  }
}

const updateStep = (index: number, state: StepState) => {
  if (index < steps.value.length) {
    steps.value[index].state = state
  }
}

const runDeploy = async () => {
  try {
    if (props.config.type === 'ssh') {
      // SSH deployment
      updateStep(0, 'running')
      progressMessage.value = '正在连接...'

      const node = await cloudStore.createSSHInstance(props.config.extra)
      updateStep(0, 'done')
      updateStep(1, 'done')
      updateStep(2, 'done')

      // Step 4: Configure client
      updateStep(3, 'running')
      progressMessage.value = '正在配置客户端...'
      // The createSSHInstance already handles subscription + apply
      updateStep(3, 'done')

      // Step 5: Verify
      updateStep(4, 'running')
      progressMessage.value = '正在验证连通性...'
      if (node?.instanceId) {
        const managed = cloudStore.instances.find(n => n.instanceId === node.instanceId)
        if (managed) {
          await cloudStore.verifyNodeConnectivity(managed)
        }
      }
      updateStep(4, 'done')
      deployDone.value = true
    } else if (props.config.type === 'cloud') {
      // Cloud deployment
      updateStep(0, 'running')
      progressMessage.value = '正在创建服务器...'

      // Pick the best region
      const region = cloudStore.regions[0]?.id || ''
      const plan = cloudStore.plans[0]?.id || ''

      const node = await cloudStore.createInstance({
        label: `wizard-node-${Date.now()}`,
        region,
        plan,
      })

      updateStep(0, 'done')
      updateStep(1, 'done')
      updateStep(2, 'done')
      updateStep(3, 'done')

      // Verify
      updateStep(4, 'running')
      progressMessage.value = '正在验证...'
      if (node?.instanceId) {
        const managed = cloudStore.instances.find(n => n.instanceId === node.instanceId)
        if (managed) {
          await cloudStore.verifyNodeConnectivity(managed)
        }
      }
      updateStep(4, 'done')
      deployDone.value = true
    } else if (props.config.type === 'manual') {
      // Manual import — just mark as done
      updateStep(0, 'done')
      updateStep(1, 'done')
      updateStep(2, 'done')

      updateStep(3, 'running')
      progressMessage.value = '正在导入节点...'

      const inputs = parseImportedNodes(props.config.importText as string)
      if (!inputs.length) {
        throw new Error('manual-import-invalid')
      }
      await cloudStore.addManualNodes(inputs)

      updateStep(3, 'done')
      updateStep(4, 'done')
      deployDone.value = true
    }
  } catch (err: any) {
    logError('[Wizard] Deploy failed:', err)
    deployError.value = err.message || String(err)
    const current = currentStep.value
    updateStep(current, 'error')
  }
}

onMounted(() => {
  EventsOn('cloud:ssh:progress', (_id: string, stage: string, msg: string) => {
    progressMessage.value = msg
    // Map stages to step indices
    const stageMap: Record<string, number> = {
      connecting: 0,
      detecting: 0,
      generating: 1,
      deploying: 2,
      verifying: 4,
      ready: 4,
      failed: -1,
    }
    const stepIdx = stageMap[stage]
    if (stepIdx !== undefined && stepIdx >= 0) {
      // Mark previous steps as done
      for (let i = 0; i < stepIdx; i++) {
        if (steps.value[i].state !== 'done') {
          updateStep(i, 'done')
        }
      }
      updateStep(stepIdx, 'running')
      currentStep.value = stepIdx
    }
    if (stage === 'failed') {
      deployError.value = msg
    }
  })

  // Start deployment automatically
  runDeploy()
})

onUnmounted(() => {
  EventsOff('cloud:ssh:progress')
})
</script>

<template>
  <div class="flex flex-col items-center gap-6 py-8 w-full max-w-lg mx-auto">
    <h3 class="text-lg font-semibold">{{ deployDone ? '部署完成' : '正在部署...' }}</h3>

    <!-- Steps -->
    <div class="flex flex-col gap-3 w-full">
      <div
        v-for="(step, idx) in steps"
        :key="idx"
        class="flex items-center gap-3 px-4 py-2 rounded"
        :class="step.state === 'running' ? 'bg-blue-50 dark:bg-blue-900/20' : ''"
      >
        <span :class="stateColor(step.state)" class="text-lg font-bold w-6 text-center">{{ stateIcon(step.state) }}</span>
        <span class="text-sm flex-1">{{ step.label }}</span>
        <span v-if="step.state === 'running'" class="text-xs text-blue-500 animate-pulse">...</span>
      </div>
    </div>

    <!-- Progress message -->
    <div v-if="progressMessage && !deployDone" class="text-xs text-secondary text-center">
      {{ progressMessage }}
    </div>

    <!-- Error -->
    <div v-if="deployError" class="w-full px-4 py-2 text-sm rounded bg-red-100 dark:bg-red-900/20 text-red-700 dark:text-red-400">
      {{ deployError }}
    </div>

    <!-- Done actions -->
    <div v-if="deployDone" class="flex gap-4 mt-4">
      <Button type="primary" @click="$emit('done')">进入仪表板</Button>
    </div>
    <div v-else-if="deployError" class="flex gap-4 mt-4">
      <Button @click="$emit('back')">返回</Button>
      <Button type="primary" @click="runDeploy">重试</Button>
    </div>
  </div>
</template>
