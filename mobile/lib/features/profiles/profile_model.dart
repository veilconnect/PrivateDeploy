class Profile {
  final String id;
  final String name;
  final String? subscriptionUrl;
  final String? content;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastUpdated;

  Profile({
    required this.id,
    required this.name,
    this.subscriptionUrl,
    this.content,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
    this.lastUpdated,
  });

  Profile copyWith({
    String? id,
    String? name,
    String? subscriptionUrl,
    String? content,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastUpdated,
  }) {
    return Profile(
      id: id ?? this.id,
      name: name ?? this.name,
      subscriptionUrl: subscriptionUrl ?? this.subscriptionUrl,
      content: content ?? this.content,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }

  factory Profile.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic value) {
      if (value == null) return null;
      if (value is DateTime) return value;
      if (value is String && value.isNotEmpty) {
        return DateTime.tryParse(value);
      }
      return null;
    }

    return Profile(
      id: (json['id'] ?? '').toString(),
      name: json['name'] ?? '',
      subscriptionUrl: json['subscription_url'] ?? json['subscriptionUrl'],
      content: json['content'],
      isActive: (json['is_active'] ?? json['active'] ?? false) == true,
      createdAt: parseDate(json['created_at']) ??
          parseDate(json['createdAt']) ??
          DateTime.now(),
      updatedAt: parseDate(json['updated_at']) ??
          parseDate(json['updatedAt']) ??
          DateTime.now(),
      lastUpdated:
          parseDate(json['last_updated']) ?? parseDate(json['lastUpdated']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'subscription_url': subscriptionUrl,
      'content': content,
      'is_active': isActive,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'last_updated': lastUpdated?.toIso8601String(),
    };
  }
}
