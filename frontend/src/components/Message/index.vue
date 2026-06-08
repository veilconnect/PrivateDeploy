<script setup lang="ts">
import { computed } from 'vue'

import i18n from '@/lang'

export type MessageIcon = 'info' | 'warn' | 'error' | 'success'

interface Props {
  icon?: MessageIcon
  content: string
}

const props = withDefaults(defineProps<Props>(), {
  icon: 'info',
})

defineEmits(['close'])

const iconMap = {
  info: 'messageInfo',
  success: 'messageSuccess',
  error: 'messageError',
  warn: 'messageWarn',
}

const icon = computed(() => iconMap[props.icon] as any)
const resolvedContent = computed(() => {
  try {
    if ((i18n.global.te as (key: string) => boolean)(props.content)) {
      return (i18n.global.t as (key: string) => string)(props.content)
    }
  } catch (error) {
    if (import.meta.env.DEV) {
      console.warn('[Message] Failed to translate content:', error)
    }
  }
  return props.content
})
</script>

<template>
  <Transition name="slide-down" appear>
    <div class="gui-message flex items-center p-8 pl-16 rounded-8 my-4 shadow">
      <Icon class="shrink-0" :icon="icon" />
      <div class="text-14 pl-12 break-all">{{ resolvedContent }}</div>
      <Button
        @click="$emit('close')"
        icon="close"
        :icon-size="10"
        type="text"
        size="small"
        class="close px-4 invisible"
      />
    </div>
  </Transition>
</template>

<style lang="less" scoped>
.gui-message {
  background: var(--toast-bg);
  &:hover {
    .close {
      visibility: visible;
    }
  }
}
</style>
