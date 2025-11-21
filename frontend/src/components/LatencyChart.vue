<template>
  <div class="latency-chart">
    <div class="chart-header">
      <span class="chart-title">{{ title }}</span>
      <span v-if="hasData" class="chart-stats">
        <span class="stat">Avg: {{ avgLatency }}ms</span>
        <span class="stat">Min: {{ minLatency }}ms</span>
        <span class="stat">Max: {{ maxLatency }}ms</span>
      </span>
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

      <!-- Y-axis labels -->
      <text
        :x="5"
        :y="10"
        font-size="10"
        fill="#8c8c8c"
      >
        {{ Math.round(maxLatencyValue) }}ms
      </text>
      <text
        :x="5"
        :y="height - 2"
        font-size="10"
        fill="#8c8c8c"
      >
        {{ Math.round(minLatencyValue) }}ms
      </text>

      <!-- Latency line path -->
      <path
        v-if="hasData"
        :d="linePath"
        fill="none"
        :stroke="lineColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
      />

      <!-- Area under curve -->
      <path
        v-if="hasData"
        :d="areaPath"
        :fill="lineColor"
        opacity="0.1"
      />

      <!-- Data points -->
      <circle
        v-for="(point, index) in normalizedPoints"
        :key="`point-${index}`"
        :cx="point.x"
        :cy="point.y"
        :r="2"
        :fill="getLatencyColor(dataPoints[index].latency)"
        class="latency-point"
      >
        <title>{{ formatTimestamp(dataPoints[index].timestamp) }}: {{ dataPoints[index].latency.toFixed(1) }}ms</title>
      </circle>
    </svg>
    <div class="chart-footer">
      <span class="chart-time-range">{{ timeRangeLabel }}</span>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { type LatencyDataPoint, getLatencyColor } from '@/utils/visualization'
import { formatRelativeTime } from '@/utils'

interface Props {
  title?: string
  data: LatencyDataPoint[]
  width?: number
  height?: number
}

const props = withDefaults(defineProps<Props>(), {
  title: 'Latency History',
  width: 300,
  height: 60,
})

const dataPoints = computed(() => props.data)

const hasData = computed(() => dataPoints.value.length > 0)

const maxLatencyValue = computed(() => {
  if (!hasData.value) return 0
  return Math.max(...dataPoints.value.map(d => d.latency))
})

const minLatencyValue = computed(() => {
  if (!hasData.value) return 0
  return Math.min(...dataPoints.value.map(d => d.latency))
})

const avgLatencyValue = computed(() => {
  if (!hasData.value) return 0
  const sum = dataPoints.value.reduce((acc, d) => acc + d.latency, 0)
  return sum / dataPoints.value.length
})

const avgLatency = computed(() => avgLatencyValue.value.toFixed(1))
const minLatency = computed(() => minLatencyValue.value.toFixed(1))
const maxLatency = computed(() => maxLatencyValue.value.toFixed(1))

const normalizedPoints = computed(() => {
  if (!hasData.value) return []

  const range = maxLatencyValue.value - minLatencyValue.value || 1
  const padding = 10

  return dataPoints.value.map((point, index) => {
    const x = (index / (dataPoints.value.length - 1 || 1)) * (props.width - padding * 2) + padding
    const normalizedLatency = (point.latency - minLatencyValue.value) / range
    const y = props.height - normalizedLatency * (props.height - padding * 2) - padding
    return { x, y }
  })
})

const linePath = computed(() => {
  if (!hasData.value) return ''
  const points = normalizedPoints.value
  if (points.length === 0) return ''

  const pathParts = points.map((p, i) => {
    if (i === 0) return `M ${p.x},${p.y}`
    return `L ${p.x},${p.y}`
  })

  return pathParts.join(' ')
})

const areaPath = computed(() => {
  if (!hasData.value) return ''
  const points = normalizedPoints.value
  if (points.length === 0) return ''

  const linePart = points.map((p, i) => {
    if (i === 0) return `M ${p.x},${p.y}`
    return `L ${p.x},${p.y}`
  }).join(' ')

  const lastPoint = points[points.length - 1]
  const firstPoint = points[0]

  return `${linePart} L ${lastPoint.x},${props.height} L ${firstPoint.x},${props.height} Z`
})

const lineColor = computed(() => {
  const avg = avgLatencyValue.value
  if (avg < 100) return '#52c41a'
  if (avg < 200) return '#faad14'
  if (avg < 500) return '#ff7a45'
  return '#ff4d4f'
})

const timeRangeLabel = computed(() => {
  if (!hasData.value) return 'No data'
  const oldest = dataPoints.value[0]?.timestamp
  const newest = dataPoints.value[dataPoints.value.length - 1]?.timestamp
  if (!oldest || !newest) return 'No data'
  return `${formatRelativeTime(oldest)} - now`
})

const formatTimestamp = (timestamp: number) => {
  return new Date(timestamp).toLocaleString()
}
</script>

<style scoped>
.latency-chart {
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

.chart-stats {
  display: flex;
  gap: 8px;
  font-size: 11px;
  color: #8c8c8c;
}

.stat {
  white-space: nowrap;
}

.chart-svg {
  display: block;
}

.latency-point {
  cursor: pointer;
  transition: r 0.2s;
}

.latency-point:hover {
  r: 4;
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
