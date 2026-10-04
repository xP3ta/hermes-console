final class FreeTierStatus {
  final bool hasGuest;
  final bool enabled;
  final bool available;
  final bool noticePending;
  final String model;
  final String label;
  final String? error;
  final String? errorCode;
  final bool? retryable;
  final int? retryAfter;

  const FreeTierStatus({
    required this.hasGuest,
    required this.enabled,
    required this.available,
    required this.noticePending,
    required this.model,
    required this.label,
    this.error,
    this.errorCode,
    this.retryable,
    this.retryAfter,
  });

  bool get shouldShowNotice => hasGuest && noticePending;

  factory FreeTierStatus.fromJson(Map<String, dynamic> json) {
    for (final key in const [
      'has_guest',
      'enabled',
      'available',
      'notice_pending',
    ]) {
      if (json[key] is! bool) {
        throw const FormatException('Invalid free-tier status');
      }
    }
    if (json['model'] is! String || json['label'] is! String) {
      throw const FormatException('Invalid free-tier status');
    }
    return FreeTierStatus(
      hasGuest: json['has_guest'] as bool,
      enabled: json['enabled'] as bool,
      available: json['available'] as bool,
      noticePending: json['notice_pending'] as bool,
      model: json['model'] as String,
      label: json['label'] as String,
      error: json['error'] is String ? json['error'] as String : null,
      errorCode: json['error_code'] is String
          ? json['error_code'] as String
          : null,
      retryable: json['retryable'] is bool ? json['retryable'] as bool : null,
      retryAfter: json['retry_after'] is int
          ? json['retry_after'] as int
          : null,
    );
  }
}

final class FreeTierAckNotice {
  final bool acked;

  const FreeTierAckNotice(this.acked);

  factory FreeTierAckNotice.fromJson(Map<String, dynamic> json) {
    if (json['acked'] is! bool) {
      throw const FormatException('Invalid free-tier notice acknowledgement');
    }
    return FreeTierAckNotice(json['acked'] as bool);
  }
}
