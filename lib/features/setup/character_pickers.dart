import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Gender choice that fills in the pronouns; "Other" lets the user type them.
class PronounPicker extends StatefulWidget {
  const PronounPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.optional = false,
  });

  final String value;
  final ValueChanged<String> onChanged;

  /// Adds "Rather not say", which leaves the pronouns empty.
  final bool optional;

  static const presets = {
    'Female': 'she/her',
    'Male': 'he/him',
    'Non-binary': 'they/them',
  };

  @override
  State<PronounPicker> createState() => _PronounPickerState();
}

class _PronounPickerState extends State<PronounPicker> {
  late final _custom = TextEditingController(
    text: _isPreset(widget.value) ? 'it/its' : widget.value,
  );
  late bool _other =
      !_isPreset(widget.value) && !(widget.optional && widget.value.isEmpty);

  static bool _isPreset(String v) =>
      PronounPicker.presets.values.contains(v.trim().toLowerCase());

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.value.trim().toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final MapEntry(key: label, value: pronouns)
                in PronounPicker.presets.entries)
              ChoiceChip(
                label: Text(label),
                selected: !_other && current == pronouns,
                onSelected: (_) {
                  setState(() => _other = false);
                  widget.onChanged(pronouns);
                },
              ),
            ChoiceChip(
              label: const Text('Other'),
              selected: _other,
              onSelected: (_) {
                setState(() => _other = true);
                widget.onChanged(_custom.text.trim());
              },
            ),
            if (widget.optional)
              ChoiceChip(
                label: const Text('Rather not say'),
                selected: !_other && current.isEmpty,
                onSelected: (_) {
                  setState(() => _other = false);
                  widget.onChanged('');
                },
              ),
          ],
        ),
        const SizedBox(height: 6),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topLeft,
          child: _other
              ? TextField(
                  controller: _custom,
                  onChanged: (v) => widget.onChanged(v.trim()),
                  decoration: const InputDecoration(
                    labelText: 'Pronouns',
                    hintText: 'it/its, xe/xem, any',
                  ),
                )
              : Text(
                  current.isEmpty ? 'No pronouns set' : 'Uses $current',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.palette.textMuted,
                  ),
                ),
        ),
      ],
    );
  }
}

/// Personality traits as chips, grouped, at most [max].
class TraitPicker extends StatefulWidget {
  const TraitPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.max = defaultMax,
  });

  final List<String> value;
  final ValueChanged<List<String>> onChanged;

  /// Five for a companion made from scratch; an imported one keeps more.
  final int max;

  static const defaultMax = 5;

  static const groups = {
    'Heart': [
      'warm',
      'caring',
      'gentle',
      'loyal',
      'empathetic',
      'protective',
      'patient',
    ],
    'Energy': [
      'cheerful',
      'playful',
      'bubbly',
      'energetic',
      'calm',
      'laid-back',
      'dreamy',
    ],
    'Mind': [
      'curious',
      'witty',
      'clever',
      'nerdy',
      'creative',
      'philosophical',
      'bookish',
    ],
    'Edge': [
      'sarcastic',
      'teasing',
      'mischievous',
      'bold',
      'blunt',
      'stubborn',
      'mysterious',
      'aloof',
    ],
    'Charm': [
      'flirty',
      'charming',
      'affectionate',
      'romantic',
      'seductive',
      'confident',
      'bashful',
      'devoted',
    ],
    'Lifestyle': [
      'night owl',
      'early bird',
      'adventurous',
      'homebody',
      'foodie',
      'gamer',
      'artsy',
      'sporty',
    ],
  };

  @override
  State<TraitPicker> createState() => _TraitPickerState();
}

class _TraitPickerState extends State<TraitPicker> {
  final _custom = TextEditingController();
  final _customFocus = FocusNode();

  List<String> get _selected => [
    for (final t in widget.value) t.trim().toLowerCase(),
  ];

  bool get _full => _selected.length >= widget.max;

  @override
  void initState() {
    super.initState();
    // The example disappears as soon as the field is clicked.
    _customFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _custom.dispose();
    _customFocus.dispose();
    super.dispose();
  }

  void _toggle(String trait) {
    final s = _selected;
    if (s.contains(trait)) {
      widget.onChanged(s..remove(trait));
    } else if (!_full) {
      widget.onChanged(s..add(trait));
    }
  }

  void _addCustom() {
    final t = _custom.text.trim().toLowerCase();
    if (t.isEmpty || _full || _selected.contains(t)) return;
    _custom.clear();
    widget.onChanged(_selected..add(t));
  }

  static String _label(String t) => t[0].toUpperCase() + t.substring(1);

  static const _header = TextStyle(fontSize: 12, fontWeight: FontWeight.w600);

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    final accent = Theme.of(context).colorScheme.primary;

    Widget chip(String t) {
      final on = selected.contains(t);
      return FilterChip(
        label: Text(_label(t)),
        selected: on,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onSelected: on || !_full ? (_) => _toggle(t) : null,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // What is picked, in order, removable; the groups below only mark it.
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              Text(
                '${selected.length} of ${widget.max}',
                style: TextStyle(
                  fontSize: 12,
                  color: context.palette.textMuted,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.centerLeft,
                  child: selected.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text(
                            'Pick up to ${widget.max == 5 ? 'five' : widget.max} '
                            'traits below',
                            style: TextStyle(color: context.palette.textMuted),
                          ),
                        )
                      : Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final t in selected)
                              InputChip(
                                label: Text(_label(t)),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: accent.withValues(alpha: 0.22),
                                deleteButtonTooltipMessage: 'Remove',
                                onDeleted: () => _toggle(t),
                              ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
        for (final MapEntry(key: group, value: traits)
            in TraitPicker.groups.entries) ...[
          const SizedBox(height: 12),
          Text(group, style: _header),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: traits.map(chip).toList()),
        ],
        const SizedBox(height: 16),
        const Text('Your own trait', style: _header),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _custom,
                focusNode: _customFocus,
                enabled: !_full,
                onSubmitted: (_) => _addCustom(),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: _full
                      ? 'Five picked; remove one to add your own'
                      : _customFocus.hasFocus
                      ? null
                      : 'e.g. Sentimental',
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Add trait',
              onPressed: _full ? null : _addCustom,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
      ],
    );
  }
}
