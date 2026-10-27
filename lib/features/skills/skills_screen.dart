import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../app_scope.dart';
import '../../data/skills/skills.dart';
import '../../theme/app_theme.dart';

/// The companion's skills: turn them on and off, read and change them,
/// write new ones or import them (Claude skills work as they are).
class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key});

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  List<Skill> _skills = const [];
  bool _loading = true;

  String? get _folder => AppScope.of(context).settings.value.companionFolder;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // It stays built behind other tabs; the companion may have written or
    // changed a skill meanwhile.
    final shown = TickerMode.valuesOf(context).enabled;
    if (_loading || (shown && !_shown)) _reload();
    _shown = shown;
  }

  bool _shown = true;

  Future<void> _reload() async {
    final folder = _folder;
    final skills = folder == null ? const <Skill>[] : await Skills.load(folder);
    if (!mounted) return;
    setState(() {
      _skills = skills;
      _loading = false;
    });
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _setOn(Skill s, bool on) async {
    await Skills.setOn(_folder!, s.id, on);
    await _reload();
  }

  Future<void> _edit([Skill? existing]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _SkillDialog(folder: _folder!, existing: existing),
    );
    if (saved == true) await _reload();
  }

  Future<void> _delete(Skill s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${s.displayTitle}?'),
        content: Text(
          s.builtIn
              ? 'You can bring the starter skills back later with "Restore '
                    'starter skills".'
              : 'Its folder, skills/${s.id}, is deleted with everything in it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Skills.delete(_folder!, s.id);
    await _reload();
  }

  Future<void> _import() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Skills', extensions: ['md', 'txt', 'zip', 'skill']),
      ],
    );
    if (file == null) return;
    try {
      final id = await Skills.import(_folder!, file.path);
      await _reload();
      _say('Imported. Call it with /$id, or let it be picked when it fits.');
    } catch (e) {
      _say('Couldn\'t import ${p.basename(file.path)}: $e');
    }
  }

  Future<void> _restore() async {
    await Skills.restoreBuiltIns(_folder!);
    await _reload();
    _say('The starter skills are back as VoxCordis brings them.');
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final name = services.settings.value.companionName;
    final palette = context.palette;
    final folder = _folder;
    final review = [
      for (final s in _skills)
        if (s.review) s,
    ];
    final rest = [
      for (final s in _skills)
        if (!s.review) s,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Skills',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              enabled: folder != null,
              onSelected: (v) => switch (v) {
                'import' => _import(),
                'folder' => launchUrl(
                  Uri.directory(Skills.dirIn(folder!).path),
                ),
                _ => _restore(),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'import',
                  child: ListTile(
                    leading: Icon(Icons.file_download_outlined),
                    title: Text('Import a skill…'),
                  ),
                ),
                PopupMenuItem(
                  value: 'folder',
                  child: ListTile(
                    leading: Icon(Icons.folder_open_outlined),
                    title: Text('Open the skills folder'),
                  ),
                ),
                PopupMenuItem(
                  value: 'restore',
                  child: ListTile(
                    leading: Icon(Icons.restore_rounded),
                    title: Text('Restore starter skills'),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 6),
            FilledButton.icon(
              onPressed: folder == null ? null : _edit,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New skill'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Skills teach $name how to do particular things. While a skill is '
          'on, $name uses it whenever it fits. Any skill can also be called '
          'up by typing its command in the chat, like /weather Bern. Claude '
          'skills (SKILL.md, .zip or .skill) can be imported as they are.',
          style: TextStyle(fontSize: 12.5, color: palette.textMuted),
        ),
        const SizedBox(height: 16),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (folder == null)
          Text(
            'Finish setting up $name first.',
            style: TextStyle(color: palette.textMuted),
          )
        else ...[
          if (review.isNotEmpty) ...[
            Text(
              'Written by $name, waiting for you',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: palette.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Read them first. They stay off until you turn them on.',
              style: TextStyle(fontSize: 12, color: palette.textMuted),
            ),
            const SizedBox(height: 8),
            for (final s in review) _tile(s),
            const SizedBox(height: 18),
          ],
          if (rest.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  'No skills yet.',
                  style: TextStyle(color: palette.textMuted),
                ),
              ),
            ),
          for (final s in rest) _tile(s),
        ],
      ],
    );
  }

  Widget _tile(Skill s) => _SkillTile(
    skill: s,
    onToggle: (on) => _setOn(s, on),
    onEdit: () => _edit(s),
    onDelete: () => _delete(s),
  );
}

class _SkillTile extends StatelessWidget {
  const _SkillTile({
    required this.skill,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final Skill skill;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final s = skill;
    final tags = [
      s.command,
      if (s.always) 'always on while switched on',
      if (s.builtIn) 'starter',
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: palette.tile,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.glassBorder),
      ),
      child: Row(
        children: [
          Icon(
            s.problem != null
                ? Icons.error_outline
                : s.always
                ? Icons.favorite_border_rounded
                : Icons.school_outlined,
            size: 20,
            color: s.problem != null
                ? Colors.orangeAccent
                : s.on
                ? Theme.of(context).colorScheme.primary
                : palette.textMuted,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.displayTitle, style: TextStyle(color: palette.text)),
                const SizedBox(height: 2),
                Text(
                  s.problem ?? s.description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: s.problem != null
                        ? Colors.orangeAccent
                        : palette.textMuted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tags,
                  style: TextStyle(fontSize: 11.5, color: palette.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Read or change',
            icon: const Icon(Icons.edit_outlined, size: 19),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline_rounded, size: 19),
            onPressed: onDelete,
          ),
          Tooltip(
            message: s.on ? 'On: used when it fits' : 'Off',
            child: Switch(
              value: s.on,
              onChanged: s.problem == null ? onToggle : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Writes a new skill or changes one.
class _SkillDialog extends StatefulWidget {
  const _SkillDialog({required this.folder, this.existing});

  final String folder;
  final Skill? existing;

  @override
  State<_SkillDialog> createState() => _SkillDialogState();
}

class _SkillDialogState extends State<_SkillDialog> {
  late final _title = TextEditingController(
    text: widget.existing?.displayTitle,
  );
  late final _id = TextEditingController(text: widget.existing?.id);
  late final _description = TextEditingController(
    text: widget.existing?.description,
  );
  late final _body = TextEditingController(text: widget.existing?.body);
  late bool _always = widget.existing?.always ?? false;

  /// The command follows the title until it is typed in itself.
  late bool _idTyped = widget.existing != null;
  String? _problem;

  @override
  void dispose() {
    _title.dispose();
    _id.dispose();
    _description.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final problem = await Skills.save(
      widget.folder,
      previousId: widget.existing?.id,
      id: _id.text.trim(),
      title: _title.text.trim(),
      description: _description.text,
      always: _always,
      body: _body.text,
    );
    if (!mounted) return;
    if (problem != null) {
      setState(() => _problem = problem);
    } else {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return AlertDialog(
      title: Text(widget.existing == null ? 'New skill' : 'Skill'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _title,
                      autofocus: widget.existing == null,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'Plant care',
                      ),
                      onChanged: (v) {
                        if (!_idTyped) _id.text = Skills.idFrom(v);
                        setState(() {});
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 200,
                    child: TextField(
                      controller: _id,
                      decoration: const InputDecoration(
                        labelText: 'Command',
                        prefixText: '/',
                        hintText: 'plant-care',
                      ),
                      onChanged: (_) => setState(() => _idTyped = true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _description,
                minLines: 1,
                maxLines: 3,
                maxLength: Skills.maxDescriptionChars,
                decoration: const InputDecoration(
                  labelText: 'What it is for, and when to use it',
                  hintText:
                      'Help my human look after their plants: watering, '
                      'light, and what is wrong with a sick one.',
                ),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _body,
                minLines: 8,
                maxLines: 16,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Instructions',
                  alignLabelWithHint: true,
                  hintText:
                      'Steps in plain words, as you would explain them to a '
                      'friend. Markdown works.',
                ),
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _always,
                onChanged: (v) => setState(() => _always = v),
                title: const Text('Always on'),
                subtitle: Text(
                  'For a way of being rather than a job: the instructions '
                  'go into every message instead of being read when needed. '
                  'Keep them short.',
                  style: TextStyle(fontSize: 12, color: palette.textMuted),
                ),
              ),
              if (widget.existing?.files.isNotEmpty ?? false)
                Text(
                  'Also in its folder: ${widget.existing!.files.join(', ')}',
                  style: TextStyle(fontSize: 12, color: palette.textMuted),
                ),
              if (_problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _problem!,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
