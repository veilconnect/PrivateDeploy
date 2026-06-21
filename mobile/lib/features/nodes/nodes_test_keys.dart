import 'package:flutter/widgets.dart';

class NodesTestKeys {
  static const workspaceFab = ValueKey('nodes.workspaceFab');
  static const configureCloudAccessFab =
      ValueKey('nodes.configureCloudAccessFab');
  static const deployCloudNodeFab = ValueKey('nodes.deployCloudNodeFab');
  static const importProfileFab = ValueKey('nodes.importProfileFab');
  static const createProfileFab = ValueKey('nodes.createProfileFab');
  static const connectButton = ValueKey('nodes.connectButton');
  static const restartButton = ValueKey('nodes.restartButton');
  static const vpnNoticeCard = ValueKey('nodes.vpnNoticeCard');

  static const importProfileNameField =
      ValueKey('nodes.importProfile.nameField');
  static const importProfilePayloadField =
      ValueKey('nodes.importProfile.payloadField');
  static const importProfilePassphraseField =
      ValueKey('nodes.importProfile.passphraseField');
  static const importProfileSubmitButton =
      ValueKey('nodes.importProfile.submitButton');

  const NodesTestKeys._();
}
