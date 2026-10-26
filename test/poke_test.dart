import 'package:companion/data/message_repository.dart';
import 'package:companion/services/schedule/poke.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _m(String role, DateTime ts, {String via = 'app'}) =>
    ChatMessage(id: '$ts$role', ts: ts, role: role, content: 'x', via: via);

void main() {
  final noon = DateTime(2026, 10, 26, 12);
  final morning = DateTime(2026, 10, 26, 8, 30);

  test('due after the quiet spell, in the daytime', () {
    final talk = [_m('user', morning), _m('assistant', morning)];
    expect(Poke.due(talk, noon, 3), isTrue);
    expect(Poke.due(talk, noon, 4), isFalse);
    expect(Poke.due(talk, noon, 0), isFalse);
    expect(Poke.due(talk, DateTime(2026, 10, 26, 23, 30), 3), isFalse);
    expect(Poke.due(talk, DateTime(2026, 10, 27, 7), 3), isFalse);
  });

  test('never before the human wrote; once, unless it repeats', () {
    final early = DateTime(2026, 10, 25, 9);
    expect(Poke.due([_m('assistant', early)], noon, 3), isFalse);
    final talk = [_m('user', early)];
    expect(Poke.due(talk, noon, 3), isTrue);
    final poked = [...talk, _m('assistant', early, via: Poke.via)];
    expect(Poke.due(poked, noon, 3), isFalse);
    expect(Poke.due(poked, noon, 3, repeat: true), isTrue);
    expect(Poke.due([...poked, _m('user', early)], noon, 3), isTrue);
  });

  test('quiet hours are the human\'s, across midnight or not', () {
    expect(Poke.quiet(23, 22, 7), isTrue);
    expect(Poke.quiet(6, 22, 7), isTrue);
    expect(Poke.quiet(12, 22, 7), isFalse);
    expect(Poke.quiet(13, 12, 14), isTrue);
    expect(Poke.quiet(14, 12, 14), isFalse);
    expect(Poke.quiet(3, 5, 5), isFalse);
    final talk = [_m('user', morning)];
    final night = DateTime(2026, 10, 27, 2);
    expect(Poke.due(talk, night, 3), isFalse);
    expect(Poke.due(talk, night, 3, quietFrom: 0, quietUntil: 0), isTrue);
  });

  test('ideas follow the tools', () {
    expect(Poke.ideasFor({}), [PokeIdea.message, PokeIdea.muse]);
    expect(
      Poke.ideasFor({'web_search', 'generate_image'}),
      containsAll([PokeIdea.rabbitHole, PokeIdea.picture]),
    );
    expect(
      Poke.note(PokeIdea.muse, 'Sam', const Duration(hours: 50)),
      contains('quiet for 2 days'),
    );
  });
}
