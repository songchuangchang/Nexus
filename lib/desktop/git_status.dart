/// S2：git status → 文件树行内标记（ZCode 口径：未跟踪绿名 + 行末 `U`，
/// 已改行末 `•`，含改动的祖先目录也出圆点）。
///
/// 这一层只做「状态 → 标记」的纯映射，不碰界面也不碰 git 调用
/// （解析在 git_panel.dart 的 parsePorcelain，执行在 GitService）。
library;

import 'git_panel.dart';

enum GitMark { untracked, modified }

/// porcelain 条目 → 相对路径 → 标记。未跟踪 = `U`，其它非空状态 = `•`。
Map<String, GitMark> marksFromStatus(List<GitStatusEntry> entries) {
  final out = <String, GitMark>{};
  for (final e in entries) {
    out[_norm(e.path)] = e.isUntracked ? GitMark.untracked : GitMark.modified;
  }
  return out;
}

String _norm(String p) => p.replaceAll(r'\', '/');

/// 树要用的标记集合：文件级标记 + 「后代有改动」的目录集合。
class GitMarks {
  GitMarks._(this._files, this._dirs, this.root);

  factory GitMarks.fromPaths(Map<String, GitMark> files, {String? root}) {
    final dirs = <String>{};
    for (final p in files.keys) {
      var i = p.lastIndexOf('/');
      while (i > 0) {
        dirs.add(p.substring(0, i));
        i = p.lastIndexOf('/', i - 1);
      }
    }
    return GitMarks._(Map.unmodifiable(files), Set.unmodifiable(dirs),
        root == null ? null : _norm(root));
  }

  factory GitMarks.empty() => GitMarks._(const {}, const {}, null);

  final Map<String, GitMark> _files;
  final Set<String> _dirs;

  /// 工作区根；给了它才能把树里的绝对路径折成相对键。
  final String? root;

  bool get isEmpty => _files.isEmpty;

  String _rel(String path, String? rootOverride) {
    var p = _norm(path);
    final r = rootOverride == null ? root : _norm(rootOverride);
    if (r != null && r.isNotEmpty) {
      final base = r.endsWith('/') ? r.substring(0, r.length - 1) : r;
      if (p.length > base.length &&
          p.substring(0, base.length).toLowerCase() == base.toLowerCase()) {
        p = p.substring(base.length);
      }
    }
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    return p;
  }

  /// 文件标记；无改动返回 null。
  GitMark? fileMark(String path, {String? root}) {
    final k = _rel(path, root);
    return _files[k];
  }

  /// 目录下是否有任何改动（决定圆点）。
  bool dirMark(String path, {String? root}) => _dirs.contains(_rel(path, root));

  @override
  bool operator ==(Object other) =>
      other is GitMarks &&
      other._files.length == _files.length &&
      other._dirs.length == _dirs.length &&
      other.root == root;

  @override
  int get hashCode => Object.hash(_files.length, _dirs.length, root);
}
