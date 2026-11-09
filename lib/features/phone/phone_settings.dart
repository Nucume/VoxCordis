import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';

import '../../app_scope.dart';
import '../../data/settings.dart';
import '../../services/phone/phone_devices.dart';
import '../../services/phone/phone_firewall.dart';
import '../../services/phone/phone_server.dart';
import '../../theme/app_theme.dart';
import '../settings/settings_text.dart';

/// Settings → Connections → Phone access: use VoxCordis from a phone's
/// browser on the home network. Saved at once, like the calendar above.
class PhoneSettings extends StatefulWidget {
  const PhoneSettings({super.key});

  /// This computer's home-network addresses; replaceable for tests.
  @visibleForTesting
  static Future<List<String>> Function({bool tailscale}) findAddresses =
      PhoneNetwork.addresses;

  /// Looks at the firewall; replaceable for tests.
  @visibleForTesting
  static Future<FirewallState> Function(int port) checkFirewall =
      PhoneFirewall.check;

  @override
  State<PhoneSettings> createState() => _PhoneSettingsState();
}

class _PhoneSettingsState extends State<PhoneSettings> {
  List<String>? _addresses;
  String? _address;
  bool _tailscaleRunning = false;
  Timer? _tick;
  bool _help = false;

  /// The firewall as last looked at, and whether it is being changed.
  FirewallState? _firewall;
  bool _firewallBusy = false;
  String? _firewallError;
  final _port = TextEditingController();
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final services = AppScope.of(context);
    _port.text = '${services.settings.value.phonePort}';
    services.phone.devices.load();
    _findAddresses();
    _checkFirewall();
  }

  Future<void> _checkFirewall() async {
    final port = AppScope.of(context).settings.value.phonePort;
    final state = await PhoneSettings.checkFirewall(port);
    if (mounted) setState(() => _firewall = state);
  }

  /// Opens the port for phones on the home network, or closes it again.
  Future<void> _changeFirewall({bool close = false}) async {
    final store = AppScope.of(context).settings;
    final s = store.value;
    final kind = _firewall?.kind ?? FirewallKind.none;
    final port = close ? s.phoneFirewallPort : s.phonePort;
    setState(() {
      _firewallBusy = true;
      _firewallError = null;
    });
    // A port opened before for another number goes first.
    if (!close && s.phoneFirewallPort != 0 && s.phoneFirewallPort != port) {
      await PhoneFirewall.change(
        kind,
        s.phoneFirewallPort,
        tailscale: s.phoneTailscale,
        close: true,
      );
    }
    final error = await PhoneFirewall.change(
      kind,
      port,
      tailscale: s.phoneTailscale,
      close: close,
    );
    if (error == null) {
      await store.update(
        store.value.copyWith(phoneFirewallPort: close ? 0 : port),
      );
    }
    final state = await PhoneSettings.checkFirewall(store.value.phonePort);
    if (!mounted) return;
    setState(() {
      _firewallBusy = false;
      _firewallError = error;
      _firewall = state;
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _port.dispose();
    // A code nobody scanned stops working once the page closes.
    final devices = _devices;
    if (devices?.code?.used == false) devices!.dropCode();
    super.dispose();
  }

  PhoneDevices? _devices;

  Future<void> _findAddresses() async {
    final s = AppScope.of(context).settings.value;
    final list = await PhoneSettings.findAddresses(tailscale: s.phoneTailscale);
    final ts = await PhoneNetwork.tailscaleRunning();
    if (!mounted) return;
    setState(() {
      _addresses = list;
      _tailscaleRunning = ts;
      if (!list.contains(_address)) _address = list.firstOrNull;
    });
  }

  Future<void> _save(AppSettings Function(AppSettings) change) async {
    final store = AppScope.of(context).settings;
    await store.update(change(store.value));
  }

  Future<void> _turn(bool on) async {
    final services = AppScope.of(context);
    if (!on) {
      services.phone.devices.dropCode();
      await _save((s) => s.copyWith(phoneAccess: false));
      if (!mounted || services.settings.value.phoneFirewallPort == 0) return;
      final close = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.shield_outlined),
          title: const Text('Close the firewall again?'),
          content: const SizedBox(
            width: 420,
            child: Text(
              'VoxCordis let phones on your home network through the '
              'firewall. Nothing listens there now, but you can close it '
              'again too. That asks for your password once more.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Leave it'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Close it'),
            ),
          ],
        ),
      );
      if (close == true) await _changeFirewall(close: true);
      return;
    }
    await _save((s) => s.copyWith(phoneAccess: true));
    unawaited(_checkFirewall());
    if (!mounted || services.settings.value.keepRunning) return;
    final tray = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.move_to_inbox_rounded),
        title: const Text('Keep VoxCordis running when the window closes?'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'Your phone only reaches VoxCordis while it runs. With “Close '
            'to the system tray” on, closing the window leaves it running '
            'in the tray, so your phone keeps working.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Turn it on'),
          ),
        ],
      ),
    );
    if (tray == true) await _save((s) => s.copyWith(keepRunning: true));
  }

  void _newCode() {
    AppScope.of(context).phone.devices.newCode();
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      final code = _devices?.code;
      setState(() {});
      if (code == null || !code.live) t.cancel();
    });
    _findAddresses();
  }

  Future<void> _remove(PairedPhone phone) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${phone.name}?'),
        content: const SizedBox(
          width: 380,
          child: Text(
            'It is disconnected at once and has to scan a new code to come '
            'back.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await AppScope.of(context).phone.devices.remove(phone.id);
    }
  }

  Future<void> _rename(PairedPhone phone) async {
    final field = TextEditingController(text: phone.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename this phone'),
        content: SizedBox(
          width: 340,
          child: TextField(
            controller: field,
            autofocus: true,
            maxLength: 40,
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    field.dispose();
    if (name != null && name.trim().isNotEmpty && mounted) {
      await AppScope.of(context).phone.devices.rename(phone.id, name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    _devices = services.phone.devices;
    return ListenableBuilder(
      listenable: Listenable.merge([
        services.settings,
        services.phone.devices,
        services.phone.problem,
      ]),
      builder: (context, _) {
        final s = services.settings.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SettingsSection('Phone access'),
            SettingsNote(
              'Chat with ${s.companionName}, see and draw pictures and play '
              'Voces Mundi from your phone\'s browser, on your home network. '
              'Nothing to install. Everything still runs on this computer, '
              'and what the phone and this computer say to each other is '
              'encrypted.',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: s.phoneAccess,
              onChanged: _turn,
              title: const Text('Let my phone use VoxCordis'),
              subtitle: SettingsNote(
                s.phoneAccess
                    ? 'Only phones you paired below get in.'
                    : 'Off: nothing listens on the network.',
              ),
            ),
            if (s.phoneAccess) ..._on(s),
          ],
        );
      },
    );
  }

  List<Widget> _on(AppSettings s) {
    final services = AppScope.of(context);
    final devices = services.phone.devices;
    final problem = services.phone.problem.value;
    final palette = context.palette;
    final code = devices.code;
    final addresses = _addresses;
    final address = _address;
    final link = address == null ? null : 'http://$address:${s.phonePort}/';
    return [
      if (problem != null)
        SettingsNote(problem, color: Theme.of(context).colorScheme.error),
      ?_firewallCard(s),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette.tile,
          borderRadius: BorderRadius.circular(14),
        ),
        child: addresses == null
            ? const Center(child: CircularProgressIndicator())
            : addresses.isEmpty
            ? Text(
                'This computer doesn\'t seem to be on a home network. '
                'Connect it to your Wi-Fi or router, then come back.',
                style: TextStyle(color: palette.textMuted),
              )
            : Wrap(
                spacing: 20,
                runSpacing: 16,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _qrBox(code, link!),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          code != null && code.live
                              ? 'Pairing is open'
                              : 'Add a phone',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          code != null && code.live
                              ? 'Open VoxCordis on your phone and tap Pair '
                                    'with my PC, or scan this code with its '
                                    'camera. Then check the code and allow it '
                                    'here. Open for ${_left(code)}, for one '
                                    'phone.'
                              : 'Your phone has to be on the same network '
                                    'as this computer. The first time, open '
                                    'the address below in its browser, or '
                                    'scan the code with its camera.',
                          style: TextStyle(
                            fontSize: 13,
                            color: palette.textMuted,
                          ),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.tonalIcon(
                          onPressed: _newCode,
                          icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                          label: Text(
                            code != null && code.live
                                ? 'Start again'
                                : 'Pair a phone',
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Phones open VoxCordis at',
                          style: TextStyle(
                            fontSize: 12,
                            color: palette.textMuted,
                          ),
                        ),
                        Row(
                          children: [
                            Flexible(
                              child: SelectableText(
                                link,
                                style: const TextStyle(
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Copy',
                              visualDensity: VisualDensity.compact,
                              iconSize: 16,
                              onPressed: () =>
                                  Clipboard.setData(ClipboardData(text: link)),
                              icon: const Icon(Icons.copy_rounded),
                            ),
                          ],
                        ),
                        if (addresses.length > 1)
                          Wrap(
                            spacing: 6,
                            children: [
                              for (final a in addresses)
                                ChoiceChip(
                                  label: Text(a),
                                  selected: a == address,
                                  visualDensity: VisualDensity.compact,
                                  onSelected: (_) =>
                                      setState(() => _address = a),
                                ),
                            ],
                          ),
                        if (addresses.length > 1)
                          SettingsNote(
                            'This computer has more than one network. If '
                            'the phone can\'t connect, try another one.',
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      SettingsSection('Paired phones'),
      if (devices.phones.isEmpty)
        SettingsNote('None yet.')
      else
        for (final phone in devices.phones)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.smartphone_rounded,
              color: devices.connected.contains(phone.id)
                  ? Theme.of(context).colorScheme.primary
                  : palette.textMuted,
            ),
            title: Text(phone.name),
            subtitle: Text(
              devices.connected.contains(phone.id)
                  ? 'Connected now'
                  : 'Last used ${_when(phone.lastSeen ?? phone.added)}',
              style: TextStyle(fontSize: 12, color: palette.textMuted),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Rename',
                  onPressed: () => _rename(phone),
                  icon: const Icon(Icons.edit_rounded, size: 18),
                ),
                TextButton(
                  onPressed: () => _remove(phone),
                  child: const Text('Remove'),
                ),
              ],
            ),
          ),
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: s.phoneKeepAwake,
        onChanged: (on) => _save((x) => x.copyWith(phoneKeepAwake: on)),
        title: const Text(
          'Keep this computer awake while a phone is connected',
        ),
        subtitle: SettingsNote(
          'So it doesn\'t go to sleep in the middle of a chat. The screen '
          'can still turn off.',
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: s.phoneTailscale,
        onChanged: (on) async {
          await _save((x) => x.copyWith(phoneTailscale: on));
          await _findAddresses();
        },
        title: const Text('Also from outside, through Tailscale'),
        subtitle: SettingsNote(
          'With Tailscale on this computer and your phone, your phone can '
          'reach VoxCordis from anywhere, still encrypted. '
          '${_tailscaleRunning ? 'Tailscale is running here.' : 'Tailscale doesn\'t seem to run on this computer.'}',
        ),
      ),
      const SizedBox(height: 6),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _help = !_help),
          icon: Icon(
            _help ? Icons.expand_less_rounded : Icons.help_outline_rounded,
            size: 18,
          ),
          label: const Text('Phone can\'t connect?'),
        ),
      ),
      if (_help) _helpBox(s),
    ];
  }

  /// Shown while the firewall may keep phones out, or once VoxCordis
  /// opened it.
  Widget? _firewallCard(AppSettings s) {
    final f = _firewall;
    if (f == null || f.kind == FirewallKind.none) return null;
    final palette = context.palette;
    final opened = s.phoneFirewallPort == s.phonePort;
    final open = f.open ?? opened;
    if (open && !opened) return null;
    final commands = PhoneFirewall.commands(
      f.kind,
      s.phonePort,
      tailscale: s.phoneTailscale,
    );
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.tile,
        borderRadius: BorderRadius.circular(14),
        border: open
            ? null
            : Border.all(color: Colors.orangeAccent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                open ? Icons.verified_user_outlined : Icons.shield_outlined,
                color: open
                    ? Theme.of(context).colorScheme.primary
                    : Colors.orangeAccent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  open
                      ? 'Phones on your home network get through the firewall'
                      : '${f.name} is on and keeps phones out',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            open
                ? 'Port ${s.phonePort} is open to your home network only'
                      '${s.phoneTailscale ? ' and Tailscale' : ''}.'
                : 'Let them through once: only port ${s.phonePort}, and only '
                      'from your home network'
                      '${s.phoneTailscale ? ' and Tailscale' : ''}. Your '
                      'computer asks for your password.',
            style: TextStyle(fontSize: 13, color: palette.textMuted),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (open)
                TextButton(
                  onPressed: _firewallBusy
                      ? null
                      : () => _changeFirewall(close: true),
                  child: const Text('Close it again'),
                )
              else
                FilledButton.tonalIcon(
                  onPressed: _firewallBusy ? null : _changeFirewall,
                  icon: const Icon(Icons.lock_open_rounded, size: 18),
                  label: const Text('Let phones through'),
                ),
              if (_firewallBusy) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          if (_firewallError case final e?) ...[
            const SizedBox(height: 8),
            SelectableText(
              e,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          if (!open && commands.isNotEmpty)
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: Material(
                type: MaterialType.transparency,
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    'Or do it yourself',
                    style: TextStyle(fontSize: 13, color: palette.textMuted),
                  ),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        [
                          for (final c in commands)
                            f.kind == FirewallKind.ufw ||
                                    f.kind == FirewallKind.firewalld
                                ? 'sudo $c'
                                : c,
                        ].join('\n'),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _qrBox(PairingCode? code, String link) {
    final palette = context.palette;
    final live = code != null && code.live;
    return Container(
      width: 184,
      height: 184,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: live ? Colors.white : palette.tile,
        borderRadius: BorderRadius.circular(12),
        border: live
            ? null
            : Border.all(color: palette.textMuted.withValues(alpha: 0.3)),
      ),
      child: live
          ? CustomPaint(painter: QrPainter('$link#${code.fragment}'))
          : Icon(
              Icons.qr_code_2_rounded,
              size: 72,
              color: palette.textMuted.withValues(alpha: 0.5),
            ),
    );
  }

  Widget _helpBox(AppSettings s) {
    final palette = context.palette;
    final port = s.phonePort;
    Widget tip(String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          SelectableText(
            body,
            style: TextStyle(fontSize: 13, color: palette.textMuted),
          ),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.tile,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          tip(
            'Same network',
            'The phone has to be on the same Wi-Fi as this computer, not on '
                'mobile data or a guest network (guest networks keep devices '
                'apart).',
          ),
          tip(
            'Firewall',
            'VoxCordis offers to open the firewall above when it finds ufw, '
                'firewalld, Windows Firewall or the macOS one. Another '
                'firewall needs TCP port $port allowed from your home '
                'network. On Windows, the Wi-Fi has to be set to a private '
                'network, and if you once said no when Windows asked about '
                'VoxCordis, allow it again under Windows Security › Firewall '
                '› Allow an app.',
          ),
          tip(
            'VPN',
            'A VPN on the phone or this computer can hide one from the '
                'other. Pause it, or use Tailscale above.',
          ),
          tip(
            'Port',
            'Another program may already use port $port. Pick another one '
                'here; paired phones then need the new address.',
          ),
          Row(
            children: [
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: () {
                  final n = int.tryParse(_port.text);
                  if (n == null || n < 1024 || n > 65535) {
                    _port.text = '$port';
                    return;
                  }
                  _save(
                    (x) => x.copyWith(phonePort: n),
                  ).then((_) => _checkFirewall());
                },
                child: const Text('Use this port'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _left(PairingCode code) {
    final left = code.expires.difference(DateTime.now());
    final m = left.inMinutes;
    final sec = left.inSeconds % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  static String _when(DateTime t) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(t.hour)}:${two(t.minute)}';
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final days = today.difference(day).inDays;
    if (days == 0) return 'today at $time';
    if (days == 1) return 'yesterday at $time';
    if (days < 7) return '$days days ago';
    return 'on ${t.year}-${two(t.month)}-${two(t.day)}';
  }
}

/// Paints [data] as a QR code, black on the white it sits on.
class QrPainter extends CustomPainter {
  QrPainter(this.data)
    : _image = QrImage(
        QrCode(
          payload: QrPayload.fromString(data),
          errorCorrectLevel: QrErrorCorrectLevel.medium,
        ),
      );

  final String data;
  final QrImage _image;

  @override
  void paint(Canvas canvas, Size size) {
    final n = _image.moduleCount;
    final cell = size.shortestSide / n;
    final paint = Paint()..color = Colors.black;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (_image.isDark(y, x)) {
          canvas.drawRect(
            Rect.fromLTWH(x * cell, y * cell, cell + 0.4, cell + 0.4),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(QrPainter old) => old.data != data;
}
