import 'package:companion/features/system/calendar_approval.dart';
import 'package:companion/features/system/system_approval.dart';
import 'package:companion/features/system/web_approval.dart';
import 'package:companion/services/calendar/calendar_event.dart';
import 'package:companion/services/calendar/calendar_tools.dart';
import 'package:companion/services/system/system_tools.dart';
import 'package:companion/services/web/web_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens the dialog [ask] shows and gives its answer once it closes.
Future<Future<T>> _open<T>(
  WidgetTester tester,
  Future<T> Function(BuildContext context) ask,
) async {
  late Future<T> answer;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => answer = ask(context),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return answer;
}

Future<void> _press(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  const command = SystemRequest(
    tool: SystemRequest.runTool,
    target: 'ls ~/Pictures',
    why: 'To see what is there',
  );

  testWidgets('a command can be allowed once, always or not at all', (
    tester,
  ) async {
    Future<Future<SystemApproval>> open() => _open(
      tester,
      (context) => askSystemApproval(context, command, companionName: 'Aria'),
    );

    var answer = await open();
    expect(find.text('Aria wants to run a command'), findsOneWidget);
    expect(find.text('“To see what is there”'), findsOneWidget);
    expect(find.text('ls ~/Pictures'), findsOneWidget);
    // The usual yes stands out; the lasting one is the quieter button.
    expect(find.widgetWithText(FilledButton, 'Allow once'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Always allow this'),
      findsOneWidget,
    );
    await _press(tester, 'Allow once');
    expect(await answer, SystemApproval.once);

    answer = await open();
    await _press(tester, 'Always allow this');
    expect(await answer, SystemApproval.always);

    answer = await open();
    await _press(tester, 'Don\'t allow');
    expect(await answer, SystemApproval.deny);
  });

  testWidgets('a program to open is asked about every time', (tester) async {
    final answer = await _open(
      tester,
      (context) => askSystemApproval(
        context,
        const SystemRequest(
          tool: SystemRequest.openTool,
          target: '/home/haru/run.sh',
          runnable: true,
        ),
        companionName: 'Aria',
      ),
    );
    expect(find.text('Aria wants to open something'), findsOneWidget);
    expect(find.text('Always allow this'), findsNothing);
    expect(find.textContaining('This is asked every time.'), findsOneWidget);
    await _press(tester, 'Allow once');
    expect(await answer, SystemApproval.once);
  });

  testWidgets('something on a site is allowed or not', (tester) async {
    Future<Future<bool>> open() => _open(
      tester,
      (context) => askWebApproval(
        context,
        const WebRequest(site: 'example.com', action: 'send the form'),
        companionName: 'Aria',
      ),
    );

    var answer = await open();
    expect(
      find.text('Aria wants to do something on example.com'),
      findsOneWidget,
    );
    expect(find.text('Send the form'), findsOneWidget);
    await _press(tester, 'Allow');
    expect(await answer, isTrue);

    answer = await open();
    await _press(tester, 'Don\'t allow');
    expect(await answer, isFalse);
  });

  testWidgets('a calendar change shows the event before and after', (
    tester,
  ) async {
    CalendarEvent event(String title) => CalendarEvent(
      id: '1',
      title: title,
      start: DateTime(2026, 11, 12, 14),
      end: DateTime(2026, 11, 12, 15),
    );
    final answer = await _open(
      tester,
      (context) => askCalendarApproval(
        context,
        CalendarChange(
          kind: CalendarChangeKind.change,
          event: event('Dentist, moved'),
          before: event('Dentist'),
          calendar: 'Home',
        ),
        companionName: 'Aria',
      ),
    );
    expect(find.text('Aria wants to change an event'), findsOneWidget);
    expect(find.text('Dentist'), findsOneWidget);
    expect(find.text('Dentist, moved'), findsOneWidget);
    expect(find.textContaining('Calendar: Home.'), findsOneWidget);
    await _press(tester, 'Change it');
    expect(await answer, isTrue);
  });
}
