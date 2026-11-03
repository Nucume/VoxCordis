import 'dart:io';

import 'package:companion/app_scope.dart';
import 'package:companion/data/database.dart';
import 'package:companion/data/database_key.dart';
import 'package:companion/data/message_repository.dart';
import 'package:companion/data/settings.dart';
import 'package:companion/features/chat/chat_controller.dart';
import 'package:companion/features/chat/chat_screen.dart';
import 'package:companion/services/runtime/runtime_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A chat whose state the test sets by hand, and that keeps lessons in
/// memory instead of on the desk.
class _Chat extends ChatController {
  _Chat(super.services);

  final kept = <String?>[];

  @override
  Future<String?> keepLesson({String? rule}) async {
    kept.add(rule);
    return null;
  }

  void changed() => notifyListeners();
}

final _reply = ChatMessage(
  id: 'a1',
  ts: DateTime(2026, 11, 2, 10),
  role: 'assistant',
  content: 'Well, there are many teas.',
);

Future<_Chat> _pumpChat(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final dir = Directory.systemTemp.createTempSync('reply_edit');
  addTearDown(() => dir.deleteSync(recursive: true));
  late AppServices services;
  await tester.runAsync(() async {
    services = AppServices(
      settings: SettingsStore(
        File('${dir.path}/settings.json'),
        AppSettings(companionName: 'Aria', userName: 'Haru'),
      ),
      db: await openAppDatabase(inMemoryDatabasePath),
      dbKey: DatabaseKey(dir),
      runtime: RuntimeController(dir),
    );
  });
  final chat = _Chat(services);
  chat.messages.addAll([
    ChatMessage(
      id: 'u1',
      ts: DateTime(2026, 11, 2, 10),
      role: 'user',
      content: 'Which tea should I try?',
    ),
    _reply,
  ]);
  await tester.pumpWidget(
    AppScope(
      services: services,
      child: MaterialApp(
        home: Scaffold(body: ChatScreen(chat: chat)),
      ),
    ),
  );
  await tester.pump();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => services.db.close());
  });
  return chat;
}

void main() {
  testWidgets('an edit being typed survives a reply that starts meanwhile', (
    tester,
  ) async {
    final chat = await _pumpChat(tester);
    await tester.tap(find.byTooltip('Edit'));
    await tester.pump();
    final editor = find.widgetWithText(TextField, _reply.content);
    expect(editor, findsOneWidget);
    await tester.enterText(editor, 'Try genmaicha.');
    await tester.pump();

    Finder save() => find.widgetWithText(FilledButton, 'Save');

    // A reminder comes due: the edit waits, it isn't thrown away.
    chat.busy = true;
    chat.changed();
    await tester.pump();
    expect(find.widgetWithText(TextField, 'Try genmaicha.'), findsOneWidget);
    expect(tester.widget<FilledButton>(save()).onPressed, isNull);

    chat.busy = false;
    chat.changed();
    await tester.pump();
    expect(find.widgetWithText(TextField, 'Try genmaicha.'), findsOneWidget);
    expect(tester.widget<FilledButton>(save()).onPressed, isNotNull);
  });

  testWidgets('Enter on a lesson waits for the last typed letter', (
    tester,
  ) async {
    final chat = await _pumpChat(tester);
    chat.lessonOffer = LessonOffer(
      messageId: _reply.id,
      rule: 'Keep replies short and direct',
      why: 'Haru likes it brief',
    );
    chat.changed();
    await tester.pump();
    final field = find.widgetWithText(
      TextField,
      'Keep replies short and direct',
    );
    expect(field, findsOneWidget);
    await tester.showKeyboard(field);
    await tester.enterText(field, 'Keep replies shor');

    // Enter arrives before the input method hands over the last letter.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'Keep replies short',
        selection: TextSelection.collapsed(offset: 18),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(chat.kept, ['Keep replies short']);
  });
}
