export 'package:fl_clash/models/clipboard_import.dart';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/clipboard_import.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

class ClipboardImportDialog extends StatefulWidget {
  const ClipboardImportDialog({
    super.key,
    required this.readClipboard,
    required this.inspect,
    required this.import,
    required this.onEditTemplate,
    this.title,
    this.initialName,
  });

  final String? title;
  final String? initialName;
  final Future<String?> Function() readClipboard;
  final Future<ClipboardImportPreview> Function(String content) inspect;
  final Future<void> Function(String content, String name) import;
  final Future<void> Function() onEditTemplate;

  @override
  State<ClipboardImportDialog> createState() => _ClipboardImportDialogState();
}

class _ClipboardImportDialogState extends State<ClipboardImportDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  String? _content;
  ClipboardImportPreview? _preview;
  String? _error;
  bool _loading = true;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final content = (await widget.readClipboard())?.trim() ?? '';
      if (content.isEmpty) {
        throw const MessageException('Clipboard is empty');
      }
      final preview = await widget.inspect(content);
      if (!mounted) return;
      _content = content;
      _preview = preview;
      _nameController.text = widget.initialName?.trim().isNotEmpty == true
          ? widget.initialName!.trim()
          : preview.suggestedName;
    } catch (error) {
      if (!mounted) return;
      _error = compactError(error);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _confirm() async {
    if (_importing || !_formKey.currentState!.validate()) return;
    final content = _content;
    if (content == null) return;
    setState(() {
      _error = null;
      _importing = true;
    });
    try {
      await widget.import(content, _nameController.text.trim());
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = compactError(error));
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final preview = _preview;
    return CommonDialog(
      title: widget.title ?? l10n.clipboardImport,
      actions: [
        TextButton(
          onPressed: _importing ? null : widget.onEditTemplate,
          child: Text(l10n.edit),
        ),
        TextButton(
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _loading || preview == null || _importing
              ? null
              : _confirm,
          child: Text(_importing ? l10n.loading : l10n.confirm),
        ),
      ],
      child: SizedBox(
        width: 360,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loading) const Center(child: CircularProgressIndicator()),
              if (preview != null) ...[
                Text(
                  '${clipboardImportKindLabels[preview.kind]} · ${preview.source}',
                ),
                if (preview.nodeCount case final count?)
                  Text('${l10n.nodes}: $count'),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _nameController,
                  decoration: InputDecoration(labelText: l10n.name),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? l10n.profileNameNullValidationDesc
                      : null,
                ),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                Text(error, style: TextStyle(color: context.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
