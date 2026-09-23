import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/views/profiles/clipboard_import_dialog.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/config/profile_template.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

const int maxDroppedProfileBytes = 2 * 1024 * 1024;
const Set<String> droppedProfileExtensions = <String>{
  'yaml',
  'yml',
  'txt',
  'conf',
};

class DropImportException implements Exception {
  const DropImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

String droppedProfileName(List<String> paths) =>
    p.basenameWithoutExtension(paths.single.replaceAll('\\', '/'));

Future<String> readDroppedProfile(List<String> paths) async {
  if (paths.length != 1) {
    throw DropImportException(currentAppLocalizations.dropExactlyOneProfile);
  }
  final file = File(paths.single);
  if (!await file.exists() || await FileSystemEntity.isDirectory(file.path)) {
    throw DropImportException(currentAppLocalizations.droppedItemNotFile);
  }
  final extension = p.extension(file.path).replaceFirst('.', '').toLowerCase();
  if (!droppedProfileExtensions.contains(extension)) {
    throw DropImportException(
      currentAppLocalizations.unsupportedProfileFileType,
    );
  }
  final length = await file.length();
  if (length > maxDroppedProfileBytes) {
    throw DropImportException(currentAppLocalizations.profileFileTooLarge);
  }
  try {
    return const Utf8Decoder(
      allowMalformed: false,
    ).convert(await file.readAsBytes());
  } on FormatException {
    throw DropImportException(currentAppLocalizations.profileFileInvalidUtf8);
  }
}

class DesktopProfileDrop extends ConsumerStatefulWidget {
  const DesktopProfileDrop({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DesktopProfileDrop> createState() => _DesktopProfileDropState();
}

class _DesktopProfileDropState extends ConsumerState<DesktopProfileDrop> {
  bool _dragging = false;
  bool _dialogOpen = false;

  Future<void> _handleDrop(DropDoneDetails details) async {
    if (_dialogOpen) return;
    setState(() => _dragging = false);
    _dialogOpen = true;
    try {
      final paths = details.files.map((file) => file.path).toList();
      final content = await readDroppedProfile(paths);
      if (!mounted) return;
      final navigatorContext = globalState.navigatorKey.currentState?.context;
      if (navigatorContext == null) return;
      final action = ref.read(profilesActionProvider.notifier);
      await showDialog<void>(
        context: navigatorContext,
        barrierDismissible: false,
        builder: (_) => ClipboardImportDialog(
          title: context.appLocalizations.fileImport,
          initialName: droppedProfileName(paths),
          readClipboard: () async => content,
          inspect: action.inspectClipboardContent,
          import: action.addProfileFromClipboardContent,
          onEditTemplate: () async {
            await BaseNavigator.push(context, const ProfileTemplateView());
          },
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final navigatorContext = globalState.navigatorKey.currentState?.context;
      if (navigatorContext == null) return;
      await showDialog<void>(
        context: navigatorContext,
        builder: (context) => AlertDialog(
          title: Text(context.appLocalizations.fileImport),
          content: Text(error.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      _dialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _handleDrop,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_dragging)
            const IgnorePointer(
              child: ColoredBox(
                color: Color(0x33000000),
                child: Center(
                  child: Icon(Icons.file_download_outlined, size: 64),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
