<script setup lang="ts">
import { reactive, ref, computed, onMounted, watch } from 'vue'
import { useI18n } from 'vue-i18n'

import { TestSSHConnection, SaveCloudConfig, SetCloudProvider } from '@/bridge'
import { useCloudStore } from '@/stores'
import { logError } from '@/utils/logger'

import type { CloudProvider } from '@/types/cloud'

const props = defineProps<{
  method: 'ssh' | 'cloud' | 'manual'
}>()

const emit = defineEmits<{
  (event: 'next', config: Record<string, any>): void
  (event: 'back'): void
}>()

const cloudStore = useCloudStore()
const { t } = useI18n()

// SSH form
const sshForm = reactive({
  host: '',
  port: '22',
  username: 'root',
  authMethod: 'password' as 'password' | 'key',
  password: '',
  privateKey: '',
})
const sshTesting = ref(false)
const sshTestResult = ref<{ success: boolean; error?: string } | null>(null)

// Cloud form
const cloudProvider = ref<CloudProvider>('vultr')
const apiKey = ref('')
const cloudValidating = ref(false)
const cloudValid = ref(false)
const cloudValidationResult = ref<{ success: boolean; message: string } | null>(null)

const fallbackCloudProviderOptions: Array<{ label: string; value: CloudProvider }> = [
  { label: 'Vultr', value: 'vultr' },
  { label: 'DigitalOcean', value: 'digitalocean' },
]

const cloudProviderOptions = computed<Array<{ label: string; value: CloudProvider }>>(() => {
  const options = cloudStore.availableProviders
    .filter((provider) => provider.name !== 'ssh')
    .map((provider) => ({
      label: provider.displayName,
      value: provider.name as CloudProvider,
    }))
  return options.length > 0 ? options : fallbackCloudProviderOptions
})

// Manual form
const manualImportText = ref('')

const canProceed = computed(() => {
  if (props.method === 'ssh') {
    return sshTestResult.value?.success === true
  }
  if (props.method === 'cloud') {
    return cloudValid.value
  }
  if (props.method === 'manual') {
    return manualImportText.value.trim().length > 0
  }
  return false
})

onMounted(async () => {
  if (props.method !== 'cloud') return
  try {
    await cloudStore.loadProviders()
    await cloudStore.loadConfig().catch(() => undefined)

    if (cloudStore.config.provider && cloudProviderOptions.value.some((item) => item.value === cloudStore.config.provider)) {
      cloudProvider.value = cloudStore.config.provider
    }

    if (cloudStore.config.apiKey?.trim()) {
      apiKey.value = cloudStore.config.apiKey
      try {
        await cloudStore.fetchRegions().catch(() => undefined)
        await cloudStore.fetchPlans().catch(() => undefined)
        await cloudStore.refreshInstances(true, true)
        cloudValid.value = true
        cloudValidationResult.value = {
          success: true,
          message: cloudStore.instances.length > 0
            ? t('cloud.credentials.loadedSavedKeyWithNodes', { count: cloudStore.instances.length })
            : t('cloud.credentials.loadedSavedKeyEmpty'),
        }
      } catch (err) {
        cloudValid.value = false
        cloudValidationResult.value = {
          success: false,
          message: err instanceof Error ? err.message : String(err),
        }
        logError('[Wizard] load saved cloud config failed:', err)
      }
    }

    const candidates = cloudProviderOptions.value
    if (!candidates.some((item) => item.value === cloudProvider.value) && candidates.length > 0) {
      cloudProvider.value = candidates[0].value
    }
  } catch (err) {
    logError('[Wizard] loadProviders failed:', err)
  }
})

const handleSSHTest = async () => {
  sshTesting.value = true
  sshTestResult.value = null
  try {
    const extra: Record<string, string> = {
      host: sshForm.host,
      port: sshForm.port,
      username: sshForm.username,
      authMethod: sshForm.authMethod,
    }
    if (sshForm.authMethod === 'password') {
      extra.password = sshForm.password
    } else {
      extra.privateKey = sshForm.privateKey
    }

    await TestSSHConnection(extra)
    sshTestResult.value = { success: true }
  } catch (err: any) {
    sshTestResult.value = { success: false, error: err?.message || String(err) || '连接测试失败，请检查 SSH 信息。' }
  } finally {
    sshTesting.value = false
  }
}

const handleCloudValidate = async () => {
  cloudValidating.value = true
  cloudValidationResult.value = null
  try {
    await SetCloudProvider(cloudProvider.value)
    const cfg = {
      provider: cloudProvider.value,
      apiKey: apiKey.value,
    }
    await SaveCloudConfig(cfg)
    await cloudStore.loadConfig()
    await cloudStore.fetchRegions()
    await cloudStore.fetchPlans()
    await cloudStore.refreshInstances(true, true)
    cloudValid.value = true
    cloudValidationResult.value = {
      success: true,
      message: cloudStore.instances.length > 0
        ? t('cloud.credentials.validatedWithNodes', { count: cloudStore.instances.length })
        : t('cloud.credentials.validatedEmpty'),
    }
  } catch (err: any) {
    cloudValid.value = false
    cloudValidationResult.value = {
      success: false,
      message: err?.message || 'API Key 验证失败，请检查权限和网络连接。',
    }
    logError('[Wizard] Cloud validate failed:', err)
  } finally {
    cloudValidating.value = false
  }
}

watch([cloudProvider, apiKey], ([nextProvider, nextApiKey], [prevProvider, prevApiKey]) => {
  if (nextProvider === prevProvider && nextApiKey === prevApiKey) {
    return
  }
  cloudValid.value = false
  cloudValidationResult.value = null
})

const handleNext = () => {
  if (props.method === 'ssh') {
    const extra: Record<string, string> = {
      host: sshForm.host,
      port: sshForm.port,
      username: sshForm.username,
      authMethod: sshForm.authMethod,
    }
    if (sshForm.authMethod === 'password') extra.password = sshForm.password
    else extra.privateKey = sshForm.privateKey
    emit('next', { type: 'ssh', extra })
  } else if (props.method === 'cloud') {
    emit('next', { type: 'cloud', provider: cloudProvider.value, apiKey: apiKey.value })
  } else {
    emit('next', { type: 'manual', importText: manualImportText.value })
  }
}
</script>

<template>
  <div class="flex flex-col gap-6 py-4 w-full max-w-lg mx-auto">
    <!-- SSH Credentials -->
    <template v-if="method === 'ssh'">
      <h3 class="text-lg font-semibold">SSH 服务器信息</h3>
      <div class="grid gap-4 grid-cols-2">
        <div class="form-field">
          <label class="form-label text-sm">主机 IP</label>
          <Input v-model="sshForm.host" placeholder="203.0.113.10" auto-size />
        </div>
        <div class="form-field">
          <label class="form-label text-sm">端口</label>
          <Input v-model="sshForm.port" placeholder="22" auto-size />
        </div>
        <div class="form-field">
          <label class="form-label text-sm">用户名</label>
          <Input v-model="sshForm.username" placeholder="root" auto-size />
        </div>
        <div class="form-field">
          <label class="form-label text-sm">认证方式</label>
          <div class="flex gap-4 items-center h-9">
            <label class="flex items-center gap-1.5 cursor-pointer text-sm">
              <input v-model="sshForm.authMethod" type="radio" value="password" class="accent-primary" /> 密码
            </label>
            <label class="flex items-center gap-1.5 cursor-pointer text-sm">
              <input v-model="sshForm.authMethod" type="radio" value="key" class="accent-primary" /> 私钥
            </label>
          </div>
        </div>
        <div v-if="sshForm.authMethod === 'password'" class="form-field col-span-2">
          <label class="form-label text-sm">密码</label>
          <Input v-model="sshForm.password" type="password" placeholder="SSH 密码" auto-size />
        </div>
        <div v-else class="form-field col-span-2">
          <label class="form-label text-sm">私钥</label>
          <textarea v-model="sshForm.privateKey" class="w-full h-20 px-3 py-2 text-xs font-mono border rounded resize-none bg-canvas" placeholder="REMOVED_PRIVATE_KEY_HEADER" />
        </div>
      </div>

      <div v-if="sshTestResult" class="px-3 py-2 text-sm rounded" :class="sshTestResult.success ? 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400' : 'bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-400'">
        {{ sshTestResult.success ? '连接成功' : `连接失败: ${sshTestResult.error}` }}
      </div>

      <Button :loading="sshTesting" @click="handleSSHTest" type="link">
        {{ sshTesting ? '测试中...' : '测试连接' }}
      </Button>
    </template>

    <!-- Cloud Credentials -->
    <template v-if="method === 'cloud'">
      <h3 class="text-lg font-semibold">云厂商 API Key</h3>
      <div class="flex flex-col gap-4">
        <div class="form-field">
          <label class="form-label text-sm">云厂商</label>
          <div class="grid grid-cols-2 gap-2">
            <label
              v-for="option in cloudProviderOptions"
              :key="option.value"
              class="flex items-center gap-1.5 cursor-pointer text-sm"
            >
              <input
                v-model="cloudProvider"
                type="radio"
                :value="option.value"
                class="accent-primary"
              />
              {{ option.label }}
            </label>
          </div>
        </div>
        <div class="form-field">
          <label class="form-label text-sm">API Key</label>
          <Input v-model="apiKey" type="password" :show-password="true" placeholder="输入 API Key" auto-size />
        </div>
        <Button :loading="cloudValidating" @click="handleCloudValidate" type="link">
          {{ cloudValidating ? '验证中...' : '验证 API Key' }}
        </Button>
        <div
          v-if="cloudValidationResult"
          class="px-3 py-2 text-sm rounded"
          :class="cloudValidationResult.success
            ? 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400'
            : 'bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-400'"
        >
          {{ cloudValidationResult.message }}
        </div>
      </div>
    </template>

    <!-- Manual Import -->
    <template v-if="method === 'manual'">
      <h3 class="text-lg font-semibold">导入节点信息</h3>
      <div class="form-field">
        <label class="form-label text-sm">协议链接（每行一个）</label>
        <textarea
          v-model="manualImportText"
          class="w-full h-32 px-3 py-2 text-xs font-mono border rounded resize-none bg-canvas"
          placeholder="ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@server:port&#10;vless://uuid@server:port?security=reality&#10;trojan://password@server:port"
        />
      </div>
    </template>

    <!-- Navigation -->
    <div class="flex justify-between mt-4">
      <Button @click="$emit('back')">返回</Button>
      <Button type="primary" :disabled="!canProceed" @click="handleNext">下一步</Button>
    </div>
  </div>
</template>
