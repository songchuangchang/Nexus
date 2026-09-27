import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/conversation.dart';
import '../services/storage_service.dart';
import 'chat_screen.dart';

/// build101（B2）：全局会话搜索页
///
/// 在**会话标题**与**消息内容**中做关键字检索（sqflite LIKE）。
/// 输入防抖 300ms，避免每敲一个字都全表扫。
/// 命中消息内容时展示上下文片段并把关键字高亮。
class ConversationSearchScreen extends StatefulWidget {
  const ConversationSearchScreen({super.key});

  @override
  State<ConversationSearchScreen> createState() =>
      _ConversationSearchScreenState();
}

class _ConversationSearchScreenState extends State<ConversationSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _searching = false;
  String _keyword = '';
  List<ConversationSearchHit> _hits = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 输入防抖：300ms 内连续输入只触发最后一次查询
  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(v));
  }

  Future<void> _run(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) {
      if (mounted) {
        setState(() {
          _keyword = '';
          _hits = const [];
          _searching = false;
        });
      }
      return;
    }
    setState(() => _searching = true);
    final storage = context.read<StorageService>();
    await storage.init();
    final hits = await storage.searchConversations(kw);
    if (!mounted) return;
    setState(() {
      _keyword = kw;
      _hits = hits;
      _searching = false;
    });
  }

  /// 命中的消息片段里截取关键字周围的窗口（前 30 / 后 70 字符）
  String _window(String text) {
    if (_keyword.isEmpty) return text;
    final idx = text.toLowerCase().indexOf(_keyword.toLowerCase());
    if (idx < 0) {
      return text.length > 100 ? '${text.substring(0, 100)}…' : text;
    }
    final start = (idx - 30).clamp(0, text.length);
    final end = (idx + _keyword.length + 70).clamp(0, text.length);
    final prefix = start > 0 ? '…' : '';
    final suffix = end < text.length ? '…' : '';
    return '$prefix${text.substring(start, end)}$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isZh = l.locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: isZh ? '搜索对话标题与消息内容' : 'Search titles and messages',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
          onSubmitted: _run,
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: isZh ? '清空' : 'Clear',
              onPressed: () {
                _controller.clear();
                _run('');
              },
            ),
        ],
      ),
      body: _searching
          ? const Center(child: CircularProgressIndicator())
          : _keyword.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search, size: 56, color: cs.outline),
                      const SizedBox(height: 12),
                      Text(isZh ? '输入关键字开始搜索' : 'Type to search',
                          style: Theme.of(context).textTheme.bodyMedium),
                    ],
                  ),
                )
              : _hits.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.search_off, size: 56, color: cs.outline),
                          const SizedBox(height: 12),
                          Text(isZh ? '没有找到匹配的对话' : 'No matching chats',
                              style: Theme.of(context).textTheme.bodyMedium),
                        ],
                      ),
                    )
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              isZh
                                  ? '找到 ${_hits.length} 个对话'
                                  : '${_hits.length} chat(s) found',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ),
                        ),
                        Expanded(
                          child: ListView.separated(
                            itemCount: _hits.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (ctx, i) {
                              final hit = _hits[i];
                              final conv = hit.conversation;
                              // build140（反馈①同源）：必须在**这一项自己的元素**上读配色。
                              // itemBuilder 的 ctx 是 SliverList 的**共享元素**，主题切换时
                              // 本页面确实重建了，但已画出来的行不会跟着重新 build，
                              // 于是它们把旧主题的 `cs`（本 State 的 build 捕获）一直带着
                              // —— 表现就是"换了配色，图标/底色不变"。包一层 Builder 即可。
                              return Builder(builder: (context) {
                                final cs = Theme.of(context).colorScheme;
                                return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: cs.surfaceContainerHighest,
                                  child: Icon(
                                    hit.matchedInTitle
                                        ? Icons.title
                                        : Icons.chat_bubble_outline,
                                    size: 18,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                                title: Text(
                                  conv.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: _buildSnippet(hit, cs),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          ChatScreen(conversation: conv),
                                    ),
                                  ).then((_) => _run(_keyword));
                                },
                              );
                              });
                            },
                          ),
                        ),
                      ],
                    ),
    );
  }

  /// 命中片段：把关键字高亮（RichText）
  Widget _buildSnippet(ConversationSearchHit hit, ColorScheme cs) {
    final text = _window(hit.snippet);
    final kw = _keyword;
    final base = Theme.of(context).textTheme.bodySmall;
    if (kw.isEmpty || text.isEmpty) {
      return Text(text, maxLines: 2, overflow: TextOverflow.ellipsis);
    }
    final spans = <TextSpan>[];
    final lower = text.toLowerCase();
    final lowerKw = kw.toLowerCase();
    var cursor = 0;
    while (true) {
      final idx = lower.indexOf(lowerKw, cursor);
      if (idx < 0) {
        spans.add(TextSpan(text: text.substring(cursor)));
        break;
      }
      if (idx > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, idx)));
      }
      spans.add(TextSpan(
        text: text.substring(idx, idx + kw.length),
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: cs.primary,
          backgroundColor: cs.primary.withValues(alpha: 0.12),
        ),
      ));
      cursor = idx + kw.length;
    }
    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(style: base, children: spans),
    );
  }
}
