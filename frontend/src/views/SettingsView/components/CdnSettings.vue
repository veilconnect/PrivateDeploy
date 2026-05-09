<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'

import { BrowserOpenURL, ClipboardSetText } from '@/bridge'
import { useCdnStore } from '@/stores'
import { confirm, message } from '@/utils'

const { t } = useI18n()
const cdnStore = useCdnStore()

const tokenInput = ref('')
const showStep3 = computed(() => cdnStore.isVerified)

// CF dashboard supports prefilling User API token creation via
// permissionGroupKeys + name + scope params. We use this to skip the
// "five-row permission ritual" entirely — clicking opens a token form with
// the three scopes M1 actually needs already selected.
//
// Source for the URL schema:
//   https://developers.cloudflare.com/fundamentals/api/how-to/account-owned-token-template/
//
// The "Edit Cloudflare Workers" preset users typically pick has only
// Workers Scripts:Edit + Account Settings:Read; using this deeplink also
// adds Zone:Read so the zone picker works after token verification.
const CF_TOKEN_DEEPLINK = (() => {
  const perms = [
    { key: 'workers_scripts', type: 'edit' },
    { key: 'account_settings', type: 'read' },
    { key: 'zone', type: 'read' },
  ]
  const params = new URLSearchParams({
    permissionGroupKeys: JSON.stringify(perms),
    name: 'PrivateDeploy CDN',
    accountId: '*',
    zoneId: 'all',
  })
  return `https://dash.cloudflare.com/profile/api-tokens?${params.toString()}`
})()
const showScopeHelp = ref(false)

// Custom domain (M1) toggle. The toggle starts ON whenever a binding is
// already saved on disk so the panel reflects current state, even if the
// user opens Settings cold. Manually flipping it off here doesn't unbind
// — the user has to press the explicit "Disable and unbind" button to
// avoid accidental clears.
const customDomainEnabled = ref(false)
const customZoneId = ref('')
const customSubdomain = ref('relay')

watch(
  () => cdnStore.customDomain,
  (cd) => {
    if (cd) {
      customDomainEnabled.value = true
      customZoneId.value = cd.zoneId
      customSubdomain.value = cd.subdomain
    } else {
      customZoneId.value = ''
      customSubdomain.value = 'relay'
    }
  },
  { immediate: true },
)

// Zones are fetched lazily when the user opens the toggle. We never hit CF
// at panel-mount because the user might have a verified token but no zones
// (CF token scope can be Workers-only) and there's nothing to display in
// that case until they ask.
const handleEnableToggle = async (next: boolean) => {
  customDomainEnabled.value = next
  if (next && cdnStore.zones.length === 0) {
    try {
      await cdnStore.refreshZones()
    } catch (err: any) {
      message.error(err?.message || String(err))
    }
  }
}

const zoneOptions = computed(() =>
  cdnStore.zones.map((z) => ({ label: z.name, value: z.id })),
)

const previewHost = computed(() => {
  const sub = customSubdomain.value.trim()
  if (!sub) return ''
  const zone = cdnStore.zones.find((z) => z.id === customZoneId.value)
  if (!zone) return ''
  return `${sub}.${zone.name}`
})

const handleSaveCustomDomain = async () => {
  const zoneId = customZoneId.value
  const subdomain = customSubdomain.value.trim()
  if (!zoneId || !subdomain) {
    message.error('cdn.customDomain.zone')
    return
  }
  const ok = await cdnStore.setCustomDomain(zoneId, subdomain)
  if (ok) {
    message.success('common.success')
  } else if (cdnStore.lastError) {
    message.error(cdnStore.lastError)
  }
}

const handleClearCustomDomain = async () => {
  await cdnStore.clearCustomDomain()
  customDomainEnabled.value = false
  message.success(t('cdn.customDomain.cleared'))
}

const handleReloadZones = async () => {
  try {
    await cdnStore.refreshZones()
  } catch (err: any) {
    message.error(err?.message || String(err))
  }
}

const statusLabel = computed(() => {
  switch (cdnStore.status) {
    case 'verified':
      return t('cdn.status.verified')
    case 'unverified':
      return t('cdn.status.unverified')
    default:
      return t('cdn.status.disabled')
  }
})

const statusType = computed(() => {
  switch (cdnStore.status) {
    case 'verified':
      return 'success'
    case 'unverified':
      return 'warning'
    default:
      return 'default'
  }
})

const handleVerify = async () => {
  const token = tokenInput.value.trim()
  if (!token) {
    message.error('cdn.tokenInput.placeholder')
    return
  }
  const ok = await cdnStore.verify(token)
  if (ok) {
    tokenInput.value = ''
    message.success('cdn.status.verified')
  } else if (cdnStore.lastError) {
    message.error(cdnStore.lastError)
  }
}

const handleClear = async () => {
  try {
    await confirm('common.warning', t('cdn.confirm.clear'))
  } catch {
    return
  }
  await cdnStore.clear()
  tokenInput.value = ''
  message.success('common.success')
}

const handleCopyExample = async () => {
  if (!cdnStore.workersDevExample) return
  try {
    await ClipboardSetText(cdnStore.workersDevExample)
    message.success('common.copied')
  } catch (err: any) {
    message.error(err?.message || String(err))
  }
}

onMounted(async () => {
  if (!cdnStore.initialized) {
    try {
      await cdnStore.refresh()
    } catch (err: any) {
      message.error(err?.message || String(err))
    }
  }
})
</script>

<template>
  <div>
    <div class="px-16 py-8">
      <div class="text-18 font-bold pt-8 pb-4 flex items-center gap-8">
        {{ t('cdn.title') }}
        <Tag :type="statusType">{{ statusLabel }}</Tag>
      </div>
      <div class="text-12 opacity-70 pb-12">{{ t('cdn.subtitle') }}</div>
      <div class="text-12 pb-12">
        <Button
          type="text"
          icon="link"
          size="small"
          @click="BrowserOpenURL('https://github.com/anthropics/PrivateDeploy/blob/main/docs/cdn-acceleration/README.md')"
        >
          {{ t('cdn.docsLink') }}
        </Button>
      </div>
    </div>

    <div class="px-16 py-8">
      <div class="text-14 font-bold pt-4 pb-8">{{ t('cdn.setup.step1') }}</div>
      <div class="text-12 opacity-70 pb-8">{{ t('cdn.setup.step1Body') }}</div>
      <Button
        type="primary"
        size="small"
        icon="link"
        @click="BrowserOpenURL(CF_TOKEN_DEEPLINK)"
      >
        {{ t('cdn.setup.createTokenAuto') }}
      </Button>
      <div class="text-12 pt-8">
        <Button
          type="text"
          size="small"
          :icon="showScopeHelp ? 'arrowDown' : 'arrowRight'"
          @click="showScopeHelp = !showScopeHelp"
        >
          {{ t('cdn.setup.scopeChecklistTitle') }}
        </Button>
      </div>
      <div v-if="showScopeHelp" class="text-12 opacity-80 pt-4 pl-12">
        <ul class="font-mono">
          <li>· Account · Workers Scripts · Edit</li>
          <li>· Account · Account Settings · Read</li>
          <li>· Zone · Zone · Read</li>
        </ul>
        <div class="pt-8 opacity-70">{{ t('cdn.setup.scopeChecklistNote') }}</div>
        <Button
          type="text"
          size="small"
          icon="link"
          class="mt-4"
          @click="BrowserOpenURL('https://dash.cloudflare.com/profile/api-tokens')"
        >
          {{ t('cdn.setup.openTokenList') }}
        </Button>
      </div>
    </div>

    <div class="px-16 py-8">
      <div class="text-14 font-bold pt-4 pb-8">{{ t('cdn.setup.step2') }}</div>
      <div class="text-12 opacity-70 pb-8">{{ t('cdn.setup.step2Body') }}</div>
      <div class="flex items-center gap-8 flex-wrap">
        <Input
          v-model="tokenInput"
          editable
          :placeholder="t('cdn.tokenInput.placeholder')"
          class="flex-1"
          style="min-width: 240px"
          type="password"
        />
        <Button
          type="primary"
          :loading="cdnStore.verifying"
          :disabled="cdnStore.verifying || tokenInput.trim().length === 0"
          @click="handleVerify"
        >
          {{ cdnStore.verifying ? t('cdn.tokenInput.verifying') : t('cdn.tokenInput.verify') }}
        </Button>
        <Button v-if="cdnStore.isConfigured" type="text" @click="handleClear">
          {{ t('cdn.tokenInput.clear') }}
        </Button>
      </div>
      <div v-if="cdnStore.lastError" class="text-12 mt-8" style="color: var(--danger-color, #d33)">
        {{ cdnStore.lastError }}
      </div>
    </div>

    <div v-if="cdnStore.isVerified" class="px-16 py-8">
      <div class="text-14 font-bold pt-4 pb-8">{{ t('cdn.account.email') }}</div>
      <div class="text-13 pb-8">{{ cdnStore.accountEmail || '—' }}</div>
      <div class="text-14 font-bold pt-4 pb-8">{{ t('cdn.account.workersSubdomain') }}</div>
      <div v-if="cdnStore.workersSubdomain" class="text-13 pb-8 font-mono">
        *.{{ cdnStore.workersSubdomain }}.workers.dev
      </div>
      <div v-else class="text-12 pb-8" style="color: var(--warning-color, #c80)">
        {{ t('cdn.account.noSubdomain') }}
      </div>
      <div v-if="cdnStore.workersDevExample">
        <div class="text-14 font-bold pt-4 pb-8">{{ t('cdn.account.example') }}</div>
        <div class="flex items-center gap-8">
          <code class="text-12">{{ cdnStore.workersDevExample }}</code>
          <Button type="text" size="small" icon="link" @click="handleCopyExample" />
        </div>
      </div>
    </div>

    <div v-if="showStep3" class="px-16 py-8">
      <div class="text-14 font-bold pt-4 pb-8">{{ t('cdn.setup.step3') }}</div>
      <div class="text-12 opacity-70 pb-4">{{ t('cdn.setup.step3Body') }}</div>
    </div>

    <div v-if="cdnStore.isVerified" class="px-16 py-8">
      <div class="text-16 font-bold pt-8 pb-4">{{ t('cdn.customDomain.title') }}</div>
      <div class="text-12 opacity-70 pb-12">{{ t('cdn.customDomain.subtitle') }}</div>

      <div class="flex items-center gap-8 pb-8">
        <Switch
          :model-value="customDomainEnabled"
          @update:model-value="handleEnableToggle"
        />
        <span class="text-13">{{ t('cdn.customDomain.enable') }}</span>
        <Button
          v-if="customDomainEnabled"
          type="text"
          size="small"
          icon="refresh"
          :loading="cdnStore.zonesLoading"
          @click="handleReloadZones"
        >
          {{ t('cdn.customDomain.reload') }}
        </Button>
      </div>

      <div v-if="customDomainEnabled">
        <div v-if="!cdnStore.zonesLoading && cdnStore.zones.length === 0" class="text-12 pb-8" style="color: var(--warning-color, #c80)">
          {{ t('cdn.customDomain.noZones') }}
        </div>

        <div v-else class="flex flex-col gap-8">
          <div class="flex items-center gap-8 flex-wrap">
            <span class="text-13 shrink-0" style="min-width: 80px">{{ t('cdn.customDomain.zone') }}:</span>
            <Select
              v-model="customZoneId"
              :options="zoneOptions"
              :placeholder="t('cdn.customDomain.zonePlaceholder')"
              size="small"
              style="min-width: 240px"
            />
          </div>

          <div class="flex items-center gap-8 flex-wrap">
            <span class="text-13 shrink-0" style="min-width: 80px">{{ t('cdn.customDomain.subdomainLabel') }}:</span>
            <Input
              v-model="customSubdomain"
              editable
              :placeholder="t('cdn.customDomain.subdomainPlaceholder')"
              style="width: 160px"
            />
            <span class="text-12 opacity-70">{{ t('cdn.customDomain.subdomainHint') }}</span>
          </div>

          <div v-if="previewHost" class="text-12 pb-4">
            {{ t('cdn.customDomain.preview', { host: previewHost }) }}
          </div>

          <div class="flex items-center gap-8 pt-4">
            <Button
              type="primary"
              :loading="cdnStore.savingCustomDomain"
              :disabled="
                cdnStore.savingCustomDomain ||
                !customZoneId ||
                customSubdomain.trim().length === 0
              "
              @click="handleSaveCustomDomain"
            >
              {{ cdnStore.savingCustomDomain ? t('cdn.customDomain.saving') : t('cdn.customDomain.save') }}
            </Button>
            <Button
              v-if="cdnStore.customDomain"
              type="text"
              :disabled="cdnStore.savingCustomDomain"
              @click="handleClearCustomDomain"
            >
              {{ t('cdn.customDomain.clear') }}
            </Button>
          </div>

          <div v-if="cdnStore.customDomain" class="text-12 pt-4">
            {{ t('cdn.customDomain.bound', { host: cdnStore.customDomainHost }) }}
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
