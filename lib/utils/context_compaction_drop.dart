/// build145（循环审查第 7 轮 P0-3）：删消息时**该连带删掉哪些压缩段**的判定。
///
/// 旧实现（`deleteMessage` / `deleteMessagesByIds`）按 `conversationId` 把整个会话的
/// 压缩段一次清空。写的时候像是"保守起见全删干净"，实际后果是**能力退化**：
/// 长会话里删一条消息，历史摘要全没 ⇒ 下一次构建上下文要么重新花一次钱去压缩，
/// 要么静默把早就压缩掉的长历史又摊回请求里（token 暴涨 + 模型看到一堆旧话）。
/// 而表里明明存着 `startMessageId` / `endMessageId`（storage_service.dart:915-923），
/// "这个段管到哪条消息"是可以精确回答的 —— 一个语义只该有一处实现，
/// 这里要的是**按区间判定**，不是按会话粗删（设计法则 #62）。
///
/// 判定口径（与调用方约定一致，三条按顺序判）：
/// 1. 段的**端点**（start/end）本身就是被删消息 ⇒ 区间无从表达 ⇒ 删。
///    端点消息被删后，段所覆盖的原文范围已经不确定了，留着比删掉更危险。
/// 2. 段的两个端点在库里都还能查到 `createdAt`，且**有被删消息落在闭区间内** ⇒ 删。
///    这条管的是"删掉的话还写在这条摘要里"——用户删一条消息的意图，
///    不该因为那段话被压缩过就落空（隐私口径，与 B-008 补删 `message_versions` 同族）。
/// 3. 其余情况一律**保留**。包括两个端点查不到时间的段：本 App 的压缩只从 prompt 里
///    过滤旧消息、不删表行（chat_screen_context.dart:1234 / chat_screen_message.dart:818
///    只有 save，没有配套 delete），所以端点行正常情况下必然在；真查不到就是数据已经坏了，
///    **在坏数据上再删一片**等于给"我不知道"压成一个假事实。
///
/// 时间戳按字符串比较是刻意的：`messages.createdAt` 存的是
/// `DateTime.toIso8601String()`（chat_message.dart:556），定宽、同时区、字典序＝时间序。
library;

/// [segments] 每个元素需要 `id` / `startMessageId` / `endMessageId` 三个键；
/// [createdAtOf] 是 `messageId -> createdAt`（调用方一次性查好，含段端点与被删消息）；
/// [deletedIds] 是本次要删除的消息 id。返回应连带删除的段 id 列表。
List<String> segmentsToDropForDeletedMessages({
  required List<Map<String, Object?>> segments,
  required Map<String, String> createdAtOf,
  required Set<String> deletedIds,
}) {
  if (deletedIds.isEmpty) return const [];
  final drop = <String>[];
  for (final seg in segments) {
    final id = seg['id'] as String? ?? '';
    if (id.isEmpty) continue;
    final start = seg['startMessageId'] as String? ?? '';
    final end = seg['endMessageId'] as String? ?? '';
    // ① 端点自身被删
    if (deletedIds.contains(start) || deletedIds.contains(end)) {
      drop.add(id);
      continue;
    }
    // ② 被删消息落在段的闭区间内
    final s = createdAtOf[start];
    final e = createdAtOf[end];
    if (s == null || e == null) continue; // ③ 区间无从判定 ⇒ 保留
    final lo = s.compareTo(e) <= 0 ? s : e;
    final hi = s.compareTo(e) <= 0 ? e : s;
    final inside = deletedIds.any((mid) {
      final t = createdAtOf[mid];
      return t != null && t.compareTo(lo) >= 0 && t.compareTo(hi) <= 0;
    });
    if (inside) drop.add(id);
  }
  return drop;
}
