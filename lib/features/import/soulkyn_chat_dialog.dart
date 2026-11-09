import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app_scope.dart';
import '../../services/import/imported_character.dart';
import '../../services/import/soulkyn_chat.dart';
import '../../theme/app_theme.dart';

/// Picks a Soulkyn chat export (.csv); null when the human cancels.
Future<File?> pickSoulkynChat() async {
  final f = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Soulkyn chat export', extensions: ['csv']),
    ],
  );
  return f == null ? null : File(f.path);
}

/// Reads a chat the human picks, telling them when it isn't one.
Future<SoulkynChat?> readSoulkynChat(
  BuildContext context, {
  Future<File?> Function()? pick,
}) async {
  final file = await (pick ?? pickSoulkynChat)();
  if (file == null || !context.mounted) return null;
  try {
    return await SoulkynChat.read(file);
  } on ImportException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
    return null;
  }
}

/// "Import a Soulkyn chat…" in Settings → General: picks the export and
/// adds its messages to the current companion's chat.
Future<void> importSoulkynChat(
  BuildContext context, {
  Future<File?> Function()? pick,
}) async {
  final chat = await readSoulkynChat(context, pick: pick);
  if (chat == null || !context.mounted) return;
  final learn = await showDialog<bool>(
    context: context,
    builder: (_) => SoulkynChatDialog(chat: chat),
  );
  if (learn == null || !context.mounted) return;
  final services = AppScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final s = services.settings.value;
  try {
    final added = await SoulkynChatImport.intoCompanion(
      services.db,
      chat,
      userName: s.userName,
    );
    services.memoryChanged();
    services.recall.update().ignore();
    services.resets.value++;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          added == 0
              ? 'Every message of this chat is already there.'
              : '$added messages from Soulkyn are in the chat now.',
        ),
      ),
    );
    if (learn) services.learnFromChat(chat).ignore();
  } on Object catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('The chat couldn\'t be imported: $e')),
    );
  }
}

/// What is in the chat and where it goes; pops whether to learn memories
/// from it, or null when cancelled.
class SoulkynChatDialog extends StatefulWidget {
  const SoulkynChatDialog({super.key, required this.chat});

  final SoulkynChat chat;

  @override
  State<SoulkynChatDialog> createState() => _SoulkynChatDialogState();
}

class _SoulkynChatDialogState extends State<SoulkynChatDialog> {
  var _learn = true;

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    final s = AppScope.of(context).settings.value;
    final name = s.companionName;
    final muted = TextStyle(
      fontSize: 13,
      height: 1.4,
      color: context.palette.textMuted,
    );
    String day(DateTime d) => DateFormat.yMMMd().format(d.toLocal());
    final other = chat.kynName.toLowerCase() != name.toLowerCase();
    return AlertDialog(
      title: Text('Bring a chat into $name\'s history'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${chat.lines.length} messages with ${chat.kynName} on Soulkyn, '
              '${day(chat.first)} to ${day(chat.last)}. You went by '
              '${chat.persona} there.',
            ),
            const SizedBox(height: 10),
            Text(
              'They go into the chat as they are, in the order they were '
              'written, with their old dates. Importing the same chat again '
              'only adds what is new.',
              style: muted,
            ),
            if (other) ...[
              const SizedBox(height: 8),
              Text(
                'This chat was with ${chat.kynName}; $name will take it as '
                'their own past.',
                style: muted,
              ),
            ],
            if (chat.looksLikeAGame) ...[
              const SizedBox(height: 8),
              Text(
                'It looks like an RPG, where ${chat.kynName} plays many '
                'people.${s.vocesMundi ? ' It may fit Voces Mundi better: '
                          'import it there as a story to go on with.' : ''}',
                style: muted,
              ),
            ],
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _learn,
              onChanged: (v) => setState(() => _learn = v!),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text('Let $name learn memories from it'),
              subtitle: Text(
                '$name reads the chat part by part and keeps what matters. '
                'It uses the model in the background for a while.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _learn),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
