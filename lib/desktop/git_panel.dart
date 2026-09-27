/// B1 Git 面板：status 列表 + 单文件 diff 视图。
/// git 一律走 Process.run 参数数组（无 shell 拼接），工作目录 = 打开的文件夹。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'workbench_theme.dart';

class GitStatusEntry {
  const GitStatusEntry({required this.x, required this.y, required this.path});

  /// porcelain v1 的两个状态列（index / worktree）。
  final String x;
  final String y;
  final String path;

  bool get isUntracked => x == '?' && y == '?';

  String get label => isUntracked ? '??' : '$x$y'.trim();
}

/// P7：git log 一行（图谱模态数据源）。
class GitLogEntry {
  const GitLogEntry({
    required this.hash,
    required this.subject,
    required this.author,
    required this.timestamp,
  });

  /// 短 hash（%h）。
  final String hash;

  /// 描述（%s）。
  final String subject;

  /// 作者（%an）。
  final String author;

  /// 提交时间（%at，epoch 秒）。
  final int timestamp;
}

/// `git status --porcelain=v1` 的行解析（含 rename 的 "old -> new"）。
List<GitStatusEntry> parsePorcelain(String out) {
  final entries = <GitStatusEntry>[];
  for (final raw in out.split('\n')) {
    if (raw.length < 4) continue;
    final x = raw[0];
    final y = raw[1];
    var path = raw.substring(3);
    final arrow = path.indexOf(' -> ');
    if (arrow >= 0) path = path.substring(arrow + 4);
    if (path.startsWith('"') && path.endsWith('"') && path.length >= 2) {
      path = path.substring(1, path.length - 1);
    }
    entries.add(GitStatusEntry(x: x, y: y, path: path));
  }
  return entries;
}

enum DiffLineType { header, hunk, add, del, context }

class DiffLine {
  const DiffLine(this.type, this.text, {this.newLine});

  final DiffLineType type;
  final String text;

  /// P9：该行在**新侧**（+ 文件）的行号，由 hunk 头 `@@ -a,b +c,d @@` 累加得出；
  /// 删除行不占新侧号，hunk/文件头与正文外的行也没有 ⇒ null。
  final int? newLine;
}

/// hunk 头 `@@ -old,olen +new,nlen @@`：只要 new 那个起点。
final RegExp _hunkHeaderRe = RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@');

/// unified diff 文本 → 逐行分类 + **新侧行号**（P9 行级批注的锚点）。
/// 计数规则：hunk 头把游标置成 `+c`；上下文行与新增行各占一个号并自增，
/// 删除行不占新侧号；`---`/`+++`/`diff `/`index ` 等头行与正文外的行（含
/// 末尾空行、`\ No newline`）不带号。
List<DiffLine> parseDiff(String out) {
  final lines = <DiffLine>[];
  int? next;
  for (final raw in out.split('\n')) {
    if (raw.startsWith('+++') || raw.startsWith('---')) {
      lines.add(DiffLine(DiffLineType.header, raw));
    } else if (raw.startsWith('diff ') ||
        raw.startsWith('index ') ||
        raw.startsWith('new file') ||
        raw.startsWith('deleted file')) {
      lines.add(DiffLine(DiffLineType.header, raw));
    } else if (raw.startsWith('@@')) {
      final m = _hunkHeaderRe.firstMatch(raw);
      next = m == null ? null : int.tryParse(m.group(1)!);
      lines.add(DiffLine(DiffLineType.hunk, raw));
    } else if (raw.startsWith('+')) {
      lines.add(DiffLine(DiffLineType.add, raw, newLine: next));
      if (next != null) next++;
    } else if (raw.startsWith('-')) {
      lines.add(DiffLine(DiffLineType.del, raw));
    } else {
      // 只有真正的上下文行（前导一个空格）才占新侧号。
      final numbered = next != null && raw.startsWith(' ');
      lines.add(DiffLine(DiffLineType.context, raw,
          newLine: numbered ? next : null));
      if (numbered) next++;
    }
  }
  return lines;
}

class GitService {
  const GitService(this.repoPath);

  final String repoPath;

  Future<List<GitStatusEntry>> status() async {
    final r = await Process.run(
      'git',
      // core.quotePath=false：默认 git 会把非 ASCII 路径转成八进制转义
      // （"\344\270\255\346\226\207.md"），那样和文件树里的真实名字对不上键。
      ['-c', 'core.quotePath=false', 'status', '--porcelain=v1'],
      workingDirectory: repoPath,
      // git 输出恒为 UTF-8；Process.run 默认按系统代码页解码，
      // 中文 Windows 上是 GBK → 「中文 说明.md」会变成「涓 璇存槑.md」。
      stdoutEncoding: utf8,
    );
    if (r.exitCode != 0) {
      throw StateError('git status 失败（exit=${r.exitCode}）：${r.stderr}');
    }
    return parsePorcelain(r.stdout as String);
  }

  /// S1b：当前分支名（输入卡片的分支 chip 用）。非 git 仓 / git 不可用时
  /// exitCode 非 0 —— 按契约返回 null，不抛（分支只是展示，不该炸工作台）。
  Future<String?> branch() async {
    final r = await Process.run(
      'git',
      ['-c', 'core.quotePath=false', 'rev-parse', '--abbrev-ref', 'HEAD'],
      workingDirectory: repoPath,
      // 同 status()：默认按系统代码页解码，中文 Windows 上 GBK 会乱码。
      stdoutEncoding: utf8,
    );
    if (r.exitCode != 0) return null;
    return (r.stdout as String).trim();
  }

  /// P7：最近提交（图谱模态数据源）。非 git 仓 / git 不可用 → 空表，
  /// 不抛不弹错。字段用 %x1f（单元分隔符）切——描述里出现竖线、空格等
  /// 任何常规字符都不怕；非仓与空仓都走 128 退出 → 空表，空态文案由
  /// 模态层合写真话。
  Future<List<GitLogEntry>> log({int limit = 50}) async {
    final r = await Process.run(
      'git',
      [
        '-c', 'core.quotePath=false',
        'log', '--pretty=format:%h%x1f%s%x1f%an%x1f%at', '-n', '$limit',
      ],
      workingDirectory: repoPath,
      stdoutEncoding: utf8,
    );
    if (r.exitCode != 0) return const [];
    final out = (r.stdout as String).trim();
    if (out.isEmpty) return const [];
    final entries = <GitLogEntry>[];
    for (final line in out.split('\n')) {
      final f = line.split('\x1f');
      if (f.length < 4) continue;
      final ts = int.tryParse(f[3]);
      if (ts == null) continue;
      entries.add(GitLogEntry(
        hash: f[0],
        subject: f[1],
        author: f[2],
        timestamp: ts,
      ));
    }
    return entries;
  }

  /// P8：暂存单文件。失败抛 StateError，由 Review 界面真话展示。
  Future<void> stage(String path) async {
    final r = await Process.run(
      'git',
      ['add', '--', path],
      workingDirectory: repoPath,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (r.exitCode != 0) {
      throw StateError('git add 失败：${r.stderr}');
    }
  }

  /// P8：取消暂存（改动保留在工作区）。
  Future<void> unstage(String path) async {
    final r = await Process.run(
      'git',
      ['restore', '--staged', '--', path],
      workingDirectory: repoPath,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (r.exitCode != 0) {
      throw StateError('git restore --staged 失败：${r.stderr}');
    }
  }

  /// P8：丢弃一个文件的全部改动（index+工作区恢复到 HEAD）。
  /// **不可恢复**——没有备份机制（规格 §4 口径），调用方必须先二次确认。
  Future<void> discard(String path) async {
    final r = await Process.run(
      'git',
      ['restore', '--staged', '--worktree', '--', path],
      workingDirectory: repoPath,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (r.exitCode != 0) {
      throw StateError('git restore 失败：${r.stderr}');
    }
  }

  /// P8：提交暂存区。无 staged 内容 / git 失败 → StateError 真话。
  /// 无 staged 时 git 把原因写在 **stdout**（stderr 0 字节），所以失败文本
  /// 两路都要带，否则面板只剩「git commit 失败：」前缀＝把原因丢了。
  Future<String> commit(String msg) async {
    final r = await Process.run(
      'git',
      ['commit', '-m', msg],
      workingDirectory: repoPath,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (r.exitCode != 0) {
      final why = [
        (r.stderr as String).trim(),
        (r.stdout as String).trim(),
      ].where((s) => s.isNotEmpty).join(' / ');
      throw StateError(why.isEmpty
          ? 'git commit 失败：git 没有给出原因（退出码 ${r.exitCode}）'
          : 'git commit 失败：$why');
    }
    return (r.stdout as String).trim();
  }

  /// 单文件 diff；未跟踪文件没有 diff，由调用方另行提示。
  Future<List<DiffLine>> diff(String path) async {
    final r = await Process.run(
      'git',
      ['diff', '--', path],
      workingDirectory: repoPath,
      // 同 status：diff 正文里的中文也必须按 UTF-8 解，否则 GBK 乱码。
      stdoutEncoding: utf8,
    );
    if (r.exitCode != 0) {
      throw StateError('git diff 失败（exit=${r.exitCode}）：${r.stderr}');
    }
    return parseDiff(r.stdout as String);
  }
}

class GitPanel extends StatefulWidget {
  const GitPanel({super.key, required this.repoPath});

  final String repoPath;

  @override
  State<GitPanel> createState() => _GitPanelState();
}

class _GitPanelState extends State<GitPanel> {
  late final GitService _git = GitService(widget.repoPath);
  List<GitStatusEntry>? _entries;
  String? _error;
  GitStatusEntry? _selected;
  List<DiffLine>? _diff;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final entries = await _git.status();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _error = null;
        _selected = null;
        _diff = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entries = null;
        _error = '$e';
      });
    }
  }

  Future<void> _select(GitStatusEntry entry) async {
    setState(() {
      _selected = entry;
      _diff = null;
    });
    if (entry.isUntracked) return; // 未跟踪文件没有 diff 可显示
    try {
      final diff = await _git.diff(entry.path);
      if (!mounted || _selected != entry) return;
      setState(() => _diff = diff);
    } catch (e) {
      if (!mounted || _selected != entry) return;
      setState(() => _error = '$e');
    }
  }

  Color _diffColor(DiffLineType t, WbColors c) => switch (t) {
        DiffLineType.add => c.ok,
        DiffLineType.del => c.danger,
        DiffLineType.hunk => c.accent,
        DiffLineType.header => c.textSecondary,
        DiffLineType.context => c.textPrimary,
      };

  Color? _diffBg(DiffLineType t, WbColors c) => switch (t) {
        DiffLineType.add => c.ok.withValues(alpha: 0.08),
        DiffLineType.del => c.danger.withValues(alpha: 0.08),
        _ => null,
      };

  /// 状态列字母的颜色：新增绿、修改琥珀、删除红、未跟踪弱化。
  Color _statusColor(GitStatusEntry e, WbColors c) {
    if (e.isUntracked) return c.textTertiary;
    final s = '${e.x}${e.y}';
    if (s.contains('D')) return c.danger;
    if (s.contains('A')) return c.ok;
    if (s.contains('M')) return c.warn;
    return c.textSecondary;
  }

  @override
  Widget build(BuildContext context) {
    final c = WbColors.of(context);
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text('git 面板：$_error',
              style: WbText.ui12.copyWith(color: c.danger)),
        ),
      );
    }
    final entries = _entries;
    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Row(
      children: [
        SizedBox(
          width: 280,
          child: Column(
            children: [
              SizedBox(
                height: 32,
                child: Row(
                  children: [
                    const SizedBox(width: 10),
                    Text('变更 ${entries.length}',
                        style: WbText.ui12.copyWith(
                            color: c.textSecondary,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: IconButton(
                        icon: Icon(Icons.refresh,
                            size: 15, color: c.textSecondary),
                        onPressed: _refresh,
                        tooltip: '刷新 git status',
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
              Divider(height: 1, color: c.border),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Text('工作区干净',
                            style:
                                WbText.ui12.copyWith(color: c.textTertiary)))
                    : ListView.builder(
                        itemCount: entries.length,
                        itemExtent: 26,
                        itemBuilder: (context, i) {
                          final e = entries[i];
                          final sel = identical(e, _selected);
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _select(e),
                            child: ColoredBox(
                              color: sel
                                  ? c.rowSelected
                                  : const Color(0x00000000),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 26,
                                      child: Text(e.label,
                                          style: WbText.code12.copyWith(
                                              fontSize: 11,
                                              color: _statusColor(e, c))),
                                    ),
                                    Expanded(
                                      child: Text(
                                        e.path,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: WbText.ui12.copyWith(
                                            color: sel
                                                ? c.accent
                                                : c.textPrimary),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        VerticalDivider(width: 1, color: c.border),
        Expanded(
          child: _selected == null
              ? Center(
                  child: Text('点左侧文件看 diff',
                      style: WbText.ui12.copyWith(color: c.textTertiary)))
              : _selected!.isUntracked
                  ? Center(
                      child: Text('未跟踪的新文件没有 diff',
                          style:
                              WbText.ui12.copyWith(color: c.textTertiary)))
                  : _diff == null
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          itemCount: _diff!.length,
                          itemExtent: 18,
                          itemBuilder: (context, i) {
                            final line = _diff![i];
                            return Container(
                              color: _diffBg(line.type, c),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              alignment: Alignment.centerLeft,
                              child: Text(
                                line.text,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                softWrap: false,
                                style: WbText.code12.copyWith(
                                  color: _diffColor(line.type, c),
                                ),
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}
