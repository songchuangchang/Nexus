/// P11-1：代码预览的 LSP 诊断条。
///
/// 为什么单独成文件而不是塞进 `workbench_screen.dart`：**生命周期绑在挂载/卸载
/// 上**——预览收起、切档、切根都会让这个 widget 离开树，`dispose()` 里收掉语言
/// 服务器进程，不需要壳层在三个地方各记一笔手工停启（`_previewCode` 已经 30 多行，
/// 再加起停/订阅/失败态会把它变成第二套状态机）。展示与收口放在同一处，
/// 「不留孤儿进程」这条才有一个能盯住的落点。
///
/// 真话纪律（第 13 回合派单点 4）：探针实测**干净文件 90 秒内一条
/// publishDiagnostics 都不发** ⇒ 「没启动」「还在算」都不能写成「0 条」；
/// 计数徽标只在服务端真的上报过之后才出现。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'lsp_client.dart';
import 'workbench_theme.dart';

/// 本机 dart language-server 的可执行文件解析（给默认工厂用）。
///
/// P11-2 块 1：**四级顺序**，全落空才返回 null ⇒ 上层显示「诊断服务未启动」，
/// 不装作跑过、也不退回「0 条」。打包版没有 `bin/cache/` 那套开发期布局，
/// 所以第②级（PATH）是这一刀的主角：
/// ① `AICHAT_DART_EXE`（最高优先，保留）
/// ② **PATH 里逐个目录**找 `dart`/`dart.exe` 条目，命中就取**它同级**的
///    `cache/dart-sdk/bin/dart.exe`（本机实测：`where dart` → `<flutter SDK>\
///    flutter\bin\dart`，而 `...\bin\cache\dart-sdk\bin\dart.exe` 确实存在）
/// ③ `FLUTTER_ROOT`（`flutter.bat` 设的那个；app 进程读不读得到是运行时事实，
///    读数写在心跳里，不靠它兜底）
/// ④ 沿自身 exe 的祖先目录扫描（开发期 `flutter test` 就靠这条，留作兜底）
///
/// 三个参数都可注入 ⇒ 测试能造"只有 shim 的目录"，不依赖跑它这台机恰好有 SDK。
String? resolveDartLanguageServer({
  List<String>? pathDirs,
  Map<String, String>? env,
  String? selfExecutable,
}) {
  final sep = Platform.pathSeparator;
  String join(String a, String b) => '$a$sep$b';
  // SDK 布局固定是 `<binDir>/cache/dart-sdk/bin/dart(.exe)`。
  String? sdkUnder(String binDir) {
    for (final name in const ['dart.exe', 'dart']) {
      final p = join(join(join(join(binDir, 'cache'), 'dart-sdk'), 'bin'), name);
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  final environment = env ?? Platform.environment;
  // ① 显式指定优先。
  final explicit = environment['AICHAT_DART_EXE'];
  if (explicit != null && explicit.isNotEmpty && File(explicit).existsSync()) {
    return explicit;
  }
  // ② PATH：命中 shim ⇒ 取它同级的 SDK（打包版唯一的可用来源）。
  final dirs = pathDirs ??
      (environment['PATH'] ?? '')
          .split(Platform.isWindows ? ';' : ':')
          .where((d) => d.trim().isNotEmpty)
          .toList();
  for (final d in dirs) {
    for (final name in const ['dart.exe', 'dart']) {
      final entry = join(d, name);
      if (!File(entry).existsSync()) continue;
      final hit = sdkUnder(File(entry).parent.path);
      if (hit != null) return hit;
    }
  }
  // ③ FLUTTER_ROOT。
  final root = environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) {
    final hit = sdkUnder(join(root, 'bin'));
    if (hit != null) return hit;
  }
  // ④ 祖先扫描（开发期命中；也保住"以前能起"的那条路）。
  var dir = File(selfExecutable ?? Platform.resolvedExecutable).parent;
  for (var i = 0; i < 8; i++) {
    final hit = sdkUnder(join(dir.path, 'bin'));
    if (hit != null) return hit;
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  return null;
}

/// P11-2 块 2：扩展名 → 语言项的映射表（「装了才亮、没装点名说清」的骨架）。
///
/// **今天只有 dart 一项 `wired: true`** ——即我们真的起了它、订阅它的诊断。
/// 其余项是"表里有名字、PATH 上探一探这台机装没装"：
/// · 没探到 ⇒ UI 说「这台机没装 X 语言服务器」；
/// · 探到了 ⇒ UI 说「X 语言服务器已探到，这一版还没接进诊断条」。
/// 两种都不是「0 条」，也不是「正在安装」——**装东西归用户，本表不提供任何自装路径**，
/// 也不在这里启动非 dart 的进程（那是下一刀的事，且要先过 A 的口径）。
class LangSpec {
  const LangSpec({
    required this.label,
    required this.wired,
    this.serverCommands = const [],
  });

  /// 给人看的语言名（句子要点名到它）。
  final String label;

  /// 这一版是否真接了生命周期（起停＋订阅）。
  final bool wired;

  /// 只探测用的候选可执行名（PATH 上找，不安装、不启动）。
  final List<String> serverCommands;
}

const Map<String, LangSpec> kLangSpecs = {
  '.dart': LangSpec(label: 'Dart', wired: true),
  '.py': LangSpec(
      label: 'Python',
      wired: false,
      serverCommands: ['pyright-langserver.exe', 'pyright-langserver']),
  '.ts': LangSpec(
      label: 'TypeScript',
      wired: false,
      serverCommands: [
        'typescript-language-server.exe',
        'typescript-language-server'
      ]),
  '.tsx': LangSpec(
      label: 'TypeScript/React',
      wired: false,
      serverCommands: [
        'typescript-language-server.exe',
        'typescript-language-server'
      ]),
};

/// 小写扩展名（带点）；没扩展名返回空串。壳层与映射表都靠它，别各写一份。
String extensionOf(String path) {
  final name = path.replaceAll(r'\', '/').split('/').last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot).toLowerCase();
}

/// 只在 PATH 上**探**某个可执行文件在不在（不装、不跑）。
String? findOnPath(String name, {List<String>? dirs}) {
  final list = dirs ??
      (Platform.environment['PATH'] ?? '')
          .split(Platform.isWindows ? ';' : ':')
          .where((d) => d.trim().isNotEmpty)
          .toList();
  for (final d in list) {
    final p = '$d${Platform.pathSeparator}$name';
    if (File(p).existsSync()) return p;
  }
  return null;
}

String _uriOf(String path) =>
    'file:///${path.replaceAll(r'\', '/').replaceAll(' ', '%20')}';

class LspDiagnosticsPanel extends StatefulWidget {
  const LspDiagnosticsPanel({
    super.key,
    required this.cwd,
    required this.path,
    required this.text,
    required this.colors,
    this.factory,
    this.resolver,
    this.onTapDiagnostic,
    this.onReport,
  });

  final String cwd;
  final String path;
  final String text;
  final WbColors colors;

  /// 测试注入用（照 `DesktopWorkbenchScreen.lspFactory` 那条既有路子）；
  /// null = 走 `resolveDartLanguageServer()` 的真解析。
  final LspClient Function(String cwd)? factory;

  /// P11-2 块 1 的注入位（骨架：这一版先收下、不接线，红测试跑完再接）：
  /// 让"这台机没有可用语言服务器"那条 UI 路径可被确定地测，而不是碰运气。
  final String? Function()? resolver;

  final void Function(LspDiagnostic d)? onTapDiagnostic;

  /// P11-2 块 3：诊断计数**按文件**上报给壳层（壳层才能既在预览标签、又在文件树
  /// 行上标出"哪一份有几条"）。只在服务端真上报之后才调 ⇒ 没上报过的文件不亮数。
  final void Function(String path, int count)? onReport;

  @override
  State<LspDiagnosticsPanel> createState() => _LspDiagnosticsPanelState();
}

enum _LspPhase { off, starting, running, failed }

class _LspDiagnosticsPanelState extends State<LspDiagnosticsPanel> {
  LspClient? _client;
  StreamSubscription<(String, List<LspDiagnostic>)>? _sub;
  _LspPhase _phase = _LspPhase.off;
  String _note = '';
  List<LspDiagnostic> _reported = const [];
  var _gotReport = false;
  var _version = 1;
  var _expanded = true;

  /// 这份文件在映射表里的语言项（扩展名不认识 ⇒ null）。
  LangSpec? get _spec => kLangSpecs[extensionOf(widget.path)];

  /// 只有 `wired: true` 的语言才真起进程（今天＝dart 一项，别的不自装自启）。
  bool get _wired => _spec?.wired ?? false;

  /// 表里有名字但这一版没接 ⇒ 句子点名到语言。措辞跟着"PATH 上探没探到"变，
  /// 不写「正在安装」（装东西归用户），也不写「0 条」（那是查过没问题的假话）。
  String _unwiredReason() {
    final spec = _spec;
    if (spec == null) return '这类文件还没接诊断服务';
    final installed = spec.serverCommands.any((c) => findOnPath(c) != null);
    return installed
        ? '${spec.label} 语言服务器已探到，但这一版还没接进诊断条'
        : '这台机没装 ${spec.label} 语言服务器（我们不代装）';
  }

  /// P11-1 返修（A2 16:01 退件点）：`LspClient.running` 就是 `_proc != null`，
  /// 握手那 0.4–2 秒里恒 false ⇒ 「拿 running 决定要不要再起」会在父级任何一次
  /// 普通 setState 上重复开一扇，而 `_client` 只有一个坑位，被顶掉的那个进程后来
  /// 没人 dispose。标志在**任何 await 之前**同步置位，不看 await 之后的状态。
  bool _startInFlight = false;

  /// State 已 dispose：此刻还在 await 里的那一扇起完必须自己收掉，不留孤儿。
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    if (_wired) unawaited(_start());
  }

  @override
  void didUpdateWidget(LspDiagnosticsPanel old) {
    super.didUpdateWidget(old);
    if (!_wired) {
      final c = _client;
      if (c != null) unawaited(_stop(c));
      return;
    }
    // 握手在飞 ⇒ 什么都不做（重建不等于"没启动"）；已判失败也不在每次重建上重试
    // ——换文件会随 `ValueKey('lsp:<路径>')` 重建 State，那才是自然的重试点。
    if (_startInFlight || _phase == _LspPhase.failed) return;
    final c = _client;
    if (c == null || !c.running) {
      unawaited(_start());
      return;
    }
    // 同一个文件被重新读取（内容变了）：走全量 didChange，不重复 didOpen。
    if (old.text != widget.text) {
      _version++;
      unawaited(c
          .didChange(uri: _uriOf(widget.path), text: widget.text, version: _version));
    }
  }

  Future<void> _start() async {
    if (_startInFlight) return;
    _startInFlight = true;
    try {
      await _stop(_client);
      if (_disposed) return;
      if (mounted) {
        setState(() {
          _phase = _LspPhase.starting;
          _note = '';
          _reported = const [];
          _gotReport = false;
        });
      }
      final LspClient client;
      try {
        if (widget.factory != null) {
          client = widget.factory!(widget.cwd);
        } else {
          final exe = (widget.resolver ?? resolveDartLanguageServer)();
          if (exe == null) {
            throw StateError('这台机的四级解析全落空（AICHAT_DART_EXE／PATH／'
                'FLUTTER_ROOT／祖先扫描都没找到 dart language-server）');
          }
          client = LspClient(
              command: exe,
              args: const ['language-server', '--protocol=lsp'],
              cwd: widget.cwd);
        }
      } on Object catch (e) {
        if (mounted) {
          setState(() {
            _phase = _LspPhase.failed;
            _note = '本机没有可用的 dart language-server：$e';
          });
        }
        return;
      }
      if (_disposed) {
        // 卸载发生在 await 期间：这一句是这条路唯一的收口点。
        await client.dispose();
        return;
      }
      _client = client;
      _sub = client.diagnostics.listen(_onDiagnostics);
      try {
        await client.start();
        await client.initialize(rootUri: _uriOf(widget.cwd));
        await client.didOpen(
            uri: _uriOf(widget.path),
            languageId: 'dart',
            text: widget.text,
            version: _version);
        if (mounted) setState(() => _phase = _LspPhase.running);
      } on Object catch (e) {
        if (mounted) {
          setState(() {
            _phase = _LspPhase.failed;
            _note = '握手失败：$e';
          });
        }
        // 不管挂在不在树上都要 dispose：`if (!mounted) return;` 放在前面
        // 就等于把这一句跳过，那个进程再没人管。
        await _stop(client);
      }
    } finally {
      _startInFlight = false;
    }
  }

  /// 只在自己确实是当前句柄时才清坑位（P2 给 `_historyWaiters` 用过的同一把尺）：
  /// 否则先起那路的收尾会把后来者的句柄抹掉，那个进程就再没人 dispose。
  Future<void> _stop(LspClient? c) async {
    if (c == null) return;
    if (identical(_client, c)) {
      final sub = _sub;
      _sub = null;
      _client = null;
      await sub?.cancel();
    }
    await _disposeQuietly(c);
  }

  /// `LspClient.dispose()` 对**已经退出**的进程会抛（shutdown 要往关掉的管道里写）。
  /// 到这一步我们的目的（进程没了）已经达成，所以吞掉是对的：不吞，异常会从
  /// `unawaited(_start())` 或 `State.dispose()` 逃成 zone 里的未处理错误
  /// ——A1 16:35 手尾①，块 4 用例用 `dart --version`（立刻退出）把它确定性造出来。
  Future<void> _disposeQuietly(LspClient c) async {
    try {
      await c.dispose();
    } on Object catch (_) {/* 已退出：不用再抛 */}
  }

  @override
  void dispose() {
    _disposed = true;
    final c = _client;
    final sub = _sub;
    _client = null;
    _sub = null;
    unawaited(sub?.cancel());
    if (c != null) unawaited(_disposeQuietly(c));
    super.dispose();
  }

  void _onDiagnostics((String, List<LspDiagnostic>) e) {
    if (e.$1 != _uriOf(widget.path)) return;
    if (!mounted) return;
    setState(() {
      _gotReport = true;
      _reported = e.$2;
    });
    // P11-2 块 3：把「这一份有几条」报给壳层——预览标签与文件树行都从壳层取数，
    // 数才只属于它代表的那一份文件（上报之后才有数，没上报过就是不亮）。
    widget.onReport?.call(widget.path, e.$2.length);
  }

  Color _sevColor(int severity, WbColors c) => switch (severity) {
        2 => c.warn,
        3 => c.accent,
        4 => c.textTertiary,
        _ => c.danger,
      };

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    if (!_wired) {
      return _line(c, '诊断服务未启动', reason: _unwiredReason());
    }
    if (_phase == _LspPhase.failed) {
      return _line(c, '诊断服务未启动', reason: _note, color: c.warn);
    }
    if (!_gotReport) {
      // 还在算：不报条数，也不闪 0（探针实测干净文件根本不上报）。
      return _line(c, '诊断服务在算…', reason: '还没收到上报，先不报条数',
          color: c.textTertiary);
    }
    if (_reported.isEmpty) {
      return _line(c, '诊断已上报 0 条', reason: '这是语言服务器报的，不是没查',
          color: c.textTertiary);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
          child: Row(
            children: [
              Text('诊断',
                  style: WbText.ui11.copyWith(color: c.textSecondary)),
              const SizedBox(width: 6),
              GestureDetector(
                // 徽标＝服务端上报的条数；只在上报之后才在场（真话纪律）。
                key: const Key('wb.lspBadge'),
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _expanded = !_expanded),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: c.accentSoft,
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: c.accent),
                  ),
                  child: Text('${_reported.length}',
                      style: WbText.ui11.copyWith(color: c.accent)),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(_expanded ? '折叠' : '展开',
                      style: WbText.ui11.copyWith(color: c.accent)),
                ),
              ),
            ],
          ),
        ),
        if (_expanded)
          // 局部最大高度，写法同 agent_panel 的 diff 块（maxHeight: 260）：
          // 不新增令牌、不新增时长，也不给行高造第二把尺。
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 120),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 4),
              itemCount: _reported.length,
              itemBuilder: (context, i) {
                final d = _reported[i];
                return GestureDetector(
                  key: Key('wb.diagItem$i'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onTapDiagnostic?.call(d),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 1, 10, 1),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // LspDiagnostic 的行/列是 LSP 的 0 基 ⇒ 显示一律 +1。
                        Text('第 ${d.startLine + 1} 行',
                            style: WbText.ui11
                                .copyWith(color: _sevColor(d.severity, c))),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            d.message.split('\n').first,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: WbText.ui11.copyWith(color: c.textPrimary),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        Divider(height: 1, color: c.border),
      ],
    );
  }

  Widget _line(WbColors c, String status, {String? reason, Color? color}) =>
    Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WbText.ui11.copyWith(color: color ?? c.textTertiary)),
          if (reason != null && reason.isNotEmpty)
            Text(reason,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WbText.ui11.copyWith(color: c.textTertiary)),
        ],
      ),
    );
}
