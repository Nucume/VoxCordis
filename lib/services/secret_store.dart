import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Keeps secrets such as the server API key out of settings.json, where
/// any program or backup that reads the file would see them.
///
/// - **Linux:** the desktop keyring (GNOME Keyring, KWallet…) through
///   libsecret, which is loaded when present, so the app still starts
///   without it.
/// - **Windows:** encrypted for the signed-in user with DPAPI, the way
///   browsers keep saved passwords, in `secrets/` in the app folder.
/// - **Otherwise** (no keyring running, or it refuses): a file in
///   `secrets/` that only the user can open.
class SecretStore {
  /// [system] false keeps secrets in the private file only (tests).
  SecretStore(this.dir, {SecretBackend? backend, bool system = true})
    : _backend = backend ?? (system ? SecretBackend.forPlatform() : null);

  /// `secrets/` in the app-support directory.
  final Directory dir;
  final SecretBackend? _backend;

  File _plain(String name) => File(p.join(dir.path, name));
  File _sealed(String name) => File(p.join(dir.path, '$name.dpapi'));

  Future<String?> read(String name) async {
    final b = _backend;
    try {
      if (b is _Dpapi) {
        final sealed = _sealed(name);
        if (await sealed.exists()) {
          return b.unseal(await sealed.readAsBytes());
        }
      } else if (b is _Libsecret) {
        final v = await b.read(name);
        if (v != null) return v;
      }
    } on Object {
      // Locked keyring, or sealed by another account: fall through.
    }
    final plain = _plain(name);
    return await plain.exists() ? await plain.readAsString() : null;
  }

  /// Saves [value], or forgets the secret when it is empty.
  Future<void> write(String name, String value) async {
    if (value.isEmpty) return delete(name);
    await dir.create(recursive: true);
    await restrictToOwner(dir.path, directory: true);
    final b = _backend;
    try {
      if (b is _Dpapi) {
        await _replace(_sealed(name), b.seal(value));
        await _deleteIfThere(_plain(name));
        return;
      }
      if (b is _Libsecret && await b.write(name, value)) {
        await _deleteIfThere(_plain(name));
        return;
      }
    } on Object {
      // No keyring or no DPAPI: the plain file below.
    }
    await _replace(_plain(name), utf8.encode(value));
  }

  Future<void> delete(String name) async {
    await _deleteIfThere(_plain(name));
    await _deleteIfThere(_sealed(name));
    final b = _backend;
    if (b is _Libsecret) {
      try {
        await b.delete(name);
      } on Object {
        // Nothing to clear.
      }
    }
  }

  /// Written beside the file, made private and then swapped in, so the
  /// secret is never readable by others, not even for a moment.
  static Future<void> _replace(File f, List<int> bytes) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(const [], flush: true);
    await restrictToOwner(tmp.path);
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }

  static Future<void> _deleteIfThere(File f) async {
    if (await f.exists()) await f.delete();
  }
}

/// The OS keeper of secrets, or null when there is none to use.
sealed class SecretBackend {
  static SecretBackend? forPlatform() {
    if (Platform.isWindows) return _Dpapi();
    if (Platform.isLinux) return _Libsecret();
    return null;
  }

  /// Linux's keyring, for tests that run against a real one.
  static SecretBackend libsecret({String schema = _Libsecret.appSchema}) =>
      _Libsecret(schema: schema);
}

/// Makes [path] readable only by the user who runs the app (0600, or 0700
/// for a folder). Windows already keeps each user's app folder private, so
/// there it does nothing. Best effort: a failure leaves the mode as it was.
Future<void> restrictToOwner(String path, {bool directory = false}) async {
  if (Platform.isWindows) return;
  try {
    final chmod = DynamicLibrary.process()
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Uint32),
          int Function(Pointer<Utf8>, int)
        >('chmod');
    final c = path.toNativeUtf8();
    try {
      chmod(c, directory ? 0x1C0 /* 0700 */ : 0x180 /* 0600 */);
    } finally {
      malloc.free(c);
    }
  } on Object {
    // No libc chmod: leave it.
  }
}

// ---------------------------------------------------------------------------
// Windows: DPAPI (crypt32), bound to the signed-in user.

final class _Blob extends Struct {
  @Uint32()
  external int size;
  external Pointer<Uint8> data;
}

typedef _ProtectC =
    Int32 Function(
      Pointer<_Blob>,
      Pointer<Utf16>,
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<_Blob>,
    );
typedef _ProtectDart =
    int Function(
      Pointer<_Blob>,
      Pointer<Utf16>,
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<_Blob>,
    );
typedef _UnprotectC =
    Int32 Function(
      Pointer<_Blob>,
      Pointer<Pointer<Utf16>>,
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<_Blob>,
    );
typedef _UnprotectDart =
    int Function(
      Pointer<_Blob>,
      Pointer<Pointer<Utf16>>,
      Pointer<_Blob>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<_Blob>,
    );

final class _Dpapi extends SecretBackend {
  static const _uiForbidden = 0x1;

  /// Ties the sealed bytes to this app, so another program the user runs
  /// can't simply ask DPAPI to open them without knowing it.
  static final _entropy = utf8.encode('VoxCordis secret v1');

  List<int> seal(String value) => _call(utf8.encode(value), protect: true);

  String unseal(List<int> sealed) => utf8.decode(_call(sealed, protect: false));

  List<int> _call(List<int> input, {required bool protect}) {
    final crypt32 = DynamicLibrary.open('crypt32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final localFree = kernel32
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    final inBlob = calloc<_Blob>();
    final entropy = calloc<_Blob>();
    final outBlob = calloc<_Blob>();
    final inBytes = calloc<Uint8>(input.isEmpty ? 1 : input.length);
    final entropyBytes = calloc<Uint8>(_entropy.length);
    try {
      inBytes.asTypedList(input.length).setAll(0, input);
      entropyBytes.asTypedList(_entropy.length).setAll(0, _entropy);
      inBlob.ref
        ..size = input.length
        ..data = inBytes;
      entropy.ref
        ..size = _entropy.length
        ..data = entropyBytes;
      final ok = protect
          ? crypt32.lookupFunction<_ProtectC, _ProtectDart>('CryptProtectData')(
              inBlob,
              nullptr,
              entropy,
              nullptr,
              nullptr,
              _uiForbidden,
              outBlob,
            )
          : crypt32.lookupFunction<_UnprotectC, _UnprotectDart>(
              'CryptUnprotectData',
            )(
              inBlob,
              nullptr,
              entropy,
              nullptr,
              nullptr,
              _uiForbidden,
              outBlob,
            );
      if (ok == 0) throw const FileSystemException('DPAPI refused');
      try {
        return List.of(outBlob.ref.data.asTypedList(outBlob.ref.size));
      } finally {
        localFree(outBlob.ref.data.cast());
      }
    } finally {
      calloc
        ..free(inBlob)
        ..free(entropy)
        ..free(outBlob)
        ..free(inBytes)
        ..free(entropyBytes);
    }
  }
}

// ---------------------------------------------------------------------------
// Linux: libsecret, loaded at run time. Its calls may wait for the human to
// unlock the keyring, so each runs on its own isolate, never the window's.

final class _Libsecret extends SecretBackend {
  _Libsecret({this.schema = appSchema});

  static const appSchema = 'io.github.nucume.VoxCordis';
  final String schema;

  Future<String?> read(String name) {
    final s = schema;
    return Isolate.run(() => _LibsecretCalls.open()?.lookup(s, name));
  }

  Future<bool> write(String name, String value) {
    final s = schema;
    return Isolate.run(
      () => _LibsecretCalls.open()?.store(s, name, value) ?? false,
    );
  }

  Future<void> delete(String name) {
    final s = schema;
    return Isolate.run(() => _LibsecretCalls.open()?.clear(s, name));
  }
}

typedef _HashNewC =
    Pointer<Void> Function(Pointer<Void> hash, Pointer<Void> equal);
typedef _HashInsertC =
    Int32 Function(Pointer<Void> table, Pointer<Void> key, Pointer<Void> value);
typedef _HashInsertDart =
    int Function(Pointer<Void> table, Pointer<Void> key, Pointer<Void> value);
typedef _VoidPtrC = Void Function(Pointer<Void>);
typedef _VoidPtrDart = void Function(Pointer<Void>);
typedef _SchemaNewvC =
    Pointer<Void> Function(
      Pointer<Utf8> name,
      Int32 flags,
      Pointer<Void> attrs,
    );
typedef _SchemaNewvDart =
    Pointer<Void> Function(Pointer<Utf8> name, int flags, Pointer<Void> attrs);
typedef _StorevC =
    Int32 Function(
      Pointer<Void> schema,
      Pointer<Void> attrs,
      Pointer<Utf8> collection,
      Pointer<Utf8> label,
      Pointer<Utf8> password,
      Pointer<Void> cancellable,
      Pointer<Pointer<Void>> error,
    );
typedef _StorevDart =
    int Function(
      Pointer<Void> schema,
      Pointer<Void> attrs,
      Pointer<Utf8> collection,
      Pointer<Utf8> label,
      Pointer<Utf8> password,
      Pointer<Void> cancellable,
      Pointer<Pointer<Void>> error,
    );
typedef _LookupvC =
    Pointer<Utf8> Function(
      Pointer<Void> schema,
      Pointer<Void> attrs,
      Pointer<Void> cancellable,
      Pointer<Pointer<Void>> error,
    );
typedef _ClearvC =
    Int32 Function(
      Pointer<Void> schema,
      Pointer<Void> attrs,
      Pointer<Void> cancellable,
      Pointer<Pointer<Void>> error,
    );
typedef _ClearvDart =
    int Function(
      Pointer<Void> schema,
      Pointer<Void> attrs,
      Pointer<Void> cancellable,
      Pointer<Pointer<Void>> error,
    );

class _LibsecretCalls {
  _LibsecretCalls(this._secret, this._glib);

  final DynamicLibrary _secret;
  final DynamicLibrary _glib;

  static _LibsecretCalls? open() {
    try {
      return _LibsecretCalls(
        DynamicLibrary.open('libsecret-1.so.0'),
        DynamicLibrary.open('libglib-2.0.so.0'),
      );
    } on ArgumentError {
      return null; // libsecret isn't installed.
    }
  }

  late final _hashNew = _glib.lookupFunction<_HashNewC, _HashNewC>(
    'g_hash_table_new',
  );
  late final _hashInsert = _glib.lookupFunction<_HashInsertC, _HashInsertDart>(
    'g_hash_table_insert',
  );
  late final _hashUnref = _glib.lookupFunction<_VoidPtrC, _VoidPtrDart>(
    'g_hash_table_unref',
  );
  late final _errorFree = _glib.lookupFunction<_VoidPtrC, _VoidPtrDart>(
    'g_error_free',
  );
  late final _strHash = _glib.lookup<Void>('g_str_hash');
  late final _strEqual = _glib.lookup<Void>('g_str_equal');

  late final _schemaNewv = _secret
      .lookupFunction<_SchemaNewvC, _SchemaNewvDart>('secret_schema_newv');
  late final _schemaUnref = _secret.lookupFunction<_VoidPtrC, _VoidPtrDart>(
    'secret_schema_unref',
  );
  late final _storev = _secret.lookupFunction<_StorevC, _StorevDart>(
    'secret_password_storev_sync',
  );
  late final _lookupv = _secret.lookupFunction<_LookupvC, _LookupvC>(
    'secret_password_lookupv_sync',
  );
  late final _clearv = _secret.lookupFunction<_ClearvC, _ClearvDart>(
    'secret_password_clearv_sync',
  );
  late final _free = _secret.lookupFunction<_VoidPtrC, _VoidPtrDart>(
    'secret_password_free',
  );

  /// Runs [body] with the schema (one string attribute, "name") and the
  /// attributes naming [name]; frees everything after. Throws when
  /// libsecret reports an error, e.g. no keyring is running.
  T _with<T>(
    String schema,
    String name,
    T Function(
      Pointer<Void> schema,
      Pointer<Void> attrs,
      Pointer<Pointer<Void>> error,
    )
    body,
  ) {
    final arena = Arena();
    final types = _hashNew(_strHash, _strEqual);
    final attrs = _hashNew(_strHash, _strEqual);
    final error = arena<Pointer<Void>>()..value = nullptr;
    final key = 'name'.toNativeUtf8(allocator: arena).cast<Void>();
    // SECRET_SCHEMA_ATTRIBUTE_STRING is 0; SECRET_SCHEMA_NONE is 0.
    _hashInsert(types, key, nullptr);
    final s = _schemaNewv(schema.toNativeUtf8(allocator: arena), 0, types);
    _hashInsert(attrs, key, name.toNativeUtf8(allocator: arena).cast());
    try {
      final r = body(s, attrs, error);
      if (error.value != nullptr) {
        _errorFree(error.value);
        throw const FileSystemException('The keyring refused');
      }
      return r;
    } finally {
      _hashUnref(attrs);
      _hashUnref(types);
      _schemaUnref(s);
      arena.releaseAll();
    }
  }

  String? lookup(String schema, String name) =>
      _with(schema, name, (s, attrs, error) {
        final v = _lookupv(s, attrs, nullptr, error);
        if (v == nullptr) return null;
        try {
          return v.toDartString();
        } finally {
          _free(v.cast());
        }
      });

  bool store(String schema, String name, String value) {
    final arena = Arena();
    try {
      return _with(
        schema,
        name,
        (s, attrs, error) =>
            _storev(
              s,
              attrs,
              nullptr, // the default collection, "login"
              'VoxCordis $name'.toNativeUtf8(allocator: arena),
              value.toNativeUtf8(allocator: arena),
              nullptr,
              error,
            ) !=
            0,
      );
    } finally {
      arena.releaseAll();
    }
  }

  void clear(String schema, String name) => _with(
    schema,
    name,
    (s, attrs, error) => _clearv(s, attrs, nullptr, error),
  );
}
