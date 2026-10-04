/// 内置插件的英文展示文案（build133 ⑤）
///
/// 背景：`PluginMetadata.name/description/tags` 在全部 25 个内置插件里**恒为中文**，
/// 英文 locale 下界面直接显示中文。模型侧的 `promptProtocol` 不在修复范围 ——
/// 那是注入给模型的协议文本，与 UI 语言无关。
///
/// 为什么用「id → 文案」字典，而不是给 PluginMetadata 加 nameEn/descriptionEn：
///   1. 不动 25 处 const 元数据 —— 不碰序列化/备份往返，零回归面；
///   2. 中文名仍是唯一权威回退值（第三方/市场插件没有 en 文案时原样显示，不出现空白）；
///   3. 文案集中一处，配 `test/build133_plugin_i18n_test.dart` 的**覆盖棘轮**：
///      遍历运行期 `builtinReActPlugins`，任一内置插件缺 en 条目即测试失败
///      ⇒ 以后新增内置插件漏写英文会被拦下。
library;

import 'plugin_interface.dart';

/// 单个内置插件的英文文案。
class PluginI18nEntry {
  final String name;
  final String description;
  final List<String> tags;

  const PluginI18nEntry({
    required this.name,
    required this.description,
    this.tags = const [],
  });
}

/// 内置插件 id → 英文文案。key 必须与 `PluginMetadata.id` 完全一致。
const Map<String, PluginI18nEntry> kBuiltinPluginI18n = {
  'nexus.builtin.image_gen': PluginI18nEntry(
    name: 'Image Generation',
    description:
        'Generates images from text. Pass image= to edit a picture the user sent (restyle / new background / redraw).',
    tags: ['Built-in', 'Generation', 'Image'],
  ),
  'nexus.builtin.video_gen': PluginI18nEntry(
    name: 'Video Generation',
    description:
        'Submits a video task from text; pass image= to animate a picture. Results show up on the AI Video page once ready.',
    tags: ['Built-in', 'Generation', 'Video'],
  ),
  'nexus.builtin.search': PluginI18nEntry(
    name: 'Web Search',
    description:
        'Gives the AI web search through the ReAct protocol, with basic and advanced depth.',
    tags: ['Built-in', 'Search', 'ReAct'],
  ),
  'nexus.builtin.download': PluginI18nEntry(
    name: 'File & App Download',
    description:
        'Three sub-modes: app search and download (catalog / GitHub / web), general file search and download by type, and direct URL download.',
    tags: ['Built-in', 'Download', 'File', 'App'],
  ),
  'nexus.builtin.ask_user': PluginI18nEntry(
    name: 'Ask User',
    description:
        'When the AI lacks information or faces a multiple-choice decision, it uses the <ask_user> tag to open an option panel and ask for clarification.',
    tags: ['Built-in', 'Interaction', 'Ask'],
  ),
  'nexus.builtin.self_check': PluginI18nEntry(
    name: 'Self-Termination Check',
    description:
        'A self-check message is injected every 20 seconds; the AI emits <self_check> to decide whether to stop thinking, so it cannot loop forever.',
    tags: ['Built-in', 'Self-check', 'Safety'],
  ),
  'nexus.builtin.answer': PluginI18nEntry(
    name: 'Final Answer',
    description:
        'When no further thinking or searching is needed, the AI emits the <answer> tag to end the ReAct loop and return the body as the final reply.',
    tags: ['Built-in', 'Output', 'ReAct'],
  ),
  'nexus.builtin.install_skill': PluginI18nEntry(
    name: 'AI Skill Install',
    description:
        'The AI installs Skills on its own in chat: direct SKILL.md / zip links or a keyword marketplace search, always security-scanned, usable in the same turn.',
    tags: ['Built-in', 'Skill', 'Install'],
  ),
  'nexus.builtin.install_mcp': PluginI18nEntry(
    name: 'AI MCP Install',
    description:
        'The AI installs MCP servers on its own in chat: direct HTTPS endpoints or a keyword search of the official registry, always locally security-scanned, usable in the same turn.',
    tags: ['Built-in', 'MCP', 'Install'],
  ),
  'nexus.builtin.card': PluginI18nEntry(
    name: 'Rich Card',
    description:
        'When the AI emits a <card> tag, a native interactive card is rendered inside the chat stream (price comparison / order / payment confirmation).',
    tags: ['Built-in', 'Card', 'Interaction'],
  ),
  'nexus.builtin.suggest': PluginI18nEntry(
    name: 'Follow-up Suggestions',
    description:
        'After answering, suggests 2 to 4 likely follow-up questions as tappable chips that send on tap.',
    tags: ['Built-in', 'Suggestion', 'Interaction'],
  ),
  'nexus.builtin.todo': PluginI18nEntry(
    name: 'Todo List',
    description:
        'For complex multi-step tasks, lists a todo checklist and ticks items off as work progresses, so the user sees the whole plan and current progress.',
    tags: ['Built-in', 'Todo', 'Task'],
  ),
  'nexus.builtin.memory_write': PluginI18nEntry(
    name: 'Auto Memory',
    description:
        'When the user reveals a long-term preference or fact, writes it to global or project memory so later conversations carry it automatically.',
    tags: ['Built-in', 'Memory'],
  ),
  'nexus.builtin.memory_delete': PluginI18nEntry(
    name: 'Memory Delete',
    description:
        'When the user explicitly asks to forget a preference or fact, deletes the global or project memory entry by key.',
    tags: ['Built-in', 'Memory'],
  ),
  'nexus.builtin.ip_locate': PluginI18nEntry(
    name: 'IP Location',
    description:
        'City-level location from the IP address (requires a configured Amap connector key); anchors nearby-style queries.',
    tags: ['Built-in', 'Location'],
  ),
  'nexus.builtin.get_location': PluginI18nEntry(
    name: 'Device Location',
    description:
        'Street-level GPS location: emits <get_location /> to fetch device coordinates (GCJ-02, ready to feed into Amap tools).',
    tags: ['Built-in', 'Location'],
  ),
  'nexus.builtin.query_quota': PluginI18nEntry(
    name: 'Balance Query',
    description:
        'Queries the balance and usage of an API config through <query_quota />, using the balance endpoint of each service (one-api relay / DeepSeek / SiliconFlow).',
    tags: ['Built-in', 'Balance'],
  ),
  'nexus.builtin.connector_guide': PluginI18nEntry(
    name: 'Connector Guide',
    description:
        'MCP connector setup steps plus a common-error reference table (401 / timeout / zero tools).',
    tags: ['Built-in', 'MCP', 'Connector'],
  ),
  'nexus.builtin.log_query': PluginI18nEntry(
    name: 'Log Query',
    description:
        'Queries app runtime logs for troubleshooting (category / keyword / tail lines); the privacy guard is off by default.',
    tags: ['Built-in', 'Log', 'Troubleshooting'],
  ),
  'nexus.builtin.ws_list': PluginI18nEntry(
    name: 'Workspace: List',
    description:
        'Lists the AI file workspace (text files only, sandboxed directory, contents are never executed).',
    tags: ['Built-in', 'Workspace'],
  ),
  'nexus.builtin.ws_read': PluginI18nEntry(
    name: 'Workspace: Read',
    description:
        'Reads a text file inside the AI file workspace (truncated with a marker beyond 30k characters).',
    tags: ['Built-in', 'Workspace'],
  ),
  'nexus.builtin.ws_write': PluginI18nEntry(
    name: 'Workspace: Write',
    description:
        'Writes or rewrites a text file in the AI file workspace (confirmation dialog required, never overwrites by default).',
    tags: ['Built-in', 'Workspace'],
  ),
  'nexus.builtin.ws_delete': PluginI18nEntry(
    name: 'Workspace: Delete',
    description:
        'Deletes a file inside the AI file workspace (confirmation dialog required).',
    tags: ['Built-in', 'Workspace'],
  ),
  'nexus.builtin.ws_patch': PluginI18nEntry(
    name: 'Workspace: Patch',
    description:
        'Locates and replaces a fragment inside a workspace file (transactional: nothing is written when the fragment is missing or not unique).',
    tags: ['Built-in', 'Workspace'],
  ),
  'nexus.builtin.ws_grep': PluginI18nEntry(
    name: 'Workspace: Grep',
    description:
        'Searches workspace text files by regular expression and returns file:line matches (200-line cap).',
    tags: ['Built-in', 'Workspace'],
  ),
  'nexus.builtin.ws_download': PluginI18nEntry(
    name: 'Workspace: Download',
    description:
        'Downloads a text file from the web into the AI file workspace (HTTPS only, security scan, 10 MB cap).',
    tags: ['Built-in', 'Workspace'],
  ),
  'nexus.builtin.ws_export': PluginI18nEntry(
    name: 'Workspace: Export',
    description:
        'Shares a workspace file out (system share sheet) or opens it with a system app.',
    tags: ['Built-in', 'Workspace'],
  ),
  'nexus.builtin.ws_make_file': PluginI18nEntry(
    name: 'Workspace: Make File',
    description:
        'Renders text data into a real Excel (.xlsx), Word (.docx) or PDF file inside the workspace; .csv is the plain-data fallback. Binary payloads such as base64 are rejected.',
    tags: ['Built-in', 'Workspace'],
  ),
  // build180（刀二）：内置浏览器四个动作。漏一条不是「英文界面显示中文」这么轻——
  // test/build133_plugin_i18n_test.dart 遍历运行期 builtinReActPlugins，缺 en 条目直接红。
  'nexus.builtin.web_navigate': PluginI18nEntry(
    name: 'Browser: Open Page',
    description:
        'Opens an HTTPS page inside the app\'s built-in browser (off by default, turned on in General settings). The first visit to a domain asks the user to confirm.',
    tags: ['Built-in', 'Browser'],
  ),
  'nexus.builtin.web_read': PluginI18nEntry(
    name: 'Browser: Read Page',
    description:
        'Serializes the current page into visible text plus a list of interactive elements, each with an idx for web_act. Long pages keep only what is near the viewport and say how much was left out.',
    tags: ['Built-in', 'Browser'],
  ),
  'nexus.builtin.web_act': PluginI18nEntry(
    name: 'Browser: Act On Element',
    description:
        'Clicks, fills or clears an element of the built-in browser page by its idx. Password fields are never filled for the user, and a form containing one must be submitted by hand.',
    tags: ['Built-in', 'Browser'],
  ),
  'nexus.builtin.web_back': PluginI18nEntry(
    name: 'Browser: Go Back',
    description:
        'Goes one page back in the built-in browser history; the element list is stale afterwards, so the page has to be read again.',
    tags: ['Built-in', 'Browser'],
  ),
};

/// 取插件展示名：中文用元数据原名；英文优先字典，缺失则回退原名（绝不返回空白）。
String pluginDisplayName(String id, String fallback, {required bool isZh}) {
  if (isZh) return fallback;
  final entry = kBuiltinPluginI18n[id];
  return (entry == null || entry.name.isEmpty) ? fallback : entry.name;
}

/// 取插件展示描述，规则同 [pluginDisplayName]。
String pluginDisplayDescription(String id, String fallback,
    {required bool isZh}) {
  if (isZh) return fallback;
  final entry = kBuiltinPluginI18n[id];
  return (entry == null || entry.description.isEmpty)
      ? fallback
      : entry.description;
}

/// 取插件展示标签，规则同 [pluginDisplayName]。
List<String> pluginDisplayTags(String id, List<String> fallback,
    {required bool isZh}) {
  if (isZh) return fallback;
  final entry = kBuiltinPluginI18n[id];
  return (entry == null || entry.tags.isEmpty) ? fallback : entry.tags;
}

/// 调用点便捷入口：直接吃 [PluginMetadata]，省掉每个 UI 点都手写 id/回退值。
extension PluginMetadataI18nX on PluginMetadata {
  String displayName(bool isZh) => pluginDisplayName(id, name, isZh: isZh);

  String displayDescription(bool isZh) =>
      pluginDisplayDescription(id, description, isZh: isZh);

  List<String> displayTags(bool isZh) => pluginDisplayTags(id, tags, isZh: isZh);
}
