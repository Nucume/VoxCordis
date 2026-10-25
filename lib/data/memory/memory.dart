import 'dart:convert';

/// One remembered fact. Shape follows Nemini SmartDisk facts.
class Memory {
  const Memory({
    required this.id,
    required this.text,
    this.subject,
    this.predicate,
    this.object,
    this.category = 'general',
    this.priority = 50,
    required this.validFrom,
    this.validTo,
    required this.recordedAt,
    this.reinforcedCount = 0,
    this.origin = 'chat',
    this.folderPath,
    this.sourceIds = const [],
    this.supersededBy,
    this.forgottenAt,
  });

  final String id;
  final String text;
  final String? subject;
  final String? predicate;
  final String? object;
  final String category;

  /// 0 to 100. Decides what goes into the prompt first.
  final int priority;
  final DateTime validFrom;

  /// Set when the fact was superseded. Only facts with no [validTo] are recalled.
  final DateTime? validTo;
  final DateTime recordedAt;
  final int reinforcedCount;
  final String origin;
  final String? folderPath;

  /// Ids of the messages this fact came from.
  final List<String> sourceIds;
  final String? supersededBy;

  /// When the companion forgot it. Such a fact is out of every prompt and
  /// waits in "Recently forgotten" until it is restored or purged.
  final DateTime? forgottenAt;

  bool get isCurrent => validTo == null;

  Map<String, Object?> toRow() => {
    'id': id,
    'text': text,
    'subject': subject,
    'predicate': predicate,
    'object': object,
    'category': category,
    'priority': priority,
    'valid_from': validFrom.toUtc().toIso8601String(),
    'valid_to': validTo?.toUtc().toIso8601String(),
    'recorded_at': recordedAt.toUtc().toIso8601String(),
    'reinforced_count': reinforcedCount,
    'origin': origin,
    'folder_path': folderPath,
    'source_ids': jsonEncode(sourceIds),
    'superseded_by': supersededBy,
  };

  factory Memory.fromRow(Map<String, Object?> r) => Memory(
    id: r['id'] as String,
    text: r['text'] as String,
    subject: r['subject'] as String?,
    predicate: r['predicate'] as String?,
    object: r['object'] as String?,
    category: r['category'] as String,
    priority: r['priority'] as int,
    validFrom: DateTime.parse(r['valid_from'] as String),
    validTo: r['valid_to'] == null
        ? null
        : DateTime.parse(r['valid_to'] as String),
    recordedAt: DateTime.parse(r['recorded_at'] as String),
    reinforcedCount: r['reinforced_count'] as int,
    origin: r['origin'] as String,
    folderPath: r['folder_path'] as String?,
    sourceIds: (jsonDecode(r['source_ids'] as String) as List).cast<String>(),
    supersededBy: r['superseded_by'] as String?,
    forgottenAt: r['forgotten_at'] == null
        ? null
        : DateTime.parse(r['forgotten_at'] as String),
  );
}
