import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;
import 'package:sqlite3/sqlite3.dart' as raw;

import '../services/secret_store.dart';

/// The key every companion database is encrypted with (SQLite3 Multiple
/// Ciphers, ChaCha20-Poly1305), so chats and memories can't be read from
/// the disk, a backup or a stolen laptop without it.
///
/// The key is a random 64-character string, or a password of the human's
/// own, and lives in [SecretStore] (the keyring, or DPAPI on Windows), so
/// the app opens without asking. Only when that copy is missing (another
/// computer, a reset keyring) does it ask for the key.
class DatabaseKey {
  DatabaseKey(this.supportDir, {SecretStore? secrets})
    : secrets =
          secrets ?? SecretStore(Directory(p.join(supportDir.path, 'secrets')));

  final Directory supportDir;
  final SecretStore secrets;

  static const secretName = 'database-key';

  /// Holds the new key while [change] re-encrypts, so an interrupted change
  /// is finished at the next start instead of locking anything out.
  static const nextName = 'database-key-next';

  /// Own passwords shorter than this are refused.
  static const minPasswordLength = 8;

  String? _value;

  File get _savedMark => File(p.join(supportDir.path, 'database-key-saved'));

  /// Whether the human has the key: copied it, set it as their own password
  /// or typed it in. Until then the app asks them to keep a copy.
  bool get saved => _savedMark.existsSync();

  Future<void> markSaved() => _savedMark.writeAsString('');

  Future<void> markUnsaved() async {
    if (await _savedMark.exists()) await _savedMark.delete();
  }

  /// The key in use; only valid once [unlock] or [tryPassword] succeeded.
  String get value => _value!;
  bool get unlocked => _value != null;

  /// A new random key: 64 letters and digits (about 380 bits).
  static String generate() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return String.fromCharCodes(
      List.generate(64, (_) => chars.codeUnitAt(r.nextInt(chars.length))),
    );
  }

  /// `PRAGMA key` and `rekey` take the key as an SQL string.
  static String quote(String key) => "'${key.replaceAll("'", "''")}'";

  /// Every companion database there is: `companion.db` and
  /// `companions/*.db`.
  List<File> databases() {
    final files = <File>[File(p.join(supportDir.path, 'companion.db'))];
    final more = Directory(p.join(supportDir.path, 'companions'));
    if (more.existsSync()) {
      files.addAll(
        more.listSync().whereType<File>().where((f) => f.path.endsWith('.db')),
      );
    }
    return [
      for (final f in files)
        if (f.existsSync()) f,
    ];
  }

  /// Whether [f] is a database nobody encrypted yet (made before
  /// encryption, or empty).
  static bool isPlain(File f) {
    final raf = f.openSync();
    try {
      final head = raf.readSync(16);
      return head.isEmpty ||
          String.fromCharCodes(head) == 'SQLite format 3\x00';
    } finally {
      raf.closeSync();
    }
  }

  /// Gets the key ready at startup. False when encrypted databases are
  /// there but their key isn't: the app then asks for it ([tryPassword]).
  ///
  /// A first start makes a new key; databases from before encryption are
  /// encrypted with it.
  Future<bool> unlock() async {
    var key = await secrets.read(secretName);
    final next = await secrets.read(nextName);
    if (next != null) {
      // A change was cut short: move the rest over to the new key.
      for (final f in databases()) {
        if (isPlain(f)) continue;
        if (!opens(f, next) && key != null && opens(f, key)) {
          _rekey(f, key, next);
        }
      }
      await secrets.write(secretName, next);
      await secrets.delete(nextName);
      key = next;
    }
    final locked = [
      for (final f in databases())
        if (!isPlain(f)) f,
    ];
    if (key == null) {
      if (locked.isNotEmpty) return false;
      key = generate();
      await markUnsaved();
      await secrets.write(secretName, key);
    } else if (!locked.every((f) => opens(f, key!))) {
      return false;
    }
    _use(key);
    return true;
  }

  /// Takes [password] (the key from Settings, or the human's own password)
  /// when it opens every encrypted database, and keeps it for next time.
  Future<bool> tryPassword(String password) async {
    if (password.isEmpty) return false;
    for (final f in databases()) {
      if (!isPlain(f) && !opens(f, password)) return false;
    }
    await secrets.write(secretName, password);
    _use(password);
    await markSaved();
    return true;
  }

  void _use(String key) {
    _value = key;
    for (final f in databases()) {
      if (isPlain(f)) _encrypt(f, key);
    }
  }

  /// Re-encrypts every database with [next], [open] (at [openPath]) being
  /// the one the app has open. The new key is saved first, so a crash
  /// half-way is finished by the next [unlock].
  Future<void> change(
    String next, {
    required Database open,
    required String openPath,
  }) async {
    final old = value;
    if (next == old) return;
    await secrets.write(nextName, next);
    for (final f in databases()) {
      if (p.equals(f.path, openPath)) {
        await open.execute('PRAGMA rekey = ${quote(next)}');
      } else if (isPlain(f)) {
        _encrypt(f, next);
      } else {
        _rekey(f, old, next);
      }
    }
    await secrets.write(secretName, next);
    await secrets.delete(nextName);
    _value = next;
  }

  /// When the key is lost for good: moves the encrypted databases into a
  /// `locked-<time>` folder (kept, should the key turn up) and starts over
  /// with a new key and empty chats and memories.
  Future<Directory> setAside() async {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    final to = Directory(p.join(supportDir.path, 'locked-$stamp'));
    for (final f in databases()) {
      if (isPlain(f)) continue;
      final rel = p.relative(f.path, from: supportDir.path);
      final target = File(p.join(to.path, rel));
      await target.parent.create(recursive: true);
      for (final side in ['', '-journal', '-wal', '-shm']) {
        final s = File('${f.path}$side');
        if (await s.exists()) await s.rename('${target.path}$side');
      }
    }
    await secrets.delete(nextName);
    await markUnsaved();
    final key = generate();
    await secrets.write(secretName, key);
    _use(key);
    return to;
  }

  /// Whether [key] opens the encrypted database [f].
  static bool opens(File f, String key) {
    raw.Database? db;
    try {
      db = raw.sqlite3.open(f.path, mode: raw.OpenMode.readOnly);
      db.execute('PRAGMA key = ${quote(key)}');
      db.select('SELECT count(*) FROM sqlite_master');
      return true;
    } on raw.SqliteException {
      return false;
    } finally {
      db?.close();
    }
  }

  static void _rekey(File f, String from, String to) {
    final db = raw.sqlite3.open(f.path);
    try {
      db.execute('PRAGMA key = ${quote(from)}');
      db.select('SELECT count(*) FROM sqlite_master');
      db.execute('PRAGMA rekey = ${quote(to)}');
    } finally {
      db.close();
    }
  }

  static void _encrypt(File f, String key) {
    final db = raw.sqlite3.open(f.path);
    try {
      // Encryption rewrites pages in place, which WAL mode doesn't allow.
      db.execute('PRAGMA journal_mode = DELETE');
      db.execute('PRAGMA rekey = ${quote(key)}');
    } finally {
      db.close();
    }
  }
}
