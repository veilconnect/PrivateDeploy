import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import 'profile_provider.dart';

class ProfileContentScreen extends StatefulWidget {
  final Profile profile;
  final String content;

  const ProfileContentScreen({
    Key? key,
    required this.profile,
    required this.content,
  }) : super(key: key);

  @override
  State<ProfileContentScreen> createState() => _ProfileContentScreenState();
}

class _ProfileContentScreenState extends State<ProfileContentScreen> {
  late TextEditingController _contentController;
  bool _isEditing = false;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _contentController = TextEditingController(text: widget.content);
    _contentController.addListener(() {
      setState(() {
        _hasChanges = _contentController.text != widget.content;
      });
    });
  }

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.profile.name),
        actions: [
          IconButton(
            icon: Icon(_isEditing ? Icons.visibility : Icons.edit),
            onPressed: () {
              setState(() {
                _isEditing = !_isEditing;
              });
            },
          ),
          if (_hasChanges && _isEditing)
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _saveContent,
            ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.all(16.w),
        child: TextField(
          controller: _contentController,
          readOnly: !_isEditing,
          maxLines: null,
          expands: true,
          decoration: InputDecoration(
            border: _isEditing ? const OutlineInputBorder() : InputBorder.none,
            hintText: AppLocalizations.of(context)!.pasteSingboxJsonHint,
          ),
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 14.sp,
          ),
        ),
      ),
    );
  }

  Future<void> _saveContent() async {
    final provider = context.read<ProfileProvider>();
    final success = await provider.saveProfileContent(
      widget.profile.id,
      _contentController.text,
    );

    if (!mounted) {
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success ? l10n.profileContentSaved : provider.error ?? l10n.saveFailed,
        ),
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );

    if (success) {
      setState(() {
        _hasChanges = false;
      });
    }
  }
}
