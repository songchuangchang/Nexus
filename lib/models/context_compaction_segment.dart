class ContextCompactionSegment {
  final String id;
  final String conversationId;
  final String summary;
  final String startMessageId;
  final String endMessageId;
  final int sourceTokenEstimate;
  final DateTime createdAt;

  const ContextCompactionSegment({
    required this.id,
    required this.conversationId,
    required this.summary,
    required this.startMessageId,
    required this.endMessageId,
    required this.sourceTokenEstimate,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'conversationId': conversationId,
        'summary': summary,
        'startMessageId': startMessageId,
        'endMessageId': endMessageId,
        'sourceTokenEstimate': sourceTokenEstimate,
        'createdAt': createdAt.toIso8601String(),
      };

  factory ContextCompactionSegment.fromMap(Map<String, dynamic> map) {
    return ContextCompactionSegment(
      id: map['id'] as String,
      conversationId: map['conversationId'] as String,
      summary: map['summary'] as String,
      startMessageId: map['startMessageId'] as String,
      endMessageId: map['endMessageId'] as String,
      sourceTokenEstimate: (map['sourceTokenEstimate'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(map['createdAt'] as String),
    );
  }
}
