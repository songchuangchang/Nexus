import 'package:flutter/material.dart';
import 'plugin_context.dart';

enum PluginSource { system, installed, market }

enum PluginKind { declarative, mcpRemote }

extension PluginKindX on PluginKind {
  String get displayLabel => switch (this) {
        PluginKind.mcpRemote => 'MCP',
        PluginKind.declarative => 'Skill',
      };

  bool get isRemote => this == PluginKind.mcpRemote;

  bool get isDeclarative => this == PluginKind.declarative;
}

class PluginMetadata {
  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final String homepage;
  final String minAppVersion;
  final String promptProtocol;
  final List<String> tags;
  final PluginKind kind;
  final String triggerType;
  final Map<String, dynamic> extra;

  const PluginMetadata({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    this.homepage = '',
    this.minAppVersion = '0.0.1',
    this.promptProtocol = '',
    this.tags = const [],
    this.kind = PluginKind.declarative,
    this.triggerType = '',
    this.extra = const {},
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'version': version,
        'author': author,
        'description': description,
        'homepage': homepage,
        'minAppVersion': minAppVersion,
        'promptProtocol': promptProtocol,
        'tags': tags.join(','),
        'kind': kind.name,
        'triggerType': triggerType,
        'extra': extra,
      };

  factory PluginMetadata.fromMap(Map<String, dynamic> m) {
    final rawTags = m['tags'];
    final tags = rawTags is List
        ? rawTags
            .whereType<String>()
            .where((e) => e.isNotEmpty)
            .toList(growable: false)
        : (rawTags as String? ?? '')
            .split(',')
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
    final kindName = m['kind'] as String?;
    final rawExtra = m['extra'];

    return PluginMetadata(
      id: m['id'] as String,
      name: m['name'] as String? ?? '',
      version: m['version'] as String? ?? '0.0.1',
      author: m['author'] as String? ?? '',
      description: m['description'] as String? ?? '',
      homepage: m['homepage'] as String? ?? '',
      minAppVersion: m['minAppVersion'] as String? ?? '0.0.1',
      promptProtocol: m['promptProtocol'] as String? ?? '',
      tags: tags,
      kind: PluginKind.values.any((e) => e.name == kindName)
          ? PluginKind.values.byName(kindName!)
          : PluginKind.declarative,
      triggerType: m['triggerType'] as String? ?? '',
      extra: rawExtra is Map
          ? Map<String, dynamic>.fromEntries(
              rawExtra.entries.where((entry) => entry.key is String).map(
                    (entry) => MapEntry(entry.key as String, entry.value),
                  ),
            )
          : const <String, dynamic>{},
    );
  }

  /// 复制一个新的 PluginMetadata，允许覆盖部分字段（NEW-BUG-02 需要：以 DB 主键 id 为准对齐）
  PluginMetadata copyWith({
    String? id,
    String? name,
    String? version,
    String? author,
    String? description,
    String? homepage,
    String? minAppVersion,
    String? promptProtocol,
    List<String>? tags,
    PluginKind? kind,
    String? triggerType,
    Map<String, dynamic>? extra,
  }) {
    return PluginMetadata(
      id: id ?? this.id,
      name: name ?? this.name,
      version: version ?? this.version,
      author: author ?? this.author,
      description: description ?? this.description,
      homepage: homepage ?? this.homepage,
      minAppVersion: minAppVersion ?? this.minAppVersion,
      promptProtocol: promptProtocol ?? this.promptProtocol,
      tags: tags ?? List<String>.unmodifiable(this.tags),
      kind: kind ?? this.kind,
      triggerType: triggerType ?? this.triggerType,
      extra: extra ?? Map<String, dynamic>.unmodifiable(this.extra),
    );
  }
}

enum PluginEventType {
  uiToaster,
  uiDialog,
  navigatePush,
  dataMutate,
  messageAppend,
  lifecycleBreak,
  reasoningAppend,
  userMessageAppend,
  answerFinalize,
  stopLoop,
}

class PluginEvent {
  final PluginEventType type;
  final Map<String, dynamic> payload;

  const PluginEvent(this.type, {this.payload = const {}});
}

abstract class ReActPlugin {
  String get triggerType;
  RegExp? get legacyTrigger;
  PluginSource get source;
  PluginMetadata get metadata;

  Future<void> handle(
    BuildContext context,
    PluginContext pluginContext,
    Map<String, dynamic> attrs,
  );
}
