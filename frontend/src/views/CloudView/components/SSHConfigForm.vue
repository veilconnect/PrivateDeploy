<script setup lang="ts">
import { reactive, ref, computed } from 'vue'

import { TestSSHConnection } from '@/bridge'
import { logError } from '@/utils/logger'

import type { SSHServerInfo } from '@/types/cloud'

const emit = defineEmits<{
  (event: 'deploy', config: Record<string, string>): void
}>()

const form = reactive({
  host: '',
  port: '22',
  username: 'root',
  authMethod: 'password' as 'password' | 'key',
  password: '',
  privateKey: '',
})

const testing = ref(false)
const testResult = ref<{ success: boolean; info?: SSHServerInfo; error?: string } | null>(null)
const deploying = ref(false)

const canTest = computed(() => {
  if (!form.host.trim()) return false
  if (form.authMethod === 'password' && !form.password) return false
  if (form.authMethod === 'key' && !form.privateKey) return false
  return true
})

const canDeploy = computed(() => canTest.value && testResult.value?.success)

const buildExtra = (): Record<string, string> => {
  const extra: Record<string, string> = {
    host: form.host.trim(),
    port: form.port || '22',
    username: form.username || 'root',
    authMethod: form.authMethod,
  }
  if (form.authMethod === 'password') {
    extra.password = form.password
  } else {
    extra.privateKey = form.privateKey
  }
  return extra
}

const handleTest = async () => {
  testing.value = true
  testResult.value = null
  try {
    const res = await TestSSHConnection(JSON.stringify(buildExtra()))
    if (res.flag) {
      const info: SSHServerInfo = JSON.parse(res.data)
      testResult.value = { success: true, info }
    } else {
      testResult.value = { success: false, error: res.data }
    }
  } catch (err: any) {
    logError('[SSHConfigForm] Test connection failed', err)
    testResult.value = { success: false, error: err.message || String(err) }
  } finally {
    testing.value = false
  }
}

const handleDeploy = () => {
  deploying.value = true
  emit('deploy', buildExtra())
}

const handleFileSelect = (e: Event) => {
  const input = e.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return
  const reader = new FileReader()
  reader.onload = () => {
    form.privateKey = reader.result as string
  }
  reader.readAsText(file)
}

defineExpose({ deploying })
</script>

<template>
  <div class="ssh-config-form flex flex-col gap-4">
    <div class="grid gap-4 md:grid-cols-2">
      <!-- Host / IP -->
      <div class="form-field">
        <label class="form-label">主机 IP</label>
        <Input v-model="form.host" placeholder="203.0.113.10" auto-size />
      </div>

      <!-- Port -->
      <div class="form-field">
        <label class="form-label">SSH 端口</label>
        <Input v-model="form.port" placeholder="22" auto-size />
      </div>

      <!-- Username -->
      <div class="form-field">
        <label class="form-label">用户名</label>
        <Input v-model="form.username" placeholder="root" auto-size />
      </div>

      <!-- Auth Method -->
      <div class="form-field">
        <label class="form-label">认证方式</label>
        <div class="flex gap-4 items-center h-[36px]">
          <label class="flex items-center gap-1.5 cursor-pointer">
            <input
              v-model="form.authMethod"
              type="radio"
              name="authMethod"
              value="password"
              class="accent-primary"
            />
            密码
          </label>
          <label class="flex items-center gap-1.5 cursor-pointer">
            <input
              v-model="form.authMethod"
              type="radio"
              name="authMethod"
              value="key"
              class="accent-primary"
            />
            私钥
          </label>
        </div>
      </div>

      <!-- Password -->
      <div v-if="form.authMethod === 'password'" class="form-field md:col-span-2">
        <label class="form-label">密码</label>
        <Input v-model="form.password" type="password" placeholder="SSH 登录密码" auto-size />
      </div>

      <!-- Private Key -->
      <div v-if="form.authMethod === 'key'" class="form-field md:col-span-2">
        <label class="form-label">私钥</label>
        <textarea
          v-model="form.privateKey"
          class="w-full h-24 px-3 py-2 text-xs font-mono border rounded resize-none bg-canvas"
          placeholder="REMOVED_PRIVATE_KEY_HEADER&#10;...&#10;REMOVED_PRIVATE_KEY_FOOTER"
        />
        <div class="mt-1">
          <label class="inline-flex items-center gap-1.5 text-xs text-primary cursor-pointer hover:underline">
            <input type="file" class="hidden" accept=".pem,.key,*" @change="handleFileSelect" />
            选择私钥文件
          </label>
        </div>
      </div>
    </div>

    <!-- Test result -->
    <div v-if="testResult" class="px-3 py-2 text-sm rounded" :class="testResult.success ? 'bg-green-50 dark:bg-green-900/20 text-green-700 dark:text-green-400' : 'bg-red-50 dark:bg-red-900/20 text-red-700 dark:text-red-400'">
      <template v-if="testResult.success && testResult.info">
        连接成功 — {{ testResult.info.os }} ({{ testResult.info.arch }}), {{ testResult.info.memoryMB }}MB RAM
      </template>
      <template v-else>
        连接失败: {{ testResult.error }}
      </template>
    </div>

    <!-- Actions -->
    <div class="flex gap-3">
      <Button :disabled="!canTest" :loading="testing" type="link" @click="handleTest">
        {{ testing ? '测试中...' : '测试连接' }}
      </Button>
      <Button :disabled="!canDeploy" :loading="deploying" type="primary" @click="handleDeploy">
        {{ deploying ? '部署中...' : '部署' }}
      </Button>
    </div>
  </div>
</template>
