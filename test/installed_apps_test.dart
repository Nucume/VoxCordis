import 'dart:convert';
import 'dart:io';

import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/prompt_history.dart';
import 'package:companion/services/system/installed_apps.dart';
import 'package:companion/services/system/system_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _apps = [
  InstalledApp(name: 'Vivaldi', id: 'vivaldi-stable.desktop'),
  InstalledApp(name: 'Google Chrome', id: 'google-chrome.desktop'),
  InstalledApp(name: 'Files', id: 'org.gnome.Nautilus.desktop'),
  InstalledApp(name: 'Steam', id: 'steam.desktop'),
  InstalledApp(name: 'Steam Link', id: 'com.valvesoftware.SteamLink.desktop'),
  InstalledApp(
    name: 'Calculator',
    id: 'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App',
  ),
];

void main() {
  test('apps are found by the name people use', () {
    InstalledApp? find(String q, {bool strict = false}) =>
        InstalledApps.best(_apps, q, strict: strict);
    expect(find('vivaldi')?.name, 'Vivaldi');
    expect(find('Chrome')?.name, 'Google Chrome');
    expect(find('nautilus')?.name, 'Files');
    expect(find('steam')?.name, 'Steam');
    expect(find('windowscalculator')?.name, 'Calculator');
    expect(find('viv')?.name, isNull); // too short
    expect(find('vival')?.name, 'Vivaldi');
    expect(find('vival', strict: true), isNull);
    expect(find('the door', strict: true), isNull);
  });

  test('desktop files are read as the menu shows them', () {
    final app = InstalledApps.parseDesktopFile(
      'vivaldi-stable.desktop',
      '/usr/share/applications/vivaldi-stable.desktop',
      '[Desktop Entry]\nType=Application\nName=Vivaldi\n'
          'Name[de]=Vivaldi\nExec=/usr/bin/vivaldi-stable %U\n'
          '[Desktop Action new-window]\nName=New Window\nExec=x --new\n',
    );
    expect(app?.name, 'Vivaldi');
    expect(app?.exec, '/usr/bin/vivaldi-stable %U');
    expect(
      InstalledApps.parseDesktopFile(
        'x.desktop',
        '/x.desktop',
        '[Desktop Entry]\nType=Application\nName=X\nExec=x\nNoDisplay=true\n',
      ),
      isNull,
    );
    expect(InstalledApps.execArgs('"/opt/My App/run" --flag %f %%x'), [
      '/opt/My App/run',
      '--flag',
      '%x',
    ]);
  });

  test('everyday requests to start an app are spotted', () {
    expect(requestedApp('Open Vivaldi please'), ['Vivaldi']);
    expect(requestedApp('can you launch steam for me?'), ['steam']);
    expect(requestedApp('could you open up the Vivaldi browser'), [
      'Vivaldi browser',
      'Vivaldi',
    ]);
    expect(requestedApp('open up to me, how was your day?'), isEmpty);
    expect(requestedApp('*smiles* tell me about it'), isEmpty);
    expect(requestedApp('open your heart'), isEmpty);
  });

  test('open starts an installed app by its name', () async {
    final dir = await Directory.systemTemp.createTemp('apps');
    addTearDown(() => dir.delete(recursive: true));
    final started = <InstalledApp>[];
    final tools = SystemTools(
      settings: () => AppSettings(
        companionFolder: p.join(dir.path, 'Mira'),
        systemAccess: true,
      ),
      logFile: File(p.join(dir.path, 'system-access.log')),
      allowAlways: (_) async {},
      apps: InstalledApps(list: () async => _apps),
      startApp: (a) async => started.add(a),
      knownFolder: (_) async => null,
    )..ask = (_) async => SystemApproval.once;

    var r = jsonDecode(
      await tools.call('open', {'target': 'Vivaldi', 'why': 'asked'}),
    );
    expect(r['ok'], isTrue);
    expect(started.single.id, 'vivaldi-stable.desktop');

    r = jsonDecode(
      await tools.call('open', {'target': 'Nothing Here', 'why': 'x'}),
    );
    expect(r['ok'], isFalse);
    expect(r['error'], contains('does not exist'));
    expect(
      File(p.join(dir.path, 'system-access.log')).readAsStringSync(),
      contains('started Vivaldi'),
    );
  });
}
