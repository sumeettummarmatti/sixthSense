import 'dart:convert';

import '../api/device_identity.dart';

/// Names and phone numbers of my trusted contacts. The server only knows link
/// ids and status (rule 2), so names live on this phone, Keystore-encrypted.
class ContactBook {
  const ContactBook(this.identity);

  final DeviceIdentity identity;

  static const _key = 'contact_book';
  static const _labelKey = 'owner_label';

  Future<Map<String, LocalContact>> load() async {
    final raw = await identity.readValue(_key);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map(
        (id, value) => MapEntry(
          id,
          LocalContact.fromJson((value as Map).cast<String, dynamic>()),
        ),
      );
    } on FormatException {
      return {};
    }
  }

  Future<void> save(String linkId, LocalContact contact) async {
    final all = await load();
    all[linkId] = contact;
    await identity.saveValue(
      _key,
      jsonEncode(all.map((id, value) => MapEntry(id, value.toJson()))),
    );
  }

  Future<void> remove(String linkId) async {
    final all = await load()
      ..remove(linkId);
    await identity.saveValue(
      _key,
      jsonEncode(all.map((id, value) => MapEntry(id, value.toJson()))),
    );
  }

  /// How my contacts see me in invites and alerts (1-40 characters).
  Future<String> ownerLabel() async {
    final saved = await identity.readValue(_labelKey);
    return (saved == null || saved.trim().isEmpty)
        ? 'A SixthSense user'
        : saved;
  }

  Future<void> saveOwnerLabel(String label) async {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return;
    await identity.saveValue(
      _labelKey,
      trimmed.substring(0, trimmed.length.clamp(0, 40)),
    );
  }
}

class LocalContact {
  const LocalContact({required this.name, this.phone = ''});

  final String name;
  final String phone;

  Map<String, String> toJson() => {'name': name, 'phone': phone};

  factory LocalContact.fromJson(Map<String, dynamic> json) => LocalContact(
    name: json['name'] as String? ?? 'Contact',
    phone: json['phone'] as String? ?? '',
  );
}
