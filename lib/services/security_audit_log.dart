/// 安全审计时间线（build98 安全审查本地加强⑦）
///
/// JSONL 追加写入应用支持目录 `security_audit.jsonl`，保留最近 500 条。
/// 记录安装/扫描/拒绝事件，设置页「安全审计时间线」可回溯。
library security_audit_log;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'logger_service.dart';
import 'package:flutter/foundation.dart';

class AuditEvent {
  final DateTime time;
  final String type; // scan / install / reject / blacklist_hit
  final String target; // 插件名 / URL / 文件名
  final String outcome; // pass / warn / blocked / failed
  final String detail;

  const AuditEvent({
    required this.time,
    required this.type,
    required this.target,
    required this.outcome,
    this.detail = '',
  });

  factory AuditEvent.fromJson(Map<String, dynamic> j) => AuditEvent(
        time: DateTime.tryParse(j['time']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        type: j['type']?.toString() ?? '',
        target: j['target']?.toString() ?? '',
        outcome: j['outcome']?.toString() ?? '',
        detail: j['detail']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'type': type,
        'target': target,
        'outcome': outcome,
        'detail': detail,
      };
}

class SecurityAuditLog {
  static const String _fileName = 'security_audit.jsonl';
  static const int _maxLines = 500;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<void> record({
    required String type,
    required String target,
    required String outcome,
    String detail = '',
  }) async {
    try {
      final f = await _file();
      final event = AuditEvent(
        time: DateTime.now(),
        type: type,
        target: target,
        outcome: outcome,
        detail: detail,
      );
      await f.writeAsString('${jsonEncode(event.toJson())}\n',
          mode: FileMode.append, flush: false);
      // 超上限裁剪（读全量重写，500 行体量可忽略）
      final lines = await f.readAsLines();
      if (lines.length > _maxLines) {
        await f.writeAsString(
            '${lines.sublist(lines.length - _maxLines).join('\n')}\n');
      }
    } catch (e) {
      LoggerService.instance.warn('审计日志写入失败: $e', tag: 'Audit');
    }
  }

  /// 最新在前
  static Future<List<AuditEvent>> readAll() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final lines = await f.readAsLines();
      final events = <AuditEvent>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          events.add(AuditEvent.fromJson(
              Map<String, dynamic>.from(jsonDecode(line) as Map)));
        } catch (e) {
          // 单行损坏跳过
          debugPrint('catch 静默异常: $e');
        }
      }
      return events.reversed.toList();
    } catch (e) {
      LoggerService.instance.warn('审计日志读取失败: $e', tag: 'Audit');
      return [];
    }
  }

  static Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (e) {
      // 忽略
      debugPrint('catch 静默异常: $e');
    }
  }
}
