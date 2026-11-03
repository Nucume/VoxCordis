import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:companion/features/images/animate_dialog.dart';
import 'package:companion/services/images/image_catalog.dart';
import 'package:companion/services/runtime/gpu_info.dart';
import 'package:companion/theme/app_theme.dart';

void main() {
  for (final width in [820.0, 1240.0]) {
    testWidgets('the Animate dialog fits a ${width.round()} px window', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(const Color(0xFF8B7CF6)),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<AnimateChoice>(
                  context: context,
                  builder: (_) => AnimateDialog(
                    models: ImageCatalog.videoModels,
                    picture: File('assets/brand/app_icon.png'),
                    gpu: const GpuInfo(name: 'Test card', memoryGb: 16),
                    writePrompt: (idea, model, seconds) async =>
                        'A long, careful prompt about $idea.',
                  ),
                ),
                child: const Text('Animate'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Animate'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Written for them, so "Back to mine" joins the buttons.
      await tester.enterText(find.byType(TextField), 'she smiles');
      await tester.pump();
      await tester.tap(find.text('Write it for me'));
      await tester.pumpAndSettle();
      expect(find.text('Back to mine'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
