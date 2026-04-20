// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'PrivateDeploy';

  @override
  String get workspace => '工作区';

  @override
  String get settings => '设置';

  @override
  String get refresh => '刷新';

  @override
  String get cancel => '取消';

  @override
  String get save => '保存';

  @override
  String get delete => '删除';

  @override
  String get close => '关闭';

  @override
  String get create => '创建';

  @override
  String get import_ => '导入';

  @override
  String get retry => '重试';

  @override
  String get copy => '复制';

  @override
  String get ok => '确定';

  @override
  String get back => '返回';

  @override
  String get cloudApiKey => '云端 API Key';

  @override
  String get apiKey => 'API Key';

  @override
  String get verifyAndSave => '验证并保存';

  @override
  String get verifying => '验证中...';

  @override
  String get failedToSaveApiKey => '保存 API Key 失败';

  @override
  String get apiKeySavedAndVerified => 'API Key 已保存并验证通过';

  @override
  String get notSet => '未设置';

  @override
  String pasteCloudProviderApiKey(Object provider) {
    return '粘贴您的 $provider API Key';
  }

  @override
  String deployToCloudProvider(Object provider) {
    return '部署到 $provider';
  }

  @override
  String get loadingNodes => '加载节点中...';

  @override
  String get vpnNotice => 'VPN 通知';

  @override
  String get nextStep => '下一步';

  @override
  String get connection => '连接状态';

  @override
  String get connected => '已连接';

  @override
  String get connecting => '连接中...';

  @override
  String get disconnecting => '断开中...';

  @override
  String get disconnected => '未连接';

  @override
  String get tapConnectHint => '点击连接，自动选择最快节点。';

  @override
  String get waitingForCredentials => '等待节点凭据…';

  @override
  String get noNodeSelected => '未选择节点。';

  @override
  String get connect => '连接';

  @override
  String get disconnect => '断开';

  @override
  String get restartVpn => '重启 VPN';

  @override
  String get processingVpn => 'VPN 处理中...';

  @override
  String get nativeVpnUnavailable => '原生 VPN 不可用';

  @override
  String get nativeVpnUnavailableMessage => '此版本未包含可用的原生 VPN 运行时。';

  @override
  String upStats(Object value) {
    return '上传 $value';
  }

  @override
  String downStats(Object value) {
    return '下载 $value';
  }

  @override
  String speedStats(Object value) {
    return '速度 $value';
  }

  @override
  String get cloudNodes => '云节点';

  @override
  String get availableRoutes => '可用线路';

  @override
  String get cloudAccessNotConfigured => '云端访问未配置';

  @override
  String setCloudProviderApiKeyHint(Object provider) {
    return '设置 $provider API Key 以开始使用。';
  }

  @override
  String get setApiKey => '设置 API Key';

  @override
  String get benchmarkAll => '全部测速';

  @override
  String get failedToLoad => '加载失败';

  @override
  String get noCloudNodesYet => '暂无云节点';

  @override
  String get deployFirstNodeHint => '先创建一个云节点，再从这台设备发起连接。';

  @override
  String get deployNode => '部署节点';

  @override
  String get manualProfilesDesc => '仅保存在这台设备上的配置';

  @override
  String get activeNode => '当前线路';

  @override
  String get useAndConnect => '使用并连接';

  @override
  String get useAndSwitch => '使用并切换';

  @override
  String get speedTest => '速度测试';

  @override
  String get retrySpeedTest => '重新测速';

  @override
  String get testing => '测试中...';

  @override
  String get active => '已就绪';

  @override
  String get provisioning => '准备中';

  @override
  String get inUse => '正在使用';

  @override
  String get saved => '已保存';

  @override
  String get nodeDetails => '节点详情';

  @override
  String get deleteNode => '删除节点';

  @override
  String probesStat(Object successful, Object total) {
    return '$successful/$total 次探测';
  }

  @override
  String msLatency(Object ms) {
    return '$ms ms 延迟';
  }

  @override
  String get deleteNodeTitle => '删除节点';

  @override
  String deleteNodeConfirm(Object label) {
    return '确定删除「$label」？\n\n此操作将永久销毁服务器。';
  }

  @override
  String get nodeDeleted => '节点已删除';

  @override
  String get nodeDeletedCleanupNeeded => '节点已删除，但本地清理需要关注';

  @override
  String get failedToDelete => '删除失败';

  @override
  String get nodeNotReady => '节点尚未就绪';

  @override
  String get failedToActivateNode => '激活节点失败';

  @override
  String get nodeReadyConnected => '节点已就绪并连接';

  @override
  String get failedToActivate => '激活失败';

  @override
  String get profileActivatedConnected => '配置已激活并连接';

  @override
  String get vpnConnectedSuccess => 'VPN 连接成功';

  @override
  String get vpnDisconnectedSuccess => 'VPN 已断开';

  @override
  String get failedToDisconnectVpn => '断开 VPN 失败';

  @override
  String get vpnRestartedSuccess => 'VPN 重启成功';

  @override
  String get vpnBusyWait => 'VPN 正忙，请稍候';

  @override
  String tryingBackupNode(Object index, Object total, Object label) {
    return '正在尝试备用节点 $index/$total: $label';
  }

  @override
  String get allNodesFailedCheckNetwork =>
      '所有就绪节点都连接失败。请检查网络（可切到 Wi-Fi）或刷新节点列表。';

  @override
  String get noCredentialsHint => '这些云节点可见，但此设备尚无其连接凭据。请恢复云备份或从此设备部署/使用节点。';

  @override
  String get noNodeSelectedHint => '尚未选择就绪节点。请在下方选择云节点或创建/导入配置。';

  @override
  String usingFastestNode(Object label, Object metric, Object endpoint) {
    return '使用最近最快节点：$label$metric$endpoint。后台刷新排名中...';
  }

  @override
  String get quickTestingNodes => '正在快速测试就绪节点，选择最快的...';

  @override
  String get noReadyCloudNode => '目前没有就绪的云节点';

  @override
  String get workspaceGuideSetupTitle => '先接入云服务';

  @override
  String workspaceGuideSetupMessage(Object provider) {
    return '保存 $provider API Key 后，这台设备就能拉取节点、部署新节点，并在稍后重新连接。';
  }

  @override
  String get workspaceGuideDeployTitle => '先建立第一条线路';

  @override
  String get workspaceGuideDeployMessage => '先部署一个云节点；如果你已经有现成配置，也可以直接导入使用。';

  @override
  String get workspaceGuideChooseTitle => '已经可以连接';

  @override
  String get workspaceGuideChooseMessage =>
      '直接点“连接”会自动选择最快节点；如果你想手动挑选，也可以先在下方选节点。';

  @override
  String get workspaceGuideSyncTitle => '等待节点同步完成';

  @override
  String get workspaceGuideSyncMessage =>
      '节点已经显示出来，但这台设备还在等待连接信息。可以先刷新，或者等节点就绪后从这台设备激活。';

  @override
  String get workspaceStepAccess => '添加访问方式';

  @override
  String get workspaceStepRoute => '准备可用线路';

  @override
  String get workspaceStepConnect => '连接';

  @override
  String get workspaceStepDone => '已完成';

  @override
  String get workspaceStepCurrent => '当前';

  @override
  String get workspaceStepUpcoming => '后续';

  @override
  String get latencyTestUnavailable => '延迟测试不可用。';

  @override
  String usingNodeInstead(Object error, Object label) {
    return '$error 改用 $label。';
  }

  @override
  String get continue_ => '继续';

  @override
  String get chooseCloudNode => '选择云节点';

  @override
  String get chooseCloudNodeDesc => '连接需要一个活跃节点，请选择要使用的云节点。';

  @override
  String get nodeDeploying => '节点部署中...需要 3-5 分钟。';

  @override
  String get failedToCreate => '创建失败';

  @override
  String get nodeNotReadyForSpeedTest => '节点尚未就绪，无法测速';

  @override
  String get failedToConnectSpeedTestTunnel => '速度测试隧道连接失败';

  @override
  String get noReadyNodeForTesting => '没有可用于测试的就绪云节点';

  @override
  String get benchmarkAllNodesTitle => '全部节点测速';

  @override
  String get benchmarkAllNodesConfirm =>
      '此测速将临时断开当前 VPN 连接，用真实下载样本测试每个就绪的云节点，然后恢复之前的连接。\n\n继续？';

  @override
  String get startBenchmark => '开始测速';

  @override
  String get benchmarkingNodes => '正在用真实下载样本对就绪节点进行测速...';

  @override
  String benchmarkingNode(Object label, Object index, Object total) {
    return '正在测速 $label（$index/$total）...';
  }

  @override
  String get nodeNotReadyForBenchmark => '节点尚未就绪，无法测速';

  @override
  String get failedToConnectBenchmarkTunnel => '测速隧道连接失败';

  @override
  String bestBenchmark(Object label, Object metric, Object endpoint) {
    return '最佳测速：$label$metric$endpoint';
  }

  @override
  String get restoreConnectionFailed => '恢复之前的连接失败';

  @override
  String get deployNodeTitle => '部署节点';

  @override
  String get loadingRegionsPlans => '加载区域和计划中...';

  @override
  String get deploymentUnavailable => '部署选项暂时不可用。';

  @override
  String get retryLoading => '重新加载';

  @override
  String get nodeNameOptional => '节点名称（可选）';

  @override
  String get autoGenerateHint => '留空则自动生成';

  @override
  String get region => '区域';

  @override
  String get plan => '套餐';

  @override
  String get noPlansInRegion => '此区域没有可用的套餐。';

  @override
  String get deploy => '部署';

  @override
  String get loading => '加载中...';

  @override
  String get selectRegionAndPlan => '请选择区域和套餐';

  @override
  String get planNotAvailableInRegion => '所选套餐在该区域不可用';

  @override
  String get importFromUrl => '从 URL 导入';

  @override
  String get profileName => '配置名称';

  @override
  String get egMySubscription => '例如：我的订阅';

  @override
  String get urlOrProxyLinks => 'URL 或代理链接';

  @override
  String get urlOrProxyLinksHint => 'https://... 或 ss://... 或 vless://...';

  @override
  String get pasteFromClipboard => '从剪贴板粘贴';

  @override
  String get pleaseEnterUrlOrLinks => '请输入 URL 或代理链接';

  @override
  String get enterHttpUrlOrLinks => '请输入 http(s) URL 或代理链接（ss://、vless:// 等）';

  @override
  String get createProfile => '创建配置';

  @override
  String get egMyVpnConfig => '例如：我的 VPN 配置';

  @override
  String get config => '配置';

  @override
  String get pasteProxyLinksOrJson => '粘贴代理链接或 sing-box JSON...';

  @override
  String get pleaseEnterProfileName => '请输入配置名称';

  @override
  String get pleasePasteConfig => '请粘贴配置或代理链接';

  @override
  String get renameProfile => '重命名配置';

  @override
  String get manualProfiles => '本地配置';

  @override
  String createdAt(Object date) {
    return '创建于：$date';
  }

  @override
  String get viewEditConfig => '打开配置';

  @override
  String get rename => '重命名';

  @override
  String get deployCloudNode => '部署云节点';

  @override
  String get importProfile => '导入配置';

  @override
  String get createProfileTooltip => '创建配置';

  @override
  String get copyAllLinks => '复制全部链接';

  @override
  String get nodeInfo => '节点信息';

  @override
  String get ip => 'IP';

  @override
  String get ipv6 => 'IPv6';

  @override
  String get statusLabel => '状态';

  @override
  String get created => '创建时间';

  @override
  String get shadowsocks => 'Shadowsocks';

  @override
  String get hysteria2 => 'Hysteria2';

  @override
  String get vlessReality => 'VLESS-Reality';

  @override
  String get trojan => 'Trojan';

  @override
  String get port => '端口';

  @override
  String get password => '密码';

  @override
  String get method => '加密方式';

  @override
  String get sni => 'SNI';

  @override
  String get uuid => 'UUID';

  @override
  String get publicKey => '公钥';

  @override
  String get shortId => '短 ID';

  @override
  String labelCopied(Object label) {
    return '$label 已复制';
  }

  @override
  String linksCopied(Object count) {
    return '已复制 $count 个链接';
  }

  @override
  String get deleteProfile => '删除配置';

  @override
  String deleteProfileConfirm(Object name) {
    return '确定删除「$name」？';
  }

  @override
  String get profileDeleted => '配置已删除';

  @override
  String get failedToDeleteProfile => '删除失败';

  @override
  String get profileRenamed => '配置已重命名';

  @override
  String get failedToRename => '重命名失败';

  @override
  String get profileCreatedSuccess => '配置创建成功';

  @override
  String get failedToCreateProfile => '创建配置失败';

  @override
  String get unrecognizedConfigFormat => '无法识别的配置格式';

  @override
  String get importedSuccess => '导入成功';

  @override
  String get failedToImport => '导入失败';

  @override
  String get fetchingSubscription => '获取订阅中...';

  @override
  String get failedToParseSubscription => '解析订阅失败';

  @override
  String get failedToParseProxyLinks => '解析代理链接失败';

  @override
  String networkError(Object error) {
    return '网络错误：$error';
  }

  @override
  String get unrecognizedFormat =>
      '无法识别的格式。请粘贴代理链接（ss://、vless:// 等）或 sing-box JSON。';

  @override
  String get profileContentSaved => '配置内容已保存';

  @override
  String get saveFailed => '保存失败';

  @override
  String get pasteSingboxJsonHint => '在此粘贴 sing-box JSON 配置...';

  @override
  String get server => '服务器';

  @override
  String get standaloneCloudAccess => '独立云端访问';

  @override
  String get standaloneCloudAccessDesc => '此设备直接调用 Vultr API';

  @override
  String get cloudProvider => '云服务商';

  @override
  String cloudProviderDirect(Object name) {
    return '$name（直连）';
  }

  @override
  String get sensitiveData => '敏感数据';

  @override
  String get sensitiveDataDesc =>
      'API Key 保存在设备安全存储中。备份导出和恢复可能暴露密钥，分享备份后请轮换密钥。';

  @override
  String get copyCloudBackup => '复制云备份';

  @override
  String get copyCloudBackupDesc => '先查看摘要，然后复制包含 API Key 和本地节点记录的敏感备份 JSON';

  @override
  String get restoreCloudBackup => '恢复云备份';

  @override
  String get restoreCloudBackupDesc => '粘贴备份 JSON，验证后确认恢复 API Key 和本地节点';

  @override
  String get app => '应用';

  @override
  String get theme => '主题';

  @override
  String get usingSystemDarkTheme => '使用系统深色主题';

  @override
  String get usingSystemLightTheme => '使用系统浅色主题';

  @override
  String get vpnStatus => 'VPN 状态';

  @override
  String get unavailableOnBuild => '此版本不可用';

  @override
  String get routingMode => '路由模式';

  @override
  String get split => '分流';

  @override
  String get global => '全局';

  @override
  String get routingModeDesc => '局域网直连 · 国内域名直连 · 国内 IP 直连';

  @override
  String get vpnDiagnostics => 'VPN 诊断';

  @override
  String get vpnDiagnosticsDesc => '查看当前出口 IP 和最近的分流命中';

  @override
  String get routingRules => '路由规则';

  @override
  String get routingRulesDesc => '内置分流规则 + 自定义域名、CIDR 和应用';

  @override
  String get routingRulesSaved => '路由规则已保存';

  @override
  String get routingRulesReset => '路由规则已重置为默认';

  @override
  String get clearLocalCloudData => '清除本地云数据';

  @override
  String get clearLocalCloudDataDesc => '移除已保存的 API Key 和本地节点缓存';

  @override
  String get clearLocalCloudDataTitle => '清除本地云数据？';

  @override
  String get clearLocalCloudDataConfirm =>
      '此操作仅移除本设备上已保存的 Vultr API Key 和缓存的云节点记录，不会删除任何云实例。';

  @override
  String get clear => '清除';

  @override
  String get localCloudDataCleared => '本地云数据已清除';

  @override
  String get about => '关于';

  @override
  String get version => '版本';

  @override
  String get unavailable => '不可用';

  @override
  String get multiProtocolTool => '多协议代理部署工具';

  @override
  String get cloudBackupReady => '云备份已就绪';

  @override
  String get backupSensitiveWarning =>
      '敏感备份 JSON 显示如下。请安全保存，因为其中包含您的 Vultr API Key 和节点凭据。';

  @override
  String get backupClipboardWarning => '敏感备份已复制到剪贴板。剪贴板内容可能被其他应用访问，直到您替换为止。';

  @override
  String get backupReviewWarning =>
      '复制前请查看以下备份摘要。备份包含敏感数据，如 Vultr API Key 和节点凭据。';

  @override
  String get copySensitiveBackup => '复制敏感备份';

  @override
  String get copyAgain => '再次复制';

  @override
  String get revealJson => '显示 JSON';

  @override
  String get hideJson => '隐藏 JSON';

  @override
  String get copySensitiveBackupTitle => '复制敏感备份？';

  @override
  String get copySensitiveBackupConfirm =>
      '这将把完整的备份 JSON 放到系统剪贴板上，包括已保存的 API Key 和节点凭据。';

  @override
  String get sensitiveBackupCopied => '敏感备份已复制到剪贴板';

  @override
  String get revealSensitiveBackupTitle => '显示敏感备份？';

  @override
  String get revealSensitiveBackupConfirm =>
      '这将在屏幕上显示完整的备份 JSON，包括已保存的 API Key 和节点凭据。';

  @override
  String get reveal => '显示';

  @override
  String get restoreCloudBackupTitle => '恢复云备份';

  @override
  String get restoreCloudBackupDesc2 =>
      '粘贴从此应用导出的备份 JSON。恢复可能替换已保存的 API Key 并覆盖此设备上的本地云节点缓存。';

  @override
  String get pasteCloudBackupHint => '在此粘贴云备份 JSON';

  @override
  String get pasteClipboard => '粘贴剪贴板';

  @override
  String get restore => '恢复';

  @override
  String get restoreThisBackupTitle => '恢复此备份？';

  @override
  String get restoreThisBackupConfirm =>
      '这将覆盖此设备上的本地云节点缓存。如果备份包含 API Key，它将替换当前保存的密钥。';

  @override
  String get backupJsonEmpty => '备份 JSON 不能为空';

  @override
  String get backupJsonInvalid => '备份 JSON 尚无效';

  @override
  String get cloudBackupRestored => '云备份已恢复';

  @override
  String get vpnDiagnosticsTitle => 'VPN 诊断';

  @override
  String get session => '连接时长';

  @override
  String get vpnConnectedDiag => 'VPN 已连接 — 以下数据来自当前会话';

  @override
  String get vpnConnectingDiag => 'VPN 连接中 — 诊断数据可能即将变化';

  @override
  String get vpnDisconnectingDiag => 'VPN 断开中 — 结果可能已过时';

  @override
  String get vpnDisconnectedDiag => 'VPN 已断开 — 显示上次会话的路由命中';

  @override
  String lastUpdated(Object time) {
    return '最后更新：$time';
  }

  @override
  String get currentEgressIp => '当前出口 IP';

  @override
  String get connectVpnToMeasure => '连接 VPN 以测量当前出口 IP';

  @override
  String get refreshing => '刷新中...';

  @override
  String get probeUnavailable => '探测不可用';

  @override
  String get egressProbeHelp => '先尝试短时原生探测，仅在需要时回退。';

  @override
  String get latestRoute => '最近命中规则';

  @override
  String get directRoute => '直连';

  @override
  String proxyRoute(Object tag) {
    return '代理 · $tag';
  }

  @override
  String get recentRoutingDecisions => '最近路由决策';

  @override
  String get noRoutingDecisionsYet => '暂无路由决策。浏览一些网站，然后刷新此页面。';

  @override
  String get editRoutingRules => '编辑路由规则';

  @override
  String get routingRulesHelp =>
      '内置默认遵循常见分流模式：局域网直连、国内域名直连、国内 IP 直连。全局模式仅保留局域网和自定义规则。';

  @override
  String get lanDirectRule => '局域网/私有网络直连';

  @override
  String get cnDomainsDirectRule => '国内域名直连';

  @override
  String get cnIpsDirectRule => '国内 IP 直连';

  @override
  String get directApps => '直连应用';

  @override
  String get proxiedApps => '代理应用';

  @override
  String get perAppAndroidOnly => '按应用路由仅支持 Android';

  @override
  String get appListError => '无法列出应用；您仍可保存域名和 CIDR 规则。';

  @override
  String get customDirectDomains => '自定义直连域名/后缀';

  @override
  String get customDirectDomainsHint => '每行一个，例如：\nexample.cn\ncorp.local';

  @override
  String get customProxiedDomains => '自定义代理域名/后缀';

  @override
  String get customProxiedDomainsHint => '每行一个，例如：\nnetflix.com\nopenai.com';

  @override
  String get customDirectCidrs => '自定义直连 CIDR';

  @override
  String get customDirectCidrsHint => '每行一个，例如：\n10.10.0.0/16';

  @override
  String get customProxiedCidrs => '自定义代理 CIDR';

  @override
  String get customProxiedCidrsHint => '每行一个，例如：\n203.0.113.0/24';

  @override
  String get resetToDefaults => '恢复默认';

  @override
  String get pickDirectApps => '选择直连应用';

  @override
  String get pickProxiedApps => '选择代理应用';

  @override
  String get appBothDirectProxied => '一个应用不能同时设为直连和代理';

  @override
  String get searchApp => '搜索应用';

  @override
  String get noAppSelected => '未选择应用';

  @override
  String appCountSelected(Object first, Object count) {
    return '$first 等 $count 个应用';
  }

  @override
  String get error => '错误';
}
