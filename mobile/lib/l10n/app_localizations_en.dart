// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'PrivateDeploy';

  @override
  String get workspace => 'Workspace';

  @override
  String get settings => 'Settings';

  @override
  String get refresh => 'Refresh';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String get delete => 'Delete';

  @override
  String get close => 'Close';

  @override
  String get create => 'Create';

  @override
  String get import_ => 'Import';

  @override
  String get retry => 'Retry';

  @override
  String get copy => 'Copy';

  @override
  String get ok => 'OK';

  @override
  String get back => 'Back';

  @override
  String get cloudApiKey => 'Cloud API Key';

  @override
  String get apiKey => 'API Key';

  @override
  String get verifyAndSave => 'Verify & Save';

  @override
  String get verifying => 'Verifying...';

  @override
  String get failedToSaveApiKey => 'Failed to save API key';

  @override
  String get apiKeySavedAndVerified => 'API key saved and verified';

  @override
  String get notSet => 'Not set';

  @override
  String pasteCloudProviderApiKey(Object provider) {
    return 'Paste your $provider API key';
  }

  @override
  String deployToCloudProvider(Object provider) {
    return 'Deploy to $provider';
  }

  @override
  String get loadingNodes => 'Loading nodes...';

  @override
  String get vpnNotice => 'VPN notice';

  @override
  String get nextStep => 'Next step';

  @override
  String get connection => 'Connection';

  @override
  String get connected => 'Connected';

  @override
  String get connecting => 'Connecting...';

  @override
  String get disconnecting => 'Disconnecting...';

  @override
  String get disconnected => 'Disconnected';

  @override
  String get tapConnectHint => 'Tap Connect to use the fastest node.';

  @override
  String get waitingForCredentials => 'Waiting for node credentials…';

  @override
  String get noNodeSelected => 'No node selected.';

  @override
  String get connect => 'Connect';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get restartVpn => 'Restart VPN';

  @override
  String get processingVpn => 'Processing VPN...';

  @override
  String get nativeVpnUnavailable => 'Native VPN unavailable';

  @override
  String get nativeVpnUnavailableMessage =>
      'This build does not include a usable native VPN runtime.';

  @override
  String upStats(Object value) {
    return 'Up $value';
  }

  @override
  String downStats(Object value) {
    return 'Down $value';
  }

  @override
  String speedStats(Object value) {
    return 'Speed $value';
  }

  @override
  String get cloudNodes => 'Cloud Nodes';

  @override
  String get cloudAccessNotConfigured => 'Cloud access not configured';

  @override
  String setCloudProviderApiKeyHint(Object provider) {
    return 'Set your $provider API key to get started.';
  }

  @override
  String get setApiKey => 'Set API Key';

  @override
  String get benchmarkAll => 'Benchmark All';

  @override
  String get failedToLoad => 'Failed to load';

  @override
  String get noCloudNodesYet => 'No cloud nodes yet';

  @override
  String get deployFirstNodeHint =>
      'Create one cloud node to start routing traffic from this device.';

  @override
  String get deployNode => 'Deploy Node';

  @override
  String get manualProfilesDesc => 'Profiles stored only on this device';

  @override
  String get activeNode => 'Active Node';

  @override
  String get useAndConnect => 'Use & Connect';

  @override
  String get useAndSwitch => 'Use & Switch';

  @override
  String get speedTest => 'Speed Test';

  @override
  String get retrySpeedTest => 'Retry Speed Test';

  @override
  String get testing => 'Testing...';

  @override
  String get active => 'Ready';

  @override
  String get provisioning => 'Starting';

  @override
  String get inUse => 'Selected';

  @override
  String get nodeDetails => 'Node Details';

  @override
  String get deleteNode => 'Delete Node';

  @override
  String probesStat(Object successful, Object total) {
    return '$successful/$total probes';
  }

  @override
  String msLatency(Object ms) {
    return '$ms ms latency';
  }

  @override
  String get deleteNodeTitle => 'Delete Node';

  @override
  String deleteNodeConfirm(Object label) {
    return 'Delete \"$label\"?\n\nThis will destroy the server permanently.';
  }

  @override
  String get nodeDeleted => 'Node deleted';

  @override
  String get nodeDeletedCleanupNeeded =>
      'Node deleted, but local cleanup needs attention';

  @override
  String get failedToDelete => 'Failed to delete';

  @override
  String get nodeNotReady => 'Node is not ready yet';

  @override
  String get failedToActivateNode => 'Failed to activate node';

  @override
  String get nodeReadyConnected => 'Node is ready and connected';

  @override
  String get failedToActivate => 'Failed to activate';

  @override
  String get profileActivatedConnected => 'Profile activated and connected';

  @override
  String get vpnConnectedSuccess => 'VPN connected successfully';

  @override
  String get vpnDisconnectedSuccess => 'VPN disconnected successfully';

  @override
  String get failedToDisconnectVpn => 'Failed to disconnect VPN';

  @override
  String get vpnRestartedSuccess => 'VPN restarted successfully';

  @override
  String get vpnBusyWait => 'VPN is busy, please wait a moment';

  @override
  String tryingBackupNode(Object index, Object total, Object label) {
    return 'Trying backup node $index/$total: $label';
  }

  @override
  String get allNodesFailedCheckNetwork =>
      'All ready nodes failed to connect. Check your network (try Wi-Fi) or refresh the node list.';

  @override
  String get noCredentialsHint =>
      'These cloud nodes are visible, but this device does not have their connection credentials yet. Restore a cloud backup or deploy/use a node from this device first.';

  @override
  String get noNodeSelectedHint =>
      'No ready node selected yet. Choose a cloud node below or create/import a profile first.';

  @override
  String usingFastestNode(Object label, Object metric, Object endpoint) {
    return 'Using recent fastest node: $label$metric$endpoint. Refreshing ranking in background...';
  }

  @override
  String get quickTestingNodes =>
      'Quick-testing ready nodes and selecting the fastest one...';

  @override
  String get noReadyCloudNode => 'No ready cloud node is available yet';

  @override
  String get workspaceGuideSetupTitle => 'Add cloud access';

  @override
  String workspaceGuideSetupMessage(Object provider) {
    return 'Save your $provider API key so this device can list nodes, deploy new ones, and reconnect later.';
  }

  @override
  String get workspaceGuideDeployTitle => 'Create your first route';

  @override
  String get workspaceGuideDeployMessage =>
      'Start with one cloud node, or import an existing profile if you already have one.';

  @override
  String get workspaceGuideChooseTitle => 'Ready to connect';

  @override
  String get workspaceGuideChooseMessage =>
      'Tap Connect to pick the fastest ready node automatically, or choose one below first.';

  @override
  String get workspaceGuideSyncTitle => 'Finish node setup';

  @override
  String get workspaceGuideSyncMessage =>
      'Your nodes are visible, but this device is still waiting for connection details. Refresh, or use a node from this device once it is ready.';

  @override
  String get latencyTestUnavailable => 'Latency test was unavailable.';

  @override
  String usingNodeInstead(Object error, Object label) {
    return '$error Using $label instead.';
  }

  @override
  String get continue_ => 'Continue';

  @override
  String get chooseCloudNode => 'Choose a cloud node';

  @override
  String get chooseCloudNodeDesc =>
      'Connect needs one active node. Pick which cloud node to use now.';

  @override
  String get nodeDeploying => 'Node deploying... It takes 3-5 minutes.';

  @override
  String get failedToCreate => 'Failed to create';

  @override
  String get nodeNotReadyForSpeedTest => 'Node is not ready for speed testing';

  @override
  String get failedToConnectSpeedTestTunnel =>
      'Failed to connect speed test tunnel';

  @override
  String get noReadyNodeForTesting =>
      'No ready cloud node is available for testing';

  @override
  String get benchmarkAllNodesTitle => 'Benchmark All Nodes';

  @override
  String get benchmarkAllNodesConfirm =>
      'This benchmark will temporarily disconnect your current VPN connection, test each ready cloud node with a real download sample, and then restore your previous connection.\n\nContinue?';

  @override
  String get startBenchmark => 'Start Benchmark';

  @override
  String get benchmarkingNodes =>
      'Benchmarking ready nodes with real download samples...';

  @override
  String benchmarkingNode(Object label, Object index, Object total) {
    return 'Benchmarking $label ($index/$total)...';
  }

  @override
  String get nodeNotReadyForBenchmark => 'Node is not ready for benchmarking';

  @override
  String get failedToConnectBenchmarkTunnel =>
      'Failed to connect benchmark tunnel';

  @override
  String bestBenchmark(Object label, Object metric, Object endpoint) {
    return 'Best benchmark: $label$metric$endpoint';
  }

  @override
  String get restoreConnectionFailed => 'Previous connection restore failed';

  @override
  String get deployNodeTitle => 'Deploy Node';

  @override
  String get loadingRegionsPlans => 'Loading regions and plans...';

  @override
  String get deploymentUnavailable =>
      'Deployment options are unavailable right now.';

  @override
  String get retryLoading => 'Retry Loading';

  @override
  String get nodeNameOptional => 'Node Name (Optional)';

  @override
  String get autoGenerateHint => 'Auto-generate if left blank';

  @override
  String get region => 'Region';

  @override
  String get plan => 'Plan';

  @override
  String get noPlansInRegion =>
      'No supported plans are available in this region.';

  @override
  String get deploy => 'Deploy';

  @override
  String get loading => 'Loading...';

  @override
  String get selectRegionAndPlan => 'Please select region and plan';

  @override
  String get planNotAvailableInRegion =>
      'Selected plan is not available in the chosen region';

  @override
  String get importFromUrl => 'Import from URL';

  @override
  String get profileName => 'Profile Name';

  @override
  String get egMySubscription => 'e.g. My Subscription';

  @override
  String get urlOrProxyLinks => 'URL or Proxy Links';

  @override
  String get urlOrProxyLinksHint => 'https://... or ss://... or vless://...';

  @override
  String get pasteFromClipboard => 'Paste from clipboard';

  @override
  String get pleaseEnterUrlOrLinks => 'Please enter a URL or proxy links';

  @override
  String get enterHttpUrlOrLinks =>
      'Enter an http(s) URL or proxy links (ss://, vless://, etc.)';

  @override
  String get createProfile => 'Create Profile';

  @override
  String get egMyVpnConfig => 'e.g. My VPN Config';

  @override
  String get config => 'Config';

  @override
  String get pasteProxyLinksOrJson => 'Paste proxy links or sing-box JSON...';

  @override
  String get pleaseEnterProfileName => 'Please enter a profile name';

  @override
  String get pleasePasteConfig => 'Please paste config or proxy links';

  @override
  String get renameProfile => 'Rename Profile';

  @override
  String get manualProfiles => 'Manual Profiles';

  @override
  String createdAt(Object date) {
    return 'Created: $date';
  }

  @override
  String get viewEditConfig => 'View / Edit Config';

  @override
  String get rename => 'Rename';

  @override
  String get deployCloudNode => 'Deploy cloud node';

  @override
  String get importProfile => 'Import profile';

  @override
  String get createProfileTooltip => 'Create profile';

  @override
  String get copyAllLinks => 'Copy All Links';

  @override
  String get nodeInfo => 'Node Info';

  @override
  String get ip => 'IP';

  @override
  String get ipv6 => 'IPv6';

  @override
  String get statusLabel => 'Status';

  @override
  String get created => 'Created';

  @override
  String get shadowsocks => 'Shadowsocks';

  @override
  String get hysteria2 => 'Hysteria2';

  @override
  String get vlessReality => 'VLESS-Reality';

  @override
  String get trojan => 'Trojan';

  @override
  String get port => 'Port';

  @override
  String get password => 'Password';

  @override
  String get method => 'Method';

  @override
  String get sni => 'SNI';

  @override
  String get uuid => 'UUID';

  @override
  String get publicKey => 'Public Key';

  @override
  String get shortId => 'Short ID';

  @override
  String labelCopied(Object label) {
    return '$label copied';
  }

  @override
  String linksCopied(Object count) {
    return '$count links copied';
  }

  @override
  String get deleteProfile => 'Delete Profile';

  @override
  String deleteProfileConfirm(Object name) {
    return 'Are you sure you want to delete \"$name\"?';
  }

  @override
  String get profileDeleted => 'Profile deleted';

  @override
  String get failedToDeleteProfile => 'Failed to delete';

  @override
  String get profileRenamed => 'Profile renamed';

  @override
  String get failedToRename => 'Failed to rename';

  @override
  String get profileCreatedSuccess => 'Profile created successfully';

  @override
  String get failedToCreateProfile => 'Failed to create profile';

  @override
  String get unrecognizedConfigFormat => 'Unrecognized config format';

  @override
  String get importedSuccess => 'Imported successfully';

  @override
  String get failedToImport => 'Failed to import';

  @override
  String get fetchingSubscription => 'Fetching subscription...';

  @override
  String get failedToParseSubscription => 'Failed to parse subscription';

  @override
  String get failedToParseProxyLinks => 'Failed to parse proxy links';

  @override
  String networkError(Object error) {
    return 'Network error: $error';
  }

  @override
  String get unrecognizedFormat =>
      'Unrecognized format. Paste proxy links (ss://, vless://, etc.) or sing-box JSON.';

  @override
  String get profileContentSaved => 'Profile content saved';

  @override
  String get saveFailed => 'Save failed';

  @override
  String get pasteSingboxJsonHint =>
      'Paste sing-box JSON configuration here...';

  @override
  String get server => 'Server';

  @override
  String get standaloneCloudAccess => 'Standalone Cloud Access';

  @override
  String get standaloneCloudAccessDesc =>
      'This device directly calls the Vultr API';

  @override
  String get cloudProvider => 'Cloud Provider';

  @override
  String cloudProviderDirect(Object name) {
    return '$name (direct)';
  }

  @override
  String get sensitiveData => 'Sensitive Data';

  @override
  String get sensitiveDataDesc =>
      'API keys stay in device secure storage. Backup export and restore can expose secrets, so rotate keys if a backup is shared.';

  @override
  String get copyCloudBackup => 'Copy Cloud Backup';

  @override
  String get copyCloudBackupDesc =>
      'Review the summary first, then copy sensitive backup JSON with API key and local node records';

  @override
  String get restoreCloudBackup => 'Restore Cloud Backup';

  @override
  String get restoreCloudBackupDesc =>
      'Paste a backup JSON, validate it, then confirm restoring the API key and local nodes';

  @override
  String get app => 'App';

  @override
  String get theme => 'Theme';

  @override
  String get usingSystemDarkTheme => 'Using system dark theme';

  @override
  String get usingSystemLightTheme => 'Using system light theme';

  @override
  String get vpnStatus => 'VPN Status';

  @override
  String get unavailableOnBuild => 'Unavailable on this build';

  @override
  String get routingMode => 'Routing Mode';

  @override
  String get split => 'Split';

  @override
  String get global => 'Global';

  @override
  String get routingModeDesc =>
      'LAN direct · CN domains direct · CN IPs direct';

  @override
  String get vpnDiagnostics => 'VPN Diagnostics';

  @override
  String get vpnDiagnosticsDesc =>
      'Check current egress IP and recent split-routing hits';

  @override
  String get routingRules => 'Routing Rules';

  @override
  String get routingRulesDesc =>
      'Built-in split rules + custom domains, CIDRs, and apps';

  @override
  String get routingRulesSaved => 'Routing rules saved';

  @override
  String get routingRulesReset => 'Routing rules reset to defaults';

  @override
  String get clearLocalCloudData => 'Clear Local Cloud Data';

  @override
  String get clearLocalCloudDataDesc =>
      'Removes saved API key and local node cache';

  @override
  String get clearLocalCloudDataTitle => 'Clear Local Cloud Data?';

  @override
  String get clearLocalCloudDataConfirm =>
      'This removes the saved Vultr API key and cached cloud node records from this device only. It does not delete any cloud instances.';

  @override
  String get clear => 'Clear';

  @override
  String get localCloudDataCleared => 'Local cloud data cleared';

  @override
  String get about => 'About';

  @override
  String get version => 'Version';

  @override
  String get unavailable => 'Unavailable';

  @override
  String get multiProtocolTool => 'Multi-protocol proxy deployment tool';

  @override
  String get cloudBackupReady => 'Cloud Backup Ready';

  @override
  String get backupSensitiveWarning =>
      'Sensitive backup JSON is visible below. Store it safely because it includes your Vultr API key and node credentials.';

  @override
  String get backupClipboardWarning =>
      'Sensitive backup copied to your clipboard. Clipboard contents may be accessible to other apps until you replace them.';

  @override
  String get backupReviewWarning =>
      'Review the backup summary below before copying. The backup includes sensitive data such as your Vultr API key and node credentials.';

  @override
  String get copySensitiveBackup => 'Copy Sensitive Backup';

  @override
  String get copyAgain => 'Copy Again';

  @override
  String get revealJson => 'Reveal JSON';

  @override
  String get hideJson => 'Hide JSON';

  @override
  String get copySensitiveBackupTitle => 'Copy Sensitive Backup?';

  @override
  String get copySensitiveBackupConfirm =>
      'This will place the full backup JSON on the system clipboard, including the saved API key and node credentials.';

  @override
  String get sensitiveBackupCopied => 'Sensitive backup copied to clipboard';

  @override
  String get revealSensitiveBackupTitle => 'Reveal Sensitive Backup?';

  @override
  String get revealSensitiveBackupConfirm =>
      'This will display the full backup JSON on screen, including the saved API key and node credentials.';

  @override
  String get reveal => 'Reveal';

  @override
  String get restoreCloudBackupTitle => 'Restore Cloud Backup';

  @override
  String get restoreCloudBackupDesc2 =>
      'Paste a backup JSON exported from this app. Restoring can replace the saved API key and overwrite the local cloud node cache on this device.';

  @override
  String get pasteCloudBackupHint => 'Paste cloud backup JSON here';

  @override
  String get pasteClipboard => 'Paste Clipboard';

  @override
  String get restore => 'Restore';

  @override
  String get restoreThisBackupTitle => 'Restore This Backup?';

  @override
  String get restoreThisBackupConfirm =>
      'This will overwrite the local cloud node cache on this device. If the backup contains an API key, it will replace the currently saved key.';

  @override
  String get backupJsonEmpty => 'Backup JSON cannot be empty';

  @override
  String get backupJsonInvalid => 'Backup JSON is not valid yet';

  @override
  String get cloudBackupRestored => 'Cloud backup restored';

  @override
  String get vpnDiagnosticsTitle => 'VPN Diagnostics';

  @override
  String get session => 'Session';

  @override
  String get vpnConnectedDiag =>
      'VPN connected — data below is from the active session';

  @override
  String get vpnConnectingDiag =>
      'VPN is connecting — diagnostics may change shortly';

  @override
  String get vpnDisconnectingDiag =>
      'VPN is disconnecting — results may be stale';

  @override
  String get vpnDisconnectedDiag =>
      'VPN disconnected — showing rule hits from the last session';

  @override
  String lastUpdated(Object time) {
    return 'Last updated: $time';
  }

  @override
  String get currentEgressIp => 'Current Egress IP';

  @override
  String get connectVpnToMeasure => 'Connect VPN to measure current egress IP';

  @override
  String get refreshing => 'Refreshing...';

  @override
  String get probeUnavailable => 'Probe unavailable';

  @override
  String get egressProbeHelp =>
      'Trying a short native probe first, then falling back only if needed.';

  @override
  String get recentRoutingDecisions => 'Recent Routing Decisions';

  @override
  String get noRoutingDecisionsYet =>
      'No routing decisions yet. Browse a few websites, then refresh this page.';

  @override
  String get editRoutingRules => 'Edit Routing Rules';

  @override
  String get routingRulesHelp =>
      'Built-in defaults follow common split patterns: LAN direct, CN domains direct, CN IPs direct. Global mode only keeps LAN and custom rules.';

  @override
  String get lanDirectRule => 'LAN / private networks direct';

  @override
  String get cnDomainsDirectRule => 'CN domains direct';

  @override
  String get cnIpsDirectRule => 'CN IPs direct';

  @override
  String get directApps => 'Direct apps';

  @override
  String get proxiedApps => 'Proxied apps';

  @override
  String get perAppAndroidOnly => 'Per-app routing is Android-only';

  @override
  String get appListError =>
      'Could not list apps; you can still save domain and CIDR rules.';

  @override
  String get customDirectDomains => 'Custom direct domains / suffixes';

  @override
  String get customDirectDomainsHint =>
      'One per line, e.g.:\nexample.cn\ncorp.local';

  @override
  String get customProxiedDomains => 'Custom proxied domains / suffixes';

  @override
  String get customProxiedDomainsHint =>
      'One per line, e.g.:\nnetflix.com\nopenai.com';

  @override
  String get customDirectCidrs => 'Custom direct CIDRs';

  @override
  String get customDirectCidrsHint => 'One per line, e.g.:\n10.10.0.0/16';

  @override
  String get customProxiedCidrs => 'Custom proxied CIDRs';

  @override
  String get customProxiedCidrsHint => 'One per line, e.g.:\n203.0.113.0/24';

  @override
  String get resetToDefaults => 'Reset to defaults';

  @override
  String get pickDirectApps => 'Pick direct apps';

  @override
  String get pickProxiedApps => 'Pick proxied apps';

  @override
  String get appBothDirectProxied => 'An app cannot be both direct and proxied';

  @override
  String get searchApp => 'Search App';

  @override
  String get noAppSelected => 'No app selected';

  @override
  String appCountSelected(Object first, Object count) {
    return '$first and $count more apps';
  }

  @override
  String get error => 'Error';
}
