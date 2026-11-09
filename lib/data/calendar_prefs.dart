/// Where the companion reads and writes the human's calendar.
enum CalendarProvider {
  /// No calendar connected.
  none,

  /// Google Calendar, signed in through the browser (OAuth).
  google,

  /// Any CalDAV server: iCloud, Fastmail, Nextcloud, mailbox.org…
  caldav,

  /// A private calendar address (.ics). Read-only.
  link,
}

/// Settings → Connections → Calendar. The passwords, tokens and the private
/// link live in [SecretStore], never here.
class CalendarPrefs {
  const CalendarPrefs({
    this.provider = CalendarProvider.none,
    this.askFirst = true,
    this.account = '',
    this.caldavUrl = '',
    this.caldavUser = '',
    this.calendars = const [],
    this.writeTo,
  });

  final CalendarProvider provider;

  /// Show the human every event the companion adds, moves or deletes
  /// before it happens.
  final bool askFirst;

  /// Who is signed in, for Settings to show ("you@example.com").
  final String account;

  /// The CalDAV server address and user name (the app password is a
  /// secret).
  final String caldavUrl;
  final String caldavUser;

  /// The calendars read, by id. Empty means every calendar found.
  final List<String> calendars;

  /// The calendar new events go to; null for the main one.
  final String? writeTo;

  bool get connected => provider != CalendarProvider.none;

  /// Whether the companion may change events at all (a link is read-only).
  bool get canWrite =>
      provider == CalendarProvider.google ||
      provider == CalendarProvider.caldav;

  CalendarPrefs copyWith({
    CalendarProvider? provider,
    bool? askFirst,
    String? account,
    String? caldavUrl,
    String? caldavUser,
    List<String>? calendars,
    String? writeTo,
    bool clearWriteTo = false,
  }) => CalendarPrefs(
    provider: provider ?? this.provider,
    askFirst: askFirst ?? this.askFirst,
    account: account ?? this.account,
    caldavUrl: caldavUrl ?? this.caldavUrl,
    caldavUser: caldavUser ?? this.caldavUser,
    calendars: calendars ?? this.calendars,
    writeTo: clearWriteTo ? null : writeTo ?? this.writeTo,
  );

  Map<String, Object?> toJson() => {
    'provider': provider.name,
    'askFirst': askFirst,
    if (account.isNotEmpty) 'account': account,
    if (caldavUrl.isNotEmpty) 'caldavUrl': caldavUrl,
    if (caldavUser.isNotEmpty) 'caldavUser': caldavUser,
    if (calendars.isNotEmpty) 'calendars': calendars,
    if (writeTo != null) 'writeTo': writeTo,
  };

  factory CalendarPrefs.fromJson(Object? json) {
    if (json is! Map) return const CalendarPrefs();
    return CalendarPrefs(
      provider:
          CalendarProvider.values.asNameMap()[json['provider']] ??
          CalendarProvider.none,
      askFirst: json['askFirst'] as bool? ?? true,
      account: json['account'] as String? ?? '',
      caldavUrl: json['caldavUrl'] as String? ?? '',
      caldavUser: json['caldavUser'] as String? ?? '',
      calendars: [
        if (json['calendars'] is List)
          for (final c in json['calendars'] as List)
            if (c is String) c,
      ],
      writeTo: json['writeTo'] as String?,
    );
  }
}
