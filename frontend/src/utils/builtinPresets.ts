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

export const BuiltinPresetsVersion = 2

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
          // Top-level
          'cn',
          // Carriers & Government
          '10010.com',
          '10086.cn',
          '189.cn',
          '12306.cn',
          'gov.cn',
          // Alibaba ecosystem
          'alibaba.com',
          'alibabacloud.com',
          'alicdn.com',
          'alidns.com',
          'alipay.com',
          'alipayobjects.com',
          'alikunlun.com',
          'aliyun.com',
          'aliyuncs.com',
          'amap.com',
          'cainiao.com',
          'dingtalk.com',
          'ele.me',
          'etao.com',
          'taobao.com',
          'tbcdn.cn',
          'tmall.com',
          'uc.cn',
          'ucweb.com',
          // Tencent ecosystem
          'gtimg.com',
          'idqqimg.com',
          'myqcloud.com',
          'qq.com',
          'qcloud.com',
          'qpic.cn',
          'qlogo.cn',
          'tencent.com',
          'tenpay.com',
          'wechat.com',
          'weixin.qq.com',
          'wxpay.wxutil.com',
          // JD ecosystem
          '3.cn',
          '360buy.com',
          '360buyimg.com',
          'jd.com',
          'jd.hk',
          'jdcloud.com',
          'jdpay.com',
          'jcloudec.com',
          // ByteDance / Douyin ecosystem
          'amemv.com',
          'bytedance.com',
          'byteimg.com',
          'bytegoofy.com',
          'bytednsdoc.com',
          'douyin.com',
          'douyinpic.com',
          'douyinstatic.com',
          'douyinvod.com',
          'feelgood.cn',
          'feiliao.com',
          'gifshow.com',
          'huoshan.com',
          'iesdouyin.com',
          'ixigua.com',
          'pstatp.com',
          'snssdk.com',
          'toutiao.com',
          'toutiaoimg.com',
          'volccdn.com',
          'volces.com',
          // Baidu ecosystem
          'baidu.com',
          'baidubce.com',
          'baiducontent.com',
          'baidustatic.com',
          'baike.com',
          'bcebos.com',
          'bdimg.com',
          'bdstatic.com',
          'bdydns.com',
          'hao123.com',
          'nuomi.com',
          'tieba.com',
          // NetEase
          '126.net',
          '127.net',
          '163.com',
          'netease.com',
          'yeah.net',
          'youdao.com',
          // Sina / Weibo
          'sina.com.cn',
          'sinaimg.cn',
          'sinajs.cn',
          'weibo.com',
          'weibocdn.com',
          // Bilibili
          'acgvideo.com',
          'b23.tv',
          'bilivideo.com',
          'bilibili.com',
          'biliapi.com',
          'biliapi.net',
          'hdslb.com',
          // Video / Entertainment
          'douyu.com',
          'iqiyi.com',
          'iqiyipic.com',
          'mgtv.com',
          'pplive.com',
          'sohu.com',
          'youku.com',
          'ykimg.com',
          // E-commerce & Services
          '58.com',
          'ctrip.com',
          'dianping.com',
          'jmstatic.com',
          'jumei.com',
          'kaola.com',
          'meituan.com',
          'meituan.net',
          'mogujie.com',
          'pinduoduo.com',
          'smzdm.com',
          'suning.com',
          'vip.com',
          'vipshop.com',
          'xiaohongshu.com',
          'xhscdn.com',
          'yangkeduo.com',
          // Tech companies
          '360.cn',
          'csdn.net',
          'huawei.com',
          'honor.cn',
          'lenovo.com',
          'meizu.com',
          'mi.com',
          'miui.com',
          'oppo.com',
          'realme.com',
          'vivo.com',
          'xiaomi.com',
          'zhihu.com',
          'zhimg.com',
          // Gaming
          'mihoyo.com',
          'miyoushe.com',
          'hoyoverse.com',
          // CDN / Cloud / Infrastructure
          'alikunlun.net',
          'bscstorage.net',
          'cdn20.com',
          'chinanetcenter.com',
          'dwstatic.com',
          'fastcdn.com',
          'kgimg.com',
          'ksyun.com',
          'kunlunaq.com',
          'kunlunca.com',
          'kunluncan.com',
          'kunlunpi.com',
          'kunlunsl.com',
          'myalicdn.com',
          'qiniucdn.com',
          'qiniudn.com',
          'qiniup.com',
          'staticdn.net',
          'tcdnos.com',
          'ucloud.cn',
          'upyun.com',
          'wangsu.com',
          'wscdns.com',
          'wscloudcdn.com',
          // Download / Tools
          'xunlei.com',
          // Finance
          'eastmoney.com',
          'hexun.com',
          'lufax.com',
          'pingan.com',
          'snowballsecurities.com',
          'xueqiu.com',
        ],
      },
      {
        ip_cidr: [
          // China mainland public DNS servers
          '1.12.12.12/32',
          '114.114.114.114/32',
          '114.114.115.115/32',
          '119.29.29.29/32',
          '120.53.53.53/32',
          '180.76.76.76/32',
          '223.5.5.5/32',
          '223.6.6.6/32',
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
      // Proxy rulesets first — resolve via remote DNS to avoid poisoning
      createDnsRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.AI), RuleAction.Route, DefaultDnsServersIds.RemoteDns),
      createDnsRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.Developer), RuleAction.Route, DefaultDnsServersIds.RemoteDns),
      createDnsRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.Global), RuleAction.Route, DefaultDnsServersIds.RemoteDns),
      // Mainland last — resolve via local DNS for best performance
      createDnsRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.Mainland), RuleAction.Route, DefaultDnsServersIds.LocalDns),
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
          // Proxy rulesets first — blocked sites must match before mainland fallback
          createRouteRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.AI), RuleAction.Route, DefaultOutboundIds.Select),
          createRouteRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.Developer), RuleAction.Route, DefaultOutboundIds.Select),
          createRouteRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.Global), RuleAction.Route, DefaultOutboundIds.Select),
          // Mainland direct — everything else falls through to final (direct)
          createRouteRule(RuleType.RuleSet, getRefId(BuiltinRulesetIds.Mainland), RuleAction.Route, DefaultOutboundIds.Direct),
        ],
        rule_set: routeRuleSets,
        auto_detect_interface: false,
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
      DefaultOutboundIds.Direct,
      DefaultDnsServersIds.LocalDns,
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

  const previousVersion = appSettingsStore.app.builtinPresetsVersion
  const isUpgrade = previousVersion > 0 && previousVersion < BuiltinPresetsVersion

  if (previousVersion >= BuiltinPresetsVersion) {
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
    // On upgrade or missing file, always overwrite ruleset content
    if (isUpgrade || !(await FileExists(seed.path))) {
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
    const existing = profilesStore.getProfileById(profile.id)
    if (existing) {
      // On upgrade, replace builtin profiles with updated versions
      if (isUpgrade) {
        Object.assign(existing, profile)
        profileChanged = true
      }
    } else {
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
