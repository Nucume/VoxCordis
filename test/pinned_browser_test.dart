import 'package:companion/services/web/headless_browser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every pinned browser download has a SHA-256', () {
    expect(HeadlessBrowser.pinnedShells.keys, [
      'win64',
      'linux64',
      'mac-arm64',
      'mac-x64',
    ]);
    for (final sha in HeadlessBrowser.pinnedShells.values) {
      expect(sha, matches(RegExp(r'^[0-9a-f]{64}$')));
    }
    expect(
      HeadlessBrowser.pinnedVersion,
      matches(RegExp(r'^\d+\.\d+\.\d+\.\d+$')),
    );
  });
}
