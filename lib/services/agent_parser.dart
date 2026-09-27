// v1.7.34：子代理编排标签解析器（纯函数，可单测）
//
// 从 AgentOrchestrator 提取 4 个解析逻辑，保证：
//   - 不依赖任何服务实例
//   - 输入输出均为纯 String/List
//   - 可被 test/agent_orchestrator_test.dart 直接测试
//
// 编排器内部仍走这 4 个函数（不再重复实现）。

/// 解析 <route target="..." reason="..."/>
///
/// 返回 (target, reason)。规则：
///   - 无 <route> 标签 → ('self', 'no <route> tag')
///   - target 不在 {self, search, synthesis, plugin} → 兜底为 'self'
///   - reason 缺失 → 空字符串
///   - 大小写不敏感，target 强制小写
({String target, String reason}) parseRouteTag(String raw) {
  // 分支 1：target 在前，reason 在后 —— 用 reason 字面段避免 [^>]*/?> 吃掉 reason
  // 分支 2：reason 在前，target 在后（用户可能反序写，兼容）
  // 分支 3：无 reason 的极简写法
  // ⚠️ 属性段之后一律放宽为 [^>]*/?>：模型常把未转义的 " 写进 reason
  // （实测 reason="用户仅发来"测试反问"这一…"）——旧写法要求紧跟 \s*/?>，
  // 三个分支会同时失配 ⇒ 静默回退 self，把 search/synthesis/plugin 全吞掉。
  final re = RegExp(
      r'<route\s+[^>]*?target\s*=\s*"([^"]*)"\s+reason\s*=\s*"([^"]*)"[^>]*/?>|'
      r'<route\s+[^>]*?reason\s*=\s*"([^"]*)"\s+target\s*=\s*"([^"]*)"[^>]*/?>|'
      r'<route\s+[^>]*?target\s*=\s*"([^"]*)"[^>]*/?>',
      caseSensitive: false);
  final m = re.firstMatch(raw);
  if (m == null) {
    return (target: 'self', reason: 'no <route> tag');
  }
  // 分支 1: g1=target g2=reason
  // 分支 2: g3=reason g4=target
  // 分支 3: g5=target（无 reason）
  final target =
      ((m.group(1) ?? m.group(4) ?? m.group(5)) ?? 'self').toLowerCase().trim();
  const validTargets = {'self', 'search', 'synthesis', 'plugin'};
  final safeTarget = validTargets.contains(target) ? target : 'self';
  final reason = (m.group(2) ?? m.group(3) ?? '').trim();
  return (target: safeTarget, reason: reason);
}

/// 提取 <answer>...</answer> 内的内容；无标签则原样返回（去首尾空白）
String stripAnswerTag(String raw) {
  final re = RegExp(r'<answer>([\s\S]*?)</answer>', caseSensitive: false);
  final m = re.firstMatch(raw);
  return m != null ? m.group(1)!.trim() : raw.trim();
}

/// 提取 <queries>...</queries> 内的 <query>...</query> 列表
///
/// 规则：
///   - 无 <queries> 外壳 → 直接从全文扫 <query>
///   - 单个 <query> 内容为空 → 丢弃
///   - 最多保留 5 条（协议上限）
List<String> extractQueries(String raw) {
  final outerRe =
      RegExp(r'<queries>([\s\S]*?)</queries>', caseSensitive: false);
  final outer = outerRe.firstMatch(raw);
  final body = outer?.group(1) ?? raw;
  final innerRe = RegExp(r'<query>([\s\S]*?)</query>', caseSensitive: false);
  final out = <String>[];
  for (final m in innerRe.allMatches(body)) {
    final q = m.group(1)!.trim();
    if (q.isNotEmpty) out.add(q);
  }
  return out.take(5).toList();
}

/// 提取 <synthesis>...</synthesis> 内的内容；无标签则原样返回
String extractSynthesis(String raw) {
  final re = RegExp(r'<synthesis>([\s\S]*?)</synthesis>', caseSensitive: false);
  final m = re.firstMatch(raw);
  return m != null ? m.group(1)!.trim() : raw.trim();
}

/// 判定 synthesis 输出是否含三节结构（兼容中英文标题）
///
/// 中文命中条件（避免 "不确定性" 误命中 "不确定"）：
///   结论   → body 含 "结论"
///   证据   → body 含 "证据"
///   分歧   → body 含 "分歧" 或 "不确定性"
({bool conclusion, bool evidence, bool disagree}) checkSynthesisSections(
    String body,
    {required bool isZh}) {
  if (isZh) {
    return (
      conclusion: body.contains('结论'),
      evidence: body.contains('证据'),
      disagree: body.contains('分歧') || body.contains('不确定性'),
    );
  }
  return (
    conclusion: RegExp(r'Conclusion', caseSensitive: false).hasMatch(body),
    evidence: RegExp(r'Evidence', caseSensitive: false).hasMatch(body),
    disagree:
        RegExp(r'Disagree|Uncertain', caseSensitive: false).hasMatch(body),
  );
}
