import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:companion/data/settings.dart';
import 'package:companion/features/settings/settings_tabs.dart';
import 'package:companion/theme/app_theme.dart';

void main() {
  Future<void> show(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(const Color(0xFF8B7CF6)),
        home: Scaffold(
          body: DefaultTabController(
            length: 9,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: SettingsTabBar(
                layout: SettingsTabs.top,
                pages: [
                  for (final n in [
                    'General',
                    'Appearance',
                    'Images',
                    'Brain',
                    'Computer',
                    'Internet',
                    'Privacy',
                    'Logs',
                    'About',
                  ])
                    (label: n, icon: Icons.tune_rounded),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double shown(WidgetTester tester, IconData icon) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  testWidgets('arrows show on the side the cut tabs are, and move them', (
    tester,
  ) async {
    await show(tester, 600);
    expect(shown(tester, Icons.chevron_left_rounded), 0);
    expect(shown(tester, Icons.chevron_right_rounded), 1);

    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();
    expect(shown(tester, Icons.chevron_left_rounded), 1);

    // Along to the end, where only the way back is left.
    for (var i = 0; i < 4; i++) {
      if (shown(tester, Icons.chevron_right_rounded) == 0) break;
      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.pumpAndSettle();
    }
    expect(shown(tester, Icons.chevron_right_rounded), 0);
    expect(find.text('About'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_left_rounded));
    await tester.pumpAndSettle();
    expect(shown(tester, Icons.chevron_right_rounded), 1);
  });

  testWidgets('no arrows when every tab fits', (tester) async {
    await show(tester, 1400);
    expect(shown(tester, Icons.chevron_left_rounded), 0);
    expect(shown(tester, Icons.chevron_right_rounded), 0);
  });
}
