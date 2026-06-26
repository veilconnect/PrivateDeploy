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

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @copyProtocolLink.
  ///
  /// In en, this message translates to:
  /// **'Copy Encrypted {protocol} Config'**
  String copyProtocolLink(Object protocol);

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

  /// No description provided for @more.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get more;

  /// No description provided for @automatic.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get automatic;

  /// No description provided for @cloudApiKey.
  ///
  /// In en, this message translates to:
  /// **'Cloud API Key'**
  String get cloudApiKey;

  /// No description provided for @cloudAccess.
  ///
  /// In en, this message translates to:
  /// **'Cloud Access'**
  String get cloudAccess;

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

  /// No description provided for @failedToSaveCloudAccess.
  ///
  /// In en, this message translates to:
  /// **'Failed to save cloud access'**
  String get failedToSaveCloudAccess;

  /// No description provided for @apiKeySavedAndVerified.
  ///
  /// In en, this message translates to:
  /// **'API key saved and verified'**
  String get apiKeySavedAndVerified;

  /// No description provided for @cloudAccessSavedAndVerified.
  ///
  /// In en, this message translates to:
  /// **'Cloud access saved and verified'**
  String get cloudAccessSavedAndVerified;

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

  /// No description provided for @deployToSshServer.
  ///
  /// In en, this message translates to:
  /// **'Deploy to {target}'**
  String deployToSshServer(Object target);

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

  /// No description provided for @vpnConflictMessageLocalized.
  ///
  /// In en, this message translates to:
  /// **'VPN permission was revoked or another VPN app/system VPN interrupted this connection. Disable the other VPN and try again.'**
  String get vpnConflictMessageLocalized;

  /// No description provided for @vpnPermissionDeniedMessageLocalized.
  ///
  /// In en, this message translates to:
  /// **'VPN permission was not granted. Allow VPN access and try again.'**
  String get vpnPermissionDeniedMessageLocalized;

  /// No description provided for @egressProbeFailureMessageLocalized.
  ///
  /// In en, this message translates to:
  /// **'Could not reach public IP probe endpoints through the current VPN route. Recent routing decisions below may still be valid.'**
  String get egressProbeFailureMessageLocalized;

  /// No description provided for @startupConnectivityFailureMessageLocalized.
  ///
  /// In en, this message translates to:
  /// **'VPN tunnel started, but traffic could not reach public IP probe endpoints through the selected node. The node may be unreachable or misconfigured.'**
  String get startupConnectivityFailureMessageLocalized;

  /// No description provided for @startupProbeInconclusiveMessageLocalized.
  ///
  /// In en, this message translates to:
  /// **'VPN connected, but Android could not confirm the public IP during startup. Traffic may still be available.'**
  String get startupProbeInconclusiveMessageLocalized;

  /// No description provided for @tunnelUpstreamDegradedMessageLocalized.
  ///
  /// In en, this message translates to:
  /// **'Tunnel is up, but this node\'s upstream can\'t be reached from your current network. Try Wi-Fi, switching to a different node, or enabling your Cloudflare Worker endpoint.'**
  String get tunnelUpstreamDegradedMessageLocalized;

  /// No description provided for @tunnelDirectRouteDegradedMessageLocalized.
  ///
  /// In en, this message translates to:
  /// **'Tunnel is up and the upstream node responds, but the direct-route path (used for domestic sites) is still settling. Some traffic may stall for up to a minute — common right after switching between Wi-Fi and cellular.'**
  String get tunnelDirectRouteDegradedMessageLocalized;

  /// No description provided for @cdnGuidanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Current network cannot reach this node'**
  String get cdnGuidanceTitle;

  /// No description provided for @cdnGuidanceBody.
  ///
  /// In en, this message translates to:
  /// **'Every attempt to reach the configured node failed on the current network. Set up CDN acceleration to use a Cloudflare Worker endpoint you control.'**
  String get cdnGuidanceBody;

  /// No description provided for @cdnGuidanceConfigure.
  ///
  /// In en, this message translates to:
  /// **'Set up CDN acceleration'**
  String get cdnGuidanceConfigure;

  /// No description provided for @cdnGuidanceDismiss.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get cdnGuidanceDismiss;

  /// No description provided for @cdnGuidanceTitleDeployed.
  ///
  /// In en, this message translates to:
  /// **'CDN acceleration is on, but this location still can\'t connect'**
  String get cdnGuidanceTitleDeployed;

  /// No description provided for @cdnGuidanceBodyDeployed.
  ///
  /// In en, this message translates to:
  /// **'The Worker is deployed, but the CDN path still can\'t reach the node. The node itself may be offline, the Worker→VPS link may be down, or the current network may not reach the Worker endpoint. Try switching to a different node, or re-deploy the Worker from CDN settings.'**
  String get cdnGuidanceBodyDeployed;

  /// No description provided for @cdnGuidanceActionSwitchNode.
  ///
  /// In en, this message translates to:
  /// **'Switch node'**
  String get cdnGuidanceActionSwitchNode;

  /// No description provided for @cdnGuidanceActionRedeploy.
  ///
  /// In en, this message translates to:
  /// **'Re-deploy Worker'**
  String get cdnGuidanceActionRedeploy;

  /// No description provided for @cdnGuidanceHowItWorksLink.
  ///
  /// In en, this message translates to:
  /// **'How this works'**
  String get cdnGuidanceHowItWorksLink;

  /// No description provided for @cdnGuidanceHowItWorksTitle.
  ///
  /// In en, this message translates to:
  /// **'How CDN acceleration works'**
  String get cdnGuidanceHowItWorksTitle;

  /// No description provided for @cdnGuidanceHowItWorksBody.
  ///
  /// In en, this message translates to:
  /// **'Some networks cannot reach a VPS address directly, so the tunnel can be established but traffic does not flow.\n\nCDN acceleration lets the client connect to a Cloudflare Worker endpoint first; the Worker forwards encrypted bytes to your VPS relay.\n\nIt runs in your own Cloudflare account. The relay does not store your VLESS credentials or inspect destination content.'**
  String get cdnGuidanceHowItWorksBody;

  /// No description provided for @cdnGuidanceHowItWorksClose.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get cdnGuidanceHowItWorksClose;

  /// No description provided for @cellularCarrierSynBlockMessageLocalized.
  ///
  /// In en, this message translates to:
  /// **'Current network cannot reach the configured node directly. Enable CDN acceleration in settings to use your Cloudflare Worker endpoint.'**
  String get cellularCarrierSynBlockMessageLocalized;

  /// No description provided for @cellularHelpTitle.
  ///
  /// In en, this message translates to:
  /// **'Cellular network issues'**
  String get cellularHelpTitle;

  /// No description provided for @cellularHelpAction.
  ///
  /// In en, this message translates to:
  /// **'Why?'**
  String get cellularHelpAction;

  /// No description provided for @help.
  ///
  /// In en, this message translates to:
  /// **'Help'**
  String get help;

  /// No description provided for @cdnAccelerationTitle.
  ///
  /// In en, this message translates to:
  /// **'CDN acceleration'**
  String get cdnAccelerationTitle;

  /// No description provided for @cdnAccelerationSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Optional: route through Cloudflare for cellular'**
  String get cdnAccelerationSubtitle;

  /// No description provided for @nextStep.
  ///
  /// In en, this message translates to:
  /// **'Next step'**
  String get nextStep;

  /// No description provided for @connection.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connection;

  /// No description provided for @connected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// No description provided for @connectedDegraded.
  ///
  /// In en, this message translates to:
  /// **'Connected · upstream blocked'**
  String get connectedDegraded;

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
  /// **'Node is still preparing connection details'**
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

  /// No description provided for @retryConnect.
  ///
  /// In en, this message translates to:
  /// **'Retry connect'**
  String get retryConnect;

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

  /// No description provided for @connectionDetails.
  ///
  /// In en, this message translates to:
  /// **'Connection details'**
  String get connectionDetails;

  /// No description provided for @cloudNodes.
  ///
  /// In en, this message translates to:
  /// **'Cloud Routes'**
  String get cloudNodes;

  /// No description provided for @availableRoutes.
  ///
  /// In en, this message translates to:
  /// **'Available Routes'**
  String get availableRoutes;

  /// No description provided for @cloudAccessNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Cloud access has not been added yet'**
  String get cloudAccessNotConfigured;

  /// No description provided for @setCloudProviderApiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Add cloud API access to list routes and create new ones on this device.'**
  String get setCloudProviderApiKeyHint;

  /// No description provided for @setApiKey.
  ///
  /// In en, this message translates to:
  /// **'Set API Key'**
  String get setApiKey;

  /// No description provided for @setCloudAccess.
  ///
  /// In en, this message translates to:
  /// **'Set Cloud Access'**
  String get setCloudAccess;

  /// No description provided for @setSshAccess.
  ///
  /// In en, this message translates to:
  /// **'Set SSH Access'**
  String get setSshAccess;

  /// No description provided for @setSshAccessHint.
  ///
  /// In en, this message translates to:
  /// **'Save the SSH server host, username, and password so this device can deploy directly.'**
  String get setSshAccessHint;

  /// No description provided for @sshDeployUsesSavedAccess.
  ///
  /// In en, this message translates to:
  /// **'This route will deploy through the saved SSH access: {target}'**
  String sshDeployUsesSavedAccess(Object target);

  /// No description provided for @benchmarkAll.
  ///
  /// In en, this message translates to:
  /// **'Measure All'**
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
  /// **'Create one cloud route, then connect from this device.'**
  String get deployFirstNodeHint;

  /// No description provided for @deployNode.
  ///
  /// In en, this message translates to:
  /// **'Create Route'**
  String get deployNode;

  /// No description provided for @manualProfilesDesc.
  ///
  /// In en, this message translates to:
  /// **'Routes saved only on this device'**
  String get manualProfilesDesc;

  /// No description provided for @activeNode.
  ///
  /// In en, this message translates to:
  /// **'Current Route'**
  String get activeNode;

  /// No description provided for @useAndConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get useAndConnect;

  /// No description provided for @useAndSwitch.
  ///
  /// In en, this message translates to:
  /// **'Switch Here'**
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

  /// No description provided for @protocol.
  ///
  /// In en, this message translates to:
  /// **'Protocol'**
  String get protocol;

  /// No description provided for @chooseProtocolForNode.
  ///
  /// In en, this message translates to:
  /// **'Choose protocol for {label}'**
  String chooseProtocolForNode(Object label);

  /// No description provided for @protocolAutomaticHint.
  ///
  /// In en, this message translates to:
  /// **'Follow the latest benchmark or fastest available endpoint automatically.'**
  String get protocolAutomaticHint;

  /// No description provided for @protocolSaved.
  ///
  /// In en, this message translates to:
  /// **'{label} will use {protocol} next time it connects.'**
  String protocolSaved(Object label, Object protocol);

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
  /// **'In Use'**
  String get inUse;

  /// No description provided for @selectedRoute.
  ///
  /// In en, this message translates to:
  /// **'Selected'**
  String get selectedRoute;

  /// No description provided for @saved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get saved;

  /// No description provided for @nodeDetails.
  ///
  /// In en, this message translates to:
  /// **'Node Details'**
  String get nodeDetails;

  /// No description provided for @repairNode.
  ///
  /// In en, this message translates to:
  /// **'Repair / Redeploy'**
  String get repairNode;

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

  /// No description provided for @repairNodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Repair / Redeploy Node'**
  String get repairNodeTitle;

  /// No description provided for @repairNodeConfirm.
  ///
  /// In en, this message translates to:
  /// **'Repair \"{label}\"?\n\nSSH nodes will redeploy on the same server. Cloud provider nodes will create a same-region replacement and keep the old node until you delete it.'**
  String repairNodeConfirm(Object label);

  /// No description provided for @nodeRepairCompleted.
  ///
  /// In en, this message translates to:
  /// **'Node repair completed'**
  String get nodeRepairCompleted;

  /// No description provided for @nodeRedeployStarted.
  ///
  /// In en, this message translates to:
  /// **'Replacement node is deploying. The old node was kept.'**
  String get nodeRedeployStarted;

  /// No description provided for @nodeRepairCleanupNeeded.
  ///
  /// In en, this message translates to:
  /// **'Node repair completed, but local cleanup needs attention'**
  String get nodeRepairCleanupNeeded;

  /// No description provided for @failedToRepair.
  ///
  /// In en, this message translates to:
  /// **'Failed to repair'**
  String get failedToRepair;

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

  /// No description provided for @failedToConnectVpn.
  ///
  /// In en, this message translates to:
  /// **'Failed to connect VPN'**
  String get failedToConnectVpn;

  /// No description provided for @failedToSwitchActiveVpnNode.
  ///
  /// In en, this message translates to:
  /// **'Failed to switch active VPN node'**
  String get failedToSwitchActiveVpnNode;

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
  /// **'Add cloud API access or SSH access so this device can list routes, deploy new ones, and reconnect later.'**
  String get workspaceGuideSetupMessage;

  /// No description provided for @workspaceGuideDeployTitle.
  ///
  /// In en, this message translates to:
  /// **'Prepare your first route'**
  String get workspaceGuideDeployTitle;

  /// No description provided for @workspaceGuideDeployMessage.
  ///
  /// In en, this message translates to:
  /// **'Start with one cloud route, or import an existing profile if you already have one.'**
  String get workspaceGuideDeployMessage;

  /// No description provided for @workspaceGuideChooseTitle.
  ///
  /// In en, this message translates to:
  /// **'Ready to connect'**
  String get workspaceGuideChooseTitle;

  /// No description provided for @workspaceGuideChooseMessage.
  ///
  /// In en, this message translates to:
  /// **'Tap Connect to pick the fastest ready route automatically, or choose one below first.'**
  String get workspaceGuideChooseMessage;

  /// No description provided for @workspaceGuideSyncTitle.
  ///
  /// In en, this message translates to:
  /// **'Routes are still getting ready'**
  String get workspaceGuideSyncTitle;

  /// No description provided for @workspaceGuideSyncMessage.
  ///
  /// In en, this message translates to:
  /// **'These routes are visible, but this device is still waiting for connection details. Refresh, or connect after they finish preparing.'**
  String get workspaceGuideSyncMessage;

  /// No description provided for @workspaceStepAccess.
  ///
  /// In en, this message translates to:
  /// **'Add access'**
  String get workspaceStepAccess;

  /// No description provided for @workspaceStepRoute.
  ///
  /// In en, this message translates to:
  /// **'Prepare route'**
  String get workspaceStepRoute;

  /// No description provided for @workspaceStepConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get workspaceStepConnect;

  /// No description provided for @workspaceStepDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get workspaceStepDone;

  /// No description provided for @workspaceStepCurrent.
  ///
  /// In en, this message translates to:
  /// **'Now'**
  String get workspaceStepCurrent;

  /// No description provided for @workspaceStepUpcoming.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get workspaceStepUpcoming;

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

  /// No description provided for @deployCdnWorkerAfterCreate.
  ///
  /// In en, this message translates to:
  /// **'Deploy CDN Worker after the node is ready'**
  String get deployCdnWorkerAfterCreate;

  /// No description provided for @deployCdnWorkerAfterCreateHint.
  ///
  /// In en, this message translates to:
  /// **'Auto-publishes a Cloudflare Worker bound to this node\'s relay port. You can always deploy or replace it later under Settings → CDN.'**
  String get deployCdnWorkerAfterCreateHint;

  /// No description provided for @cdnAutoDeployTimedOut.
  ///
  /// In en, this message translates to:
  /// **'Node created, but didn\'t see a relay port within 10 min — deploy the CDN Worker manually under Settings → CDN.'**
  String get cdnAutoDeployTimedOut;

  /// No description provided for @cdnAutoDeployDone.
  ///
  /// In en, this message translates to:
  /// **'CDN Worker deployed for {node}'**
  String cdnAutoDeployDone(Object node);

  /// No description provided for @cdnAutoDeployFailed.
  ///
  /// In en, this message translates to:
  /// **'Node created but CDN Worker deploy failed — retry from Settings → CDN.'**
  String get cdnAutoDeployFailed;

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
  /// **'Measure All Routes'**
  String get benchmarkAllNodesTitle;

  /// No description provided for @benchmarkAllNodesConfirm.
  ///
  /// In en, this message translates to:
  /// **'This check will temporarily disconnect your current VPN connection, test each ready cloud route with a real download sample, and then restore your previous connection.\n\nContinue?'**
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

  /// No description provided for @accountStatusLockedTitle.
  ///
  /// In en, this message translates to:
  /// **'Provider account is locked'**
  String get accountStatusLockedTitle;

  /// No description provided for @accountStatusLockedHint.
  ///
  /// In en, this message translates to:
  /// **'New deployments are disabled until the upstream account is restored. Open the provider console to resolve the lock, then reopen this dialog.'**
  String get accountStatusLockedHint;

  /// No description provided for @accountStatusLockedSoftHint.
  ///
  /// In en, this message translates to:
  /// **'Deployments may still succeed by reusing an existing configuration, but no new constrained resources can be created until you free up headroom in the provider console.'**
  String get accountStatusLockedSoftHint;

  /// No description provided for @accountStatusWarningTitle.
  ///
  /// In en, this message translates to:
  /// **'Provider account warning'**
  String get accountStatusWarningTitle;

  /// No description provided for @accountStatusWarningHint.
  ///
  /// In en, this message translates to:
  /// **'Deployments are still permitted, but the provider has flagged the account. Review the message in the provider console.'**
  String get accountStatusWarningHint;

  /// No description provided for @deployNodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Create Route'**
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

  /// No description provided for @regionUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Unreachable'**
  String get regionUnreachable;

  /// No description provided for @regionProbing.
  ///
  /// In en, this message translates to:
  /// **'Testing region reachability…'**
  String get regionProbing;

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
  /// **'Import Encrypted Config'**
  String get importFromUrl;

  /// No description provided for @profileName.
  ///
  /// In en, this message translates to:
  /// **'Profile Name'**
  String get profileName;

  /// No description provided for @optionalProfileNameHint.
  ///
  /// In en, this message translates to:
  /// **'Optional shared profile name'**
  String get optionalProfileNameHint;

  /// No description provided for @egMySubscription.
  ///
  /// In en, this message translates to:
  /// **'e.g. My Subscription'**
  String get egMySubscription;

  /// No description provided for @urlOrProxyLinks.
  ///
  /// In en, this message translates to:
  /// **'Subscription URL or Proxy Links'**
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
  /// **'Please enter a subscription URL or proxy links'**
  String get pleaseEnterUrlOrLinks;

  /// No description provided for @enterHttpUrlOrLinks.
  ///
  /// In en, this message translates to:
  /// **'Enter a subscription URL or proxy links (https://, ss://, vless://, etc.)'**
  String get enterHttpUrlOrLinks;

  /// No description provided for @importEncryptedProfile.
  ///
  /// In en, this message translates to:
  /// **'Import Encrypted Config'**
  String get importEncryptedProfile;

  /// No description provided for @encryptedConfig.
  ///
  /// In en, this message translates to:
  /// **'Encrypted Config'**
  String get encryptedConfig;

  /// No description provided for @pasteEncryptedConfigHint.
  ///
  /// In en, this message translates to:
  /// **'Paste encrypted content copied from PrivateDeploy...'**
  String get pasteEncryptedConfigHint;

  /// No description provided for @pleasePasteEncryptedConfig.
  ///
  /// In en, this message translates to:
  /// **'Please paste encrypted config content'**
  String get pleasePasteEncryptedConfig;

  /// No description provided for @enterEncryptedConfig.
  ///
  /// In en, this message translates to:
  /// **'Paste encrypted content copied from PrivateDeploy'**
  String get enterEncryptedConfig;

  /// No description provided for @createProfile.
  ///
  /// In en, this message translates to:
  /// **'Create Local Config'**
  String get createProfile;

  /// No description provided for @egMyVpnConfig.
  ///
  /// In en, this message translates to:
  /// **'e.g. My JSON Config'**
  String get egMyVpnConfig;

  /// No description provided for @config.
  ///
  /// In en, this message translates to:
  /// **'sing-box JSON'**
  String get config;

  /// No description provided for @pasteProxyLinksOrJson.
  ///
  /// In en, this message translates to:
  /// **'Paste sing-box JSON...'**
  String get pasteProxyLinksOrJson;

  /// No description provided for @pleaseEnterProfileName.
  ///
  /// In en, this message translates to:
  /// **'Please enter a profile name'**
  String get pleaseEnterProfileName;

  /// No description provided for @pleasePasteConfig.
  ///
  /// In en, this message translates to:
  /// **'Please paste sing-box JSON'**
  String get pleasePasteConfig;

  /// No description provided for @renameProfile.
  ///
  /// In en, this message translates to:
  /// **'Rename Profile'**
  String get renameProfile;

  /// No description provided for @manualProfiles.
  ///
  /// In en, this message translates to:
  /// **'Saved Profiles'**
  String get manualProfiles;

  /// No description provided for @createdAt.
  ///
  /// In en, this message translates to:
  /// **'Created: {date}'**
  String createdAt(Object date);

  /// No description provided for @viewEditConfig.
  ///
  /// In en, this message translates to:
  /// **'Open Config'**
  String get viewEditConfig;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @deployCloudNode.
  ///
  /// In en, this message translates to:
  /// **'Create cloud route'**
  String get deployCloudNode;

  /// No description provided for @importProfile.
  ///
  /// In en, this message translates to:
  /// **'Import Encrypted Config'**
  String get importProfile;

  /// No description provided for @createProfileTooltip.
  ///
  /// In en, this message translates to:
  /// **'Create Local Config'**
  String get createProfileTooltip;

  /// No description provided for @copyAllLinks.
  ///
  /// In en, this message translates to:
  /// **'Copy Encrypted Node'**
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

  /// No description provided for @encryptedImportFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to import encrypted config: {error}'**
  String encryptedImportFailed(Object error);

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

  /// No description provided for @invalidConfigNotJsonObject.
  ///
  /// In en, this message translates to:
  /// **'Invalid config: not a JSON object'**
  String get invalidConfigNotJsonObject;

  /// No description provided for @invalidConfigMissingOutbounds.
  ///
  /// In en, this message translates to:
  /// **'Invalid config: missing or empty \"outbounds\" section'**
  String get invalidConfigMissingOutbounds;

  /// No description provided for @invalidConfigNotJson.
  ///
  /// In en, this message translates to:
  /// **'Invalid config: not valid JSON'**
  String get invalidConfigNotJson;

  /// No description provided for @invalidConfigGeneric.
  ///
  /// In en, this message translates to:
  /// **'Invalid config: {error}'**
  String invalidConfigGeneric(Object error);

  /// No description provided for @apiKeyConfiguredMask.
  ///
  /// In en, this message translates to:
  /// **'•••• ({length} chars)'**
  String apiKeyConfiguredMask(Object length);

  /// No description provided for @vpnRouteDecisionProxy.
  ///
  /// In en, this message translates to:
  /// **'PROXY'**
  String get vpnRouteDecisionProxy;

  /// No description provided for @vpnRouteDecisionDirect.
  ///
  /// In en, this message translates to:
  /// **'DIRECT'**
  String get vpnRouteDecisionDirect;

  /// No description provided for @vpnRouteDecisionDns.
  ///
  /// In en, this message translates to:
  /// **'DNS'**
  String get vpnRouteDecisionDns;

  /// No description provided for @vpnStatusConnected.
  ///
  /// In en, this message translates to:
  /// **'CONNECTED'**
  String get vpnStatusConnected;

  /// No description provided for @vpnStatusConnecting.
  ///
  /// In en, this message translates to:
  /// **'CONNECTING'**
  String get vpnStatusConnecting;

  /// No description provided for @vpnStatusDisconnecting.
  ///
  /// In en, this message translates to:
  /// **'DISCONNECTING'**
  String get vpnStatusDisconnecting;

  /// No description provided for @vpnStatusDisconnected.
  ///
  /// In en, this message translates to:
  /// **'DISCONNECTED'**
  String get vpnStatusDisconnected;

  /// No description provided for @routingSummaryGlobal.
  ///
  /// In en, this message translates to:
  /// **'All traffic via VPN, LAN bypassed · {dns}'**
  String routingSummaryGlobal(Object dns);

  /// No description provided for @routingSummaryGlobalWithCustom.
  ///
  /// In en, this message translates to:
  /// **'All traffic via VPN, LAN bypassed, {count} custom rule(s) · {dns}'**
  String routingSummaryGlobalWithCustom(Object count, Object dns);

  /// No description provided for @routingSummaryNoBuiltins.
  ///
  /// In en, this message translates to:
  /// **'No built-in rules enabled'**
  String get routingSummaryNoBuiltins;

  /// No description provided for @routingSummaryWithCustom.
  ///
  /// In en, this message translates to:
  /// **'{builtins} · {count} custom rule(s)'**
  String routingSummaryWithCustom(Object builtins, Object count);

  /// No description provided for @routingTagLanDirect.
  ///
  /// In en, this message translates to:
  /// **'LAN direct'**
  String get routingTagLanDirect;

  /// No description provided for @routingTagCnAppsDirect.
  ///
  /// In en, this message translates to:
  /// **'Regional apps direct'**
  String get routingTagCnAppsDirect;

  /// No description provided for @routingTagCnDomainsDirect.
  ///
  /// In en, this message translates to:
  /// **'Regional domains direct'**
  String get routingTagCnDomainsDirect;

  /// No description provided for @routingTagCnIpsDirect.
  ///
  /// In en, this message translates to:
  /// **'Regional IPs direct'**
  String get routingTagCnIpsDirect;

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
  /// **'Cloud'**
  String get server;

  /// No description provided for @standaloneCloudAccess.
  ///
  /// In en, this message translates to:
  /// **'Cloud Access'**
  String get standaloneCloudAccess;

  /// No description provided for @standaloneCloudAccessDesc.
  ///
  /// In en, this message translates to:
  /// **'This device directly calls the {provider} API'**
  String standaloneCloudAccessDesc(Object provider);

  /// No description provided for @standaloneSshAccessDesc.
  ///
  /// In en, this message translates to:
  /// **'This device deploys directly over SSH'**
  String get standaloneSshAccessDesc;

  /// No description provided for @cloudProvider.
  ///
  /// In en, this message translates to:
  /// **'Cloud Service'**
  String get cloudProvider;

  /// No description provided for @cloudProviderDirect.
  ///
  /// In en, this message translates to:
  /// **'{name} · direct access'**
  String cloudProviderDirect(Object name);

  /// No description provided for @chooseCloudProviderHint.
  ///
  /// In en, this message translates to:
  /// **'Choose a cloud service or SSH when you add access.'**
  String get chooseCloudProviderHint;

  /// No description provided for @sshAccess.
  ///
  /// In en, this message translates to:
  /// **'SSH Access'**
  String get sshAccess;

  /// No description provided for @sshHost.
  ///
  /// In en, this message translates to:
  /// **'SSH Host'**
  String get sshHost;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @sshPassword.
  ///
  /// In en, this message translates to:
  /// **'SSH Password'**
  String get sshPassword;

  /// No description provided for @sensitiveData.
  ///
  /// In en, this message translates to:
  /// **'Security & Backup'**
  String get sensitiveData;

  /// No description provided for @sensitiveDataDesc.
  ///
  /// In en, this message translates to:
  /// **'Saved cloud access stays in device secure storage. Backup export and restore can expose secrets, so rotate or replace credentials if a backup is shared.'**
  String get sensitiveDataDesc;

  /// No description provided for @copyCloudBackup.
  ///
  /// In en, this message translates to:
  /// **'Export Encrypted Cloud Backup'**
  String get copyCloudBackup;

  /// No description provided for @copyCloudBackupDesc.
  ///
  /// In en, this message translates to:
  /// **'Review the summary first, then encrypt and copy a cloud backup with your saved access and cloud route records.'**
  String get copyCloudBackupDesc;

  /// No description provided for @restoreCloudBackup.
  ///
  /// In en, this message translates to:
  /// **'Import Encrypted Cloud Backup'**
  String get restoreCloudBackup;

  /// No description provided for @restoreCloudBackupDesc.
  ///
  /// In en, this message translates to:
  /// **'Paste encrypted cloud backup content from PrivateDeploy to restore saved access and cloud route records.'**
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
  /// **'LAN direct · regional apps direct · regional domains direct · regional IPs direct'**
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
  /// **'Removes saved access and local node cache'**
  String get clearLocalCloudDataDesc;

  /// No description provided for @clearLocalCloudDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear Local Cloud Data?'**
  String get clearLocalCloudDataTitle;

  /// No description provided for @clearLocalCloudDataConfirm.
  ///
  /// In en, this message translates to:
  /// **'This removes the saved {provider} access and cached cloud node records from this device only. It does not delete any cloud instances.'**
  String clearLocalCloudDataConfirm(Object provider);

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
  /// **'Encrypted cloud backup text is visible below. Only someone with the same share passphrase can import it.'**
  String get backupSensitiveWarning;

  /// No description provided for @backupClipboardWarning.
  ///
  /// In en, this message translates to:
  /// **'Encrypted cloud backup copied to your clipboard. Even if you share it through chat apps, the recipient still needs the share passphrase.'**
  String get backupClipboardWarning;

  /// No description provided for @backupReviewWarning.
  ///
  /// In en, this message translates to:
  /// **'Review the backup summary below first. Copying will require a share passphrase and the clipboard will never contain raw backup JSON.'**
  String get backupReviewWarning;

  /// No description provided for @copySensitiveBackup.
  ///
  /// In en, this message translates to:
  /// **'Copy Encrypted Backup'**
  String get copySensitiveBackup;

  /// No description provided for @copyAgain.
  ///
  /// In en, this message translates to:
  /// **'Copy Again'**
  String get copyAgain;

  /// No description provided for @revealJson.
  ///
  /// In en, this message translates to:
  /// **'Reveal Encrypted Text'**
  String get revealJson;

  /// No description provided for @hideJson.
  ///
  /// In en, this message translates to:
  /// **'Hide Encrypted Text'**
  String get hideJson;

  /// No description provided for @copySensitiveBackupTitle.
  ///
  /// In en, this message translates to:
  /// **'Copy Encrypted Backup?'**
  String get copySensitiveBackupTitle;

  /// No description provided for @copySensitiveBackupConfirm.
  ///
  /// In en, this message translates to:
  /// **'Enter a share passphrase first. The clipboard will receive encrypted backup text instead of raw JSON.'**
  String get copySensitiveBackupConfirm;

  /// No description provided for @sensitiveBackupCopied.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup copied to clipboard'**
  String get sensitiveBackupCopied;

  /// No description provided for @revealSensitiveBackupTitle.
  ///
  /// In en, this message translates to:
  /// **'Reveal Encrypted Backup?'**
  String get revealSensitiveBackupTitle;

  /// No description provided for @revealSensitiveBackupConfirm.
  ///
  /// In en, this message translates to:
  /// **'Enter a share passphrase first. The screen will show encrypted backup text instead of raw JSON.'**
  String get revealSensitiveBackupConfirm;

  /// No description provided for @reveal.
  ///
  /// In en, this message translates to:
  /// **'Reveal'**
  String get reveal;

  /// No description provided for @restoreCloudBackupTitle.
  ///
  /// In en, this message translates to:
  /// **'Import Encrypted Cloud Backup'**
  String get restoreCloudBackupTitle;

  /// No description provided for @restoreCloudBackupDesc2.
  ///
  /// In en, this message translates to:
  /// **'Paste encrypted cloud backup content exported from this app, then enter the same share passphrase. Importing can replace your saved access and overwrite this device\'s local cloud route cache.'**
  String get restoreCloudBackupDesc2;

  /// No description provided for @pasteCloudBackupHint.
  ///
  /// In en, this message translates to:
  /// **'Paste encrypted cloud backup text here'**
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
  /// **'This will overwrite the local cloud node cache on this device. If the backup contains saved access, it will replace the currently saved credentials.'**
  String get restoreThisBackupConfirm;

  /// No description provided for @backupJsonEmpty.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup cannot be empty'**
  String get backupJsonEmpty;

  /// No description provided for @backupJsonInvalid.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup is not valid yet'**
  String get backupJsonInvalid;

  /// No description provided for @cloudBackupRestored.
  ///
  /// In en, this message translates to:
  /// **'Cloud backup restored'**
  String get cloudBackupRestored;

  /// No description provided for @sharePassphrase.
  ///
  /// In en, this message translates to:
  /// **'Share Passphrase'**
  String get sharePassphrase;

  /// No description provided for @confirmSharePassphrase.
  ///
  /// In en, this message translates to:
  /// **'Confirm Passphrase'**
  String get confirmSharePassphrase;

  /// No description provided for @passphraseRequired.
  ///
  /// In en, this message translates to:
  /// **'Please enter the share passphrase'**
  String get passphraseRequired;

  /// No description provided for @passphraseMismatch.
  ///
  /// In en, this message translates to:
  /// **'Passphrases do not match'**
  String get passphraseMismatch;

  /// No description provided for @encryptBeforeCopyTitle.
  ///
  /// In en, this message translates to:
  /// **'Encrypt Before Copying'**
  String get encryptBeforeCopyTitle;

  /// No description provided for @encryptBeforeCopyMessage.
  ///
  /// In en, this message translates to:
  /// **'Set a share passphrase first. Only someone with the same passphrase can import this content.'**
  String get encryptBeforeCopyMessage;

  /// No description provided for @encryptedProtocolCopied.
  ///
  /// In en, this message translates to:
  /// **'Encrypted {protocol} config copied'**
  String encryptedProtocolCopied(Object protocol);

  /// No description provided for @encryptedNodeCopied.
  ///
  /// In en, this message translates to:
  /// **'Encrypted node copied'**
  String get encryptedNodeCopied;

  /// No description provided for @encryptedCopyFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to copy encrypted content: {error}'**
  String encryptedCopyFailed(Object error);

  /// No description provided for @vpnDiagnosticsTitle.
  ///
  /// In en, this message translates to:
  /// **'VPN Diagnostics'**
  String get vpnDiagnosticsTitle;

  /// No description provided for @session.
  ///
  /// In en, this message translates to:
  /// **'Connection Time'**
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
  /// **'Exit IP'**
  String get currentEgressIp;

  /// No description provided for @vpnExcludedAppsTitle.
  ///
  /// In en, this message translates to:
  /// **'Apps bypassing VPN'**
  String get vpnExcludedAppsTitle;

  /// No description provided for @vpnExcludedAppsDescription.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No apps are currently excluded from Android VPN coverage.} one{1 app is currently excluded from Android VPN coverage and uses the local network directly.} other{{count} apps are currently excluded from Android VPN coverage and use the local network directly.}}'**
  String vpnExcludedAppsDescription(int count);

  /// No description provided for @vpnExcludedAppsMore.
  ///
  /// In en, this message translates to:
  /// **'+{count} more'**
  String vpnExcludedAppsMore(int count);

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

  /// No description provided for @egressProbeBusy.
  ///
  /// In en, this message translates to:
  /// **'Checking egress...'**
  String get egressProbeBusy;

  /// No description provided for @egressLastSeen.
  ///
  /// In en, this message translates to:
  /// **'{ip} (last seen)'**
  String egressLastSeen(Object ip);

  /// No description provided for @egressProbeStillRoutingHint.
  ///
  /// In en, this message translates to:
  /// **'VPN is still forwarding traffic; the egress probe just hasn\'t reconfirmed yet.'**
  String get egressProbeStillRoutingHint;

  /// No description provided for @egressViaFailover.
  ///
  /// In en, this message translates to:
  /// **'Automatically switched to {node}'**
  String egressViaFailover(Object node);

  /// No description provided for @latestRoute.
  ///
  /// In en, this message translates to:
  /// **'Latest Route Match'**
  String get latestRoute;

  /// No description provided for @directRoute.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get directRoute;

  /// No description provided for @proxyRoute.
  ///
  /// In en, this message translates to:
  /// **'Proxy · {tag}'**
  String proxyRoute(Object tag);

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
  /// **'In split mode you can toggle: LAN direct, CN domains direct, CN IPs direct. Below you can also pick proxied or direct apps and customise domains / CIDRs. Global mode only keeps LAN and custom rules.'**
  String get routingRulesHelp;

  /// No description provided for @dnsMode.
  ///
  /// In en, this message translates to:
  /// **'DNS Mode'**
  String get dnsMode;

  /// No description provided for @cnOptimizedDns.
  ///
  /// In en, this message translates to:
  /// **'Regional optimized DNS'**
  String get cnOptimizedDns;

  /// No description provided for @strictProxyDns.
  ///
  /// In en, this message translates to:
  /// **'Strict proxy DNS'**
  String get strictProxyDns;

  /// No description provided for @systemDns.
  ///
  /// In en, this message translates to:
  /// **'System DNS'**
  String get systemDns;

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
