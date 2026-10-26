import 'dart:convert';

import '../settings.dart';
import 'skills.dart';

/// use_skill: the companion reads a skill's instructions before doing the
/// job, so only their names and descriptions take room in every prompt.
class SkillTools {
  SkillTools({required this.settings});

  final AppSettings Function() settings;

  static const useTool = 'use_skill';
  static const names = {useTool};

  static const definitions = <Map<String, Object?>>[
    {
      'type': 'function',
      'function': {
        'name': useTool,
        'description':
            'Read one of your skills (listed under "Your skills") before '
            'doing what it is for, then follow it.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'The skill\'s name, e.g. "weather".',
            },
          },
          'required': ['name'],
        },
      },
    },
  ];

  /// Runs one tool call and returns the JSON string sent back to the model.
  Future<String> call(String name, Map<String, Object?> args) async {
    try {
      final s = settings();
      final folder = s.companionFolder;
      if (folder == null) throw 'there is no folder yet';
      if (name != useTool) throw 'unknown tool $name';
      final wanted = Skills.idFrom('${args['name'] ?? ''}');
      final skills = await Skills.load(folder);
      final skill = skills.where((x) => x.id == wanted).firstOrNull;
      if (skill == null || !skill.on || skill.problem != null) {
        final on = [
          for (final x in skills)
            if (x.on && x.problem == null) x.id,
        ];
        throw skill == null
            ? 'there is no skill "$wanted". You have: ${on.join(', ')}.'
            : 'the skill "$wanted" is switched off. Your human can turn it '
                  'on in the Skills tab.';
      }
      return jsonEncode(Skills.forTool(skill, contextSize: s.contextSize));
    } catch (e) {
      return jsonEncode({'ok': false, 'error': '$e'});
    }
  }
}
