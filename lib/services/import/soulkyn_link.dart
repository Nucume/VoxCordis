import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'character_card.dart';
import 'imported_character.dart';

/// Imports a Soulkyn character from a pasted page link, e.g.
/// `https://soulkyn.com/l/en-US/@aurora-skye`.
///
/// The app reads the public page the way a browser would see it before any
/// script runs. That page may be behind a Cloudflare check, and it may not
/// carry the tag lists the exporter bookmarklet reads from a logged-in
/// page, so [fetch] throws [SoulkynLinkFailed] when it gets nothing useful
/// and the setup shows the bookmarklet instead.
class SoulkynLink {
  SoulkynLink({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _maxBytes = 5 * 1024 * 1024;
  static const _timeout = Duration(seconds: 20);

  /// The character page [input] names, or null when it is not a Soulkyn
  /// character link. Only soulkyn.com and soulkyn.io over HTTPS.
  static Uri? parse(String input) {
    var t = input.trim();
    if (t.isEmpty) return null;
    if (!t.contains('://')) t = 'https://$t';
    final u = Uri.tryParse(t);
    if (u == null || u.scheme != 'https') return null;
    final host = u.host.toLowerCase();
    final ok = RegExp(r'(^|\.)soulkyn\.(com|io)$').hasMatch(host);
    if (!ok || slug(u) == null) return null;
    return u.hasFragment ? Uri.parse(t.split('#').first) : u;
  }

  /// The character's editor page, `…/@aurora-skye/edit`, where its owner
  /// sees every field: identity, clothing, location, the whole story and
  /// chat examples.
  static Uri editLink(Uri page) {
    final segs = page.pathSegments;
    final at = segs.indexWhere((s) => s.startsWith('@'));
    return Uri(
      scheme: page.scheme,
      host: page.host,
      pathSegments: [...segs.take(at + 1), 'edit'],
    );
  }

  static bool isEditLink(Uri u) =>
      u.pathSegments.isNotEmpty && u.pathSegments.last == 'edit';

  /// A character from what [soulkynEditorReader] read on its editor page.
  static ImportedCharacter fromEditor(
    Map<Object?, Object?> fields,
    Uri url, {
    String? avatarHint,
  }) {
    final s = slug(url);
    final card = CharacterCard.parse({
      'avatar': avatarFrom([avatarHint], url),
      'data': {
        'name': s == null ? 'Soulkyn character' : nameFromSlug(s),
        'extensions': {
          'soulkyn': {...fields, 'source_url': url.toString()},
        },
      },
    });
    return ImportedCharacter(
      source: card.source,
      name: card.name,
      pronouns: card.pronouns,
      traits: card.traits,
      looks: card.looks,
      sections: card.sections,
      avatarUrl: card.avatarUrl,
      notes: card.notes,
    );
  }

  /// `aurora-skye` from `…/@aurora-skye`.
  static String? slug(Uri u) {
    for (final s in u.pathSegments) {
      if (s.startsWith('@') && s.length > 1) return s.substring(1);
    }
    return null;
  }

  /// "Aurora Skye" from the link, as the bookmarklet names it.
  static String nameFromSlug(String slug) => slug
      .split('-')
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  Future<ImportedCharacter> fetch(Uri url) async {
    final http.StreamedResponse response;
    try {
      final request = http.Request('GET', url)
        ..followRedirects = true
        ..maxRedirects = 3
        ..headers.addAll({
          'Accept': 'text/html,application/xhtml+xml',
          'Accept-Language': 'en-US,en;q=0.9',
          'User-Agent':
              'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/130.0 Safari/537.36',
        });
      response = await _client.send(request).timeout(_timeout);
    } catch (_) {
      throw const SoulkynLinkFailed(
        'Soulkyn could not be reached. Check the link and your connection.',
      );
    }
    final bytes = <int>[];
    try {
      await for (final chunk in response.stream.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBytes) break;
      }
    } catch (_) {
      throw const SoulkynLinkFailed('The page did not finish loading.');
    }
    final html = utf8.decode(bytes, allowMalformed: true);
    if (looksBlocked(response.statusCode, html)) {
      throw const SoulkynLinkFailed(
        'Soulkyn asked for a browser check, which the app can\'t pass.',
      );
    }
    if (response.statusCode != 200) {
      throw SoulkynLinkFailed(
        'Soulkyn answered with an error (${response.statusCode}).',
      );
    }
    final c = fromHtml(html, url);
    if (c == null) {
      throw const SoulkynLinkFailed(
        'The public page didn\'t show enough about this character.',
      );
    }
    return c;
  }

  /// Cloudflare's "Just a moment…" page and similar walls.
  static bool looksBlocked(int status, String html) {
    final head = html.length > 20000 ? html.substring(0, 20000) : html;
    return (status == 403 || status == 503 || status == 429) ||
        head.contains('cf-chl') ||
        head.contains('challenges.cloudflare.com') ||
        RegExp(r'<title>\s*Just a moment', caseSensitive: false).hasMatch(head);
  }

  /// What the page shows without scripts. The default profile view has
  /// "Personality Traits" and "Physical Traits" chips, info pills (age,
  /// gender, race, a tagline) and a bio; the editor page has the "… Tags"
  /// lists and the story field the original exporter read. Rich (custom)
  /// profiles have neither, so only the page's description comes over.
  /// Null when that is too thin to be worth importing.
  ///
  /// [avatarHint] is the avatar's address as a browser resolved it
  /// (`currentSrc`), used when the HTML alone doesn't give a usable one.
  static ImportedCharacter? fromHtml(
    String html,
    Uri url, {
    String? avatarHint,
  }) {
    final s = slug(url);
    final physical = _chipsUnder(html, const [
      'Physical Traits',
      'Physical Tags',
    ]);
    final personality = _chipsUnder(html, const [
      'Personality Traits',
      'Personality Tags',
    ]);
    final identity = _chipsUnder(html, const ['Identity Tags']);
    final clothing = _chipsUnder(html, const ['Clothing Style']);
    final location = _chipsUnder(html, const ['Location']);
    final pills = _pills(html);
    final editorStory = _textareaValue(html, 'persona_create_bg_story');
    final examples = [
      for (var i = 1; i <= 4; i++) ?_textareaValue(html, 'chat_example_$i'),
    ];
    final birthdate = _inputValue(html, 'persona_create_birthdate') ?? '';
    final story =
        editorStory ??
        _longestParagraph(html) ??
        _meta(html, 'og:description') ??
        _meta(html, 'description') ??
        '';
    final tagCount = physical.length + personality.length + identity.length;
    if (tagCount == 0 && story.trim().length < 40) return null;

    var name = s == null ? '' : nameFromSlug(s);
    final title = _meta(html, 'og:title');
    if (title != null) {
      final t = title.split(RegExp(r'\s[-|–—]\s')).first.trim();
      if (t.isNotEmpty && t.length <= 40) name = t;
    }
    final card = CharacterCard.parse({
      'avatar': avatarFrom([
        _personaAvatar(html),
        avatarHint,
        _meta(html, 'og:image'),
      ], url),
      'data': {
        'name': name,
        'extensions': {
          'soulkyn': {
            'physical_tags': physical,
            'personality_tags': personality,
            'identity_tags': [
              ...identity,
              if (pills['Gender'] case final g?) g,
              if (pills['Race'] case final r?) r,
            ],
            'age': pills['Age'] ?? '',
            'tagline': pills[''] ?? '',
            'background_story': story,
            'chat_examples': examples,
            'birthdate': birthdate,
            'clothing_style': clothing,
            'location': location,
            'source_url': url.toString(),
          },
        },
      },
    });
    return ImportedCharacter(
      source: card.source,
      name: card.name,
      pronouns: card.pronouns,
      traits: card.traits,
      looks: card.looks,
      sections: card.sections,
      avatarUrl: card.avatarUrl,
      notes: [
        if (tagCount > 0 && editorStory == null)
          'The public page has no identity, clothing or location tags and '
              'may shorten the story. If this is your character, import it '
              'as your own to bring those from its editor page.',
        if (tagCount == 0)
          'Only the page\'s description came over. If the character shows a '
              'custom (rich) profile, switch it to the default view on '
              'Soulkyn and use the exporter: go Back, pick Soulkyn again and '
              'choose "Use the exporter or a .json file instead".',
      ],
    );
  }

  static String _text(String html) => _unescape(
    html.replaceAll(RegExp(r'<[^>]*>'), ' '),
  ).replaceAll(RegExp(r'\s+'), ' ').trim();

  /// The chips after an `<h2>` naming one of [headings]: `span.tag-text`
  /// on the editor page, `a.tag-theme` on the default view. Stops at the
  /// next `<h2>` and never reads more than 30 000 characters on.
  static List<String> _chipsUnder(String html, List<String> headings) {
    for (final heading in headings) {
      final h = RegExp(
        '<h2[^>]*>\\s*${RegExp.escape(heading)}[^<]*</h2>',
        caseSensitive: false,
      ).firstMatch(html);
      if (h == null) continue;
      var rest = html.substring(h.end);
      if (rest.length > 30000) rest = rest.substring(0, 30000);
      final next = rest.indexOf(RegExp('<h2[^>]*>', caseSensitive: false));
      final section = next < 0 ? rest : rest.substring(0, next);
      final chips = [
        for (final m in _chip.allMatches(section))
          if (_text(m.group(2)!) case final t when t.isNotEmpty) t,
      ];
      if (chips.isNotEmpty) return chips.toSet().toList();
    }
    return const [];
  }

  static final _chip = RegExp(
    r"""<(span|a)\b[^>]*class=["'][^"']*\b(?:tag-text|tag-theme)\b[^"']*["'][^>]*>([\s\S]*?)</\1>""",
    caseSensitive: false,
  );

  /// The info pills, keyed by their label ("Gender", "Age", "Race"); the
  /// tagline pill (two or more real words, no label) goes under ''. Stat
  /// pills like "18 Level" or "M - 3.8" match neither.
  static Map<String, String> _pills(String html) {
    final out = <String, String>{};
    for (final m in RegExp(
      r"""<(div|span|a)\b[^>]*class=["'][^"']*\bsk-pbd__pill\b[^"']*["'][^>]*>([\s\S]*?)</\1>""",
      caseSensitive: false,
    ).allMatches(html)) {
      final t = _text(m.group(2)!);
      final labelled = RegExp(r'^(.+?)\s*(Gender|Age|Race)$').firstMatch(t);
      if (labelled != null) {
        out.putIfAbsent(labelled.group(2)!, () => labelled.group(1)!.trim());
      } else if (RegExp(r'[A-Za-z]{3,}').allMatches(t).length >= 2) {
        out.putIfAbsent('', () => t);
      }
    }
    return out;
  }

  /// The bio on the default view: the longest paragraph before the footer.
  static String? _longestParagraph(String html) {
    final footer = html.toLowerCase().lastIndexOf('<footer');
    final body = footer > 0 ? html.substring(0, footer) : html;
    String? best;
    for (final m in RegExp(
      r'<p\b[^>]*>([\s\S]*?)</p>',
      caseSensitive: false,
    ).allMatches(body)) {
      final t = _text(m.group(1)!);
      if (t.length >= 80 && t.length > (best?.length ?? 0)) best = t;
    }
    return best;
  }

  /// The `<img alt="Persona Avatar">` served from Soulkyn's image host.
  /// The first candidate that makes an HTTPS picture address. A relative
  /// or image-proxy address (`/_ipx/w_700/https://rub.soulkyn.io/…`) is
  /// resolved against the page, or the original address inside it taken.
  @visibleForTesting
  static String avatarFrom(Iterable<String?> candidates, Uri page) {
    for (final c in candidates) {
      if (c == null || c.trim().isEmpty || c.startsWith('data:')) continue;
      final inner = RegExp(
        r'''https://[^\s"'<>]+''',
      ).firstMatch(c.substring(1));
      final Uri? u;
      if (c.startsWith('https://')) {
        u = Uri.tryParse(c);
      } else if (inner != null) {
        u = Uri.tryParse(inner.group(0)!);
      } else {
        final r = Uri.tryParse(c);
        u = r == null ? null : page.resolveUri(r);
      }
      if (u != null && u.scheme == 'https' && u.host.isNotEmpty) {
        return u.toString();
      }
    }
    return '';
  }

  static String? _personaAvatar(String html) {
    for (final m in RegExp(
      r'<img\b[^>]*>',
      caseSensitive: false,
    ).allMatches(html)) {
      final tag = m.group(0)!;
      if (!RegExp(
        r"""alt=["']Persona Avatar["']""",
        caseSensitive: false,
      ).hasMatch(tag)) {
        continue;
      }
      final src = RegExp(r"""(?<![\w-])src=["']([^"']+)["']""").firstMatch(tag);
      final url = src == null ? null : _unescape(src.group(1)!);
      if (url != null && !url.startsWith('data:')) return url;
    }
    return null;
  }

  static String? _inputValue(String html, String id) {
    for (final m in RegExp(
      r'<input\b[^>]*>',
      caseSensitive: false,
    ).allMatches(html)) {
      final tag = m.group(0)!;
      if (!RegExp('\\bid=["\']${RegExp.escape(id)}["\']').hasMatch(tag)) {
        continue;
      }
      final v = RegExp(r'''\bvalue=["']([^"']*)["']''').firstMatch(tag);
      final t = v == null ? '' : _unescape(v.group(1)!).trim();
      return t.isEmpty ? null : t;
    }
    return null;
  }

  static String? _textareaValue(String html, String id) {
    final m = RegExp(
      '<textarea[^>]*id=["\']${RegExp.escape(id)}["\'][^>]*>([\\s\\S]*?)</textarea>',
      caseSensitive: false,
    ).firstMatch(html);
    final v = m == null ? '' : _unescape(m.group(1)!).trim();
    return v.isEmpty ? null : v;
  }

  static String? _meta(String html, String key) {
    for (final m in RegExp(
      r'<meta\b[^>]*>',
      caseSensitive: false,
    ).allMatches(html)) {
      final tag = m.group(0)!;
      final k = RegExp(
        r'''(?:property|name)\s*=\s*["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(tag);
      if (k == null || k.group(1)!.toLowerCase() != key) continue;
      final c = RegExp(
        r"""content\s*=\s*"([^"]*)"|content\s*=\s*'([^']*)'""",
        caseSensitive: false,
      ).firstMatch(tag);
      final v = c == null ? '' : _unescape(c.group(1) ?? c.group(2)!).trim();
      if (v.isNotEmpty) return v;
    }
    return null;
  }

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');

  void close() => _client.close();
}

class SoulkynLinkFailed implements Exception {
  const SoulkynLinkFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The exporter bookmarklet, grown from the community version: run on a
/// Soulkyn character page, it saves `<slug>-soulkyn.json` in the shape
/// [CharacterCard] reads. It reads the default profile view (Personality
/// and Physical Traits chips, info pills, bio) and the editor page (the
/// "… Tags" lists and story fields); on a custom (rich) profile, which has
/// neither, it asks for the default view instead. It only reads the page
/// and starts a download; nothing is sent anywhere.
/// Reads a character's editor page (`…/@name/edit`) in the browser window:
/// the tag boxes, story, chat examples and birthday, in the exporter's
/// shape. Null on any other page.
const soulkynEditorReader = r'''(() => {
  const T = e => ((e && e.textContent) || '').replace(/\s+/g, ' ').trim();
  const uniq = a => a.filter((x, i) => x && a.indexOf(x) === i);
  const val = id => ((document.getElementById(id) || {}).value || '').trim();
  // The id sits on the box's typing field; the tags are its siblings.
  const tags = id => {
    const f = document.getElementById('tags_persona_create_' + id);
    const b = f && (f.closest('.fv-taginput') || f.parentElement);
    if (!b) return [];
    return uniq([...b.querySelectorAll('.fv-tag')].map(t => {
      const text = t.querySelector('.fv-tag__text');
      if (text) return T(text);
      const c = t.cloneNode(true);
      c.querySelectorAll('button,svg,[role=button]').forEach(x => x.remove());
      return T(c).replace(/\s*[\u00d7\u2715]$/, '');
    }));
  };
  if (!document.getElementById('persona_create_bg_story')) return null;
  return {
    physical_tags: tags('phys_tags'),
    personality_tags: tags('perso_tags'),
    identity_tags: tags('secrets_tags'),
    clothing_style: tags('clothes'),
    location: tags('location'),
    background_story: val('persona_create_bg_story'),
    chat_examples: [1, 2, 3, 4].map(i => val('chat_example_' + i)).filter(Boolean),
    birthdate: val('persona_create_birthdate'),
    card_type: val('personaCardType'),
  };
})()''';

const soulkynExporter =
    r'''javascript:(function(){'''
    r'''const T=(e)=>((e&&e.textContent)||'').replace(/\s+/g,' ').trim();'''
    r'''const uniq=(a)=>a.filter((x,i)=>x&&a.indexOf(x)===i);'''
    r'''const head=(names)=>Array.from(document.querySelectorAll('h2')).find(x=>names.some(n=>T(x).indexOf(n)===0));'''
    r'''const chips=(names)=>{const h=head(names);if(!h)return[];let box=h.parentElement;for(let i=0;i<4&&box;i++){if(i>0&&box.querySelectorAll('h2').length>1)break;const c=box.querySelectorAll('span.tag-text,.tag-theme');if(c.length)return uniq(Array.from(c).map(T));box=box.parentElement;}const n=h.parentElement&&h.parentElement.nextElementSibling;return n?uniq(Array.from(n.querySelectorAll('span.tag-text,.tag-theme')).map(T)):[];};'''
    r'''const val=(id)=>((document.getElementById(id)||{}).value||'').trim();'''
    r'''const tagbox=(id)=>{const f=document.getElementById('tags_persona_create_'+id);const b=f&&(f.closest('.fv-taginput')||f.parentElement);if(!b)return[];return uniq(Array.from(b.querySelectorAll('.fv-tag')).map(t=>{const x=t.querySelector('.fv-tag__text');if(x)return T(x);const c=t.cloneNode(true);c.querySelectorAll('button,svg,[role=button]').forEach(x=>x.remove());return T(c).replace(/\s*[\u00d7\u2715]$/,'');}));};'''
    r'''const either=(a,b)=>a.length?a:b;'''
    r'''const m=location.pathname.match(/\/@([^/]+)/);const slug=m?m[1]:'unknown';'''
    r'''const name=slug.split('-').filter(Boolean).map(w=>w[0].toUpperCase()+w.slice(1)).join(' ');'''
    r'''const pills={};Array.from(document.querySelectorAll('.sk-pbd__pill')).forEach(p=>{const t=T(p);const k=t.match(/^(.+?)\s*(Gender|Age|Race)$/);if(k){if(!pills[k[2]])pills[k[2]]=k[1].trim();}else if((t.match(/[A-Za-z]{3,}/g)||[]).length>=2&&!pills.tagline){pills.tagline=t;}});'''
    r'''const h1=document.querySelector('h1');const root=(h1&&h1.closest('.base-container'))||document;'''
    r'''const ps=Array.from(root.querySelectorAll('p')).filter(p=>!p.closest('footer')).map(T).filter(t=>t.length>=80).sort((a,b)=>b.length-a.length);'''
    r'''const imgs=Array.from(document.querySelectorAll('img[src*="rub.soulkyn"]'));'''
    r'''let pick=imgs.find(e=>/persona avatar|avatar|ai companion/i.test(e.alt||''));'''
    r'''if(!pick)pick=imgs.sort((a,b)=>b.naturalWidth*b.naturalHeight-a.naturalWidth*a.naturalHeight)[0];'''
    r'''const sk={physical_tags:either(tagbox('phys_tags'),chips(['Physical Traits','Physical Tags'])),personality_tags:either(tagbox('perso_tags'),chips(['Personality Traits','Personality Tags'])),identity_tags:uniq(either(tagbox('secrets_tags'),chips(['Identity Tags'])).concat([pills.Gender,pills.Race])),'''
    r'''age:pills.Age||'',tagline:pills.tagline||'',background_story:val('persona_create_bg_story')||ps[0]||'',chat_examples:[1,2,3,4].map(i=>val('chat_example_'+i)).filter(Boolean),'''
    r'''clothing_style:either(tagbox('clothes'),chips(['Clothing Style'])),location:either(tagbox('location'),chips(['Location'])),birthdate:val('persona_create_birthdate'),card_type:val('personaCardType'),source_url:location.href,exported_date:new Date().toISOString()};'''
    r'''if(!sk.physical_tags.length&&!sk.personality_tags.length){alert('No traits found on this page. If it shows a custom (rich) profile, switch it to the default view and click the bookmark again.');return;}'''
    r'''const card={avatar:(pick&&pick.src)||'',data:{name:name,creator:'Exported from SoulKyn',extensions:{soulkyn:sk}}};'''
    r'''const url=URL.createObjectURL(new Blob([JSON.stringify(card,null,2)],{type:'application/json'}));'''
    r'''const a=document.createElement('a');a.href=url;a.download=slug+'-soulkyn.json';document.body.appendChild(a);a.click();a.remove();'''
    r'''setTimeout(()=>URL.revokeObjectURL(url),1000);'''
    r'''alert('Saved '+slug+'-soulkyn.json: '+sk.personality_tags.length+' personality and '+sk.physical_tags.length+' physical traits. Now choose it in VoxCordis.');'''
    r'''})();''';
