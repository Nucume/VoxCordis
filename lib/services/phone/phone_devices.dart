import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../secret_store.dart';
import 'phone_crypto.dart';

/// A phone allowed to use VoxCordis.
class PairedPhone {
  const PairedPhone({
    required this.id,
    required this.name,
    required this.key,
    required this.added,
    this.lastSeen,
  });

  final String id;
  final String name;

  /// The phone's own key ([PhoneCrypto]), base64url.
  final String key;
  final DateTime added;
  final DateTime? lastSeen;

  PairedPhone copyWith({String? name, DateTime? lastSeen}) => PairedPhone(
    id: id,
    name: name ?? this.name,
    key: key,
    added: added,
    lastSeen: lastSeen ?? this.lastSeen,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'key': key,
    'added': added.toUtc().toIso8601String(),
    if (lastSeen != null) 'lastSeen': lastSeen!.toUtc().toIso8601String(),
  };

  static PairedPhone? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], key = j['key'];
    if (id is! String || key is! String) return null;
    return PairedPhone(
      id: id,
      name: j['name'] as String? ?? 'Phone',
      key: key,
      added: DateTime.tryParse('${j['added']}')?.toLocal() ?? DateTime.now(),
      lastSeen: DateTime.tryParse('${j['lastSeen']}')?.toLocal(),
    );
  }
}

/// A QR code's one-time way in: [id] names it, [secret] is only in the
/// code. It works once, until [expires].
class PairingCode {
  PairingCode({required this.id, required this.secret, required this.expires});

  final String id;
  final List<int> secret;
  final DateTime expires;
  bool used = false;

  bool get live => !used && DateTime.now().isBefore(expires);

  /// What goes after the `#` of the page's address.
  String get fragment => 'pair=$id.${PhoneCrypto.encode(secret)}';
}

/// The phones paired with this computer, kept with the other secrets
/// ([SecretStore]: the desktop keyring, or DPAPI on Windows), since each
/// one's key opens its messages. Also hands out pairing codes.
class PhoneDevices extends ChangeNotifier {
  PhoneDevices(this._secrets);

  final SecretStore? _secrets;
  static const _name = 'phone-devices';

  /// How long a QR code works.
  static const codeLife = Duration(minutes: 5);

  var phones = <PairedPhone>[];
  bool _loaded = false;

  /// The QR code showing now; one at a time.
  PairingCode? code;

  /// Phones connected now, by id.
  final connected = <String>{};

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final text = await _secrets?.read(_name);
      if (text == null || text.isEmpty) return;
      final list = jsonDecode(text);
      if (list is List) {
        phones = [for (final j in list) ?PairedPhone.fromJson(j)];
      }
    } on Object catch (e) {
      debugPrint('Paired phones couldn\'t be read: $e');
    }
    notifyListeners();
  }

  /// Saves one after another, each the list as it is by then.
  Future<void> _saving = Future.value();

  Future<void> _save() {
    notifyListeners();
    return _saving = _saving.then((_) async {
      try {
        await _secrets?.write(
          _name,
          jsonEncode([for (final p in phones) p.toJson()]),
        );
      } on Object catch (e) {
        debugPrint('Paired phones couldn\'t be saved: $e');
      }
    });
  }

  PairedPhone? byId(String id) => phones.where((p) => p.id == id).firstOrNull;

  /// A fresh QR code; the last one stops working.
  PairingCode newCode() {
    final c = code = PairingCode(
      id: PhoneCrypto.encode(PhoneCrypto.randomBytes(6)),
      secret: PhoneCrypto.randomBytes(PhoneCrypto.keyBytes),
      expires: DateTime.now().add(codeLife),
    );
    notifyListeners();
    return c;
  }

  /// The live code named [id], if any.
  PairingCode? liveCode(String id) {
    final c = code;
    return c != null && c.id == id && c.live ? c : null;
  }

  void dropCode() {
    code = null;
    notifyListeners();
  }

  /// Pairs a phone called [name]: it gets an id and a key of its own.
  Future<PairedPhone> add(String name) async {
    await load();
    final phone = PairedPhone(
      id: PhoneCrypto.encode(PhoneCrypto.randomBytes(9)),
      name: name.trim().isEmpty ? 'Phone' : name.trim(),
      key: PhoneCrypto.encode(PhoneCrypto.randomBytes(PhoneCrypto.keyBytes)),
      added: DateTime.now(),
      lastSeen: DateTime.now(),
    );
    phones = [...phones, phone];
    await _save();
    return phone;
  }

  Future<void> seen(String id) async {
    phones = [
      for (final p in phones)
        p.id == id ? p.copyWith(lastSeen: DateTime.now()) : p,
    ];
    await _save();
  }

  Future<void> rename(String id, String name) async {
    phones = [
      for (final p in phones) p.id == id ? p.copyWith(name: name.trim()) : p,
    ];
    await _save();
  }

  /// Unpairs [id]; it must scan a new code to come back. [onRemoved]
  /// (the server) closes its connection.
  Future<void> remove(String id) async {
    phones = phones.where((p) => p.id != id).toList();
    await _save();
    onRemoved?.call(id);
  }

  Future<void> removeAll() async {
    final ids = [for (final p in phones) p.id];
    phones = [];
    await _save();
    for (final id in ids) {
      onRemoved?.call(id);
    }
  }

  void Function(String id)? onRemoved;

  void setConnected(String id, bool on) {
    final changed = on ? connected.add(id) : connected.remove(id);
    if (changed) notifyListeners();
  }
}
