import { defineStore } from 'pinia'
import { ref } from 'vue'
import { parse, stringify } from 'yaml'

import { ReadFile, WriteFile, ReadDir, MoveFile } from '@/bridge'
import { ProfilesFilePath } from '@/constant/app'
import { RulesetType, RuleType } from '@/enums/kernel'
import {
  debounce,
  ignoredError,
  transformProfileV189To190,
  transformProfileV194,
  alert,
} from '@/utils'

import { useRulesetsStore } from './rulesets'

export const useProfilesStore = defineStore('profiles', () => {
  const profiles = ref<IProfile[]>([])

  const pruneInvalidRulesetRefs = (profile: IProfile) => {
    const rulesets = useRulesetsStore().rulesets
    const canValidateLocalRulesets = rulesets.length > 0
    const validLocalRulesets = new Set(rulesets.map((item) => item.id))
    let changed = false

    profile.route.rule_set = profile.route.rule_set.filter((ruleset) => {
      if (ruleset.type !== RulesetType.Local) {
        changed = true
        return false
      }
      if (canValidateLocalRulesets && !validLocalRulesets.has(ruleset.path)) {
        changed = true
        return false
      }
      return true
    })

    const validProfileRulesets = new Set(profile.route.rule_set.map((ruleset) => ruleset.id))
    const normalizeRulesetPayload = <TRule extends { type: string; payload: string }>(rules: TRule[]) =>
      rules.flatMap((rule) => {
        if (rule.type !== RuleType.RuleSet || !canValidateLocalRulesets) {
          return [rule]
        }

        const payload = rule.payload
          .split(',')
          .map((item) => item.trim())
          .filter(Boolean)
          .filter((item) => validProfileRulesets.has(item))

        if (payload.length === 0) {
          changed = true
          return []
        }

        if (payload.join(',') !== rule.payload) {
          changed = true
          return [{ ...rule, payload: payload.join(',') }]
        }

        return [rule]
      })

    profile.route.rules = normalizeRulesetPayload(profile.route.rules)
    profile.dns.rules = normalizeRulesetPayload(profile.dns.rules)

    return changed
  }

  const setupProfiles = async () => {
    const data = await ignoredError(ReadFile, ProfilesFilePath)
    data && (profiles.value = parse(data))

    let needsDiskSync = false
    profiles.value.forEach((profile, index) => {
      if (!(profile as any).route) {
        profiles.value[index] = transformProfileV189To190(profile)
        needsDiskSync = true
      }
    })

    const dirs = await ReadDir('data/.cache')
    const backupProfiles = dirs.find((file) => file.name === 'profiles-backup.yaml')
    if (backupProfiles) {
      const txt = await ReadFile('data/.cache/profiles-backup.yaml')
      const oldProfiles = parse(txt)
      for (const p of oldProfiles) {
        profiles.value.push(transformProfileV189To190(p))
        needsDiskSync = true
      }
      await MoveFile('data/.cache/profiles-backup.yaml', 'data/.cache/profiles-backup.yaml.done')
    }

    if (needsDiskSync) {
      // Remove duplicates
      profiles.value = profiles.value.reduce((p, c) => {
        const x = p.find((item) => item.id === c.id)
        if (!x) {
          return p.concat([c])
        } else {
          return p
        }
      }, [] as IProfile[])

      await saveProfiles()
      alert('Tip', 'The old profiles have been upgraded. Please adjust manually if necessary.')
    }

    needsDiskSync = false
    profiles.value.forEach((profile, index) => {
      // Fix missing invert field
      profile.dns.rules.forEach((rule) => {
        if (typeof rule.invert === 'undefined') {
          rule.invert = false
        }
      })
      // @ts-expect-error(Deprecated)
      if (profile.dns.fakeip) {
        needsDiskSync = true
        profiles.value[index] = transformProfileV194(profile)
      }
      profile.inbounds.forEach((inbound) => {
        if (inbound.tun && !inbound.tun.route_exclude_address) {
          inbound.tun.route_exclude_address = []
          needsDiskSync = true
        }
      })

      if (pruneInvalidRulesetRefs(profile)) {
        needsDiskSync = true
      }
    })

    if (needsDiskSync) {
      await saveProfiles()
    }
  }

  const saveProfiles = debounce(async () => {
    await WriteFile(ProfilesFilePath, stringify(profiles.value))
  }, 100)

  const addProfile = async (p: IProfile) => {
    profiles.value.push(p)
    try {
      await saveProfiles()
    } catch (error) {
      profiles.value.pop()
      throw error
    }
  }

  const deleteProfile = async (id: string) => {
    const idx = profiles.value.findIndex((v) => v.id === id)
    if (idx === -1) return
    const backup = profiles.value.splice(idx, 1)[0]
    try {
      await saveProfiles()
    } catch (error) {
      profiles.value.splice(idx, 0, backup)
      throw error
    }
  }

  const editProfile = async (id: string, p: IProfile) => {
    const idx = profiles.value.findIndex((v) => v.id === id)
    if (idx === -1) return
    const backup = profiles.value.splice(idx, 1, p)[0]
    try {
      await saveProfiles()
    } catch (error) {
      profiles.value.splice(idx, 1, backup)
      throw error
    }
  }

  const getProfileById = (id: string) => profiles.value.find((v) => v.id === id)

  return {
    profiles,
    setupProfiles,
    saveProfiles,
    addProfile,
    editProfile,
    deleteProfile,
    getProfileById,
  }
})
