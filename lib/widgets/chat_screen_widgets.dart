import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../ui/tokens.dart';

/// v1.7.23：从 chat_screen.dart build 方法抽离的纯展示 widget，
/// 用于给 God class 减重（主文件 3779 → <800 行）。
/// 这些 widget 不持有业务状态，全部通过构造函数回调与外部交互。

/// 未配置 AI API Key 时的全屏引导视图。
class NoApiKeyView extends StatelessWidget {
  final AppLocalizations l;
  final bool isZh;
  final VoidCallback onBack;

  const NoApiKeyView({
    super.key,
    required this.l,
    required this.isZh,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(isZh ? '内置' : 'Built-in')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.chat, size: 64, color: colorScheme.appTextSub),
              const SizedBox(height: 16),
              Text(l.tr('apiConfigNotFound'),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 24),
              Text(
                isZh
                    ? '💡 没有 API Key 也能先体验哦！试试在输入框里说：\n'
                        '"帮我下载微信"\n"download telegram"'
                    : '💡 No API key? You can still try it! Type:\n'
                        '"download WeChat"\n"download telegram"',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: onBack,
                child: Text(l.tr('goBack')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 消息列表为空时的居中引导（含常用语快捷提示条）。
class EmptyChatHint extends StatelessWidget {
  final AppLocalizations l;
  final bool isZh;
  final String model;
  final void Function(String insertText) onPromptTap;

  const EmptyChatHint({
    super.key,
    required this.l,
    required this.isZh,
    required this.model,
    required this.onPromptTap,
  });

  List<(String, String)> get _prompts => isZh
      ? const [
          ('🌐 翻译', '请将以下内容翻译成英文：\n\n'),
          ('📖 解释', '请用通俗易懂的方式解释以下概念：\n\n'),
          ('📝 总结', '请用要点形式总结以下内容：\n\n'),
          ('🔍 代码审查', '请审查以下代码，指出潜在问题和改进建议：\n\n'),
          ('💡 头脑风暴', '请围绕以下主题头脑风暴，给出 10 个创意点子：\n\n'),
          ('🐛 调试', '以下代码有 bug，请帮我定位并修复：\n\n'),
          ('✍️ 重写', '请重写以下内容，使其更清晰简洁：\n\n'),
          ('📅 计划', '请为以下目标制定一份详细的分步执行计划：\n\n'),
        ]
      : const [
          ('🌐 Translate', 'Translate the following into English:\n\n'),
          ('📖 Explain', 'Explain the following concept in plain words:\n\n'),
          ('📝 Summarize', 'Summarize the following in bullet points:\n\n'),
          (
            '🔍 Code review',
            'Review the following code and suggest improvements:\n\n'
          ),
          (
            '💡 Brainstorm',
            'Brainstorm 10 creative ideas around this topic:\n\n'
          ),
          ('🐛 Debug', 'The following code has a bug. Locate and fix it:\n\n'),
          (
            '✍️ Rewrite',
            'Rewrite the following to be clearer and concise:\n\n'
          ),
          ('📅 Plan', 'Create a detailed step-by-step plan for this goal:\n\n'),
        ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prompts = _prompts;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline,
              size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text(l.tr('startChattingWith', args: {'model': model}),
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          Text(
            isZh
                ? '💡 试试：帮我下载微信 · download telegram\n'
                    '🌐 输入框左侧按钮可切换联网搜索'
                : '💡 Try: download WeChat · download telegram\n'
                    '🌐 Tap the left input button for web search',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          // v1.7.36：宽屏下 chips 居中而非横滚占满，比例协调；窄屏自动换行居中
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in prompts)
                ActionChip(
                  label: Text(p.$1),
                  onPressed: () => onPromptTap(p.$2),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 聊天页 AppBar 右上角的弹出菜单
/// （插件管理 / 对话设置 / 压缩上下文 / 在对话中查找 / 多模型对比 / 下载 / 清空）。
class ChatAppBarMenu extends StatelessWidget {
  final AppLocalizations l;
  final bool isZh;
  final void Function(String value) onSelected;

  /// build104（I13）：压缩进行中 → 菜单项显示「压缩中…」并禁用
  final bool compressBusy;

  const ChatAppBarMenu({
    super.key,
    required this.l,
    required this.isZh,
    required this.onSelected,
    this.compressBusy = false,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: onSelected,
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'pluginManager',
          child: Row(
            children: [
              const Icon(Icons.extension),
              const SizedBox(width: 8),
              Text(isZh ? '插件管理' : 'Plugin Manager'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'settings',
          child: Row(
            children: [
              const Icon(Icons.tune),
              const SizedBox(width: 8),
              Text(isZh ? '对话设置' : 'Chat Settings'),
            ],
          ),
        ),
        // build104（I13/I14）：压缩状态长在菜单项上——进行中禁用+显示进度，
        // 不再用常驻 SnackBar（会遮挡输入栏且不自动消失，实机反馈 I13）
        PopupMenuItem(
          value: 'compress',
          enabled: !compressBusy,
          child: Row(
            children: [
              Icon(compressBusy ? Icons.hourglass_top : Icons.compress),
              const SizedBox(width: 8),
              Text(compressBusy
                  ? (isZh ? '压缩中…' : 'Compressing…')
                  : (isZh ? '压缩上下文' : 'Compress Context')),
            ],
          ),
        ),
        // build101（F1/F2）：会话内全文查找 → 命中项可跳转定位
        PopupMenuItem(
          value: 'findInChat',
          child: Row(
            children: [
              const Icon(Icons.manage_search),
              const SizedBox(width: 8),
              Text(isZh ? '在对话中查找' : 'Find in Chat'),
            ],
          ),
        ),
        // build101（E5 多模型对比）：同一问题并发问多个模型，并排看差异
        PopupMenuItem(
          value: 'compare',
          child: Row(
            children: [
              const Icon(Icons.compare_arrows),
              const SizedBox(width: 8),
              Text(isZh ? '多模型对比' : 'Compare Models'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'download',
          child: Row(
            children: [
              const Icon(Icons.download_rounded),
              const SizedBox(width: 8),
              Text(isZh ? '下载文件' : 'Download File'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'clear',
          child: Row(
            children: [
              const Icon(Icons.clear_all),
              const SizedBox(width: 8),
              Text(l.tr('clearMessages')),
            ],
          ),
        ),
      ],
    );
  }
}
