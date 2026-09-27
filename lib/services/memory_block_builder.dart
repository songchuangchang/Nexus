import '../models/chat_message.dart';
import 'logger_service.dart';
import 'storage_service.dart';

/// v1.7.38 build90（待办⑧）：全局/项目记忆 → 稳定前缀注入块构建器。
///
/// 注入策略（方案文档定稿，⑮前缀稳定性铁律）：
/// - 拼成固定模板块放入 stablePrefix 末尾，内容不变时逐字节稳定可进缓存；
/// - 全局记忆所有对话生效；项目记忆仅 conversation.projectId 非空时注入；
/// - 条数上限由写入端裁剪（N5：全局 ≤50 / 每项目 ≤50，超限时只删 source=auto
///   且未 pinned 的最旧条，manual/pinned 不删故可能保持超限），此处不再截断；
/// - 返回空串 = 无任何记忆，调用方跳过（不注入空块保前缀干净）。
class MemoryBlockBuilder {
  MemoryBlockBuilder._();

  /// 构建记忆注入块文本（空=无记忆）。
  static Future<String> build(String? projectId, {bool isZh = true}) async {
    final (globals, projects) = await buildParts(projectId);
    final sb = StringBuffer();
    if (globals.isNotEmpty) {
      sb.writeln(isZh ? '【用户长期偏好 / 全局记忆】' : '[User long-term memory]');
      for (final m in globals) {
        sb.writeln('- $m');
      }
    }
    if (projects.isNotEmpty) {
      sb.writeln(isZh ? '【当前项目记忆】' : '[Current project memory]');
      for (final m in projects) {
        sb.writeln('- $m');
      }
    }
    return sb.toString().trim();
  }

  /// build103（I11）：分源构建——全局/项目记忆分开返回，供「记忆注入预览」
  /// 分两段展示；注入链路仍走 [build]，拼接结果与原实现逐字节一致（前缀稳定）。
  static Future<(List<String>, List<String>)> buildParts(
      String? projectId) async {
    final storage = StorageService.instance;
    final globals = <String>[];
    final projects = <String>[];
    // build157（第 15 轮扫描 P2）：原来这**一个 try 罩着两次读取**，且 catch 里只有
    // `debugPrint`（release 包不进可导出日志）。两个后果都得堵：
    // ① 全局记忆抛 ⇒ 项目记忆**根本没被尝试**，块里两类都空；
    // ② 只成功一半 ⇒ 发出去的提示词与"用户确实没有那类记忆"长得一模一样，
    //    用户只会觉得「AI 记不住东西」，日志里 0 条线索。
    // 口径与同文件调用方 chat_screen_message.dart 里那条记忆读取 warn 一致。
    try {
      for (final m in await storage.loadGlobalMemories()) {
        globals.add(m.content);
      }
    } catch (e) {
      LoggerService.instance.warn('[Memory] 全局记忆读取失败，本轮不带全局记忆：$e',
          cat: LogCat.chat, tag: 'Memory');
    }
    if (projectId != null && projectId.isNotEmpty) {
      try {
        for (final m in await storage.loadProjectMemories(projectId)) {
          projects.add(m.content);
        }
      } catch (e) {
        LoggerService.instance.warn(
            '[Memory] 项目 $projectId 记忆读取失败，本轮不带项目记忆：$e',
            cat: LogCat.chat,
            tag: 'Memory');
      }
    }
    return (globals, projects);
  }

  /// 便捷方法：非空时直接包成 system 消息
  static Future<ChatMessage?> buildMessage(String conversationId,
      {String? projectId, bool isZh = true}) async {
    final block = await build(projectId, isZh: isZh);
    if (block.isEmpty) return null;
    return ChatMessage.create(
      conversationId: conversationId,
      role: MessageRole.system,
      content: block,
    );
  }
}
