<template>
  <div class="connectivity-chart">
    <div class="chart-header">
      <span class="chart-title">{{ title }}</span>
      <span v-if="showUptime" class="chart-uptime">{{ uptime }}% uptime</span>
    </div>
    <svg :width="width" :height="height" class="chart-svg">
      <!-- Background grid -->
      <line
        v-for="i in 5"
        :key="`grid-${i}`"
        :x1="0"
        :y1="(i * height) / 5"
        :x2="width"
        :y2="(i * height) / 5"
        stroke="#f0f0f0"
        stroke-width="1"
      />

      <!-- Connectivity status circles -->
      <circle
        v-for="(point, index) in dataPoints"
        :key="`point-${index}`"
        :cx="(index / (dataPoints.length - 1 || 1)) * width"
        :cy="height / 2"
        :r="3"
        :fill="getStatusColor(point.status)"
        class="status-point"
      >
        <title>{{ formatTimestamp(point.timestamp) }}: {{ point.status }}</title>
      </circle>

      <!-- Connection line -->
      <polyline
        v-if="dataPoints.length > 1"
        :points="linePoints"
        fill="none"
        :stroke="averageColor"
        stroke-width="1.5"
        opacity="0.3"
      />
    </svg>
    <div class="chart-footer">
      <span class="chart-time-range">{{ timeRangeLabel }}</span>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue'

import { formatRelativeTime } from '@/utils'
import {
  type ConnectivityDataPoint,
  getConnectivityStatusColor,
  calculateUptime,
} from '@/utils/visualization'

interface Props {
  title?: string
  data: ConnectivityDataPoint[]
  width?: number
  height?: number
  showUptime?: boolean
}

const props = withDefaults(defineProps<Props>(), {
  title: 'Connectivity Status',
  width: 200,
  height: 40,
  showUptime: true,
})

const dataPoints = computed(() => props.data)

const uptime = computed(() => calculateUptime(dataPoints.value).toFixed(1))

const linePoints = computed(() => {
  if (dataPoints.value.length === 0) return ''
  return dataPoints.value
    .map((point, index) => {
      const x = (index / (dataPoints.value.length - 1 || 1)) * props.width
      const y = props.height / 2
      return `${x},${y}`
    })
    .join(' ')
})

const averageColor = computed(() => {
  const upTimePercent = parseFloat(uptime.value)
  if (upTimePercent >= 95) return '#52c41a'
  if (upTimePercent >= 80) return '#faad14'
  return '#ff4d4f'
})

const timeRangeLabel = computed(() => {
  if (dataPoints.value.length === 0) return 'No data'
  const oldest = dataPoints.value[0]?.timestamp
  const newest = dataPoints.value[dataPoints.value.length - 1]?.timestamp
  if (!oldest || !newest) return 'No data'
  return `${formatRelativeTime(oldest)} - now`
})

const getStatusColor = (status: string) => getConnectivityStatusColor(status)

const formatTimestamp = (timestamp: number) => {
  return new Date(timestamp).toLocaleString()
}
</script>

<style scoped>
.connectivity-chart {
  display: flex;
  flex-direction: column;
  gap: 4px;
  padding: 8px;
  background: #fafafa;
  border-radius: 4px;
}

.chart-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 12px;
}

.chart-title {
  font-weight: 500;
  color: #262626;
}

.chart-uptime {
  font-size: 11px;
  color: #8c8c8c;
}

.chart-svg {
  display: block;
}

.status-point {
  cursor: pointer;
  transition: r 0.2s;
}

.status-point:hover {
  r: 5;
}

.chart-footer {
  font-size: 10px;
  color: #8c8c8c;
  text-align: right;
}

.chart-time-range {
  font-style: italic;
}
</style>
