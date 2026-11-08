import 'package:flutter_test/flutter_test.dart';

import 'package:companion/features/voces/story_text.dart';

String show(String line) => [
  for (final r in storyRuns(line))
    r.bold && r.italic
        ? '<bi>${r.text}</bi>'
        : r.bold
        ? '<b>${r.text}</b>'
        : r.italic
        ? '<i>${r.text}</i>'
        : r.text,
].join();

void main() {
  test('actions, bold and both', () {
    expect(show('*waves* "Hi"'), '<i>waves</i> "Hi"');
    expect(show('It says **stop** here'), 'It says <b>stop</b> here');
    expect(show('***Run.***'), '<bi>Run.</bi>');
  });

  test('bold inside an action', () {
    expect(
      show('*The label: **"OWN YOURS."** No name.*'),
      '<i>The label: </i><bi>"OWN YOURS."</bi><i> No name.</i>',
    );
    expect(show('*reads **this***'), '<i>reads </i><bi>this</bi>');
  });

  test('lone asterisks stay', () {
    expect(show('5 * 3 = 15'), '5 * 3 = 15');
    expect(show('*sighs'), '*sighs');
    expect(show('a **b* c'), 'a **b* c');
  });
}
