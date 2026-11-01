import 'package:companion/theme/app_theme.dart';
import 'package:companion/widgets/download_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(double? progress, {bool showText = true}) => MaterialApp(
    theme: ThemeData(extensions: [AppPalette.dark]),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          child: DownloadBar(progress: progress, showText: showText),
        ),
      ),
    ),
  );

  testWidgets('shows the percentage and waits before guessing a time', (
    tester,
  ) async {
    await tester.pumpWidget(host(0.42));
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('calculating…'), findsOneWidget);
  });

  testWidgets('an unknown size shows dots and no time', (tester) async {
    await tester.pumpWidget(host(null));
    expect(find.text('…'), findsOneWidget);
    expect(find.textContaining('left'), findsNothing);
  });

  testWidgets('showText false draws just the bar', (tester) async {
    await tester.pumpWidget(host(0.5, showText: false));
    expect(find.text('50%'), findsNothing);
  });
}
