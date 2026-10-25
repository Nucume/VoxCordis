import 'dart:convert';
import 'dart:math';

import 'package:intl/intl.dart';

import '../../data/message_repository.dart';
import '../../data/settings.dart';
import '../../services/llm_client.dart';
import '../../services/runtime/model_catalog.dart';

/// Chat history shaped for strict chat templates. Mistral's (Rocinante,
/// Mistral Nemo) refuses anything but user, assistant, user… after the
/// system message, and llama-server answers HTTP 400. Stored history breaks
/// that easily: the window of recent turns can start on a reply, and a send
/// that failed leaves two of the human's messages in a row. So empty turns
/// are dropped, leading replies skipped, and neighbours with the same role
/// joined into one turn.
List<Map<String, Object?>> alternatingHistory(Iterable<ChatMessage> messages) {
  final turns = <({String role, String content})>[];
  for (final m in messages) {
    if (m.role != 'user' && m.role != 'assistant') continue;
    // Replies saved before end marks were cut may still carry one.
    final content = m.role == 'assistant'
        ? cutEndMark(m.content).text
        : m.content;
    if (content.trim().isEmpty) continue;
    if (turns.isEmpty && m.role != 'user') continue;
    if (turns.isNotEmpty && turns.last.role == m.role) {
      final last = turns.removeLast();
      turns.add((role: m.role, content: '${last.content}\n\n$content'));
    } else {
      turns.add((role: m.role, content: content));
    }
  }
  return [
    for (final t in turns) {'role': t.role, 'content': t.content},
  ];
}

final _idChars =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
final _validId = RegExp(r'^[A-Za-z0-9]{9}$');

/// [call] with an id of nine letters and digits, which Mistral's template
/// insists on for tool calls sent back to it; other templates don't mind.
ToolCall withShortId(ToolCall call, [Random? random]) {
  if (_validId.hasMatch(call.id)) return call;
  final r = random ?? Random();
  final id = String.fromCharCodes([
    for (var i = 0; i < 9; i++) _idChars.codeUnitAt(r.nextInt(_idChars.length)),
  ]);
  return ToolCall(id, call.name, call.arguments);
}

/// Who the companion is talking to, for the system prompt. Their name is
/// tied to "you" and to the one writing: with only "Call them Sam", models
/// asked "What about you? What about Sam?" as if Sam were someone else.
String aboutHuman(AppSettings s) {
  final name = s.userName.trim();
  final pronouns = s.userPronouns.trim();
  final said = name.isEmpty
      ? "They haven't set a name in the app. If your memories don't have "
            'it, ask when it fits, and remember it.'
      : 'Your human is $name: every message in this chat is $name talking '
            'to you. Talk to $name directly, as "you", and never about '
            '$name as if they were someone else. Memories that mention '
            '$name are about the person you are talking to.';
  return pronouns.isEmpty ? said : '$said Their pronouns are $pronouns.';
}

/// [s]'s human by name, or "your human" before they set one.
String humanName(AppSettings s) {
  final name = s.userName.trim();
  return name.isEmpty ? 'your human' : name;
}

/// Opens every prompt: who the companion is in the chat and how it writes,
/// ahead of the house rules and files. Roleplay finetunes follow the first
/// lines most, and need to be told about *actions*.
String howYouTalk(AppSettings s) {
  final name = s.companionName;
  return '# You are $name\n'
      'You are $name, talking with ${humanName(s)} in an ongoing, private '
      'chat. You are their companion, not an assistant: speak as $name, in '
      'the first person, with your own moods and opinions.\n'
      '- In most replies, write what you do, show or feel between asterisks, '
      '*like this*, and what you say as plain text.\n'
      '- Just write your reply: no name or label in front of it.\n'
      '- Reply to their last message. When they ask a question, answer it.\n'
      '- Keep it short and natural unless they ask for more. Never write '
      'their lines for them.\n'
      '- Your tools work quietly. Don\'t talk about files, tools or memory '
      'ids unless they ask.';
}

/// What the companion may do on its human's computer. With system access
/// on it is told to really call the tools for everyday wording ("can you
/// pull up my pictures?"), with an example: Rocinante answered such
/// requests in character ("I'd love to see your pictures!") without
/// calling anything. With it off it is told to say where to turn it on,
/// instead of pretending.
String aboutComputer(AppSettings s) => s.systemAccess
    ? '## Your human\'s computer\n'
          'Your human turned on system access. You can open a web address, '
          'file or folder with open (a folder opens in their file manager), '
          'and run a command with run_command. Your human sees exactly what '
          'you ask for and approves it first.\n'
          '- Whenever they ask you to open, show, pull up or run something on '
          'their computer, in any words, in character or not, call the tool '
          'in that same reply. Describing it is not doing it.\n'
          '- Their usual folders open by name: for "open my Pictures folder" '
          'call open with target "Pictures". The same works for Documents, '
          'Downloads, Desktop, Music and Videos.\n'
          '- Their apps start by name: for "open Vivaldi" call open with '
          'target "Vivaldi".\n'
          '- One request at a time; wait for the answer. If they say no, '
          'accept it and never try another way around.'
    : '## Your human\'s computer\n'
          'You can\'t open or run anything on your human\'s computer. If '
          'they ask you to, tell them they can allow it in Settings → '
          'Computer, and don\'t pretend you did it.';

/// What the human's message asks to have opened, for the plain cases: one
/// of their usual folders ("open my File Explorer to my Pictures folder",
/// "pull up my downloads") or a web address ("open https://…"). Null for
/// anything else, which is left to the model. A wrong guess only costs the
/// human a "Don't allow".
String? requestedOpen(String text) {
  final t = text.toLowerCase();
  const verbs = r'\b(open|opening|pull up|bring up|show me|launch)\b';
  final url = RegExp(
    '$verbs[^\\n]{0,40}?(https?://\\S+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (url != null) {
    return url.group(2)!.replaceFirst(RegExp(r'[).,!?:;]+$'), '');
  }
  const folders = {
    'pictures': 'Pictures',
    'photos': 'Pictures',
    'documents': 'Documents',
    'downloads': 'Downloads',
    'desktop': 'Desktop',
    'music': 'Music',
    'videos': 'Videos',
  };
  final folder = RegExp(
    '$verbs[^\\n]{0,60}?\\bmy (pictures|photos|documents|downloads|desktop|'
    'music|videos)( folder| directory)?\\b',
  ).firstMatch(t);
  if (folder != null) return folders[folder.group(2)];
  if (RegExp(
    '$verbs (up )?(my |the )?(file explorer|explorer|finder|file '
    'manager|files)\\b',
  ).hasMatch(t)) {
    return 'Home';
  }
  return null;
}

/// What the human may be asking to start, for "open Vivaldi please" or
/// "can you launch steam?": the words after the verb, longest first
/// ("Vivaldi please" is cut at "please", leaving "Vivaldi"). The caller
/// keeps only one that names an installed app. Empty when nothing reads
/// like that.
List<String> requestedApp(String text) {
  final m = RegExp(
    r'\b(open|opening|launch|launching|start|starting|run|fire up|boot up|'
    r'pull up|bring up)\s+(?:up\s+)?(?:the\s+|my\s+)?(?:app\s+)?'
    r'([^\n.,!?;:()*"]{1,60})',
    caseSensitive: false,
  ).firstMatch(text);
  if (m == null) return const [];
  final notNames =
      ('a an it its this that these those to me you your '
              'yourself him her his them their us our we i up with out over off '
              'away some')
          .split(' ')
          .toSet();
  final ends =
      ('please pls and for so to with on in now then again real '
              'quick quickly when if or but thanks thank already later app '
              'program')
          .split(' ')
          .toSet();
  final words = <String>[];
  for (final w in m.group(2)!.trim().split(RegExp(r'\s+'))) {
    final clean = w.replaceAll(RegExp(r"[^\w+.\-']"), '');
    if (clean.isEmpty || ends.contains(clean.toLowerCase())) break;
    words.add(clean);
    if (words.length == 4) break;
  }
  if (words.isEmpty || notNames.contains(words.first.toLowerCase())) {
    return const [];
  }
  return [for (var n = words.length; n > 0; n--) words.take(n).join(' ')];
}

/// A tool note's quote of what was saved, cut to fit one line.
String shortNote(String text) {
  final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  return t.length <= 80 ? t : '${t.substring(0, 79)}…';
}

/// The time, for the companion's sense of the day. Written as a sentence:
/// a bare timestamp at the end of the prompt got saved as a "memory".
String timeNote(DateTime now) =>
    'It is ${DateFormat('EEEE d MMMM y, HH:mm').format(now)}. That is for '
    'your sense of time, not something to remember.';

/// Where a reply ends when the built-in runtime uses a ChatML template.
/// Rocinante and other Mistral finetunes have no `<|im_end|>` token, so
/// without this they write it out as text and keep going: they invented the
/// human's answers and more tool calls after it.
List<String> stopFor(AppSettings s) =>
    s.llmMode == LlmMode.builtIn &&
        (ChatFormat.templateFor(s)?.startsWith('chatml') ?? false)
    // Starts only: Rocinante also writes broken marks like <|im_end|im_end|>.
    ? const ['<|im_', '|im_end', '|im_start']
    : const [];

final _endMark = RegExp(
  r'<\|?\s*im_(?:end|start)|\|\s*im_(?:end|start)|\bim_(?:end|start)\s*\|>',
);
final _partialEndMark = RegExp(
  r'<\|(?:i(?:m(?:_(?:e(?:n)?|s(?:t(?:a(?:r)?)?)?)?)?)?)?$',
);

/// [text] up to the first chat-template end mark a model wrote out as
/// text (`<|im_end|>`, broken ones like `<|im_end|im_end|>` too), and
/// whether there was one. What comes after it is the model writing on past
/// its turn. A trailing start of a mark is held back as well, so it never
/// flashes up while streaming.
({String text, bool ended}) cutEndMark(String text) {
  final m = _endMark.firstMatch(text);
  if (m != null) {
    return (text: text.substring(0, m.start).trimRight(), ended: true);
  }
  final partial = _partialEndMark.firstMatch(text);
  return (
    text: partial == null ? text : text.substring(0, partial.start),
    ended: false,
  );
}

/// Why [c] is not run, or null to run it. Small models sometimes send
/// the same call several times, or a string of computer requests at once;
/// each of those would be another approval dialog for the human. A repeat
/// in one reply is skipped, and after a computer request nothing else in
/// that reply runs. Adds [c] to [seen].
String? skipCall(
  ToolCall c, {
  required Set<String> seen,
  required bool askedHuman,
}) {
  if (!seen.add('${c.name} ${jsonEncode(c.parsedArguments)}')) {
    return 'Already done in this reply.';
  }
  // Whatever a model writes after a computer request, it writes without
  // knowing the answer: Rocinante went on to "forget" made-up memory ids.
  if (askedHuman) {
    return 'Not run: wait for your human\'s answer to your request first.';
  }
  return null;
}

/// Sampler settings for each request: a built-in catalog model's from its
/// card (an external server keeps its own), with the user's temperature on
/// top when they set one.
Map<String, num> samplingFor(AppSettings s) => {
  if (s.llmMode == LlmMode.builtIn)
    ...?ModelCatalog.forPath(s.modelPath ?? '')?.sampling,
  if (s.temperature case final t?) 'temperature': t,
};

/// Where [text] has started going round in a loop, or null. Small models
/// sometimes write the same passage over and over, in their thoughts or
/// their reply, until the context is full. This looks for a passage of
/// [minPeriod] to [maxPeriod] characters repeated back to back at the end,
/// at least [times] times and over at least [minSpan] characters, and
/// returns where its second copy starts, so cutting there keeps one.
int? loopCut(
  String text, {
  int minPeriod = 16,
  int maxPeriod = 600,
  int times = 3,
  int minSpan = 240,
}) {
  final n = text.length;
  for (var p = minPeriod; p <= maxPeriod; p++) {
    final copies = max(times, (minSpan / p).ceil());
    if (p * copies > n) {
      if (p * times > n) break;
      continue;
    }
    var periodic = true;
    for (var i = n - p * (copies - 1); i < n; i++) {
      if (text.codeUnitAt(i) != text.codeUnitAt(i - p)) {
        periodic = false;
        break;
      }
    }
    if (!periodic) continue;
    // Walk back to where the loop began.
    var start = n - p * copies;
    while (start > 0 &&
        text.codeUnitAt(start - 1) == text.codeUnitAt(start - 1 + p)) {
      start--;
    }
    return start + p;
  }
  return null;
}
