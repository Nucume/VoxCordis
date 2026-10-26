import 'dart:convert';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../../data/settings.dart';
import '../import/untrusted_text.dart';

/// One search result.
class SearchHit {
  const SearchHit(this.title, this.url, this.snippet);

  final String title;
  final String url;
  final String snippet;

  Map<String, Object?> toJson() => {
    'title': title,
    'url': url,
    if (snippet.isNotEmpty) 'snippet': snippet,
  };
}

/// Searches the web with the provider the human picked in Settings →
/// Internet. DuckDuckGo needs no account; Brave and Tavily want a key;
/// SearXNG is the human's own (or a public) instance.
class WebSearch {
  WebSearch({required this.settings, http.Client? client, this.apiKey})
    : _http = client ?? http.Client();

  final AppSettings Function() settings;

  /// The provider key, kept by [SecretStore]; read when needed.
  final Future<String> Function()? apiKey;
  final http.Client _http;

  static const maxResults = 8;
  static const _timeout = Duration(seconds: 20);

  /// Browser-like, so the no-key page doesn't think it's a bot.
  static const userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like '
      'Gecko) Chrome/130.0 Safari/537.36';

  Future<List<SearchHit>> search(String query) async {
    final s = settings();
    final q = query.trim();
    if (q.isEmpty) throw '"query" is empty';
    final hits = switch (s.searchProvider) {
      SearchProvider.duckDuckGo => await _duckDuckGo(q),
      SearchProvider.brave => await _brave(q, await _key('Brave')),
      SearchProvider.tavily => await _tavily(q, await _key('Tavily')),
      SearchProvider.searxng => await _searxng(q, s.searxngUrl),
    };
    return [
      for (final h in hits.take(maxResults))
        SearchHit(
          UntrustedText.clean(h.title),
          h.url,
          UntrustedText.clean(h.snippet),
        ),
    ];
  }

  Future<String> _key(String name) async {
    final key = (await apiKey?.call() ?? '').trim();
    if (key.isEmpty) {
      throw '$name search needs an API key. Your human can add it in '
          'Settings → Internet.';
    }
    return key;
  }

  Future<http.Response> _get(Uri url, Map<String, String> headers) async {
    final res = await _http.get(url, headers: headers).timeout(_timeout);
    if (res.statusCode != 200) {
      throw 'The search service answered HTTP ${res.statusCode}.';
    }
    return res;
  }

  Future<List<SearchHit>> _duckDuckGo(String q) async {
    final res = await _http
        .post(
          Uri.parse('https://html.duckduckgo.com/html/'),
          headers: {
            'User-Agent': userAgent,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: {'q': q, 'kl': 'wt-wt'},
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw 'DuckDuckGo answered HTTP ${res.statusCode}. It sometimes '
          'limits searches; your human can pick another search service in '
          'Settings → Internet.';
    }
    return parseDuckDuckGo(utf8.decode(res.bodyBytes, allowMalformed: true));
  }

  /// Results from DuckDuckGo's plain HTML page. Its links go through a
  /// redirect (`//duckduckgo.com/l/?uddg=<address>`); the address is taken
  /// out of it, and ads are skipped.
  static List<SearchHit> parseDuckDuckGo(String source) {
    final doc = html.parse(source);
    final hits = <SearchHit>[];
    for (final r in doc.querySelectorAll('.result')) {
      if (r.classes.contains('result--ad')) continue;
      final a = r.querySelector('a.result__a');
      if (a == null) continue;
      var href = a.attributes['href'] ?? '';
      if (href.startsWith('//')) href = 'https:$href';
      final link = Uri.tryParse(href);
      final real = link?.queryParameters['uddg'] ?? href;
      if (!real.startsWith('http') || real.contains('duckduckgo.com/y.js')) {
        continue;
      }
      hits.add(
        SearchHit(
          a.text.trim(),
          real,
          (r.querySelector('.result__snippet')?.text ?? '').trim(),
        ),
      );
    }
    return hits;
  }

  Future<List<SearchHit>> _brave(String q, String key) async {
    final res = await _get(
      Uri.https('api.search.brave.com', '/res/v1/web/search', {
        'q': q,
        'count': '$maxResults',
      }),
      {'Accept': 'application/json', 'X-Subscription-Token': key},
    );
    final results =
        ((jsonDecode(res.body) as Map)['web'] as Map?)?['results'] as List? ??
        const [];
    return [
      for (final r in results.whereType<Map>())
        SearchHit(
          '${r['title'] ?? ''}',
          '${r['url'] ?? ''}',
          _stripTags('${r['description'] ?? ''}'),
        ),
    ];
  }

  Future<List<SearchHit>> _tavily(String q, String key) async {
    final res = await _http
        .post(
          Uri.parse('https://api.tavily.com/search'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $key',
          },
          body: jsonEncode({'query': q, 'max_results': maxResults}),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      throw 'Tavily answered HTTP ${res.statusCode}.';
    }
    final results = (jsonDecode(res.body) as Map)['results'] as List? ?? [];
    return [
      for (final r in results.whereType<Map>())
        SearchHit(
          '${r['title'] ?? ''}',
          '${r['url'] ?? ''}',
          '${r['content'] ?? ''}',
        ),
    ];
  }

  Future<List<SearchHit>> _searxng(String q, String base) async {
    final b = Uri.tryParse(base.trim());
    if (b == null || !b.hasScheme || b.host.isEmpty) {
      throw 'SearXNG needs its address. Your human can add it in Settings '
          '→ Internet.';
    }
    final res = await _get(
      b.replace(
        path: '${b.path.replaceFirst(RegExp(r'/+$'), '')}/search',
        queryParameters: {'q': q, 'format': 'json'},
      ),
      {'Accept': 'application/json', 'User-Agent': userAgent},
    );
    final results = (jsonDecode(res.body) as Map)['results'] as List? ?? [];
    return [
      for (final r in results.whereType<Map>())
        SearchHit(
          '${r['title'] ?? ''}',
          '${r['url'] ?? ''}',
          '${r['content'] ?? ''}',
        ),
    ];
  }

  static String _stripTags(String s) =>
      s.replaceAll(RegExp(r'<[^>]{0,40}>'), '');

  void close() => _http.close();
}
