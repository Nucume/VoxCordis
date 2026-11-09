import 'dart:io';

import 'package:flutter/foundation.dart';

/// Which firewall stands between phones and VoxCordis.
enum FirewallKind {
  /// None found, or one VoxCordis can't read.
  none,

  /// Ubuntu, Mint, Pop!_OS…
  ufw,

  /// Fedora, openSUSE…
  firewalld,
  windows,
  macos,
}

/// What [PhoneFirewall.check] found.
class FirewallState {
  const FirewallState(this.kind, {this.open});

  final FirewallKind kind;

  /// Whether phones get through to the port: true, false, or null when
  /// that can't be read without the administrator password (ufw keeps its
  /// rules to root).
  final bool? open;

  String get name => switch (kind) {
    FirewallKind.ufw => 'The firewall (ufw)',
    FirewallKind.firewalld => 'The firewall (firewalld)',
    FirewallKind.windows => 'Windows Firewall',
    FirewallKind.macos => 'The macOS firewall',
    FirewallKind.none => 'No firewall',
  };
}

typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Opens the phone port in the computer's firewall, for the home network
/// only, after the system asks for the administrator password once:
///
/// - **ufw:** `ufw allow from <home network> to any port <port> proto tcp`
///   for 192.168/16, 10/8 and 172.16/12 (and 100.64/10 with Tailscale),
///   through `pkexec`;
/// - **firewalld:** the port in the active zone, now and after restarts,
///   through `pkexec`;
/// - **Windows:** an inbound rule for the local subnet on private networks,
///   through an elevated `netsh`;
/// - **macOS:** VoxCordis allowed in the application firewall.
abstract final class PhoneFirewall {
  /// Runs a program; replaceable for tests.
  @visibleForTesting
  static ProcessRunner run = Process.run;

  /// `/etc/ufw/ufw.conf`; replaceable for tests.
  @visibleForTesting
  static String ufwConfig = '/etc/ufw/ufw.conf';

  static const ruleName = 'VoxCordis phone access';
  static const _comment = 'VoxCordis phone access';

  static const _home = ['192.168.0.0/16', '10.0.0.0/8', '172.16.0.0/12'];
  static const _tailscale = '100.64.0.0/10';

  static Future<ProcessResult?> _try(String exe, List<String> args) async {
    try {
      return await run(exe, args);
    } on Object {
      return null;
    }
  }

  static Future<FirewallState> check(int port) async {
    if (Platform.isWindows) return _checkWindows(port);
    if (Platform.isMacOS) return _checkMac();
    if (Platform.isLinux) return _checkLinux(port);
    return const FirewallState(FirewallKind.none);
  }

  static Future<FirewallState> _checkLinux(int port) async {
    final state = await _try('firewall-cmd', ['--state']);
    if (state != null &&
        state.exitCode == 0 &&
        '${state.stdout}'.trim() == 'running') {
      final ports = await _try('firewall-cmd', ['--list-ports']);
      if (ports == null || ports.exitCode != 0) {
        return const FirewallState(FirewallKind.firewalld);
      }
      return FirewallState(
        FirewallKind.firewalld,
        open: portListed('${ports.stdout}', port),
      );
    }
    try {
      final conf = await File(ufwConfig).readAsString();
      if (RegExp(r'^\s*ENABLED\s*=\s*yes', multiLine: true).hasMatch(conf)) {
        return const FirewallState(FirewallKind.ufw);
      }
    } on Object {
      // No ufw.
    }
    return const FirewallState(FirewallKind.none);
  }

  /// Whether firewalld's `--list-ports` output ("8080/tcp 1025-65535/tcp")
  /// lets [port] in over TCP.
  @visibleForTesting
  static bool portListed(String list, int port) {
    for (final item in list.split(RegExp(r'\s+'))) {
      final m = RegExp(r'^(\d+)(?:-(\d+))?/tcp$').firstMatch(item);
      if (m == null) continue;
      final from = int.parse(m[1]!);
      final to = int.parse(m[2] ?? m[1]!);
      if (port >= from && port <= to) return true;
    }
    return false;
  }

  static Future<FirewallState> _checkWindows(int port) async {
    final state = await _try('netsh', [
      'advfirewall',
      'show',
      'currentprofile',
      'state',
    ]);
    if (state != null &&
        state.exitCode == 0 &&
        !RegExp(r'\bON\b').hasMatch('${state.stdout}')) {
      return const FirewallState(FirewallKind.none);
    }
    final rule = await _try('netsh', [
      'advfirewall',
      'firewall',
      'show',
      'rule',
      'name=$ruleName',
    ]);
    final open =
        rule != null &&
        rule.exitCode == 0 &&
        RegExp('LocalPort:\\s*$port\\b').hasMatch('${rule.stdout}');
    return FirewallState(FirewallKind.windows, open: open);
  }

  static const _socketfilterfw =
      '/usr/libexec/ApplicationFirewall/socketfilterfw';

  static Future<FirewallState> _checkMac() async {
    final state = await _try(_socketfilterfw, ['--getglobalstate']);
    if (state == null || !'${state.stdout}'.contains('enabled')) {
      return const FirewallState(FirewallKind.none);
    }
    final blocked = await _try(_socketfilterfw, [
      '--getappblocked',
      Platform.resolvedExecutable,
    ]);
    final text = '${blocked?.stdout}';
    return FirewallState(
      FirewallKind.macos,
      open: text.contains('permitted') ? true : null,
    );
  }

  /// The commands that open (or with [close], close) [port], as the
  /// administrator would type them; also shown for doing it by hand.
  static List<String> commands(
    FirewallKind kind,
    int port, {
    bool tailscale = false,
    bool close = false,
  }) {
    final from = [..._home, if (tailscale) _tailscale];
    switch (kind) {
      case FirewallKind.ufw:
        return [
          for (final net in from)
            close
                ? 'ufw delete allow from $net to any port $port proto tcp'
                : 'ufw allow from $net to any port $port proto tcp '
                      'comment "$_comment"',
        ];
      case FirewallKind.firewalld:
        final verb = close ? '--remove-port' : '--add-port';
        return [
          'firewall-cmd $verb=$port/tcp',
          'firewall-cmd --permanent $verb=$port/tcp',
        ];
      case FirewallKind.windows:
        return [
          'netsh advfirewall firewall delete rule name="$ruleName"',
          if (!close)
            'netsh advfirewall firewall add rule name="$ruleName" dir=in '
                'action=allow protocol=TCP localport=$port '
                'remoteip=LocalSubnet profile=private',
        ];
      case FirewallKind.macos:
        final exe = Platform.resolvedExecutable;
        return [
          '$_socketfilterfw --add "$exe"',
          '$_socketfilterfw ${close ? '--blockapp' : '--unblockapp'} "$exe"',
        ];
      case FirewallKind.none:
        return const [];
    }
  }

  /// Opens [port] (or with [close], closes it) after the system asks for
  /// the administrator password. Null when done, else why not.
  static Future<String?> change(
    FirewallKind kind,
    int port, {
    bool tailscale = false,
    bool close = false,
  }) async {
    final list = commands(kind, port, tailscale: tailscale, close: close);
    if (list.isEmpty) return null;
    final ProcessResult? result;
    switch (kind) {
      case FirewallKind.ufw || FirewallKind.firewalld:
        // One password for all of them. Deleting a ufw rule that isn't
        // there fails, so closing goes on past that.
        final script = list.join(close ? '; ' : ' && ');
        result = await _try('pkexec', ['/bin/sh', '-c', script]);
        if (result == null) {
          return 'This computer has no pkexec to ask for the password. '
              'Run this in a terminal instead:\nsudo sh -c \'$script\'';
        }
        // 126: the password prompt was closed; 127: not allowed.
        if (result.exitCode == 126 || result.exitCode == 127) {
          return 'The password wasn\'t given, so nothing changed.';
        }
      case FirewallKind.windows:
        final args = list.join(' & ').replaceAll("'", "''");
        result = await _try('powershell', [
          '-NoProfile',
          '-Command',
          "Start-Process -FilePath cmd -ArgumentList '/c $args' "
              '-Verb RunAs -Wait -WindowStyle Hidden',
        ]);
        if (result != null && result.exitCode != 0) {
          return 'Windows didn\'t allow it, so nothing changed.';
        }
      case FirewallKind.macos:
        final script = list.join(' && ').replaceAll('"', r'\"');
        result = await _try('osascript', [
          '-e',
          'do shell script "$script" with administrator privileges',
        ]);
      case FirewallKind.none:
        return null;
    }
    if (result == null) return 'That didn\'t work on this computer.';
    if (result.exitCode != 0 && !close) {
      final why = '${result.stderr}'.trim();
      return why.isEmpty ? 'That didn\'t work (code ${result.exitCode}).' : why;
    }
    return null;
  }
}
