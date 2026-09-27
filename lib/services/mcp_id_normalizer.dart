/// MCP 调用目标（plugin_id + tool）的**唯一归一入口**。
///
/// ## 为什么需要它（结构性根因，2026-09-15 真机日志实锤）
///
/// 目录层给模型看的条目 id 是**三段复合串** `mcp:<连接器id>:<工具名>`
/// （如 `mcp:amap:maps_schema_take_taxi`），但下游每个消费点要的是**拆开的
/// 两个字段**（`plugin_id="amap"` + `tool="maps_schema_take_taxi"`）。模型照抄
/// 它看到的东西，于是产生多种「id 方言」：
///
/// | 模型实际传的 | 真机日志出处 | 旧行为 |
/// |---|---|---|
/// | `amap` + `maps_text_search` | 正确写法 | ✅ 通过 |
/// | `mcp:amap` + `tool` | build107 样本 | 旧容错能修 |
/// | `mcp:mcp:amap` | W2a 样本（Detail not found） | 旧容错能修 |
/// | `mcp:amap:maps_schema_take_taxi` | **2026-09-15 22:26 样本** | ❌ 修不了 → 「未找到插件」→ 模型放弃 |
/// | `log_query`（内置短名） | U6 样本 | 走内置路由 |
///
/// 旧实现有三处各自为政的 id 处理（`PluginRegistry.dispatch` 的
/// `replaceFirst('mcp:')`、`plugin_prompt_catalog.normalizeMcpPluginId`、
/// chat_screen 的 mcp_detail 分支），**每修一种方言就漏下一种**——这正是
/// 「修了 N 多次还在犯」的机制。本文件把解析收敛成**一个纯函数**，三处共用。
///
/// 纯 dart 实现（无 Flutter 依赖），可被 `dart run` 探针直接验证。
library;

/// 归一结果：拆好的调用目标 + 是否发生过纠正（供日志/教学回灌用）。
class McpTarget {
  final String pluginId;
  final String tool;

  /// 非空表示发生了纠正，内容形如 `mcp:amap:maps_x → amap / maps_x`
  final String fixNote;

  const McpTarget(this.pluginId, this.tool, {this.fixNote = ''});

  bool get isEmpty => pluginId.isEmpty;
  bool get wasFixed => fixNote.isNotEmpty;

  @override
  String toString() => 'McpTarget($pluginId, $tool)${wasFixed ? ' [$fixNote]' : ''}';
}

/// 把模型给的 plugin_id / tool 归一成注册表能认的 `(pluginId, tool)`。
///
/// [isKnownId] 由调用方注入（注册表 / 已启用插件集合），用于判定「某段是不是
/// 真实连接器 id」——只有这样才能安全地把三段式的后段当工具名拆出来。
McpTarget normalizeMcpTarget(
  String rawPluginId,
  String rawTool, {
  required bool Function(String id) isKnownId,
}) {
  var id = rawPluginId.trim();
  final tool = rawTool.trim();
  if (id.isEmpty) return McpTarget('', tool);

  // ① 剥掉重复的 `mcp:` 前缀（`mcp:mcp:amap` → `amap`）
  final beforePrefix = id;
  while (id.startsWith('mcp:')) {
    id = id.substring(4);
  }
  var prefixStripped = id != beforePrefix;

  // ② 剥完就是已知 id → 直接可用
  if (isKnownId(id)) {
    return McpTarget(
      id,
      tool,
      fixNote: prefixStripped ? '$beforePrefix → $id' : '',
    );
  }

  // ③ 三段式/多段式：`amap:maps_schema_take_taxi` → 取首段试匹配
  //    （目录 id 是 `mcp:<连接器id>:<工具名>`，模型整串照抄时落在这一支）
  if (id.contains(':')) {
    final idx = id.indexOf(':');
    final head = id.substring(0, idx);
    final tail = id.substring(idx + 1);
    if (isKnownId(head)) {
      // 工具名优先用模型显式给的；没给或给得不一致时用 id 里拆出来的
      final resolvedTool = tool.isNotEmpty ? tool : tail;
      return McpTarget(
        head,
        resolvedTool,
        fixNote: '$beforePrefix → $head / $resolvedTool',
      );
    }
    // 首段不认识：可能是「工具名里带冒号」的罕见情况，整串再试一次
    if (isKnownId(id)) {
      return McpTarget(id, tool,
          fixNote: prefixStripped ? '$beforePrefix → $id' : '');
    }
  }

  // ④ 认不出来：原样返回（由调用方报「未找到插件」并教学）
  return McpTarget(id, tool, fixNote: prefixStripped ? '$beforePrefix → $id' : '');
}
