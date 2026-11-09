import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app_scope.dart';
import '../../data/voces/lore_match.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/setup/import_step.dart' show SoulkynImportDialog;
import '../../data/voces/voces_library.dart';
import '../../data/voces/voces_models.dart';
import '../../services/import/avatar_download.dart';
import '../../services/import/imported_character.dart';
import '../../services/import/voces_import.dart';
import '../../services/voces/chat_import.dart';
import '../import/soulkyn_chat_dialog.dart' show readSoulkynChat;
import 'chat_import_dialog.dart';
import 'story_view.dart' show playStory;
import '../../shell/companion_switcher.dart';
import '../../theme/app_theme.dart';
import 'characters_view.dart';
import 'lorebooks_view.dart';
import 'voces_editor.dart';
import 'voces_widgets.dart';
import 'worlds_view.dart';

/// Everything in the Voces Mundi folder, loaded once and again after each
/// change.
class VocesData extends ChangeNotifier {
  VocesData(this.library, {this.mature = _no});

  static bool _no() => false;

  final VocesLibrary library;

  /// Whether 18+ worlds and their stories show (Settings → Mature content).
  final bool Function() mature;
  var worlds = <VocesWorld>[];
  var characters = <VocesCharacter>[];
  var lorebooks = <Lorebook>[];
  var stories = <StorySave>[];

  /// Keys of the drafts kept ([VocesLibrary.draftKey]).
  var drafts = <String>{};
  var loaded = false;
  var _gone = false;

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }

  Future<void> reload() async {
    final results = await Future.wait([
      library.worlds(),
      library.characters(),
      library.lorebooks(),
      library.stories(),
      library.draftKeys(),
    ]);
    if (_gone) return;
    drafts = results[4] as Set<String>;
    final all = results[0] as List<VocesWorld>;
    final adult = mature()
        ? const <String>{}
        : {
            for (final w in all)
              if (w.adult) w.id,
          };
    worlds = [
      for (final w in all)
        if (!adult.contains(w.id)) w,
    ];
    characters = results[1] as List<VocesCharacter>;
    lorebooks = results[2] as List<Lorebook>;
    stories = [
      for (final s in results[3] as List<StorySave>)
        if (!adult.contains(s.worldId)) s,
    ];
    loaded = true;
    notifyListeners();
  }

  VocesCharacter? character(String id) =>
      characters.where((c) => c.id == id).firstOrNull;
  VocesWorld? world(String id) => worlds.where((w) => w.id == id).firstOrNull;
  Lorebook? lorebook(String id) =>
      lorebooks.where((b) => b.id == id).firstOrNull;
}

enum VocesTab {
  worlds('Worlds', Icons.public_rounded),
  characters('Characters', Icons.groups_rounded),
  lorebooks('Lorebooks', Icons.auto_stories_rounded);

  const VocesTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Voces Mundi's home: the library of worlds, characters and lorebooks,
/// with the stories under way on top. It takes the window's place while
/// open; "Back to …" returns to the companion.
class VocesHome extends StatefulWidget {
  const VocesHome({super.key});

  @override
  State<VocesHome> createState() => _VocesHomeState();
}

class _VocesHomeState extends State<VocesHome> {
  VocesData? _data;
  var _tab = VocesTab.worlds;
  final _search = TextEditingController();

  /// What each tab has open, kept while switching tabs.
  String? _world;
  String? _character;
  String? _book;

  /// A lore line to try, when search jumped to an entry.
  String? _loreTry;

  /// The editor filling the main panel, if one is open, and how to close
  /// it (it keeps a draft).
  Widget? _editor;

  /// Settings, open in the main panel.
  var _settingsOpen = false;
  final _settings = GlobalKey<SettingsScreenState>();

  /// Closes Settings, first asking about unsaved changes there. False
  /// when the human chose to stay.
  Future<bool> _leaveSettings() async {
    if (!_settingsOpen) return true;
    final ok = await _settings.currentState?.mayLeave() ?? true;
    if (ok && mounted) setState(() => _settingsOpen = false);
    return ok;
  }

  /// "Back to …": straight to the only companion, or the companion picker
  /// when there are more.
  Future<void> _back() async {
    if (!await _leaveSettings() || !mounted) return;
    final services = AppScope.of(context);
    final s = services.settings.value;
    if (s.otherCompanions.isEmpty) {
      services.vocesOpen.value = false;
      return;
    }
    final picked = await pickCompanion(context);
    if (picked == null || !mounted) return;
    final c = picked.companion;
    if (c != null && c.id != s.companionId) {
      await services.switchCompanion(services.settings.value.switchedTo(c));
    }
    services.vocesOpen.value = false;
    if (picked.add) services.addingCompanion.value = true;
  }

  Future<void> _go(VoidCallback then) async {
    if (await _leaveSettings()) then();
  }

  final _body = GlobalKey();
  VoidCallback? _endEditor;
  var _editors = 0;

  Future<T?> _openEditor<T>(Widget Function(void Function(T?) done) build) {
    _endEditor?.call();
    final result = Completer<T?>();
    final n = ++_editors;
    void done(T? value) {
      if (result.isCompleted) return;
      if (mounted && _editors == n) {
        setState(() {
          _editor = null;
          _endEditor = null;
        });
      }
      result.complete(value);
    }

    _search.clear();
    setState(() {
      _editor = KeyedSubtree(key: ValueKey('editor:$n'), child: build(done));
      _endEditor = () => done(null);
    });
    return result.future;
  }

  @override
  void initState() {
    super.initState();
    // Searching leaves the editor (its draft is kept).
    _search.addListener(() {
      if (_search.text.trim().isEmpty) return;
      _endEditor?.call();
      if (_settingsOpen) {
        // Searching leaves Settings too, unless the human stays there.
        _leaveSettings().then((left) {
          if (!left) _search.clear();
        });
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_data != null) return;
    final settings = AppScope.of(context).settings;
    final folder = settings.value.companionFolder;
    final root = folder == null ? Directory.systemTemp.path : p.dirname(folder);
    _data = VocesData(
      VocesLibrary.inside(root),
      mature: () => settings.value.vocesMature,
    )..reload();
  }

  @override
  void dispose() {
    _search.dispose();
    _data?.dispose();
    super.dispose();
  }

  void _show(VocesTab tab, {String? world, String? character, String? book}) {
    _endEditor?.call();
    setState(() {
      _tab = tab;
      _search.clear();
      if (tab == VocesTab.worlds) _world = world;
      if (character != null) _character = character;
      if (book != null) _book = book;
    });
  }

  Future<void> _import() async {
    final how = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Import'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'file'),
            child: const ListTile(
              leading: Icon(Icons.description_outlined),
              title: Text('A card or lorebook file'),
              subtitle: Text('Character cards (JSON or PNG), lorebooks'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'soulkyn'),
            child: const ListTile(
              leading: Icon(Icons.link_rounded),
              title: Text('A Soulkyn link'),
              subtitle: Text('Characters, and RPG or World cards as worlds'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'chat'),
            child: const ListTile(
              leading: Icon(Icons.forum_outlined),
              title: Text('A Soulkyn chat (.csv)'),
              subtitle: Text('A chat you exported there, as a story to go on'),
            ),
          ),
        ],
      ),
    );
    if (how == null || !mounted) return;
    final data = _data!;
    if (how == 'chat') return _importChat(data);
    try {
      VocesImported? read;
      if (how == 'file') {
        final file = await _pickCard();
        if (file == null || !mounted) return;
        read = await VocesImport.readFile(file);
      } else {
        final got = await showDialog<Object>(
          context: context,
          builder: (_) =>
              SoulkynImportDialog(pickFile: _pickCard, offerChat: false),
        );
        if (got is ImportedCharacter) {
          read = VocesImport.fromCard(null, got);
        } else if (got is File) {
          read = await VocesImport.readFile(got);
        }
      }
      if (read == null || !mounted) return;
      if (read.isEmpty) {
        throw const ImportException(
          'There is no character or lorebook in this file.',
        );
      }
      if (read.card != null) {
        final as = await _askImportAs(read);
        if (as == null || !mounted) return;
        if (as.picture) read = await _withPicture(read);
        if (as.world) read = VocesImport.asWorld(read);
      }
      if (!mounted) return;
      final named = await _nameClashes(read, data);
      if (named == null || !mounted) return;
      final got = await VocesImport.save(named, data.library);
      await data.reload();
      if (!mounted) return;
      await _showImported(got);
    } on ImportException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// A chat exported from Soulkyn, as a story: asks where it goes and who
  /// the human plays, saves it and opens it.
  Future<void> _importChat(VocesData data) async {
    final chat = await readSoulkynChat(context);
    if (chat == null || !mounted) return;
    final plan = await showDialog<ChatStoryPlan>(
      context: context,
      builder: (_) => ChatStoryDialog(chat: chat, data: data),
    );
    if (plan == null || !mounted) return;
    final services = AppScope.of(context);
    try {
      final story = await VocesChatImport.save(
        chat,
        data.library,
        openLog: services.openStoryLog,
        world: plan.world,
        narratorLed: plan.how != ChatWorld.character,
        adult: plan.adult,
        player: plan.player,
        title: plan.title,
      );
      await data.reload();
      if (!mounted) return;
      if (plan.adult && !data.mature()) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The story is saved. It shows once Mature content is on in '
              'Settings.',
            ),
          ),
        );
        return;
      }
      await playStory(context, data, story);
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('The chat couldn\'t be imported: $e')),
      );
    }
  }

  Future<File?> _pickCard() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Character cards and lorebooks',
          extensions: ['json', 'png'],
        ),
      ],
    );
    return file == null ? null : File(file.path);
  }

  /// The picture a card only links to, fetched now that the human asked.
  Future<VocesImported> _withPicture(VocesImported read) async {
    final card = read.card!;
    final url = card.avatarUrl ?? card.avatars?.still;
    if (url == null || read.portrait != null) return read;
    try {
      final file = await AvatarDownload().fetch(url);
      return VocesImported(
        character: read.character,
        portrait: file,
        lorebook: read.lorebook,
        notes: read.notes,
        card: read.card,
      );
    } on Object {
      return VocesImported(
        character: read.character,
        lorebook: read.lorebook,
        notes: [...read.notes, 'Its picture couldn\'t be downloaded.'],
        card: read.card,
      );
    }
  }

  /// Whether a card comes in as a character or as a world the narrator
  /// runs, and whether to fetch a picture it only links to. Null when
  /// cancelled.
  Future<({bool world, bool picture})?> _askImportAs(VocesImported read) {
    final card = read.card!;
    final link = read.portrait == null
        ? (card.avatarUrl ?? card.avatars?.still)
        : null;
    var world = read.looksLikeAGame;
    var picture = false;
    return showDialog<({bool world, bool picture})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final muted = TextStyle(
            fontSize: 12,
            color: context.palette.textMuted,
          );
          return AlertDialog(
            title: Text('Bring in ${card.name} as…'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (read.looksLikeAGame) ...[
                    Text(
                      'This card was made for roleplay, so a world fits it '
                      'best.',
                      style: muted,
                    ),
                    const SizedBox(height: 8),
                  ],
                  RadioGroup<bool>(
                    groupValue: world,
                    onChanged: (v) => setState(() => world = v ?? world),
                    child: const Column(
                      children: [
                        RadioListTile(
                          value: false,
                          contentPadding: EdgeInsets.zero,
                          title: Text('A character'),
                          subtitle: Text(
                            'One person, for any world\'s cast or for you '
                            'to play.',
                          ),
                        ),
                        RadioListTile(
                          value: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('A world the narrator runs'),
                          subtitle: Text(
                            'The card is the game: its story becomes the '
                            'setting and a lorebook, people it names become '
                            'characters, and the narrator voices the rest.',
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (link != null)
                    CheckboxListTile(
                      value: picture,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (v) => setState(() => picture = v ?? false),
                      title: const Text('Download its picture'),
                      subtitle: Text('From ${link.host}', style: muted),
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
                onPressed: () =>
                    Navigator.pop(context, (world: world, picture: picture)),
                child: const Text('Import'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// When something by the same name is already here, asks what to call
  /// the new one (the old one is never replaced); null when cancelled.
  Future<VocesImported?> _nameClashes(
    VocesImported read,
    VocesData data,
  ) async {
    var character = read.character;
    var book = read.lorebook;
    var world = read.world;
    if (world != null) {
      final taken = {for (final w in data.worlds) _key(w.name)};
      if (taken.contains(_key(world.name))) {
        final name = await _askNewName(
          kind: 'world',
          name: world.name,
          taken: taken,
        );
        if (name == null) return null;
        if (book != null && book.name == '${world.name} lore') {
          book = book.copyWith(name: '$name lore');
        }
        world = world.copyWith(name: name);
      }
    }
    // People a world brings get a number when the name is taken; their
    // world tells them apart anyway.
    final names = {for (final c in data.characters) _key(c.name)};
    final cast = [
      for (final c in read.cast) c.copyWith(name: _free(c.name, names)),
    ];
    if (character != null) {
      final taken = {for (final c in data.characters) _key(c.name)};
      if (taken.contains(_key(character.name))) {
        final name = await _askNewName(
          kind: 'character',
          name: character.name,
          taken: taken,
        );
        if (name == null) return null;
        // The card's own lorebook is named after them.
        if (book != null && book.name == "${character.name}'s lore") {
          book = book.copyWith(name: "$name's lore");
        }
        character = character.copyWith(name: name);
      }
    }
    if (book != null) {
      final taken = {for (final b in data.lorebooks) _key(b.name)};
      if (taken.contains(_key(book.name))) {
        final name = await _askNewName(
          kind: 'lorebook',
          name: book.name,
          taken: taken,
        );
        if (name == null) return null;
        book = book.copyWith(name: name);
      }
    }
    return VocesImported(
      character: character,
      portrait: read.portrait,
      lorebook: book,
      notes: read.notes,
      world: world,
      cast: cast,
    );
  }

  static String _key(String name) => name.trim().toLowerCase();

  /// [name], or "[name] 2" and up when taken; adds it to [taken].
  static String _free(String name, Set<String> taken) {
    var out = name;
    for (var n = 2; taken.contains(_key(out)); n++) {
      out = '$name $n';
    }
    taken.add(_key(out));
    return out;
  }

  Future<String?> _askNewName({
    required String kind,
    required String name,
    required Set<String> taken,
  }) {
    var n = 2;
    while (taken.contains(_key('$name $n'))) {
      n++;
    }
    final field = TextEditingController(text: '$name $n');
    return showDialog<String>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: field,
        builder: (context, _) {
          final text = field.text.trim();
          final ok = text.isNotEmpty && !taken.contains(_key(text));
          return AlertDialog(
            title: Text('$name is already here'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'You already have a $kind called $name. The one you '
                    'have stays as it is; give the new one a name of its own.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: field,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Name',
                      errorText: text.isNotEmpty && !ok
                          ? 'That name is taken too.'
                          : null,
                    ),
                    onSubmitted: ok
                        ? (_) => Navigator.pop(context, text)
                        : null,
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
                onPressed: ok ? () => Navigator.pop(context, text) : null,
                child: const Text('Import'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showImported(VocesImported got) async {
    final c = got.character;
    final b = got.lorebook;
    final w = got.world;
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          w != null
              ? '${w.name} is in your worlds'
              : c != null
              ? '${c.name} joined your characters'
              : 'Lorebook imported',
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (b != null)
                Text(
                  '${b.name}: ${b.entries.length} '
                  '${b.entries.length == 1 ? 'entry' : 'entries'} in Lorebooks.',
                ),
              for (final n in got.notes) ...[
                const SizedBox(height: 8),
                Text(
                  n,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.palette.textMuted,
                  ),
                ),
              ],
              if (w == null && c != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Add them to a world from the world\'s page.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.palette.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    if (open != true) return;
    if (w != null) {
      _show(VocesTab.worlds, world: w.id);
    } else if (c != null) {
      _show(VocesTab.characters, character: c.id);
    } else if (b != null) {
      _show(VocesTab.lorebooks, book: b.id);
    }
  }

  Future<void> _newWorld() async {
    _show(VocesTab.worlds);
    // From under the editor host, so the editor takes the main panel.
    final made = await editWorld(_body.currentContext!, _data!, null);
    if (made != null) _show(VocesTab.worlds, world: made.id);
  }

  @override
  Widget build(BuildContext context) {
    final data = _data!;
    return VocesEditorHost(
      open: _openEditor,
      child: Scaffold(
        key: _body,
        body: Padding(
          padding: const EdgeInsets.all(14),
          child: ListenableBuilder(
            listenable: Listenable.merge([data, _search]),
            builder: (context, _) => Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 280, child: _sidebar(context, data)),
                const SizedBox(width: 14),
                Expanded(
                  child: _settingsOpen
                      ? SettingsScreen(key: _settings)
                      : GlassPanel(
                          blur: GlassPanel.still,
                          padding: EdgeInsets.zero,
                          child: Material(
                            type: MaterialType.transparency,
                            child: !data.loaded
                                ? const Center(
                                    child: CircularProgressIndicator(),
                                  )
                                : AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 220),
                                    child: _main(context, data),
                                  ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _main(BuildContext context, VocesData data) {
    if (_editor != null) return _editor!;
    final q = _search.text.trim();
    if (q.length >= 2) {
      return _SearchResults(
        key: ValueKey('search:$q'),
        query: q,
        data: data,
        onWorld: (w) => _show(VocesTab.worlds, world: w.id),
        onCharacter: (c) => _show(VocesTab.characters, character: c.id),
        onLore: (b, e) {
          _loreTry = e.keys.isEmpty ? e.title : e.keys.first;
          _show(VocesTab.lorebooks, book: b.id);
        },
      );
    }
    return switch (_tab) {
      VocesTab.worlds => WorldsView(
        key: const ValueKey('worlds'),
        data: data,
        open: _world,
        onOpen: (id) => setState(() => _world = id),
        onCharacter: (id) => _show(VocesTab.characters, character: id),
        onLorebook: (id) => _show(VocesTab.lorebooks, book: id),
      ),
      VocesTab.characters => CharactersView(
        key: const ValueKey('characters'),
        data: data,
        selected: _character,
        onSelect: (id) => setState(() => _character = id),
      ),
      VocesTab.lorebooks => LorebooksView(
        key: ValueKey('lore:$_loreTry'),
        data: data,
        selected: _book,
        onSelect: (id) => setState(() => _book = id),
        tryText: _loreTry,
      ),
    };
  }

  Widget _sidebar(BuildContext context, VocesData data) {
    final services = AppScope.of(context);
    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    final searching = _search.text.trim().length >= 2;
    final counts = {
      VocesTab.worlds: data.worlds.length,
      VocesTab.characters: data.characters.length,
      VocesTab.lorebooks: data.lorebooks.length,
    };
    return GlassPanel(
      blur: GlassPanel.still,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _back,
                icon: const Icon(Icons.chevron_left_rounded),
                label: Text(
                  services.settings.value.otherCompanions.isEmpty
                      ? 'Back to ${services.settings.value.companionName}'
                      : 'Back to Vox Cordis',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: vocesColors,
                    ),
                  ),
                  child: const Icon(Icons.public_rounded, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Voces Mundi',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          color: palette.text,
                        ),
                      ),
                      Text(
                        'RPG mode · Worlds, stories, lorebooks',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search everything',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: _search.clear,
                      ),
              ),
            ),
            const SizedBox(height: 12),
            for (final t in VocesTab.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: _NavRow(
                  icon: t.icon,
                  label: t.label,
                  count: counts[t]!,
                  on: t == _tab && !searching && !_settingsOpen,
                  accent: accent,
                  onTap: () => _go(
                    () => _show(
                      t,
                      world: t == _tab && !_settingsOpen ? null : _world,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            _NavRow(
              icon: Icons.settings_outlined,
              label: 'Settings',
              on: _settingsOpen,
              accent: accent,
              onTap: () {
                _endEditor?.call();
                _search.clear();
                setState(() => _settingsOpen = true);
              },
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: () => _go(_newWorld),
              icon: const Icon(Icons.add_rounded),
              label: const Text('New world'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _go(_import),
              icon: const Icon(Icons.file_download_outlined),
              label: const Text('Import'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.label,
    this.count,
    required this.on,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int? count;
  final bool on;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: on ? accent.withValues(alpha: 0.2) : Colors.transparent,
          border: Border.all(
            color: on ? accent.withValues(alpha: 0.5) : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: on ? palette.text : palette.textMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  color: on ? palette.text : palette.textMuted,
                ),
              ),
            ),
            if (count != null)
              Text(
                '$count',
                style: TextStyle(fontSize: 12, color: palette.textMuted),
              ),
          ],
        ),
      ),
    );
  }
}

/// What the sidebar's search found, by kind.
class _SearchResults extends StatelessWidget {
  const _SearchResults({
    super.key,
    required this.query,
    required this.data,
    required this.onWorld,
    required this.onCharacter,
    required this.onLore,
  });

  final String query;
  final VocesData data;
  final ValueChanged<VocesWorld> onWorld;
  final ValueChanged<VocesCharacter> onCharacter;
  final void Function(Lorebook, LoreEntry) onLore;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final hits = searchVoces(
      query,
      worlds: data.worlds,
      characters: data.characters,
      lorebooks: data.lorebooks,
    );
    Widget row(
      String kind,
      String name,
      String line,
      VoidCallback onTap, {
      Widget? lead,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: VocesBox(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              ?lead,
              if (lead != null) const SizedBox(width: 12),
              VocesPill(kind),
              const SizedBox(width: 12),
              Text(
                name,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: palette.text,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: palette.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Results for “$query”',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: palette.text,
          ),
        ),
        const SizedBox(height: 14),
        if (hits.isEmpty)
          Text(
            'Nothing found in your worlds, characters or lorebooks.',
            style: TextStyle(color: palette.textMuted),
          ),
        for (final h in hits)
          switch (h) {
            WorldHit(:final world) => row(
              'World',
              world.name,
              world.line,
              () => onWorld(world),
            ),
            CharacterHit(:final character) => row(
              'Character',
              character.name,
              character.line,
              () => onCharacter(character),
              lead: VocesAvatar(
                name: character.name,
                seed: character.art,
                file: data.library.portraitOf(character),
                size: 30,
              ),
            ),
            LoreHit(:final book, :final entry) => row(
              'Lore',
              entry.title,
              'in ${book.name}',
              () => onLore(book, entry),
            ),
          },
      ],
    );
  }
}
