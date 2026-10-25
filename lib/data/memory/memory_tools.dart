import 'dart:convert';

import 'memory.dart';
import 'memory_repository.dart';

/// The three memory tools offered to the model, in OpenAI function-calling
/// format, and the code that runs them.
class MemoryTools {
  MemoryTools(this._repo);

  final MemoryRepository _repo;

  static const names = {'remember', 'update_memory', 'forget'};

  static const definitions = <Map<String, Object?>>[
    {
      'type': 'function',
      'function': {
        'name': 'remember',
        'description':
            'Save a new long-term fact about the user, yourself, or your shared life. '
            'Use for things worth knowing weeks from now, not small talk.',
        'parameters': {
          'type': 'object',
          'properties': {
            'text': {
              'type': 'string',
              'description': 'The fact as one plain sentence.',
            },
            'subject': {'type': 'string'},
            'predicate': {'type': 'string'},
            'object': {'type': 'string'},
            'category': {
              'type': 'string',
              'description': 'e.g. preference, relationship, project, event',
            },
            'priority': {
              'type': 'integer',
              'minimum': 0,
              'maximum': 100,
              'description': '100 = always keep in mind, 0 = trivia.',
            },
          },
          'required': ['text'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'update_memory',
        'description':
            'Replace an outdated fact with a newer one. The old one is kept as history.',
        'parameters': {
          'type': 'object',
          'properties': {
            'id': {
              'type': 'string',
              'description': 'Id of the memory being replaced.',
            },
            'text': {'type': 'string'},
            'priority': {'type': 'integer', 'minimum': 0, 'maximum': 100},
          },
          'required': ['id', 'text'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'forget',
        'description':
            'Delete a memory. Only when the user explicitly asks you to forget it.',
        'parameters': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
          'required': ['id'],
        },
      },
    },
  ];

  /// Runs one tool call and returns the JSON string sent back to the model.
  Future<String> call(
    String name,
    Map<String, Object?> args, {
    List<String> sourceIds = const [],
  }) async {
    try {
      switch (name) {
        case 'remember':
          final m = await _repo.remember(
            text: _text(args),
            subject: args['subject'] as String?,
            predicate: args['predicate'] as String?,
            object: args['object'] as String?,
            category: args['category'] as String? ?? 'general',
            priority: (args['priority'] as num?)?.toInt() ?? 50,
            sourceIds: sourceIds,
          );
          return jsonEncode({'ok': true, 'id': m.id});
        case 'update_memory':
          final m = await _repo.update(
            args['id'] as String,
            text: _text(args),
            priority: (args['priority'] as num?)?.toInt(),
            sourceIds: sourceIds,
          );
          return jsonEncode({'ok': true, 'id': m.id, 'replaced': args['id']});
        case 'forget':
          final ok = await _repo.retire(args['id'] as String);
          return jsonEncode({
            'ok': ok,
            if (!ok) 'error': 'No current memory has that id.',
          });
      }
      return jsonEncode({'ok': false, 'error': 'unknown tool $name'});
    } catch (e) {
      return jsonEncode({'ok': false, 'error': '$e'});
    }
  }

  /// The fact to save. An empty one is refused, so a model that misnames the
  /// argument is told instead of saving a blank memory.
  static String _text(Map<String, Object?> args) {
    final text = args['text'];
    // A fact has words; a bare date or number (the prompt's clock, say)
    // is not one.
    if (text is! String || !text.contains(RegExp(r'\p{L}', unicode: true))) {
      throw 'Not saved: "text" must be the fact as one plain sentence.';
    }
    return text.trim();
  }

  /// Formats recalled memories for the system prompt, with ids so the model
  /// can update or forget them.
  static String formatForPrompt(List<Memory> memories) {
    if (memories.isEmpty) return 'You have no saved memories yet.';
    return [
      for (final m in memories)
        '- [${m.id}] (${m.category}, p${m.priority}) ${m.text}',
    ].join('\n');
  }
}
