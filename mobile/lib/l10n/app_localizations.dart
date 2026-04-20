import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'PrivateDeploy'**
  String get appTitle;

  /// No description provided for @workspace.
  ///
  /// In en, this message translates to:
  /// **'Workspace'**
  String get workspace;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @create.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// No description provided for @import_.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get import_;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @cloudApiKey.
  ///
  /// In en, this message translates to:
  /// **'Cloud API Key'**
  String get cloudApiKey;

  /// No description provided for @apiKey.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get apiKey;

  /// No description provided for @verifyAndSave.
  ///
  /// In en, this message translates to:
  /// **'Verify & Save'**
  String get verifyAndSave;

  /// No description provided for @verifying.
  ///
  /// In en, this message translates to:
  /// **'Verifying...'**
  String get verifying;

  /// No description provided for @failedToSaveApiKey.
  ///
  /// In en, this message translates to:
  /// **'Failed to save API key'**
  String get failedToSaveApiKey;

  /// No description provided for @apiKeySavedAndVerified.
  ///
  /// In en, this message translates to:
  /// **'API key saved and verified'**
  String get apiKeySavedAndVerified;

  /// No description provided for @notSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get notSet;

  /// No description provided for @pasteCloudProviderApiKey.
  ///
  /// In en, this message translates to:
  /// **'Paste your {provider} API key'**
  String pasteCloudProviderApiKey(Object provider);

  /// No description provided for @deployToCloudProvider.
  ///
  /// In en, this message translates to:
  /// **'Deploy to {provider}'**
  String deployToCloudProvider(Object provider);

  /// No description provided for @loadingNodes.
  ///
  /// In en, this message translates to:
  /// **'Loading nodes...'**
  String get loadingNodes;

  /// No description provided for @vpnNotice.
  ///
  /// In en, this message translates to:
  /// **'VPN notice'**
  String get vpnNotice;

  /// No description provided for @nextStep.
  ///
  /// In en, this message translates to:
  /// **'Next step'**
  String get nextStep;

  /// No description provided for @connection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get connection;

  /// No description provided for @connected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// No description provided for @connecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get connecting;

  /// No description provided for @disconnecting.
  ///
  /// In en, this message translates to:
  /// **'Disconnecting...'**
  String get disconnecting;

  /// No description provided for @disconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get disconnected;

  /// No description provided for @tapConnectHint.
  ///
  /// In en, this message translates to:
  /// **'Tap Connect to use the fastest node.'**
  String get tapConnectHint;

  /// No description provided for @waitingForCredentials.
  ///
  /// In en, this message translates to:
  /// **'Waiting for node credentials…'**
  String get waitingForCredentials;

  /// No description provided for @noNodeSelected.
  ///
  /// In en, this message translates to:
  /// **'No node selected.'**
  String get noNodeSelected;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @disconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get disconnect;

  /// No description provided for @restartVpn.
  ///
  /// In en, this message translates to:
  /// **'Restart VPN'**
  String get restartVpn;

  /// No description provided for @processingVpn.
  ///
  /// In en, this message translates to:
  /// **'Processing VPN...'**
  String get processingVpn;

  /// No description provided for @nativeVpnUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Native VPN unavailable'**
  String get nativeVpnUnavailable;

  /// No description provided for @nativeVpnUnavailableMessage.
  ///
  /// In en, this message translates to:
  /// **'This build does not include a usable native VPN runtime.'**
  String get nativeVpnUnavailableMessage;

  /// No description provided for @upStats.
  ///
  /// In en, this message translates to:
  /// **'Up {value}'**
  String upStats(Object value);

  /// No description provided for @downStats.
  ///
  /// In en, this message translates to:
  /// **'Down {value}'**
  String downStats(Object value);

  /// No description provided for @speedStats.
  ///
  /// In en, this message translates to:
  /// **'Speed {value}'**
  String speedStats(Object value);

  /// No description provided for @cloudNodes.
  ///
  /// In en, this message translates to:
  /// **'Cloud Nodes'**
  String get cloudNodes;

  /// No description provided for @cloudAccessNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Cloud access not configured'**
  String get cloudAccessNotConfigured;

  /// No description provided for @setCloudProviderApiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Set your {provider} API key to get started.'**
  String setCloudProviderApiKeyHint(Object provider);

  /// No description provided for @setApiKey.
  ///
  /// In en, this message translates to:
  /// **'Set API Key'**
  String get setApiKey;

  /// No description provided for @benchmarkAll.
  ///
  /// In en, this message translates to:
  /// **'Benchmark All'**
  String get benchmarkAll;

  /// No description provided for @failedToLoad.
  ///
  /// In en, this message translates to:
  /// **'Failed to load'**
  String get failedToLoad;

  /// No description provided for @noCloudNodesYet.
  ///
  /// In en, this message translates to:
  /// **'No cloud nodes yet'**
  String get noCloudNodesYet;

  /// No description provided for @deployFirstNodeHint.
  ///
  /// In en, this message translates to:
  /// **'Create one cloud node to start routing traffic from this device.'**
  String get deployFirstNodeHint;

  /// No description provided for @deployNode.
  ///
  /// In en, this message translates to:
  /// **'Deploy Node'**
  String get deployNode;

  /// No description provided for @manualProfilesDesc.
  ///
  /// In en, this message translates to:
  /// **'Profiles stored only on this device'**
  String get manualProfilesDesc;

  /// No description provided for @activeNode.
  ///
  /// In en, this message translates to:
  /// **'Active Node'**
  String get activeNode;

  /// No description provided for @useAndConnect.
  ///
  /// In en, this message translates to:
  /// **'Use & Connect'**
  String get useAndConnect;

  /// No description provided for @useAndSwitch.
  ///
  /// In en, this message translates to:
  /// **'Use & Switch'**
  String get useAndSwitch;

  /// No description provided for @speedTest.
  ///
  /// In en, this message translates to:
  /// **'Speed Test'**
  String get speedTest;

  /// No description provided for @retrySpeedTest.
  ///
  /// In en, this message translates to:
  /// **'Retry Speed Test'**
  String get retrySpeedTest;

  /// No description provided for @testing.
  ///
  /// In en, this message translates to:
  /// **'Testing...'**
  String get testing;

  /// No description provided for @active.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get active;

  /// No description provided for @provisioning.
  ///
  /// In en, this message translates to:
  /// **'Starting'**
  String get provisioning;

  /// No description provided for @inUse.
  ///
  /// In en, this message translates to:
  /// **'Selected'**
  String get inUse;

  /// No description provided for @nodeDetails.
  ///
  /// In en, this message translates to:
  /// **'Node Details'**
  String get nodeDetails;

  /// No description provided for @deleteNode.
  ///
  /// In en, this message translates to:
  /// **'Delete Node'**
  String get deleteNode;

  /// No description provided for @probesStat.
  ///
  /// In en, this message translates to:
  /// **'{successful}/{total} probes'**
  String probesStat(Object successful, Object total);

  /// No description provided for @msLatency.
  ///
  /// In en, this message translates to:
  /// **'{ms} ms latency'**
  String msLatency(Object ms);

  /// No description provided for @deleteNodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Node'**
  String get deleteNodeTitle;

  /// No description provided for @deleteNodeConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{label}\"?\n\nThis will destroy the server permanently.'**
  String deleteNodeConfirm(Object label);

  /// No description provided for @nodeDeleted.
  ///
  /// In en, this message translates to:
  /// **'Node deleted'**
  String get nodeDeleted;

  /// No description provided for @nodeDeletedCleanupNeeded.
  ///
  /// In en, this message translates to:
  /// **'Node deleted, but local cleanup needs attention'**
  String get nodeDeletedCleanupNeeded;

  /// No description provided for @failedToDelete.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete'**
  String get failedToDelete;

  /// No description provided for @nodeNotReady.
  ///
  /// In en, this message translates to:
  /// **'Node is not ready yet'**
  String get nodeNotReady;

  /// No description provided for @failedToActivateNode.
  ///
  /// In en, this message translates to:
  /// **'Failed to activate node'**
  String get failedToActivateNode;

  /// No description provided for @nodeReadyConnected.
  ///
  /// In en, this message translates to:
  /// **'Node is ready and connected'**
  String get nodeReadyConnected;

  /// No description provided for @failedToActivate.
  ///
  /// In en, this message translates to:
  /// **'Failed to activate'**
  String get failedToActivate;

  /// No description provided for @profileActivatedConnected.
  ///
  /// In en, this message translates to:
  /// **'Profile activated and connected'**
  String get profileActivatedConnected;

  /// No description provided for @vpnConnectedSuccess.
  ///
  /// In en, this message translates to:
  /// **'VPN connected successfully'**
  String get vpnConnectedSuccess;

  /// No description provided for @vpnDisconnectedSuccess.
  ///
  /// In en, this message translates to:
  /// **'VPN disconnected successfully'**
  String get vpnDisconnectedSuccess;

  /// No description provided for @failedToDisconnectVpn.
  ///
  /// In en, this message translates to:
  /// **'Failed to disconnect VPN'**
  String get failedToDisconnectVpn;

  /// No description provided for @vpnRestartedSuccess.
  ///
  /// In en, this message translates to:
  /// **'VPN restarted successfully'**
  String get vpnRestartedSuccess;

  /// No description provided for @vpnBusyWait.
  ///
  /// In en, this message translates to:
  /// **'VPN is busy, please wait a moment'**
  String get vpnBusyWait;

  /// No description provided for @tryingBackupNode.
  ///
  /// In en, this message translates to:
  /// **'Trying backup node {index}/{total}: {label}'**
  String tryingBackupNode(Object index, Object total, Object label);

  /// No description provided for @allNodesFailedCheckNetwork.
  ///
  /// In en, this message translates to:
  /// **'All ready nodes failed to connect. Check your network (try Wi-Fi) or refresh the node list.'**
  String get allNodesFailedCheckNetwork;

  /// No description provided for @noCredentialsHint.
  ///
  /// In en, this message translates to:
  /// **'These cloud nodes are visible, but this device does not have their connection credentials yet. Restore a cloud backup or deploy/use a node from this device first.'**
  String get noCredentialsHint;

  /// No description provided for @noNodeSelectedHint.
  ///
  /// In en, this message translates to:
  /// **'No ready node selected yet. Choose a cloud node below or create/import a profile first.'**
  String get noNodeSelectedHint;

  /// No description provided for @usingFastestNode.
  ///
  /// In en, this message translates to:
  /// **'Using recent fastest node: {label}{metric}{endpoint}. Refreshing ranking in background...'**
  String usingFastestNode(Object label, Object metric, Object endpoint);

  /// No description provided for @quickTestingNodes.
  ///
  /// In en, this message translates to:
  /// **'Quick-testing ready nodes and selecting the fastest one...'**
  String get quickTestingNodes;

  /// No description provided for @noReadyCloudNode.
  ///
  /// In en, this message translates to:
  /// **'No ready cloud node is available yet'**
  String get noReadyCloudNode;

  /// No description provided for @workspaceGuideSetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Add cloud access'**
  String get workspaceGuideSetupTitle;

  /// No description provided for @workspaceGuideSetupMessage.
  ///
  /// In en, this message translates to:
  /// **'Save your {provider} API key so this device can list nodes, deploy new ones, and reconnect later.'**
  String workspaceGuideSetupMessage(Object provider);

  /// No description provided for @workspaceGuideDeployTitle.
  ///
  /// In en, this message translates to:
  /// **'Create your first route'**
  String get workspaceGuideDeployTitle;

  /// No description provided for @workspaceGuideDeployMessage.
  ///
  /// In en, this message translates to:
  /// **'Start with one cloud node, or import an existing profile if you already have one.'**
  String get workspaceGuideDeployMessage;

  /// No description provided for @workspaceGuideChooseTitle.
  ///
  /// In en, this message translates to:
  /// **'Ready to connect'**
  String get workspaceGuideChooseTitle;

  /// No description provided for @workspaceGuideChooseMessage.
  ///
  /// In en, this message translates to:
  /// **'Tap Connect to pick the fastest ready node automatically, or choose one below first.'**
  String get workspaceGuideChooseMessage;

  /// No description provided for @workspaceGuideSyncTitle.
  ///
  /// In en, this message translates to:
  /// **'Finish node setup'**
  String get workspaceGuideSyncTitle;

  /// No description provided for @workspaceGuideSyncMessage.
  ///
  /// In en, this message translates to:
  /// **'Your nodes are visible, but this device is still waiting for connection details. Refresh, or use a node from this device once it is ready.'**
  String get workspaceGuideSyncMessage;

  /// No description provided for @latencyTestUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Latency test was unavailable.'**
  String get latencyTestUnavailable;

  /// No description provided for @usingNodeInstead.
  ///
  /// In en, this message translates to:
  /// **'{error} Using {label} instead.'**
  String usingNodeInstead(Object error, Object label);

  /// No description provided for @continue_.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continue_;

  /// No description provided for @chooseCloudNode.
  ///
  /// In en, this message translates to:
  /// **'Choose a cloud node'**
  String get chooseCloudNode;

  /// No description provided for @chooseCloudNodeDesc.
  ///
  /// In en, this message translates to:
  /// **'Connect needs one active node. Pick which cloud node to use now.'**
  String get chooseCloudNodeDesc;

  /// No description provided for @nodeDeploying.
  ///
  /// In en, this message translates to:
  /// **'Node deploying... It takes 3-5 minutes.'**
  String get nodeDeploying;

  /// No description provided for @failedToCreate.
  ///
  /// In en, this message translates to:
  /// **'Failed to create'**
  String get failedToCreate;

  /// No description provided for @nodeNotReadyForSpeedTest.
  ///
  /// In en, this message translates to:
  /// **'Node is not ready for speed testing'**
  String get nodeNotReadyForSpeedTest;

  /// No description provided for @failedToConnectSpeedTestTunnel.
  ///
  /// In en, this message translates to:
  /// **'Failed to connect speed test tunnel'**
  String get failedToConnectSpeedTestTunnel;

  /// No description provided for @noReadyNodeForTesting.
  ///
  /// In en, this message translates to:
  /// **'No ready cloud node is available for testing'**
  String get noReadyNodeForTesting;

  /// No description provided for @benchmarkAllNodesTitle.
  ///
  /// In en, this message translates to:
  /// **'Benchmark All Nodes'**
  String get benchmarkAllNodesTitle;

  /// No description provided for @benchmarkAllNodesConfirm.
  ///
  /// In en, this message translates to:
  /// **'This benchmark will temporarily disconnect your current VPN connection, test each ready cloud node with a real download sample, and then restore your previous connection.\n\nContinue?'**
  String get benchmarkAllNodesConfirm;

  /// No description provided for @startBenchmark.
  ///
  /// In en, this message translates to:
  /// **'Start Benchmark'**
  String get startBenchmark;

  /// No description provided for @benchmarkingNodes.
  ///
  /// In en, this message translates to:
  /// **'Benchmarking ready nodes with real download samples...'**
  String get benchmarkingNodes;

  /// No description provided for @benchmarkingNode.
  ///
  /// In en, this message translates to:
  /// **'Benchmarking {label} ({index}/{total})...'**
  String benchmarkingNode(Object label, Object index, Object total);

  /// No description provided for @nodeNotReadyForBenchmark.
  ///
  /// In en, this message translates to:
  /// **'Node is not ready for benchmarking'**
  String get nodeNotReadyForBenchmark;

  /// No description provided for @failedToConnectBenchmarkTunnel.
  ///
  /// In en, this message translates to:
  /// **'Failed to connect benchmark tunnel'**
  String get failedToConnectBenchmarkTunnel;

  /// No description provided for @bestBenchmark.
  ///
  /// In en, this message translates to:
  /// **'Best benchmark: {label}{metric}{endpoint}'**
  String bestBenchmark(Object label, Object metric, Object endpoint);

  /// No description provided for @restoreConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Previous connection restore failed'**
  String get restoreConnectionFailed;

  /// No description provided for @deployNodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Deploy Node'**
  String get deployNodeTitle;

  /// No description provided for @loadingRegionsPlans.
  ///
  /// In en, this message translates to:
  /// **'Loading regions and plans...'**
  String get loadingRegionsPlans;

  /// No description provided for @deploymentUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Deployment options are unavailable right now.'**
  String get deploymentUnavailable;

  /// No description provided for @retryLoading.
  ///
  /// In en, this message translates to:
  /// **'Retry Loading'**
  String get retryLoading;

  /// No description provided for @nodeNameOptional.
  ///
  /// In en, this message translates to:
  /// **'Node Name (Optional)'**
  String get nodeNameOptional;

  /// No description provided for @autoGenerateHint.
  ///
  /// In en, this message translates to:
  /// **'Auto-generate if left blank'**
  String get autoGenerateHint;

  /// No description provided for @region.
  ///
  /// In en, this message translates to:
  /// **'Region'**
  String get region;

  /// No description provided for @plan.
  ///
  /// In en, this message translates to:
  /// **'Plan'**
  String get plan;

  /// No description provided for @noPlansInRegion.
  ///
  /// In en, this message translates to:
  /// **'No supported plans are available in this region.'**
  String get noPlansInRegion;

  /// No description provided for @deploy.
  ///
  /// In en, this message translates to:
  /// **'Deploy'**
  String get deploy;

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get loading;

  /// No description provided for @selectRegionAndPlan.
  ///
  /// In en, this message translates to:
  /// **'Please select region and plan'**
  String get selectRegionAndPlan;

  /// No description provided for @planNotAvailableInRegion.
  ///
  /// In en, this message translates to:
  /// **'Selected plan is not available in the chosen region'**
  String get planNotAvailableInRegion;

  /// No description provided for @importFromUrl.
  ///
  /// In en, this message translates to:
  /// **'Import from URL'**
  String get importFromUrl;

  /// No description provided for @profileName.
  ///
  /// In en, this message translates to:
  /// **'Profile Name'**
  String get profileName;

  /// No description provided for @egMySubscription.
  ///
  /// In en, this message translates to:
  /// **'e.g. My Subscription'**
  String get egMySubscription;

  /// No description provided for @urlOrProxyLinks.
  ///
  /// In en, this message translates to:
  /// **'URL or Proxy Links'**
  String get urlOrProxyLinks;

  /// No description provided for @urlOrProxyLinksHint.
  ///
  /// In en, this message translates to:
  /// **'https://... or ss://... or vless://...'**
  String get urlOrProxyLinksHint;

  /// No description provided for @pasteFromClipboard.
  ///
  /// In en, this message translates to:
  /// **'Paste from clipboard'**
  String get pasteFromClipboard;

  /// No description provided for @pleaseEnterUrlOrLinks.
  ///
  /// In en, this message translates to:
  /// **'Please enter a URL or proxy links'**
  String get pleaseEnterUrlOrLinks;

  /// No description provided for @enterHttpUrlOrLinks.
  ///
  /// In en, this message translates to:
  /// **'Enter an http(s) URL or proxy links (ss://, vless://, etc.)'**
  String get enterHttpUrlOrLinks;

  /// No description provided for @createProfile.
  ///
  /// In en, this message translates to:
  /// **'Create Profile'**
  String get createProfile;

  /// No description provided for @egMyVpnConfig.
  ///
  /// In en, this message translates to:
  /// **'e.g. My VPN Config'**
  String get egMyVpnConfig;

  /// No description provided for @config.
  ///
  /// In en, this message translates to:
  /// **'Config'**
  String get config;

  /// No description provided for @pasteProxyLinksOrJson.
  ///
  /// In en, this message translates to:
  /// **'Paste proxy links or sing-box JSON...'**
  String get pasteProxyLinksOrJson;

  /// No description provided for @pleaseEnterProfileName.
  ///
  /// In en, this message translates to:
  /// **'Please enter a profile name'**
  String get pleaseEnterProfileName;

  /// No description provided for @pleasePasteConfig.
  ///
  /// In en, this message translates to:
  /// **'Please paste config or proxy links'**
  String get pleasePasteConfig;

  /// No description provided for @renameProfile.
  ///
  /// In en, this message translates to:
  /// **'Rename Profile'**
  String get renameProfile;

  /// No description provided for @manualProfiles.
  ///
  /// In en, this message translates to:
  /// **'Manual Profiles'**
  String get manualProfiles;

  /// No description provided for @createdAt.
  ///
  /// In en, this message translates to:
  /// **'Created: {date}'**
  String createdAt(Object date);

  /// No description provided for @viewEditConfig.
  ///
  /// In en, this message translates to:
  /// **'View / Edit Config'**
  String get viewEditConfig;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @deployCloudNode.
  ///
  /// In en, this message translates to:
  /// **'Deploy cloud node'**
  String get deployCloudNode;

  /// No description provided for @importProfile.
  ///
  /// In en, this message translates to:
  /// **'Import profile'**
  String get importProfile;

  /// No description provided for @createProfileTooltip.
  ///
  /// In en, this message translates to:
  /// **'Create profile'**
  String get createProfileTooltip;

  /// No description provided for @copyAllLinks.
  ///
  /// In en, this message translates to:
  /// **'Copy All Links'**
  String get copyAllLinks;

  /// No description provided for @nodeInfo.
  ///
  /// In en, this message translates to:
  /// **'Node Info'**
  String get nodeInfo;

  /// No description provided for @ip.
  ///
  /// In en, this message translates to:
  /// **'IP'**
  String get ip;

  /// No description provided for @ipv6.
  ///
  /// In en, this message translates to:
  /// **'IPv6'**
  String get ipv6;

  /// No description provided for @statusLabel.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get statusLabel;

  /// No description provided for @created.
  ///
  /// In en, this message translates to:
  /// **'Created'**
  String get created;

  /// No description provided for @shadowsocks.
  ///
  /// In en, this message translates to:
  /// **'Shadowsocks'**
  String get shadowsocks;

  /// No description provided for @hysteria2.
  ///
  /// In en, this message translates to:
  /// **'Hysteria2'**
  String get hysteria2;

  /// No description provided for @vlessReality.
  ///
  /// In en, this message translates to:
  /// **'VLESS-Reality'**
  String get vlessReality;

  /// No description provided for @trojan.
  ///
  /// In en, this message translates to:
  /// **'Trojan'**
  String get trojan;

  /// No description provided for @port.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get port;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @method.
  ///
  /// In en, this message translates to:
  /// **'Method'**
  String get method;

  /// No description provided for @sni.
  ///
  /// In en, this message translates to:
  /// **'SNI'**
  String get sni;

  /// No description provided for @uuid.
  ///
  /// In en, this message translates to:
  /// **'UUID'**
  String get uuid;

  /// No description provided for @publicKey.
  ///
  /// In en, this message translates to:
  /// **'Public Key'**
  String get publicKey;

  /// No description provided for @shortId.
  ///
  /// In en, this message translates to:
  /// **'Short ID'**
  String get shortId;

  /// No description provided for @labelCopied.
  ///
  /// In en, this message translates to:
  /// **'{label} copied'**
  String labelCopied(Object label);

  /// No description provided for @linksCopied.
  ///
  /// In en, this message translates to:
  /// **'{count} links copied'**
  String linksCopied(Object count);

  /// No description provided for @deleteProfile.
  ///
  /// In en, this message translates to:
  /// **'Delete Profile'**
  String get deleteProfile;

  /// No description provided for @deleteProfileConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{name}\"?'**
  String deleteProfileConfirm(Object name);

  /// No description provided for @profileDeleted.
  ///
  /// In en, this message translates to:
  /// **'Profile deleted'**
  String get profileDeleted;

  /// No description provided for @failedToDeleteProfile.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete'**
  String get failedToDeleteProfile;

  /// No description provided for @profileRenamed.
  ///
  /// In en, this message translates to:
  /// **'Profile renamed'**
  String get profileRenamed;

  /// No description provided for @failedToRename.
  ///
  /// In en, this message translates to:
  /// **'Failed to rename'**
  String get failedToRename;

  /// No description provided for @profileCreatedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Profile created successfully'**
  String get profileCreatedSuccess;

  /// No description provided for @failedToCreateProfile.
  ///
  /// In en, this message translates to:
  /// **'Failed to create profile'**
  String get failedToCreateProfile;

  /// No description provided for @unrecognizedConfigFormat.
  ///
  /// In en, this message translates to:
  /// **'Unrecognized config format'**
  String get unrecognizedConfigFormat;

  /// No description provided for @importedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Imported successfully'**
  String get importedSuccess;

  /// No description provided for @failedToImport.
  ///
  /// In en, this message translates to:
  /// **'Failed to import'**
  String get failedToImport;

  /// No description provided for @fetchingSubscription.
  ///
  /// In en, this message translates to:
  /// **'Fetching subscription...'**
  String get fetchingSubscription;

  /// No description provided for @failedToParseSubscription.
  ///
  /// In en, this message translates to:
  /// **'Failed to parse subscription'**
  String get failedToParseSubscription;

  /// No description provided for @failedToParseProxyLinks.
  ///
  /// In en, this message translates to:
  /// **'Failed to parse proxy links'**
  String get failedToParseProxyLinks;

  /// No description provided for @networkError.
  ///
  /// In en, this message translates to:
  /// **'Network error: {error}'**
  String networkError(Object error);

  /// No description provided for @unrecognizedFormat.
  ///
  /// In en, this message translates to:
  /// **'Unrecognized format. Paste proxy links (ss://, vless://, etc.) or sing-box JSON.'**
  String get unrecognizedFormat;

  /// No description provided for @profileContentSaved.
  ///
  /// In en, this message translates to:
  /// **'Profile content saved'**
  String get profileContentSaved;

  /// No description provided for @saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Save failed'**
  String get saveFailed;

  /// No description provided for @pasteSingboxJsonHint.
  ///
  /// In en, this message translates to:
  /// **'Paste sing-box JSON configuration here...'**
  String get pasteSingboxJsonHint;

  /// No description provided for @server.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get server;

  /// No description provided for @standaloneCloudAccess.
  ///
  /// In en, this message translates to:
  /// **'Standalone Cloud Access'**
  String get standaloneCloudAccess;

  /// No description provided for @standaloneCloudAccessDesc.
  ///
  /// In en, this message translates to:
  /// **'This device directly calls the Vultr API'**
  String get standaloneCloudAccessDesc;

  /// No description provided for @cloudProvider.
  ///
  /// In en, this message translates to:
  /// **'Cloud Provider'**
  String get cloudProvider;

  /// No description provided for @cloudProviderDirect.
  ///
  /// In en, this message translates to:
  /// **'{name} (direct)'**
  String cloudProviderDirect(Object name);

  /// No description provided for @sensitiveData.
  ///
  /// In en, this message translates to:
  /// **'Sensitive Data'**
  String get sensitiveData;

  /// No description provided for @sensitiveDataDesc.
  ///
  /// In en, this message translates to:
  /// **'API keys stay in device secure storage. Backup export and restore can expose secrets, so rotate keys if a backup is shared.'**
  String get sensitiveDataDesc;

  /// No description provided for @copyCloudBackup.
  ///
  /// In en, this message translates to:
  /// **'Copy Cloud Backup'**
  String get copyCloudBackup;

  /// No description provided for @copyCloudBackupDesc.
  ///
  /// In en, this message translates to:
  /// **'Review the summary first, then copy sensitive backup JSON with API key and local node records'**
  String get copyCloudBackupDesc;

  /// No description provided for @restoreCloudBackup.
  ///
  /// In en, this message translates to:
  /// **'Restore Cloud Backup'**
  String get restoreCloudBackup;

  /// No description provided for @restoreCloudBackupDesc.
  ///
  /// In en, this message translates to:
  /// **'Paste a backup JSON, validate it, then confirm restoring the API key and local nodes'**
  String get restoreCloudBackupDesc;

  /// No description provided for @app.
  ///
  /// In en, this message translates to:
  /// **'App'**
  String get app;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @usingSystemDarkTheme.
  ///
  /// In en, this message translates to:
  /// **'Using system dark theme'**
  String get usingSystemDarkTheme;

  /// No description provided for @usingSystemLightTheme.
  ///
  /// In en, this message translates to:
  /// **'Using system light theme'**
  String get usingSystemLightTheme;

  /// No description provided for @vpnStatus.
  ///
  /// In en, this message translates to:
  /// **'VPN Status'**
  String get vpnStatus;

  /// No description provided for @unavailableOnBuild.
  ///
  /// In en, this message translates to:
  /// **'Unavailable on this build'**
  String get unavailableOnBuild;

  /// No description provided for @routingMode.
  ///
  /// In en, this message translates to:
  /// **'Routing Mode'**
  String get routingMode;

  /// No description provided for @split.
  ///
  /// In en, this message translates to:
  /// **'Split'**
  String get split;

  /// No description provided for @global.
  ///
  /// In en, this message translates to:
  /// **'Global'**
  String get global;

  /// No description provided for @routingModeDesc.
  ///
  /// In en, this message translates to:
  /// **'LAN direct · CN domains direct · CN IPs direct'**
  String get routingModeDesc;

  /// No description provided for @vpnDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'VPN Diagnostics'**
  String get vpnDiagnostics;

  /// No description provided for @vpnDiagnosticsDesc.
  ///
  /// In en, this message translates to:
  /// **'Check current egress IP and recent split-routing hits'**
  String get vpnDiagnosticsDesc;

  /// No description provided for @routingRules.
  ///
  /// In en, this message translates to:
  /// **'Routing Rules'**
  String get routingRules;

  /// No description provided for @routingRulesDesc.
  ///
  /// In en, this message translates to:
  /// **'Built-in split rules + custom domains, CIDRs, and apps'**
  String get routingRulesDesc;

  /// No description provided for @routingRulesSaved.
  ///
  /// In en, this message translates to:
  /// **'Routing rules saved'**
  String get routingRulesSaved;

  /// No description provided for @routingRulesReset.
  ///
  /// In en, this message translates to:
  /// **'Routing rules reset to defaults'**
  String get routingRulesReset;

  /// No description provided for @clearLocalCloudData.
  ///
  /// In en, this message translates to:
  /// **'Clear Local Cloud Data'**
  String get clearLocalCloudData;

  /// No description provided for @clearLocalCloudDataDesc.
  ///
  /// In en, this message translates to:
  /// **'Removes saved API key and local node cache'**
  String get clearLocalCloudDataDesc;

  /// No description provided for @clearLocalCloudDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear Local Cloud Data?'**
  String get clearLocalCloudDataTitle;

  /// No description provided for @clearLocalCloudDataConfirm.
  ///
  /// In en, this message translates to:
  /// **'This removes the saved Vultr API key and cached cloud node records from this device only. It does not delete any cloud instances.'**
  String get clearLocalCloudDataConfirm;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @localCloudDataCleared.
  ///
  /// In en, this message translates to:
  /// **'Local cloud data cleared'**
  String get localCloudDataCleared;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get version;

  /// No description provided for @unavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get unavailable;

  /// No description provided for @multiProtocolTool.
  ///
  /// In en, this message translates to:
  /// **'Multi-protocol proxy deployment tool'**
  String get multiProtocolTool;

  /// No description provided for @cloudBackupReady.
  ///
  /// In en, this message translates to:
  /// **'Cloud Backup Ready'**
  String get cloudBackupReady;

  /// No description provided for @backupSensitiveWarning.
  ///
  /// In en, this message translates to:
  /// **'Sensitive backup JSON is visible below. Store it safely because it includes your Vultr API key and node credentials.'**
  String get backupSensitiveWarning;

  /// No description provided for @backupClipboardWarning.
  ///
  /// In en, this message translates to:
  /// **'Sensitive backup copied to your clipboard. Clipboard contents may be accessible to other apps until you replace them.'**
  String get backupClipboardWarning;

  /// No description provided for @backupReviewWarning.
  ///
  /// In en, this message translates to:
  /// **'Review the backup summary below before copying. The backup includes sensitive data such as your Vultr API key and node credentials.'**
  String get backupReviewWarning;

  /// No description provided for @copySensitiveBackup.
  ///
  /// In en, this message translates to:
  /// **'Copy Sensitive Backup'**
  String get copySensitiveBackup;

  /// No description provided for @copyAgain.
  ///
  /// In en, this message translates to:
  /// **'Copy Again'**
  String get copyAgain;

  /// No description provided for @revealJson.
  ///
  /// In en, this message translates to:
  /// **'Reveal JSON'**
  String get revealJson;

  /// No description provided for @hideJson.
  ///
  /// In en, this message translates to:
  /// **'Hide JSON'**
  String get hideJson;

  /// No description provided for @copySensitiveBackupTitle.
  ///
  /// In en, this message translates to:
  /// **'Copy Sensitive Backup?'**
  String get copySensitiveBackupTitle;

  /// No description provided for @copySensitiveBackupConfirm.
  ///
  /// In en, this message translates to:
  /// **'This will place the full backup JSON on the system clipboard, including the saved API key and node credentials.'**
  String get copySensitiveBackupConfirm;

  /// No description provided for @sensitiveBackupCopied.
  ///
  /// In en, this message translates to:
  /// **'Sensitive backup copied to clipboard'**
  String get sensitiveBackupCopied;

  /// No description provided for @revealSensitiveBackupTitle.
  ///
  /// In en, this message translates to:
  /// **'Reveal Sensitive Backup?'**
  String get revealSensitiveBackupTitle;

  /// No description provided for @revealSensitiveBackupConfirm.
  ///
  /// In en, this message translates to:
  /// **'This will display the full backup JSON on screen, including the saved API key and node credentials.'**
  String get revealSensitiveBackupConfirm;

  /// No description provided for @reveal.
  ///
  /// In en, this message translates to:
  /// **'Reveal'**
  String get reveal;

  /// No description provided for @restoreCloudBackupTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore Cloud Backup'**
  String get restoreCloudBackupTitle;

  /// No description provided for @restoreCloudBackupDesc2.
  ///
  /// In en, this message translates to:
  /// **'Paste a backup JSON exported from this app. Restoring can replace the saved API key and overwrite the local cloud node cache on this device.'**
  String get restoreCloudBackupDesc2;

  /// No description provided for @pasteCloudBackupHint.
  ///
  /// In en, this message translates to:
  /// **'Paste cloud backup JSON here'**
  String get pasteCloudBackupHint;

  /// No description provided for @pasteClipboard.
  ///
  /// In en, this message translates to:
  /// **'Paste Clipboard'**
  String get pasteClipboard;

  /// No description provided for @restore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restore;

  /// No description provided for @restoreThisBackupTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore This Backup?'**
  String get restoreThisBackupTitle;

  /// No description provided for @restoreThisBackupConfirm.
  ///
  /// In en, this message translates to:
  /// **'This will overwrite the local cloud node cache on this device. If the backup contains an API key, it will replace the currently saved key.'**
  String get restoreThisBackupConfirm;

  /// No description provided for @backupJsonEmpty.
  ///
  /// In en, this message translates to:
  /// **'Backup JSON cannot be empty'**
  String get backupJsonEmpty;

  /// No description provided for @backupJsonInvalid.
  ///
  /// In en, this message translates to:
  /// **'Backup JSON is not valid yet'**
  String get backupJsonInvalid;

  /// No description provided for @cloudBackupRestored.
  ///
  /// In en, this message translates to:
  /// **'Cloud backup restored'**
  String get cloudBackupRestored;

  /// No description provided for @vpnDiagnosticsTitle.
  ///
  /// In en, this message translates to:
  /// **'VPN Diagnostics'**
  String get vpnDiagnosticsTitle;

  /// No description provided for @session.
  ///
  /// In en, this message translates to:
  /// **'Session'**
  String get session;

  /// No description provided for @vpnConnectedDiag.
  ///
  /// In en, this message translates to:
  /// **'VPN connected — data below is from the active session'**
  String get vpnConnectedDiag;

  /// No description provided for @vpnConnectingDiag.
  ///
  /// In en, this message translates to:
  /// **'VPN is connecting — diagnostics may change shortly'**
  String get vpnConnectingDiag;

  /// No description provided for @vpnDisconnectingDiag.
  ///
  /// In en, this message translates to:
  /// **'VPN is disconnecting — results may be stale'**
  String get vpnDisconnectingDiag;

  /// No description provided for @vpnDisconnectedDiag.
  ///
  /// In en, this message translates to:
  /// **'VPN disconnected — showing rule hits from the last session'**
  String get vpnDisconnectedDiag;

  /// No description provided for @lastUpdated.
  ///
  /// In en, this message translates to:
  /// **'Last updated: {time}'**
  String lastUpdated(Object time);

  /// No description provided for @currentEgressIp.
  ///
  /// In en, this message translates to:
  /// **'Current Egress IP'**
  String get currentEgressIp;

  /// No description provided for @connectVpnToMeasure.
  ///
  /// In en, this message translates to:
  /// **'Connect VPN to measure current egress IP'**
  String get connectVpnToMeasure;

  /// No description provided for @refreshing.
  ///
  /// In en, this message translates to:
  /// **'Refreshing...'**
  String get refreshing;

  /// No description provided for @probeUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Probe unavailable'**
  String get probeUnavailable;

  /// No description provided for @egressProbeHelp.
  ///
  /// In en, this message translates to:
  /// **'Trying a short native probe first, then falling back only if needed.'**
  String get egressProbeHelp;

  /// No description provided for @recentRoutingDecisions.
  ///
  /// In en, this message translates to:
  /// **'Recent Routing Decisions'**
  String get recentRoutingDecisions;

  /// No description provided for @noRoutingDecisionsYet.
  ///
  /// In en, this message translates to:
  /// **'No routing decisions yet. Browse a few websites, then refresh this page.'**
  String get noRoutingDecisionsYet;

  /// No description provided for @editRoutingRules.
  ///
  /// In en, this message translates to:
  /// **'Edit Routing Rules'**
  String get editRoutingRules;

  /// No description provided for @routingRulesHelp.
  ///
  /// In en, this message translates to:
  /// **'Built-in defaults follow common split patterns: LAN direct, CN domains direct, CN IPs direct. Global mode only keeps LAN and custom rules.'**
  String get routingRulesHelp;

  /// No description provided for @lanDirectRule.
  ///
  /// In en, this message translates to:
  /// **'LAN / private networks direct'**
  String get lanDirectRule;

  /// No description provided for @cnDomainsDirectRule.
  ///
  /// In en, this message translates to:
  /// **'CN domains direct'**
  String get cnDomainsDirectRule;

  /// No description provided for @cnIpsDirectRule.
  ///
  /// In en, this message translates to:
  /// **'CN IPs direct'**
  String get cnIpsDirectRule;

  /// No description provided for @directApps.
  ///
  /// In en, this message translates to:
  /// **'Direct apps'**
  String get directApps;

  /// No description provided for @proxiedApps.
  ///
  /// In en, this message translates to:
  /// **'Proxied apps'**
  String get proxiedApps;

  /// No description provided for @perAppAndroidOnly.
  ///
  /// In en, this message translates to:
  /// **'Per-app routing is Android-only'**
  String get perAppAndroidOnly;

  /// No description provided for @appListError.
  ///
  /// In en, this message translates to:
  /// **'Could not list apps; you can still save domain and CIDR rules.'**
  String get appListError;

  /// No description provided for @customDirectDomains.
  ///
  /// In en, this message translates to:
  /// **'Custom direct domains / suffixes'**
  String get customDirectDomains;

  /// No description provided for @customDirectDomainsHint.
  ///
  /// In en, this message translates to:
  /// **'One per line, e.g.:\nexample.cn\ncorp.local'**
  String get customDirectDomainsHint;

  /// No description provided for @customProxiedDomains.
  ///
  /// In en, this message translates to:
  /// **'Custom proxied domains / suffixes'**
  String get customProxiedDomains;

  /// No description provided for @customProxiedDomainsHint.
  ///
  /// In en, this message translates to:
  /// **'One per line, e.g.:\nnetflix.com\nopenai.com'**
  String get customProxiedDomainsHint;

  /// No description provided for @customDirectCidrs.
  ///
  /// In en, this message translates to:
  /// **'Custom direct CIDRs'**
  String get customDirectCidrs;

  /// No description provided for @customDirectCidrsHint.
  ///
  /// In en, this message translates to:
  /// **'One per line, e.g.:\n10.10.0.0/16'**
  String get customDirectCidrsHint;

  /// No description provided for @customProxiedCidrs.
  ///
  /// In en, this message translates to:
  /// **'Custom proxied CIDRs'**
  String get customProxiedCidrs;

  /// No description provided for @customProxiedCidrsHint.
  ///
  /// In en, this message translates to:
  /// **'One per line, e.g.:\n203.0.113.0/24'**
  String get customProxiedCidrsHint;

  /// No description provided for @resetToDefaults.
  ///
  /// In en, this message translates to:
  /// **'Reset to defaults'**
  String get resetToDefaults;

  /// No description provided for @pickDirectApps.
  ///
  /// In en, this message translates to:
  /// **'Pick direct apps'**
  String get pickDirectApps;

  /// No description provided for @pickProxiedApps.
  ///
  /// In en, this message translates to:
  /// **'Pick proxied apps'**
  String get pickProxiedApps;

  /// No description provided for @appBothDirectProxied.
  ///
  /// In en, this message translates to:
  /// **'An app cannot be both direct and proxied'**
  String get appBothDirectProxied;

  /// No description provided for @searchApp.
  ///
  /// In en, this message translates to:
  /// **'Search App'**
  String get searchApp;

  /// No description provided for @noAppSelected.
  ///
  /// In en, this message translates to:
  /// **'No app selected'**
  String get noAppSelected;

  /// No description provided for @appCountSelected.
  ///
  /// In en, this message translates to:
  /// **'{first} and {count} more apps'**
  String appCountSelected(Object first, Object count);

  /// No description provided for @error.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get error;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
