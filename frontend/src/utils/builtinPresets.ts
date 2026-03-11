import { FileExists, WriteFile } from '@/bridge'
import {
  DefaultDns,
  DefaultDnsServersIds,
  DefaultExperimental,
  DefaultInboundIds,
  DefaultInbounds,
  DefaultLog,
  DefaultMixin,
  DefaultOutbounds,
  DefaultOutboundIds,
  DefaultScript,
} from '@/constant/profile'
import {
  RuleActionReject,
  ClashMode,
  RuleAction,
  RulesetFormat,
  RulesetType,
  RuleType,
  Strategy,
} from '@/enums/kernel'
import i18n from '@/lang'
import { useAppSettingsStore } from '@/stores/appSettings'
import { useProfilesStore } from '@/stores/profiles'
import { useRulesetsStore } from '@/stores/rulesets'

import type { RuleSet } from '@/stores/rulesets'

export const BuiltinPresetsVersion = 1

export const BuiltinRulesetIds = {
  PrivateLan: 'builtin-ruleset-private-lan',
  SystemConnectivity: 'builtin-ruleset-system-connectivity',
  Mainland: 'builtin-ruleset-mainland',
  AI: 'builtin-ruleset-ai-services',
  Developer: 'builtin-ruleset-developer-platforms',
  Global: 'builtin-ruleset-global-services',
  Ads: 'builtin-ruleset-ads-trackers',
} as const

export const BuiltinProfileIds = {
  Smart: 'builtin-profile-smart-route',
  Global: 'builtin-profile-global-proxy',
  Direct: 'builtin-profile-direct-bypass',
} as const

type BuiltinRulesPayload = {
  version: 1
  rules: Record<string, string[]>[]
}

type BuiltinRulesetSeed = {
  id: string
  key: keyof typeof BuiltinRulesetIds
  path: string
  payload: BuiltinRulesPayload
}

const countRules = (payload: BuiltinRulesPayload) =>
  payload.rules.reduce(
    (total, rule) =>
      total +
      Object.values(rule).reduce((subtotal, value) => subtotal + value.length, 0),
    0,
  )

const createRulesetPayload = (...rules: Record<string, string[]>[]): BuiltinRulesPayload => ({
  version: 1,
  rules,
})

export const buildBuiltinRulesetSeeds = () => [
  {
    id: BuiltinRulesetIds.PrivateLan,
    key: 'PrivateLan',
    path: 'data/rulesets/private-lan.json',
    payload: createRulesetPayload(
      {
        domain_suffix: [
          'lan',
          'local',
          'localdomain',
          'localhost',
          'home.arpa',
          'internal',
          'test',
          'invalid',
          'example',
        ],
      },
      {
        domain: [
          'router.asus.com',
          'routerlogin.net',
          'miwifi.com',
          'openwrt.lan',
          'localhost',
        ],
      },
      {
        ip_cidr: [
          '0.0.0.0/8',
          '10.0.0.0/8',
          '100.64.0.0/10',
          '127.0.0.0/8',
          '169.254.0.0/16',
          '172.16.0.0/12',
          '192.168.0.0/16',
          '224.0.0.0/4',
          '240.0.0.0/4',
          '::1/128',
          'fc00::/7',
          'fe80::/10',
        ],
      },
    ),
  },
  {
    id: BuiltinRulesetIds.SystemConnectivity,
    key: 'SystemConnectivity',
    path: 'data/rulesets/system-connectivity.json',
    payload: createRulesetPayload(
      {
        domain: [
          'captive.apple.com',
          'gsp1.apple.com',
          'time.apple.com',
          'time-ios.apple.com',
          'connectivitycheck.gstatic.com',
          'clients3.google.com',
          'connect.rom.miui.com',
          'detectportal.firefox.com',
          'msftconnecttest.com',
          'msftncsi.com',
          'time.windows.com',
          'www.msftconnecttest.com',
          'www.msftncsi.com',
        ],
      },
      {
        domain_suffix: ['ntp.org', 'pool.ntp.org'],
      },
    ),
  },
  {
    id: BuiltinRulesetIds.Mainland,
    key: 'Mainland',
    path: 'data/rulesets/mainland.json',
    payload: createRulesetPayload(
      {
        domain_suffix: [
          'cn',
          '10010.com',
          '12306.cn',
          '126.net',
          '163.com',
          '360.cn',
          '58.com',
          'alicdn.com',
          'alipay.com',
          'aliyun.com',
          'aliyuncs.com',
          'bilibili.com',
          'bytedance.com',
          'csdn.net',
          'douyin.com',
          'douyu.com',
          'ele.me',
          'gtimg.com',
          'huawei.com',
          'iqiyi.com',
          'jd.com',
          'mi.com',
          'mihoyo.com',
          'meituan.com',
          'netease.com',
          'pinduoduo.com',
          'qq.com',
          'qpic.cn',
          'sina.com.cn',
          'smzdm.com',
          'taobao.com',
          'tmall.com',
          'tencent.com',
          'weibo.com',
          'xiaohongshu.com',
          'xunlei.com',
          'youku.com',
          'zhihu.com',
        ],
      },
      {
        ip_cidr: [
          '114.114.114.114/32',
          '119.29.29.29/32',
          '180.76.76.76/32',
          '223.5.5.5/32',
        ],
      },
    ),
  },
  {
    id: BuiltinRulesetIds.AI,
    key: 'AI',
    path: 'data/rulesets/ai-services.json',
    payload: createRulesetPayload({
      domain_suffix: [
        'anthropic.com',
        'chatgpt.com',
        'claude.ai',
        'cursor.sh',
        'grok.com',
        'notionusercontent.com',
        'oaistatic.com',
        'openai.com',
        'perplexity.ai',
        'poe.com',
        'windsurf.com',
        'x.ai',
      ],
    }),
  },
  {
    id: BuiltinRulesetIds.Developer,
    key: 'Developer',
    path: 'data/rulesets/developer-platforms.json',
    payload: createRulesetPayload({
      domain_suffix: [
        'archlinux.org',
        'crates.io',
        'docker.com',
        'docker.io',
        'github.com',
        'githubassets.com',
        'githubusercontent.com',
        'go.dev',
        'golang.org',
        'nodejs.org',
        'npmjs.com',
        'nuget.org',
        'pkg.go.dev',
        'pypi.org',
        'pythonhosted.org',
        'quay.io',
        'registry.npmjs.org',
        'rubygems.org',
        'rust-lang.org',
      ],
    }),
  },
  {
    id: BuiltinRulesetIds.Global,
    key: 'Global',
    path: 'data/rulesets/global-services.json',
    payload: createRulesetPayload({
      domain_suffix: [
        '1e100.net',
        'cloudflare.com',
        'discord.com',
        'discord.gg',
        'facebook.com',
        'fastly.net',
        'fbcdn.net',
        'google.com',
        'googleapis.com',
        'gstatic.com',
        'instagram.com',
        'netflix.com',
        'nflxvideo.net',
        'reddit.com',
        'redd.it',
        'spotify.com',
        'telegram.org',
        't.me',
        'whatsapp.com',
        'wikipedia.org',
        'workers.dev',
        'x.com',
        'youtube.com',
        'ytimg.com',
      ],
    }),
  },
  {
    id: BuiltinRulesetIds.Ads,
    key: 'Ads',
    path: 'data/rulesets/ads-trackers.json',
    payload: createRulesetPayload(
      {
        domain_suffix: [
          'adnxs.com',
          'ads-twitter.com',
          'amazon-adsystem.com',
          'appsflyer.com',
          'branch.io',
          'criteo.com',
          'doubleclick.net',
          'googlesyndication.com',
          'googletagmanager.com',
          'googletagservices.com',
          'googleadservices.com',
          'openx.net',
          'outbrain.com',
          'scorecardresearch.com',
          'taboola.com',
        ],
      },
      {
        domain_keyword: ['adservice', 'analytics', 'tracking', 'tracker'],
      },
    ),
  },
] as const satisfies BuiltinRulesetSeed[]

const builtinRulesetTag = (key: keyof typeof BuiltinRulesetIds) => {
  const { t } = i18n.global
  return t(`presets.rulesets.${key}`)
}

const createBuiltinRulesetMeta = (seed: BuiltinRulesetSeed): RuleSet => ({
  id: seed.id,
  tag: builtinRulesetTag(seed.key),
  updateTime: 0,
  disabled: false,
  type: 'Manual',
  format: RulesetFormat.Source,
  path: seed.path,
  url: '',
  count: countRules(seed.payload),
})

const createLocalRulesetRef = (
  profileId: string,
  rulesetId: string,
  key: keyof typeof BuiltinRulesetIds,
): IRuleSet => ({
  id: `${profileId}-${rulesetId}`,
  type: RulesetType.Local,
  tag: builtinRulesetTag(key),
  format: RulesetFormat.Source,
  url: '',
  download_detour: '',
  update_interval: '',
  rules: '',
  path: rulesetId,
})

const createRouteRule = (
  type: IRule['type'],
  payload: string,
  action: IRule['action'],
  outbound = '',
): IRule => ({
  id: `${type}-${payload}-${action}-${outbound || 'none'}`,
  type,
  payload,
  invert: false,
  action,
  outbound,
  sniffer: [],
  strategy: Strategy.Default,
  server: '',
})

const createDnsRule = (
  type: IDNSRule['type'],
  payload: string,
  action: IDNSRule['action'],
  server: string,
): IDNSRule => ({
  id: `dns-${type}-${payload}-${action}-${server}`,
  type,
  payload,
  action,
  invert: false,
  server,
  strategy: Strategy.Default,
  disable_cache: false,
  client_subnet: '',
})

export const buildBuiltinProfiles = () => {
  const { t } = i18n.global
  const createProfile = (
    id: string,
    name: string,
    mode: ClashMode,
    finalOutbound: string,
    finalDns: string,
  ): IProfile => {
    const experimental = DefaultExperimental()
    const dns = DefaultDns()
    const routeRuleSets = [
      createLocalRulesetRef(id, BuiltinRulesetIds.PrivateLan, 'PrivateLan'),
      createLocalRulesetRef(id, BuiltinRulesetIds.SystemConnectivity, 'SystemConnectivity'),
      createLocalRulesetRef(id, BuiltinRulesetIds.Mainland, 'Mainland'),
      createLocalRulesetRef(id, BuiltinRulesetIds.AI, 'AI'),
      createLocalRulesetRef(id, BuiltinRulesetIds.Developer, 'Developer'),
      createLocalRulesetRef(id, BuiltinRulesetIds.Global, 'Global'),
      createLocalRulesetRef(id, BuiltinRulesetIds.Ads, 'Ads'),
    ]
    const getRefId = (rulesetId: string) => routeRuleSets.find((item) => item.path === rulesetId)!.id

    dns.rules = [
      createDnsRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.Ads), RuleAction.Reject, RuleActionReject.Default),
      createDnsRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.PrivateLan), RuleAction.Route, DefaultDnsServersIds.LocalDns),
      createDnsRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.SystemConnectivity), RuleAction.Route, DefaultDnsServersIds.LocalDns),
      createDnsRule(RuleType.ClashMode, ClashMode.Direct, RuleAction.Route, DefaultDnsServersIds.LocalDns),
      createDnsRule(RuleType.ClashMode, ClashMode.Global, RuleAction.Route, DefaultDnsServersIds.RemoteDns),
      createDnsRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.Mainland), RuleAction.Route, DefaultDnsServersIds.LocalDns),
      createDnsRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.AI), RuleAction.Route, DefaultDnsServersIds.RemoteDns),
      createDnsRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.Developer), RuleAction.Route, DefaultDnsServersIds.RemoteDns),
      createDnsRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.Global), RuleAction.Route, DefaultDnsServersIds.RemoteDns),
    ]
    dns.final = finalDns

    return {
      id,
      name,
      log: DefaultLog(),
      experimental: {
        ...experimental,
        clash_api: {
          ...experimental.clash_api,
          default_mode: mode,
        },
      },
      inbounds: DefaultInbounds(),
      outbounds: DefaultOutbounds(),
      route: {
        rules: [
          createRouteRule(RuleType.Inbound, DefaultInboundIds.Tun, RuleAction.Sniff),
          createRouteRule(RuleType.Network, 'icmp', RuleAction.Route, DefaultOutboundIds.Direct),
          createRouteRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.PrivateLan), RuleAction.Route, DefaultOutboundIds.Direct),
          createRouteRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.SystemConnectivity), RuleAction.Route, DefaultOutboundIds.Direct),
          createRouteRule(RuleType.ClashMode, ClashMode.Direct, RuleAction.Route, DefaultOutboundIds.Direct),
          createRouteRule(RuleType.ClashMode, ClashMode.Global, RuleAction.Route, DefaultOutboundIds.Global),
          createRouteRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.Mainland), RuleAction.Route, DefaultOutboundIds.Direct),
          createRouteRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.AI), RuleAction.Route, DefaultOutboundIds.Select),
          createRouteRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.Developer), RuleAction.Route, DefaultOutboundIds.Select),
          createRouteRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.Global), RuleAction.Route, DefaultOutboundIds.Select),
        ],
        rule_set: routeRuleSets,
        auto_detect_interface: true,
        default_interface: '',
        final: finalOutbound,
        find_process: false,
        default_domain_resolver: {
          server: DefaultDnsServersIds.LocalDns,
          client_subnet: '',
        },
      },
      dns,
      mixin: DefaultMixin(),
      script: DefaultScript(),
    }
  }

  return [
    createProfile(
      BuiltinProfileIds.Smart,
      t('presets.profiles.smart'),
      ClashMode.Rule,
      DefaultOutboundIds.Fallback,
      DefaultDnsServersIds.RemoteDns,
    ),
    createProfile(
      BuiltinProfileIds.Global,
      t('presets.profiles.global'),
      ClashMode.Global,
      DefaultOutboundIds.Global,
      DefaultDnsServersIds.RemoteDns,
    ),
    createProfile(
      BuiltinProfileIds.Direct,
      t('presets.profiles.direct'),
      ClashMode.Direct,
      DefaultOutboundIds.Direct,
      DefaultDnsServersIds.LocalDns,
    ),
  ]
}

export const ensureBuiltinPresets = async () => {
  const appSettingsStore = useAppSettingsStore()
  const profilesStore = useProfilesStore()
  const rulesetsStore = useRulesetsStore()

  if (appSettingsStore.app.builtinPresetsVersion >= BuiltinPresetsVersion) {
    const activeProfile = appSettingsStore.app.kernel.profile
    if (!activeProfile || !profilesStore.getProfileById(activeProfile)) {
      appSettingsStore.app.kernel.profile =
        profilesStore.getProfileById(BuiltinProfileIds.Smart)?.id || profilesStore.profiles[0]?.id || ''
    }
    return
  }

  let rulesetChanged = false
  for (const seed of buildBuiltinRulesetSeeds()) {
    const existing = rulesetsStore.getRulesetById(seed.id)
    if (!existing) {
      rulesetsStore.rulesets.push(createBuiltinRulesetMeta(seed))
      rulesetChanged = true
    }
    if (!(await FileExists(seed.path))) {
      await WriteFile(seed.path, JSON.stringify(seed.payload, null, 2))
      const current = rulesetsStore.getRulesetById(seed.id)
      if (current) {
        current.count = countRules(seed.payload)
      }
      rulesetChanged = true
    }
  }

  if (rulesetChanged) {
    await rulesetsStore.saveRulesets()
  }

  let profileChanged = false
  for (const profile of buildBuiltinProfiles()) {
    if (!profilesStore.getProfileById(profile.id)) {
      profilesStore.profiles.push(profile)
      profileChanged = true
    }
  }

  if (profileChanged) {
    await profilesStore.saveProfiles()
  }

  if (!appSettingsStore.app.kernel.profile || !profilesStore.getProfileById(appSettingsStore.app.kernel.profile)) {
    appSettingsStore.app.kernel.profile = BuiltinProfileIds.Smart
  }

  appSettingsStore.app.builtinPresetsVersion = BuiltinPresetsVersion
}
