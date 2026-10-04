import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/plugin_hint_config.dart';
import '../plugins/plugin_interface.dart';
import '../utils/prompt_structure_guard.dart';
import 'builtin_prompt_catalog.dart';
import 'mcp_id_normalizer.dart';

/// v1.7.17：插件协议按需加载——接口契约层 + 目录构建器（纯函数，无副作用）。
///
/// 供 api_service（构建常驻 system 目录层/格式层）与 chat_screen（详情按需注入）共用。
///
/// 三层模型：
///   - 目录层：名字 + 摘要（常驻）
///   - 格式层：格式骨架（常驻，宿主协议语法；集中常量表 [_kFormatByTrigger]，
///     键必须覆盖全部内置 triggerType——build147 起由
///     `test/build147_resident_format_layer_test.dart` 扫源码钉住，不写死名单）
///   - 详情层：完整 promptProtocol / MCP description+schema（按需注入）
///
/// [collectCatalog] 只产出目录/格式/详情三层的结构化数据；
/// [buildDirectoryAndFormatLayer] 把前两层拼成常驻 system 文本；
/// [resolvePluginDetail]/[resolveMcpDetail]/[resolveSkillDetail] 按需返回详情文本。

/// 一键回退开关：true=按需加载（新行为）；false=回退旧全量注入。
const bool kLazyPluginProtocol = true;

/// 目录层每条摘要的最大字符数（预算截断，主要作用于 MCP 工具 description）。
const int kSummaryMaxLen = 80;

/// 目录层条目，同时承载目录/格式/详情三层所需文本。
class CatalogEntry {
  final String id;
  final String name;
  final String summary;
  final String notWhen;
  final String format;
  final String detail;

  /// build116：MCP 条目的**可直接照抄的调用写法**（如 `plugin_id="amap"
  /// tool="maps_text_search"`）。目录 id 是 `mcp:<连接器id>:<工具名>` 三段式，
  /// 模型整串照抄当 plugin_id 是「未找到插件」的头号来源（真机日志实锤）——
  /// 直接给出拆好的字段，从源头消灭这种误解。
  final String callHint;

  const CatalogEntry({
    required this.id,
    required this.name,
    required this.summary,
    this.notWhen = '',
    required this.format,
    required this.detail,
    this.callHint = '',
  });
}

/// 格式层骨架常量表（宿主协议语法）。
///
/// **键集必须覆盖全部内置 triggerType**：漏一行＝那个标签对模型只剩目录摘要、
/// 没有任何语法可照抄（同型事故：build104/106/107/116/131/136/138，本轮 147 补最后 13 个）。
/// 现在由 [residentFormatFor] 单点取值 + build147 结构锁（扫源码枚举，不写死名单）兜住。
const Map<String, String> _kFormatByTrigger = {
  // build122：生成类标签的格式骨架——缺了它模型看不到语法（#56 检查单第 ④ 项，
  // build104/build106 两次因漏登记导致模型「想调但不知道怎么写」）。
  //
  // build131：骨架**必须**带上参考图属性 `image`。图生图/图生视频的完整说明只写在
  // 「按需详情层」（模型得先发 <plugin_detail> 才看得到），而常驻的目录摘要 + 格式骨架
  // 此前只字未提参考图 —— 真机实锤：模型答「我这边没有『上传一张图再按提示改』的接口，
  // 没法拿现有图片当输入做编辑/变换」，而该能力 build129 就已实现。**能力只要没进
  // 常驻层，对模型就等于不存在**（同型教训：build104/106/107 的格式层漏登记）。
  'image_gen':
      '<image_gen prompt="画面描述" image="1|文件名|last 仅改图时写" size="1024x1024" n="1" quality="medium" />',
  'video_gen':
      '<video_gen prompt="画面与运镜描述" image="1|文件名|last 仅图生视频时写" seconds="5" size="1280x720" mode="std" />',
  'search': '<search query="关键词" depth="basic|advanced" />',
  'download':
      '<download intent="true|false" canonical="应用名" keywords="k1,k2" domains="d1,d2" platform="android|pc" url="直链" type="app|pdf|mp4|jpg|doc|any" query="文件名" />',
  'ask_user': '<ask_user>问题||选项1||选项2</ask_user>',
  'self_check': '<self_check continue="true|false" reason="原因" />',
  'answer': '<answer>最终回复（支持 Markdown）</answer>',
  'mcp_call': '<mcp_call plugin_id="..." tool="...">{JSON 参数对象}</mcp_call>',
  'skill_call': '<skill_call name="skill.xxx">{可选 JSON}</skill_call>',
  'install_skill':
      '<install_skill url="SKILL.md或zip直链" query="市场搜索关键词" name="可选名称" />',
  'get_location': '<get_location />',
  'ip_locate': '<ip_locate />',
  // build107（U6 日志实锤）：build104 起漏登记，模型看不到标签语法只能摸 mcp_call 兜圈
  'log_query':
      '<log_query category="ERROR|API|REACT|APP|DB|DOWNLOAD" keyword="可选关键字" tail="40" />',
  // build108（Q1）：余额查询（refresh 属性可选）
  'query_quota': '<query_quota refresh="true|false 可选，默认走缓存" />',
  // build136（G66/G67）：写代码两件套必须进常驻格式层——否则模型「不知道
  // 怎么写」（同型教训第 5 次：能力没进常驻层＝对模型不存在）。
  'ws_patch':
      '<ws_patch path="相对路径" find="原文片段（含上下文，须唯一）" replace="新片段" all="false" />',
  'ws_grep':
      '<ws_grep pattern="正则" glob="*.dart 可选" ignore_case="false 可选" />',
  // build138（G61-G64）：生成真文件必须进常驻格式层（同型教训第 6 次）——
  // 只写在按需详情层的话，模型不会主动索取，就永远不知道「能生成真 Excel」，
  // 继续输出 HTML 伪装 .xls 或干脆回答「我没有导出 Excel 的能力」。
  'ws_make_file':
      '<ws_make_file path="exports/名称.xlsx" kind="xlsx|docx|pdf|csv|md|txt" content="文本载荷（表格用 CSV/TSV，文档用 markdown 正文；禁止 base64）" title="可选标题" overwrite="false" />',
  // build147（又一次同型）：本表此前只有 17 键，而内置插件的 triggerType 有 29 种，
  // 漏登记的 13 个标签模型只在目录里看到一行摘要、看不到任何语法 ⇒ 只能猜
  // （suggest 最贵：读不到「必须紧跟 </answer>」，宿主每轮多付一次 N14 兜底调用）。
  // 语法一律**以解析器为准**（react_parser.parseReActOutput 的各分支正则 +
  // agent_kernel 的 `key="值"` 属性抓取），与提示词文本不一致处写在行注释里。
  // 这些行**每轮常驻**，所以只写语法、不写用法（用法属按需详情层）。
  // 解析器另有自闭合容错 `<suggest items="a||b" />`；标准写法是配对，骨架给配对。
  'suggest': '<suggest>问题1||问题2||问题3（须紧跟 </answer> 之后）</suggest>',
  // 解析器把 type 存成 cardType，落到 <answer> 外只会被记一条「位置错误」提醒
  'card':
      '<card type="options|order|pay" title="卡片标题">{"单行合法JSON"}</card>（放在 answer 内）',
  // 解析器兼容裸开/配对（正文忽略），骨架按自闭合标准写法；list/clear 可省 items
  'todo':
      '<todo action="add|done|list|clear" items="事项1||事项2（list/clear 可省）" />',
  // 提示词里的反例写法（`<memory_write">entries=[...]`）解析器有容错分支，
  // 骨架只给标准属性写法——key/value 任一为空宿主直接判 invalid
  'memory_write':
      '<memory_write scope="global|project" key="分类名（≤10字）" value="一句话事实（≤50字）" />',
  'memory_delete': '<memory_delete scope="global|project" key="分类名" />',
  // 解析器这条只读 refresh/category/keyword/tail 四个属性，写别的会被静默丢弃
  // ⇒ 骨架给无属性形态（插件本身也只是「已引用指南」的可见化声明）
  'connector_guide': '<connector_guide />',
  // 解析器正则要求标签名后有空白 + 属性段 ⇒ 零属性的 <install_mcp /> 抓不到，
  // 所以骨架至少写 endpoint（endpoint 与 query 至少一个，直连优先）
  'install_mcp':
      '<install_mcp endpoint="https直连端点" query="市场关键词" name="可选名" />',
  'ws_list': '<ws_list />',
  'ws_read': '<ws_read path="相对路径" />',
  // 解析器另接受配对写法 <ws_write path="..">正文</ws_write>（正文→content）；
  // 属性值走 _wsAttrValue 实体解码（&#10; = 换行），写真实换行同样有效
  'ws_write':
      '<ws_write path="相对路径" content="文本正文（≤8000字）" overwrite="false 覆盖同名才写true" />',
  'ws_delete': '<ws_delete path="相对路径" />',
  'ws_export': '<ws_export path="相对路径" mode="share|open" />',
  'ws_download': '<ws_download url="https://…" filename="可选文件名" />',
  // build180（刀二·内置浏览器四动作）：语法以 react_parser 的 webMatch 分支为准。
  // 缺这四行的后果与历史同型一致——模型只看得到目录摘要、看不到语法，
  // 于是「有工具却不会写」（test/build147_resident_format_layer_test.dart 柱子①）。
  'web_navigate': '<web_navigate url="https://完整地址" />',
  'web_read': '<web_read />',
  'web_act': '<web_act idx="7" action="click|input|clear" value="仅 input/clear 要写" />',
  'web_back': '<web_back />',
};

/// build147：常驻格式层**唯一取值入口**（口径写在这里，测试 `build147_*` 钉住）。
///
/// 取代原来散在 [collectCatalog] 的 `_kFormatByTrigger[p.triggerType] ?? ''`：
/// 那种写法把「漏登记」变成静默空串，模型只是看不到语法，谁也不知道。
///
/// 缺项口径（**热路径，每轮都走，不许抛**）：
///   1. 本地骨架命中 → 远程覆盖优先（[BuiltinPromptCatalog.resolveFormat]，原有语义不变）；
///   2. 本地没有、远程有 → 用远程；
///   3. 两边都没有 → **照旧返回空串**，但记进 [missingResidentFormatTriggers]
///      并 debugPrint 一行（同一 trigger 进程内只打一次）。生产绝不 throw。
String residentFormatFor(String triggerType) {
  final local = _kFormatByTrigger[triggerType];
  if (local != null && local.isNotEmpty) {
    return BuiltinPromptCatalog.instance.resolveFormat(triggerType, local);
  }
  final remote = BuiltinPromptCatalog.instance.resolveFormat(triggerType, '');
  if (remote.isNotEmpty) return remote;
  if (missingResidentFormatTriggers.add(triggerType)) {
    debugPrint('[build147] 常驻格式层缺 triggerType="$triggerType" 的骨架：'
        '模型只会看到目录摘要、看不到语法。请在 _kFormatByTrigger 补一行'
        '（语法以 react_parser 的解析形状为准）。');
  }
  return '';
}

/// 已被读取但**没有**常驻骨架的 triggerType（去重，供测试与日志核对）。
/// 正常应为空集：非空即说明又出现了「插件加了、格式层漏登记」。
final Set<String> missingResidentFormatTriggers = <String>{};

// ---- build153：结构锁族（防插件供给文本撑坏拼进 prompt 的块）----
//
// 四条锁，全部收进 `utils/prompt_structure_guard.dart` 的**同一条归一化通道**
// （先去噪归一：小写 / 全角→半角 / 剥零宽与软连字符与 markdown 反斜杠 /
// 判分隔符与包裹标签前再压实空白；换行按字面判），不再各自加 `contains`：
//   L1 换行/块边界锁 —— 单行目录字段含 \n：在 \n\n 缓存块边界处伪造新块；
//   L2 分隔符锁     —— `===`（宿主 section 头柱）与整行 `---`/`***`/`___`
//                       （水平分隔行）：抓全角＝、拆段夹空白、零宽变体；
//   L3 包裹标签锁   —— `<toolresult>` 开/闭：详情注入走 <toolresult> 包裹，
//                       内容再出现该标签＝逃出宿主包裹边界（大小写/拆段/全角）；
//   L4 标题层级锁   —— 仅单行目录字段行首 `#{1,6}+空格`（详情里 `##` 是合法
//                       markdown，不锁）。
//
// 口径（与文件既有处理方式一致）：**fail-closed、降级为纯文本、生产绝不 throw**
// （同 residentFormatFor 缺项→空串的「静默降级 + 记名核对」两件套）：
// 命中即剥结构字符/丢分隔行/标签替裸词，清洗后复检仍命中则整段降纯文本；
// 字段名记进 [promptStructureGuardHits] 并 debugPrint 一次，供测试与真机日志核对。

/// 被结构锁命中并降级过的字段（`条目id:字段名`，去重）。正常应为空集。
final Set<String> promptStructureGuardHits = <String>{};

/// 结构锁统一入口。[field] 形如 `mcp:amap:x#summary`，仅用于命中登记。
String guardCatalogField(String field, String value, {bool singleLine = true}) {
  final v = guardPromptStructure(value, singleLine: singleLine);
  if (v.breached && promptStructureGuardHits.add(field)) {
    debugPrint('[build153] 结构锁命中并降级为纯文本：$field（${v.hits.join(',')}）'
        '——插件供给文本含伪造的 prompt 结构（分隔符/包裹标签/标题层级），'
        '归一化后仍命中，已剥除。');
  }
  return v.text;
}

/// 收集目录层条目。
///
/// - 内置 5 插件（source==system）始终收集。
/// - MCP/Skill 按 [hint.mode] 过滤：
///   off 不收集；manual 只收集 [PluginHintConfig.selectedIds] 命中的；
///   auto 收集全部传入的 enabled 插件。
List<CatalogEntry> collectCatalog(
    Iterable<ReActPlugin> enabledPlugins, PluginHintConfig hint) {
  final ordered = enabledPlugins.toList();
  final entries = <CatalogEntry>[];

  // 1. 内置插件（source==system）
  for (final p in ordered) {
    if (p.source != PluginSource.system) continue;
    final m = p.metadata;
    if (m.promptProtocol.isEmpty) continue;
    entries.add(CatalogEntry(
      id: m.id,
      name: m.name,
      summary: _catalogSummary(m),
      notWhen: m.extra['notWhen']?.toString() ?? '',
      format: residentFormatFor(p.triggerType),
      detail: m.promptProtocol,
    ));
  }

  if (hint.mode == PluginHintMode.off) return entries;

  final manualSelected = hint.selectedIds.toSet();

  // 2. MCP 插件（每个工具一个条目）
  for (final p in ordered) {
    final m = p.metadata;
    if (!m.kind.isRemote) continue;
    if (hint.mode == PluginHintMode.manual && !manualSelected.contains(m.id)) {
      continue;
    }
    final tools = m.extra['tools'];
    if (tools is! List) continue;
    for (final raw in tools.whereType<Map>()) {
      final tool = Map<String, dynamic>.from(raw);
      final toolName = tool['name']?.toString() ?? '';
      if (toolName.isEmpty) continue;
      final description = (tool['description']?.toString() ?? '').trim();
      final schema = tool['inputSchema'] ?? tool['input_schema'];
      final schemaText = schema is Map ? jsonEncode(schema) : '{}';
      entries.add(CatalogEntry(
        id: 'mcp:${m.id}:$toolName',
        name: toolName,
        summary: _truncate(
            description.isEmpty ? '无描述' : description, kSummaryMaxLen),
        notWhen: tool['notWhen']?.toString() ?? '',
        format: residentFormatFor('mcp_call'),
        detail: _buildMcpDetail(m.id, toolName, description, schemaText),
        // build116：拆好的调用字段，模型照抄即可（消灭三段式 id 误用）
        callHint: 'plugin_id="${m.id}" tool="$toolName"',
      ));
    }
  }

  // 3. Skill / 声明式插件（source!=system）
  for (final p in ordered) {
    final m = p.metadata;
    if (!m.kind.isDeclarative) continue;
    if (p.source == PluginSource.system) continue;
    if (hint.mode == PluginHintMode.manual && !manualSelected.contains(m.id)) {
      continue;
    }
    entries.add(CatalogEntry(
      id: m.id,
      name: m.name,
      summary: _skillSummary(m, p.triggerType),
      notWhen: m.extra['notWhen']?.toString() ?? '',
      format: residentFormatFor('skill_call'),
      // build153：skill 的 promptProtocol 来自插件供给（市场/用户安装），
      // 详情多行口径过结构锁（伪造 === 头/逃出 <toolresult> 的行会被降级）
      detail: guardCatalogField('${m.id}#detail', m.promptProtocol,
          singleLine: false),
    ));
  }

  return entries;
}

/// 生成「目录层（名字+摘要）+ 格式层（格式骨架）」的常驻 system 文本。
String buildDirectoryAndFormatLayer(List<CatalogEntry> entries) {
  final sb = StringBuffer();
  sb.writeln('=== 可用插件目录 ===');
  if (entries.isEmpty) {
    sb.writeln('（无）');
  } else {
    for (final e in entries) {
      // build153：单行字段过结构锁（L1-L4）后才拼进目录行——越界的
      // 换行/`===`/`#` 标题/`<toolresult>` 变体一律先降级为纯文本
      final name = guardCatalogField('${e.id}#name', e.name);
      final summary = guardCatalogField('${e.id}#summary', e.summary);
      final notWhen = guardCatalogField('${e.id}#notWhen', e.notWhen);
      final callHint = guardCatalogField('${e.id}#callHint', e.callHint);
      sb.writeln('- [${e.id}] $name: $summary');
      // build116：MCP 条目直接给出拆好的调用字段（目录 id 是三段式，
      // 整串当 plugin_id 是「未找到插件」的头号来源——真机日志实锤）
      if (e.callHint.isNotEmpty) {
        sb.writeln('  调用时用：$callHint');
      }
      if (e.notWhen.isNotEmpty) sb.writeln('  不适用: $notWhen');
    }
  }
  // v1.7.36：明确告诉 AI 当前 MCP/Skill 的真实数量，杜绝臆造工具名
  final mcpCount = entries.where((e) => e.id.startsWith('mcp:')).length;
  final skillCount = entries
      .where(
          (e) => !e.id.startsWith('mcp:') && !e.id.startsWith('nexus.builtin.'))
      .length;
  sb.writeln('当前 MCP 工具数：$mcpCount；当前 Skill 数：$skillCount。');
  if (mcpCount > 0) {
    sb.writeln('MCP 调用写法：方括号里是目录条目 id（三段式 `mcp:<连接器id>:<工具名>`，'
        '**不要整串当 plugin_id**）；按每条下面「调用时用」给的 plugin_id 与 tool 填：'
        '<mcp_call plugin_id="连接器id" tool="工具名">{JSON 参数}</mcp_call>');
  }
  sb.writeln();
  sb.writeln('=== 调用格式骨架 ===');
  final seen = <String>{};
  var wrote = 0;
  for (final e in entries) {
    if (e.format.isEmpty || seen.contains(e.format)) continue;
    seen.add(e.format);
    sb.writeln(e.format);
    wrote++;
  }
  if (wrote == 0) sb.writeln('（无）');
  sb.writeln();
  // v1.7.36：防幻觉铁律——AI 曾多次臆造 mcp_list / skill_store 等不存在的工具
  sb.writeln('=== 工具真实性铁律 ===');
  sb.writeln('- 你只能使用上面目录中明确列出的插件、MCP 工具和 Skill。');
  sb.writeln(
      '- 目录中不存在的名字（如 mcp_list、skill_store、skill_search 等）都不是真实工具，禁止臆造、禁止调用、禁止向用户声称它们存在。');
  sb.writeln('- 用户问你"装了哪些 MCP/Skill"时，只能依据上面目录如实回答；目录里没有就说没有，不要猜测。');
  // build94（滴滴空转教训）：mcp_call 同一工具连续失败即被宿主熔断判定不可用，
  // 收到「宿主熔断」提示后禁止再调同一工具，直接基于已有信息如实答复用户。
  sb.writeln(
      '- 同一个 MCP 工具调用失败一次可换参数再试一次；仍失败（或收到「宿主熔断」提示）就判定它不可用，'
      '禁止第三次调用，直接向用户说明该能力当前不可用并给出替代建议。');
  // v1.7.38（待办①/拍板⑥）：AI 代装 Skill 已内置——引导用 install_skill 标签直装。
  // 仅在 install_skill 插件实际启用（出现在目录层）时才引导，避免禁用后 prompt 撒谎。
  final hasInstallSkill =
      entries.any((e) => e.id == 'nexus.builtin.install_skill');
  if (hasInstallSkill) {
    sb.writeln(
        '- 用户要求"下载/安装 Skill 或插件"时：你有 <install_skill> 代装工具，优先用 <install_skill url="直链" /> 或 <install_skill query="市场关键词" /> 直接安装；安装会自动经过安全扫描，不通过会被拒绝并以 <toolresult> 告知原因。');
  } else {
    sb.writeln(
        '- 用户要求"下载/安装 Skill 或插件"时：你没有安装工具，做不到代装；请告诉用户到 App 的「插件管理 → 插件市场」里手动安装，不要只回答"做不到"。');
  }
  return sb.toString();
}

/// 按 name 匹配（先 metadata.id 精确，退化 triggerType）返回完整 promptProtocol。
/// 找不到返回空串。
String resolvePluginDetail(String name, Iterable<ReActPlugin> enabledPlugins) {
  if (name.isEmpty) return '';
  final ordered = enabledPlugins.toList();
  for (final p in ordered) {
    if (p.metadata.id == name && p.metadata.promptProtocol.isNotEmpty) {
      return p.metadata.promptProtocol;
    }
  }
  for (final p in ordered) {
    if (p.triggerType == name && p.metadata.promptProtocol.isNotEmpty) {
      return p.metadata.promptProtocol;
    }
  }
  return '';
}

/// 返回该 MCP 工具的 description + inputSchema 文本；找不到返回空串。
/// W2a（补充单02）：与 mcp_call 的 id auto-fix 同源——模型常把目录前缀
/// 兼容入口：仅剥 `mcp:` 前缀（保留旧签名，内部委托给统一归一器）。
/// **新代码请直接用 [normalizeMcpTarget]**（它还能拆三段式 `mcp:id:tool`）。
String normalizeMcpPluginId(String raw) {
  var t = raw.trim();
  while (t.startsWith('mcp:')) {
    t = t.substring(4);
  }
  return t;
}

String resolveMcpDetail(
    String pluginId, String tool, Iterable<ReActPlugin> enabledPlugins) {
  if (pluginId.isEmpty || tool.isEmpty) return '';
  final ordered = enabledPlugins.toList();
  // build116（结构性修复）：与 PluginRegistry.dispatch 共用同一归一入口——
  // 三段式 `mcp:amap:maps_x` 等全部方言在这里被拆成 (连接器id, 工具名)，
  // 不再出现「mcp_call 能修、mcp_detail 修不了」的两条通道漂移。
  final target = normalizeMcpTarget(
    pluginId,
    tool,
    isKnownId: (id) => ordered.any((p) =>
        p.metadata.kind.isRemote && p.metadata.id == id),
  );
  for (final p in ordered) {
    if (!p.metadata.kind.isRemote) continue;
    if (p.metadata.id != target.pluginId) continue;
    final tools = p.metadata.extra['tools'];
    if (tools is! List) return '';
    for (final raw in tools.whereType<Map>()) {
      final t = Map<String, dynamic>.from(raw);
      if (t['name']?.toString() != target.tool) continue;
      final description = (t['description']?.toString() ?? '').trim();
      final schema = t['inputSchema'] ?? t['input_schema'];
      final schemaText = schema is Map ? jsonEncode(schema) : '{}';
      return _buildMcpDetail(
          target.pluginId, target.tool, description, schemaText);
    }
    return '';
  }
  return '';
}

/// 返回该 Skill 的完整 promptProtocol；找不到返回空串。
String resolveSkillDetail(String name, Iterable<ReActPlugin> enabledPlugins) {
  if (name.isEmpty) return '';
  for (final p in enabledPlugins) {
    final m = p.metadata;
    if (!m.kind.isDeclarative) continue;
    if (p.source == PluginSource.system) continue;
    if (m.id == name || m.name == name) {
      // build153：与 collectCatalog 详情层同口径（幂等，两处都过锁不漏面）
      return guardCatalogField('${m.id}#detail', m.promptProtocol,
          singleLine: false);
    }
  }
  return '';
}

// ---- 私有 helper ----

String _catalogSummary(PluginMetadata m) {
  final override = m.extra['catalogSummary']?.toString() ?? '';
  if (override.isNotEmpty) return _truncate(override, kSummaryMaxLen);
  return _truncate(m.description, kSummaryMaxLen);
}

String _skillSummary(PluginMetadata m, String triggerType) {
  final extraSummary = m.extra['skillSummary']?.toString() ?? '';
  if (extraSummary.isNotEmpty) {
    return _truncate(extraSummary, kSummaryMaxLen);
  }
  return '${m.name} | type=$triggerType | 触发: 当涉及"${_truncate(m.description, 20)}"';
}

String _buildMcpDetail(
    String pluginId, String toolName, String description, String schemaText) {
  // build153：description/inputSchema 是远端服务器供给的文本，会被拼进
  // <toolresult> 包裹的详情块——过结构锁（单行口径：\n 会把一行说明劈成
  // 新行/新块，=== 与 toolresult 变体会伪造边界）
  return 'MCP 工具 $toolName (plugin_id=$pluginId)\n'
      '说明: ${description.isEmpty ? '无描述' : guardCatalogField('mcp:$pluginId:$toolName#desc', description)}\n'
      'inputSchema: ${guardCatalogField('mcp:$pluginId:$toolName#schema', schemaText)}';
}

String _truncate(String s, int maxLen) {
  if (s.length <= maxLen) return s;
  return '${s.substring(0, maxLen)}…';
}
