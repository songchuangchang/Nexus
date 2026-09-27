import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../services/skill_install_service.dart';
import 'plugin_context.dart';
import 'plugin_interface.dart';
import 'plugin_registry.dart';

/// AI 代装 Skill 插件（待办① / 拍板⑥）
///
/// AI 输出 <install_skill url="..." query="..." name="..." /> 时触发：
/// 直链 URL 或市场搜索（直链优先）→ 下载 → 安全扫描（不过即硬拒）
/// → 解析 SKILL.md → 写入 .skills/ → 注册 PluginRegistry → 当轮即可 <skill_call>。
///
/// 注册表通过 [registryResolver] 注入（由 createBuiltinPluginRegistry 绑定），
/// 避免 handle 里跨 async 用 context.read 崩溃。
class InstallSkillPlugin extends ReActPlugin {
  /// 全局 PluginRegistry 解析器，createBuiltinPluginRegistry 创建后绑定。
  static PluginRegistry? Function()? registryResolver;

  @override
  String get triggerType => 'install_skill';

  @override
  RegExp? get legacyTrigger => null;

  @override
  PluginSource get source => PluginSource.system;

  @override
  PluginMetadata get metadata => const PluginMetadata(
        id: 'nexus.builtin.install_skill',
        name: 'AI 代装 Skill',
        version: '1.7.38',
        author: 'Nexus Team',
        description:
            'AI 在聊天中自助安装 Skill：支持 SKILL.md/zip 直链或按关键词搜市场，全程自动安全扫描，装完当轮即可调用。',
        homepage: 'https://nexus.local/plugins/install_skill',
        minAppVersion: '1.7.38',
        tags: ['内置', 'Skill', '安装'],
        promptProtocol: '''
【Skill 代装工具】使用说明：
- 使用场景：用户要求"安装/装一个 Skill"，或当前任务明显需要某个尚不存在的 Skill 能力时。
- 协议格式（自闭合标签）：<install_skill url="直链URL" query="市场搜索关键词" name="可选名称" />
  - url：SKILL.md 原文或 zip 包的 http(s) 直链。【直链优先】：url 非空时忽略 query。
  - query：没有直链时填市场搜索关键词，宿主取第一个市场条目安装。
  - url 与 query 至少填一个。
- 安全关卡（不可绕过）：下载后必须经过本地安全扫描（及可选远程深扫），扫描不通过会被直接拒绝安装，结果会以 <toolresult kind="install_skill"> 返回给你。
- 安装成功后：该 Skill 立即注册并启用，你可在后续轮次用 <skill_call name="skill.xxx"> 调用，或按其规则自然触发；先用 <toolresult> 里返回的 pluginId 作为 name。
- 幂等：已安装的 Skill 再次安装会直接返回成功，不会重复写入。
- ❌ 禁止：不要输出 <answer> 告诉用户"请去插件市场手动安装"来代替本标签——你可以直接代装。
''',
      );

  @override
  Future<void> handle(BuildContext context, PluginContext pc,
      Map<String, dynamic> attrs) async {
    final isZh = pc.userMsg?.content.contains(RegExp(r'[一-龥]')) ?? true;
    final url = (attrs['url'] as String? ?? '').trim();
    final query =
        (attrs['query'] as String? ?? attrs['content'] as String? ?? '').trim();

    if (url.isEmpty && query.isEmpty) {
      pc.addReasoningStep(
        'install_skill',
        isZh
            ? '代装参数为空（url/query 至少一个），已忽略'
            : 'install_skill: empty params, ignored',
        status: 'invalid',
        resultSummary: 'missing url/query',
      );
      return;
    }
    final registry = registryResolver?.call();
    if (registry == null) {
      pc.addReasoningStep(
        'install_skill',
        isZh ? '插件注册表不可用，无法代装' : 'Plugin registry unavailable',
        status: 'failed',
      );
      return;
    }

    final sourceLabel = url.isNotEmpty
        ? _hostOf(url)
        : (isZh ? '市场搜索「$query」' : 'market "$query"');
    pc.addReasoningStep(
      'install_skill',
      isZh
          ? '🧩 正在代装 Skill（来源：$sourceLabel）...'
          : '🧩 Installing skill (source: $sourceLabel)...',
      status: 'running',
    );
    pc.logger.info('[InstallSkill] trigger source=$sourceLabel', tag: 'Plugin');

    final result = await SkillInstallService.install(
      registry: registry,
      cfg: pc.webSearchCfg,
      url: url,
      query: query,
    );

    final convId = pc.userMsg?.conversationId ?? pc.assistantMsg.conversationId;
    if (result.ok) {
      final already = result.alreadyInstalled;
      pc.addReasoningStep(
        'install_skill',
        isZh
            ? (already
                ? '✅ Skill「${result.name}」已安装过，直接可用（${result.pluginId}）'
                : '✅ Skill「${result.name}」安装成功并已启用（${result.pluginId}）')
            : (already
                ? '✅ Skill "${result.name}" already installed (${result.pluginId})'
                : '✅ Skill "${result.name}" installed and enabled (${result.pluginId})'),
        pluginId: result.pluginId,
        pluginName: result.name,
        status: 'success',
        resultSummary: already ? 'already installed' : 'installed',
      );
      pc.addMessage(ChatMessage.create(
        conversationId: convId,
        role: MessageRole.user,
        content: '<toolresult kind="install_skill" status="success">'
            'Skill installed and enabled. pluginId=${result.pluginId} name=${result.name}'
            '${already ? ' (already installed)' : ''}. '
            'You can now use it via <skill_call name="${result.pluginId}">optional JSON</skill_call>, '
            'or follow its rules when triggered naturally.'
            '</toolresult>',
      ));
      return;
    }

    if (result.blockedByScan) {
      // 扫描不通过：硬拒 + 思考面板留可见节点 + 注入 toolresult 让 AI 知情
      final findingsText = result.findings.join('；');
      pc.addReasoningStep(
        'install_skill',
        isZh
            ? '🛡️ Skill「${result.name ?? sourceLabel}」安全扫描不通过，已拒绝安装。命中：$findingsText'
            : '🛡️ Skill "${result.name ?? sourceLabel}" rejected by security scan. Findings: $findingsText',
        pluginName: result.name,
        status: 'blocked',
        resultSummary: result.error,
      );
      pc.addMessage(ChatMessage.create(
        conversationId: convId,
        role: MessageRole.user,
        content: '<toolresult kind="install_skill" status="blocked">'
            'Installation REJECTED by security scan. ${result.error}. '
            'Do NOT retry the same source; inform the user why it was blocked.'
            '</toolresult>',
      ));
      return;
    }

    pc.addReasoningStep(
      'install_skill',
      isZh
          ? '❌ Skill 代装失败：${result.error}'
          : '❌ Skill install failed: ${result.error}',
      status: 'failed',
      resultSummary: result.error,
    );
    pc.addMessage(ChatMessage.create(
      conversationId: convId,
      role: MessageRole.user,
      content: '<toolresult kind="install_skill" status="failed">'
          'Installation failed: ${result.error}. '
          'Check the url/query and try again, or ask the user for a valid source.'
          '</toolresult>',
    ));
  }

  static String _hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return 'url';
    }
  }
}
