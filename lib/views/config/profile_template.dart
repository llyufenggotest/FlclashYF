import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProfileTemplateView extends ConsumerStatefulWidget {
  const ProfileTemplateView({
    super.key,
    this.loadTemplate,
    this.saveTemplate,
    this.resetTemplate,
    this.confirmReset,
  });

  static const editorKey = Key('profile-template-editor');

  final Future<String> Function()? loadTemplate;
  final Future<void> Function(String content)? saveTemplate;
  final Future<void> Function()? resetTemplate;
  final Future<bool> Function(BuildContext context)? confirmReset;

  @override
  ConsumerState<ProfileTemplateView> createState() =>
      _ProfileTemplateViewState();
}

class _ProfileTemplateViewState extends ConsumerState<ProfileTemplateView> {
  final _controller = TextEditingController();
  String? _error;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String> _loadTemplate() {
    return widget.loadTemplate?.call() ??
        ref.read(profilesActionProvider.notifier).loadProfileTemplate();
  }

  Future<void> _saveTemplate(String content) {
    return widget.saveTemplate?.call(content) ??
        ref.read(profilesActionProvider.notifier).saveProfileTemplate(content);
  }

  Future<void> _resetTemplate() {
    return widget.resetTemplate?.call() ??
        ref.read(profilesActionProvider.notifier).resetProfileTemplate();
  }

  Future<void> _load() async {
    try {
      final content = await _loadTemplate();
      if (!mounted) return;
      setState(() {
        _controller.text = content;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _saveTemplate(_controller.text);
      if (!mounted) return;
      context.showSnackBar(context.appLocalizations.profileTemplateSaved);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reset() async {
    final title = context.appLocalizations.restoreDefault;
    final resetMessage = context.appLocalizations.profileTemplateResetConfirm;
    final confirmReset = widget.confirmReset;
    final confirmed = confirmReset != null
        ? await confirmReset(context)
        : await dialogs.showMessage(
                context: context,
                title: title,
                message: TextSpan(text: resetMessage),
              ) ==
              true;
    if (!confirmed || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _resetTemplate();
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      appBar: AppBar(
        title: Text(context.appLocalizations.profileTemplate),
        actions: [
          IconButton(
            tooltip: context.appLocalizations.restoreDefault,
            onPressed: _loading || _saving ? null : _reset,
            icon: const Icon(Icons.restore),
          ),
          IconButton(
            tooltip: context.appLocalizations.save,
            onPressed: _loading || _saving ? null : _save,
            icon: const Icon(Icons.save),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CommonCircleLoading())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(color: context.colorScheme.error),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Expanded(
                    child: TextField(
                      key: ProfileTemplateView.editorKey,
                      controller: _controller,
                      expands: true,
                      maxLines: null,
                      minLines: null,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(fontFamily: 'JetBrainsMono'),
                      decoration: InputDecoration(
                        alignLabelWithHint: true,
                        border: const OutlineInputBorder(),
                        labelText: context.appLocalizations.profileTemplateYaml,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
