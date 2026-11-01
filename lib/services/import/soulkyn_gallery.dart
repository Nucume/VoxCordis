import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'soulkyn_browser.dart';
import 'soulkyn_link.dart';
import 'soulkyn_media.dart';

/// Lists every picture and video in a Soulkyn character's gallery, in a
/// browser window like [SoulkynBrowser].
///
/// Soulkyn's app loads the gallery from its own API with a signed request,
/// which only it can make. So the window opens the character's Gallery and
/// Videos tabs the way a person would, and a small script in the page
/// keeps a copy of the lists the app gets back. Only those lists come back
/// to the app, as JSON text; the files themselves are on Soulkyn's public
/// file server and [SoulkynMediaDownload] fetches them.
class SoulkynGallery {
  final status = ValueNotifier<String>('Opening the page...');

  Webview? _view;
  bool _closed = false;

  static const _poll = Duration(milliseconds: 800);
  static const _giveUp = Duration(minutes: 15);

  /// How long a tab gets to load its list before the window clicks it, and
  /// before it is given up on.
  static const _nudgeAfter = Duration(seconds: 6);
  static const _tabGiveUp = Duration(seconds: 30);

  /// Runs in the page before Soulkyn's own scripts and keeps a copy of
  /// each gallery list (`…/Persona/<slug>/_Images/…` or `_Videos`) the app
  /// fetches. It changes nothing the app sends or gets.
  @visibleForTesting
  static const capture = r'''(() => {
  if (window.__vcGal) return;
  window.__vcGal = [];
  const re = /\/_special\/rest\/Sk\/public\/Persona\/([^/?#]+)\/_(Images|Videos)\//;
  const keep = (url, j, status) => {
    const m = re.exec(url || '');
    if (!m) return;
    let slug = m[1];
    try { slug = decodeURIComponent(slug); } catch (e) {}
    if (!j || !Array.isArray(j.data)) {
      window.__vcGal.push({slug, kind: m[2], status: status || 0});
      return;
    }
    window.__vcGal.push({slug, kind: m[2], paging: j.paging || null, data: j.data});
  };
  const f = window.fetch;
  if (f) window.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || String(input);
    const r = f.apply(this, arguments);
    if (re.test(url)) r.then(res => res.clone().json().then(j => keep(url, j, res.status), () => keep(url, null, res.status))).catch(() => {});
    return r;
  };
  const open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, url) {
    this.__vcUrl = String(url);
    return open.apply(this, arguments);
  };
  const send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function () {
    if (re.test(this.__vcUrl || '')) this.addEventListener('load', () => {
      let j = null;
      try { j = JSON.parse(this.responseText); } catch (e) {}
      keep(this.__vcUrl, j, this.status);
    });
    return send.apply(this, arguments);
  };
})();''';

  static const _drain = r'''(() => {
  const g = window.__vcGal || [];
  if (window.__vcGal) window.__vcGal = [];
  const cf = /just a moment|attention required/i.test(document.title || '') ||
    !!document.querySelector('#challenge-form, #challenge-running, [name="cf-turnstile-response"]');
  return JSON.stringify({cf, ready: document.readyState === 'complete', lists: g});
})()''';

  /// Clicks the tab or page button whose text is [label], or starts with
  /// it for a tab ("Videos (6)").
  static String _click(String label, {bool exact = false}) =>
      '''(() => {
  const want = ${jsonEncode(label.toLowerCase())};
  const el = [...document.querySelectorAll('a, button, [role="tab"]')].find(e => {
    const t = (e.textContent || '').trim().toLowerCase();
    return ${exact ? 't === want' : 't === want || t.startsWith(want + " ") || t.startsWith(want + "(")'};
  });
  if (el) el.click();
  // A list further down may only load once it scrolls into view.
  window.scrollTo(0, document.body.scrollHeight);
  return !!el;
})()''';

  /// Opens the character [page] links to and returns everything its
  /// gallery lists. Throws [SoulkynLinkFailed] when there is no browser,
  /// the human closes it, or the gallery never loads.
  Future<List<SoulkynMedia>> read(Uri page) async {
    final slug = SoulkynLink.slug(page);
    if (slug == null) throw const SoulkynLinkFailed('That is not a Kyn link.');
    final profile = Uri.https('soulkyn.com', '/l/en-US/@$slug');
    final view = await _open();
    await view.launch(profile.toString());
    final end = DateTime.now().add(_giveUp);
    final pages = <String, Map<int, List<SoulkynMedia>>>{
      'Images': {},
      'Videos': {},
    };
    final pageMax = <String, int>{};

    /// Waits until [kind]'s page [n] has come in; false when it didn't.
    Future<bool> waitFor(
      String kind,
      int n, {
      required String what,
      String? tab,
      bool patient = false,
    }) async {
      var started = DateTime.now();
      var nudged = false;
      int? refused;
      while (DateTime.now().isBefore(end)) {
        await Future<void>.delayed(_poll);
        if (_closed) {
          throw const SoulkynLinkFailed('The browser window was closed.');
        }
        Object? raw;
        try {
          raw = await view.evaluateJavaScript(_drain);
        } on PlatformException {
          continue; // Mid-navigation.
        }
        final got = _decode(raw);
        if (got == null) continue;
        if (got['cf'] == true) {
          status.value =
              'Soulkyn is checking the connection. If the window asks, '
              'confirm you are human there; the download goes on by itself.';
          started = DateTime.now();
          continue;
        }
        for (final l in (got['lists'] as List? ?? const [])) {
          if (l is! Map || '${l['slug']}'.toLowerCase() != slug.toLowerCase()) {
            continue;
          }
          final k = '${l['kind']}';
          if (!pages.containsKey(k)) continue;
          if (l['data'] == null) {
            refused = (l['status'] as num?)?.toInt();
            continue;
          }
          final paging = l['paging'];
          final no = paging is Map
              ? (paging['page_no'] as num?)?.toInt()
              : null;
          final max = paging is Map
              ? (paging['page_max'] as num?)?.toInt()
              : null;
          pages[k]![no ?? 1] = SoulkynMedia.fromApi(k, l['data']);
          pageMax[k] = max ?? pageMax[k] ?? 1;
        }
        if (pages[kind]!.containsKey(n)) return true;
        final waited = DateTime.now().difference(started);
        status.value = refused != null
            ? 'Soulkyn didn\'t show the gallery ($refused). Log in to Soulkyn '
                  'in the window; the download goes on by itself.'
            : patient && waited > _tabGiveUp
            ? 'Still waiting for $what. If Soulkyn asks you to log in, do it '
                  'in the window, or open the Gallery tab there yourself.'
            : 'Waiting for $what...';
        if (got['ready'] == true &&
            (!nudged || waited > _tabGiveUp && waited.inSeconds % 15 == 0)) {
          if (waited < _nudgeAfter) continue;
          nudged = true;
          try {
            await view.evaluateJavaScript(
              tab != null ? _click(tab) : _click('$n', exact: true),
            );
          } on PlatformException {
            // Try again on the next round.
            nudged = false;
          }
        }
        if (!patient && waited > _tabGiveUp) return false;
      }
      return false;
    }

    try {
      if (!await waitFor(
        'Images',
        1,
        what: 'the Gallery tab',
        tab: 'Gallery',
        patient: true,
      )) {
        throw const SoulkynLinkFailed(
          'The character\'s gallery never loaded. Check the link, or log in '
          'to Soulkyn in the window and try again.',
        );
      }
      for (var n = 2; n <= (pageMax['Images'] ?? 1) && n <= 100; n++) {
        if (!await waitFor('Images', n, what: 'gallery page $n')) break;
      }
      final videos = profile.replace(path: '${profile.path}/videos');
      await view.launch(videos.toString());
      if (await waitFor('Videos', 1, what: 'the Videos tab', tab: 'Videos')) {
        for (var n = 2; n <= (pageMax['Videos'] ?? 1) && n <= 100; n++) {
          await view.launch(
            videos.replace(queryParameters: {'page': '$n'}).toString(),
          );
          if (!await waitFor('Videos', n, what: 'videos page $n')) break;
        }
      }
      return SoulkynMedia.unique([
        for (final k in ['Images', 'Videos'])
          for (final n in pages[k]!.keys.toList()..sort()) ...pages[k]![n]!,
      ]);
    } finally {
      await close();
    }
  }

  static Map<Object?, Object?>? _decode(Object? raw) {
    // WebKitGTK hands back the string; WebView2 may wrap it in JSON again.
    for (var i = 0; i < 2 && raw is String; i++) {
      try {
        raw = jsonDecode(raw);
      } on FormatException {
        return null;
      }
    }
    return raw is Map ? raw : null;
  }

  Future<Webview> _open() async {
    try {
      final windows = await SoulkynBrowser.windowsOptions();
      final view = _view = await WebviewWindow.create(
        configuration: CreateConfiguration(
          windowWidth: 1100,
          windowHeight: 820,
          title: 'Soulkyn',
          windows: windows,
        ),
      );
      unawaited(view.onClose.then((_) => _closed = true));
      await view.setOnUrlRequestCallback(SoulkynBrowser.allowed);
      await view.addScriptToExecuteOnDocumentCreated(capture);
      return view;
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
  }

  /// Opens a sign-in link from Soulkyn's email in the window, like
  /// [SoulkynBrowser.openLink].
  Future<bool> openLink(String link) async {
    final u = Uri.tryParse(link.trim());
    final view = _view;
    if (u == null || u.scheme != 'https' || u.host.isEmpty || view == null) {
      return false;
    }
    await view.launch(u.toString(), triggerOnUrlRequestEvent: false);
    return true;
  }

  /// Closes the window; the login stays, as with [SoulkynBrowser.close].
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
}
