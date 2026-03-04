<script setup lang="ts">
defineEmits<{
  (event: 'select', method: 'ssh' | 'cloud' | 'manual'): void
}>()
</script>

<template>
  <div class="flex flex-col items-center gap-8 py-8">
    <h2 class="text-xl font-semibold">如何部署你的 VPN 节点？</h2>
    <p class="text-sm text-secondary">选择最适合你的部署方式</p>

    <div class="grid grid-cols-1 md:grid-cols-3 gap-6 w-full max-w-2xl mt-4">
      <button
        class="flex flex-col items-center gap-3 p-6 rounded-lg border-2 border-secondary hover:border-primary transition-colors cursor-pointer"
        @click="$emit('select', 'ssh')"
      >
        <div class="text-3xl">🖥️</div>
        <div class="font-medium">我有服务器</div>
        <div class="text-xs text-secondary text-center">提供 IP + 密码/密钥，通过 SSH 自动部署</div>
      </button>

      <button
        class="flex flex-col items-center gap-3 p-6 rounded-lg border-2 border-secondary hover:border-primary transition-colors cursor-pointer"
        @click="$emit('select', 'cloud')"
      >
        <div class="text-3xl">☁️</div>
        <div class="font-medium">我需要服务器</div>
        <div class="text-xs text-secondary text-center">选择云厂商 + API Key，一键创建 + 部署</div>
      </button>

      <button
        class="flex flex-col items-center gap-3 p-6 rounded-lg border-2 border-secondary hover:border-primary transition-colors cursor-pointer"
        @click="$emit('select', 'manual')"
      >
        <div class="text-3xl">📋</div>
        <div class="font-medium">我有节点信息</div>
        <div class="text-xs text-secondary text-center">手动输入或导入协议链接 (ss://, vless://)</div>
      </button>
    </div>
  </div>
</template>
