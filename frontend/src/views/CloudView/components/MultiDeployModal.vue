<script setup lang="ts">
import { EventsOn, EventsOff } from '@wails/runtime/runtime'
import { computed, ref, onMounted, onUnmounted } from 'vue'

import { CreateMultipleCloudInstances } from '@/bridge'
import { useCloudStore } from '@/stores'
import { logError } from '@/utils/logger'

import type { CloudRegion, DeployProgress, DeployProgressStatus, MultiDeployResult } from '@/types/cloud'

const props = defineProps<{
  regions: CloudRegion[]
  latencyResults: Record<string, number>
}>()

const emit = defineEmits<{
  (event: 'done', results: MultiDeployResult[]): void
}>()

const cloudStore = useCloudStore()

const selectedRegions = ref<Set<string>>(new Set())
const plan = ref('')
const deploying = ref(false)
const progress = ref<Map<number, DeployProgress>>(new Map())
const results = ref<MultiDeployResult[]>([])

const sortedRegions = computed(() => {
  return [...props.regions].sort((a, b) => {
    const latA = props.latencyResults[a.id] ?? 99999
    const latB = props.latencyResults[b.id] ?? 99999
    return latA - latB
  })
})

const selectedCount = computed(() => selectedRegions.value.size)

const toggleRegion = (id: string) => {
  const s = new Set(selectedRegions.value)
  if (s.has(id)) {
    s.delete(id)
  } else {
    s.add(id)
  }
  selectedRegions.value = s
}

const autoRecommend = () => {
  // Pick top 2-3 regions with lowest latency from different continents
  const seen = new Set<string>()
  const picks = new Set<string>()
  for (const region of sortedRegions.value) {
    if (picks.size >= 3) break
    const continent = region.continent || region.country
    if (!seen.has(continent)) {
      seen.add(continent)
      picks.add(region.id)
    }
  }
  // If we still have < 2, just pick top by latency
  if (picks.size < 2) {
    for (const region of sortedRegions.value) {
      if (picks.size >= 2) break
      picks.add(region.id)
    }
  }
  selectedRegions.value = picks
}

const canDeploy = computed(() => selectedCount.value > 0 && !deploying.value)

const handleDeploy = async (): Promise<MultiDeployResult[] | null> => {
  if (!canDeploy.value) return null
  deploying.value = true
  progress.value = new Map()
  results.value = []

  const configs = Array.from(selectedRegions.value).map((regionId, idx) => ({
    label: `node-${regionId}-${String(idx + 1).padStart(2, '0')}`,
    region: regionId,
    plan: plan.value || cloudStore.config.defaultPlan || '',
  }))

  // Initialize progress for each
  configs.forEach((cfg, idx) => {
    progress.value.set(idx, {
      index: idx,
      status: 'pending' as DeployProgressStatus,
      label: cfg.label,
      message: '等待中...',
    })
  })

  try {
    results.value = await CreateMultipleCloudInstances(configs)
    emit('done', results.value)
    return results.value
  } catch (err: any) {
    logError('[MultiDeploy] Error:', err)
    return null
  } finally {
    deploying.value = false
  }
}

defineExpose({
  canDeploy,
  deploying,
  handleDeploy,
})

const statusColor = (status: DeployProgressStatus) => {
  switch (status) {
    case 'pending': return 'text-gray-500'
    case 'deploying': return 'text-blue-500'
    case 'ready': return 'text-green-600'
    case 'failed': return 'text-red-500'
    default: return ''
  }
}

const statusIcon = (status: DeployProgressStatus) => {
  switch (status) {
    case 'pending': return '○'
    case 'deploying': return '◌'
    case 'ready': return '●'
    case 'failed': return '✕'
    default: return '?'
  }
}

const latencyDisplay = (regionId: string) => {
  const ms = props.latencyResults[regionId]
  if (!ms || ms >= 99999) return ''
  return `${Math.round(ms)}ms`
}

// Listen for multi-deploy progress events
onMounted(() => {
  EventsOn('cloud:multi:progress', (idx: number, status: string, message: string) => {
    const current = progress.value.get(idx)
    if (current) {
      progress.value.set(idx, {
        ...current,
        status: status as DeployProgressStatus,
        message,
      })
      // Force reactivity
      progress.value = new Map(progress.value)
    }
  })
})

onUnmounted(() => {
  EventsOff('cloud:multi:progress')
})
</script>

<template>
  <div class="multi-deploy-modal flex flex-col gap-2 max-h-[70vh] overflow-hidden">
    <!-- Region selection -->
    <div class="flex items-center justify-between">
      <h3 class="text-sm font-semibold">选择部署区域</h3>
      <Button type="link" size="small" @click="autoRecommend">
        自动推荐
      </Button>
    </div>

    <div class="grid grid-cols-2 md:grid-cols-3 gap-2 max-h-24 md:max-h-40 overflow-y-auto pr-1">
      <label
        v-for="region in sortedRegions"
        :key="region.id"
        class="flex items-center gap-2 px-3 py-2 rounded border cursor-pointer transition-colors"
        :class="selectedRegions.has(region.id) ? 'border-primary bg-primary/10' : 'border-secondary hover:border-primary/50'"
      >
        <input
          type="checkbox"
          :checked="selectedRegions.has(region.id)"
          class="accent-primary"
          @change="toggleRegion(region.id)"
        />
        <div class="flex-1 min-w-0">
          <div class="text-xs font-medium truncate">{{ region.city }}</div>
          <div class="text-xs opacity-60">{{ region.country }}</div>
        </div>
        <span v-if="latencyDisplay(region.id)" class="text-xs opacity-50">
          {{ latencyDisplay(region.id) }}
        </span>
      </label>
    </div>

    <!-- Plan selection -->
    <div class="form-field shrink-0" v-if="cloudStore.plans?.length">
      <label class="form-label text-xs">套餐</label>
      <select v-model="plan" class="w-full px-3 py-1.5 text-sm border rounded bg-canvas">
        <option value="">默认</option>
        <option v-for="p in cloudStore.plans" :key="p.id" :value="p.id">
          {{ p.description || p.id }} — ${{ p.monthlyCost }}/mo
        </option>
      </select>
    </div>

    <!-- Deploy progress -->
    <div v-if="progress.size > 0" class="flex flex-col gap-2 max-h-20 overflow-y-auto shrink-0">
      <div
        v-for="[idx, p] of progress"
        :key="idx"
        class="flex items-center gap-2 px-3 py-2 rounded bg-canvas text-sm"
      >
        <span :class="statusColor(p.status)" class="text-base">{{ statusIcon(p.status) }}</span>
        <span class="font-mono text-xs flex-shrink-0">{{ p.label }}</span>
        <span class="text-xs opacity-60 truncate flex-1">{{ p.message }}</span>
      </div>
    </div>

    <div class="shrink-0 border-t border-secondary/50 pt-2">
      <div class="text-xs opacity-60">
        已选择 {{ selectedCount }} 个区域
      </div>
    </div>
  </div>
</template>
