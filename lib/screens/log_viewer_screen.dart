import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../services/logger_service.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';

/// 日志查看页（v1.4.2 结构化分类升级）
///
/// 新增功能：
///   - 顶部一排「分类筛选 chip」：全部 / 应用 / UI / 导航 / 数据库 / 聊天 / API /
///     ReAct / 压缩 / 搜索 / 下载 / 备份 / 配置 / 错误 / 性能
///   - 每个 chip 显示该分类当前日志数量（便于一眼看到哪一类活动频繁）
///   - 仅在「全部」模式下可看到 VERBOSE 等混合日志，分类模式下只显示分类缓冲
class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  bool _autoScroll = true;
  LogCat? _filter; // null = 显示全部
  final _scrollController = ScrollController();
  // build133（⑥）：删掉 _focusNode —— 只创建 + dispose、从未挂到任何 widget 上，
  // 纯死字段（不影响行为，但会误导后来者以为这里有输入焦点逻辑）。

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    final max = _scrollController.position.maxScrollExtent;
    _scrollController.animateTo(
      max,
      duration: AppDur.base,
      curve: Curves.easeOut,
    );
  }

  /// 根据 LogCat 给出稳定的颜色（用于 chip、行高亮）
  Color _catColor(BuildContext ctx, LogCat c) {
    final colors = <LogCat, int>{
      LogCat.app: 0xFF607D8B, // 蓝灰
      LogCat.ui: 0xFF4CAF50, // 绿
      LogCat.nav: 0xFF00BCD4, // 青
      LogCat.db: 0xFFFF9800, // 橙
      LogCat.chat: 0xFF8BC34A, // 浅绿
      LogCat.api: 0xFF3F51B5, // 靛
      LogCat.react: 0xFF9C27B0, // 紫
      LogCat.compress: 0xFF795548, // 棕
      LogCat.ws: 0xFF2196F3, // 蓝
      LogCat.download: 0xFFFFC107, // 琥珀
      LogCat.backup: 0xFF673AB7, // 深紫
      LogCat.config: 0xFF009688, // 蓝绿
      LogCat.error: 0xFFF44336, // 红
      LogCat.perf: 0xFFE91E63, // 粉
    };
    return Color(colors[c] ?? 0xFF607D8B).withValues(alpha: 0.9);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final logger = context.watch<LoggerService>();

    final allLines = logger.buffer;
    final filteredLines =
        _filter == null ? allLines : logger.linesByCat(_filter!);

    final text = filteredLines.join('\n');

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_autoScroll) _jumpToBottom();
    });

    return Scaffold(
      appBar: AppBar(
        title: Text(l.tr('viewLogs')),
        actions: [
          IconButton(
            tooltip: l.tr('copyAll'),
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                AppSnackBar.showSnackBar(context, 
                  SnackBar(content: Text(l.tr('copied'))),
                );
              }
            },
          ),
          IconButton(
            tooltip: _autoScroll ? l.tr('autoScrollOn') : l.tr('autoScrollOff'),
            icon: Icon(_autoScroll
                ? Icons.vertical_align_bottom
                : Icons.vertical_align_top),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: Container(
            height: kToolbarHeight,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                // 「全部」Chip
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(
                        '${l.locale.languageCode == 'zh' ? '全部' : 'All'} (${allLines.length})'),
                    selected: _filter == null,
                    onSelected: (_) => setState(() => _filter = null),
                  ),
                ),
                // 分类 Chip（按 enum 顺序）
                ...LogCat.values.map((c) {
                  final count = logger.linesByCat(c).length;
                  final color = _catColor(context, c);
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      avatar: CircleAvatar(
                        backgroundColor: color,
                        radius: 8,
                      ),
                      label: Text(
                          '${l.locale.languageCode == 'zh' ? c.labelCN : c.labelEN} ($count)'),
                      selected: _filter == c,
                      onSelected: (_) => setState(() => _filter = c),
                      selectedColor: color.withValues(alpha: 0.25),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ),
      body: filteredLines.isEmpty
          ? Center(child: Text(l.tr('noLogs')))
          : Scrollbar(
              controller: _scrollController,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.all(8),
                child: SelectableText(
                  text,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ),
            ),
    );
  }
}
