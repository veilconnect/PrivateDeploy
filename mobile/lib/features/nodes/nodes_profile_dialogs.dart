import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/security/encrypted_share.dart';
import '../../l10n/app_localizations.dart';
import '../profiles/profile_config_normalizer.dart';
import 'nodes_config_validation.dart';
import 'nodes_dialog_models.dart';
import 'nodes_test_keys.dart';

Future<NodesImportProfileRequest?> showNodesImportProfileDialog(
  BuildContext context, {
  NodesProfileNameValidator? validateName,
}) {
  return showDialog<NodesImportProfileRequest>(
    context: context,
    builder: (context) => _NodesImportProfileDialog(validateName: validateName),
  );
}

Future<NodesCreateProfileRequest?> showNodesCreateProfileDialog(
  BuildContext context, {
  NodesProfileNameValidator? validateName,
}) {
  return showDialog<NodesCreateProfileRequest>(
    context: context,
    builder: (context) => _NodesCreateProfileDialog(validateName: validateName),
  );
}

/// Collects WireGuard connection fields via a form (no raw JSON) and returns a
/// ready-to-create profile whose config is a full-tunnel sing-box config built
/// by [buildWireguardProfileConfig]. The resulting profile appears in the node
/// list and connects like any other VPN node.
Future<NodesCreateProfileRequest?> showNodesWireguardProfileDialog(
  BuildContext context, {
  NodesProfileNameValidator? validateName,
}) {
  return showDialog<NodesCreateProfileRequest>(
    context: context,
    builder: (context) =>
        _NodesWireguardProfileDialog(validateName: validateName),
  );
}

Future<String?> showNodesRenameProfileDialog({
  required BuildContext context,
  required String initialName,
  NodesProfileNameValidator? validateName,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _NodesRenameProfileDialog(
      initialName: initialName,
      validateName: validateName,
    ),
  );
}

class _NodesImportProfileDialog extends StatefulWidget {
  final NodesProfileNameValidator? validateName;

  const _NodesImportProfileDialog({
    this.validateName,
  });

  @override
  State<_NodesImportProfileDialog> createState() =>
      _NodesImportProfileDialogState();
}

class _NodesImportProfileDialogState extends State<_NodesImportProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _payloadController;
  late final TextEditingController _nameController;
  late final TextEditingController _passphraseController;
  bool _obscurePassphrase = true;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  @override
  void initState() {
    super.initState();
    _payloadController = TextEditingController();
    _nameController = TextEditingController();
    _passphraseController = TextEditingController();
  }

  @override
  void dispose() {
    _payloadController.dispose();
    _nameController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.importEncryptedProfile),
      content: Form(
        key: _formKey,
        autovalidateMode: _autovalidate,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: NodesTestKeys.importProfileNameField,
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: l10n.profileName,
                  hintText: l10n.optionalProfileNameHint,
                  errorMaxLines: 3,
                ),
                validator: (value) {
                  final name = value?.trim() ?? '';
                  if (name.isEmpty) {
                    return null;
                  }
                  return widget.validateName?.call(name);
                },
              ),
              SizedBox(height: 16.h),
              TextFormField(
                key: NodesTestKeys.importProfilePayloadField,
                controller: _payloadController,
                decoration: InputDecoration(
                  labelText: l10n.encryptedConfig,
                  hintText: l10n.pasteEncryptedConfigHint,
                  border: const OutlineInputBorder(),
                  errorMaxLines: 4,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.paste),
                    tooltip: l10n.pasteFromClipboard,
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null && data!.text!.isNotEmpty) {
                        _payloadController.text = data.text!;
                      }
                    },
                  ),
                ),
                minLines: 4,
                maxLines: 6,
                validator: (value) {
                  final input = value?.trim() ?? '';
                  if (input.isEmpty) {
                    return l10n.pleasePasteEncryptedConfig;
                  }
                  if (!EncryptedShareCodec.looksEncrypted(input)) {
                    return l10n.enterEncryptedConfig;
                  }
                  return null;
                },
              ),
              SizedBox(height: 16.h),
              TextFormField(
                key: NodesTestKeys.importProfilePassphraseField,
                controller: _passphraseController,
                obscureText: _obscurePassphrase,
                decoration: InputDecoration(
                  labelText: l10n.sharePassphrase,
                  border: const OutlineInputBorder(),
                  errorMaxLines: 3,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassphrase
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    tooltip: l10n.sharePassphrase,
                    onPressed: () {
                      setState(() {
                        _obscurePassphrase = !_obscurePassphrase;
                      });
                    },
                  ),
                ),
                validator: (value) {
                  if ((value ?? '').trim().isEmpty) {
                    return l10n.passphraseRequired;
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          key: NodesTestKeys.importProfileSubmitButton,
          onPressed: () {
            if (!_formKey.currentState!.validate()) {
              // Once the user has hit submit and seen errors, switch to live
              // re-validation so corrections clear the errors immediately
              // instead of waiting for the next submit.
              setState(() {
                _autovalidate = AutovalidateMode.onUserInteraction;
              });
              return;
            }
            Navigator.pop(
              context,
              NodesImportProfileRequest(
                name: _nameController.text.trim(),
                payload: _payloadController.text.trim(),
                passphrase: _passphraseController.text.trim(),
              ),
            );
          },
          child: Text(l10n.import_),
        ),
      ],
    );
  }
}

class _NodesCreateProfileDialog extends StatefulWidget {
  final NodesProfileNameValidator? validateName;

  const _NodesCreateProfileDialog({
    this.validateName,
  });

  @override
  State<_NodesCreateProfileDialog> createState() =>
      _NodesCreateProfileDialogState();
}

class _NodesCreateProfileDialogState extends State<_NodesCreateProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _configController;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _configController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _configController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.createProfile),
      content: Form(
        key: _formKey,
        autovalidateMode: _autovalidate,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: l10n.profileName,
                  hintText: l10n.egMyVpnConfig,
                  errorMaxLines: 3,
                ),
                validator: (value) {
                  final name = value?.trim() ?? '';
                  if (name.isEmpty) {
                    return l10n.pleaseEnterProfileName;
                  }
                  final validationError = widget.validateName?.call(name);
                  if (validationError != null) {
                    return validationError;
                  }
                  return null;
                },
              ),
              SizedBox(height: 16.h),
              TextFormField(
                controller: _configController,
                decoration: InputDecoration(
                  labelText: l10n.config,
                  hintText: l10n.pasteSingboxJsonHint,
                  border: const OutlineInputBorder(),
                  errorMaxLines: 4,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.paste),
                    tooltip: l10n.pasteFromClipboard,
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null && data!.text!.isNotEmpty) {
                        _configController.text = data.text!;
                      }
                    },
                  ),
                ),
                maxLines: 8,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.sp,
                ),
                validator: (value) {
                  final config = value?.trim() ?? '';
                  if (config.isEmpty) {
                    return l10n.pleasePasteConfig;
                  }
                  return validateSingboxConfig(config, l10n);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) {
              setState(() {
                _autovalidate = AutovalidateMode.onUserInteraction;
              });
              return;
            }
            Navigator.pop(
              context,
              NodesCreateProfileRequest(
                name: _nameController.text.trim(),
                config: _configController.text.trim(),
              ),
            );
          },
          child: Text(l10n.create),
        ),
      ],
    );
  }
}

class _NodesRenameProfileDialog extends StatefulWidget {
  final String initialName;
  final NodesProfileNameValidator? validateName;

  const _NodesRenameProfileDialog({
    required this.initialName,
    this.validateName,
  });

  @override
  State<_NodesRenameProfileDialog> createState() =>
      _NodesRenameProfileDialogState();
}

class _NodesRenameProfileDialogState extends State<_NodesRenameProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.renameProfile),
      content: Form(
        key: _formKey,
        autovalidateMode: _autovalidate,
        child: TextFormField(
          controller: _nameController,
          decoration: InputDecoration(
            labelText: l10n.profileName,
            errorMaxLines: 3,
          ),
          validator: (value) {
            final name = value?.trim() ?? '';
            if (name.isEmpty) {
              return l10n.pleaseEnterProfileName;
            }
            final validationError = widget.validateName?.call(name);
            if (validationError != null) {
              return validationError;
            }
            return null;
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) {
              setState(() {
                _autovalidate = AutovalidateMode.onUserInteraction;
              });
              return;
            }
            Navigator.pop(context, _nameController.text.trim());
          },
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

class _NodesWireguardProfileDialog extends StatefulWidget {
  final NodesProfileNameValidator? validateName;

  const _NodesWireguardProfileDialog({this.validateName});

  @override
  State<_NodesWireguardProfileDialog> createState() =>
      _NodesWireguardProfileDialogState();
}

class _NodesWireguardProfileDialogState
    extends State<_NodesWireguardProfileDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _serverController;
  late final TextEditingController _portController;
  late final TextEditingController _privateKeyController;
  late final TextEditingController _peerPublicKeyController;
  late final TextEditingController _localAddressController;
  late final TextEditingController _preSharedKeyController;
  late final TextEditingController _mtuController;
  late final TextEditingController _keepaliveController;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: 'WireGuard');
    _serverController = TextEditingController();
    _portController = TextEditingController(text: '51820');
    _privateKeyController = TextEditingController();
    _peerPublicKeyController = TextEditingController();
    _localAddressController = TextEditingController();
    _preSharedKeyController = TextEditingController();
    _mtuController = TextEditingController();
    // wg-quick default; keeps the NAT mapping alive so an idle tunnel does not
    // silently drop (the classic "WireGuard keeps disconnecting" symptom).
    _keepaliveController = TextEditingController(text: '25');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _serverController.dispose();
    _portController.dispose();
    _privateKeyController.dispose();
    _peerPublicKeyController.dispose();
    _localAddressController.dispose();
    _preSharedKeyController.dispose();
    _mtuController.dispose();
    _keepaliveController.dispose();
    super.dispose();
  }

  String? _validateRequired(String? value, String message) {
    if ((value ?? '').trim().isEmpty) {
      return message;
    }
    return null;
  }

  String? _validatePort(String? value) {
    final port = int.tryParse((value ?? '').trim());
    if (port == null || port < 1 || port > 65535) {
      return '端口需为 1-65535 的数字 / Port must be 1-65535';
    }
    return null;
  }

  String? _validateOptionalPositiveInt(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) {
      return null;
    }
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0) {
      return '需为正整数 / Must be a positive number';
    }
    return null;
  }

  /// Keepalive accepts 0 as an explicit opt-out (the config builder honors
  /// 0 = no keepalive), unlike MTU which must stay strictly positive.
  String? _validateOptionalNonNegativeInt(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) {
      return null;
    }
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 0) {
      return '需为 0 或正整数 / Must be 0 or a positive number';
    }
    return null;
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscure = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: 12.h),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
          errorMaxLines: 3,
        ),
        validator: validator,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: const Text('添加 WireGuard 连接 / Add WireGuard'),
      content: Form(
        key: _formKey,
        autovalidateMode: _autovalidate,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(
                controller: _nameController,
                label: '名称 / Name',
                validator: (value) {
                  final name = value?.trim() ?? '';
                  if (name.isEmpty) {
                    return l10n.pleaseEnterProfileName;
                  }
                  return widget.validateName?.call(name);
                },
              ),
              _field(
                controller: _serverController,
                label: '服务器地址 / Server',
                hint: 'vpn.example.com 或 IP',
                validator: (value) => _validateRequired(
                  value,
                  '请输入服务器地址 / Server is required',
                ),
              ),
              _field(
                controller: _portController,
                label: '端口 / Server Port',
                keyboardType: TextInputType.number,
                validator: _validatePort,
              ),
              _field(
                controller: _localAddressController,
                label: '本地地址 / Local Address (CIDR)',
                hint: '10.0.0.2/32 (多个用逗号分隔)',
                validator: (value) => _validateRequired(
                  value,
                  '请输入本地地址 / Local address is required',
                ),
              ),
              _field(
                controller: _privateKeyController,
                label: '私钥 / Private Key',
                hint: 'base64',
                validator: (value) => _validateRequired(
                  value,
                  '请输入私钥 / Private key is required',
                ),
              ),
              _field(
                controller: _peerPublicKeyController,
                label: '对端公钥 / Peer Public Key',
                hint: 'base64',
                validator: (value) => _validateRequired(
                  value,
                  '请输入对端公钥 / Peer public key is required',
                ),
              ),
              _field(
                controller: _preSharedKeyController,
                label: '预共享密钥 / Pre-shared Key (可选)',
                hint: 'base64 (optional)',
              ),
              _field(
                controller: _mtuController,
                label: 'MTU (可选)',
                hint: '1408',
                keyboardType: TextInputType.number,
                validator: _validateOptionalPositiveInt,
              ),
              _field(
                controller: _keepaliveController,
                label: '保活间隔秒 / Keepalive (可选, 0=关闭)',
                hint: '25',
                keyboardType: TextInputType.number,
                validator: _validateOptionalNonNegativeInt,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        ElevatedButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) {
              setState(() {
                _autovalidate = AutovalidateMode.onUserInteraction;
              });
              return;
            }
            final keepaliveRaw = _keepaliveController.text.trim();
            final config = buildWireguardProfileConfig(
              server: _serverController.text.trim(),
              serverPort: int.parse(_portController.text.trim()),
              privateKey: _privateKeyController.text.trim(),
              peerPublicKey: _peerPublicKeyController.text.trim(),
              localAddress: _localAddressController.text
                  .split(',')
                  .map((address) => address.trim())
                  .where((address) => address.isNotEmpty)
                  .toList(growable: false),
              preSharedKey: _preSharedKeyController.text.trim().isEmpty
                  ? null
                  : _preSharedKeyController.text.trim(),
              mtu: int.tryParse(_mtuController.text.trim()),
              persistentKeepalive:
                  keepaliveRaw.isEmpty ? 25 : int.parse(keepaliveRaw),
            );
            Navigator.pop(
              context,
              NodesCreateProfileRequest(
                name: _nameController.text.trim(),
                config: config,
              ),
            );
          },
          child: Text(l10n.create),
        ),
      ],
    );
  }
}
