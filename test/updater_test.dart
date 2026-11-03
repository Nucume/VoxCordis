import 'dart:convert';
import 'dart:io';

import 'package:companion/services/runtime/download.dart';
import 'package:companion/services/updater.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('version order', () {
    expect(compareVersions('0.2.0', '0.1.9'), greaterThan(0));
    expect(compareVersions('0.1.10', '0.1.9'), greaterThan(0));
    expect(compareVersions('0.1.0', '0.1.0-dev.12'), greaterThan(0));
    expect(compareVersions('0.2.0-beta.2', '0.2.0-beta.1'), greaterThan(0));
    expect(compareVersions('0.2.0-beta.10', '0.2.0-beta.9'), greaterThan(0));
    expect(compareVersions('0.1.0', '0.1.0'), 0);
    expect(compareVersions('0.1.0', '0.1.0+3'), 0);
  });

  final release = {
    'tag_name': 'v0.2.0',
    'body': '**New:** updates',
    'html_url': 'https://github.com/x/y/releases/tag/v0.2.0',
    'assets': [
      {
        'name': 'VoxCordis-0.2.0-windows-x64-setup.exe',
        'browser_download_url':
            'https://github.com/x/y/releases/download/v0.2.0/setup.exe',
        'size': 30,
        'digest': 'sha256:${'cd' * 32}',
      },
      {
        'name': 'VoxCordis-0.2.0-x86_64.AppImage',
        'browser_download_url':
            'https://github.com/x/y/releases/download/v0.2.0/app.AppImage',
        'size': 40,
        'digest': 'sha256:${'ef' * 32}',
      },
    ],
  };

  test('picks the file for this kind of install', () {
    final linux = parseRelease(release, appImage: true, windows: false)!;
    expect(linux.version, '0.2.0');
    expect(
      linux.assetUrl,
      'https://github.com/x/y/releases/download/v0.2.0/app.AppImage',
    );
    expect(linux.assetSize, 40);
    final win = parseRelease(release, appImage: false, windows: true)!;
    expect(
      win.assetUrl,
      'https://github.com/x/y/releases/download/v0.2.0/setup.exe',
    );
    // A plain bundle (dev build) or macOS: release page only.
    final other = parseRelease(release, appImage: false, windows: false)!;
    expect(other.canInstall, isFalse);
    expect(other.pageUrl, endsWith('v0.2.0'));
  });

  test('takes the checksum GitHub lists, and only github.com files', () {
    final hex = 'ab' * 32;
    final withDigest = {
      ...release,
      'assets': [
        {
          ...(release['assets'] as List).last as Map<String, Object?>,
          'digest': 'sha256:$hex',
        },
      ],
    };
    expect(
      parseRelease(withDigest, appImage: true, windows: false)!.assetSha256,
      hex,
    );
    final elsewhere = {
      ...release,
      'assets': [
        {
          'name': 'VoxCordis-0.2.0-x86_64.AppImage',
          'browser_download_url': 'https://example.com/app.AppImage',
        },
      ],
    };
    expect(
      parseRelease(elsewhere, appImage: true, windows: false)!.canInstall,
      isFalse,
    );
  });

  test('a file without a checksum is never installed in one step', () {
    final noDigest = {
      ...release,
      'assets': [
        for (final a in release['assets'] as List)
          {...a as Map<String, Object?>}..remove('digest'),
      ],
    };
    final info = parseRelease(noDigest, appImage: true, windows: false)!;
    expect(info.assetUrl, isNotNull);
    expect(info.canInstall, isFalse);
  });

  test('a download that does not match its checksum is deleted', () async {
    final dir = await Directory.systemTemp.createTemp('sum');
    final f = File('${dir.path}/x');
    await f.writeAsString('hello');
    await verifySha256(
      f,
      '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
    );
    await expectLater(
      verifySha256(f, 'ab' * 32),
      throwsA(isA<HttpException>()),
    );
    expect(f.existsSync(), isFalse);
    await dir.delete(recursive: true);
  });

  test('check offers a newer release and ignores an older one', () async {
    Updater with_(String tag) => Updater(
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode({...release, 'tag_name': tag}), 200),
      ),
      environment: {'APPIMAGE': '/tmp/VoxCordis.AppImage'},
    );
    final newer = with_('v99.0.0');
    expect((await newer.check())?.version, '99.0.0');
    expect(newer.status, UpdateStatus.available);
    final older = with_('v0.0.1');
    expect(await older.check(), isNull);
    expect(older.status, UpdateStatus.upToDate);
  });

  test('a private or empty repository just reads as up to date', () async {
    final u = Updater(client: MockClient((_) async => http.Response('', 404)));
    expect(await u.check(), isNull);
    expect(u.status, UpdateStatus.upToDate);
  });

  test('a package install is told to use its package manager', () async {
    Updater pkg(String? type) => Updater(
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode({...release, 'tag_name': 'v99.0.0'}), 200),
      ),
      environment: const {},
      packageType: type,
    );
    final deb = pkg('deb');
    final info = await deb.check();
    // Nothing is downloaded or run by the app itself.
    expect(info?.canInstall, isFalse);
    expect(deb.packageUpdateCommand, contains('apt'));
    expect(pkg('rpm').packageUpdateCommand, contains('dnf'));
    expect(pkg(null).packageUpdateCommand, isNull);
  });

  test('the repository page follows the update repository', () {
    expect(
      Updater.packageRepoPage,
      'https://nucume.github.io/VoxCordisPR/repo/',
    );
  });

  test('leftover installers in the temporary folder are deleted', () async {
    final temp = Directory.systemTemp.createTempSync('upd');
    addTearDown(() => temp.deleteSync(recursive: true));
    File('${temp.path}/VoxCordis-0.3.7-setup.exe').writeAsStringSync('x');
    File('${temp.path}/VoxCordis-0.4.0-rc.1-setup.exe').writeAsStringSync('x');
    File('${temp.path}/other-setup.exe').writeAsStringSync('x');
    File('${temp.path}/VoxCordis-notes.txt').writeAsStringSync('x');

    await Updater.deleteLeftoverInstallers(temp: temp);

    final left = [for (final e in temp.listSync()) e.uri.pathSegments.last]
      ..sort();
    expect(left, ['VoxCordis-notes.txt', 'other-setup.exe']);
  });

  test('a failed install keeps the database open', () async {
    final dir = await Directory.systemTemp.createTemp('update');
    addTearDown(() => dir.delete(recursive: true));
    final appImage = '${dir.path}/VoxCordis.AppImage';
    // A folder where the AppImage should be: putting the new one there
    // fails after the download.
    await Directory('$appImage/in-use').create(recursive: true);
    final bytes = utf8.encode('the new version');
    final u = Updater(
      client: MockClient((_) async => http.Response.bytes(bytes, 200)),
      environment: {'APPIMAGE': appImage},
    );
    final info = UpdateInfo(
      version: '99.0.0',
      notes: '',
      pageUrl: '',
      assetUrl: 'https://github.com/x/y/VoxCordis-x86_64.AppImage',
      assetSize: bytes.length,
      assetSha256: sha256.convert(bytes).toString(),
    );
    final steps = <String>[];
    await u.install(
      info,
      beforeExit: () async => steps.add('stop the model server'),
      atExit: () async => steps.add('close the database'),
    );
    expect(u.status, UpdateStatus.failed);
    expect(u.error, startsWith('The update failed'));
    expect(steps, ['stop the model server']);
  });

  group('a finished install', () {
    final bytes = utf8.encode('the new version');
    final info = UpdateInfo(
      version: '99.0.0',
      notes: '',
      pageUrl: '',
      assetUrl: 'https://github.com/x/y/VoxCordis-x86_64.AppImage',
      assetSize: bytes.length,
      assetSha256: sha256.convert(bytes).toString(),
    );
    late List<String> steps;
    late String appImage;

    setUp(() async {
      steps = [];
      final dir = await Directory.systemTemp.createTemp('update');
      addTearDown(() => dir.delete(recursive: true));
      appImage = '${dir.path}/VoxCordis.AppImage';
      await File(appImage).writeAsString('the old version');
    });

    Updater updater({Map<String, String>? environment, Object? startFails}) =>
        Updater(
          client: MockClient((_) async => http.Response.bytes(bytes, 200)),
          environment: environment ?? {'APPIMAGE': appImage},
          start: (program, args) async {
            if (startFails != null) throw startFails;
            steps.add('start the new version');
          },
          quit: () => steps.add('quit'),
          failedStartPause: Duration.zero,
        );

    Future<void> install(Updater u) => u.install(
      info,
      beforeExit: () async => steps.add('stop the model server'),
      atExit: () async => steps.add('close the database'),
    );

    test('closes the database before the new AppImage starts', () async {
      final u = updater();
      await install(u);
      expect(steps, [
        'stop the model server',
        'close the database',
        'start the new version',
        'quit',
      ]);
      expect(await File(appImage).readAsString(), 'the new version');
    });

    test('quits when the new AppImage will not start', () async {
      final u = updater(startFails: 'no exec');
      await install(u);
      expect(steps, ['stop the model server', 'close the database', 'quit']);
      expect(u.status, UpdateStatus.installing);
      expect(u.error, contains('did not start'));
      expect(u.error, contains('open it again'));
    });

    test('closes the database once the Windows installer started', () async {
      final u = updater(environment: {});
      addTearDown(() async {
        final setup = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'VoxCordis-99.0.0-setup.exe',
        );
        if (await setup.exists()) await setup.delete();
      });
      await install(u);
      expect(steps, [
        'stop the model server',
        'start the new version',
        'close the database',
        'quit',
      ]);
    });
  });
}
