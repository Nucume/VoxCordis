import 'dart:async';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'avatar_download.dart';
import 'import_temp.dart';
import 'imported_character.dart';
import 'soulkyn_link.dart';

/// Reads a Soulkyn page in a browser window: the system's WebKitGTK on
/// Linux, WebView2 on Windows. The human passes a Cloudflare check there
/// when one comes up, then the app reads the rendered page with
/// [SoulkynLink.fromHtml], the same reader a plain fetch uses.
///
/// The window only goes to Soulkyn and Cloudflare. Nothing from the page
/// runs in the app: it hands over its HTML as text, and that text is
/// cleaned like any other import.
class SoulkynBrowser {
  /// What the dialog shows while the window is open.
  final status = ValueNotifier<String>('Opening the page...');

  Webview? _view;
  bool _readNow = false;
  bool _closed = false;

  static const _poll = Duration(milliseconds: 1500);
  static const _giveUp = Duration(minutes: 15);
  static const _maxHtml = 5 << 20;

  /// Asks the page whether it is a character yet.
  static const _probe = r'''(() => {
  const t = document.title || '';
  const cf = /just a moment|attention required/i.test(t) ||
    !!document.querySelector('#challenge-form, #challenge-running, [name="cf-turnstile-response"], script[src*="challenges.cloudflare.com"]');
  const heads = [...document.querySelectorAll('h2, h3')].map(e => e.textContent.trim());
  const editor = !!document.querySelector('#persona_create_bg_story');
  const traits = editor || heads.some(h => /^(Personality|Physical) (Traits|Tags)/i.test(h));
  return {cf, traits, editor, named: !!document.querySelector('h1'), loading: document.readyState !== 'complete'};
})()''';

  /// Copies what the editor's fields hold into the HTML, which otherwise
  /// keeps only what the server first sent.
  static const _syncFields = r'''(() => {
  document.querySelectorAll('textarea').forEach(t => { t.textContent = t.value; });
  document.querySelectorAll('input').forEach(i => i.setAttribute('value', i.value));
  return true;
})()''';

  /// The avatar's address as the browser resolved it. When the avatar is
  /// a short video (`<video aria-label="Avatar video for …">`), its poster, or else one of its frames as a
  /// `data:image/jpeg` address. Soulkyn's `<video>` has no `crossorigin`,
  /// so drawing it would taint the canvas; a second, CORS-enabled copy of
  /// the clip is loaded instead, and 'pending' returned until it is ready.
  static const _avatar = r'''(() => {
  const imgs = [...document.images];
  const a = imgs.find(i => /persona avatar/i.test(i.alt));
  if (a) return a.currentSrc || a.src;
  const area = e => e.clientWidth * e.clientHeight;
  const named = e => /avatar video/i.test(e.getAttribute('aria-label') || '');
  const vids = [...document.querySelectorAll('video')];
  const v = vids.find(named) || vids
    .filter(e => area(e) >= 120 * 120 &&
      (/soulkyn\.(io|com)/.test(e.currentSrc || e.src || e.poster || '') ||
       e.closest('[class*="avatar" i],[aria-label*="avatar" i],[alt*="avatar" i]')))
    .sort((x, y) => area(y) - area(x))[0];
  if (v && v.poster) return v.poster;
  const src = v && (v.currentSrc || v.src);
  if (src) {
    const st = window.__vcFrame || (window.__vcFrame = { src: '', state: '' });
    if (st.src !== src) {
      st.src = src;
      st.state = 'pending';
      const c = document.createElement('video');
      c.crossOrigin = 'anonymous';
      c.muted = true;
      c.preload = 'auto';
      c.onloadeddata = () => {
        try {
          const k = Math.min(1, 1280 / Math.max(c.videoWidth, c.videoHeight));
          const cv = document.createElement('canvas');
          cv.width = Math.round(c.videoWidth * k);
          cv.height = Math.round(c.videoHeight * k);
          cv.getContext('2d').drawImage(c, 0, 0, cv.width, cv.height);
          st.state = cv.toDataURL('image/jpeg', 0.9);
        } catch (e) { st.state = 'failed'; }
      };
      c.onerror = () => { st.state = 'failed'; };
      c.src = src;
    }
    if (st.state !== 'failed') return st.state;
  }
  const b = imgs.filter(i => /soulkyn\.(io|com)/.test(i.currentSrc || i.src))
    .sort((x, y) => y.naturalWidth * y.naturalHeight - x.naturalWidth * x.naturalHeight)[0];
  return b ? (b.currentSrc || b.src) : null;
})()''';

  /// The address of the avatar's video, when the avatar is one.
  static const _avatarVideo = r'''(() => {
  const vids = [...document.querySelectorAll('video')];
  const area = e => e.clientWidth * e.clientHeight;
  const v = vids.find(e => /avatar video/i.test(e.getAttribute('aria-label') || '')) ||
    vids.filter(e => /soulkyn\.io\//.test(e.currentSrc || e.src || ''))
      .sort((x, y) => area(y) - area(x))[0];
  return v ? (v.currentSrc || v.src) : null;
})()''';

  /// Whether the page, as [_probe] described it, can be read now.
  /// With [editor], only the editor page will do.
  @visibleForTesting
  static String? waitingFor(Object? probe, {bool editor = false}) {
    if (probe is! Map) return 'Waiting for the page...';
    if (probe['cf'] == true) {
      return 'Soulkyn is checking the connection. If the window asks, '
          'confirm you are human there; the import goes on by itself.';
    }
    if (probe['loading'] == true) return 'Loading the page...';
    if (editor) {
      return probe['editor'] == true
          ? null
          : 'Waiting for the character\'s editor page. Log in to Soulkyn in '
                'the window if it asks, then open the character\'s Edit page '
                'if it doesn\'t open by itself.';
    }
    if (probe['traits'] == true) return null;
    if (probe['named'] == true) {
      return 'This page shows a custom profile. Switch it to the default '
          'view in the browser window, or press "Read the page now".';
    }
    return 'Waiting for the page...';
  }

  /// Only Soulkyn, its Cloudflare check and the sign-in services its
  /// login page may send to open in the window. The gallery download's
  /// window uses it too.
  static bool allowed(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.scheme != 'https') return false;
    bool under(String d) => u.host == d || u.host.endsWith('.$d');
    return under('soulkyn.com') ||
        under('soulkyn.io') ||
        under('cloudflare.com') ||
        u.host == 'accounts.google.com' ||
        u.host == 'discord.com' ||
        u.host == 'appleid.apple.com';
  }

  /// Whether copied [text] is a sign-in link from Soulkyn's email: an
  /// https link to Soulkyn, or one that mentions it (mail trackers wrap
  /// it), but not a character page.
  static bool looksLikeSignInLink(String text) {
    if (text.contains(RegExp(r'\s'))) return false;
    final u = Uri.tryParse(text);
    if (u == null || u.scheme != 'https' || u.host.isEmpty) return false;
    return text.toLowerCase().contains('soulkyn') &&
        SoulkynLink.parse(text) == null;
  }

  /// Opens a link the human pasted, such as the sign-in link from
  /// Soulkyn's email, which would otherwise open in their own browser and
  /// log in there instead. False when it is not an https link or no window
  /// is open.
  Future<bool> openLink(String link) async {
    final u = Uri.tryParse(link.trim());
    final view = _view;
    if (u == null || u.scheme != 'https' || u.host.isEmpty || view == null) {
      return false;
    }
    // The human chose it, and mail links often pass through a tracker
    // first, so this one navigation skips the Soulkyn-only check.
    await view.launch(u.toString(), triggerOnUrlRequestEvent: false);
    _signedIn = true;
    return true;
  }

  /// Set once the window went through signing in (a pasted email link or
  /// a sign-in page), so going back to the editor can't interrupt a login
  /// form on Soulkyn's home page.
  bool _signedIn = false;
  int _returns = 0;
  DateTime _lastReturn = DateTime.now();
  static const _settle = Duration(seconds: 6);

  /// Whether, waiting for the editor, the window is on a Soulkyn page that
  /// is neither the editor nor part of signing in, so it should go back.
  @visibleForTesting
  static bool backToEditor(String? url) {
    final u = Uri.tryParse(url ?? '');
    if (u == null || !RegExp(r'(^|\.)soulkyn\.(com|io)$').hasMatch(u.host)) {
      return false;
    }
    if (SoulkynLink.isEditLink(u)) return false;
    return !_isSignIn(url);
  }

  static bool _isSignIn(String? url) {
    final u = Uri.tryParse(url ?? '');
    if (u == null) return false;
    if (u.host == 'accounts.google.com' || u.host == 'discord.com') return true;
    return RegExp(
      r'login|log-in|signin|sign-in|auth|magic|verify|token|callback|register',
      caseSensitive: false,
    ).hasMatch('${u.path}?${u.query}');
  }

  /// Reads whatever the page shows now instead of waiting for traits.
  void readNow() => _readNow = true;

  /// Opens [url] and waits for a readable character page, or with
  /// [editor] for the character's editor page, which needs its owner
  /// logged in. Throws [SoulkynLinkFailed] when there is no browser, or the
  /// human closes it.
  Future<ImportedCharacter> read(Uri url, {bool editor = false}) async {
    final Webview view;
    try {
      final windows = await windowsOptions();
      view = _view = await WebviewWindow.create(
        configuration: CreateConfiguration(
          windowWidth: 1100,
          windowHeight: 820,
          title: 'Soulkyn',
          windows: windows,
        ),
      );
    } on MissingPluginException {
      throw SoulkynLinkFailed(
        Platform.isLinux
            ? 'The app can\'t open a browser window here: WebKitGTK '
                  '(libwebkit2gtk-4.1) isn\'t installed.'
            : 'The app can\'t open a browser window here.',
      );
    } on PlatformException catch (e) {
      throw SoulkynLinkFailed(
        'The app can\'t open a browser window here (${e.message ?? e.code}).',
      );
    }
    unawaited(view.onClose.then((_) => _closed = true));
    await view.setOnUrlRequestCallback(allowed);
    await view.launch(url.toString());

    final end = DateTime.now().add(_giveUp);
    try {
      while (DateTime.now().isBefore(end)) {
        await Future<void>.delayed(_poll);
        if (_closed) {
          throw const SoulkynLinkFailed('The browser window was closed.');
        }
        final here = view.navigationState.value;
        if (_isSignIn(here.url)) _signedIn = true;
        if (editor &&
            _signedIn &&
            !here.isLoading &&
            backToEditor(here.url) &&
            _returns < 3 &&
            DateTime.now().difference(_lastReturn) > _settle) {
          // Signed in, and Soulkyn showed its home page instead.
          _returns++;
          _lastReturn = DateTime.now();
          status.value = 'Signed in. Opening the Edit page again...';
          await view.launch(url.toString());
          continue;
        }
        final page = SoulkynLink.parse(here.url ?? '');
        if (page == null) {
          status.value = editor
              ? 'Waiting for the character\'s editor page. Log in to Soulkyn '
                    'in the window if it asks.'
              : 'Waiting for a character page on Soulkyn...';
          continue;
        }
        Object? probe;
        try {
          probe = await view.evaluateJavaScript(_probe);
        } on PlatformException {
          continue; // Mid-navigation.
        }
        final wait = waitingFor(probe, editor: editor);
        if (wait != null &&
            !(_readNow && probe is Map && probe['cf'] != true)) {
          status.value = wait;
          continue;
        }
        _readNow = false;
        status.value = 'Reading the page...';
        var avatar = await view.evaluateJavaScript(_avatar);
        // A video avatar's frame takes a moment to load.
        for (var i = 0; i < 20 && avatar == 'pending'; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          avatar = await view.evaluateJavaScript(_avatar);
        }
        if (avatar == 'pending') avatar = null;
        // Both versions of the avatar from the page's data, or else the
        // video it shows.
        Object? read;
        try {
          read = await view.evaluateJavaScript(soulkynPersonaAvatars);
        } on PlatformException {
          read = null;
        }
        var avatars = SoulkynLink.avatarSetFrom(read);
        if (avatars == null) {
          final clip = await view.evaluateJavaScript(_avatarVideo);
          final video = SoulkynLink.videoFrom([if (clip is String) clip], page);
          if (video != null) avatars = AvatarSet(video: video);
        }
        var hint = avatar is String ? avatar : null;
        File? frame;
        if (hint != null && hint.startsWith('data:image/')) {
          // A still of the video avatar.
          frame = await AvatarDownload.saveFrame(hint);
          hint = null;
        }
        if (editor) {
          final fields = await view.evaluateJavaScript(soulkynEditorReader);
          if (fields is Map) {
            return SoulkynLink.fromEditor(
              fields,
              page,
              avatarHint: hint,
              avatars: avatars,
              portrait: frame,
            );
          }
        }
        await view.evaluateJavaScript(_syncFields);
        final html = await view.evaluateJavaScript(
          'document.documentElement.outerHTML',
        );
        if (html is! String || html.length > _maxHtml) continue;
        final c = SoulkynLink.fromHtml(
          html,
          page,
          avatarHint: hint,
          avatars: avatars,
          portrait: frame,
        );
        if (c != null) return c;
        if (frame != null) await ImportTemp.remove(frame.path);
        status.value = 'The page has no character details yet.';
      }
      throw const SoulkynLinkFailed('The page never showed the character.');
    } finally {
      await close();
    }
  }

  /// Closes the window. The Soulkyn login stays in the browser's own
  /// files, so the next import, avatar or gallery download doesn't ask
  /// again, until [logOut].
  Future<void> close() async {
    final view = _view;
    _view = null;
    if (view != null && !_closed) {
      try {
        await view.close();
      } on Object {
        // Already gone.
      }
    }
  }

  /// The browser's own files, shared by every Soulkyn window.
  static Future<WindowsWebviewOptions> windowsOptions() async =>
      WindowsWebviewOptions(
        userDataFolder: p.join(
          (await getApplicationSupportDirectory()).path,
          'WebView2',
        ),
      );

  /// Wipes what the Soulkyn windows kept: cookies, the login and their
  /// storage. The next one signs in again.
  static Future<void> logOut() async {
    try {
      await WebviewWindow.clearAll(windows: await windowsOptions());
    } on Object {
      // No browser, or its files are busy.
    }
  }
}
