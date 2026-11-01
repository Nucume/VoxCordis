import 'dart:io';

import 'package:companion/services/import/soulkyn_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  final png = [0x89, 0x50, 0x4E, 0x47, ...List.filled(60, 1)];
  final mp4 = [0, 0, 0, 0x20, ...'ftypisom'.codeUnits, ...List.filled(60, 2)];

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('sk-media'));
  tearDown(() => dir.delete(recursive: true));

  test('fromApi reads gallery and video lists as Soulkyn sends them', () {
    const pic = '65803750-b15b-4139-8b4d-58733f089b44';
    const moving = '6581c402-b413-4ff8-b43d-5f4524391f3e';
    const movingVideo = '8fda1b7e-0000-4000-8000-000000000001';
    const video = 'e84bc0e3-c522-46af-b8bd-aae16185aabd';
    const poster = '96635bda-f3ec-430d-9ef7-e6dd091ea7e3';
    final images = SoulkynMedia.fromApi('Images', [
      {'FWSUUID': pic, 'ImageURL': pic, 'IsNSFW': false},
      {'FWSUUID': moving, 'IsNSFW': true, 'VideoFwsUUID': movingVideo},
      {'FWSUUID': 'aaaaaaaa-1', 'IsLocked': true},
      {'FWSUUID': '../../etc/passwd'},
      'junk',
    ]);
    final videos = SoulkynMedia.fromApi('Videos', [
      {
        'VideoFwsUUID': video,
        'LightVersion': '72ade2f5-80c4-4fad-b917-4550a3bc2ca6',
        'NSFW': true,
        'Image': {'FWSUUID': poster},
      },
    ]);
    final all = SoulkynMedia.unique([...images, ...videos, ...videos]);
    expect(all.map((m) => '${m.id}:${m.video}:${m.nsfw}'), [
      '$pic:false:false',
      '$moving:false:true',
      '$movingVideo:true:true',
      'etcpasswd:false:false',
      '$video:true:true',
    ]);
    expect(all[0].url.toString(), 'https://rub.soulkyn.io/$pic');
    expect(all[2].url.toString(), 'https://rub.soulkyn.io/$movingVideo.mp4');
    expect(all[2].poster!.path, '/$moving/scale_ratio~400x1000@q~85.webp');
    expect(all[4].poster!.path, startsWith('/$poster/'));
  });

  test(
    'saves pictures and videos, skips saved ones and rejects others',
    () async {
      final client = MockClient((r) async {
        final body = switch (r.url.path) {
          '/pic' => png,
          '/vid.mp4' => mp4,
          _ => '<html>nope</html>'.codeUnits,
        };
        return http.Response.bytes(body, 200);
      });
      final items = [
        SoulkynMedia(id: 'pic', url: Uri.parse('https://rub.soulkyn.io/pic')),
        SoulkynMedia(
          id: 'vid',
          url: Uri.parse('https://rub.soulkyn.io/vid.mp4'),
          video: true,
          poster: Uri.parse('https://rub.soulkyn.io/pic'),
        ),
        SoulkynMedia(id: 'bad', url: Uri.parse('https://rub.soulkyn.io/bad')),
        // A picture the page said was a video.
        SoulkynMedia(
          id: 'pic2',
          url: Uri.parse('https://rub.soulkyn.io/pic'),
          video: true,
        ),
      ];
      final first = await SoulkynMediaDownload(
        client: client,
      ).saveAll(items, dir);
      expect((first.saved, first.failed, first.skipped), (2, 2, 0));
      final names = dir.listSync().map((e) => p.basename(e.path)).toList()
        ..sort();
      expect(names, ['.posters', 'soulkyn-pic.png', 'soulkyn-vid.mp4']);
      final video = File(p.join(dir.path, 'soulkyn-vid.mp4'));
      expect(
        p.basename(SoulkynMediaDownload.posterFor(video)!.path),
        'soulkyn-vid.png',
      );

      final again = await SoulkynMediaDownload(
        client: client,
      ).saveAll(items.take(2).toList(), dir);
      expect((again.saved, again.skipped), (0, 2));
    },
  );

  test('a redirect off Soulkyn is refused', () async {
    final client = MockClient(
      (r) async => http.Response(
        '',
        302,
        headers: {'location': 'https://evil.example/x'},
      ),
    );
    final done = await SoulkynMediaDownload(client: client).saveAll([
      SoulkynMedia(id: 'r', url: Uri.parse('https://rub.soulkyn.io/r')),
    ], dir);
    expect(done.failed, 1);
    expect(dir.listSync(), isEmpty);
  });
}
