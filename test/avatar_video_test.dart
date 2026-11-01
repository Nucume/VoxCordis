import 'package:companion/services/avatar_video.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(AvatarVideo.channel, null));

  test('no video plugin means videos play outside the app', () async {
    // Nothing answers the channel, as when the runner couldn't load it.
    expect(await AvatarVideo.pluginLoaded(), isFalse);
  });

  test('a loaded video plugin is found', () async {
    MethodCall? asked;
    messenger.setMockMethodCallHandler(AvatarVideo.channel, (call) async {
      asked = call;
      return null;
    });
    expect(await AvatarVideo.pluginLoaded(), isTrue);
    expect(asked?.method, 'VideoOutputManager.Dispose');
  });
}
