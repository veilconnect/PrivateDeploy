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
  String get confirm => '确认';

  @override
  String copyProtocolLink(Object protocol) {
    return '复制加密 $protocol 配置';
  }

  @override
  String get ok => '确定';

  @override
  String get back => '返回';

  @override
  String get more => '更多';

  @override
  String get automatic => '自动';

  @override
  String get cloudApiKey => '云端 API Key';

  @override
  String get cloudAccess => '云服务访问';

  @override
  String get apiKey => 'API Key';

  @override
  String get verifyAndSave => '验证并保存';

  @override
  String get verifying => '验证中...';

  @override
  String get failedToSaveApiKey => '保存 API Key 失败';

  @override
  String get failedToSaveCloudAccess => '保存云服务访问失败';

  @override
  String get apiKeySavedAndVerified => 'API Key 已保存并验证通过';

  @override
  String get cloudAccessSavedAndVerified => '云服务访问已保存并验证通过';

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
  String deployToSshServer(Object target) {
    return '部署到 $target';
  }

  @override
  String get loadingNodes => '加载节点中...';

  @override
  String get vpnNotice => 'VPN 通知';

  @override
  String get vpnConflictMessageLocalized =>
      'VPN 权限被撤销，或被其他 VPN 应用 / 系统 VPN 中断。请关闭其他 VPN 后重试。';

  @override
  String get vpnPermissionDeniedMessageLocalized => '未授予 VPN 权限。请允许 VPN 访问后重试。';

  @override
  String get egressProbeFailureMessageLocalized =>
      '无法通过当前 VPN 路由抵达公网 IP 探测端点。下方最近的路由决策仍可能有效。';

  @override
  String get startupConnectivityFailureMessageLocalized =>
      'VPN 隧道已启动，但通过所选节点无法抵达公网 IP 探测端点。该节点可能不可达或配置有误。';

  @override
  String get startupProbeInconclusiveMessageLocalized =>
      'VPN 已连接，但 Android 在启动期间未能确认公网 IP，流量可能仍然可用。';

  @override
  String get tunnelUpstreamDegradedMessageLocalized =>
      '隧道已连接，但当前网络无法访问该节点的上游服务器。可切换到 Wi-Fi 或更换其他节点 —— 蜂窝运营商有时会屏蔽 VPS 的 IP。';

  @override
  String get cellularHelpTitle => '手机数据网络问题';

  @override
  String get cellularHelpAction => '了解原因';

  @override
  String get help => '帮助';

  @override
  String get cdnAccelerationTitle => 'CDN 加速';

  @override
  String get cdnAccelerationSubtitle => '可选:蜂窝网络出问题时通过 Cloudflare 中转';

  @override
  String get nextStep => '下一步';

  @override
  String get connection => '连接';

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
  String get waitingForCredentials => '节点还在准备连接信息';

  @override
  String get noNodeSelected => '未选择节点。';

  @override
  String get connect => '连接';

  @override
  String get retryConnect => '重试连接';

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
  String get connectionDetails => '连接详情';

  @override
  String get cloudNodes => '云线路';

  @override
  String get availableRoutes => '可用线路';

  @override
  String get cloudAccessNotConfigured => '还没有添加云访问';

  @override
  String get setCloudProviderApiKeyHint => '添加云服务访问后，就能在这台设备上查看并创建云线路。';

  @override
  String get setApiKey => '设置 API Key';

  @override
  String get setCloudAccess => '设置云访问';

  @override
  String get setSshAccess => '设置 SSH 访问';

  @override
  String get setSshAccessHint => '保存 SSH 服务器地址、用户名和密码后，这台设备就能直接部署线路。';

  @override
  String sshDeployUsesSavedAccess(Object target) {
    return '这条线路会通过已保存的 SSH 访问部署：$target';
  }

  @override
  String get benchmarkAll => '全部线路测速';

  @override
  String get failedToLoad => '加载失败';

  @override
  String get noCloudNodesYet => '暂无云节点';

  @override
  String get deployFirstNodeHint => '先创建一个云线路，然后就能在这台设备上连接。';

  @override
  String get deployNode => '创建线路';

  @override
  String get manualProfilesDesc => '仅保存在这台设备上的线路配置';

  @override
  String get activeNode => '当前线路';

  @override
  String get useAndConnect => '连接';

  @override
  String get useAndSwitch => '切换到此线路';

  @override
  String get speedTest => '速度测试';

  @override
  String get retrySpeedTest => '重新测速';

  @override
  String get testing => '测试中...';

  @override
  String get protocol => '协议';

  @override
  String chooseProtocolForNode(Object label) {
    return '为 $label 选择协议';
  }

  @override
  String get protocolAutomaticHint => '自动跟随最近测速结果或当前最快的可用协议。';

  @override
  String protocolSaved(Object label, Object protocol) {
    return '$label 下次连接时将使用 $protocol。';
  }

  @override
  String get active => '已就绪';

  @override
  String get provisioning => '准备中';

  @override
  String get inUse => '正在使用';

  @override
  String get selectedRoute => '已选中';

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
  String get failedToConnectVpn => 'VPN 连接失败';

  @override
  String get failedToSwitchActiveVpnNode => '切换活动 VPN 节点失败';

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
  String get workspaceGuideSetupTitle => '先添加云访问';

  @override
  String get workspaceGuideSetupMessage =>
      '添加云服务 API 访问或 SSH 访问后，这台设备就能拉取线路、部署新线路，并在稍后重新连接。';

  @override
  String get workspaceGuideDeployTitle => '先准备第一条线路';

  @override
  String get workspaceGuideDeployMessage => '先部署一个云线路；如果你已经有现成配置，也可以直接导入使用。';

  @override
  String get workspaceGuideChooseTitle => '已经可以连接';

  @override
  String get workspaceGuideChooseMessage =>
      '直接点“连接”会自动选择最快线路；如果你想手动挑选，也可以先在下方选线路。';

  @override
  String get workspaceGuideSyncTitle => '节点还在准备中';

  @override
  String get workspaceGuideSyncMessage =>
      '这些线路已经显示出来，但这台设备还在等待连接信息。可以先刷新，或者等它们就绪后再连接。';

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
  String get benchmarkAllNodesTitle => '全部线路测速';

  @override
  String get benchmarkAllNodesConfirm =>
      '此测速将临时断开当前 VPN 连接，用真实下载样本测试每条就绪的云线路，然后恢复之前的连接。\n\n继续？';

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
  String get deployNodeTitle => '创建线路';

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
  String get importFromUrl => '导入加密配置';

  @override
  String get profileName => '配置名称';

  @override
  String get optionalProfileNameHint => '可选，覆盖分享内的配置名称';

  @override
  String get egMySubscription => '例如：我的订阅';

  @override
  String get urlOrProxyLinks => '订阅 URL 或代理链接';

  @override
  String get urlOrProxyLinksHint => 'https://... 或 ss://... 或 vless://...';

  @override
  String get pasteFromClipboard => '从剪贴板粘贴';

  @override
  String get pleaseEnterUrlOrLinks => '请输入订阅 URL 或代理链接';

  @override
  String get enterHttpUrlOrLinks =>
      '请输入订阅 URL 或代理链接（https://、ss://、vless:// 等）';

  @override
  String get importEncryptedProfile => '导入加密配置';

  @override
  String get encryptedConfig => '加密配置';

  @override
  String get pasteEncryptedConfigHint => '粘贴从 PrivateDeploy 复制的加密内容...';

  @override
  String get pleasePasteEncryptedConfig => '请粘贴加密配置内容';

  @override
  String get enterEncryptedConfig => '请粘贴从 PrivateDeploy 复制的加密内容';

  @override
  String get createProfile => '新建本地配置';

  @override
  String get egMyVpnConfig => '例如：我的 JSON 配置';

  @override
  String get config => 'sing-box JSON';

  @override
  String get pasteProxyLinksOrJson => '粘贴 sing-box JSON...';

  @override
  String get pleaseEnterProfileName => '请输入配置名称';

  @override
  String get pleasePasteConfig => '请粘贴 sing-box JSON';

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
  String get deployCloudNode => '创建云线路';

  @override
  String get importProfile => '导入加密配置';

  @override
  String get createProfileTooltip => '新建本地配置';

  @override
  String get copyAllLinks => '复制加密节点';

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
  String encryptedImportFailed(Object error) {
    return '导入加密配置失败：$error';
  }

  @override
  String networkError(Object error) {
    return '网络错误：$error';
  }

  @override
  String get unrecognizedFormat =>
      '无法识别的格式。请粘贴代理链接（ss://、vless:// 等）或 sing-box JSON。';

  @override
  String get invalidConfigNotJsonObject => '配置无效：不是 JSON 对象';

  @override
  String get invalidConfigMissingOutbounds => '配置无效：缺少或为空的 “outbounds” 节';

  @override
  String get invalidConfigNotJson => '配置无效：不是合法 JSON';

  @override
  String invalidConfigGeneric(Object error) {
    return '配置无效：$error';
  }

  @override
  String apiKeyConfiguredMask(Object length) {
    return '•••• （$length 位）';
  }

  @override
  String get vpnRouteDecisionProxy => '代理';

  @override
  String get vpnRouteDecisionDirect => '直连';

  @override
  String get vpnRouteDecisionDns => 'DNS';

  @override
  String get vpnStatusConnected => '已连接';

  @override
  String get vpnStatusConnecting => '连接中';

  @override
  String get vpnStatusDisconnecting => '断开中';

  @override
  String get vpnStatusDisconnected => '已断开';

  @override
  String routingSummaryGlobal(Object dns) {
    return '全部流量经 VPN，局域网直连 · $dns';
  }

  @override
  String routingSummaryGlobalWithCustom(Object count, Object dns) {
    return '全部流量经 VPN，局域网直连，$count 条自定义规则 · $dns';
  }

  @override
  String get routingSummaryNoBuiltins => '未启用任何内置规则';

  @override
  String routingSummaryWithCustom(Object builtins, Object count) {
    return '$builtins · $count 条自定义规则';
  }

  @override
  String get routingTagLanDirect => '局域网直连';

  @override
  String get routingTagCnAppsDirect => '国内应用直连';

  @override
  String get routingTagCnDomainsDirect => '国内域名直连';

  @override
  String get routingTagCnIpsDirect => '国内 IP 直连';

  @override
  String get profileContentSaved => '配置内容已保存';

  @override
  String get saveFailed => '保存失败';

  @override
  String get pasteSingboxJsonHint => '在此粘贴 sing-box JSON 配置...';

  @override
  String get server => '云服务';

  @override
  String get standaloneCloudAccess => '云服务访问';

  @override
  String standaloneCloudAccessDesc(Object provider) {
    return '此设备直接调用 $provider API';
  }

  @override
  String get standaloneSshAccessDesc => '此设备通过 SSH 直接部署';

  @override
  String get cloudProvider => '云服务';

  @override
  String cloudProviderDirect(Object name) {
    return '$name · 直连';
  }

  @override
  String get chooseCloudProviderHint => '添加访问时再选择云服务或 SSH。';

  @override
  String get sshAccess => 'SSH 访问';

  @override
  String get sshHost => 'SSH 主机';

  @override
  String get username => '用户名';

  @override
  String get sshPassword => 'SSH 密码';

  @override
  String get sensitiveData => '安全与备份';

  @override
  String get sensitiveDataDesc =>
      '保存的云访问会保存在设备安全存储中。备份导出和恢复可能暴露敏感信息，分享备份后请及时轮换或替换凭据。';

  @override
  String get copyCloudBackup => '导出加密云备份';

  @override
  String get copyCloudBackupDesc => '先查看摘要，再加密复制包含已保存云访问和云线路记录的云备份。';

  @override
  String get restoreCloudBackup => '导入加密云备份';

  @override
  String get restoreCloudBackupDesc =>
      '粘贴从 PrivateDeploy 导出的加密云备份，以恢复已保存云访问和云线路记录。';

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
  String get routingModeDesc => '局域网直连 · 国内应用直连 · 国内域名直连 · 国内 IP 直连';

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
  String get clearLocalCloudDataDesc => '移除已保存的访问和本地节点缓存';

  @override
  String get clearLocalCloudDataTitle => '清除本地云数据？';

  @override
  String clearLocalCloudDataConfirm(Object provider) {
    return '此操作仅移除本设备上已保存的 $provider 访问和缓存的云节点记录，不会删除任何云实例。';
  }

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
  String get backupSensitiveWarning => '加密后的云备份文本显示如下。只有知道分享口令的人才能导入。';

  @override
  String get backupClipboardWarning =>
      '加密云备份已复制到剪贴板。即使通过微信等软件转发，接收方也仍需分享口令才能导入。';

  @override
  String get backupReviewWarning =>
      '复制前请查看以下备份摘要。复制时会先要求输入分享口令，剪贴板中不会出现原始 JSON。';

  @override
  String get copySensitiveBackup => '复制加密备份';

  @override
  String get copyAgain => '再次复制';

  @override
  String get revealJson => '显示加密文本';

  @override
  String get hideJson => '隐藏加密文本';

  @override
  String get copySensitiveBackupTitle => '复制加密备份？';

  @override
  String get copySensitiveBackupConfirm => '请先输入分享口令。复制到剪贴板的是加密文本，不是原始备份 JSON。';

  @override
  String get sensitiveBackupCopied => '加密备份已复制到剪贴板';

  @override
  String get revealSensitiveBackupTitle => '显示加密备份？';

  @override
  String get revealSensitiveBackupConfirm =>
      '请先输入分享口令。屏幕上显示的是加密文本，不是原始备份 JSON。';

  @override
  String get reveal => '显示';

  @override
  String get restoreCloudBackupTitle => '导入加密云备份';

  @override
  String get restoreCloudBackupDesc2 =>
      '粘贴从此应用导出的加密云备份，再输入相同的分享口令。导入后可能替换已保存的访问，并覆盖这台设备上的本地云线路缓存。';

  @override
  String get pasteCloudBackupHint => '在此粘贴加密云备份文本';

  @override
  String get pasteClipboard => '粘贴剪贴板';

  @override
  String get restore => '恢复';

  @override
  String get restoreThisBackupTitle => '恢复此备份？';

  @override
  String get restoreThisBackupConfirm =>
      '这将覆盖此设备上的本地云节点缓存。如果备份包含已保存的访问，它将替换当前保存的凭据。';

  @override
  String get backupJsonEmpty => '加密备份不能为空';

  @override
  String get backupJsonInvalid => '加密备份尚无效';

  @override
  String get cloudBackupRestored => '云备份已恢复';

  @override
  String get sharePassphrase => '分享口令';

  @override
  String get confirmSharePassphrase => '确认口令';

  @override
  String get passphraseRequired => '请输入分享口令';

  @override
  String get passphraseMismatch => '两次输入的口令不一致';

  @override
  String get encryptBeforeCopyTitle => '复制前先加密';

  @override
  String get encryptBeforeCopyMessage => '请先设置分享口令。只有知道相同口令的人，才能在另一台设备上导入这份内容。';

  @override
  String encryptedProtocolCopied(Object protocol) {
    return '已复制加密 $protocol 配置';
  }

  @override
  String get encryptedNodeCopied => '已复制加密节点';

  @override
  String encryptedCopyFailed(Object error) {
    return '复制加密内容失败：$error';
  }

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
  String get vpnExcludedAppsTitle => '系统级直连应用';

  @override
  String vpnExcludedAppsDescription(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '当前有 $count 个应用被排除在 Android VPN 覆盖范围之外，会直接走本地网络。',
      zero: '当前没有被排除在 Android VPN 覆盖范围之外的应用。',
    );
    return '$_temp0';
  }

  @override
  String vpnExcludedAppsMore(int count) {
    return '另有 $count 个';
  }

  @override
  String get connectVpnToMeasure => '连接 VPN 以测量当前出口 IP';

  @override
  String get refreshing => '刷新中...';

  @override
  String get probeUnavailable => '探测不可用';

  @override
  String get egressProbeHelp => '先尝试短时原生探测，仅在需要时回退。';

  @override
  String get egressProbeBusy => '正在探测出口...';

  @override
  String egressLastSeen(Object ip) {
    return '$ip（上次探测）';
  }

  @override
  String get egressProbeStillRoutingHint => 'VPN 仍在转发流量，只是出口探测暂未刷新。';

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
      '分流模式可单独开关：局域网直连、国内域名直连、国内 IP 直连。下方还可单独指定走代理或直连的应用，并自定义域名 / CIDR。全局模式仅保留局域网和自定义规则。';

  @override
  String get dnsMode => 'DNS 模式';

  @override
  String get cnOptimizedDns => '中国优化 DNS';

  @override
  String get strictProxyDns => '严格代理 DNS';

  @override
  String get systemDns => '系统 DNS';

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
