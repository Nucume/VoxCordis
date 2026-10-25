import 'package:companion/features/setup/character_pickers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('pronoun presets fill in the pronouns', (tester) async {
    var value = 'she/her';
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => _host(
          PronounPicker(
            value: value,
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Male'));
    await tester.pump();
    expect(value, 'he/him');

    await tester.tap(find.text('Other'));
    await tester.pump();
    expect(value, 'it/its');
    await tester.enterText(find.byType(TextField), 'xe/xem');
    expect(value, 'xe/xem');
  });

  testWidgets('traits stop at five', (tester) async {
    var traits = <String>[];
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => _host(
          TraitPicker(
            value: traits,
            onChanged: (v) => setState(() => traits = v),
          ),
        ),
      ),
    );
    for (final t in ['Warm', 'Witty', 'Flirty', 'Gamer', 'Calm', 'Bold']) {
      // The group chip; once picked, the trait also shows in the chosen list.
      await tester.ensureVisible(find.text(t).last);
      await tester.tap(find.text(t).last);
      await tester.pump();
    }
    expect(traits, ['warm', 'witty', 'flirty', 'gamer', 'calm']);
    expect(find.text('5 of 5'), findsOneWidget);

    // Unselecting frees a slot.
    // Remove it from the chosen list at the top.
    await tester.ensureVisible(find.byTooltip('Remove').first);
    await tester.tap(find.byTooltip('Remove').first);
    await tester.pump();
    expect(traits, hasLength(4));
  });

  testWidgets('an imported character keeps up to twenty', (tester) async {
    var traits = [for (var i = 0; i < 12; i++) 'tag$i'];
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => _host(
          TraitPicker(
            value: traits,
            max: 20,
            onChanged: (v) => setState(() => traits = v),
          ),
        ),
      ),
    );
    expect(find.text('12 of 20'), findsOneWidget);
    await tester.ensureVisible(find.text('Warm').last);
    await tester.tap(find.text('Warm').last);
    await tester.pump();
    expect(traits, hasLength(13));
  });
}
