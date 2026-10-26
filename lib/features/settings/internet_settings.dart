import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../services/web/web_guard.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass_popover.dart';
import 'model_picker.dart' show InfoIcon;

/// Settings → Internet: whether the companion may search and read the
/// web, its own browser (no window), the search service, and sites it
/// must never visit. Saved with the page's Save button.
class InternetSettings extends StatefulWidget {
  const InternetSettings({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final AppSettings value;
  final ValueChanged<AppSettings> onChanged;

  @override
  State<InternetSettings> createState() => _InternetSettingsState();
}

class _InternetSettingsState extends State<InternetSettings> {
  late final _key = TextEditingController(text: widget.value.searchApiKey);
  late final _searx = TextEditingController(text: widget.value.searxngUrl);
  final _site = TextEditingController();

  /// The browser that would be used, null while looking.
  String? _browser;
  bool _looked = false;
  double? _progress;
  String? _error;

  AppSettings get _v => widget.value;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_looked) {
      _looked = true;
      _findBrowser();
    }
  }

  @override
  void dispose() {
    for (final c in [_key, _searx, _site]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _findBrowser() async {
    final exe = await AppScope.of(context).browser.executable();
    if (mounted) setState(() => _browser = exe ?? '');
  }

  Future<void> _download() async {
    final browser = AppScope.of(context).browser;
    setState(() {
      _error = null;
      _progress = 0;
    });
    try {
      final exe = await browser.download(
        onProgress: (got, total) {
          if (mounted && total != null && total > 0) {
            setState(() => _progress = got / total);
          }
        },
      );
      if (mounted) setState(() => _browser = exe);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  /// "Microsoft Edge" for msedge.exe, and so on.
  static String browserName(String exe) {
    final name = p.basenameWithoutExtension(exe).toLowerCase();
    if (name.contains('msedge') || name.contains('microsoft-edge')) {
      return 'Microsoft Edge';
    }
    if (name.contains('brave')) return 'Brave';
    if (name.contains('vivaldi')) return 'Vivaldi';
    if (name.contains('headless-shell')) return 'headless-shell';
    if (name.contains('chromium')) return 'Chromium';
    if (exe.toLowerCase().contains('chromium')) return 'Chromium';
    return 'Google Chrome';
  }

  void _addSite() {
    final site = WebGuard.normalizeSite(_site.text);
    _site.clear();
    if (site.isEmpty || _v.blockedSites.contains(site)) return;
    widget.onChanged(_v.copyWith(blockedSites: [..._v.blockedSites, site]));
  }

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, color: context.palette.textMuted),
    ),
  );

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 2),
    child: Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final name = _v.companionName;
    final browser = _browser;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('Internet'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _v.internetAccess,
          onChanged: (on) => widget.onChanged(_v.copyWith(internetAccess: on)),
          title: Text('Let $name search and read the web'),
          subtitle: _note(
            'For news, weather, facts and anything current. What $name '
            'reads online is treated as information only, and after reading '
            'the web $name can\'t use your computer until you write again.',
          ),
        ),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _v.internetAccess ? 1 : 0.45,
          child: IgnorePointer(
            ignoring: !_v.internetAccess,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _v.companionBrowser,
                  onChanged: (on) =>
                      widget.onChanged(_v.copyWith(companionBrowser: on)),
                  title: Text('Let $name use a browser of their own'),
                  subtitle: _note(
                    'For sites that need clicking or typing. It runs '
                    'invisibly, with no window, and has its own profile '
                    'without your logins or history. Sending a form asks '
                    'you first. Works best with a server-hosted brain.',
                  ),
                ),
                if (_v.companionBrowser) _browserRow(browser),
                _section('Search service'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: GlassSelect<SearchProvider>(
                        label: 'Search with',
                        value: _v.searchProvider,
                        options: const [
                          GlassOption(
                            SearchProvider.duckDuckGo,
                            'DuckDuckGo (no account needed)',
                          ),
                          GlassOption(
                            SearchProvider.brave,
                            'Brave Search (API key)',
                          ),
                          GlassOption(
                            SearchProvider.tavily,
                            'Tavily (API key)',
                          ),
                          GlassOption(
                            SearchProvider.searxng,
                            'SearXNG (your own address)',
                          ),
                        ],
                        onChanged: (v) =>
                            widget.onChanged(_v.copyWith(searchProvider: v)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const InfoIcon(
                      message:
                          'DuckDuckGo works without an account but may '
                          'sometimes ask "are you a robot?"; with the '
                          'browser on, the search then goes through it. '
                          'Brave Search and Tavily have free plans with an '
                          'API key, and are more dependable.',
                    ),
                  ],
                ),
                if (_v.searchProvider == SearchProvider.brave ||
                    _v.searchProvider == SearchProvider.tavily)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextField(
                      controller: _key,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText:
                            '${_v.searchProvider == SearchProvider.brave ? 'Brave Search' : 'Tavily'} API key',
                        helperText: 'Kept in your keyring, never in a file.',
                      ),
                      onChanged: (k) =>
                          widget.onChanged(_v.copyWith(searchApiKey: k.trim())),
                    ),
                  ),
                if (_v.searchProvider == SearchProvider.searxng)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextField(
                      controller: _searx,
                      decoration: const InputDecoration(
                        labelText: 'SearXNG address',
                        hintText: 'https://searx.example.org',
                        helperText: 'The instance must allow JSON results.',
                      ),
                      onChanged: (u) =>
                          widget.onChanged(_v.copyWith(searxngUrl: u.trim())),
                    ),
                  ),
                _section('Never visit'),
                _note(
                  '$name never opens these sites or their subdomains. Your '
                  'own computer and home network are always off limits.',
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final site in _v.blockedSites)
                      InputChip(
                        label: Text(site),
                        onDeleted: () => widget.onChanged(
                          _v.copyWith(
                            blockedSites: [
                              for (final s in _v.blockedSites)
                                if (s != site) s,
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _site,
                        decoration: const InputDecoration(
                          labelText: 'Add a site',
                          hintText: 'example.com',
                        ),
                        onSubmitted: (_) => _addSite(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(onPressed: _addSite, child: const Text('Add')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _browserRow(String? browser) {
    final palette = context.palette;
    final Widget body;
    if (browser == null) {
      body = Text(
        'Looking for a browser…',
        style: TextStyle(color: palette.textMuted),
      );
    } else if (browser.isNotEmpty) {
      final name = browserName(browser);
      body = Text(
        name == 'headless-shell'
            ? 'Uses the browser VoxCordis downloaded.'
            : 'Uses $name, found on this computer.',
        style: TextStyle(fontSize: 13, color: palette.text),
      );
    } else if (_progress != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Downloading the browser…',
            style: TextStyle(color: palette.text),
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: _progress),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            Platform.isWindows
                ? 'Microsoft Edge wasn\'t found, nor another Chromium '
                      'browser.'
                : 'No Chrome, Chromium, Edge, Brave or Vivaldi was found.',
            style: TextStyle(fontSize: 13, color: palette.text),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _download,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Download a browser for this (about 120 MB)'),
          ),
        ],
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.tile,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.glassBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.public_rounded, size: 18, color: palette.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                body,
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
