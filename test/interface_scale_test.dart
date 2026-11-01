import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:companion/shell/interface_scale.dart';

void main() {
  test('never goes bigger than the window has room for', () {
    expect(InterfaceScale.effective(const Size(1140, 720), 1.5), 1.0);
    expect(InterfaceScale.effective(const Size(2280, 1440), 1.5), 1.5);
    expect(InterfaceScale.effective(const Size(1710, 720), 1.2), 1.0);
  });

  test('shrinks to fit a window under the design size', () {
    expect(InterfaceScale.effective(const Size(960, 540), 1.0), 0.75);
    expect(InterfaceScale.effective(const Size(960, 540), 0.8), 0.75);
  });

  testWidgets('lays out at the scaled size and keeps taps working', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.reset);
    Size? seen;
    var taps = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(1920, 1080)),
          child: InterfaceScale(
            scale: 1.5,
            child: Builder(
              builder: (context) {
                seen = MediaQuery.sizeOf(context);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                  child: const SizedBox.expand(),
                );
              },
            ),
          ),
        ),
      ),
    );
    expect(seen, const Size(1280, 720));
    await tester.tapAt(const Offset(1900, 1000));
    expect(taps, 1);
  });
}
