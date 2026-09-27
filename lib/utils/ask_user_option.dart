/// build140（真机反馈⑦）：`<ask_user>` 选项的**带说明**协议与清洗链。
///
/// ## 为什么要动协议
/// 参考形态里每个选项是「标题 + 一行说明」，标题旁还能挂「推荐」徽标。
/// 我们原来的协议只有**一个槽位**（`问题||选项1||选项2`），模型想解释
/// "为什么这个选项好"只能把话塞进 30 字的标题里 ⇒ 用户看不明白选项差别，
/// 反问就成了"三个词让你猜"。
///
/// ## 向后兼容是硬要求
/// 旧写法 `手机版 Android` 必须照旧工作（现网会话、老模型、第三方插件模板都在这么写）。
/// 所以**线格式仍是 List&lt;String&gt;**，只是在单个选项里多开可选段：
///
/// ```
/// 标题[::说明][::推荐]
/// ```
///
/// 用 `::` 而不是 `|`：`|` 已被 `问题||选项` 的分隔语义占用；`::` 在正常中文
/// 选项文案里几乎不出现，且真出现时最坏结果只是"说明被并进标题"，不会错位。
///
/// ## 清洗链必须整条走这里（教训 #166）
/// 标题截 30 字、说明截 60 字、按**标题**去重、最多 8 条——这些规则只要有一处
/// 绕开本文件，就会出现"面板看到了未清洗的说明"或"重复标题各带不同说明"。
/// 因此调用方一律用 [cleanWires]，不要各自 `split('::')`。
class AskUserOption {
  const AskUserOption({
    required this.title,
    this.desc = '',
    this.recommended = false,
  });

  /// 段分隔符（选项内部）
  static const String sep = '::';

  /// 「推荐」标记的可选写法。模型偶尔写英文，这里一次兜住，
  /// 免得同一个语义在解析侧再长出一个分支。
  static const Set<String> _recTokens = {
    '推荐',
    '建议',
    '首选',
    'rec',
    'recommend',
    'recommended',
    'best',
  };

  /// 标题最多 30 字、说明最多 60 字、最多 8 条。
  /// 标题上限沿用 `AskUserPlugin.kMaxOptionChars` 的值（那一步是**上限的唯一来源**）。
  static const int maxTitleChars = 30;
  static const int maxDescChars = 60;
  static const int maxOptions = 8;

  final String title;
  final String desc;
  final bool recommended;

  /// 解析单个选项串。没有 `::` 时整串就是标题（旧写法逐字等价）。
  static AskUserOption parse(String raw) {
    final parts = raw.split(sep);
    var title = parts.first.trim();
    final descs = <String>[];
    var recommended = false;
    for (final extra in parts.skip(1)) {
      final seg = extra.trim();
      if (seg.isEmpty) continue;
      if (_recTokens.contains(seg.toLowerCase())) {
        recommended = true;
        continue;
      }
      descs.add(seg);
    }
    // 标题为空却带说明 ⇒ 模型把内容写歪了（例如整句塞进说明位）。
    // 这时拿说明当标题，比丢掉一个可点选项好（与 build139「只剩 1 条不丢空」同思路）。
    if (title.isEmpty && descs.isNotEmpty) {
      title = descs.removeAt(0);
    }
    return AskUserOption(
      title: _clip(title, maxTitleChars),
      desc: _clip(descs.join(' · '), maxDescChars),
      recommended: recommended,
    );
  }

  /// 归一化回线格式：没有说明与推荐标记时**不加空段**，
  /// 这样旧数据清洗一遍仍是旧写法（diff 干净，日志里也读得懂）。
  String toWire() {
    final sb = StringBuffer(title);
    if (desc.isNotEmpty) sb..write(sep)..write(desc);
    if (recommended) sb..write(sep)..write('推荐');
    return sb.toString();
  }

  /// 整条清洗：解析 → 逐字段截断 → 按标题去重（保序）→ 截 8 条 → 回线格式。
  /// 入参可以是旧写法，也可以已经带 `::` 段（幂等）。
  static List<String> cleanWires(List<String> raws) {
    final out = <String, AskUserOption>{};
    for (final raw in raws) {
      final opt = parse(raw);
      if (opt.title.isEmpty) continue;
      // 同名标题后写的覆盖前写的：模型偶尔先给个半成品再补一句，
      // 保留**更完整**的那条比留第一条有用。
      final key = opt.title.toLowerCase();
      final prev = out[key];
      if (prev == null || opt.desc.length > prev.desc.length || opt.recommended) {
        out[key] = opt;
      }
      if (out.length >= maxOptions) break;
    }
    return out.values.map((e) => e.toWire()).toList();
  }

  /// 只要标题（回灌给模型的上下文、思考面板那行摘要用这个，别把说明文字塞进去）。
  static List<String> titles(List<String> wires) =>
      wires.map((e) => parse(e).title).toList();

  static String _clip(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);
}
