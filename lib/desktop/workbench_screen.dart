/// S1 桌面工作台壳：左（任务 ⇄ 文件 同槽）· 中（会话）· 右（预览：代码/终端/Review）。
/// 桌面定位 = agent 优先的代码工作台（规格 docs/DESKTOP_IA_SPEC_20260926.html），
/// 底部不再有常驻 git 栏。
///
/// bench 模式（实测数字从这里出，别手抄）：
///   set AICHAT_DESKTOP_BENCH=1
///   set AICHAT_DESKTOP_BENCH_ROOT=<项目目录>
///   set AICHAT_DESKTOP_BENCH_OUT=<结果.json>
///   aichat.exe  →  自动开根目录、全展开树、滚到底、开 builtin 大文件、
///   再造 67k 行合成文件滚一遍，JSON 落盘后退出。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'agent_panel.dart';
import 'bench.dart';
import 'diagnostics_strip.dart';
import 'file_tree.dart';
import 'file_viewer.dart';
import 'gateway_client.dart';
import 'git_graph.dart';
import 'git_panel.dart';
import 'git_status.dart';
import 'lsp_client.dart';
import 'proposals.dart';
import 'pty.dart';
import 'term_tab.dart';
import 'wb_prefs.dart';
import 'workbench_theme.dart';

/// S1 新骨架的结构锚点（test/desktop_ia_test.dart 按名引用）。
const Key kSlotTask = Key('wb.slotTask');
const Key kSlotFile = Key('wb.slotFile');
const Key kCenter = Key('wb.center');
const Key kPreviewShell = Key('wb.previewShell');
const Key kPreviewTabCode = Key('wb.tabCode');
const Key kPreviewTabTerm = Key('wb.tabTerm');
const Key kPreviewTabReview = Key('wb.tabReview');
const Key kOpenPreview = Key('wb.openPreview');
const Key kThemeToggle = Key('wb.themeToggle');

/// S1b：输入卡片顶行（四颗 chip）的结构锚点，desktop_ia_test 按名引用。
const Key kComposerHeader = Key('wb.composerHeader');

/// P3：模板卡结构锚点，三张卡共用；desktop_ia_test 断言 findsNWidgets(3)。
const Key kTemplateCard = Key('wb.templateCard');

/// S1b：权限模式两档（规格 §2 权限模式 chip）。只影响「终端命令与落盘前
/// 是否先问」的档位展示；落盘永远走桌面进程审批流，B2 口径不变。
enum _PermMode { confirm, full }

class DesktopWorkbenchScreen extends StatefulWidget {
  const DesktopWorkbenchScreen({
    super.key,
    this.initialRoot,
    this.gateway,
    this.lspFactory,
    this.lspResolver,
  });

  /// 测试与 bench 用：跳过目录选择直接打开。
  final String? initialRoot;

  /// B2：注入假 gateway 跑审批流；null = 真连本机 gateway（懒建）。
  final GatewayApi? gateway;

  /// P11：注入 LSP 客户端工厂（照 `gateway` 那条既有注入路子），主要给测试
  /// 留一个能观察 `running` 收口的把手。null = 用本机的 dart language-server
  /// 自己解析；解析不到就是「诊断服务未启动」，不装作跑过。
  final LspClient Function(String cwd)? lspFactory;

  /// P11-2 块 1 注入位（骨架：先收下、透传给面板，实装在红测试之后）：
  /// 断「这台机起不来语言服务器」时 UI 说的是什么，不靠碰运气。
  final String? Function()? lspResolver;

  @override
  State<DesktopWorkbenchScreen> createState() => DesktopWorkbenchState();
}

class DesktopWorkbenchState extends State<DesktopWorkbenchScreen> {
  /// 真机默认连本机 gateway；可用 --dart-define 覆盖。
  static const String _gwBase = String.fromEnvironment('AICHAT_GATEWAY_BASE',
      defaultValue: 'http://127.0.0.1:8765');
  static const String _gwSecret = String.fromEnvironment(
      'AICHAT_GATEWAY_SECRET',
      defaultValue: r'<你的 gateway 目录>\.device_secret');

  FileTreeModel? _tree;
  FileDocument? _doc;
  bool _loadingFile = false;

  /// 左栏同槽切换：true = 任务槽（默认），false = 文件槽。
  bool _leftTasks = true;

  /// gateway 是否已连上；连上后中栏才放会话面板。
  bool _connected = false;

  /// 右预览面板：默认收起，点文件 / 点「预览」才开。
  bool _showPreview = false;

  /// 0 = 代码，1 = 终端，2 = Review。
  int _previewTab = 0;

  /// S3：桌面默认深色，浅色保留可切（本轮内存态，持久化在 S6）。
  bool _dark = true;

  /// P5：用户是否抢先切换过——防启动读回的迟到结果盖掉用户操作。
  bool _darkTouched = false;

  String? _rootPath;
  ProposalStore? _store;

  /// P11-2 块 3：诊断计数**按文件**存（`路径 → 条数`），只由面板收到真上报时写。
  /// 没上报过的文件不在表里 ⇒ 不亮数——"未知"和"0 条"是两回事（真话纪律）。
  final Map<String, int> _diagCounts = <String, int>{};

  /// 路径键归一：文件树给的是 OS 分隔符，面板给的是文档路径，统一成 `/`。
  static String diagKey(String path) => path.replaceAll(r'\', '/');

  void _onDiagReport(String path, int count) {
    if (!mounted) return;
    setState(() => _diagCounts[diagKey(path)] = count);
  }
  GatewayApi? _gateway;
  bool _gatewayTried = false;

  /// S2：树行内的 git 状态（非 git 仓 = 空，不报错）。
  GitMarks _marks = GitMarks.empty();

  /// S1b：分支 chip 的数据（_openRoot 与 _refreshMarks 时取；非 git 仓 = null）。
  String? _branch;

  /// S1b：权限模式 chip 的档位（默认变更前确认；完全访问时橙 warn 色）。
  _PermMode _permMode = _PermMode.confirm;

  /// S1b：任务槽真列表（null = 还没拉到；错误与空列表都只说真话）。
  List<GwSession>? _sessions;
  String? _sessionsError;

  /// P2：点任务槽行 → 让中栏面板切到该会话（命令走 GlobalKey，
  /// 当前行高亮数据走 onSessionChanged 回调回来）。
  final _agentPanelKey = GlobalKey<AgentPanelState>();
  String? _panelSid;

  /// P3：点模板卡暂存的文案；AgentPanel 建起（initState 吃进 initialPrompt）
  /// 后由帧尾回调清掉，防面板重建时重填。
  String? _pendingPrompt;

  final _treeScroll = ScrollController();
  final _fileScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // P5：启动读回明暗记录。无记录/读失败 → 落默认暗（_dark 初值即 true），
    // 不弹错；用户已抢先切换过就不拿旧记录覆盖。
    WbPrefs.readDark().then((v) {
      if (!mounted || v == null || _darkTouched) return;
      setState(() => _dark = v);
    });
    final initial = widget.initialRoot;
    if (initial != null) {
      _openRoot(initial);
    }
    if (Platform.environment['AICHAT_DESKTOP_BENCH'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runBench());
    }
    // 真窗口探针：GUI 发布形态没有控制台，ConPTY 的 std 句柄接管要走
    // AllocConsole+SW_HIDE 分支 —— flutter test 覆盖不到，用这个在真进程里量。
    // 两种开法：环境变量，或标记文件 term_probe_cfg.json（放在进程工作目录）
    // （后者给 explorer.exe 起进程用 —— explorer 没有控制台，父进程
    // _attach_ 不上，才会真走到 AllocConsole 分支；debug runner 从控制台
    // 起时会 AttachConsole(父进程)，量不到这条）。
    if (Platform.environment['AICHAT_DESKTOP_TERM_PROBE'] == '1' ||
        File('term_probe_cfg.json').existsSync()) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runTermProbe());
    }
  }

  @override
  void dispose() {
    _treeScroll.dispose();
    _fileScroll.dispose();
    _store?.dispose();
    _gateway?.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null || !mounted) return;
    await _openRoot(path);
  }

  Future<void> _openRoot(String path) async {
    final tree = FileTreeModel(path);
    final old = _store;
    setState(() {
      _tree = tree;
      _rootPath = path;
      _doc = null;
      _store = ProposalStore(rootPath: path);
      _showPreview = false;
      _previewTab = 0;
      _branch = null; // 新根的分支等 _refreshMarks 拉回来再显示
    });
    old?.dispose();
    await tree.open();
    await _refreshMarks(path);
  }

  /// 状态来自 `git status --porcelain=v1`；不是 git 仓就清空标记（不弹错，
  /// 树照常能用）。提案落盘后由 S4 的 Review 流程再调一次。
  /// S1b：同口径顺带取分支名（branch() 非 0 退出返回 null，不抛）。
  Future<void> _refreshMarks(String path) async {
    GitMarks next;
    try {
      next = GitMarks.fromPaths(
          marksFromStatus(await GitService(path).status()),
          root: path);
    } catch (_) {
      next = GitMarks.empty();
    }
    String? branch;
    try {
      branch = await GitService(path).branch();
    } catch (_) {
      branch = null; // git 不可执行等极端情况：chip 显示占位「—」
    }
    if (!mounted) return;
    setState(() {
      _marks = next;
      _branch = branch;
    });
  }

  Future<void> _openFile(String path) async {
    setState(() {
      _loadingFile = true;
      _showPreview = true; // 点文件 = 在右预览里开「代码」标签。
      _previewTab = 0;
    });
    try {
      final doc = await FileDocument.load(path);
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _loadingFile = false;
      });
      if (_fileScroll.hasClients) _fileScroll.jumpTo(0);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingFile = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打不开 $path：$e')),
      );
    }
  }

  /// 连本机 gateway：配对（读 .device_secret）+ WS。连不上就明说，不静默降级。
  Future<void> _connectGateway() async {
    if (_connected) return;
    if (_store == null) {
      // 提案审批的工作区根来自打开的文件夹；没有根就没有审批边界。
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先打开工作区文件夹，再连 gateway')),
      );
      return;
    }
    _gateway ??= widget.gateway ??
        LiveGateway(baseUrl: _gwBase, secretPath: _gwSecret);
    if (!_gatewayTried) {
      _gatewayTried = true;
      try {
        await _gateway!.connect();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连不上本机 gateway（$_gwBase）：$e')),
        );
        return;
      }
    }
    if (!mounted) return;
    setState(() => _connected = true);
    await _loadSessions();
  }

  /// S1b：任务槽真列表 = listSessions()（gateway /api/sessions/snapshot）。
  /// 拉失败或为空都只显示一句真话，不拿假数据填这一栏。
  Future<void> _loadSessions() async {
    final gw = _gateway;
    if (gw == null) return;
    try {
      final sessions = await gw.listSessions();
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _sessionsError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sessions = null;
        _sessionsError = '$e';
      });
    }
  }

  // -------------------------------------------------------------------------
  // bench 驱动（只有 AICHAT_DESKTOP_BENCH=1 才会进来）
  // -------------------------------------------------------------------------

  Future<void> _waitFrame() => SchedulerBinding.instance.endOfFrame;

  /// 空白对照：不滚不动干跑 N 帧。idle 帧的 span 也超预算就说明
  /// spanJank 是流水线重叠造成的测量假象，不是真实渲染成本。
  Future<Map<String, dynamic>> _measureIdle([int frames = 90]) async {
    await _waitFrame();
    final meter = JankMeter();
    final sw = Stopwatch()..start();
    meter.start();
    for (var i = 0; i < frames; i++) {
      SchedulerBinding.instance.scheduleFrame();
      await _waitFrame();
    }
    meter.stop();
    sw.stop();
    return meter.toJson(wallMs: sw.elapsedMilliseconds);
  }

  /// 每帧回调里推进滚动（不等事件回路）：把「事件回路往返拖慢跳频」
  /// 从测量里剔掉，剩下的帧间隔才是界面自己能不能跟上。
  Future<Map<String, dynamic>> _measureScroll(ScrollController c,
      {required double stepPx}) async {
    // 先落一帧，viewportDimension 才有值。必须主动 scheduleFrame：
    // 上一段测量结束界面已静止，干等 endOfFrame 会永久挂起。
    SchedulerBinding.instance.scheduleFrame();
    await _waitFrame();
    final meter = JankMeter();
    final pos = c.position;
    final sw = Stopwatch()..start();
    meter.start();
    c.jumpTo(0);
    var done = false;
    void tick(Duration _) {
      if (done) return;
      if (c.offset >= pos.maxScrollExtent) {
        done = true;
        return;
      }
      final next = c.offset + stepPx;
      c.jumpTo(next > pos.maxScrollExtent ? pos.maxScrollExtent : next);
      SchedulerBinding.instance.scheduleFrameCallback(tick);
    }

    SchedulerBinding.instance.scheduleFrameCallback(tick);
    while (!done) {
      await _waitFrame();
    }
    meter.stop();
    sw.stop();
    return meter.toJson(wallMs: sw.elapsedMilliseconds);
  }

  /// 双口径滚一遍：page = 每帧跳 0.9 屏（按住 PageDown 的压力口径）；
  /// wheel = 每帧 3 行（滚轮人类口径）。文本排版密集型界面这两口径
  /// 差一个量级，报告必须分开写，不许拿压力口径冒充人感卡顿。
  Future<Map<String, dynamic>> _measureScrollDual(ScrollController c,
      {required double wheelPx}) async {
    SchedulerBinding.instance.scheduleFrame();
    await _waitFrame();
    final pos = c.position;
    final pagePx =
        pos.viewportDimension > 0 ? pos.viewportDimension * 0.9 : 400.0;
    return {
      'page': await _measureScroll(c, stepPx: pagePx),
      'wheel': await _measureScroll(c, stepPx: wheelPx),
    };
  }

  Future<Map<String, dynamic>> _benchOpenAndScroll(String path) async {
    final sw = Stopwatch()..start();
    await _openFile(path);
    await _waitFrame();
    final doc = _doc!;
    final r = <String, dynamic>{
      'path': path.replaceAll(r'\', '/'),
      'lines': doc.lines.length,
      'bytes': doc.byteCount,
      'loadMs': doc.loadMs,
      'tokenizeMs': doc.tokenizeMs,
      'firstPaintMs': sw.elapsedMilliseconds,
    };
    r['scroll'] = await _measureScrollDual(_fileScroll, wheelPx: 54);
    return r;
  }

  Future<void> _runBench() async {
    final env = Platform.environment;
    final root = env['AICHAT_DESKTOP_BENCH_ROOT'] ?? Directory.current.path;
    final outPath = env['AICHAT_DESKTOP_BENCH_OUT'] ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}desktop_bench.json';
    final result = <String, dynamic>{
      'root': root.replaceAll(r'\', '/'),
      'mode': const String.fromEnvironment('FLUTTER_BUILD_MODE',
          defaultValue: 'unknown'),
    };
    try {
      // 1) 打开文件夹 → 全展开 → 树首帧
      final sw = Stopwatch()..start();
      await _openRoot(root);
      await _tree!.expandAll();
      await _waitFrame();
      result['tree'] = {
        'visibleNodes': _tree!.visible.length,
        'files': _tree!.fileCount,
        'firstPaintMs': sw.elapsedMilliseconds,
      };
      // 2) 空白对照：不动界面干跑 90 帧，给 spanJank 一个「测量底噪」参照
      result['idle'] = await _measureIdle();
      // 3) 树从头滚到底的卡顿（树行高 24，滚轮口径 3 行/帧 = 72px）
      result['treeScroll'] =
          await _measureScrollDual(_treeScroll, wheelPx: 72);

      // 3) 本仓最大 Dart 文件之一：builtin_plugins.dart（中文/全角/转义俱全）
      final builtin = '$root${Platform.pathSeparator}lib'
          '${Platform.pathSeparator}plugins'
          '${Platform.pathSeparator}builtin_plugins.dart';
      if (File(builtin).existsSync()) {
        result['builtinFile'] = await _benchOpenAndScroll(builtin);
      } else {
        result['builtinFile'] = 'not-found: $builtin';
      }

      // 4) 合成 67k 行大文件（验收口径的规模，本仓没有真文件到这量级）
      final synth = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}bench_67k.dart');
      await synth.writeAsString(buildSynthSource(67000));
      result['synth67k'] = await _benchOpenAndScroll(synth.path);
      await synth.delete();

      await File(outPath).writeAsString(
          const JsonEncoder.withIndent('  ').convert(result));
    } catch (e, st) {
      await File(outPath).writeAsString(jsonEncode({
        'error': '$e',
        'stack': '$st',
        'partial': result,
      }));
    }
    exit(0);
  }

  // -------------------------------------------------------------------------
  // 真窗口探针（只有 AICHAT_DESKTOP_TERM_PROBE=1 才会进来）
  // -------------------------------------------------------------------------

  Completer<WinPty>? _termProbeSpawn;

  /// 量三件事：GUI 进程启动时有没有控制台（应为 false）、终端标签起的
  /// 伪控制台是不是走了 AllocConsole 分支（应为 true）、AllocConsole 之后
  /// 窗口有没有被藏住（consoleVisible 应为 false，即不闪窗）。
  Future<void> _runTermProbe() async {
    var out = Platform.environment['AICHAT_DESKTOP_TERM_PROBE_OUT'] ??
        '${Directory.systemTemp.path}${Platform.pathSeparator}term_probe.json';
    final cfg = File('term_probe_cfg.json');
    if (cfg.existsSync()) {
      try {
        final j = (jsonDecode(cfg.readAsStringSync()) as Map);
        out = (j['out'] as String?) ?? out;
      } catch (_) {/* 配置坏了就用默认路径 */}
    }
    final r = <String, dynamic>{
      'consoleWindowAtStart': hostHasConsole(),
    };
    try {
      _termProbeSpawn = Completer<WinPty>();
      setState(() {
        _showPreview = true;
        _previewTab = 1;
      });
      // 等 onSpawned 回调，不轮询（D1 闸门不许这里出现毫秒字面量）。
      WinPty? pty;
      try {
        pty = await _termProbeSpawn!.future.timeout(const Duration(seconds: 15));
      } on TimeoutException {
        pty = null;
      }
      if (pty == null) {
        r['error'] = 'term tab never spawned a pty';
      } else {
        r['consoleAllocated'] = pty.consoleAllocated;
        r['pid'] = pty.pid;
        await Future<void>.delayed(const Duration(seconds: 3));
        r['aliveAfter3s'] = pty.alive;
        r['consoleVisible'] = hostConsoleVisible();
      }
    } catch (e, st) {
      r['error'] = '$e';
      r['stack'] = '$st';
    }
    await File(out)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(r));
    exit(0);
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // 工作台子树整体换桌面主题（手机端 AppTheme 不动）：底色/发丝线/关水波纹。
    return Theme(
      data: wbTheme(context, dark: _dark),
      child: Builder(builder: _buildThemed),
    );
  }

  Widget _buildThemed(BuildContext context) {
    final c = WbColors.of(context);
    final rootName = _rootPath
        ?.replaceAll(r'\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .last;
    // S1 骨架：左（任务 ⇄ 文件 同槽）· 中（会话，永远在场）· 右（预览，默认收起）。
    // 底部不再有常驻 git 栏（状态归树，审阅归 Review 标签）。
    return Scaffold(
      body: Row(
        children: [
          ColoredBox(
            color: c.sidebarBg,
            child: SizedBox(
              width: WbSize.sidebarW,
              child: _buildLeft(c, rootName),
            ),
          ),
          VerticalDivider(width: 1, color: c.border),
          Expanded(
            child: KeyedSubtree(key: kCenter, child: _buildCenter(c, rootName)),
          ),
          if (_showPreview) ...[
            VerticalDivider(width: 1, color: c.border),
            ColoredBox(
              color: c.sidebarBg,
              child: SizedBox(
                width: WbSize.agentPanelW,
                child: KeyedSubtree(
                    key: kPreviewShell, child: _buildPreview(c)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------- 左栏：任务 ⇄ 文件
  Widget _buildLeft(WbColors c, String? rootName) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
          child: WbToolButton(
            icon: Icons.folder_open,
            label: rootName == null ? '打开文件夹' : '换文件夹',
            onPressed: _pickFolder,
          ),
        ),
        Row(
          children: [
            Expanded(
              child: _WbSlot(
                key: kSlotTask,
                label: '任务',
                selected: _leftTasks,
                onTap: () => setState(() => _leftTasks = true),
              ),
            ),
            Expanded(
              child: _WbSlot(
                key: kSlotFile,
                label: '文件',
                selected: !_leftTasks,
                onTap: () => setState(() => _leftTasks = false),
              ),
            ),
          ],
        ),
        Divider(height: 1, color: c.border),
        Expanded(child: _leftTasks ? _buildTaskSlot(c) : _buildFileSlot(c)),
        Divider(height: 1, color: c.border),
        SizedBox(
          height: 32,
          child: Row(
            children: [
              const SizedBox(width: 4),
              WbToolButton(
                key: kThemeToggle,
                icon: _dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                label: _dark ? '切浅色' : '切深色',
                // P5：切换即写（启动时读回，见 initState）。
                onPressed: () {
                  setState(() => _dark = !_dark);
                  _darkTouched = true;
                  WbPrefs.writeDark(_dark);
                },
              ),
              // P7：Git 图谱模态入口（与既有按钮文案不冲突）。
              WbToolButton(
                icon: Icons.account_tree_outlined,
                label: 'Git 图谱',
                onPressed: _showGitGraph,
              ),
              const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ),
      ],
    );
  }

  /// 任务槽：连上 gateway 前只给连接入口；连上后 = listSessions() 真列表
  /// （标题 + 相对时间）。拉失败或为空只显示一句真话，不造假数据（规格 §7）。
  /// P2：行可点切会话，当前行高亮。
  Widget _buildTaskSlot(WbColors c) {
    if (!_connected) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('未连接 gateway',
                  style: WbText.ui12.copyWith(color: c.textSecondary)),
              const SizedBox(height: 8),
              WbToolButton(
                icon: Icons.link,
                label: '连接 gateway',
                onPressed: _connectGateway,
              ),
            ],
          ),
        ),
      );
    }
    final error = _sessionsError;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text('任务列表拉取失败：$error',
              textAlign: TextAlign.center,
              style: WbText.ui12.copyWith(color: c.textSecondary)),
        ),
      );
    }
    final sessions = _sessions;
    if (sessions == null) {
      return Center(
        child: Text('任务列表读取中…',
            style: WbText.ui12.copyWith(color: c.textTertiary)),
      );
    }
    if (sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text('gateway 上还没有会话。在中栏点「新会话」派活后，这里会列出它。',
              textAlign: TextAlign.center,
              style: WbText.ui12.copyWith(color: c.textTertiary)),
        ),
      );
    }
    // P2：行可点。点击 = 让中栏面板切到该会话（标题/事件过滤/发送目标
    // 一致）；高亮 = onSessionChanged 回报的当前 sid 对上哪行。切不存在的
    // sid 给一句真话，不假装切成功。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: Text('下面是 gateway 的全部会话；点击行切到该会话，高亮为当前。',
              style: WbText.ui11.copyWith(color: c.textTertiary)),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: sessions.length,
            itemBuilder: (context, i) {
              final s = sessions[i];
              final title = s.title.trim().isEmpty ? s.sid : s.title;
              final current = _panelSid == s.sid;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _switchToSession(s),
                child: Container(
                  color: current ? c.rowSelected : null,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WbText.ui12.copyWith(color: c.textPrimary)),
                      Text(_sessionRelTime(s.updatedAt),
                          style: WbText.ui11.copyWith(color: c.textTertiary)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// P2：切会话入口。sid 必须在快照里（行本就来自快照，防御校验）；面板
  /// 还没就绪也明说，不静默吞掉点击。
  void _switchToSession(GwSession s) {
    if (!(_sessions?.any((e) => e.sid == s.sid) ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('会话 ${s.sid} 不在 gateway 快照里，切不过去。')));
      return;
    }
    final panel = _agentPanelKey.currentState;
    if (panel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('会话面板还没就绪，稍后再点。')));
      return;
    }
    panel.switchSession(s.sid);
  }

  Widget _buildFileSlot(WbColors c) {
    final tree = _tree;
    if (tree == null) {
      return Center(
        child: Text('先打开文件夹',
            style: WbText.ui12.copyWith(color: c.textTertiary)),
      );
    }
    return FileTreeView(
      model: tree,
      scrollController: _treeScroll,
      selectedPath: _doc?.path,
      marks: _marks,
      diagCounts: _diagCounts,
      onOpenFile: _openFile,
    );
  }

  // ---------------------------------- 中栏：上下文条 + 会话
  Widget _buildCenter(WbColors c, String? rootName) {
    return Column(
      children: [
        ColoredBox(
          color: c.sidebarBg,
          child: SizedBox(
            height: WbSize.toolbarH,
            child: Row(
              children: [
                const SizedBox(width: 8),
                _WbChip(
                  icon: Icons.folder_outlined,
                  label: rootName ?? '未打开文件夹',
                  onTap: _pickFolder,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _rootPath ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WbText.ui11.copyWith(color: c.textTertiary),
                  ),
                ),
                WbToolButton(
                  key: kOpenPreview,
                  icon: Icons.dashboard_outlined,
                  label: _showPreview ? '收起预览' : '预览',
                  active: _showPreview,
                  onPressed: _rootPath == null
                      ? null
                      : () => setState(() => _showPreview = !_showPreview),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: c.border),
        Expanded(child: _buildConversation(c, rootName)),
      ],
    );
  }

  Widget _buildConversation(WbColors c, String? rootName) {
    final gw = _gateway;
    final store = _store;
    if (_connected && gw != null && store != null) {
      return AgentPanel(
        key: _agentPanelKey,
        gateway: gw,
        store: store,
        workspaceCwd: _rootPath,
        composerHeader: _buildComposerHeader(c, rootName),
        initialPrompt: _pendingPrompt,
        readOnlyMode: _permMode == _PermMode.confirm,
        onSessionChanged: (sid) {
          if (_panelSid != sid) setState(() => _panelSid = sid);
        },
        onOpenReview: () => setState(() {
          _showPreview = true;
          _previewTab = 2;
        }),
      );
    }
    // P3：未连接空态。时段问候 + 大标题 + 一句说明 + 打开文件夹主按钮 +
    // 三张模板卡（全是 agent 真能跑的活）。连接成功后空态整体消失。
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_greeting(),
                  style: WbText.ui12.copyWith(color: c.textTertiary)),
              const SizedBox(height: 6),
              Text('把活交给 agent，你只管验收',
                  style: WbText.ui13.copyWith(
                      color: c.textPrimary, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                  '连上本机 gateway，把要干的活发给 agent；改动会以提案形式回到这里，逐条验收后才落盘。',
                  style: WbText.ui12.copyWith(color: c.textSecondary)),
              const SizedBox(height: 16),
              WbToolButton(
                icon: Icons.folder_open_outlined,
                // 标签避开工具栏既有「打开文件夹」——desktop_workbench_test
                // 的空态用例按精确文本断言 findsOneWidget（该文件不在白名单）。
                label: '打开工作区文件夹',
                onPressed: _pickFolder,
              ),
              const SizedBox(height: 20),
              Text('试试这些（点卡填进输入框）',
                  style: WbText.ui11.copyWith(color: c.textTertiary)),
              const SizedBox(height: 8),
              ..._kTemplatePrompts.map((p) => _templateCard(p, c)),
            ],
          ),
        ),
      ),
    );
  }

  /// P3：时段问候。DateTime.now 真钟点；测试按五时段集合匹配。
  String _greeting() {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 9) return '早上好';
    if (h < 12) return '上午好';
    if (h < 14) return '中午好';
    if (h < 18) return '下午好';
    return '晚上好';
  }

  /// P3：模板卡文案——只许写 agent 真能跑的活（规格 §6 假功能红线）：
  /// 只读检查、目录梳理、起草文档走提案审批。禁 $/# 语法、禁闲时任务。
  static const _kTemplatePrompts = <String>[
    '检查工作区未提交改动，逐文件说明改了什么（只读）',
    '梳理本项目目录结构，说明各目录的职责',
    '帮我起草一份 README 项目简介，改动走审批',
  ];

  Widget _templateCard(String prompt, WbColors c) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _useTemplate(prompt),
      child: Container(
        key: kTemplateCard,
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: c.panelBg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Icon(Icons.description_outlined, size: 14, color: c.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(prompt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: WbText.ui12.copyWith(color: c.textPrimary)),
            ),
            const SizedBox(width: 8),
            Icon(Icons.arrow_forward_outlined, size: 14, color: c.textTertiary),
          ],
        ),
      ),
    );
  }

  /// P7：打开 Git 图谱模态。没打开文件夹先一句真话（图谱需要工作区根）。
  void _showGitGraph() {
    final root = _rootPath;
    if (root == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('先打开工作区文件夹，再打开图谱')));
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: GitGraphModal(
            service: GitService(root), onClose: () => Navigator.pop(ctx)),
      ),
    );
  }

  /// P6：切进完全访问前的确认弹窗（铁律 10：破坏性动作必须确认）。
  /// 确认后切档 + SnackBar 真话——agent 之后直写工作区、不再走审批；
  /// 取消什么都不变。
  Future<void> _confirmFullAccess() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切到完全访问？'),
        content: const Text(
            'agent 的改动将直写工作区，不再经过审批；确认后新发送的消息立即生效。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _permMode = _PermMode.full);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('完全访问已生效：agent 改动直写工作区，不再走审批')));
  }

  /// P4：「＋」= 把当前打开文件的相对路径以 @path 插进输入框光标处。
  /// 真话纪律：插入的只是路径引用文本，文件内容并没有进上下文；
  /// 没有打开的文件就一句真话，不假装能附加。
  void _insertFileReference() {
    final doc = _doc;
    final root = _rootPath;
    if (doc == null || root == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('先在文件树里打开一个文件')));
      return;
    }
    var rel = doc.path;
    if (rel.startsWith(root)) {
      rel = rel.substring(root.length);
    }
    rel = rel.replaceAll('\\', '/');
    while (rel.startsWith('/')) {
      rel = rel.substring(1);
    }
    if (rel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('先在文件树里打开一个文件')));
      return;
    }
    _agentPanelKey.currentState?.insertIntoInput('@$rel');
  }

  /// P3：点模板卡 = 文案最终进输入框的真闭环。没打开文件夹先提示（既有
  /// 口径，_connectGateway 的审批边界依赖根目录）；未连接先走连接流程；
  /// 面板建起时经 initialPrompt 填进输入框，帧尾清掉壳层暂存防重建重填。
  Future<void> _useTemplate(String prompt) async {
    if (_store == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('先打开工作区文件夹，再连 gateway')));
      return;
    }
    _pendingPrompt = prompt;
    if (!_connected) {
      await _connectGateway();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _agentPanelKey.currentState != null) {
        _pendingPrompt = null;
      }
    });
  }

  // ---------------------------------- S1b：输入卡片顶行（四颗 chip）
  /// 项目 / 分支 / 权限模式 / 模型。模型 chip：GatewayApi 不带模型名字段，
  /// 没有数据源就恒灰显「模型 —」——不显示假型号（规格 §2 假功能红线）。
  Widget _buildComposerHeader(WbColors c, String? rootName) {
    final full = _permMode == _PermMode.full;
    return KeyedSubtree(
      key: kComposerHeader,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: _WbChip(
              icon: Icons.folder_outlined,
              label: rootName ?? '未打开文件夹',
              onTap: _pickFolder,
            ),
          ),
          const SizedBox(width: 6),
          _WbChip(
            icon: Icons.call_split,
            label: _branch ?? '—',
            // 非 git 仓（branch() 返回 null）→ 灰显占位「—」。
            color: _branch == null ? c.textTertiary : null,
          ),
          const SizedBox(width: 6),
          _WbChip(
            icon: Icons.add,
            label: '＋',
            // 规格 §2「＋附加 = 引用文件」：把当前打开文件的 @相对路径
            // 插进输入框光标处；插入的只是路径引用文本，不是文件内容。
            onTap: _insertFileReference,
          ),
          const SizedBox(width: 6),
          _WbChip(
            icon:
                full ? Icons.warning_amber_rounded : Icons.back_hand_outlined,
            label: full ? '完全访问' : '变更前确认',
            // 完全访问 = 橙 warn 色（规格 §0 mock 与 §2 权限模式 chip）。
            color: full ? c.warn : null,
            // P6：完全访问已接线（agent 直写、不走审批）——切入是破坏性
            // 动作，先确认弹窗（铁律 10）；切回确认档无需弹窗。
            onTap: () {
              if (!full) {
                _confirmFullAccess();
              } else {
                setState(() => _permMode = _PermMode.confirm);
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已回到变更前确认')));
              }
            },
          ),
          const SizedBox(width: 6),
          _WbChip(
            icon: Icons.memory_outlined,
            label: '模型 —',
            color: c.textTertiary,
          ),
        ],
      ),
    );
  }

  /// 相对时间：updated_at（epoch 秒，服务端 time.time() 口径）与
  /// DateTime.now() 的差值 →「x分 / x小时 / x天」；不足一分（含未来时间
  /// 的时钟偏差）显示「刚刚」。
  static String _sessionRelTime(double updatedAt) {
    final ts =
        DateTime.fromMillisecondsSinceEpoch((updatedAt * 1000).round());
    final diff = DateTime.now().difference(ts);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分';
    if (diff.inHours < 24) return '${diff.inHours}小时';
    return '${diff.inDays}天';
  }

  // ---------------------------------- 右栏：预览面板（代码 / 终端 / Review）
  Widget _buildPreview(WbColors c) {
    return Column(
      children: [
        SizedBox(
          height: WbSize.toolbarH,
          child: Row(
            children: [
              Expanded(
                child: _WbSlot(
                  key: kPreviewTabCode,
                  label: '代码',
                  selected: _previewTab == 0,
                  onTap: () => setState(() => _previewTab = 0),
                  // P11-2 块 3：这个数**只代表当前预览这一份**，不是总数、
                  // 也不许继承上一个文件的数（没被上报过就是不亮）。
                  trailing: _tabDiagBadge(c),
                ),
              ),
              Expanded(
                child: _WbSlot(
                  key: kPreviewTabTerm,
                  label: '终端',
                  selected: _previewTab == 1,
                  onTap: () => setState(() => _previewTab = 1),
                ),
              ),
              Expanded(
                child: _WbSlot(
                  key: kPreviewTabReview,
                  label: 'Review',
                  selected: _previewTab == 2,
                  onTap: () => setState(() => _previewTab = 2),
                ),
              ),
              WbToolButton(
                icon: Icons.close,
                label: '收起',
                onPressed: () => setState(() => _showPreview = false),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
        Divider(height: 1, color: c.border),
        Expanded(
          child: switch (_previewTab) {
            0 => _previewCode(c),
            1 => _previewTerm(c),
            _ => _previewReview(c),
          },
        ),
      ],
    );
  }

  /// 预览标签的诊断徽标：只对**当前打开的那一份**、且它真被语言服务器上报过时亮。
  /// 没上报过 ⇒ 返回 null（不亮），而不是亮个 0——"没查"与"查过没问题"得区分。
  Widget? _tabDiagBadge(WbColors c) {
    final doc = _doc;
    if (doc == null) return null;
    final n = _diagCounts[diagKey(doc.path)];
    if (n == null || n <= 0) return null;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text('$n',
          key: const Key('wb.tabDiagBadge'),
          style: WbText.ui11.copyWith(color: c.danger)),
    );
  }

  Widget _previewCode(WbColors c) {
    final doc = _doc;
    if (doc == null) {
      if (_loadingFile) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: Text('点左侧文件在这里打开（只读）',
            style: WbText.ui12.copyWith(color: c.textTertiary)),
      );
    }
    return Column(
      children: [
        Container(
          height: WbSize.fileHeaderH,
          color: c.sidebarBg,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: doc.path.replaceAll(r'\', '/'),
                  style: WbText.code12.copyWith(color: c.textPrimary),
                ),
                TextSpan(
                  text: '  ${doc.lines.length} 行 / ${doc.byteCount} 字节',
                  style: WbText.ui11.copyWith(color: c.textTertiary),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Divider(height: 1, color: c.border),
        // P11：诊断条只在「代码」档、且文档真在场时挂进来——它自己绑挂载/卸载
        // 起停语言服务器，收起预览或切档就离开树 ⇒ dispose 收进程。
        LspDiagnosticsPanel(
          key: ValueKey('lsp:${doc.path}'),
          cwd: _rootPath ?? doc.path,
          path: doc.path,
          text: doc.lines.join('\n'),
          colors: c,
          factory: widget.lspFactory,
          resolver: widget.lspResolver,
          onReport: _onDiagReport,
          onTapDiagnostic: _revealLine,
        ),
        Divider(height: 1, color: c.border),
        Expanded(
          child: FileViewer(
            key: ValueKey(doc.path),
            document: doc,
            scrollController: _fileScroll,
          ),
        ),
      ],
    );
  }

  /// P11：点一条诊断把预览定位到那一行（`LspDiagnostic` 的行是 0 基 ⇒ 直接用，
  /// jumpTo 的偏移也是行序号 × 行高）。行高**不在这里再造一把尺**：FileViewer
  /// 是定高行、ListView 挂在同一个 `_fileScroll` 上，所以
  /// 行高 = (maxScrollExtent + viewportDimension) / 行数，从实测量反推。
  void _revealLine(LspDiagnostic d) {
    final doc = _doc;
    if (doc == null || !_fileScroll.hasClients) return;
    final n = doc.lines.length;
    final pos = _fileScroll.position;
    if (n <= 0 || pos.maxScrollExtent <= 0) return;
    final lineH = (pos.maxScrollExtent + pos.viewportDimension) / n;
    final line = d.startLine < 0 ? 0 : d.startLine;
    _fileScroll.jumpTo((line * lineH).clamp(0.0, pos.maxScrollExtent));
  }

  /// 终端标签：S5 接上 B5 的 ConPTY 底座。
  /// 切走这个标签即销毁会话（TermTab.dispose 收句柄），回来是新会话。
  /// cwd 跟打开的文件夹走，和 ZCode / VS Code 的终端开在工作区一致。
  Widget _previewTerm(WbColors c) {
    return TermTab(
      cwd: _rootPath,
      onSpawned: (p) {
        final completer = _termProbeSpawn;
        if (completer != null && !completer.isCompleted) completer.complete(p);
      },
    );
  }

  Widget _previewReview(WbColors c) {
    final store = _store;
    if (store == null) {
      return Center(
        child: Text('还没有工作区，无提案可审',
            style: WbText.ui12.copyWith(color: c.textTertiary)),
      );
    }
    return ProposalReviewView(
      store: store,
      onClose: () => setState(() => _previewTab = 0),
      // P9：批注导出走 P4 那条既有公开通道（写进输入框，不做任何「已发送」
      // 承诺）。面板不在场就返回 false，由 Review 侧给真话提示。
      onExportNotes: (text) {
        final panel = _agentPanelKey.currentState;
        if (panel == null) return false;
        panel.insertIntoInput(text);
        return true;
      },
    );
  }
}

/// 槽位/标签：底部 2px 下划线标选中态（瞬时换色，零动画）。
class _WbSlot extends StatelessWidget {
  const _WbSlot({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// P11-2 块 3：标签右端的小尾巴（诊断计数徽标用）。放这儿是为了**不新增尺寸
  /// 所有者**——槽的高度、宽度、间距全走原来那套，尾巴只是行内一个 intrinsic Text。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = WbColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: WbSize.toolbarH - 8,
        margin: const EdgeInsets.fromLTRB(6, 4, 6, 0),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
                width: 2, color: selected ? c.accent : const Color(0x00000000)),
          ),
        ),
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: WbText.ui12
                    .copyWith(color: selected ? c.textPrimary : c.textTertiary),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// 上下文 chip（S1 项目一颗；S1b 起分支/权限模式/模型也用它，
/// 语义色由 [color] 覆盖：完全访问橙、灰显占位走 textTertiary）。
class _WbChip extends StatelessWidget {
  const _WbChip({required this.icon, required this.label, this.onTap, this.color});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// 前景色覆盖（图标+文字+边框内文案）；null = 按可点性取默认级。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = WbColors.of(context);
    final fg = color ?? (onTap == null ? c.textTertiary : c.textSecondary);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 5),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: WbText.ui12.copyWith(color: fg)),
            ),
          ],
        ),
      ),
    );
  }
}
