import { computed, ref } from 'vue'

import { buildCloudTableData } from './cloudViewPresentation'

import type { ManagedCloudNode } from '@/stores/cloud'

type CloudStoreLike = {
  instances: ManagedCloudNode[]
}

const columns = [
  { title: 'selection', key: 'selection', width: '40px' },
  { title: 'cloud.table.label', key: 'label', width: '11%' },
  { title: 'cloud.table.region', key: 'region', width: '9%' },
  { title: 'cloud.table.plan', key: 'plan', width: '11%' },
  { title: 'cloud.table.ipAddresses', key: 'ipAddresses', width: '12%' },
  { title: 'cloud.table.protocols', key: 'protocols', width: '17%' },
  { title: 'cloud.table.status', key: 'status', width: '13%' },
  { title: 'cloud.table.connectivity', key: 'connectivity', width: '9%' },
  { title: 'cloud.table.createdAt', key: 'createdAt', width: '8%' },
  { title: 'cloud.table.actions', key: 'actions', width: '11%' },
]

export const useCloudViewTable = (
  cloudStore: CloudStoreLike,
  formatNodeRegion: (regionId: string) => string,
) => {
  const searchQuery = ref('')
  const filterConnectivity = ref<string>('all')
  const filterStatus = ref<string>('all')
  const sortBy = ref<string>('')
  const sortOrder = ref<'asc' | 'desc'>('asc')

  const tableData = computed(() =>
    buildCloudTableData(cloudStore.instances, {
      searchQuery: searchQuery.value,
      filterConnectivity: filterConnectivity.value,
      filterStatus: filterStatus.value,
      sortBy: sortBy.value,
      sortOrder: sortOrder.value,
      formatNodeRegion,
    }),
  )

  const clearFilters = () => {
    searchQuery.value = ''
    filterConnectivity.value = 'all'
    filterStatus.value = 'all'
    sortBy.value = ''
    sortOrder.value = 'asc'
  }

  const hasActiveFilters = computed(() => (
    searchQuery.value.trim() !== '' ||
    filterConnectivity.value !== 'all' ||
    filterStatus.value !== 'all'
  ))

  return {
    clearFilters,
    columns,
    filterConnectivity,
    filterStatus,
    hasActiveFilters,
    searchQuery,
    sortBy,
    sortOrder,
    tableData,
  }
}
