/// B1 文件树：惰性加载 + 可见节点拍平，滚动只走 ListView.builder。
/// 目录子项在展开时才 list；拍平表只在展开/折叠时重建。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'git_status.dart';
import 'workbench_theme.dart';

/// 永不进树的目录名（构建产物与 VCS 内脏）。
const Set<String> kTreeSkipDirs = {
  '.git',
  '.dart_tool',
  '.gradle',
  '.idea',
  '.vscode',
  'build',
  'node_modules',
};

class FileTreeNode {
  FileTreeNode({
    required this.path,
    required this.name,
    required this.isDir,
    required this.depth,
  });

  final String path;
  final String name;
  final bool isDir;
  final int depth;
  bool expanded = false;

  /// null = 尚未加载；空列表 = 已加载但为空目录。
  List<FileTreeNode>? children;
}

class FileTreeModel extends ChangeNotifier {
  FileTreeModel(String rootPath)
      : rootPath = rootPath,
        rootNode = FileTreeNode(
          path: rootPath,
          name: rootPath
              .replaceAll(r'\', '/')
              .split('/')
              .where((s) => s.isNotEmpty)
              .last,
          isDir: true,
          depth: -1, // 根节点不进可见列表，子项从 depth 0 起
        );

  final String rootPath;

  /// 持久根节点：children 缓存挂在它身上，重复 open 不丢。
  final FileTreeNode rootNode;
  final List<FileTreeNode> visible = [];

  /// 树骨架是否已加载过至少一次（bench 用来判「首帧」）。
  bool get loaded => _loaded;
  bool _loaded = false;

  int get fileCount => _fileCount;
  int _fileCount = 0;

  Future<void> open() async {
    await _ensureChildren(rootNode);
    rootNode.expanded = true;
    _rebuild();
  }

  Future<void> toggle(FileTreeNode node) async {
    if (!node.isDir) return;
    node.expanded = !node.expanded;
    if (node.expanded) {
      await _ensureChildren(node);
    }
    _rebuild();
  }

  Future<void> _ensureChildren(FileTreeNode node) async {
    node.children ??= await _listChildren(node);
  }

  /// bench 用：整棵树全展开，最后只重建一次拍平表。
  Future<void> expandAll() async {
    Future<void> walk(FileTreeNode node) async {
      if (!node.isDir) return;
      await _ensureChildren(node);
      node.expanded = true;
      for (final c in node.children!) {
        await walk(c);
      }
    }

    await walk(rootNode);
    _rebuild();
  }

  Future<List<FileTreeNode>> _listChildren(FileTreeNode node) async {
    final dir = Directory(node.path);
    final dirs = <FileTreeNode>[];
    final files = <FileTreeNode>[];
    try {
      await for (final e in dir.list(followLinks: false)) {
        final name = e.path.replaceAll(r'\', '/').split('/').last;
        if (e is Directory) {
          if (kTreeSkipDirs.contains(name)) continue;
          dirs.add(FileTreeNode(
              path: e.path, name: name, isDir: true, depth: node.depth + 1));
        } else if (e is File) {
          files.add(FileTreeNode(
              path: e.path, name: name, isDir: false, depth: node.depth + 1));
        }
      }
    } on FileSystemException {
      // 坏符号链接/断开的 junction/权限拒绝：当空目录处理，不许拖垮整棵树。
      return const [];
    }
    int byName(FileTreeNode a, FileTreeNode b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    dirs.sort(byName);
    files.sort(byName);
    return [...dirs, ...files];
  }

  void _rebuild() {
    visible.clear();
    _fileCount = 0;
    void walk(FileTreeNode n) {
      visible.add(n);
      if (!n.isDir) _fileCount++;
      if (n.isDir && n.expanded && n.children != null) {
        for (final c in n.children!) {
          walk(c);
        }
      }
    }

    final kids = rootNode.children;
    if (rootNode.expanded && kids != null) {
      for (final n in kids) {
        walk(n);
      }
    }
    _loaded = true;
    notifyListeners();
  }
}

class FileTreeView extends StatefulWidget {
  const FileTreeView({
    super.key,
    required this.model,
    required this.onOpenFile,
    this.scrollController,
    this.selectedPath,
    this.marks,
    this.diagCounts,
  });

  final FileTreeModel model;
  final ValueChanged<String> onOpenFile;
  final ScrollController? scrollController;

  /// 当前在查看器里打开的文件（树里给选中底色）。
  final String? selectedPath;

  /// S2：git 状态行内标记（`U` / `•`）。null 或空 = 不画。
  final GitMarks? marks;

  /// P11-2 块 3：诊断计数（键＝`/` 分隔的路径）。没有键或 0 ⇒ 不画——
  /// "语言服务器还没上报"与"上报了 0 条"都不该在树上留数（真话纪律）。
  final Map<String, int>? diagCounts;

  @override
  State<FileTreeView> createState() => _FileTreeViewState();
}

class _FileTreeViewState extends State<FileTreeView> {
  String? _hoverPath;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.model.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final c = WbColors.of(context);
    final nodes = widget.model.visible;
    return ListView.builder(
      controller: widget.scrollController,
      itemCount: nodes.length,
      itemExtent: WbSize.treeRowH,
      itemBuilder: (context, i) {
        final node = nodes[i];
        final icon = node.isDir
            ? (node.expanded ? Icons.folder_open : Icons.folder_outlined)
            : Icons.insert_drive_file_outlined;
        final selected =
            !node.isDir && node.path == widget.selectedPath;
        final hovered = node.path == _hoverPath;
        final bg = selected
            ? c.rowSelected
            : hovered
                ? c.rowHover
                : const Color(0x00000000);
        // S2：行内 git 标记。未跟踪绿名，已改与含改动的目录走行末徽标。
        final marks = widget.marks;
        // P11-2 块 3：这一份文件的诊断条数（只有被上报过才有值；目录不亮数——
        // 上报是按文件来的，冒到目录上就成了假数）。
        final counts = widget.diagCounts;
        final diagCount = (node.isDir || counts == null)
            ? null
            : counts[node.path.replaceAll(r'\', '/')];
        GitMark? mark;
        var dirChanged = false;
        if (marks != null && !marks.isEmpty) {
          if (node.isDir) {
            dirChanged = marks.dirMark(node.path);
          } else {
            mark = marks.fileMark(node.path);
          }
        }
        final nameColor = selected
            ? c.accent
            : mark == GitMark.untracked
                ? c.ok
                : c.textPrimary;
        return MouseRegion(
          onEnter: (_) => setState(() => _hoverPath = node.path),
          onExit: (_) => setState(() => _hoverPath = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (node.isDir) {
                widget.model.toggle(node);
              } else {
                widget.onOpenFile(node.path);
              }
            },
            // 单段落成行（图标字形并进 Text.rich）：一行一次文本排版，
            // 不是 Icon+Text 两次——快速滚动时每帧几十行，差一倍排版量。
            // 底色由外层 ColoredBox 画，与文字排版互不牵扯。
            child: ColoredBox(
              color: bg,
              child: Padding(
                padding: EdgeInsets.only(
                    left: 8.0 + node.depth * WbSize.treeIndent, right: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: String.fromCharCode(icon.codePoint),
                              style: TextStyle(
                                fontFamily: icon.fontFamily,
                                package: icon.fontPackage,
                                fontSize: 15,
                                color: node.isDir
                                    ? c.textSecondary
                                    : c.textTertiary,
                              ),
                            ),
                            TextSpan(
                              text: '  ${node.name}',
                              style: WbText.ui13.copyWith(color: nameColor),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // 行末状态槽固定宽（ZCode 口径：U=未跟踪，•=已改/目录含改动）。
                    SizedBox(
                      width: WbSize.treeBadgeW,
                      child: Center(
                        child: mark == GitMark.untracked
                            ? Text('U',
                                style: WbText.ui11.copyWith(color: c.ok))
                            : (mark == GitMark.modified || dirChanged)
                                ? Text('•',
                                    style:
                                        WbText.ui11.copyWith(color: c.warn))
                                : null,
                      ),
                    ),
                    // P11-2 块 3：诊断计数槽。宽度复用同一个令牌 ⇒ 不新增尺寸
                    // 所有者；只在语言服务器**真上报过**且条数 >0 时画。
                    SizedBox(
                      width: WbSize.treeBadgeW,
                      child: Center(
                        child: (diagCount == null || diagCount <= 0)
                            ? null
                            : Text('$diagCount',
                                key: const Key('wb.treeDiagBadge'),
                                style: WbText.ui11.copyWith(color: c.danger)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
