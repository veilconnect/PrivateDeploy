<script setup lang="ts">
import { reactive, ref, computed } from 'vue'

import { TestSSHConnection, SaveCloudConfig, SetCloudProvider } from '@/bridge'
import { useCloudStore } from '@/stores'
import { logError } from '@/utils/logger'

const props = defineProps<{
  method: 'ssh' | 'cloud' | 'manual'
}>()

const emit = defineEmits<{
  (event: 'next', config: Record<string, any>): void
  (event: 'back'): void
}>()

const cloudStore = useCloudStore()

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
const cloudProvider = ref<'vultr' | 'digitalocean'>('vultr')
const apiKey = ref('')
const cloudValidating = ref(false)
const cloudValid = ref(false)

// Manual form
const manualImportText = ref('')

const canProceed = computed(() => {
  if (props.method === 'ssh') {
    return sshTestResult.value?.success === true
  }
  if (props.method === 'cloud') {
    return apiKey.value.trim().length > 0
  }
  if (props.method === 'manual') {
    return manualImportText.value.trim().length > 0
  }
  return false
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

    const res = await TestSSHConnection(JSON.stringify(extra))
    sshTestResult.value = { success: res.flag, error: res.flag ? undefined : res.data }
  } catch (err: any) {
    sshTestResult.value = { success: false, error: err.message }
  } finally {
    sshTesting.value = false
  }
}

const handleCloudValidate = async () => {
  cloudValidating.value = true
  try {
    await SetCloudProvider(cloudProvider.value)
    const cfg = {
      provider: cloudProvider.value,
      apiKey: apiKey.value,
    }
    const res = await SaveCloudConfig(JSON.stringify(cfg))
    cloudValid.value = res.flag
    if (res.flag) {
      await cloudStore.loadConfig()
      await cloudStore.fetchRegions()
    }
  } catch (err: any) {
    logError('[Wizard] Cloud validate failed:', err)
  } finally {
    cloudValidating.value = false
  }
}

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
          <div class="flex gap-4">
            <label class="flex items-center gap-1.5 cursor-pointer text-sm">
              <input v-model="cloudProvider" type="radio" value="vultr" class="accent-primary" /> Vultr
            </label>
            <label class="flex items-center gap-1.5 cursor-pointer text-sm">
              <input v-model="cloudProvider" type="radio" value="digitalocean" class="accent-primary" /> DigitalOcean
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
