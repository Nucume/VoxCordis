import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../app_scope.dart';
import '../../data/desk/pictures.dart';
import '../../data/desk/shared_files.dart';
import '../../data/message_repository.dart';
import '../../data/settings.dart';
import '../../data/voces/story_log.dart';
import '../../data/voces/voces_library.dart';
import '../../data/voces/voces_models.dart';
import '../../services/images/image_catalog.dart';
import '../../services/images/image_engine.dart';
import '../../services/images/sd_runtime.dart';
import '../../services/calendar/calendar_event.dart';
import '../../services/calendar/calendar_tools.dart';
import '../../services/folder_service.dart';
import '../../services/logs/app_log.dart';
import '../../services/phone/keep_awake.dart';
import '../../services/phone/phone_crypto.dart';
import '../../services/phone/phone_devices.dart';
import '../../services/phone/phone_server.dart';
import '../../services/voces/story_engine.dart';
import '../../services/voces/story_notes.dart';
import '../../services/voces/story_session.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_text.dart';
import '../chat/prompt_history.dart';
import '../images/draw_panel.dart';
import '../voces/voces_home.dart';
import '../voces/voces_widgets.dart';
import 'phone_dialogs.dart';

/// What a phone can do with VoxCordis: chat with the companion, look at
/// and draw pictures, and play Voces Mundi stories. Everything runs here,
/// on the computer; the phone only shows it ([PhoneServer]).
///
/// The phone and the window share one chat ([AppServices.chat]) and one
/// session per story ([AppServices.openStory]), so both always show the
/// same thing.
class PhoneApi implements PhoneHandler {
  PhoneApi(this.services) : devices = PhoneDevices(services.settings.secrets) {
    server = PhoneServer(devices: devices, handler: this, log: services.log);
    devices.onRemoved = (id) => unawaited(server.drop(id));
  }

  final AppServices services;
  final PhoneDevices devices;
  late final PhoneServer server;
  final _awake = KeepAwake();

  final _clients = <PhoneLink, _Client>{};

  /// Why the server couldn't start, for Settings.
  final problem = ValueNotifier<String?>(null);

  bool get anyConnected => _clients.isNotEmpty;

  /// Follows Settings: starts or stops the server, and keeps the computer
  /// awake while a phone is connected.
  void start() {
    services.settings.addListener(_apply);
    devices.addListener(_keepAwake);
    _apply();
  }

  AppSettings? _last;

  Future<void> _apply() async {
    final s = services.settings.value;
    final last = _last;
    _last = s;
    server.tailscale = s.phoneTailscale;
    final want = s.phoneAccess && s.isSetUp;
    if (!want) {
      if (server.running) await server.stop();
      problem.value = null;
    } else if (!server.running || last?.phonePort != s.phonePort) {
      if (server.running) await server.stop();
      try {
        await server.start(s.phonePort);
        problem.value = null;
      } on SocketException catch (e) {
        problem.value =
            'Port ${s.phonePort} is taken by another program '
            '(${e.osError?.message ?? e.message}). Pick another port.';
      }
    }
    _keepAwake();
    if (last != null && _companionChanged(last, s)) {
      _bindChat();
      for (final c in _clients.values) {
        unawaited(c.link.send({'ev': 'state', ...await _state()}));
      }
    }
  }

  bool _companionChanged(AppSettings a, AppSettings b) =>
      a.companionId != b.companionId ||
      a.companionName != b.companionName ||
      a.portraitPath != b.portraitPath ||
      a.accentColor != b.accentColor ||
      a.themeChoice != b.themeChoice ||
      a.vocesMundi != b.vocesMundi ||
      a.imageEngine != b.imageEngine ||
      a.otherCompanions.length != b.otherCompanions.length;

  void _keepAwake() {
    unawaited(
      _awake.set(
        services.settings.value.phoneKeepAwake && devices.connected.isNotEmpty,
      ),
    );
  }

  Future<void> close() async {
    services.settings.removeListener(_apply);
    await server.stop();
    await _awake.set(false);
  }

  // ---------------------------------------------------------------- links

  @override
  Future<String?> allow(String name, String address, {String? check}) =>
      askAllowPhone(services, name: name, address: address, check: check);

  @override
  void connected(PhoneLink link) {
    _clients[link] = _Client(link);
    _bindChat();
    _bindDrawing();
    services.log.add(
      LogKind.connections,
      'Phone connected: ${link.phone?.name ?? 'a new phone'}',
    );
  }

  @override
  void disconnected(PhoneLink link) {
    final c = _clients.remove(link);
    if (c != null) unawaited(_leaveStory(c));
    for (final a in _asks.values) {
      if (a.links.remove(link) && a.links.isEmpty && !a.done.isCompleted) {
        a.done.complete(false);
      }
    }
  }

  @override
  Future<Map<String, Object?>> handle(
    PhoneLink link,
    String op,
    Map<String, Object?> r,
  ) async {
    final c = _clients[link];
    if (c == null) throw const PhoneError('Not connected.');
    switch (op) {
      case 'hello':
        return {...await _state(), 'chat': await _chatEvent(c, full: true)};
      case 'state':
        return _state();
      case 'pic':
        return _picture(c, '${r['ref']}', full: r['full'] == true);
      case 'answer':
        _answer('${r['ask']}', r['yes'] == true);
        return const {};
      // Chat
      case 'chat.send':
        return _send(r);
      case 'chat.stop':
        services.chat.stop();
        return const {};
      case 'chat.retry':
        unawaited(services.chat.retry());
        return const {};
      case 'chat.days':
        final days = await services.messages.days();
        return {
          'days': [for (final d in days) _day(d)],
        };
      case 'chat.day':
        final day = DateTime.tryParse('${r['day']}');
        if (day == null) throw const PhoneError('Which day?');
        final list = await services.messages.forDay(day);
        return {
          'msgs': [
            for (final m in list.map(_clean))
              if (_hasSomething(m)) _message(c, m),
          ],
        };
      case 'companion':
        return _switchCompanion('${r['id']}');
      // Pictures
      case 'pics':
        return _pictures(c);
      case 'draw.options':
        return _drawOptions();
      case 'draw':
        return _draw(c, r);
      case 'draw.cancel':
        services.imageEngine.cancelAll();
        return const {};
      // Voces Mundi
      case 'voces':
        return _vocesHome(c);
      case 'voces.new':
        return _newStoryInfo(c, '${r['world']}');
      case 'voces.start':
        return _startStory(c, r);
      case 'voces.open':
        return _openStory(c, '${r['story']}', r);
      case 'voces.close':
        await _leaveStory(c);
        return const {};
      default:
        if (op.startsWith('story.')) return _storyOp(c, op.substring(6), r);
        throw PhoneError('Unknown request $op.');
    }
  }

  // ---------------------------------------------------------------- state

  Future<Map<String, Object?>> _state() async {
    final s = services.settings.value;
    String? portrait(String? path) =>
        path == null || !File(path).existsSync() ? null : _sharedRef(path);
    return {
      'companion': {
        'id': s.companionId ?? '',
        'name': s.companionName,
        'traits': s.traits,
        'portrait': portrait(s.portraitPath),
      },
      'companions': [
        for (final c in s.companions)
          {
            'id': c.id ?? '',
            'name': c.name,
            'traits': c.traits,
            'portrait': portrait(c.portraitPath),
            'current': c.id == s.companionId,
            'accent': _hex(c.accentColor),
          },
      ],
      'human': humanName(s),
      'look': {
        'accent': _hex(s.accentColor),
        'glows': [for (final g in s.backgroundColors) _hex(g)],
        'theme': s.themeChoice.name,
      },
      'voces': s.vocesMundi,
      'draw': s.imageEngine != ImageEngineChoice.off,
    };
  }

  static String _hex(int argb) =>
      '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<Map<String, Object?>> _switchCompanion(String id) async {
    final s = services.settings.value;
    if (id == (s.companionId ?? '')) return const {};
    final chat = services.chat;
    if (chat.busy) {
      throw PhoneError('Let ${s.companionName} finish replying first.');
    }
    final to = s.otherCompanions.where((c) => (c.id ?? '') == id).firstOrNull;
    if (to == null) throw const PhoneError('That companion is gone.');
    await services.switchCompanion(s.switchedTo(to));
    return _state();
  }

  // ---------------------------------------------------------------- chat

  ChatController? _chat;

  /// Follows the chat of the current companion.
  void _bindChat() {
    if (_clients.isEmpty) return;
    final chat = services.chat;
    if (identical(chat, _chat)) return;
    _chat?.removeListener(_chatChanged);
    _chat = chat..addListener(_chatChanged);
    for (final c in _clients.values) {
      c.sentMsgs.clear();
    }
    _chatChanged();
  }

  void _chatChanged() {
    for (final c in _clients.values) {
      c.chatTimer ??= Timer(const Duration(milliseconds: 80), () async {
        c.chatTimer = null;
        try {
          await c.link.send({'ev': 'chat', ...await _chatEvent(c)});
        } on Object {
          // The phone left meanwhile.
        }
      });
    }
  }

  static ChatMessage _clean(ChatMessage m) =>
      m.role == 'assistant' ? m.withContent(cutEndMark(m.content).text) : m;

  static bool _hasSomething(ChatMessage m) =>
      m.role != 'assistant' ||
      m.content.isNotEmpty ||
      (m.reasoning?.isNotEmpty ?? false);

  /// What the phone needs to show the chat: how it's going, every
  /// message's id in order, and the messages it hasn't got as they are.
  Future<Map<String, Object?>> _chatEvent(
    _Client c, {
    bool full = false,
  }) async {
    final chat = services.chat;
    if (full) c.sentMsgs.clear();
    // The window may be showing a past day; the phone keeps to today.
    final list = chat.viewingDay == null
        ? chat.messages
        : [
            for (final m in (await services.messages.recent()).map(_clean))
              if (_hasSomething(m)) m,
          ];
    final changed = <Map<String, Object?>>[];
    for (final m in list) {
      final hash = Object.hash(m.content, m.reasoning);
      if (c.sentMsgs[m.id] == hash) continue;
      c.sentMsgs[m.id] = hash;
      changed.add(_message(c, m));
    }
    return {
      'order': [for (final m in list) m.id],
      'msgs': changed,
      'busy': chat.busy,
      'phase': chat.phase.name,
      'note': chat.toolNote,
      'error': chat.error,
      'canRetry': chat.canRetry,
      'stopping': chat.stopping,
      'forPhone': chat.forPhone,
    };
  }

  Map<String, Object?> _message(_Client c, ChatMessage m) {
    final folder = services.settings.value.companionFolder;
    final pictures = Pictures.inText(m.content);
    final files = SharedFiles.inText(m.content);
    final raw = pictures.isEmpty && files.isEmpty
        ? m.content
        : SharedFiles.withoutMarkers(m.content);
    return {
      'id': m.id,
      'role': m.role,
      'via': m.via,
      'ts': m.ts.millisecondsSinceEpoch,
      'text': m.role == 'user' ? raw : tidyBlankLines(raw),
      if (m.reasoning?.isNotEmpty ?? false) 'think': m.reasoning,
      'pics': [
        if (folder != null)
          for (final rel in pictures)
            if (Pictures.fileIn(folder, rel.split('. ').first) case final f?)
              c.ref(f.path),
      ],
      'files': [for (final f in files) p.basename(f)],
    };
  }

  Future<Map<String, Object?>> _send(Map<String, Object?> r) async {
    final chat = services.chat;
    final s = services.settings.value;
    if (chat.busy) {
      throw PhoneError('${s.companionName} is still replying.');
    }
    final text = '${r['text'] ?? ''}';
    final photos = r['photos'] is List ? r['photos'] as List : const [];
    final dir = Directory(
      p.join(services.runtime.supportDir.path, 'phone-uploads'),
    );
    final paths = <String>[];
    for (final ph in photos.take(6)) {
      if (ph is! Map) continue;
      final bytes = PhoneCrypto.decode('${ph['data']}');
      if (bytes.length > SharedFiles.maxPictureBytes) {
        throw const PhoneError('That picture is too big.');
      }
      final ext = Pictures.imageExtensionOf(bytes);
      if (ext == null) throw const PhoneError('That isn\'t a picture.');
      await dir.create(recursive: true);
      final name = p
          .basenameWithoutExtension('${ph['name'] ?? 'photo'}')
          .replaceAll(RegExp(r'[^\w\- ]'), '')
          .trim();
      final f = File(
        p.join(
          dir.path,
          '${name.isEmpty ? 'photo' : name}-'
          '${DateTime.now().millisecondsSinceEpoch}.$ext',
        ),
      );
      await f.writeAsBytes(bytes);
      paths.add(f.path);
    }
    if (text.trim().isEmpty && paths.isEmpty) return const {};
    // The reply runs on; the phone follows it through chat events.
    unawaited(
      chat.send(text, images: paths, via: 'phone').whenComplete(() async {
        for (final path in paths) {
          await File(path).delete().then((_) {}, onError: (_) {});
        }
      }),
    );
    return const {};
  }

  // ------------------------------------------------------------ questions

  final _asks = <String, _Ask>{};
  var _askCount = 0;

  /// Asks on the phone instead of the computer: the companion, answering
  /// a message written there, wants to do something that needs a yes.
  /// False when no phone answers.
  Future<bool> ask({
    required String title,
    required String body,
    String yes = 'Allow',
  }) async {
    if (_clients.isEmpty) return false;
    final id = 'a${++_askCount}';
    final a = _asks[id] = _Ask({..._clients.keys});
    for (final l in [..._clients.keys]) {
      unawaited(
        l.send({
          'ev': 'ask',
          'ask': id,
          'title': title,
          'body': body,
          'yes': yes,
        }),
      );
    }
    try {
      return await a.done.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => false,
      );
    } finally {
      _asks.remove(id);
      for (final l in _clients.keys) {
        unawaited(l.send({'ev': 'asked', 'ask': id}));
      }
    }
  }

  /// A calendar change, asked on the phone.
  Future<bool> askCalendar(CalendarChange change) {
    final name = services.settings.value.companionName;
    String when(CalendarEvent e) {
      String two(int n) => n.toString().padLeft(2, '0');
      final d = e.start;
      final day = '${d.year}-${two(d.month)}-${two(d.day)}';
      if (e.allDay) return '$day, all day';
      return '$day ${two(d.hour)}:${two(d.minute)}–'
          '${two(e.end.hour)}:${two(e.end.minute)}';
    }

    String event(CalendarEvent e) => [
      e.title.isEmpty ? '(no title)' : e.title,
      when(e),
      if (e.location.isNotEmpty) e.location,
    ].join('\n');
    final (verb, yes) = switch (change.kind) {
      CalendarChangeKind.add => ('add', 'Add it'),
      CalendarChangeKind.change => ('change', 'Change it'),
      CalendarChangeKind.delete => ('delete', 'Delete it'),
    };
    return ask(
      title: '$name wants to $verb an event',
      body: [
        if (change.before case final b?) '${event(b)}\n↓',
        event(change.event),
        if (change.calendar.isNotEmpty) 'Calendar: ${change.calendar}',
      ].join('\n\n'),
      yes: yes,
    );
  }

  void _answer(String id, bool yes) {
    final a = _asks[id];
    if (a != null && !a.done.isCompleted) a.done.complete(yes);
  }

  // ------------------------------------------------------------- pictures

  /// A picture's way to the phone that every phone shares: for portraits.
  String _sharedRef(String path) =>
      's:${PhoneCrypto.encode(utf8.encode(path))}';

  /// The bytes of picture [ref], made small unless [full].
  Future<Map<String, Object?>> _picture(
    _Client c,
    String ref, {
    required bool full,
  }) async {
    final String? path;
    if (ref.startsWith('s:')) {
      final named = utf8.decode(PhoneCrypto.decode(ref.substring(2)));
      // Only the companions' own portraits go out this way.
      final s = services.settings.value;
      final ok = s.companions.any((x) => x.portraitPath == named);
      path = ok ? named : null;
    } else {
      path = c.refs[ref];
    }
    if (path == null) throw const PhoneError('That picture is gone.');
    final file = File(path);
    if (!await file.exists()) throw const PhoneError('That picture is gone.');
    final video = Pictures.videoExtensions.contains(
      p.extension(path).replaceFirst('.', '').toLowerCase(),
    );
    final Uint8List bytes;
    final String mime;
    if (video) {
      if (!full) throw const PhoneError('No preview for clips.');
      if (await file.length() > 60 * 1024 * 1024) {
        throw const PhoneError('This clip is too big for the phone.');
      }
      bytes = await file.readAsBytes();
      mime = p.extension(path).toLowerCase() == '.webm'
          ? 'video/webm'
          : 'video/mp4';
    } else {
      final small = await _small(file, full ? 2560 : 640, full);
      bytes = small.$1;
      mime = small.$2;
    }
    return {'mime': mime, 'data': base64.encode(bytes)};
  }

  /// Small copies, kept while VoxCordis runs.
  final _thumbs = <String, (Uint8List, String)>{};

  Future<(Uint8List, String)> _small(File f, int edge, bool full) async {
    final stamp = (await f.lastModified()).millisecondsSinceEpoch;
    final key = '${f.path}|$stamp|$edge';
    if (_thumbs[key] case final hit?) return hit;
    final bytes = await f.readAsBytes();
    final mime = switch (Pictures.imageExtensionOf(bytes)) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };
    // A full picture that isn't huge goes as it is.
    if (full && bytes.length < 6 * 1024 * 1024) return (bytes, mime);
    final out = await phoneCompute(_shrink, (bytes, edge));
    final result = out == null ? (bytes, mime) : (out, 'image/jpeg');
    if (!full) {
      if (_thumbs.length > 400) _thumbs.remove(_thumbs.keys.first);
      _thumbs[key] = result;
    }
    return result;
  }

  static Uint8List? _shrink((Uint8List, int) a) {
    final image = img.decodeImage(a.$1);
    if (image == null) return null;
    final edge = a.$2;
    final big = image.width > image.height ? image.width : image.height;
    final small = big <= edge
        ? image
        : image.width >= image.height
        ? img.copyResize(image, width: edge)
        : img.copyResize(image, height: edge);
    return Uint8List.fromList(img.encodeJpg(small, quality: 82));
  }

  Future<Map<String, Object?>> _pictures(_Client c) async {
    final folder = services.settings.value.companionFolder;
    if (folder == null) return const {'pics': []};
    final dir = CompanionFolder(folder).images;
    if (!await dir.exists()) return const {'pics': []};
    final files = <(File, DateTime)>[];
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final ext = p.extension(e.path).replaceFirst('.', '').toLowerCase();
      if (!Pictures.extensions.contains(ext) &&
          !Pictures.videoExtensions.contains(ext)) {
        continue;
      }
      files.add((e, await e.lastModified()));
    }
    files.sort((a, b) => b.$2.compareTo(a.$2));
    return {
      'pics': [
        for (final (f, at) in files.take(600))
          {
            'ref': c.ref(f.path),
            'at': at.millisecondsSinceEpoch,
            'video': Pictures.videoExtensions.contains(
              p.extension(f.path).replaceFirst('.', '').toLowerCase(),
            ),
          },
      ],
    };
  }

  // -------------------------------------------------------------- drawing

  void _bindDrawing() {
    if (_drawBound) return;
    _drawBound = true;
    services.imageEngine.addListener(_drawingChanged);
  }

  var _drawBound = false;
  Timer? _drawTimer;

  void _drawingChanged() {
    _drawTimer ??= Timer(const Duration(milliseconds: 250), () {
      _drawTimer = null;
      final e = services.imageEngine;
      for (final c in _clients.values) {
        final mine = c.jobs.contains(e.current);
        unawaited(
          c.link.send({
            'ev': 'drawing',
            'busy': e.busy,
            'mine': mine,
            'status': e.status,
            'progress': e.progress,
            'waiting': e.waiting,
          }),
        );
      }
    });
  }

  List<ImageModel> _readyModels(AppSettings s) =>
      s.imageEngine == ImageEngineChoice.off
      ? const <ImageModel>[]
      : services.imageEngine.available(s);

  /// What the phone's Draw needs: the simple choices, and for Advanced
  /// everything the PC's Draw panel offers, as it was last left there.
  Map<String, Object?> _drawOptions() {
    final s = services.settings.value;
    final ready = _readyModels(s);
    final model = ready.isEmpty
        ? null
        : ready.where((m) => m.id == s.draw.model).firstOrNull ??
              ImageCatalog.defaultFor(s, ready);
    final draw = s.draw;
    return {
      'ready': model != null,
      'why': s.imageEngine == ImageEngineChoice.off
          ? 'Drawing is off. Turn it on in Settings › Images on your PC.'
          : 'No picture model is downloaded yet. Get one in Settings › Images '
                'on your PC.',
      'model': model?.id,
      'shape': draw.shape,
      'advanced': draw.advanced,
      'width': draw.width,
      'height': draw.height,
      'ratio': draw.ratio,
      'models': [
        for (final m in ready)
          {
            'id': m.id,
            'name': m.name,
            'steps': m.steps,
            'cfg': m.cfg,
            'sampler': SdRun.samplers[m.sampler] ?? m.sampler,
            'scheduler': SdRun.schedulers[m.scheduler] ?? 'Normal',
            'base': m.baseSize,
            'sizes': {
              for (final shape in const ['square', 'portrait', 'landscape'])
                shape: [m.sizeFor(shape).width, m.sizeFor(shape).height],
            },
            'tags': m.prompting == Prompting.tags,
          },
      ],
      'choices': {
        for (final e in draw.perModel.entries) e.key: e.value.toJson(),
      },
      'loras': [
        for (final l in services.imageEngine.lorasFor(s))
          {'name': l.name, 'note': l.note},
      ],
      'samplers': [
        for (final e in SdRun.samplers.entries) [e.key, e.value],
      ],
      'schedulers': [
        for (final e in SdRun.schedulers.entries) [e.key, e.value],
      ],
      'presets': [
        for (final pr in draw.presets)
          {'name': pr.name, 'prompt': pr.prompt, 'negative': pr.negative},
      ],
    };
  }

  static int _snap(int v) => ((v / 64).round() * 64).clamp(256, 2048).toInt();

  static int? _int(Object? v) => v is num
      ? v.round()
      : v is String
      ? int.tryParse(v.trim())
      : null;

  static double? _double(Object? v) => v is num
      ? v.toDouble()
      : (v is String ? double.tryParse(v.trim()) : null);

  /// A width:height ratio ("9:16", "16 9", "4/3"), as the PC reads them.
  static ({double w, double h})? _ratioIn(Object? text) =>
      text is String ? DrawPanel.ratioIn(text) : null;

  Future<Map<String, Object?>> _draw(_Client c, Map<String, Object?> r) async {
    final s = services.settings.value;
    final folder = s.companionFolder;
    final prompt = '${r['prompt'] ?? ''}'.trim();
    if (folder == null || prompt.isEmpty) {
      throw const PhoneError('Say what to draw first.');
    }
    final ready = _readyModels(s);
    if (ready.isEmpty) throw PhoneError('${_drawOptions()['why']}');
    final advanced = r['advanced'] == true;
    final model =
        (advanced
            ? ready.where((m) => m.id == r['model']).firstOrNull
            : null) ??
        ready.where((m) => m.id == s.draw.model).firstOrNull ??
        ImageCatalog.defaultFor(s, ready)!;
    final shape = switch ('${r['shape']}') {
      'portrait' => 'portrait',
      'landscape' => 'landscape',
      _ => 'square',
    };
    final DrawRequest request;
    var draw = s.draw.copyWith(shape: shape, advanced: advanced);
    if (advanced) {
      final known = {for (final l in services.imageEngine.lorasFor(s)) l.name};
      final loras = <String, double>{
        if (r['loras'] case final Map<Object?, Object?> picked)
          for (final e in picked.entries)
            if (known.contains(e.key) && e.value is num)
              '${e.key}': (e.value! as num).toDouble().clamp(-1, 2),
      };
      final ratio = _ratioIn(r['ratio']);
      var width = _int(r['width']);
      var height = _int(r['height']);
      width = width == null || width == 0 ? null : _snap(width);
      height = height == null || height == 0 ? null : _snap(height);
      // A ratio on its own sets the size from the model's own area.
      final ({int width, int height}) size;
      if (ratio == null) {
        size = model.sizeFor(shape);
      } else {
        final area = model.baseSize * model.baseSize;
        final w = sqrt(area * ratio.w / ratio.h);
        size = (width: _snap(w.round()), height: _snap((area / w).round()));
      }
      String? listed(Object? v, Map<String, String> list) =>
          v is String && list.containsKey(v) ? v : null;
      final choices = DrawChoices(
        steps: _int(r['steps'])?.clamp(1, 150),
        cfg: _double(r['cfg'])?.clamp(0, 30).toDouble(),
        seed: _int(r['seed']),
        negative: '${r['negative'] ?? ''}',
        loras: loras,
        sampler: listed(r['sampler'], SdRun.samplers),
        scheduler: listed(r['scheduler'], SdRun.schedulers),
      );
      request = DrawRequest(
        model: model,
        prompt: prompt,
        negative: choices.negative,
        shape: shape,
        loras: [for (final e in loras.entries) (name: e.key, weight: e.value)],
        width: width ?? size.width,
        height: height ?? size.height,
        steps: choices.steps,
        cfg: choices.cfg,
        seed: choices.seed,
        sampler: choices.sampler,
        scheduler: choices.scheduler,
      );
      // Kept as the PC's Draw panel keeps them, so both show the same.
      draw = draw
          .copyWith(model: model.id)
          .withChoices(model.id, choices)
          .withSize(
            width: width,
            height: height,
            ratio: ratio == null ? null : '${r['ratio']}'.trim(),
          );
    } else {
      request = DrawRequest(
        model: model,
        prompt: prompt,
        negative: '${r['negative'] ?? ''}',
        shape: shape,
      );
    }
    if (draw != s.draw) {
      await services.settings.update(
        services.settings.value.copyWith(draw: draw),
      );
    }
    final job = services.imageEngine.draw(
      DrawJob(request, folder: folder, forChat: false),
    );
    c.jobs.add(job);
    unawaited(
      job.done
          .then(
            (file) => c.link.send({'ev': 'drawn', 'ref': c.ref(file.path)}),
            onError: (Object e) =>
                c.link.send({'ev': 'drawn', 'error': StorySession.short(e)}),
          )
          .whenComplete(() => c.jobs.remove(job)),
    );
    _drawingChanged();
    return const {};
  }

  // ---------------------------------------------------------- Voces Mundi

  VocesData _vocesData() {
    final s = services.settings.value;
    final folder = s.companionFolder;
    final root = folder == null ? Directory.systemTemp.path : p.dirname(folder);
    return VocesData(
      VocesLibrary.inside(root),
      mature: () => services.settings.value.vocesMature,
    );
  }

  void _needVoces() {
    if (!services.settings.value.vocesMundi) {
      throw const PhoneError(
        'Voces Mundi is off. Turn it on in Settings › General on your PC.',
      );
    }
  }

  static Map<String, Object?> _art(String name, int? seed) {
    final look = seed == null ? ArtLook.named(name) : ArtLook.of(seed);
    return {
      'colors': [for (final c in look.colors) _hex(c.toARGB32())],
      // The CSS angle of a gradient running from begin to the far side.
      'angle': (atan2(-look.begin.x, look.begin.y) * 180 / pi).round(),
    };
  }

  Future<Map<String, Object?>> _vocesHome(_Client c) async {
    _needVoces();
    final data = _vocesData();
    await data.reload();
    final lib = data.library;
    final stories = [...data.stories]
      ..sort((a, b) => b.lastPlayed.compareTo(a.lastPlayed));
    String? picture(File? f) =>
        f != null && f.existsSync() ? c.ref(f.path) : null;
    return {
      'stories': [
        for (final s in stories)
          {
            'id': s.id,
            'title': s.title,
            'world': s.worldName,
            'player': s.playerName,
            'difficulty': s.difficulty.label,
            'turns': s.turns,
            'at': s.lastPlayed.millisecondsSinceEpoch,
            'place': s.place,
            'art': _art(s.worldName, data.world(s.worldId)?.art),
            'picture': picture(
              data.world(s.worldId) == null
                  ? null
                  : lib.worldPicture(data.world(s.worldId)!),
            ),
          },
      ],
      'worlds': [
        for (final w in data.worlds)
          {
            'id': w.id,
            'name': w.name,
            'line': w.line,
            'tags': w.tags.take(2).toList(),
            'adult': w.adult,
            'cast': w.castIds.length,
            'stories': data.stories.where((s) => s.worldId == w.id).length,
            'art': _art(w.name, w.art),
            'picture': picture(lib.worldPicture(w)),
          },
      ],
    };
  }

  Future<Map<String, Object?>> _newStoryInfo(_Client c, String worldId) async {
    _needVoces();
    final data = _vocesData();
    await data.reload();
    final world = data.world(worldId);
    if (world == null) throw const PhoneError('That world is gone.');
    final played = {for (final s in data.stories) s.playerId};
    final outside = [
      for (final ch in data.characters)
        if (!world.castIds.contains(ch.id)) ch,
    ];
    final player =
        outside.where((ch) => played.contains(ch.id)).firstOrNull ??
        outside.firstOrNull ??
        data.characters.firstOrNull;
    final castHere = [
      for (final id in world.castIds)
        if (data.character(id) != null) data.character(id)!,
    ];
    Map<String, Object?> person(VocesCharacter ch) => {
      'id': ch.id,
      'name': ch.name,
      'line': ch.line,
      'art': _art(ch.name, ch.art),
      if (data.library.portraitOf(ch) case final f? when f.existsSync())
        'picture': c.ref(f.path),
    };
    return {
      'world': {'id': world.id, 'name': world.name, 'adult': world.adult},
      'characters': [for (final ch in data.characters) person(ch)],
      'castIds': world.castIds,
      'player': player?.id,
      'cast': [
        for (final ch in castHere.where((x) => x.id != player?.id).take(3))
          ch.id,
      ],
      'openings': [for (final o in world.openings) o.title],
      'difficulties': [
        for (final d in Difficulty.values)
          if (!d.adultOnly || world.adult)
            {'id': d.name, 'label': d.label, 'blurb': d.blurb},
      ],
    };
  }

  Future<Map<String, Object?>> _startStory(
    _Client c,
    Map<String, Object?> r,
  ) async {
    _needVoces();
    final data = _vocesData();
    await data.reload();
    final world = data.world('${r['world']}');
    final player = data.character('${r['player']}');
    if (world == null || player == null) {
      throw const PhoneError('Pick who you play first.');
    }
    final title = '${r['title'] ?? ''}'.trim();
    final opening = world.openings
        .where((o) => o.title == r['opening'])
        .firstOrNull;
    final story = await data.library.startStory(
      world: world,
      player: player,
      title: title.isEmpty
          ? '${player.name.split(' ').first} in ${world.name}'
          : title,
      difficulty: Difficulty.byName('${r['difficulty']}'),
      opening: opening,
    );
    final cast = [
      for (final id in (r['cast'] is List ? r['cast'] as List : const []))
        if (world.castIds.contains(id) && id != player.id) '$id',
    ];
    return _openStory(c, story.id, {'cast': cast});
  }

  Future<Map<String, Object?>> _openStory(
    _Client c,
    String id,
    Map<String, Object?> r,
  ) async {
    _needVoces();
    await _leaveStory(c);
    final data = _vocesData();
    await data.reload();
    final save = data.stories.where((s) => s.id == id).firstOrNull;
    if (save == null) throw const PhoneError('That story is gone.');
    final cast = r['cast'] is List
        ? [for (final x in r['cast'] as List) '$x']
        : null;
    final session = services.openStory(data.library, save, cast: cast);
    c.story = session;
    c.sentTurns.clear();
    c.storyListener = () => _storyChanged(c);
    session.addListener(c.storyListener!);
    c.storyNotices = session.notices.listen(
      (text) => c.link.send({'ev': 'notice', 'text': text}),
    );
    // A story still opening tells the phone once it is ready.
    return {'story': _storyEvent(c, full: true)};
  }

  Future<void> _leaveStory(_Client c) async {
    final s = c.story;
    if (s == null) return;
    c.story = null;
    if (c.storyListener case final l?) s.removeListener(l);
    c.storyListener = null;
    await c.storyNotices?.cancel();
    c.storyNotices = null;
    c.storyTimer?.cancel();
    c.storyTimer = null;
    await services.releaseStory(s);
  }

  void _storyChanged(_Client c) {
    c.storyTimer ??= Timer(const Duration(milliseconds: 80), () {
      c.storyTimer = null;
      if (c.story == null) return;
      unawaited(c.link.send({'ev': 'story', ..._storyEvent(c)}));
    });
  }

  Map<String, Object?> _storyEvent(_Client c, {bool full = false}) {
    final s = c.story!;
    if (full) c.sentTurns.clear();
    final engine = s.engine;
    final changed = <Map<String, Object?>>[];
    for (final t in s.turns) {
      final hash = Object.hash(t.text, t.kind, t.speaker);
      if (c.sentTurns[t.id] == hash) continue;
      c.sentTurns[t.id] = hash;
      changed.add(_turn(c, s, t));
    }
    final writing = s.busy && s.writing.isNotEmpty && engine != null
        ? {
            'who': s.writer,
            'name': engine.nameOf(s.writer),
            'text': s.writer == null
                ? StoryEngine.splitPlace(s.writing.toString()).text
                : engine.clean(s.writing.toString(), s.writer),
          }
        : null;
    return {
      'id': s.story.id,
      'title': s.story.title,
      'world': s.story.worldName,
      'player': engine?.playerName ?? s.story.playerName,
      'difficulty': s.story.difficulty.label,
      'place': s.state.place,
      'ready': engine != null,
      'error': s.error == null ? null : StorySession.short(s.error!),
      'order': [for (final t in s.turns) t.id],
      'turns': changed,
      'busy': s.busy,
      'writer': s.busy ? engine?.nameOf(s.writer) : null,
      'writing': writing,
      'jumpedIn': s.jumpedIn,
      'canRetry': s.canRetry,
      'drawing': s.drawing,
      'recap': s.recap,
      'recapping': s.recapping,
      'liveliness': s.state.liveliness.name,
      'chain': s.state.chain,
      'cast': engine == null ? const [] : _cast(c, s, engine),
    };
  }

  List<Map<String, Object?>> _cast(
    _Client c,
    StorySession s,
    StoryEngine engine,
  ) {
    final here = s.state.present;
    final player = engine.world.player;
    return [
      if (player != null) _person(c, s, player, here: true, you: true),
      for (final id in here)
        if (engine.world.cast[id] case final ch?)
          _person(c, s, ch, here: true, pinned: s.state.pinned.contains(id)),
      for (final ch in engine.voices)
        if (!here.contains(ch.id)) _person(c, s, ch, here: false),
    ];
  }

  Map<String, Object?> _person(
    _Client c,
    StorySession s,
    VocesCharacter ch, {
    required bool here,
    bool pinned = false,
    bool you = false,
  }) {
    final pic = s.engine?.world.portraitOf(ch);
    return {
      'id': ch.id,
      'name': ch.name,
      'here': here,
      'pinned': pinned,
      'you': you,
      'art': _art(ch.name, ch.art),
      if (pic != null && pic.existsSync()) 'picture': c.ref(pic.path),
    };
  }

  Map<String, Object?> _turn(_Client c, StorySession s, StoryTurn t) {
    final pic = s.pictureOf(t);
    return {
      'id': t.id,
      'kind': t.kind.name,
      'text': switch (t.kind) {
        TurnKind.picture => '',
        TurnKind.narrator => StoryEngine.splitPlace(t.text).text,
        _ => t.text,
      },
      'speaker': t.speaker,
      'speakerId': t.speakerId,
      if (pic != null) 'picture': c.ref(pic.path),
      if (s.state.rolls[t.id] case final n?)
        'roll': {'n': n, 'outcome': Fortune.outcome(n)},
    };
  }

  Future<Map<String, Object?>> _storyOp(
    _Client c,
    String op,
    Map<String, Object?> r,
  ) async {
    final s = c.story;
    if (s == null || s.closed) throw const PhoneError('Open a story first.');
    switch (op) {
      case 'send':
        final kind = switch ('${r['kind']}') {
          'act' => TurnKind.act,
          'ask' => TurnKind.ask,
          _ => TurnKind.say,
        };
        if (s.busy) throw const PhoneError('Wait for the reply to finish.');
        unawaited(s.send(kind, '${r['text'] ?? ''}', roll: r['roll'] == true));
      case 'continue':
        unawaited(s.continueStory());
      case 'stop':
        s.stop();
      case 'jumpIn':
        s.jumpIn();
      case 'retry':
        unawaited(s.retry());
      case 'recap':
        unawaited(s.makeRecap());
      case 'closeRecap':
        s.closeRecap();
      case 'bringIn':
        await s.bringIn('${r['id']}');
      case 'sendAway':
        await s.sendAway('${r['id']}');
      case 'pin':
        final id = '${r['id']}';
        final pinned = {...s.state.pinned};
        r['on'] == true ? pinned.add(id) : pinned.remove(id);
        await s.saveState(s.state.copyWith(pinned: pinned));
      case 'liveliness':
        await s.saveState(
          s.state.copyWith(liveliness: Liveliness.byName(r['value'])),
        );
      case 'chain':
        final n = (r['value'] as num?)?.toInt() ?? 2;
        await s.saveState(
          s.state.copyWith(chain: n.clamp(0, StoryState.maxChain)),
        );
      case 'drawScene':
        final last = s.turns.where((t) => !t.kind.aside).lastOrNull;
        if (last == null) throw const PhoneError('Nothing to draw yet.');
        unawaited(s.drawScene(last));
      default:
        throw PhoneError('Unknown story request $op.');
    }
    return const {};
  }
}

class _Client {
  _Client(this.link);

  final PhoneLink link;

  /// Pictures this phone may fetch, by the name it was given for each:
  /// only files VoxCordis itself listed for it.
  final refs = <String, String>{};
  final _byPath = <String, String>{};

  String ref(String path) => _byPath[path] ??= () {
    final r = 'p${refs.length + 1}';
    refs[r] = path;
    return r;
  }();

  /// What the phone has of each message and turn.
  final sentMsgs = <String, int>{};
  final sentTurns = <int, int>{};
  Timer? chatTimer;

  final jobs = <DrawJob>{};

  StorySession? story;
  VoidCallback? storyListener;
  StreamSubscription<String>? storyNotices;
  Timer? storyTimer;
}

class _Ask {
  _Ask(this.links);
  final Set<PhoneLink> links;
  final done = Completer<bool>();
}
