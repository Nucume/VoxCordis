import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/voces/voces_models.dart';
import '../../services/import/soulkyn_chat.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_popover.dart';
import 'voces_home.dart';
import 'voces_widgets.dart';

/// Where a Soulkyn chat goes in Voces Mundi.
enum ChatWorld {
  /// A new world the narrator runs: the Kyn played everyone.
  narrator,

  /// A new world with the Kyn as its one character.
  character,

  /// A world already in the library.
  existing,
}

/// What the human chose for a chat brought in as a story.
class ChatStoryPlan {
  const ChatStoryPlan({
    required this.how,
    required this.title,
    this.world,
    this.player,
    this.adult = false,
  });

  final ChatWorld how;
  final String title;

  /// The world for [ChatWorld.existing].
  final VocesWorld? world;

  /// Who the human plays; null makes a character with the name they went
  /// by in the chat.
  final VocesCharacter? player;

  /// A new world is for adults only.
  final bool adult;
}

/// Asks how a Soulkyn chat becomes a story: in which world, played as
/// whom, and its title. Pops a [ChatStoryPlan], or null when cancelled.
class ChatStoryDialog extends StatefulWidget {
  const ChatStoryDialog({super.key, required this.chat, required this.data});

  final SoulkynChat chat;
  final VocesData data;

  @override
  State<ChatStoryDialog> createState() => _ChatStoryDialogState();
}

class _ChatStoryDialogState extends State<ChatStoryDialog> {
  late final _title = TextEditingController(text: widget.chat.kynName);
  late var _how = widget.chat.looksLikeAGame
      ? ChatWorld.narrator
      : ChatWorld.character;
  VocesWorld? _world;
  VocesCharacter? _player;
  late var _adult = widget.data.mature();

  /// The value of "a new character" in the player list.
  static const _newPlayer = '';

  @override
  void initState() {
    super.initState();
    final persona = widget.chat.persona.toLowerCase();
    _player = widget.data.characters
        .where((c) => c.name.toLowerCase() == persona)
        .firstOrNull;
    final kyn = widget.chat.kynName.toLowerCase();
    _world =
        widget.data.worlds
            .where((w) => w.name.toLowerCase() == kyn)
            .firstOrNull ??
        widget.data.worlds.firstOrNull;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    final data = widget.data;
    final muted = TextStyle(
      fontSize: 12,
      height: 1.4,
      color: context.palette.textMuted,
    );
    String day(DateTime d) => DateFormat.yMMMd().format(d.toLocal());
    final ready =
        _title.text.trim().isNotEmpty &&
        (_how != ChatWorld.existing || _world != null);
    Widget choice(ChatWorld v, String title, String blurb) => RadioListTile(
      value: v,
      contentPadding: EdgeInsets.zero,
      enabled: v != ChatWorld.existing || data.worlds.isNotEmpty,
      title: Text(title),
      subtitle: Text(blurb),
    );
    return AlertDialog(
      title: const Text('A story from a Soulkyn chat'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${chat.lines.length} messages with ${chat.kynName}, '
                '${day(chat.first)} to ${day(chat.last)}. They become the '
                'story so far, and you go on from the last one.',
              ),
              const SizedBox(height: 6),
              Text(
                'Once it opens, Voces Mundi reads it through for its people '
                'and notes, a part at a time, with the chat model.',
                style: muted,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 18),
              const VocesLabel('The world'),
              RadioGroup<ChatWorld>(
                groupValue: _how,
                onChanged: (v) => setState(() => _how = v ?? _how),
                child: Column(
                  children: [
                    choice(
                      ChatWorld.narrator,
                      'A new world the narrator runs',
                      '${chat.kynName} played everyone: the narrator goes on '
                          'doing that.',
                    ),
                    choice(
                      ChatWorld.character,
                      'A new world with ${chat.kynName} in it',
                      '${chat.kynName} is one person, who goes on speaking '
                          'for themselves.',
                    ),
                    choice(
                      ChatWorld.existing,
                      'A world you have',
                      data.worlds.isEmpty
                          ? 'There are no worlds yet.'
                          : 'Its setting, cast and lore carry the story on.',
                    ),
                  ],
                ),
              ),
              if (_how == ChatWorld.existing && data.worlds.isNotEmpty)
                LayoutBuilder(
                  builder: (context, box) => GlassSelect<String?>(
                    value: _world?.id,
                    width: box.maxWidth,
                    placeholder: 'Pick a world',
                    options: [
                      for (final w in data.worlds) GlassOption(w.id, w.name),
                    ],
                    onChanged: (id) => setState(
                      () => _world = id == null ? null : data.world(id),
                    ),
                  ),
                )
              else
                SwitchListTile(
                  value: _adult,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) => setState(() => _adult = v),
                  title: const Text('18+ world'),
                  subtitle: Text(
                    data.mature()
                        ? 'For mature stories.'
                        : 'Shows once Mature content is on in Settings.',
                    style: muted,
                  ),
                ),
              const SizedBox(height: 14),
              const VocesLabel('Who you play'),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, box) => GlassSelect<String>(
                  value: _player?.id ?? _newPlayer,
                  width: box.maxWidth,
                  options: [
                    GlassOption(_newPlayer, 'New: ${chat.persona}'),
                    for (final c in data.characters)
                      GlassOption(
                        c.id,
                        c.line.isEmpty ? c.name : '${c.name} · ${c.line}',
                      ),
                  ],
                  onChanged: (id) => setState(
                    () =>
                        _player = id == _newPlayer ? null : data.character(id),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text('You went by ${chat.persona} in the chat.', style: muted),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: ready
              ? () => Navigator.pop(
                  context,
                  ChatStoryPlan(
                    how: _how,
                    title: _title.text.trim(),
                    world: _how == ChatWorld.existing ? _world : null,
                    player: _player,
                    adult: _adult,
                  ),
                )
              : null,
          child: const Text('Import'),
        ),
      ],
    );
  }
}
