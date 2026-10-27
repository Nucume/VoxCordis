import 'dart:io';

import 'package:companion/data/database.dart';
import 'package:companion/services/logs/app_log.dart';
import 'package:companion/services/web/headless_browser.dart';
import 'package:companion/services/web/web_guard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Drives a real Chromium. Runs only with VOXCORDIS_TEST_BROWSER set to a
/// Chrome or Chromium executable, e.g.
/// `VOXCORDIS_TEST_BROWSER=/usr/bin/chromium flutter test test/headless_browser_test.dart`.
void main() {
  final exe = Platform.environment['VOXCORDIS_TEST_BROWSER'];
  final skip = exe == null || !File(exe).existsSync()
      ? 'Set VOXCORDIS_TEST_BROWSER to a Chromium to run'
      : null;

  late Directory tmp;
  late HttpServer site;
  late Database db;
  late AppLog log;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vc_browser');
    db = await openAppDatabase(inMemoryDatabasePath);
    log = AppLog(db: () => db, enabled: (_) => true);
    site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    site.listen((req) {
      req.response.headers.contentType = ContentType.html;
      req.response.write(switch (req.uri.path) {
        '/alert' =>
          '<html><body><p>Before</p><script>alert("hi"); '
              'document.body.insertAdjacentHTML("beforeend", "<p>After</p>")'
              '</script></body></html>',
        _ =>
          '<html><title>Tea</title><body><main><p>Genmaicha is a '
              'green tea.</p><a href="/alert" target="_blank">More</a></main>'
              '</body></html>',
      });
      req.response.close();
    });
  });

  tearDown(() async {
    await site.close(force: true);
    await db.close();
    await tmp.delete(recursive: true);
  });

  HeadlessBrowser browser() => HeadlessBrowser(
    tmp,
    findInstalled: () async => exe,
    resolvesPublic: (_) async => true,
  )..log = log;

  // The test site is on this computer, which the companion may never visit.
  const guard = _AllowAll();
  Future<BrowserPage> open(HeadlessBrowser b, String path) =>
      b.open(Uri.parse('http://127.0.0.1:${site.port}$path'), guard);

  test(
    'starts again over a browser left running before',
    () async {
      final first = browser();
      expect((await open(first, '/')).text, contains('Genmaicha'));
      // VoxCordis "crashes": the first browser is never closed. A new
      // session's browser must take over its profile.
      final second = browser();
      final page = await open(second, '/');
      expect(page.title, 'Tea');
      await second.close();
      final text = await log.asText(kinds: {LogKind.browser});
      expect(text, contains('left running by an earlier session'));
      await first.close();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'dismisses pop-up dialogs instead of hanging',
    () async {
      final b = browser();
      final page = await open(b, '/alert');
      expect(page.text, contains('After'));
      final more = await open(b, '/');
      // A link to a new tab opens in the same page.
      final link = more.elements.firstWhere((e) => e.label == 'More');
      expect((await b.click(link.ref, guard)).text, contains('After'));
      await b.close();
      expect(
        await log.asText(kinds: {LogKind.browser}),
        contains('pop-up (alert); dismissed it'),
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

class _AllowAll extends WebGuard {
  const _AllowAll();

  @override
  String? refuse(Uri url) => null;
}
