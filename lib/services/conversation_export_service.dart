import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import 'logger_service.dart';

/// build101（B6/B7）：整段对话导出服务
///
/// 支持 Markdown（人读）与 JSON（机读/再导入）两种格式。
/// 文件落在应用文档目录的 `exports/` 子目录下，文件名格式：
///   `<清洗后的标题>_<yyyyMMdd_HHmmss>.<ext>`
///
/// 设计说明：
/// - Markdown 采用「## 角色（时间）」分节，正文原样保留（含 AI 的 reasoning 折叠块）；
/// - JSON 保留完整字段（含 token 用量、搜索来源），便于后续做导入或分析；
/// - 文件名清洗掉文件系统非法字符（`\ / : * ? " < > |`），中文标题原样保留。
class ConversationExportService {
  final _logger = LoggerService.instance;

  /// build120：导出互斥锁。
  ///
  /// 真机反馈「短时间多次导出，弹窗还没铺满整屏就跳转，结果没保存文件」——
  /// 实际链路是：写文件很快，但紧接着 `Share.shareXFiles` 会拉起系统分享面板
  /// （一次原生 Activity 跳转）。用户在前一次分享面板还停留/刚返回时再点一次导出，
  /// 两次 share 调用互相抢占，后一次写好的文件虽然落盘、却没有任何可见反馈，
  /// 体感即「没保存」。这里做单飞：导出中直接拒绝第二次，避免静默丢结果。
  static bool _exporting = false;

  /// 当前是否有导出正在进行（UI 可据此禁用入口）
  static bool get isExporting => _exporting;

  /// 导出目录（惰性创建）
  Future<Directory> _exportDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}exports');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 统一出口：单飞保护 + 写盘 + 日志。失败抛 [ExportBusyException] / IO 异常。
  Future<File> _runGuarded(
    String label,
    Future<File> Function() write,
  ) async {
    if (_exporting) {
      _logger.warn('导出被拒绝：另一次导出正在进行中（$label）', tag: 'Export');
      throw const ExportBusyException();
    }
    _exporting = true;
    try {
      final file = await write();
      // 写盘完成再记一条可核对的事实（含字节数），便于日后对账「文件到底有没有落盘」
      final size = await file.length();
      _logger.info('导出对话 $label 完成 → ${file.path}（$size 字节）',
          tag: 'Export');
      return file;
    } finally {
      _exporting = false;
    }
  }

  /// 把标题清洗成合法文件名片段
  String _sanitize(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_').trim();
    if (cleaned.isEmpty) return 'chat';
    // 限制长度，避免超长文件名（Android 单段上限通常 255 字节）
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }

  /// 文件名里的时间戳 `yyyyMMdd_HHmmss`
  String _stamp(DateTime t) {
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${p2(t.month)}${p2(t.day)}_'
        '${p2(t.hour)}${p2(t.minute)}${p2(t.second)}';
  }

  /// 导出为 Markdown，返回文件句柄
  Future<File> exportMarkdown(
      Conversation conv, List<ChatMessage> messages) async {
    final dir = await _exportDir();
    final file = File('${dir.path}${Platform.pathSeparator}'
        '${_sanitize(conv.title)}_${_stamp(DateTime.now())}.md');
    final sb = StringBuffer();
    sb.writeln('# ${conv.title}');
    sb.writeln('- 导出时间：${DateTime.now().toIso8601String()}');
    sb.writeln('- 消息数：${messages.length}');
    sb.writeln('- 对话创建于：${conv.createdAt.toIso8601String()}');
    sb.writeln();
    sb.writeln('---');
    sb.writeln();
    for (final m in messages) {
      final roleLabel = _roleLabel(m.role);
      sb.writeln('## $roleLabel · ${m.createdAt.toIso8601String()}');
      sb.writeln();
      if (m.modelName != null && m.modelName!.trim().isNotEmpty) {
        sb.writeln('> 模型：`${m.modelName}`');
        sb.writeln();
      }
      if (m.content.trim().isNotEmpty) {
        sb.writeln(m.content);
        sb.writeln();
      }
      // 推理过程以折叠块附上，不干扰正文阅读
      final reasoning = _reasoningText(m);
      if (reasoning.isNotEmpty) {
        sb.writeln('<details><summary>思考过程</summary>');
        sb.writeln();
        sb.writeln(reasoning);
        sb.writeln();
        sb.writeln('</details>');
        sb.writeln();
      }
      // 搜索来源
      if (m.searchSources.isNotEmpty) {
        sb.writeln('**搜索来源：**');
        sb.writeln();
        for (final s in m.searchSources) {
          sb.writeln('- [${s.title}](${s.url})');
        }
        sb.writeln();
      }
      sb.writeln('---');
      sb.writeln();
    }
    return _runGuarded('Markdown', () async {
      await file.writeAsString(sb.toString(), encoding: utf8);
      return file;
    });
  }

  /// 导出为 JSON，返回文件句柄
  Future<File> exportJson(
      Conversation conv, List<ChatMessage> messages) async {
    final dir = await _exportDir();
    final file = File('${dir.path}${Platform.pathSeparator}'
        '${_sanitize(conv.title)}_${_stamp(DateTime.now())}.json');
    final payload = <String, dynamic>{
      'exportedAt': DateTime.now().toIso8601String(),
      'conversation': conv.toMap(),
      'messages': messages.map((m) => m.toMap()).toList(),
    };
    return _runGuarded('JSON', () async {
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
        encoding: utf8,
      );
      return file;
    });
  }

  String _roleLabel(MessageRole role) {
    switch (role) {
      case MessageRole.user:
        return '用户';
      case MessageRole.assistant:
        return 'AI';
      case MessageRole.system:
        return '系统';
    }
  }

  /// 把 reasoningSteps 拼成纯文本（导出用）
  String _reasoningText(ChatMessage m) {
    final steps = m.reasoningSteps;
    if (steps.isEmpty) return '';
    final sb = StringBuffer();
    for (final s in steps) {
      // phase 形如 'think' / 'search' / 'plugin'，kind 是更细的动作分类；
      // 导出取 kind 作为小节标题（更贴近用户看到的「思考/搜索/插件」分组）
      if (s.kind.trim().isNotEmpty) sb.writeln('### ${s.kind}');
      if (s.content.trim().isNotEmpty) sb.writeln(s.content);
      if (s.resultSummary != null && s.resultSummary!.trim().isNotEmpty) {
        sb.writeln(s.resultSummary);
      }
      sb.writeln();
    }
    return sb.toString().trim();
  }
}

/// build120：导出重入被拒绝时抛出，UI 据此给出「上一次导出还没结束」而不是静默无反应。
class ExportBusyException implements Exception {
  const ExportBusyException();

  @override
  String toString() => 'ExportBusyException: 另一次导出正在进行中';
}
