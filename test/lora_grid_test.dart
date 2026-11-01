import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:companion/features/images/lora_grid.dart';

void main() {
  testWidgets('picking a LoRA opens its slider, picking again closes it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final picked = <String, double>{};
    const loras = [
      (name: 'film-grain', note: 'Adds grain'),
      (name: 'watercolor', note: ''),
      (name: 'detail-tweaker', note: ''),
      (name: 'pixel-art', note: ''),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 940,
              child: StatefulBuilder(
                builder: (context, setState) => LoraGrid(
                  loras: loras,
                  picked: picked,
                  onChanged: (name, weight) => setState(
                    () => weight == null
                        ? picked.remove(name)
                        : picked[name] = weight,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Four across at this width, all on one row.
    final ys = {
      for (final l in loras)
        tester.getTopLeft(find.byKey(ValueKey('lora-${l.name}'))).dy,
    };
    expect(ys, hasLength(1));
    Slider slider(String name) => tester.widget<Slider>(
      find.descendant(
        of: find.byKey(ValueKey('lora-$name')),
        matching: find.byType(Slider),
      ),
    );
    double height(String name) =>
        tester.getSize(find.byKey(ValueKey('lora-$name'))).height;
    expect(slider('watercolor').onChanged, isNull);
    final before = height('watercolor');

    await tester.tap(find.text('watercolor'));
    await tester.pumpAndSettle();
    expect(picked, {'watercolor': LoraGrid.start});
    expect(slider('watercolor').onChanged, isNotNull);
    expect(slider('film-grain').onChanged, isNull);
    expect(find.text('0.8'), findsOneWidget);
    // The slider had its room all along: nothing grows or moves.
    expect(height('watercolor'), before);
    expect(height('film-grain'), before);

    await tester.drag(
      find.descendant(
        of: find.byKey(const ValueKey('lora-watercolor')),
        matching: find.byType(Slider),
      ),
      const Offset(400, 0),
    );
    await tester.pumpAndSettle();
    expect(picked['watercolor'], 2);
    expect(find.text('2.0'), findsOneWidget);

    await tester.tap(find.text('watercolor'));
    await tester.pumpAndSettle();
    expect(picked, isEmpty);
    expect(slider('watercolor').onChanged, isNull);
  });
}
