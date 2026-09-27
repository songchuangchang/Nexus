/// B2 提案与审批：agent 全程只读跑（gateway `local:false` → readonly argv，
/// 协议里本来就没有授权回传这一腿），改动只能用 PATCH 块吐在文本里；
/// **桌面进程是唯一落盘者** —— 批准的由这里写，拒绝的从结构上就不可能落盘。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'git_panel.dart';

/// 发给 agent 的协议头：每次 send 都带上，防多轮后模型忘了格式。
const String kPatchProtocolPreamble = '''
【桌面工作台协议】你正在只读模式运行，不能直接写文件。凡是要改/新建文件，
对每个文件输出恰好一个块（路径相对当前工作区，不许含 ..，不许绝对路径）：
<<<PATCH path="相对/路径.dart">>>
（该文件的完整新内容）
<<<END>>>
块之外可以用普通文字解释。不输出块 = 本轮不改任何文件。
''';

class PatchBlock {
  const PatchBlock({required this.path, required this.content});

  final String path;
  final String content;
}

/// 解析 PATCH 块。非贪婪匹配到**第一个** <<<END>>> —— 文件内容里本不该出现这串；
/// 出现了也算协议违规，块会在那里截断，审批时人能看到截断结果再决定。
/// 不用内联标志（本仓规约），多行内容用 [\s\S]。
final RegExp _blockRe =
    RegExp(r'<<<PATCH path="([^"]+)">>>\r?\n([\s\S]*?)\r?\n<<<END>>>');

List<PatchBlock> parsePatchBlocks(String text) {
  return [
    for (final m in _blockRe.allMatches(text))
      PatchBlock(path: m.group(1)!.trim(), content: m.group(2)!),
  ];
}

/// 相对路径 → 绝界内绝对路径；越界返回 null。
/// 手工分段归一化（不引 path 包）：处理 . / .. / 正反斜杠。
String? resolveWithinRoot(String rootPath, String rel) {
  if (rel.isEmpty) return null;
  final rootSegs = rootPath
      .replaceAll(r'\', '/')
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  final segs = rel.replaceAll(r'\', '/').split('/');
  final lead = rootPath.replaceAll(r'\', '/').startsWith('/') ? '/' : '';
  final out = List<String>.from(rootSegs);
  for (final s in segs) {
    if (s.isEmpty || s == '.') continue;
    if (s == '..') {
      if (out.length <= rootSegs.length) return null; // 逃出根
      out.removeLast();
      continue;
    }
    if (s.contains(':')) return null; // 盘符/流，一律拒
    out.add(s);
  }
  if (out.length == rootSegs.length) return null; // 指到根本身
  return '$lead${out.join('/')}';
}

/// LCS 行级 diff。行数乘积超上限就退化成「整文件替换」，绝不做 O(n·m) 的炸弹。
const int kDiffCellCap = 2000000;

/// 折叠长相同段：变更上下各留 [keep] 行，中间收成一行 header。
List<DiffLine> diffLines(String? oldText, String newText, {int keep = 3}) {
  final a = oldText == null ? const <String>[] : oldText.split('\n');
  final b = newText.split('\n');
  if (a.isEmpty && b.length == 1 && b[0].isEmpty) return const [];
  if (a.length * b.length > kDiffCellCap) {
    return [
      DiffLine(DiffLineType.header, '（文件过大，diff 退化为整文件替换：'
          '旧 ${a.length} 行 → 新 ${b.length} 行）'),
      ...a.map((l) => DiffLine(DiffLineType.del, '-$l')),
      ...b.map((l) => DiffLine(DiffLineType.add, '+$l')),
    ];
  }
  // LCS 反查操作序列
  final dp = List.generate(a.length + 1, (_) => List<int>.filled(b.length + 1, 0));
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      dp[i][j] = a[i] == b[j]
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  final ops = <DiffLine>[];
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      ops.add(DiffLine(DiffLineType.context, ' ${a[i]}'));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      ops.add(DiffLine(DiffLineType.del, '-${a[i]}'));
      i++;
    } else {
      ops.add(DiffLine(DiffLineType.add, '+${b[j]}'));
      j++;
    }
  }
  while (i < a.length) {
    ops.add(DiffLine(DiffLineType.del, '-${a[i]}'));
    i++;
  }
  while (j < b.length) {
    ops.add(DiffLine(DiffLineType.add, '+${b[j]}'));
    j++;
  }
  // 折叠长 context 段：段贴文件头则不憋头、贴文件尾则不憋尾
  final out = <DiffLine>[];
  var runStart = -1;
  for (var k = 0; k <= ops.length; k++) {
    final isCtx = k < ops.length && ops[k].type == DiffLineType.context;
    if (isCtx) {
      if (runStart < 0) runStart = k;
      continue;
    }
    if (runStart >= 0) {
      final run = k - runStart;
      final head = runStart > 0 ? keep : 0; // 段首贴着变更才留头
      final tail = k < ops.length ? keep : 0; // 段尾贴着变更才留尾
      if (head + tail >= run) {
        out.addAll(ops.sublist(runStart, k));
      } else {
        if (head > 0) out.addAll(ops.sublist(runStart, runStart + head));
        out.add(DiffLine(DiffLineType.header, '… ${run - head - tail} 行相同 …'));
        if (tail > 0) out.addAll(ops.sublist(k - tail, k));
      }
      runStart = -1;
    }
    if (k < ops.length) out.add(ops[k]); // 变更行本身必须进结果
  }
  return out;
}

enum ProposalStatus { pending, approved, rejected, applied, failed }

class Proposal {
  Proposal({required this.path, required this.newContent});

  /// 相对工作区根的路径（协议原样，审批页展示用）。
  final String path;
  final String newContent;

  /// null = 磁盘上没有该文件（新建）。
  String? oldContent;
  List<DiffLine> diff = const [];
  ProposalStatus status = ProposalStatus.pending;
  String? error;

  String get fingerprint => '$path:${newContent.length}:'
      '${newContent.hashCode}';
}

/// 文件读写做成可注入：widget 测试跑在 FakeAsync 里，真 IO 永远不会完成
/// （B1 已经踩过这个坑），所以测试喂内存表；真机默认走 dart:io。
typedef FileRead = Future<String?> Function(String absPath);
typedef FileWrite = Future<void> Function(String absPath, String content);

Future<String?> _ioRead(String absPath) async {
  final f = File(absPath);
  return await f.exists() ? await f.readAsString(encoding: utf8) : null;
}

Future<void> _ioWrite(String absPath, String content) async {
  final f = File(absPath);
  await f.parent.create(recursive: true);
  await f.writeAsString(content, encoding: utf8, flush: true);
}

/// 提案收集与审批执行。唯一会写盘的地方是 [apply]。
class ProposalStore extends ChangeNotifier {
  ProposalStore({required this.rootPath, FileRead? read, FileWrite? write})
      : _read = read ?? _ioRead,
        _write = write ?? _ioWrite;

  final String rootPath;
  final FileRead _read;
  final FileWrite _write;
  final List<Proposal> proposals = [];

  List<Proposal> get pending =>
      proposals.where((p) => p.status == ProposalStatus.pending).toList();

  /// 从一段 agent 文本里收提案。同 fingerprint 去重（result 会重复 message 内容）；
  /// 同 path 且仍 pending 的旧提案被新提案替换（agent 改主意了，留最新版）。
  Future<int> ingestText(String text) async {
    final blocks = parsePatchBlocks(text);
    var added = 0;
    for (final b in blocks) {
      final p = Proposal(path: b.path, newContent: b.content);
      if (proposals.any((x) => x.fingerprint == p.fingerprint)) continue;
      proposals.removeWhere(
          (x) => x.path == p.path && x.status == ProposalStatus.pending);
      final abs = resolveWithinRoot(rootPath, p.path);
      if (abs == null) {
        p.status = ProposalStatus.failed;
        p.error = '路径越界或非法，拒绝纳入审批';
        p.diff = const [];
      } else {
        p.oldContent = await _read(abs);
        p.diff = diffLines(p.oldContent, p.newContent);
      }
      proposals.add(p);
      added++;
    }
    if (added > 0) notifyListeners();
    return added;
  }

  /// 批准 = 这里写盘（utf8、无 BOM、不做任何换行翻译）。再次做越界校验，
  /// 不信 ingest 时的结论（根可能已换）。
  Future<bool> apply(Proposal p) async {
    if (p.status != ProposalStatus.pending &&
        p.status != ProposalStatus.approved) {
      return false;
    }
    final abs = resolveWithinRoot(rootPath, p.path);
    if (abs == null) {
      p.status = ProposalStatus.failed;
      p.error = '路径越界，拒绝落盘';
      notifyListeners();
      return false;
    }
    try {
      await _write(abs, p.newContent);
      p.status = ProposalStatus.applied;
      notifyListeners();
      return true;
    } catch (e) {
      p.status = ProposalStatus.failed;
      p.error = '$e';
      notifyListeners();
      return false;
    }
  }

  /// 拒绝 = 只改状态。磁盘从头到尾没被碰过。
  void reject(Proposal p) {
    if (p.status != ProposalStatus.pending) return;
    p.status = ProposalStatus.rejected;
    notifyListeners();
  }
}
