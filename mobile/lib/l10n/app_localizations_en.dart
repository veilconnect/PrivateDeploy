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
  String get confirm => 'Confirm';

  @override
  String copyProtocolLink(Object protocol) {
    return 'Copy Encrypted $protocol Config';
  }

  @override
  String get ok => 'OK';

  @override
  String get back => 'Back';

  @override
  String get more => 'More';

  @override
  String get automatic => 'Automatic';

  @override
  String get cloudApiKey => 'Cloud API Key';

  @override
  String get cloudAccess => 'Cloud Access';

  @override
  String get apiKey => 'API Key';

  @override
  String get verifyAndSave => 'Verify & Save';

  @override
  String get verifying => 'Verifying...';

  @override
  String get failedToSaveApiKey => 'Failed to save API key';

  @override
  String get failedToSaveCloudAccess => 'Failed to save cloud access';

  @override
  String get apiKeySavedAndVerified => 'API key saved and verified';

  @override
  String get cloudAccessSavedAndVerified => 'Cloud access saved and verified';

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
  String deployToSshServer(Object target) {
    return 'Deploy to $target';
  }

  @override
  String get loadingNodes => 'Loading nodes...';

  @override
  String get vpnNotice => 'VPN notice';

  @override
  String get vpnConflictMessageLocalized =>
      'VPN permission was revoked or another VPN app/system VPN interrupted this connection. Disable the other VPN and try again.';

  @override
  String get vpnPermissionDeniedMessageLocalized =>
      'VPN permission was not granted. Allow VPN access and try again.';

  @override
  String get egressProbeFailureMessageLocalized =>
      'Could not reach public IP probe endpoints through the current VPN route. Recent routing decisions below may still be valid.';

  @override
  String get startupConnectivityFailureMessageLocalized =>
      'VPN tunnel started, but traffic could not reach public IP probe endpoints through the selected node. The node may be unreachable or misconfigured.';

  @override
  String get startupProbeInconclusiveMessageLocalized =>
      'VPN connected, but Android could not confirm the public IP during startup. Traffic may still be available.';

  @override
  String get tunnelUpstreamDegradedMessageLocalized =>
      'Tunnel is up, but this node\'s upstream can\'t be reached from your current network. Try Wi-Fi or switching to a different node — cellular carriers sometimes block VPS IPs.';

  @override
  String get cellularHelpTitle => 'Cellular network issues';

  @override
  String get cellularHelpAction => 'Why?';

  @override
  String get help => 'Help';

  @override
  String get cdnAccelerationTitle => 'CDN acceleration';

  @override
  String get cdnAccelerationSubtitle =>
      'Optional: route through Cloudflare for cellular';

  @override
  String get nextStep => 'Next step';

  @override
  String get connection => 'Connect';

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
  String get waitingForCredentials =>
      'Node is still preparing connection details';

  @override
  String get noNodeSelected => 'No node selected.';

  @override
  String get connect => 'Connect';

  @override
  String get retryConnect => 'Retry connect';

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
  String get connectionDetails => 'Connection details';

  @override
  String get cloudNodes => 'Cloud Routes';

  @override
  String get availableRoutes => 'Available Routes';

  @override
  String get cloudAccessNotConfigured => 'Cloud access has not been added yet';

  @override
  String get setCloudProviderApiKeyHint =>
      'Add cloud API access to list routes and create new ones on this device.';

  @override
  String get setApiKey => 'Set API Key';

  @override
  String get setCloudAccess => 'Set Cloud Access';

  @override
  String get setSshAccess => 'Set SSH Access';

  @override
  String get setSshAccessHint =>
      'Save the SSH server host, username, and password so this device can deploy directly.';

  @override
  String sshDeployUsesSavedAccess(Object target) {
    return 'This route will deploy through the saved SSH access: $target';
  }

  @override
  String get benchmarkAll => 'Measure All';

  @override
  String get failedToLoad => 'Failed to load';

  @override
  String get noCloudNodesYet => 'No cloud nodes yet';

  @override
  String get deployFirstNodeHint =>
      'Create one cloud route, then connect from this device.';

  @override
  String get deployNode => 'Create Route';

  @override
  String get manualProfilesDesc => 'Routes saved only on this device';

  @override
  String get activeNode => 'Current Route';

  @override
  String get useAndConnect => 'Connect';

  @override
  String get useAndSwitch => 'Switch Here';

  @override
  String get speedTest => 'Speed Test';

  @override
  String get retrySpeedTest => 'Retry Speed Test';

  @override
  String get testing => 'Testing...';

  @override
  String get protocol => 'Protocol';

  @override
  String chooseProtocolForNode(Object label) {
    return 'Choose protocol for $label';
  }

  @override
  String get protocolAutomaticHint =>
      'Follow the latest benchmark or fastest available endpoint automatically.';

  @override
  String protocolSaved(Object label, Object protocol) {
    return '$label will use $protocol next time it connects.';
  }

  @override
  String get active => 'Ready';

  @override
  String get provisioning => 'Starting';

  @override
  String get inUse => 'In Use';

  @override
  String get selectedRoute => 'Selected';

  @override
  String get saved => 'Saved';

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
  String get failedToConnectVpn => 'Failed to connect VPN';

  @override
  String get failedToSwitchActiveVpnNode => 'Failed to switch active VPN node';

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
  String get workspaceGuideSetupMessage =>
      'Add cloud API access or SSH access so this device can list routes, deploy new ones, and reconnect later.';

  @override
  String get workspaceGuideDeployTitle => 'Prepare your first route';

  @override
  String get workspaceGuideDeployMessage =>
      'Start with one cloud route, or import an existing profile if you already have one.';

  @override
  String get workspaceGuideChooseTitle => 'Ready to connect';

  @override
  String get workspaceGuideChooseMessage =>
      'Tap Connect to pick the fastest ready route automatically, or choose one below first.';

  @override
  String get workspaceGuideSyncTitle => 'Routes are still getting ready';

  @override
  String get workspaceGuideSyncMessage =>
      'These routes are visible, but this device is still waiting for connection details. Refresh, or connect after they finish preparing.';

  @override
  String get workspaceStepAccess => 'Add access';

  @override
  String get workspaceStepRoute => 'Prepare route';

  @override
  String get workspaceStepConnect => 'Connect';

  @override
  String get workspaceStepDone => 'Done';

  @override
  String get workspaceStepCurrent => 'Now';

  @override
  String get workspaceStepUpcoming => 'Next';

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
  String get benchmarkAllNodesTitle => 'Measure All Routes';

  @override
  String get benchmarkAllNodesConfirm =>
      'This check will temporarily disconnect your current VPN connection, test each ready cloud route with a real download sample, and then restore your previous connection.\n\nContinue?';

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
  String get deployNodeTitle => 'Create Route';

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
  String get importFromUrl => 'Import Encrypted Config';

  @override
  String get profileName => 'Profile Name';

  @override
  String get optionalProfileNameHint => 'Optional shared profile name';

  @override
  String get egMySubscription => 'e.g. My Subscription';

  @override
  String get urlOrProxyLinks => 'Subscription URL or Proxy Links';

  @override
  String get urlOrProxyLinksHint => 'https://... or ss://... or vless://...';

  @override
  String get pasteFromClipboard => 'Paste from clipboard';

  @override
  String get pleaseEnterUrlOrLinks =>
      'Please enter a subscription URL or proxy links';

  @override
  String get enterHttpUrlOrLinks =>
      'Enter a subscription URL or proxy links (https://, ss://, vless://, etc.)';

  @override
  String get importEncryptedProfile => 'Import Encrypted Config';

  @override
  String get encryptedConfig => 'Encrypted Config';

  @override
  String get pasteEncryptedConfigHint =>
      'Paste encrypted content copied from PrivateDeploy...';

  @override
  String get pleasePasteEncryptedConfig =>
      'Please paste encrypted config content';

  @override
  String get enterEncryptedConfig =>
      'Paste encrypted content copied from PrivateDeploy';

  @override
  String get createProfile => 'Create Local Config';

  @override
  String get egMyVpnConfig => 'e.g. My JSON Config';

  @override
  String get config => 'sing-box JSON';

  @override
  String get pasteProxyLinksOrJson => 'Paste sing-box JSON...';

  @override
  String get pleaseEnterProfileName => 'Please enter a profile name';

  @override
  String get pleasePasteConfig => 'Please paste sing-box JSON';

  @override
  String get renameProfile => 'Rename Profile';

  @override
  String get manualProfiles => 'Saved Profiles';

  @override
  String createdAt(Object date) {
    return 'Created: $date';
  }

  @override
  String get viewEditConfig => 'Open Config';

  @override
  String get rename => 'Rename';

  @override
  String get deployCloudNode => 'Create cloud route';

  @override
  String get importProfile => 'Import Encrypted Config';

  @override
  String get createProfileTooltip => 'Create Local Config';

  @override
  String get copyAllLinks => 'Copy Encrypted Node';

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
  String encryptedImportFailed(Object error) {
    return 'Failed to import encrypted config: $error';
  }

  @override
  String networkError(Object error) {
    return 'Network error: $error';
  }

  @override
  String get unrecognizedFormat =>
      'Unrecognized format. Paste proxy links (ss://, vless://, etc.) or sing-box JSON.';

  @override
  String get invalidConfigNotJsonObject => 'Invalid config: not a JSON object';

  @override
  String get invalidConfigMissingOutbounds =>
      'Invalid config: missing or empty \"outbounds\" section';

  @override
  String get invalidConfigNotJson => 'Invalid config: not valid JSON';

  @override
  String invalidConfigGeneric(Object error) {
    return 'Invalid config: $error';
  }

  @override
  String apiKeyConfiguredMask(Object length) {
    return '•••• ($length chars)';
  }

  @override
  String get vpnRouteDecisionProxy => 'PROXY';

  @override
  String get vpnRouteDecisionDirect => 'DIRECT';

  @override
  String get vpnRouteDecisionDns => 'DNS';

  @override
  String get vpnStatusConnected => 'CONNECTED';

  @override
  String get vpnStatusConnecting => 'CONNECTING';

  @override
  String get vpnStatusDisconnecting => 'DISCONNECTING';

  @override
  String get vpnStatusDisconnected => 'DISCONNECTED';

  @override
  String routingSummaryGlobal(Object dns) {
    return 'All traffic via VPN, LAN bypassed · $dns';
  }

  @override
  String routingSummaryGlobalWithCustom(Object count, Object dns) {
    return 'All traffic via VPN, LAN bypassed, $count custom rule(s) · $dns';
  }

  @override
  String get routingSummaryNoBuiltins => 'No built-in rules enabled';

  @override
  String routingSummaryWithCustom(Object builtins, Object count) {
    return '$builtins · $count custom rule(s)';
  }

  @override
  String get routingTagLanDirect => 'LAN direct';

  @override
  String get routingTagCnAppsDirect => 'regional apps direct';

  @override
  String get routingTagCnDomainsDirect => 'CN domains direct';

  @override
  String get routingTagCnIpsDirect => 'CN IPs direct';

  @override
  String get profileContentSaved => 'Profile content saved';

  @override
  String get saveFailed => 'Save failed';

  @override
  String get pasteSingboxJsonHint =>
      'Paste sing-box JSON configuration here...';

  @override
  String get server => 'Cloud';

  @override
  String get standaloneCloudAccess => 'Cloud Access';

  @override
  String standaloneCloudAccessDesc(Object provider) {
    return 'This device directly calls the $provider API';
  }

  @override
  String get standaloneSshAccessDesc => 'This device deploys directly over SSH';

  @override
  String get cloudProvider => 'Cloud Service';

  @override
  String cloudProviderDirect(Object name) {
    return '$name · direct access';
  }

  @override
  String get chooseCloudProviderHint =>
      'Choose a cloud service or SSH when you add access.';

  @override
  String get sshAccess => 'SSH Access';

  @override
  String get sshHost => 'SSH Host';

  @override
  String get username => 'Username';

  @override
  String get sshPassword => 'SSH Password';

  @override
  String get sensitiveData => 'Security & Backup';

  @override
  String get sensitiveDataDesc =>
      'Saved cloud access stays in device secure storage. Backup export and restore can expose secrets, so rotate or replace credentials if a backup is shared.';

  @override
  String get copyCloudBackup => 'Export Encrypted Cloud Backup';

  @override
  String get copyCloudBackupDesc =>
      'Review the summary first, then encrypt and copy a cloud backup with your saved access and cloud route records.';

  @override
  String get restoreCloudBackup => 'Import Encrypted Cloud Backup';

  @override
  String get restoreCloudBackupDesc =>
      'Paste encrypted cloud backup content from PrivateDeploy to restore saved access and cloud route records.';

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
      'LAN direct · regional apps direct · CN domains direct · CN IPs direct';

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
      'Removes saved access and local node cache';

  @override
  String get clearLocalCloudDataTitle => 'Clear Local Cloud Data?';

  @override
  String clearLocalCloudDataConfirm(Object provider) {
    return 'This removes the saved $provider access and cached cloud node records from this device only. It does not delete any cloud instances.';
  }

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
      'Encrypted cloud backup text is visible below. Only someone with the same share passphrase can import it.';

  @override
  String get backupClipboardWarning =>
      'Encrypted cloud backup copied to your clipboard. Even if you share it through chat apps, the recipient still needs the share passphrase.';

  @override
  String get backupReviewWarning =>
      'Review the backup summary below first. Copying will require a share passphrase and the clipboard will never contain raw backup JSON.';

  @override
  String get copySensitiveBackup => 'Copy Encrypted Backup';

  @override
  String get copyAgain => 'Copy Again';

  @override
  String get revealJson => 'Reveal Encrypted Text';

  @override
  String get hideJson => 'Hide Encrypted Text';

  @override
  String get copySensitiveBackupTitle => 'Copy Encrypted Backup?';

  @override
  String get copySensitiveBackupConfirm =>
      'Enter a share passphrase first. The clipboard will receive encrypted backup text instead of raw JSON.';

  @override
  String get sensitiveBackupCopied => 'Encrypted backup copied to clipboard';

  @override
  String get revealSensitiveBackupTitle => 'Reveal Encrypted Backup?';

  @override
  String get revealSensitiveBackupConfirm =>
      'Enter a share passphrase first. The screen will show encrypted backup text instead of raw JSON.';

  @override
  String get reveal => 'Reveal';

  @override
  String get restoreCloudBackupTitle => 'Import Encrypted Cloud Backup';

  @override
  String get restoreCloudBackupDesc2 =>
      'Paste encrypted cloud backup content exported from this app, then enter the same share passphrase. Importing can replace your saved access and overwrite this device\'s local cloud route cache.';

  @override
  String get pasteCloudBackupHint => 'Paste encrypted cloud backup text here';

  @override
  String get pasteClipboard => 'Paste Clipboard';

  @override
  String get restore => 'Restore';

  @override
  String get restoreThisBackupTitle => 'Restore This Backup?';

  @override
  String get restoreThisBackupConfirm =>
      'This will overwrite the local cloud node cache on this device. If the backup contains saved access, it will replace the currently saved credentials.';

  @override
  String get backupJsonEmpty => 'Encrypted backup cannot be empty';

  @override
  String get backupJsonInvalid => 'Encrypted backup is not valid yet';

  @override
  String get cloudBackupRestored => 'Cloud backup restored';

  @override
  String get sharePassphrase => 'Share Passphrase';

  @override
  String get confirmSharePassphrase => 'Confirm Passphrase';

  @override
  String get passphraseRequired => 'Please enter the share passphrase';

  @override
  String get passphraseMismatch => 'Passphrases do not match';

  @override
  String get encryptBeforeCopyTitle => 'Encrypt Before Copying';

  @override
  String get encryptBeforeCopyMessage =>
      'Set a share passphrase first. Only someone with the same passphrase can import this content.';

  @override
  String encryptedProtocolCopied(Object protocol) {
    return 'Encrypted $protocol config copied';
  }

  @override
  String get encryptedNodeCopied => 'Encrypted node copied';

  @override
  String encryptedCopyFailed(Object error) {
    return 'Failed to copy encrypted content: $error';
  }

  @override
  String get vpnDiagnosticsTitle => 'VPN Diagnostics';

  @override
  String get session => 'Connection Time';

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
  String get currentEgressIp => 'Exit IP';

  @override
  String get vpnExcludedAppsTitle => 'Apps bypassing VPN';

  @override
  String vpnExcludedAppsDescription(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count apps are currently excluded from Android VPN coverage and use the local network directly.',
      one:
          '1 app is currently excluded from Android VPN coverage and uses the local network directly.',
      zero: 'No apps are currently excluded from Android VPN coverage.',
    );
    return '$_temp0';
  }

  @override
  String vpnExcludedAppsMore(int count) {
    return '+$count more';
  }

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
  String get egressProbeBusy => 'Checking egress...';

  @override
  String egressLastSeen(Object ip) {
    return '$ip (last seen)';
  }

  @override
  String get egressProbeStillRoutingHint =>
      'VPN is still forwarding traffic; the egress probe just hasn\'t reconfirmed yet.';

  @override
  String get latestRoute => 'Latest Route Match';

  @override
  String get directRoute => 'Direct';

  @override
  String proxyRoute(Object tag) {
    return 'Proxy · $tag';
  }

  @override
  String get recentRoutingDecisions => 'Recent Routing Decisions';

  @override
  String get noRoutingDecisionsYet =>
      'No routing decisions yet. Browse a few websites, then refresh this page.';

  @override
  String get editRoutingRules => 'Edit Routing Rules';

  @override
  String get routingRulesHelp =>
      'In split mode you can toggle: LAN direct, CN domains direct, CN IPs direct. Below you can also pick proxied or direct apps and customise domains / CIDRs. Global mode only keeps LAN and custom rules.';

  @override
  String get dnsMode => 'DNS Mode';

  @override
  String get cnOptimizedDns => 'regional optimized DNS';

  @override
  String get strictProxyDns => 'Strict proxy DNS';

  @override
  String get systemDns => 'System DNS';

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
