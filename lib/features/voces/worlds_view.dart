import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app_scope.dart';
import '../../data/voces/voces_library.dart';
import '../../data/voces/voces_models.dart';
import '../../services/voces/describer.dart';
import '../../services/voces/opening_writer.dart';
import '../../services/voces/tag_suggester.dart';
import '../../theme/app_theme.dart';
import 'voces_editor.dart';
import 'voces_home.dart';
import 'voces_picture.dart';
import 'story_view.dart';
import 'voces_widgets.dart';

/// The Worlds tab: stories under way on top, every world below, and one
/// world's page when [open] is set.
class WorldsView extends StatefulWidget {
  const WorldsView({
    super.key,
    required this.data,
    required this.open,
    required this.onOpen,
    required this.onCharacter,
    required this.onLorebook,
  });

  final VocesData data;
  final String? open;
  final ValueChanged<String?> onOpen;
  final ValueChanged<String> onCharacter;
  final ValueChanged<String> onLorebook;

  @override
  State<WorldsView> createState() => _WorldsViewState();
}

class _WorldsViewState extends State<WorldsView> {
  String? _tag;

  @override
  Widget build(BuildContext context) {
    final world = widget.open == null ? null : widget.data.world(widget.open!);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: world == null
          ? _library(context)
          : _WorldPage(
              key: ValueKey(world.id),
              world: world,
              data: widget.data,
              onBack: () => widget.onOpen(null),
              onStart: () => startStoryIn(context, widget.data, world),
              onStory: (s) => playStory(context, widget.data, s),
              onCharacter: widget.onCharacter,
              onLorebook: widget.onLorebook,
            ),
    );
  }

  Widget _library(BuildContext context) {
    final data = widget.data;
    final palette = context.palette;
    final tags = {for (final w in data.worlds) ...w.tags}.toList()..sort();
    final shown = [
      for (final w in data.worlds)
        if (_tag == null || w.tags.contains(_tag)) w,
    ];
    return CustomScrollView(
      key: const ValueKey('library'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
          sliver: SliverList.list(
            children: [
              const VocesLabel('Continue'),
              const SizedBox(height: 12),
              if (data.stories.isEmpty)
                VocesBox(
                  child: Text(
                    'Stories you start show up here, the one you played '
                    'last first. Pick a world below to begin one.',
                    style: TextStyle(fontSize: 13, color: palette.textMuted),
                  ),
                )
              else
                SizedBox(
                  height: 112,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: data.stories.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 14),
                    itemBuilder: (context, i) => _StoryCard(
                      story: data.stories[i],
                      world: data.world(data.stories[i].worldId),
                      data: data,
                      onTap: () => playStory(context, data, data.stories[i]),
                    ),
                  ),
                ),
              const SizedBox(height: 26),
              Row(
                children: [
                  const Expanded(child: VocesLabel('Worlds')),
                  if (tags.isNotEmpty) ...[
                    VocesPill(
                      'All',
                      on: _tag == null,
                      onTap: () => setState(() => _tag = null),
                    ),
                    for (final t in tags) ...[
                      const SizedBox(width: 6),
                      VocesPill(
                        t,
                        on: _tag == t,
                        onTap: () => setState(() => _tag = t),
                      ),
                    ],
                  ],
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 300,
              mainAxisExtent: 236,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
            ),
            delegate: SliverChildListDelegate([
              for (final w in shown)
                _WorldCard(
                  world: w,
                  data: data,
                  onTap: () => widget.onOpen(w.id),
                ),
              VocesCard(
                dashed: true,
                onTap: () async {
                  final made = await editWorld(context, data, null);
                  if (made != null) widget.onOpen(made.id);
                },
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.add_rounded,
                        size: 30,
                        color: palette.textMuted,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'New world',
                        style: TextStyle(color: palette.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }
}

class _StoryCard extends StatelessWidget {
  const _StoryCard({
    required this.story,
    required this.world,
    required this.data,
    required this.onTap,
  });

  final StorySave story;
  final VocesWorld? world;
  final VocesData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final muted = TextStyle(fontSize: 12, color: palette.textMuted);
    return SizedBox(
      width: 300,
      child: VocesCard(
        onTap: onTap,
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: VocesArt(
                name: story.worldName,
                seed: world?.art,
                file: world == null ? null : data.library.worldPicture(world!),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      story.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: palette.text,
                      ),
                    ),
                    Text(story.worldName, style: muted, maxLines: 1),
                    Text(
                      'as ${story.playerName} · ${story.difficulty.label}',
                      style: muted,
                      maxLines: 1,
                    ),
                    const Spacer(),
                    Text(
                      '${_ago(story.lastPlayed)} · ${story.turns} turns',
                      style: muted.copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 2) return 'Just now';
  if (d.inHours < 1) return '${d.inMinutes} minutes ago';
  if (d.inHours == 1) return 'An hour ago';
  if (d.inHours < 24) return '${d.inHours} hours ago';
  if (d.inDays == 1) return 'Yesterday';
  return '${d.inDays} days ago';
}

class _WorldCard extends StatelessWidget {
  const _WorldCard({
    required this.world,
    required this.data,
    required this.onTap,
    this.picture,
  });

  final VocesWorld world;
  final VocesData data;
  final VoidCallback? onTap;

  /// Shown in place of the saved picture (the editor's preview).
  final File? Function()? picture;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final stories = data.stories.where((s) => s.worldId == world.id).length;
    final meta = [
      if (world.narratorLed)
        'Narrator-led'
      else
        switch (world.castIds.length) {
          1 => '1 character',
          final n => '$n characters',
        },
      switch (stories) {
        0 => 'no stories yet',
        1 => '1 story',
        _ => '$stories stories',
      },
    ].join(' · ');
    return VocesCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 108,
            child: VocesArt(
              name: world.name,
              seed: world.art,
              file: picture != null
                  ? picture!()
                  : data.library.worldPicture(world),
              child: world.tags.isEmpty && !world.adult
                  ? null
                  : Align(
                      alignment: Alignment.topRight,
                      child: Container(
                        margin: const EdgeInsets.all(8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          [
                            if (world.tags.isNotEmpty) world.tags.first,
                            if (world.adult) '18+',
                          ].join(' · '),
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    world.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: palette.text,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    world.line,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: palette.textMuted),
                  ),
                  const Spacer(),
                  Text(
                    meta,
                    style: TextStyle(fontSize: 11, color: palette.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One world: what it is, who lives there, its lore, openings and stories.
class _WorldPage extends StatelessWidget {
  const _WorldPage({
    super.key,
    required this.world,
    required this.data,
    required this.onBack,
    required this.onStart,
    required this.onStory,
    required this.onCharacter,
    required this.onLorebook,
  });

  final VocesWorld world;
  final VocesData data;
  final VoidCallback onBack;
  final VoidCallback onStart;
  final ValueChanged<StorySave> onStory;
  final ValueChanged<String> onCharacter;
  final ValueChanged<String> onLorebook;

  Future<void> _delete(BuildContext context) async {
    final ok = await confirmDelete(
      context,
      title: 'Delete ${world.name}?',
      body:
          'The world goes, with its picture. Its characters and lorebooks '
          'stay in your library, and stories already started keep their own '
          'copy.',
    );
    if (!ok) return;
    await data.library.deleteWorld(world.id);
    onBack();
    await data.reload();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = TextStyle(fontSize: 13, height: 1.55, color: palette.text);
    final muted = TextStyle(fontSize: 12, color: palette.textMuted);
    final cast = [for (final id in world.castIds) ?data.character(id)];
    final books = [for (final id in world.lorebookIds) ?data.lorebook(id)];
    final stories = data.stories.where((s) => s.worldId == world.id).toList();
    Widget box(String label, List<Widget> children) => VocesBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [VocesLabel(label), const SizedBox(height: 10), ...children],
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            height: 170,
            child: VocesArt(
              name: world.name,
              seed: world.art,
              file: data.library.worldPicture(world),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xAA000000)],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 18, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                            ),
                            onPressed: onBack,
                            icon: const Icon(Icons.chevron_left_rounded),
                            label: const Text('All worlds'),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: 'Edit world',
                            color: Colors.white,
                            onPressed: () => editWorld(context, data, world),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: 'Delete world',
                            color: Colors.white,
                            onPressed: () => _delete(context),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  world.name,
                                  style: const TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                ),
                                if (world.line.isNotEmpty)
                                  Text(
                                    world.line,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: Colors.white70,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: onStart,
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('Start a story'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, area) {
            final half = (area.maxWidth - 14) / 2;
            return Wrap(
              spacing: 14,
              runSpacing: 14,
              children: [
                SizedBox(
                  width: half,
                  child: box('Setting and tone', [
                    Text(
                      world.setting.isEmpty
                          ? 'Not written yet. Edit the world to tell the narrator '
                                'where and when this is, and how it should feel.'
                          : world.setting,
                      style: world.setting.isEmpty ? muted : text,
                    ),
                    if (world.tags.isNotEmpty || world.adult) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final t in world.tags) VocesPill(t),
                          if (world.adult) const VocesPill('18+'),
                        ],
                      ),
                    ],
                  ]),
                ),
                SizedBox(
                  width: half,
                  child: box(
                    world.narratorLed ? 'Met so far' : 'Cast in this world',
                    [
                      if (cast.isEmpty)
                        Text(
                          'Nobody yet. Add characters by editing the world.',
                          style: muted,
                        )
                      else
                        Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          children: [
                            for (final c in cast)
                              InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () => onCharacter(c.id),
                                child: SizedBox(
                                  width: 60,
                                  child: Column(
                                    children: [
                                      VocesAvatar(
                                        name: c.name,
                                        seed: c.art,
                                        file: data.library.portraitOf(c),
                                        size: 44,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        c.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: palette.text,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      const SizedBox(height: 8),
                      Text(
                        'You pick who you play when a story starts.',
                        style: muted,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: half,
                  child: box('Lorebooks', [
                    if (books.isEmpty)
                      Text('None attached.', style: muted)
                    else
                      for (final b in books)
                        InkWell(
                          onTap: () => onLorebook(b.id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Expanded(child: Text(b.name, style: text)),
                                Text(
                                  b.entries.length == 1
                                      ? '1 entry'
                                      : '${b.entries.length} entries',
                                  style: muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                  ]),
                ),
                SizedBox(
                  width: half,
                  child: box('How it can open', [
                    if (world.openings.isEmpty)
                      Text(
                        'No openings yet: the narrator will set the first scene.',
                        style: muted,
                      )
                    else
                      for (final o in world.openings)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '${o.title}  ',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                TextSpan(text: o.text, style: muted),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text,
                          ),
                        ),
                  ]),
                ),
                SizedBox(
                  width: area.maxWidth,
                  child: box('Your stories here', [
                    if (stories.isEmpty)
                      Text('None yet. Be the first to walk in.', style: muted)
                    else
                      for (final s in stories)
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => onStory(s),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.play_arrow_rounded,
                                  size: 16,
                                  color: palette.textMuted,
                                ),
                                const SizedBox(width: 6),
                                Expanded(child: Text(s.title, style: text)),
                                Text(
                                  'as ${s.playerName} · ${s.turns} turns',
                                  style: muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                  ]),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Makes a new world ([world] null) or edits one; returns it once saved.
Future<VocesWorld?> editWorld(
  BuildContext context,
  VocesData data,
  VocesWorld? world,
) => openEditor<VocesWorld>(
  context,
  (done) => _WorldEditor(data: data, world: world, done: done),
);

class _WorldEditor extends StatefulWidget {
  const _WorldEditor({
    required this.data,
    required this.world,
    required this.done,
  });

  final VocesData data;
  final VocesWorld? world;
  final void Function(VocesWorld?) done;

  @override
  State<_WorldEditor> createState() => _WorldEditorState();
}

typedef _OpeningFields = (TextEditingController, TextEditingController);

class _WorldEditorState extends State<_WorldEditor> {
  final _name = TextEditingController();
  final _line = TextEditingController();
  final _setting = TextEditingController();
  final _tags = <String>[];
  var _adult = false;
  var _narratorLed = false;
  final _cast = <String>{};
  final _books = <String>{};
  final _openings = <_OpeningFields>[];
  var _art = VocesLibrary.newArt();

  /// A new picture, uploaded or drawn.
  File? _picture;

  /// The old picture is to go, for the colours.
  var _cleared = false;
  var _saving = false;

  /// The opening being written by the model: its index, or -1 for a new
  /// one.
  int? _writing;
  String? _writeError;
  var _suggesting = false;
  String? _suggestError;

  /// What the editor held as it opened, to tell whether anything changed.
  late final String _start;
  late final int _firstArt;

  /// The draft the editor came back with.
  VocesDraft? _restored;

  /// Saved, or let go with Cancel: no draft to keep.
  var _finished = false;

  VocesLibrary get _library => widget.data.library;
  String get _draftKey => VocesLibrary.draftKey('world', widget.world?.id);

  @override
  void initState() {
    super.initState();
    _load(widget.world);
    _firstArt = _art;
    _start = _fingerprint();
    final draft = _library.draft(_draftKey);
    if (draft != null) {
      _restored = draft;
      _load(VocesWorld.fromJson(draft.item));
      _picture = draft.picture?.existsSync() == true ? draft.picture : null;
      _cleared = draft.cleared;
    }
  }

  /// Fills the fields from [w] (empty for null).
  void _load(VocesWorld? w) {
    _name.text = w?.name ?? '';
    _line.text = w?.line ?? '';
    _setting.text = w?.setting ?? '';
    _tags
      ..clear()
      ..addAll(w?.tags ?? const []);
    _adult = w?.adult ?? false;
    _narratorLed = w?.narratorLed ?? false;
    _cast
      ..clear()
      ..addAll(w?.castIds ?? const []);
    _books
      ..clear()
      ..addAll(w?.lorebookIds ?? const []);
    final old = [..._openings];
    _openings
      ..clear()
      ..addAll([
        for (final o in w?.openings ?? const <Opening>[])
          (
            TextEditingController(text: o.title),
            TextEditingController(text: o.text),
          ),
      ]);
    // The old fields may still be on screen until the next frame.
    if (old.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final (a, b) in old) {
          a.dispose();
          b.dispose();
        }
      });
    }
    _art = w?.art ?? _art;
  }

  /// The world as it stands in the editor; [raw] keeps empty openings and
  /// untrimmed text, for a draft.
  VocesWorld _current({bool raw = false}) {
    final base =
        widget.world ?? VocesWorld(id: '', name: '', created: DateTime.now());
    return base.copyWith(
      name: _name.text.trim(),
      line: _line.text.trim(),
      setting: raw ? _setting.text : _setting.text.trim(),
      tags: [..._tags],
      adult: _adult,
      narratorLed: _narratorLed,
      art: _art,
      // Kept in the library's order, and only those that still exist.
      castIds: [
        for (final c in widget.data.characters)
          if (_cast.contains(c.id)) c.id,
      ],
      lorebookIds: [
        for (final b in widget.data.lorebooks)
          if (_books.contains(b.id)) b.id,
      ],
      openings: [
        for (final (t, x) in _openings)
          if (raw)
            Opening(t.text, x.text)
          else if (x.text.trim().isNotEmpty)
            Opening(
              t.text.trim().isEmpty ? 'Opening' : t.text.trim(),
              x.text.trim(),
            ),
      ],
    );
  }

  /// Keeps what's typed as a draft.
  void _keepDraft() {
    _picture = _library.keepDraft(
      _draftKey,
      _current(raw: true).toJson(),
      picture: _picture,
      cleared: _cleared,
    );
  }

  /// Goes back to the saved world, dropping the draft.
  void _dropDraft() {
    dropDrawn(_library, _picture);
    setState(() {
      _load(widget.world);
      _art = _firstArt;
      _picture = null;
      _cleared = false;
      _restored = null;
    });
    unawaited(_library.dropDraft(_draftKey).then((_) => widget.data.reload()));
  }

  Future<void> _cancel() async {
    if (_fingerprint() != _start) {
      final choice = await askLeave(context);
      if (choice == null || !mounted) return;
      if (choice == LeaveChoice.draft) {
        _keepDraft();
      } else {
        await _library.dropDraft(_draftKey);
      }
    } else if (_restored != null) {
      await _library.dropDraft(_draftKey);
    }
    _finished = true;
    unawaited(widget.data.reload());
    widget.done(null);
  }

  @override
  void dispose() {
    // Left without Cancel or Save: what was typed waits as a draft.
    if (!_finished && _fingerprint() != _start) {
      _keepDraft();
      unawaited(widget.data.reload());
    }
    for (final c in [_name, _line, _setting]) {
      c.dispose();
    }
    dropDrawn(_library, _picture);
    for (final (a, b) in _openings) {
      a.dispose();
      b.dispose();
    }
    super.dispose();
  }

  /// "Describe it": the chat model fills the world in from [idea].
  Future<String?> _describe(String idea) {
    final services = AppScope.of(context);
    return describeError(() async {
      final reply = await services.models.ask(
        WorldDescriber.instructions(adult: _adult),
        WorldDescriber.brief(idea, adult: _adult),
        maxTokens: 1800,
        what: 'Describe the world',
      );
      final got = WorldDescriber.parse(reply, adult: _adult);
      if (got == null) return 'The model gave nothing usable. Try again.';
      if (!mounted) return null;
      setState(() {
        _name.text = got.name;
        _line.text = got.line;
        _setting.text = got.setting;
        _tags
          ..clear()
          ..addAll(got.tags);
        final o = got.opening;
        if (o != null) {
          final empty = _openings.indexWhere((f) => f.$2.text.trim().isEmpty);
          if (empty >= 0) {
            _openings[empty].$1.text = o.title;
            _openings[empty].$2.text = o.text;
          } else {
            _openings.add((
              TextEditingController(text: o.title),
              TextEditingController(text: o.text),
            ));
          }
        }
      });
      return null;
    });
  }

  /// Has the chat model pick the tags from the setting.
  Future<void> _suggestTags() async {
    final services = AppScope.of(context);
    setState(() {
      _suggesting = true;
      _suggestError = null;
    });
    try {
      final reply = await services.models.ask(
        TagSuggester.instructions(adult: _adult),
        TagSuggester.brief(
          name: _name.text,
          line: _line.text,
          setting: _setting.text,
        ),
        maxTokens: 600,
        what: 'Suggest world tags',
        exact: true,
      );
      final got = TagSuggester.parse(reply, adult: _adult);
      if (!mounted) return;
      setState(() {
        if (got.isEmpty) {
          _suggestError = 'The model gave nothing usable. Try again.';
        } else {
          _tags
            ..clear()
            ..addAll(got);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _suggestError = 'Couldn\'t reach the model: $e');
      }
    } finally {
      if (mounted) setState(() => _suggesting = false);
    }
  }

  File? get _shown =>
      _picture ??
      (_cleared || widget.world == null
          ? null
          : _library.worldPicture(widget.world!));

  /// Has the chat model write opening [i] (its title is the idea, if
  /// any), or a new one when null.
  Future<void> _writeOpening(int? i) async {
    final services = AppScope.of(context);
    final world = (widget.world ?? const VocesWorld(id: '', name: '')).copyWith(
      name: _name.text.trim(),
      line: _line.text.trim(),
      setting: _setting.text.trim(),
      tags: _tags,
      adult: _adult,
      openings: [
        for (var n = 0; n < _openings.length; n++)
          if (n != i && _openings[n].$2.text.trim().isNotEmpty)
            Opening(_openings[n].$1.text.trim(), _openings[n].$2.text),
      ],
    );
    setState(() {
      _writing = i ?? -1;
      _writeError = null;
    });
    try {
      final reply = await services.models.ask(
        OpeningWriter.instructions,
        OpeningWriter.brief(
          world: world,
          cast: [
            for (final c in widget.data.characters)
              if (_cast.contains(c.id)) c,
          ],
          idea: i == null ? '' : _openings[i].$1.text,
        ),
        what: 'Write an opening',
      );
      final o = OpeningWriter.parse(reply);
      if (!mounted) return;
      setState(() {
        if (o == null) {
          _writeError = 'The model gave nothing usable. Try again.';
        } else if (i == null || i >= _openings.length) {
          _openings.add((
            TextEditingController(text: o.title),
            TextEditingController(text: o.text),
          ));
        } else {
          if (_openings[i].$1.text.trim().isEmpty) {
            _openings[i].$1.text = o.title;
          }
          _openings[i].$2.text = o.text;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _writeError = 'Couldn\'t reach the model: $e');
      }
    } finally {
      if (mounted) setState(() => _writing = null);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return;
    setState(() => _saving = true);
    final lib = _library;
    var saved = await lib.saveWorld(_current());
    if (_picture != null) {
      final name = await lib.adoptWorldPicture(saved.id, _picture!);
      saved = await lib.saveWorld(saved.copyWith(picture: name));
    } else if (_cleared && saved.picture != null) {
      await lib.removeWorldPicture(saved.id);
      saved = await lib.saveWorld(saved.copyWith(clearPicture: true));
    }
    await forgetPicture(lib.worldPicture(saved));
    _finished = true;
    await lib.dropDraft(_draftKey);
    await widget.data.reload();
    widget.done(saved);
  }

  /// Everything the editor would save, to tell whether anything changed.
  String _fingerprint() => [
    _name.text,
    _line.text,
    _setting.text,
    ..._tags,
    _adult,
    _narratorLed,
    ..._cast,
    ..._books,
    for (final (t, x) in _openings) '${t.text}\u0000${x.text}',
    _art,
    _picture?.path,
    _cleared,
  ].join('\u0001');

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final muted = TextStyle(fontSize: 12, color: palette.textMuted);
    InputDecoration field(String label, {String? hint}) => InputDecoration(
      labelText: label,
      hintText: hint,
      alignLabelWithHint: true,
    );
    final error = TextStyle(
      fontSize: 12,
      color: Theme.of(context).colorScheme.error,
    );
    return ListenableBuilder(
      listenable: _name,
      builder: (context, _) => VocesEditorPage(
        title: widget.world == null
            ? 'New world'
            : 'Edit ${widget.world!.name}',
        saveLabel: widget.world == null ? 'Create world' : 'Save',
        onCancel: _cancel,
        onSave: _saving || _name.text.trim().isEmpty ? null : _save,
        banner: _restored == null
            ? null
            : DraftBanner(saved: _restored!.saved, onDrop: _dropDraft),
        preview: _preview(context),
        sections: [
          EditorSection(
            'Basics',
            Icons.edit_note_rounded,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.world == null) ...[
                  DescribeBox(
                    title: 'Describe it',
                    what: 'world',
                    hint:
                        'e.g. a drowned city where the bells still ring '
                        'at low tide',
                    onDescribe: _describe,
                    // The same as the world's own 18+ switch.
                    adult: _adult,
                    onAdult: (on) => setState(() {
                      _adult = on;
                      if (!on) _tags.removeWhere(WorldTags.mature.contains);
                    }),
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: _name,
                  autofocus: widget.world == null && _restored == null,
                  decoration: field('Name', hint: 'e.g. Ember Coast'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _line,
                  decoration: field(
                    'In one line',
                    hint:
                        'A smugglers\' harbour where the lighthouse never '
                        'goes dark.',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _setting,
                  minLines: 5,
                  maxLines: 14,
                  decoration: field(
                    'Setting and tone',
                    hint:
                        'Where and when this is, what kind of story it is, '
                        'and any rules the narrator should keep to.',
                  ),
                ),
              ],
            ),
          ),
          EditorSection(
            'Look',
            Icons.palette_outlined,
            VocesPictureField(
              name: _name.text,
              seed: _art,
              file: _shown,
              wide: true,
              drawingFolder: _library.drawingFolder,
              prompt: () => worldPrompt(
                tags: _tags,
                line: _line.text,
                setting: _setting.text,
              ),
              onSeed: (seed) => setState(() => _art = seed),
              onFile: (f) => setState(() {
                if (f != _picture) dropDrawn(_library, _picture);
                _picture = f;
                _cleared = f == null;
              }),
            ),
          ),
          EditorSection(
            'Tags',
            Icons.sell_outlined,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Up to ${WorldTags.max}. ★ marks the main tag: the '
                        'first one you pick. The story always revolves '
                        'around it; the others add flavour.',
                        style: muted,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ListenableBuilder(
                      listenable: Listenable.merge([_line, _setting]),
                      builder: (context, _) => _suggesting
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : TextButton.icon(
                              onPressed:
                                  (_setting.text.trim().isEmpty &&
                                      _line.text.trim().isEmpty)
                                  ? null
                                  : _suggestTags,
                              icon: const Icon(
                                Icons.auto_awesome_rounded,
                                size: 18,
                              ),
                              label: const Text('Suggest'),
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in [
                      ...WorldTags.all,
                      if (_adult) ...WorldTags.mature,
                    ])
                      Tooltip(
                        message: WorldTags.meanings[t]?.means ?? t,
                        waitDuration: const Duration(milliseconds: 400),
                        child: FilterChip(
                          avatar: _tags.isNotEmpty && _tags.first == t
                              ? const Icon(Icons.star_rounded, size: 18)
                              : null,
                          showCheckmark: false,
                          label: Text(t),
                          selectedColor: WorldTags.mature.contains(t)
                              ? const Color(0x66B23A48)
                              : null,
                          selected: _tags.contains(t),
                          onSelected:
                              !_tags.contains(t) &&
                                  _tags.length >= WorldTags.max
                              ? null
                              : (on) => setState(
                                  () => on ? _tags.add(t) : _tags.remove(t),
                                ),
                        ),
                      ),
                  ],
                ),
                if (_suggestError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_suggestError!, style: error),
                  ),
                if (_adult ||
                    AppScope.of(context).settings.value.vocesMature) ...[
                  const SizedBox(height: 6),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _adult,
                    onChanged: (on) => setState(() {
                      _adult = on;
                      if (!on) _tags.removeWhere(WorldTags.mature.contains);
                    }),
                    title: const Text('For adults (18+)'),
                    subtitle: Text(
                      'Doesn\'t count as a tag, and adds the mature tags '
                      'above. The narrator may then show violence, sex and '
                      'heavy themes in full. The mood itself belongs in the '
                      'setting.',
                      style: muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          EditorSection(
            'Cast and lore',
            Icons.groups_rounded,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _narratorLed,
                  onChanged: (on) => setState(() => _narratorLed = on),
                  title: const Text('The narrator runs everything'),
                  subtitle: Text(
                    'For a game more than a cast: the narrator invents and '
                    'voices the people you meet. Characters picked below '
                    'still speak for themselves.',
                    style: muted,
                  ),
                ),
                const SizedBox(height: 10),
                const VocesLabel('Cast'),
                const SizedBox(height: 8),
                if (widget.data.characters.isEmpty)
                  Text(
                    'Import or make characters in Characters first.',
                    style: muted,
                  )
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in widget.data.characters)
                        FilterChip(
                          avatar: VocesAvatar(
                            name: c.name,
                            seed: c.art,
                            file: _library.portraitOf(c),
                            size: 22,
                          ),
                          label: Text(c.name),
                          selected: _cast.contains(c.id),
                          showCheckmark: false,
                          onSelected: (on) => setState(
                            () => on ? _cast.add(c.id) : _cast.remove(c.id),
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 16),
                const VocesLabel('Lorebooks'),
                const SizedBox(height: 8),
                if (widget.data.lorebooks.isEmpty)
                  Text('No lorebooks yet.', style: muted)
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final b in widget.data.lorebooks)
                        FilterChip(
                          label: Text(b.name),
                          selected: _books.contains(b.id),
                          onSelected: (on) => setState(
                            () => on ? _books.add(b.id) : _books.remove(b.id),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          EditorSection(
            'Openings',
            Icons.menu_book_rounded,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Ways a story here can begin. When you start one, you pick '
                  'one of these, and the narrator opens with it. "Write one '
                  'for me" asks your chat model, from what you wrote above; '
                  'a title you type first becomes its idea.',
                  style: muted,
                ),
                for (var i = 0; i < _openings.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: _openingBox(i, field),
                  ),
                if (_writeError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_writeError!, style: error),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: () => setState(
                        () => _openings.add((
                          TextEditingController(),
                          TextEditingController(),
                        )),
                      ),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Add an opening'),
                    ),
                    TextButton.icon(
                      onPressed: _writing != null || _name.text.trim().isEmpty
                          ? null
                          : () => _writeOpening(null),
                      icon: _writing == -1
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome_rounded),
                      label: Text(
                        _writing == -1 ? 'Writing…' : 'Write one for me',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _openingBox(
    int i,
    InputDecoration Function(String, {String? hint}) field,
  ) => VocesBox(
    padding: const EdgeInsets.fromLTRB(14, 6, 6, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Opening ${i + 1}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            if (_writing == i)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                tooltip: 'Write it for me',
                onPressed: _writing != null ? null : () => _writeOpening(i),
                icon: const Icon(Icons.auto_awesome_rounded),
              ),
            IconButton(
              tooltip: 'Remove',
              onPressed: _writing != null
                  ? null
                  : () => setState(() => _openings.removeAt(i)),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _openings[i].$1,
                decoration: field('Title', hint: 'The back room'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _openings[i].$2,
                minLines: 3,
                maxLines: 10,
                decoration: field(
                  'First words',
                  hint: 'Rain hammers the shutters…',
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  /// The world as it will show in the library, and how the narrator reads
  /// it, as it's typed.
  Widget _preview(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      _line,
      _setting,
      for (final (t, x) in _openings) ...[t, x],
    ]),
    builder: (context, _) {
      final palette = context.palette;
      final w = _current();
      final muted = TextStyle(fontSize: 12, color: palette.textMuted);
      final first = w.openings.firstOrNull;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const VocesLabel('In your library'),
          const SizedBox(height: 8),
          SizedBox(
            height: 236,
            child: _WorldCard(
              world: w.copyWith(name: w.name.isEmpty ? 'Untitled world' : null),
              data: widget.data,
              onTap: null,
              picture: () => _shown,
            ),
          ),
          if (w.tags.isNotEmpty) ...[
            const SizedBox(height: 18),
            const VocesLabel('How the narrator reads the tags'),
            const SizedBox(height: 8),
            VocesBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, t) in w.tags.indexed) ...[
                    if (i > 0) const SizedBox(height: 8),
                    Row(
                      children: [
                        if (i == 0) ...[
                          Icon(
                            Icons.star_rounded,
                            size: 16,
                            color: palette.text,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          i == 0 ? '$t · main' : t,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: palette.text,
                          ),
                        ),
                      ],
                    ),
                    Text(WorldTags.meanings[t]?.means ?? t, style: muted),
                  ],
                ],
              ),
            ),
          ],
          if (first != null) ...[
            const SizedBox(height: 18),
            const VocesLabel('First opening'),
            const SizedBox(height: 8),
            VocesBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    first.title,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: palette.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    first.text,
                    maxLines: 9,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      fontStyle: FontStyle.italic,
                      color: palette.text.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    },
  );
}
