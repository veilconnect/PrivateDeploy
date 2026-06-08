import {
  LogLevel,
  Inbound,
  Outbound,
  TunStack,
  ClashMode,
  RulesetType,
  RulesetFormat,
  RuleType,
  RuleAction,
  Strategy,
  DnsServer,
} from '@/enums/kernel'
import i18n from '@/lang'
import { generateSecureKey, sampleID } from '@/utils/identity'

import { DefaultTestURL } from './app'

const translate = (key: string) => i18n.global.t(key)

export const DefaultOutboundIds = {
  Select: 'outbound-select',
  Urltest: 'outbound-urlte',
  Direct: 'outbound-direct',
  Fallback: 'outbound-fallback',
  Global: 'outbound-global',
}

export const DefaultInboundIds = {
  MixedIn: 'mixed-in',
  Tun: 'tun-in',
}

export const DefaultDnsServersIds = {
  LocalDns: 'Local-DNS',
  RemoteDns: 'Remote-DNS',
  FakeIP: 'Fake-IP',
  LocalDnsResolver: 'Local-DNS-Resolver',
  RemoteDnsResolver: 'Remote-DNS-Resolver',
}

export const DefaultLog = (): ILog => ({
  disabled: false,
  level: LogLevel.Info,
  output: '',
  timestamp: false,
})

export const DefaultExperimental = (): IExperimental => ({
  clash_api: {
    external_controller: '127.0.0.1:20123',
    external_ui: '',
    external_ui_download_url: '',
    external_ui_download_detour: DefaultOutboundIds.Direct,
    secret: generateSecureKey(),
    default_mode: ClashMode.Rule,
    // access_control_allow_origin: ['*'],  // Removed: not supported in sing-box 1.12+
    // access_control_allow_private_network: false,  // Removed: not supported in sing-box 1.12+
  },
  cache_file: {
    enabled: true,
    path: 'cache.db',
    cache_id: '',
    store_fakeip: true,
    store_rdrc: true,
    rdrc_timeout: '7d',
  },
})

export const DefaultInboundSocks = (): IInbound['socks'] => ({
  listen: {
    listen: '127.0.0.1',
    listen_port: 20120,
    tcp_fast_open: false,
    tcp_multi_path: false,
    udp_fragment: false,
  },
  users: [],
})

export const DefaultInboundHttp = (): IInbound['http'] => ({
  listen: {
    listen: '127.0.0.1',
    listen_port: 20121,
    tcp_fast_open: false,
    tcp_multi_path: false,
    udp_fragment: false,
  },
  users: [],
})

export const DefaultInboundMixed = (): IInbound['mixed'] => ({
  listen: {
    listen: '127.0.0.1',
    listen_port: 20122,
    tcp_fast_open: false,
    tcp_multi_path: false,
    udp_fragment: false,
  },
  users: [],
})

export const DefaultInboundTun = (): IInbound['tun'] => ({
  interface_name: '',
  address: ['172.18.0.1/30', 'fdfe:dcba:9876::1/126'],
  mtu: 9000,
  auto_route: true,
  strict_route: true,
  route_address: [],
  route_exclude_address: [],
  endpoint_independent_nat: false,
  stack: TunStack.Mixed,
})

export const DefaultInbounds = (): IInbound[] => [
  {
    id: DefaultInboundIds.MixedIn,
    type: Inbound.Mixed,
    tag: 'mixed-in',
    enable: true,
    mixed: DefaultInboundMixed(),
  },
  {
    id: DefaultInboundIds.Tun,
    type: Inbound.Tun,
    tag: 'tun-in',
    enable: false,
    tun: DefaultInboundTun(),
  },
]

export const DefaultOutbound = (): IOutbound => ({
  id: sampleID(),
  tag: '',
  type: Outbound.Selector,
  outbounds: [],
  interrupt_exist_connections: true,
  url: DefaultTestURL,
  interval: '3m',
  tolerance: 150,
  include: '',
  exclude: '',
  // wireguard (sing-box 1.12 endpoint)
  server: '',
  server_port: '',
  local_address: [],
  private_key: '',
  peer_public_key: '',
  pre_shared_key: '',
  mtu: '',
  persistent_keepalive_interval: '',
})

export const DefaultOutbounds = (): IOutbound[] => [
  {
    ...DefaultOutbound(),
    id: DefaultOutboundIds.Select,
    tag: translate('outbound.select'),
    type: Outbound.Selector,
    outbounds: [{ id: DefaultOutboundIds.Urltest, type: 'Built-in', tag: translate('outbound.urltest') }],
    url: '',
  },
  {
    ...DefaultOutbound(),
    id: DefaultOutboundIds.Urltest,
    tag: translate('outbound.urltest'),
    type: Outbound.Urltest,
    outbounds: [],
    url: DefaultTestURL,
  },
  {
    ...DefaultOutbound(),
    id: DefaultOutboundIds.Direct,
    tag: translate('outbound.direct'),
    type: Outbound.Direct,
    outbounds: [],
    url: '',
  },
  {
    ...DefaultOutbound(),
    id: DefaultOutboundIds.Fallback,
    tag: translate('outbound.fallback'),
    type: Outbound.Selector,
    outbounds: [
      { id: DefaultOutboundIds.Select, type: 'Built-in', tag: translate('outbound.select') },
      { id: DefaultOutboundIds.Direct, type: 'Built-in', tag: translate('outbound.direct') },
    ],
    url: '',
  },
  {
    ...DefaultOutbound(),
    id: DefaultOutboundIds.Global,
    tag: 'GLOBAL',
    type: Outbound.Selector,
    outbounds: [
      { id: DefaultOutboundIds.Select, type: 'Built-in', tag: translate('outbound.select') },
      { id: DefaultOutboundIds.Urltest, type: 'Built-in', tag: translate('outbound.urltest') },
      { id: DefaultOutboundIds.Direct, type: 'Built-in', tag: translate('outbound.direct') },
      { id: DefaultOutboundIds.Fallback, type: 'Built-in', tag: translate('outbound.fallback') },
    ],
    url: '',
  },
]

export const DefaultRouteRule = (): IRule => ({
  id: sampleID(),
  type: RuleType.RuleSet,
  payload: '',
  invert: false,
  action: RuleAction.Route,
  outbound: '',
  sniffer: [],
  strategy: Strategy.Default,
  server: '',
})

export const DefaultRouteRuleset = (): IRuleSet => ({
  id: sampleID(),
  type: RulesetType.Local,
  tag: '',
  format: RulesetFormat.Binary,
  url: '',
  download_detour: '',
  update_interval: '',
  rules: '',
  path: '',
})

export const DefaultRoute = (): IRoute => ({
  rules: [
    {
      id: sampleID(),
      type: RuleType.Inbound,
      payload: DefaultInboundIds.Tun,
      invert: false,
      action: RuleAction.Sniff,
      outbound: '',
      sniffer: [],
      strategy: Strategy.Default,
      server: '',
    },
    {
      id: sampleID(),
      type: RuleType.Protocol,
      payload: 'dns',
      invert: false,
      action: RuleAction.HijackDNS,
      outbound: '',
      sniffer: [],
      strategy: Strategy.Default,
      server: '',
    },
    {
      id: sampleID(),
      type: RuleType.ClashMode,
      payload: ClashMode.Direct,
      invert: false,
      action: RuleAction.Route,
      outbound: DefaultOutboundIds.Direct,
      sniffer: [],
      strategy: Strategy.Default,
      server: '',
    },
    {
      id: sampleID(),
      type: RuleType.ClashMode,
      payload: ClashMode.Global,
      invert: false,
      action: RuleAction.Route,
      outbound: DefaultOutboundIds.Global,
      sniffer: [],
      strategy: Strategy.Default,
      server: '',
    },
    {
      id: sampleID(),
      type: RuleType.Network,
      payload: 'icmp',
      invert: false,
      action: RuleAction.Route,
      outbound: DefaultOutboundIds.Direct,
      sniffer: [],
      strategy: Strategy.Default,
      server: '',
    },
    {
      id: sampleID(),
      type: RuleType.Protocol,
      payload: 'quic',
      invert: false,
      action: RuleAction.Reject,
      outbound: '',
      sniffer: [],
      strategy: Strategy.Default,
      server: '',
    },
  ],
  rule_set: [],
  auto_detect_interface: false,
  default_interface: '',
  final: DefaultOutboundIds.Fallback,
  find_process: false,
  default_domain_resolver: {
    server: DefaultDnsServersIds.LocalDns,
    client_subnet: '',
  },
})

export const DefaultDnsServer = (): IDNSServer => ({
  id: sampleID(),
  tag: '',
  type: DnsServer.Local,
  detour: '',
  domain_resolver: '',
  server: '',
  server_port: '',
  path: '',
  interface: '',
  inet4_range: '',
  inet6_range: '',
  hosts_path: [],
  predefined: {},
})

export const DefaultDnsServers = (): IDNSServer[] => [
  {
    id: DefaultDnsServersIds.LocalDns,
    tag: DefaultDnsServersIds.LocalDns,
    detour: '',
    type: DnsServer.Https,
    domain_resolver: DefaultDnsServersIds.LocalDnsResolver,
    server: '223.5.5.5',
    server_port: '443',
    path: '/dns-query',
    interface: '',
    inet4_range: '',
    inet6_range: '',
    hosts_path: [],
    predefined: {},
  },
  {
    id: DefaultDnsServersIds.LocalDnsResolver,
    tag: DefaultDnsServersIds.LocalDnsResolver,
    detour: '',
    type: DnsServer.Udp,
    domain_resolver: '',
    server: '223.5.5.5',
    server_port: '53',
    path: '',
    interface: '',
    inet4_range: '',
    inet6_range: '',
    hosts_path: [],
    predefined: {},
  },
  {
    id: DefaultDnsServersIds.RemoteDns,
    tag: DefaultDnsServersIds.RemoteDns,
    detour: DefaultOutboundIds.Select,
    type: DnsServer.Tls,
    domain_resolver: DefaultDnsServersIds.RemoteDnsResolver,
    server: '8.8.8.8',
    server_port: '853',
    path: '',
    interface: '',
    inet4_range: '',
    inet6_range: '',
    hosts_path: [],
    predefined: {},
  },
  {
    id: DefaultDnsServersIds.RemoteDnsResolver,
    tag: DefaultDnsServersIds.RemoteDnsResolver,
    detour: DefaultOutboundIds.Select,
    type: DnsServer.Udp,
    domain_resolver: '',
    server: '8.8.8.8',
    server_port: '53',
    path: '',
    interface: '',
    inet4_range: '',
    inet6_range: '',
    hosts_path: [],
    predefined: {},
  },
]

export const DefaultFakeIPDnsRule = () => ({
  __is_fake_ip: true,
  type: 'logical',
  mode: 'and',
  rules: [
    {
      domain_suffix: [
        '.lan',
        '.localdomain',
        '.example',
        '.invalid',
        '.localhost',
        '.test',
        '.local',
        '.home.arpa',
        '.msftconnecttest.com',
        '.msftncsi.com',
      ],
      invert: true,
    },
    {
      query_type: ['A', 'AAAA'],
    },
  ],
})

export const DefaultDnsRule = (): IDNSRule => ({
  id: sampleID(),
  type: RuleType.RuleSet,
  payload: '',
  action: RuleAction.Route,
  invert: false,
  // route
  server: '',
  strategy: Strategy.Default,
  // route/route-options
  disable_cache: false,
  client_subnet: '',
})

export const DefaultDnsRules = (): IDNSRule[] => [
  {
    id: sampleID(),
    type: RuleType.ClashMode,
    payload: ClashMode.Direct,
    action: RuleAction.Route,
    server: DefaultDnsServersIds.LocalDns,
    invert: false,
    strategy: Strategy.Default,
    disable_cache: false,
    client_subnet: '',
  },
  {
    id: sampleID(),
    type: RuleType.ClashMode,
    payload: ClashMode.Global,
    action: RuleAction.Route,
    server: DefaultDnsServersIds.RemoteDns,
    invert: false,
    strategy: Strategy.Default,
    disable_cache: false,
    client_subnet: '',
  },
]

export const DefaultDns = (): IDNS => ({
  servers: DefaultDnsServers(),
  rules: DefaultDnsRules(),
  disable_cache: false,
  disable_expire: false,
  independent_cache: false,
  client_subnet: '',
  final: DefaultDnsServersIds.RemoteDns,
  strategy: Strategy.Default,
})

export const DefaultMixin = (): IProfile['mixin'] => {
  return { priority: 'mixin', config: '{}' }
}

export const DefaultScript = (): IProfile['script'] => {
  return { code: `const onGenerate = async (config) => {\n  return config\n}` }
}
