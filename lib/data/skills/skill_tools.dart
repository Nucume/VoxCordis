import 'dart:convert';

import '../settings.dart';
import 'skills.dart';

/// The companion's skill tools: use_skill reads a skill's instructions
/// before doing the job, so only names and descriptions take room in every
/// prompt; switch_skill keeps the ones it needs at hand; write_skill writes
/// a new one, which waits for the human's OK.
class SkillTools {
  SkillTools({required this.settings});

  final AppSettings Function() settings;

  static const useTool = 'use_skill';
  static const switchTool = 'switch_skill';
  static const writeTool = 'write_skill';
  static const names = {useTool, switchTool, writeTool};

  static const _name = {
    'type': 'string',
    'description': 'The skill\'s name, e.g. "weather".',
  };

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
          'properties': {'name': _name},
          'required': ['name'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': switchTool,
        'description':
            'Turn one of your skills on, so it is offered to you whenever it '
            'fits, or off, to keep your list short. At most ${Skills.maxOn} '
            'can be on at once.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': _name,
            'on': {'type': 'boolean', 'description': 'true for on.'},
          },
          'required': ['name', 'on'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': writeTool,
        'description':
            'Write down how to do a job as a skill of your own, or improve '
            'one you have. A new skill waits for your human to turn it on.',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description':
                  'Short, small letters and dashes, e.g. "plant-care".',
            },
            'description': {
              'type': 'string',
              'description':
                  'One line: what the skill is for and when to use it.',
            },
            'instructions': {
              'type': 'string',
              'description':
                  'The steps and know-how, in Markdown, as you will want to '
                  'read them next time.',
            },
          },
          'required': ['name', 'description', 'instructions'],
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
      if (!names.contains(name)) throw 'unknown tool $name';
      if (name == writeTool) {
        final id = Skills.idFrom('${args['name'] ?? ''}');
        final problem = await Skills.write(
          folder,
          id: id,
          description: '${args['description'] ?? ''}',
          body: '${args['instructions'] ?? ''}',
        );
        if (problem != null) throw problem;
        final skill = (await Skills.load(folder)).firstWhere((x) => x.id == id);
        return jsonEncode({
          'ok': true,
          'skill': id,
          'note': skill.review
              ? 'Saved. It waits for your human to read it and turn it on in '
                    'the Skills tab, so tell them about it.'
              : 'Saved.',
        });
      }
      final wanted = Skills.idFrom('${args['name'] ?? ''}');
      final skills = await Skills.load(folder);
      final skill = skills.where((x) => x.id == wanted).firstOrNull;
      if (skill == null) {
        throw 'there is no skill "$wanted". You have: '
            '${[for (final x in skills)
              if (x.problem == null && !x.review) x.id].join(', ')}.';
      }
      if (skill.problem != null) throw skill.problem!;
      if (skill.review) {
        throw 'the skill "$wanted" waits for your human\'s OK. They can turn '
            'it on in the Skills tab.';
      }
      if (name == useTool) {
        return jsonEncode({
          ...Skills.forTool(skill, contextSize: s.contextSize),
          if (!skill.on)
            'note':
                'This skill is off. If you will need it again, turn it on '
                'with $switchTool.',
        });
      }
      final on = args['on'] != false && args['on'] != 'false';
      if (skill.always) {
        throw '${skill.displayTitle} shapes every reply, so only your human '
            'turns it on or off, in the Skills tab.';
      }
      if (skill.on == on) {
        return jsonEncode({
          'ok': true,
          'note': 'It was ${on ? 'on' : 'off'} already.',
        });
      }
      if (await Skills.setOn(folder, wanted, on) != null) {
        throw '${Skills.maxOn} skills are on, the most at once. Turn one '
            'off first: ${[for (final x in skills)
              if (x.on && !x.always) x.id].join(', ')}.';
      }
      return jsonEncode({'ok': true, 'on': on});
    } catch (e) {
      return jsonEncode({'ok': false, 'error': '$e'});
    }
  }
}
