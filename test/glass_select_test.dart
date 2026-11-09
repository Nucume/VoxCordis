import 'package:companion/theme/app_theme.dart';
import 'package:companion/theme/glass_popover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a picker with a single option opens and picks', (tester) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(const Color(0xFF8B7CF6)),
        home: Scaffold(
          body: Center(
            child: GlassSelect<String?>(
              value: null,
              placeholder: 'Pick a world',
              options: const [GlassOption('a', 'The only world')],
              onChanged: (v) => picked = v,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Pick a world'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('The only world'));
    await tester.pumpAndSettle();
    expect(picked, 'a');
  });
}
