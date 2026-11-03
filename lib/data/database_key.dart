import 'dart:convert';
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

  /// The keys in use before each start over ([setAside]), as a JSON list,
  /// so chats set aside then can still be brought back ([LockedChats]).
  static const earlierName = 'database-key-earlier';

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
      // A change was cut short: move the rest over to the new key, from
      // whichever stored copy opens it (the keyring's may be stale).
      final olds = await secrets.readAll(secretName);
      for (final f in databases()) {
        if (isPlain(f) || opens(f, next)) continue;
        for (final from in olds) {
          if (opens(f, from)) {
            _rekey(f, from, next);
            break;
          }
        }
      }
      // The change drops the key it replaced, but not one kept on purpose
      // (a stale copy [change] kept for chats set aside).
      final earlier = await _earlierKeys();
      await _keepOthers({
        next,
        for (final k in olds)
          if (!earlier.contains(k)) k,
      });
      await secrets.write(secretName, next);
      await secrets.delete(nextName);
      key = next;
    }
    final locked = [
      for (final f in databases())
        if (!isPlain(f)) f,
    ];
    if (locked.isEmpty && key == null) {
      key = generate();
      await markUnsaved();
      await secrets.write(secretName, key);
    } else if (key == null || !locked.every((f) => opens(f, key!))) {
      // The keyring and the file can each hold a copy (one was written
      // while the keyring was locked), and keys from before a start over
      // are kept: whichever opens everything is the key.
      final fits = [
        for (final k in await _knownKeys())
          if (k != key && locked.every((f) => opens(f, k))) k,
      ];
      if (fits.isEmpty) return false;
      key = fits.first;
      await _keepOthers({key});
      await secrets.write(secretName, key);
    }
    _use(key);
    return true;
  }

  /// Every key this computer still has: the stored one wherever a copy
  /// is (keyring and file), one a change was moving to, and those kept
  /// when the human started over without the key ([setAside]).
  Future<List<String>> _knownKeys() async => {
    ...await secrets.readAll(secretName),
    ...await secrets.readAll(nextName),
    ...await _earlierKeys(),
  }.toList();

  /// The kept keys from every copy of the list (keyring and file), which
  /// differ when one was written while the keyring was locked.
  Future<List<String>> _earlierKeys() async {
    final keys = <String>{};
    for (final saved in await secrets.readAll(earlierName)) {
      try {
        final list = jsonDecode(saved);
        if (list is! List) continue;
        keys.addAll([
          for (final k in list)
            if (k is String && k.isNotEmpty) k,
        ]);
      } on FormatException {
        // Not a list we wrote: nothing to keep from it.
      }
    }
    return keys.toList();
  }

  /// Before a new key replaces the stored key: keeps every other key still
  /// stored (a copy in the keyring, one in the file) with the earlier ones,
  /// so chats set aside with it can still be brought back. [drop] are the
  /// new key and any key that is not to be kept.
  Future<void> _keepOthers(Set<String> drop) async {
    final keep = {...await _knownKeys()}..removeAll(drop);
    if (keep.isNotEmpty) {
      await secrets.write(earlierName, jsonEncode(keep.toList()));
    }
  }

  /// Takes [password] (the key from Settings, or the human's own password)
  /// when it opens every encrypted database, and keeps it for next time.
  Future<bool> tryPassword(String password) async {
    if (password.isEmpty) return false;
    for (final f in databases()) {
      if (!isPlain(f) && !opens(f, password)) return false;
    }
    await _keepOthers({password});
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
    // The old key is dropped, but a stale copy of another one (left in the
    // keyring while it was locked) may be the key to chats set aside.
    await _keepOthers({old, next});
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
    final to = Directory(p.join(supportDir.path, '$lockedPrefix$stamp'));
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
    // Whatever key was there may be the right one after all (a locked
    // keyring, a database left half-written): keep it for bringing the
    // chats back, rather than writing over its only copy. A copy in a
    // keyring that is locked now is kept once it can be read ([unlock]).
    final key = generate();
    await _keepOthers({key});
    await secrets.delete(nextName);
    await markUnsaved();
    await secrets.write(secretName, key);
    _use(key);
    return to;
  }

  /// The folders [setAside] moved chats into, oldest first.
  List<Directory> lockedFolders() {
    if (!supportDir.existsSync()) return const [];
    return supportDir
        .listSync()
        .whereType<Directory>()
        .where((d) => p.basename(d.path).startsWith(lockedPrefix))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  static const lockedPrefix = 'locked-';

  /// The databases in a folder [setAside] made.
  static List<File> databasesIn(Directory folder) => [
    for (final e in folder.listSync(recursive: true))
      if (e is File && e.path.endsWith('.db')) e,
  ];

  /// A key this computer kept that opens every database in [folder], or
  /// null when only the human's copy can.
  Future<String?> keptKeyFor(Directory folder) async {
    final dbs = databasesIn(folder);
    if (dbs.isEmpty) return null;
    for (final k in {if (_value != null) _value!, ...await _knownKeys()}) {
      if (dbs.every((f) => opens(f, k))) return k;
    }
    return null;
  }

  /// Whether [key] opens the encrypted database [f].
  ///
  /// A database the app was writing when it was killed (shut down, out of
  /// memory, power cut) has a "hot" journal that has to be rolled back
  /// before it can be read, which a read-only look can't do: SQLite then
  /// says "readonly", not "wrong key". Another program writing to it says
  /// "busy". Neither means the key is wrong, so those are checked on a copy
  /// (rolling back with a wrong key would scramble the real file).
  static bool opens(File f, String key) {
    final r = _look(f.path, key, readOnly: true);
    if (r == true) return true;
    if (r == false && !_hasSideFiles(f.path)) return false;
    return _opensCopy(f, key);
  }

  static const _notADatabase = 26; // SQLITE_NOTADB: what a wrong key gives

  /// True when [key] opens [path], false when it is the wrong key, null
  /// when SQLite can't tell (half-written, busy, unreadable).
  static bool? _look(String path, String key, {required bool readOnly}) {
    raw.Database? db;
    try {
      db = raw.sqlite3.open(
        path,
        mode: readOnly ? raw.OpenMode.readOnly : raw.OpenMode.readWrite,
      );
      db.execute('PRAGMA key = ${quote(key)}');
      db.execute('PRAGMA busy_timeout = 3000');
      db.select('SELECT count(*) FROM sqlite_master');
      return true;
    } on raw.SqliteException catch (e) {
      return e.resultCode == _notADatabase ? false : null;
    } finally {
      db?.close();
    }
  }

  static bool _hasSideFiles(String path) =>
      ['-journal', '-wal'].any((side) => File('$path$side').existsSync());

  /// [opens] on a copy of [f] with its journal, which may be rolled back.
  static bool _opensCopy(File f, String key) {
    Directory? tmp;
    try {
      tmp = Directory.systemTemp.createTempSync('voxcordis-key-check');
      final copy = p.join(tmp.path, 'check.db');
      f.copySync(copy);
      for (final side in ['-journal', '-wal']) {
        final s = File('${f.path}$side');
        if (s.existsSync()) s.copySync('$copy$side');
      }
      return _look(copy, key, readOnly: false) ?? false;
    } on FileSystemException {
      return false;
    } finally {
      try {
        tmp?.deleteSync(recursive: true);
      } on FileSystemException {
        // A temporary folder: the system clears it.
      }
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
