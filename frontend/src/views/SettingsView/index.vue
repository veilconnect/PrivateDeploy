<script setup lang="ts">
import { computed } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRoute, useRouter } from 'vue-router'

import { useAppStore } from '@/stores'
import CloudView from '@/views/CloudView/index.vue'
import ProfilesView from '@/views/ProfilesView/index.vue'
import RulesetsView from '@/views/RulesetsView/index.vue'

import CdnSettings from './components/CdnSettings.vue'
import CoreSettings from './components/CoreSettings.vue'
import GeneralSettings from './components/GeneralSettings.vue'

const settings = [
  { key: 'general', tab: 'settings.general' },
  { key: 'kernel', tab: 'router.kernel' },
  { key: 'cloud', tab: 'router.subscriptions' },
  { key: 'profiles', tab: 'router.profiles' },
  { key: 'rulesets', tab: 'router.rulesets' },
  { key: 'cdn', tab: 'cdn.title' },
]

const { t } = useI18n()
const route = useRoute()
const router = useRouter()
const appStore = useAppStore()

const settingsKeys = new Set(settings.map((item) => item.key))

const activeKey = computed({
  get() {
    const tab = typeof route.query.tab === 'string' ? route.query.tab : ''
    return settingsKeys.has(tab) ? tab : settings[0].key
  },
  set(value: string) {
    router.replace({
      name: 'Settings',
      query: value === settings[0].key ? {} : { tab: value },
    })
  },
})
</script>

<template>
  <Tabs v-model:active-key="activeKey" :items="settings" height="100%">
    <template #general>
      <GeneralSettings />
    </template>

    <template #kernel>
      <CoreSettings />
    </template>

    <template #cloud>
      <CloudView />
    </template>

    <template #profiles>
      <ProfilesView />
    </template>

    <template #rulesets>
      <RulesetsView />
    </template>

    <template #cdn>
      <CdnSettings />
    </template>

    <template #extra>
      <Button @click="appStore.showAbout = true" type="text">
        {{ t('router.about') }}
      </Button>
    </template>
  </Tabs>
</template>
