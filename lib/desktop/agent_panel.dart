/// B2 Agent 面板：会话 + 事件流 + 提案审批入口。
/// 事件渲染只读；审批页（ProposalReviewView）一屏列出全部待批 diff，
/// 批准/拒绝逐条来 —— 落盘只发生在 ProposalStore.apply。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'gateway_client.dart';
import 'git_panel.dart';
import 'proposals.dart';
import 'workbench_theme.dart';

class AgentPanel extends StatefulWidget {
  const AgentPanel({
    super.key,
    required this.gateway,
    required this.store,
    required this.workspaceCwd,
    required this.onOpenReview,
    this.composerHeader,
    this.onSessionChanged,
    this.initialPrompt,
    this.readOnlyMode = true,
  });

  final GatewayApi gateway;
  final ProposalStore store;

  /// 当前打开的工作区路径；null = 还没打开文件夹，不能建会话。
  final String? workspaceCwd;
  final VoidCallback onOpenReview;

  /// S1b：输入卡片顶行（四颗 chip 由壳层组装传进来）。渲染在输入框
  /// **同一张卡片内部**的顶行，不另起一栏；null 时输入区与现状逐像素同。
  final Widget? composerHeader;

  /// P2：当前会话变化时通知壳层（任务槽用它高亮当前行）。
  /// _newSession 与 switchSession 都会触发。
  final ValueChanged<String?>? onSessionChanged;

  /// P3：壳层暂存的模板文案，建面板时一次性填进输入框（initState）。
  /// 只在面板首次创建时生效，重建不重填——壳层用完即清。
  final String? initialPrompt;

  /// P6：true（默认）＝变更前确认档——agent 只读、改动以 PATCH 回来走审批；
  /// false＝完全访问档——agent 直写工作区（gateway 按 local:true 放开档位），
  /// 不再带「只读模式」协议头。由壳层权限 chip 决定。
  final bool readOnlyMode;

  @override
  State<AgentPanel> createState() => AgentPanelState();
}

class AgentPanelState extends State<AgentPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<_Row> _rows = [];
  StreamSubscription<GatewayMsg>? _sub;
  String? _sid;
  bool _busy = false;
  String? _error;
  String _turnBuffer = '';

  @override
  void initState() {
    super.initState();
    // P3：模板卡文案的一次性入口（initState 只跑一次，不会重建重填）。
    final prompt = widget.initialPrompt;
    if (prompt != null && prompt.isNotEmpty) {
      _input.text = prompt;
    }
    _sub = widget.gateway.messages.listen(_onMsg);
    widget.store.addListener(_onStore);
  }

  @override
  void dispose() {
    _sub?.cancel();
    widget.store.removeListener(_onStore);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  void _onMsg(GatewayMsg msg) {
    if (!mounted) return;
    if (msg is GmControl) {
      switch (msg.type) {
        case 'accepted':
          setState(() => _busy = true);
        case 'busy':
          setState(() => _error = '上一轮还在跑（服务端 busy）');
        case 'error':
          setState(() => _error = '${msg.raw['reason'] ?? msg.raw}');
        case 'closed':
        case 'socket_error':
          setState(() => _error = '连接断开：${msg.raw['error'] ?? '对端关闭'}');
        default:
          break; // hello / pong 不用画
      }
      return;
    }
    final e = (msg as GmEvent).event;
    if (_sid != null && e.sid != _sid) return; // 只看当前会话
    setState(() {
      switch (e.kind) {
        case 'message':
          _rows.add(_Row(e.role == 'user' ? '你' : 'Agent', e.text));
          if (e.role == 'agent') _turnBuffer += '${e.text}\n';
        case 'tool_result':
          _rows.add(_Row('工具结果', e.text, dim: true));
        case 'result':
          _rows.add(_Row('结果', e.text, dim: true));
          _finishTurn();
          _busy = false;
        case 'error':
          _rows.add(_Row('错误', e.text, warn: true));
          _finishTurn();
          _busy = false;
        case 'cancelled':
          _rows.add(_Row('已中止', e.text, warn: true));
          _finishTurn();
          _busy = false;
        default:
          _rows.add(_Row(e.kind, e.text, dim: true));
      }
    });
    _jumpBottom();
  }

  /// 一轮收尾：把攒下的整轮文本过一遍提案解析。
  void _finishTurn() {
    if (_turnBuffer.trim().isEmpty) return;
    final buf = _turnBuffer;
    _turnBuffer = '';
    widget.store.ingestText(buf);
  }

  void _jumpBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _newSession() async {
    final cwd = widget.workspaceCwd;
    if (cwd == null) {
      setState(() => _error = '先在左侧打开工作区文件夹');
      return;
    }
    try {
      final sid =
          await widget.gateway.newSession(cwd: cwd, title: '桌面工作台');
      setState(() {
        _sid = sid;
        _error = null;
        _rows.add(_Row('系统', '会话 $sid 已建立', dim: true));
      });
      widget.onSessionChanged?.call(sid);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  /// P2：切到指定会话。标题（build 里「会话 $_sid」）、事件过滤
  /// （_onMsg 的 e.sid != _sid）、发送目标（_send 的 sid）都读同一个
  /// _sid，切一次全跟着走。历史走 gateway 的 WS history 接口回填；
  /// 拉不到就一句真话（该会话新消息仍会实时显示），不造假对话。
  Future<void> switchSession(String sid) async {
    if (_sid == sid) return;
    setState(() {
      _sid = sid;
      _rows
        ..clear()
        ..add(_Row('系统', '会话 $sid 已打开，正在拉历史…', dim: true));
      _turnBuffer = '';
      _busy = false;
      _error = null;
    });
    widget.onSessionChanged?.call(sid);
    final List<GatewayEvent> items;
    try {
      items = await widget.gateway.history(sid);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _rows.removeWhere((r) => r.who == '系统');
        _rows.add(_Row(
            '系统', '历史拉不到（$e）；该会话的新消息仍会实时显示。', dim: true));
      });
      _jumpBottom();
      return;
    }
    if (!mounted) return;
    setState(() {
      _rows.clear();
      for (final e in items) {
        switch (e.kind) {
          case 'message':
            _rows.add(_Row(e.role == 'user' ? '你' : 'Agent', e.text));
          case 'tool_result':
            _rows.add(_Row('工具结果', e.text, dim: true));
          case 'result':
            _rows.add(_Row('结果', e.text, dim: true));
          case 'cancelled':
            _rows.add(_Row('已中止', e.text, warn: true));
          case 'error':
            _rows.add(_Row('错误', e.text, warn: true));
          default:
            break; // 其余 kind 不回放
        }
      }
      if (items.isEmpty) {
        _rows.add(const _Row('系统', '该会话在 gateway 上没有历史事件。', dim: true));
      }
    });
    _jumpBottom();
  }

  void _send() {
    final sid = _sid;
    final text = _input.text.trim();
    if (sid == null || text.isEmpty || _busy) return;
    _input.clear();
    _turnBuffer = '';
    if (widget.readOnlyMode) {
      // P6 确认档（现状逐字节）：只读协议头 + local:false——改动只能以
      // PATCH 块回来走审批。
      widget.gateway.send(sid, '$kPatchProtocolPreamble\n$text', local: false);
    } else {
      // P6 完全访问档：直写工作区。不带「只读模式」协议头——协议头自称
      // 只读，直写档再发就是假话；local:true 让 gateway 放开档位。
      widget.gateway.send(sid, text, local: true);
    }
  }

  /// P4：向输入框光标处插入文本（「＋」引用文件用）。
  /// 光标无效或未定位时追加到末尾；插入文本后带一个尾随空格，光标停在
  /// 插入内容之后。只负责机械插入，插的是什么由调用方保证真话。
  void insertIntoInput(String text) {
    final base = _input.text;
    final sel = _input.selection;
    final pos = sel.isValid && sel.baseOffset >= 0
        ? sel.baseOffset
        : base.length;
    final needsSpace =
        pos > 0 && !base.substring(0, pos).endsWith(' ');
    final insert = needsSpace ? ' $text ' : '$text ';
    _input.value = TextEditingValue(
      text: base.replaceRange(pos, pos, insert),
      selection: TextSelection.collapsed(offset: pos + insert.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = WbColors.of(context);
    final pending = widget.store.pending.length;
    return Column(
      children: [
        SizedBox(
          height: 36,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _sid == null ? '未建会话' : '会话 $_sid',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: WbText.ui12.copyWith(
                        color: c.textSecondary,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _newSession,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 4),
                    child: Text('新会话',
                        style: WbText.ui12.copyWith(color: c.accent)),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_error != null)
          Container(
            width: double.infinity,
            color: c.danger.withValues(alpha: 0.10),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(_error!,
                style: WbText.ui11.copyWith(color: c.danger)),
          ),
        if (pending > 0)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onOpenReview,
            child: Container(
              width: double.infinity,
              color: c.warnSoft,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.rate_review_outlined, size: 15, color: c.warn),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('$pending 个待审批改动 — 点这里进审批页',
                        style: WbText.ui12.copyWith(color: c.warn)),
                  ),
                  Icon(Icons.chevron_right, size: 15, color: c.warn),
                ],
              ),
            ),
          ),
        Divider(height: 1, color: c.border),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            itemCount: _rows.length,
            itemBuilder: (context, i) {
              final r = _rows[i];
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.who,
                        style: WbText.ui11.copyWith(
                            fontSize: 10,
                            color:
                                r.warn ? c.danger : c.textTertiary)),
                    const SizedBox(height: 1),
                    SelectableText(
                      r.text,
                      style: WbText.ui12.copyWith(
                        color: r.dim ? c.textSecondary : c.textPrimary,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        Divider(height: 1, color: c.border),
        Padding(
          padding: const EdgeInsets.all(8),
          // S1b：有 composerHeader 时把顶行和输入行包进同一张卡片；
          // null 时保持旧结构（Padding 里裸 Row），与现状逐像素同。
          child: widget.composerHeader == null
              ? _inputRow(c)
              : Container(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                  decoration: BoxDecoration(
                    color: c.panelBg,
                    border: Border.all(color: c.border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: widget.composerHeader!,
                      ),
                      const SizedBox(height: 6),
                      _inputRow(c),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  /// 输入行本体（TextField + 发送 + 中止）。原样从 build 里提出来，
  /// 让「有/无 composerHeader」两条路共享同一份像素。
  Widget _inputRow(WbColors c) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: _input,
            minLines: 1,
            maxLines: 6,
            style: WbText.ui13.copyWith(color: c.textPrimary),
            decoration: InputDecoration(
              hintText: '给 agent 派活（只读档，改动走审批）',
              hintStyle: WbText.ui12.copyWith(color: c.textTertiary),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              filled: true,
              fillColor: c.panelBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: c.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: c.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: c.accent),
              ),
            ),
            onSubmitted: (_) => _send(),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: Icon(Icons.send,
              size: 17, color: _busy ? c.textTertiary : c.accent),
          onPressed: _busy ? null : _send,
          tooltip: '发送',
        ),
        IconButton(
          icon: Icon(Icons.stop,
              size: 17,
              color: _busy && _sid != null ? c.danger : c.textTertiary),
          onPressed:
              _busy && _sid != null ? () => widget.gateway.cancel(_sid!) : null,
          tooltip: '中止本轮',
        ),
      ],
    );
  }
}

class _Row {
  const _Row(this.who, this.text, {this.dim = false, this.warn = false});
  final String who;
  final String text;
  final bool dim;
  final bool warn;
}

/// 审批页（S4）：两档范围 + 未落盘批量撤销。
/// 本次会话 = [ProposalStore] 的提案（带逐条批拒与 diff）；
/// 全部未提交 = `git status` 的清单（只读，点开看单文件 diff）。
/// 撤销只作用于**未落盘**的 pending 提案：已落盘的改动没有备份机制，
/// 这个按钮不许碰它（规格 §4 S4）。
enum ReviewScope { session, git }

class ProposalReviewView extends StatefulWidget {
  const ProposalReviewView({
    super.key,
    required this.store,
    this.onClose,
    this.onExportNotes,
  });

  final ProposalStore store;
  final VoidCallback? onClose;

  /// P9：把「行级批注汇总文本」送进会话输入框的通道（壳层用
  /// `AgentPanel.insertIntoInput` 实现）。返回 false＝没处送（面板不在场），
  /// 调用方给真话提示。为 null 时同样算没处送——批注不会假装已送出。
  final bool Function(String text)? onExportNotes;

  @override
  State<ProposalReviewView> createState() => _ProposalReviewViewState();
}

class _ProposalReviewViewState extends State<ProposalReviewView> {
  ReviewScope _scope = ReviewScope.session;
  List<GitStatusEntry>? _entries;
  String? _gitError;
  String? _selPath;
  List<DiffLine>? _selDiff;
  bool _loadingDiff = false;

  /// P8：面板内提交说明；空串时提交禁用。
  final _commitMsg = TextEditingController();

  /// P8：git 操作进行中（行内按钮与提交键禁用防连点）。
  bool _gitBusy = false;

  /// P9：行级批注，key = `"<路径>#<新侧行号>"`，value = 那一句批注。
  /// **只活在面板内存态**——不入库、不进 ProposalStore、不上 WS，
  /// 所以「导出」出去的只是文本，agent 会不会按行回改不由这里承诺。
  final Map<String, String> _notes = <String, String>{};

  @override
  void dispose() {
    _commitMsg.dispose();
    super.dispose();
  }

  ProposalStore get store => widget.store;

  Future<void> _loadGit() async {
    try {
      final e = await GitService(store.rootPath).status();
      if (!mounted) return;
      setState(() {
        _entries = e;
        _gitError = null;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _entries = null;
        _gitError = '$err';
      });
    }
  }

  void _setScope(ReviewScope s) {
    if (_scope == s) return;
    setState(() {
      _scope = s;
      _selPath = null;
      _selDiff = null;
    });
    if (s == ReviewScope.git && _entries == null && _gitError == null) {
      _loadGit();
    }
  }

  Future<void> _toggleDiff(GitStatusEntry e) async {
    if (_selPath == e.path) {
      setState(() {
        _selPath = null;
        _selDiff = null;
      });
      return;
    }
    setState(() {
      _selPath = e.path;
      _selDiff = null;
      _loadingDiff = true;
    });
    if (e.isUntracked) {
      // 未跟踪文件没进索引，git diff 是空的 —— 直接说明，不给假空 diff。
      if (!mounted) return;
      setState(() {
        _loadingDiff = false;
        _selDiff = const [];
      });
      return;
    }
    final lines = await GitService(store.rootPath).diff(e.path);
    if (!mounted) return;
    setState(() {
      _loadingDiff = false;
      _selDiff = lines;
    });
  }

  /// P8：行内 git 操作统一收口——忙标记防连点、操作后刷新列表、
  /// 成功/失败都给真话 SnackBar。
  /// P8 返修（A1/A2 退件点 1）：Messenger 在任何 await **之前**取好——
  /// `await _loadGit()` 之后再用 `context` 取 ancestor，撞上窗口关闭/切根
  /// 就是在已 deactivate 的 element 上找（`use_build_context_synchronously`）。
  /// mounted 仍在每条分支用，只是不再跨 await 现取 context。
  Future<void> _gitOp(Future<void> Function() op, String okMsg) async {
    if (_gitBusy) return;
    setState(() => _gitBusy = true);
    final ms = ScaffoldMessenger.of(context);
    try {
      await op();
      await _loadGit();
      if (!mounted) return;
      ms.showSnackBar(SnackBar(content: Text(okMsg)));
    } catch (e) {
      if (!mounted) return;
      ms.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _gitBusy = false);
    }
  }

  GitService get _git => GitService(store.rootPath);

  Future<void> _stageEntry(GitStatusEntry e) =>
      _gitOp(() => _git.stage(e.path), '已暂存：${e.path}');

  Future<void> _unstageEntry(GitStatusEntry e) =>
      _gitOp(() => _git.unstage(e.path), '已取消暂存：${e.path}');

  /// 不可恢复（没有备份机制）——先二次确认弹窗再执行。
  Future<void> _discardEntry(GitStatusEntry e) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('丢弃改动？'),
        content: Text('${e.path}\n\n该操作不可恢复——没有备份机制。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认丢弃')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await _gitOp(() => _git.discard(e.path), '已丢弃：${e.path} 的改动');
  }

  Future<void> _commit() async {
    final msg = _commitMsg.text.trim();
    if (msg.isEmpty) return;
    await _gitOp(() async {
      await _git.commit(msg);
      _commitMsg.clear();
    }, '已提交：$msg');
  }

  /// P9：批注 key（`"<路径>#<新侧行号>"`）→ 人话标签「路径 第 N 行」。
  static String _noteLabel(String key) {
    final at = key.lastIndexOf('#');
    return '${key.substring(0, at)} 第 ${key.substring(at + 1)} 行';
  }

  /// P9：给 diff 里的一行写一句批注。空文本不存；已有批注重开弹框可改写。
  Future<void> _noteLine(WbColors c, String path, DiffLine l) async {
    final key = '$path#${l.newLine}';
    final ctl = TextEditingController(text: _notes[key] ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('批注 $path 第 ${l.newLine} 行'),
        content: TextField(
          key: const Key('wb.noteInput'),
          controller: ctl,
          minLines: 1,
          maxLines: 3,
          style: WbText.ui12.copyWith(color: c.textPrimary),
          decoration: const InputDecoration(labelText: '一句话'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    final text = ctl.text.trim();
    ctl.dispose();
    if (saved != true || text.isEmpty || !mounted) return;
    setState(() => _notes[key] = text);
  }

  /// P9：汇总成多行文本。头部那句是承诺的上限——出去的只是文本，
  /// agent 会不会按行回改不由这里说什么。
  String _notesText() {
    final b = StringBuffer('行级批注（以下是文本，不是已定位的改动请求）：');
    for (final it in _notes.entries) {
      b.write('\n${_noteLabel(it.key)}：${it.value}');
    }
    return b.toString();
  }

  /// P9：导出＝把文本放进会话输入框；没处送时给真话，绝不假装已发送。
  void _exportNotes() {
    if (_notes.isEmpty) return;
    final delivered = widget.onExportNotes?.call(_notesText()) ?? false;
    if (!delivered && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('会话面板还没起来，批注没处送。')));
    }
  }

  /// P9：批注列表（可见＋可删）与导出入口。maxHeight 96 沿用本文件里
  /// diff 块 `maxHeight: 260` 那种局部约束写法，不新增令牌、不新增时长。
  Widget _notesStrip(WbColors c) {
    final items = _notes.entries.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 1, color: c.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
          child: Row(
            children: [
              Expanded(
                  child: Text('批注 ${items.length} 条',
                      style: WbText.ui11.copyWith(color: c.textSecondary))),
              GestureDetector(
                key: const Key('wb.exportNotes'),
                behavior: HitTestBehavior.opaque,
                onTap: items.isEmpty ? null : _exportNotes,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text('导出批注',
                      style: WbText.ui11.copyWith(
                          color: items.isEmpty ? c.textTertiary : c.accent)),
                ),
              ),
            ],
          ),
        ),
        if (items.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 96),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 4),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final it = items[i];
                return Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 2),
                  child: Row(
                    children: [
                      Expanded(
                          child: Text('${_noteLabel(it.key)}：${it.value}',
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  WbText.ui11.copyWith(color: c.textPrimary))),
                      GestureDetector(
                        key: Key('wb.delNote#${it.key}'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _notes.remove(it.key)),
                        child: Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          child: Text('删',
                              style: WbText.ui11.copyWith(color: c.danger)),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  /// P8：行尾操作——未暂存（含未跟踪）给「暂存」；已暂存给「取消暂存/丢弃」。
  List<Widget> _rowActions(GitStatusEntry e, WbColors c) {
    Widget act(String label, VoidCallback onTap, Color color) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _gitBusy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(label,
              style: WbText.ui11
                  .copyWith(color: _gitBusy ? c.textTertiary : color)),
        ),
      );
    }

    final staged = !e.isUntracked && e.y == ' ';
    if (staged) {
      return [
        act('取消暂存', () => _unstageEntry(e), c.accent),
        act('丢弃', () => _discardEntry(e), c.danger),
      ];
    }
    return [act('暂存', () => _stageEntry(e), c.accent)];
  }

  /// 只拒未落盘的 pending；已批准/已落盘的不动。
  void _rejectPending() {
    for (final p in store.pending.toList()) {
      store.reject(p);
    }
  }

  Color _statusColor(ProposalStatus s, WbColors c) => switch (s) {
        ProposalStatus.pending => c.warn,
        ProposalStatus.approved => c.accent,
        ProposalStatus.applied => c.ok,
        ProposalStatus.rejected => c.textTertiary,
        ProposalStatus.failed => c.danger,
      };

  String _statusText(ProposalStatus s) => switch (s) {
        ProposalStatus.pending => '待审批',
        ProposalStatus.approved => '已批准',
        ProposalStatus.applied => '已落盘',
        ProposalStatus.rejected => '已拒绝',
        ProposalStatus.failed => '失败',
      };

  @override
  Widget build(BuildContext context) {
    final c = WbColors.of(context);
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final list = store.proposals;
        final pending = store.pending;
        return Column(
          children: [
            SizedBox(
              height: 36,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Text(
                        _scope == ReviewScope.session
                            ? '改动审批（${list.length}）'
                            : '未提交改动（${_entries?.length ?? 0}）',
                        style: WbText.ui13.copyWith(
                            fontWeight: FontWeight.w600,
                            color: c.textPrimary)),
                    const SizedBox(width: 10),
                    _ScopeToggle(
                        key: const Key('wb.scopeSession'),
                        label: '本次会话',
                        selected: _scope == ReviewScope.session,
                        onTap: () => _setScope(ReviewScope.session)),
                    _ScopeToggle(
                        key: const Key('wb.scopeGit'),
                        label: '全部未提交',
                        selected: _scope == ReviewScope.git,
                        onTap: () => _setScope(ReviewScope.git)),
                    const Spacer(),
                    if (_scope == ReviewScope.session && pending.isNotEmpty)
                      _CardAction(
                        key: const Key('wb.rejectPending'),
                        label: '撤销未落盘',
                        color: c.danger,
                        onTap: _rejectPending,
                      ),
                    if (widget.onClose != null)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.onClose,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          child: Text('返回文件',
                              style: WbText.ui12.copyWith(color: c.accent)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            ColoredBox(color: c.border, child: const SizedBox(height: 1)),
            Expanded(
                child: _scope == ReviewScope.session
                    ? _buildSession(list, c)
                    : _buildGitScope(c)),
          ],
        );
      },
    );
  }

  Widget _buildSession(List<Proposal> list, WbColors c) {
    if (list.isEmpty) {
      return Center(
          child: Text('还没有提案。给 agent 派活后，改动会以块的形式回到这里。',
              style: WbText.ui12.copyWith(color: c.textTertiary)));
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, i) => _ProposalCard(
          proposal: list[i],
          store: store,
          statusColor: _statusColor(list[i].status, c),
          statusText: _statusText(list[i].status)),
    );
  }

  /// P9 返修（A1 13:56 退件点＝批注条**可达性**）：批注条挂在 `_buildGit`
  /// **外面**。`_buildGit` 有三个早返回（读不到 git 状态／读取中／工作区
  /// 干净），批注条挂在内层 Column 尾部时会跟着整条消失＝批注还在 `_notes`
  /// 里，却看不见、删不掉、导不出，也没有任何一句话告诉用户它还在。
  /// 这一层壳只干这一件事，那三个分支渲染的内容一字不改。
  Widget _buildGitScope(WbColors c) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _buildGit(c)),
          _notesStrip(c),
        ],
      );

  Widget _buildGit(WbColors c) {
    if (_gitError != null) {
      return Center(
          child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text('读不到 git 状态（这个文件夹可能不是仓库）：$_gitError',
            textAlign: TextAlign.center,
            style: WbText.ui12.copyWith(color: c.textTertiary)),
      ));
    }
    final entries = _entries;
    if (entries == null) {
      return Center(
          child: Text('读取中…',
              style: WbText.ui12.copyWith(color: c.textTertiary)));
    }
    if (entries.isEmpty) {
      return Center(
          child: Text('工作区干净，没有未提交改动。',
              style: WbText.ui12.copyWith(color: c.textTertiary)));
    }
    // P8：提交区 + 行内操作。行尾按钮按状态真话标注：未暂存（含未跟踪）
    // =「暂存」；已暂存 =「取消暂存 / 丢弃（不可恢复，二次确认）」。
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _commitMsg,
                  maxLines: 1,
                  style: WbText.ui12.copyWith(color: c.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '提交说明（只提交已暂存的改动）',
                    hintStyle: WbText.ui11.copyWith(color: c.textTertiary),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: c.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: BorderSide(color: c.border),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _commitMsg.text.trim().isEmpty || _gitBusy
                    ? null
                    : _commit,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text('提交',
                      style: WbText.ui12.copyWith(
                          color: _commitMsg.text.trim().isEmpty || _gitBusy
                              ? c.textTertiary
                              : c.accent)),
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: c.border),
        Expanded(
          child: ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              final name = e.path.split('/').last;
              final untracked = e.isUntracked;
              final selected = _selPath == e.path;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _toggleDiff(e),
                    child: Container(
                      height: WbSize.treeRowH,
                      color: selected ? c.rowSelected : null,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          Expanded(
                              child: Text(name,
                                  style: WbText.ui12.copyWith(
                                      color:
                                          untracked ? c.ok : c.textPrimary))),
                          Text(untracked ? 'U' : '•',
                              style: WbText.ui11
                                  .copyWith(color: untracked ? c.ok : c.warn)),
                          const SizedBox(width: 8),
                          Text(selected ? '收起' : 'diff',
                              style:
                                  WbText.ui11.copyWith(color: c.accent)),
                          ..._rowActions(e, c),
                        ],
                      ),
                    ),
                  ),
                  if (selected) _diffBlock(c, untracked, e.path),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _diffBlock(WbColors c, bool untracked, String path) {
    if (_loadingDiff) {
      return Padding(
          padding: const EdgeInsets.all(10),
          child: Text('读取中…',
              style: WbText.ui12.copyWith(color: c.textTertiary)));
    }
    if (untracked) {
      return Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
          child: Text('未跟踪文件没进索引，没有 diff 可看。',
              style: WbText.ui12.copyWith(color: c.textTertiary)));
    }
    final lines = _selDiff;
    if (lines == null || lines.isEmpty) {
      return Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
          child: Text('没有内容差异。',
              style: WbText.ui12.copyWith(color: c.textTertiary)));
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 260),
      child: ColoredBox(
        color: c.panelBg,
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: lines.length,
          itemBuilder: (context, i) {
            final l = lines[i];
            final noted = _notes.containsKey('$path#${l.newLine}');
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l.text,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: WbText.code12.copyWith(
                        color: switch (l.type) {
                          DiffLineType.add => c.ok,
                          DiffLineType.del => c.danger,
                          DiffLineType.header => c.textSecondary,
                          _ => c.textPrimary,
                        },
                      ),
                    ),
                  ),
                  // P9：只有拿到新侧行号的行（上下文/新增）给批注入口——
                  // 删除行没有「第 N 行」可指，不编号就不给入口。
                  if (l.newLine != null)
                    GestureDetector(
                      key: Key('wb.noteLine${l.newLine}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _noteLine(c, path, l),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        child: Text(noted ? '改注' : '批注',
                            style: WbText.ui11.copyWith(
                                color: noted ? c.warn : c.accent)),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 范围切换：紧凑文字件，选中态走 accent 下划线（瞬时，无动画）。
class _ScopeToggle extends StatelessWidget {
  const _ScopeToggle({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = WbColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(
                  width: 2,
                  color: selected ? c.accent : const Color(0x00000000))),
        ),
        child: Text(label,
            style: WbText.ui11
                .copyWith(color: selected ? c.textPrimary : c.textTertiary)),
      ),
    );
  }
}

class _ProposalCard extends StatelessWidget {
  const _ProposalCard({
    required this.proposal,
    required this.store,
    required this.statusColor,
    required this.statusText,
  });

  final Proposal proposal;
  final ProposalStore store;
  final Color statusColor;
  final String statusText;

  @override
  Widget build(BuildContext context) {
    final c = WbColors.of(context);
    final p = proposal;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.panelBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${p.path}${p.oldContent == null ? "（新文件）" : ""}',
                    style: WbText.ui12.copyWith(
                        fontWeight: FontWeight.w600, color: c.textPrimary),
                  ),
                ),
                Text(statusText,
                    style: WbText.ui11.copyWith(color: statusColor)),
                if (p.status == ProposalStatus.pending) ...[
                  _CardAction(
                    label: '批准',
                    color: c.accent,
                    onTap: () => store.apply(p),
                  ),
                  _CardAction(
                    label: '拒绝',
                    color: c.danger,
                    onTap: () => store.reject(p),
                  ),
                ],
              ],
            ),
          ),
          if (p.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: Text(p.error!,
                  style: WbText.ui11.copyWith(color: c.danger)),
            ),
          ColoredBox(color: c.border, child: const SizedBox(height: 1)),
          ...p.diff.map((l) => Container(
                width: double.infinity,
                color: switch (l.type) {
                  DiffLineType.add => c.ok.withValues(alpha: 0.08),
                  DiffLineType.del => c.danger.withValues(alpha: 0.08),
                  _ => null,
                },
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
                child: Text(
                  l.text,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  softWrap: false,
                  style: WbText.code12.copyWith(
                    color: switch (l.type) {
                      DiffLineType.add => c.ok,
                      DiffLineType.del => c.danger,
                      DiffLineType.header => c.textSecondary,
                      _ => c.textPrimary,
                    },
                  ),
                ),
              )),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _CardAction extends StatelessWidget {
  const _CardAction({
    super.key,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(label, style: WbText.ui12.copyWith(color: color)),
      ),
    );
  }
}
