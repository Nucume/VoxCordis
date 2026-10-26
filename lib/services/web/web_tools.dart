import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../data/settings.dart';
import '../import/untrusted_text.dart';
import 'headless_browser.dart';
import 'page_text.dart';
import 'web_guard.dart';
import 'web_search.dart';

/// Asks the human about a browser action that does something on a site
/// (sending a form, typing into a field that isn't a search box). Set by
/// the window; with nothing set those actions are refused.
typedef WebAsk = Future<bool> Function(WebRequest request);

/// A browser action waiting for the human's OK.
class WebRequest {
  const WebRequest({required this.site, required this.action, this.why = ''});

  /// The site the action happens on, e.g. `example.com`.
  final String site;

  /// What would happen, in plain words.
  final String action;
  final String why;
}

/// The companion's internet tools, offered while Settings → Internet is
/// on: search, read a page, and (with its own browser on) browse a site in
/// a browser without a window.
///
/// Everything a page says comes back marked as information, never as
/// instructions, and after reading the web the companion can't use system
/// tools in the same reply (see [ChatController]).
class WebTools {
  WebTools({
    required this.settings,
    required this.browser,
    required this.searchKey,
    http.Client? client,
    WebSearch? search,
  }) : _http = client ?? http.Client(),
       _search =
           search ??
           WebSearch(settings: settings, client: client, apiKey: searchKey);

  final AppSettings Function() settings;
  final HeadlessBrowser browser;
  final Future<String> Function() searchKey;
  final http.Client _http;
  final WebSearch _search;

  WebAsk? ask;

  static const searchTool = 'web_search';
  static const readTool = 'read_page';
  static const browseTools = {
    'browse',
    'browse_click',
    'browse_type',
    'browse_scroll',
    'browse_back',
  };
  static const names = {searchTool, readTool, ...browseTools};

  static const _maxBytes = 4 << 20;
  static const _timeout = Duration(seconds: 25);

  WebGuard get _guard => WebGuard(blocked: settings().blockedSites);

  static Map<String, Object?> _tool(
    String name,
    String description,
    Map<String, Object?> properties,
    List<String> required,
  ) => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': properties,
        'required': required,
      },
    },
  };

  static List<Map<String, Object?>> definitionsFor(AppSettings s) => [
    if (s.internetAccess) ...[
      _tool(
        searchTool,
        'Search the web. Use it for anything current or that you don\'t '
        'know for sure: news, weather, prices, facts, opening hours. '
        'Then read_page the best result if the snippets aren\'t enough.',
        {
          'query': {'type': 'string', 'description': 'What to search for.'},
        },
        ['query'],
      ),
      _tool(
        readTool,
        'Read a web page as text: an address from web_search, or one your '
        'human gave you.',
        {
          'url': {'type': 'string', 'description': 'The full https address.'},
        },
        ['url'],
      ),
    ],
    if (s.internetAccess && s.companionBrowser) ...[
      _tool(
        'browse',
        'Open a page in your own browser, for sites that need clicking or '
            'typing (a site\'s own search, menus, more results). You get '
            'its text and numbered items to click or type into.',
        {
          'url': {'type': 'string', 'description': 'The full https address.'},
        },
        ['url'],
      ),
      _tool(
        'browse_click',
        'Click item n on the page open in your browser.',
        {
          'n': {'type': 'integer', 'description': 'The item\'s number.'},
          'why': {
            'type': 'string',
            'description': 'Why, in a few words, in case your human is asked.',
          },
        },
        ['n'],
      ),
      _tool(
        'browse_type',
        'Type into field n on the page open in your browser, e.g. a search '
            'box. Never type passwords or your human\'s private details.',
        {
          'n': {'type': 'integer', 'description': 'The field\'s number.'},
          'text': {'type': 'string', 'description': 'What to type.'},
          'submit': {
            'type': 'boolean',
            'description': 'Press Enter afterwards, e.g. to search.',
          },
          'why': {
            'type': 'string',
            'description': 'Why, in a few words, in case your human is asked.',
          },
        },
        ['n', 'text'],
      ),
      _tool(
        'browse_scroll',
        'Scroll the page open in your browser to read more.',
        {
          'direction': {
            'type': 'string',
            'enum': ['down', 'up'],
          },
        },
        [],
      ),
      _tool('browse_back', 'Go back a page in your browser.', {}, []),
    ],
  ];

  /// Runs one tool call and returns the JSON string sent back to the model.
  /// [unattended] is a scheduled run with nobody there to ask, so actions
  /// that need the human's OK are refused.
  Future<String> call(
    String name,
    Map<String, Object?> args, {
    bool unattended = false,
  }) async {
    final s = settings();
    try {
      if (!s.internetAccess) {
        throw 'Internet access is off. Your human can turn it on in '
            'Settings → Internet.';
      }
      if (browseTools.contains(name) && !s.companionBrowser) {
        throw 'Your browser is off. Your human can turn it on in Settings '
            '→ Internet.';
      }
      final result = switch (name) {
        searchTool => await _searchCall('${args['query'] ?? ''}'),
        readTool => await _read(_parseUrl(args['url'])),
        'browse' => (await browser.open(
          _parseUrl(args['url']),
          _guard,
        )).toToolResult(),
        'browse_click' => await _click(_ref(args), args, unattended),
        'browse_type' => await _type(_ref(args), args, unattended),
        'browse_scroll' => (await browser.scroll(
          _guard,
          up: args['direction'] == 'up',
        )).toToolResult(),
        'browse_back' => (await browser.back(_guard)).toToolResult(),
        _ => throw 'unknown tool $name',
      };
      return jsonEncode(result);
    } on BrowserMissing catch (e) {
      return jsonEncode({'ok': false, 'error': '$e'});
    } on TimeoutException {
      return jsonEncode({'ok': false, 'error': 'The site took too long.'});
    } catch (e) {
      return jsonEncode({'ok': false, 'error': '$e'});
    }
  }

  static int _ref(Map<String, Object?> args) {
    final n = args['n'];
    final ref = n is int ? n : int.tryParse('$n');
    if (ref == null) throw '"n" must be an item number from the page.';
    return ref;
  }

  static Uri _parseUrl(Object? raw) {
    var s = '${raw ?? ''}'.trim();
    if (s.isEmpty) throw '"url" is empty';
    if (!s.contains('://')) s = 'https://$s';
    final url = Uri.tryParse(s);
    if (url == null || url.host.isEmpty) throw '$raw is not a web address.';
    return url;
  }

  Future<Map<String, Object?>> _searchCall(String query) async {
    List<SearchHit> hits;
    try {
      hits = await _search.search(query);
    } catch (e) {
      // The no-key search sometimes asks "are you a robot?"; a real
      // browser gets through.
      if (settings().searchProvider != SearchProvider.duckDuckGo ||
          !settings().companionBrowser) {
        rethrow;
      }
      hits = const [];
    }
    if (hits.isEmpty &&
        settings().searchProvider == SearchProvider.duckDuckGo &&
        settings().companionBrowser) {
      hits = await _searchInBrowser(query);
    }
    return {
      'ok': true,
      'query': query,
      'note': PageText.untrustedNote,
      'results': [for (final h in hits) h.toJson()],
      if (hits.isEmpty) 'error': 'Nothing found. Try other words.',
    };
  }

  Future<List<SearchHit>> _searchInBrowser(String query) async {
    await browser.open(
      Uri.https('duckduckgo.com', '/', {'q': query, 'ia': 'web'}),
      const WebGuard(),
    );
    final found = await browser.evaluate(_duckDuckGoResults);
    return [
      for (final r in (found as List? ?? const []).whereType<Map>())
        if ('${r['url']}'.startsWith('http'))
          SearchHit(
            UntrustedText.clean('${r['title'] ?? ''}'),
            '${r['url']}',
            UntrustedText.clean('${r['snippet'] ?? ''}'),
          ),
    ].take(WebSearch.maxResults).toList();
  }

  /// The organic results on DuckDuckGo's own page, without ads.
  static const _duckDuckGoResults = '''
[...document.querySelectorAll('article[data-testid=result]')].map(r => {
  const a = r.querySelector('a[data-testid=result-title-a]');
  const sn = r.querySelector('[data-result=snippet]');
  return {title: a ? a.innerText : '', url: a ? a.href : '', snippet: sn ? sn.innerText : ''};
})''';

  /// Fetches [url] without a browser, following redirects only to sites
  /// that may be visited.
  Future<Map<String, Object?>> _read(Uri url) async {
    final guard = _guard;
    var at = url;
    for (var hop = 0; hop < 6; hop++) {
      final why = guard.refuse(at);
      if (why != null) throw why;
      if (!await WebGuard.resolvesPublic(at.host)) {
        throw 'That site points into the home network, which is off limits.';
      }
      final req = http.Request('GET', at)
        ..followRedirects = false
        ..headers.addAll({
          'User-Agent': WebSearch.userAgent,
          'Accept': 'text/html,application/xhtml+xml,text/plain;q=0.9',
          'Accept-Language': 'en;q=0.9,*;q=0.5',
        });
      final res = await _http.send(req).timeout(_timeout);
      if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400)) {
        final to = res.headers['location'];
        res.stream.drain<void>().ignore();
        if (to == null) throw '${at.host} sent a redirect with no address.';
        at = at.resolve(to);
        continue;
      }
      if (res.statusCode != 200) {
        res.stream.drain<void>().ignore();
        if (settings().companionBrowser &&
            (res.statusCode == 403 || res.statusCode == 429)) {
          return (await browser.open(at, guard)).toToolResult();
        }
        throw '${at.host} answered HTTP ${res.statusCode}.';
      }
      final type = res.headers['content-type'] ?? '';
      if (!type.contains('html') && !type.startsWith('text/')) {
        res.stream.drain<void>().ignore();
        throw 'That address is not a web page ($type), so it can\'t be read.';
      }
      final bytes = <int>[];
      await for (final chunk in res.stream.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBytes) break;
      }
      final body = utf8.decode(bytes, allowMalformed: true);
      if (!type.contains('html')) {
        return PageText(
          url: at,
          title: at.pathSegments.lastOrNull ?? at.host,
          text: body.length > 12000 ? body.substring(0, 12000) : body,
          cut: body.length > 12000,
        ).toToolResult();
      }
      final page = PageText.fromHtml(body, at, maxChars: maxPageChars());
      // Pages built by scripts are nearly empty without a browser.
      if (page.text.length < 200 && settings().companionBrowser) {
        return (await browser.open(at, guard)).toToolResult();
      }
      return page.toToolResult();
    }
    throw 'Too many redirects.';
  }

  /// About a third of the memory span, at roughly 4 characters a token.
  int maxPageChars() => (settings().contextSize * 4 ~/ 3).clamp(3000, 24000);

  Future<Map<String, Object?>> _click(
    int ref,
    Map<String, Object?> args,
    bool unattended,
  ) async {
    final e = await browser.element(ref);
    if (e == null) throw 'There is no item $ref on the page now.';
    if (e.submits) {
      await _approve(
        'press "${e.label.isEmpty ? 'Send' : e.label}"',
        args,
        unattended,
      );
    }
    return (await browser.click(ref, _guard)).toToolResult();
  }

  Future<Map<String, Object?>> _type(
    int ref,
    Map<String, Object?> args,
    bool unattended,
  ) async {
    final text = '${args['text'] ?? ''}';
    final e = await browser.element(ref);
    if (e == null) throw 'There is no item $ref on the page now.';
    if (e.password) {
      throw 'You never type into password fields. Your human logs in '
          'themselves.';
    }
    if (!e.search) {
      await _approve(
        'type "$text" into ${e.label.isEmpty ? 'a field' : '"${e.label}"'}'
        '${args['submit'] == true ? ' and send it' : ''}',
        args,
        unattended,
      );
    }
    return (await browser.type(
      ref,
      text,
      _guard,
      submit: args['submit'] == true,
    )).toToolResult();
  }

  Future<void> _approve(
    String action,
    Map<String, Object?> args,
    bool unattended,
  ) async {
    if (unattended) {
      throw 'Not done: this needs your human\'s OK, and they aren\'t here. '
          'Tell them about it instead.';
    }
    final ok =
        await ask?.call(
          WebRequest(
            site: browser.currentUrl?.host ?? 'the page',
            action: action,
            why: '${args['why'] ?? ''}'.trim(),
          ),
        ) ??
        false;
    if (!ok) throw 'Your human said no. Don\'t try another way around it.';
  }

  /// The line under the reply for a successful call.
  static String? noteFor(String name, Map<String, Object?> args) {
    String host() {
      final u = Uri.tryParse('${args['url'] ?? ''}');
      return u == null || u.host.isEmpty ? '${args['url']}' : u.host;
    }

    return switch (name) {
      searchTool => 'Searched the web',
      readTool => 'Read ${host()}',
      'browse' => 'Browsed ${host()}',
      _ => null,
    };
  }

  void close() {
    _http.close();
    _search.close();
    browser.close().ignore();
  }
}
