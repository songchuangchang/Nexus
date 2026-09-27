import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/conversation.dart';
import '../services/storage_service.dart';

/// build101（F1/F2）：会话内查找页
///
/// 与全局搜索页（conversation_search_screen.dart）的区别：
/// - 数据源锁定单个会话，只搜消息正文；
/// - 命中项显示消息角色、时间、以及关键字上下文窗口；
/// - 点击命中项通过 `Navigator.pop(context, indexInConversation)` 把
///   消息下标回传给 ChatScreen，由 ChatScreen 负责滚动定位（F2）。
///
/// 防抖 300ms + RichText 关键字高亮的做法与全局搜索页保持一致的观感。
class ChatSearchScreen extends StatefulWidget {
  final String conversationId;
  final String conversationTitle;

  const ChatSearchScreen({
    super.key,
    required this.conversationId,
    required this.conversationTitle,
  });

  @override
  State<ChatSearchScreen> createState() => _ChatSearchScreenState();
}

class _ChatSearchScreenState extends State<ChatSearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;

  List<MessageSearchHit> _hits = const [];
  bool _searching = false;
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    // 进页面即聚焦，少一次点击
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(v));
  }

  Future<void> _run(String kw) async {
    final trimmed = kw.trim();
    if (trimmed.isEmpty) {
      if (!mounted) return;
      setState(() {
        _hits = const [];
        _keyword = '';
        _searching = false;
      });
      return;
    }
    if (mounted) setState(() => _searching = true);
    final res = await StorageService.instance
        .searchMessagesInConversation(widget.conversationId, trimmed);
    if (!mounted) return;
    setState(() {
      _hits = res;
      _keyword = trimmed;
      _searching = false;
    });
  }

  /// 命中条目：左侧角色竖条 + 时间，右侧高亮片段，尾部命中次数徽标。
  Widget _buildHit(MessageSearchHit hit, bool isZh, ColorScheme cs) {
    final isUser = hit.message.role.name == 'user';
    final snippet = hit.snippet;
    final start = hit.matchStartInSnippet;
    final end = (start >= 0 && start + _keyword.length <= snippet.length)
        ? start + _keyword.length
        : start;

    final base = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: 12.5,
          height: 1.35,
        );
    final hl = base?.copyWith(
      fontWeight: FontWeight.bold,
      color: cs.primary,
      backgroundColor: cs.primary.withValues(alpha: 0.12),
    );

    final TextSpan span;
    if (start < 0 || end <= start) {
      span = TextSpan(text: snippet, style: base);
    } else {
      span = TextSpan(
        style: base,
        children: [
          TextSpan(text: snippet.substring(0, start)),
          TextSpan(text: snippet.substring(start, end), style: hl),
          TextSpan(text: snippet.substring(end)),
        ],
      );
    }

    final dt = hit.message.createdAt;
    String two(int v) => v.toString().padLeft(2, '0');
    final timeStr = '${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';

    return InkWell(
      onTap: () => Navigator.pop(context, hit.indexInConversation),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
          border: Border(
            left: BorderSide(
              width: 3,
              color: isUser ? cs.tertiary : cs.primary,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isUser ? Icons.person_outline : Icons.smart_toy_outlined,
                  size: 14,
                  color: isUser ? cs.tertiary : cs.primary,
                ),
                const SizedBox(width: 5),
                Text(
                  isUser ? (isZh ? '我' : 'You') : (isZh ? '助手' : 'AI'),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant,
                      ),
                ),
                const SizedBox(width: 8),
                Text(
                  timeStr,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                        fontSize: 11,
                      ),
                ),
                const Spacer(),
                Text(
                  isZh ? '第 ${hit.indexInConversation + 1} 条' : '#${hit.indexInConversation + 1}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                        fontSize: 10,
                      ),
                ),
                if (hit.matchCount > 1) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${hit.matchCount}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            fontSize: 10,
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            RichText(text: span, maxLines: 4, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(isZh ? '在对话中查找' : 'Find in chat',
                style: const TextStyle(fontSize: 16)),
            Text(
              widget.conversationTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              onChanged: _onChanged,
              textInputAction: TextInputAction.search,
              onSubmitted: _run,
              decoration: InputDecoration(
                hintText: isZh ? '搜索本对话的消息…' : 'Search messages in this chat...',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _controller.clear();
                          _run('');
                        },
                      ),
                isDense: true,
                filled: true,
                fillColor: cs.surfaceContainerHighest,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          // 统计条
          if (_keyword.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _searching
                      ? (isZh ? '搜索中…' : 'Searching...')
                      : (_hits.isEmpty
                          ? (isZh ? '未找到匹配消息' : 'No matches')
                          : (isZh
                              ? '找到 ${_hits.length} 条消息'
                              : '${_hits.length} message(s)')),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
              ),
            ),
          const SizedBox(height: 4),
          Expanded(
            child: _hits.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.manage_search,
                              size: 44,
                              color: cs.onSurfaceVariant.withValues(alpha: 0.35)),
                          const SizedBox(height: 10),
                          Text(
                            _keyword.isEmpty
                                ? (isZh
                                    ? '输入关键字，搜索本对话全部消息'
                                    : 'Type to search all messages in this chat')
                                : (isZh ? '没有匹配的消息' : 'No matching messages'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurfaceVariant
                                  .withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 20),
                    itemCount: _hits.length,
                    itemBuilder: (_, i) => Builder(
                      // build140（反馈①同源）：懒加载行的 ctx 是 SliverList 的**共享元素**，
                      // 主题/语言切换后**已画出来的行不会重建**，把外层 build 捕获的 `cs`
                      // 一直带着（表现为换了配色结果卡片颜色不变）。取值挪到包内即可。
                      builder: (context) {
                        final cs = Theme.of(context).colorScheme;
                        final isZh = AppLocalizations.of(context)
                                .locale
                                .languageCode ==
                            'zh';
                        return _buildHit(_hits[i], isZh, cs);
                      },
                    ),
                  ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(
                top: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.4)),
              ),
            ),
            child: Text(
              isZh
                  ? '点击任意结果即可跳转到该条消息'
                  : 'Tap a result to jump to that message',
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
