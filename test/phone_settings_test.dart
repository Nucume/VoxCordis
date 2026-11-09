import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/phone/phone_settings.dart';
import 'package:companion/services/phone/phone_firewall.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:companion/services/secret_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('turns phone access on and shows a pairing code', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    PhoneSettings.findAddresses = ({bool tailscale = false}) async => [
      '192.168.1.20',
    ];
    var opened = false;
    PhoneSettings.checkFirewall = (port) async =>
        FirewallState(FirewallKind.firewalld, open: opened);
    final ran = <List<String>>[];
    PhoneFirewall.run = (exe, args) async {
      ran.add([exe, ...args]);
      opened = true;
      return ProcessResult(0, 0, '', '');
    };
    addTearDown(() => PhoneFirewall.run = Process.run);
    final dir = Directory.systemTemp.createTempSync('phone_settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    late AppServices services;
    await tester.runAsync(() async {
      final key = DatabaseKey(
        dir,
        secrets: SecretStore(
          Directory(p.join(dir.path, 'secrets')),
          system: false,
        ),
      );
      await key.unlock();
      services = AppServices(
        settings: SettingsStore(
          File(p.join(dir.path, 'settings.json')),
          AppSettings(companionName: 'Aria', keepRunning: true),
        ),
        db: await openAppDatabase(
          AppServices.companionDbPath(dir.path, null),
          key: key.value,
        ),
        runtime: RuntimeController(dir),
        dbKey: key,
      );
    });

    await tester.pumpWidget(
      AppScope(
        services: services,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: PhoneSettings())),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.text('Let my phone use VoxCordis'), findsOneWidget);
    expect(find.text('Pair a phone'), findsNothing);

    await tester.tap(find.text('Let my phone use VoxCordis'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(services.settings.value.phoneAccess, isTrue);
    expect(find.text('http://192.168.1.20:47800/'), findsOneWidget);

    // The firewall keeps phones out until it is opened, once.
    expect(find.text('Let phones through'), findsOneWidget);
    await tester.tap(find.text('Let phones through'));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(ran.single.first, 'pkexec');
    expect(services.settings.value.phoneFirewallPort, 47800);
    expect(
      find.text('Phones on your home network get through the firewall'),
      findsOneWidget,
    );

    await tester.tap(find.text('Pair a phone'));
    await tester.pump();
    final code = services.phone.devices.code!;
    expect(code.live, isTrue);
    expect(find.text('Pairing is open'), findsOneWidget);
    final qr = tester.widget<CustomPaint>(
      find.byWidgetPredicate((w) => w is CustomPaint && w.painter is QrPainter),
    );
    expect(
      (qr.painter! as QrPainter).data,
      'http://192.168.1.20:47800/#${code.fragment}',
    );

    // Leaving the page drops a code nobody scanned.
    await tester.pumpWidget(const SizedBox());
    expect(services.phone.devices.code, isNull);
  });
}
