/// P7：Git 图谱模态。暗底遮罩由 showDialog 提供，本组件是圆角卡片本体：
/// 表格（图 / 描述 / 日期 / 作者 / 提交号）+ 右上刷新/关闭。
/// 数据源 = GitService.log（纯客户端 git log 解析）；非 git 仓与空仓都
/// 走 128 退出 → 空态合写成「不是 git 仓库，或还没有任何提交」保真话。
library;

import 'package:flutter/material.dart';

import 'git_panel.dart';
import 'workbench_theme.dart';

class GitGraphModal extends StatefulWidget {
  const GitGraphModal({super.key, required this.service, this.onClose});

  final GitService service;
  final VoidCallback? onClose;

  @override
  State<GitGraphModal> createState() => _GitGraphModalState();
}

class _GitGraphModalState extends State<GitGraphModal> {
  List<GitLogEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _entries = null);
    final e = await widget.service.log();
    if (!mounted) return;
    setState(() => _entries = e);
  }

  String _fmtDate(int epochSeconds) {
    final d =
        DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = WbColors.of(context);
    final entries = _entries;
    return Container(
      width: 860,
      height: 560,
      decoration: BoxDecoration(
        color: c.panelBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('Git 图谱（最近提交）',
                      style: WbText.ui13.copyWith(
                          color: c.textPrimary,
                          fontWeight: FontWeight.w700)),
                ),
                TextButton(
                    onPressed: _load,
                    child: Text('刷新',
                        style: WbText.ui12.copyWith(color: c.accent))),
                TextButton(
                    onPressed: widget.onClose,
                    child: Text('关闭',
                        style: WbText.ui12.copyWith(color: c.textSecondary))),
              ],
            ),
          ),
          Divider(height: 1, color: c.border),
          _headerRow(c),
          Divider(height: 1, color: c.border),
          Expanded(
            child: entries == null
                ? Center(
                    child: Text('读取中…',
                        style:
                            WbText.ui12.copyWith(color: c.textTertiary)))
                : entries.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('不是 git 仓库，或还没有任何提交。',
                              textAlign: TextAlign.center,
                              style: WbText.ui12
                                  .copyWith(color: c.textTertiary)),
                        ),
                      )
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, i) =>
                            _row(entries[i], c, i == entries.length - 1),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _headerRow(WbColors c) {
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          const SizedBox(width: 36),
          _colLabel('描述', c),
          SizedBox(width: 120, child: _colLabel('日期', c)),
          SizedBox(width: 90, child: _colLabel('作者', c)),
          SizedBox(width: 70, child: _colLabel('提交号', c)),
          const SizedBox(width: 10),
        ],
      ),
    );
  }

  Widget _colLabel(String t, WbColors c) => Text(t,
      style: WbText.ui11.copyWith(color: c.textTertiary));

  Widget _row(GitLogEntry e, WbColors c, bool last) {
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          _GraphCell(lineColor: c.border, dotColor: c.accent, last: last),
          Expanded(
            child: Text(e.subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WbText.ui12.copyWith(color: c.textPrimary)),
          ),
          SizedBox(
              width: 120,
              child: Text(_fmtDate(e.timestamp),
                  style: WbText.ui11.copyWith(color: c.textSecondary))),
          SizedBox(
              width: 90,
              child: Text(e.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WbText.ui11.copyWith(color: c.textSecondary))),
          SizedBox(
              width: 70,
              child: Text(e.hash,
                  style: WbText.code12.copyWith(color: c.textTertiary))),
          const SizedBox(width: 10),
        ],
      ),
    );
  }
}

/// 图列：竖提交线 + 圆点（示意，不画真 graph）。
class _GraphCell extends StatelessWidget {
  const _GraphCell({
    required this.lineColor,
    required this.dotColor,
    required this.last,
  });

  final Color lineColor;
  final Color dotColor;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 32,
      child: CustomPaint(
        painter: _GraphLinePainter(
            lineColor: lineColor, dotColor: dotColor, last: last),
      ),
    );
  }
}

class _GraphLinePainter extends CustomPainter {
  const _GraphLinePainter({
    required this.lineColor,
    required this.dotColor,
    required this.last,
  });

  final Color lineColor;
  final Color dotColor;
  final bool last;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final line = Paint()
      ..color = lineColor
      ..strokeWidth = 2;
    // 上半段永远画（上一行有线连下来）；末行下半段收掉。
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height / 2), line);
    if (!last) {
      canvas.drawLine(Offset(cx, size.height / 2), Offset(cx, size.height), line);
    }
    final ring = Paint()
      ..color = dotColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(Offset(cx, size.height / 2), 5, ring);
    canvas.drawCircle(Offset(cx, size.height / 2), 3, Paint()..color = dotColor);
  }

  @override
  bool shouldRepaint(covariant _GraphLinePainter old) =>
      old.lineColor != lineColor ||
      old.dotColor != dotColor ||
      old.last != last;
}
