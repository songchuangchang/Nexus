/// S5 终端标签：把 B5 的 ConPTY 底座（[WinPty]）挂进右栏预览面板。
///
/// 最小样本口径（有意为之，别当成品终端用）：
/// * 只做「收字节 → 去 ANSI 序列 → 按行显示」与「输入行 → 写 `text\r`」；
///   光标移动、颜色、备用屏、滚动回看缓冲都不解析（那是下一层 VT 引擎的活）。
/// * 尺寸在 spawn 时定死（cols/rows），不随面板拖宽 resize ——
///   resize 与销毁并发的竞态在 desktop_pty_test 里单测，界面层先不掺和。
/// * 卸载即 dispose：活着就 TerminateProcess，退出码 Future 必须收口。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'pty.dart';
import 'workbench_theme.dart';

/// 去掉 CSI / OSC 转义序列，只留可打印文本（够读，不做渲染）。
final RegExp _ansiSeq = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]|\x1B\][^\x07]*\x07');

class TermTab extends StatefulWidget {
  const TermTab({super.key, this.command = 'cmd.exe', this.cols = 100,
      this.rows = 30, this.cwd, this.onSpawned});

  /// 进伪控制台的命令行。
  final String command;
  final int cols;
  final int rows;

  /// 终端的工作目录；null = 跟进程走。工作台应传打开的文件夹，
  /// 和 ZCode / VS Code 的终端开在工作区一致。
  final String? cwd;

  /// 探针/测试钩子：会话起来后把 [WinPty] 交出去（读 consoleAllocated 等）。
  final ValueChanged<WinPty>? onSpawned;

  @override
  State<TermTab> createState() => _TermTabState();
}

class _TermTabState extends State<TermTab> {
  static const int _maxLines = 2000;

  WinPty? _pty;
  StreamSubscription<Uint8List>? _sub;
  final List<String> _lines = <String>[];
  String _partial = '';
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _starting = true;
  String? _error;
  int? _exitCode;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_pty?.dispose());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    // 重启路径：先把旧会话的订阅与句柄收干净再起新的，
    // 否则每点一次「重启」就漏一个 cmd.exe + 一对管道句柄。
    final oldPty = _pty;
    final oldSub = _sub;
    _pty = null;
    _sub = null;
    await oldSub?.cancel();
    if (oldPty != null) await oldPty.dispose();
    if (!mounted) return;
    setState(() {
      _starting = true;
      _error = null;
      _exitCode = null;
      _lines.clear();
      _partial = '';
    });
    if (!Platform.isWindows) {
      setState(() {
        _starting = false;
        _error = '终端目前只支持 Windows（ConPTY）';
      });
      return;
    }
    try {
      final pty = await WinPty.spawn(
          command: widget.command,
          cols: widget.cols,
          rows: widget.rows,
          cwd: widget.cwd);
      if (!mounted) {
        await pty.dispose();
        return;
      }
      setState(() {
        _pty = pty;
        _starting = false;
      });
      widget.onSpawned?.call(pty);
      _sub = pty.output.listen(_onBytes);
      unawaited(pty.exitCode.then((code) {
        // 只认当前这一代 pty：旧会话被 dispose 时退出码回 -1，
        // 不许把「已退出」写进新会话的界面。
        if (!mounted || _pty != pty) return;
        setState(() => _exitCode = code);
      }));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = '起不来：$e';
      });
    }
  }

  void _onBytes(Uint8List bytes) {
    if (!mounted) return; // 订阅取消是异步的，退订后仍可能有一发在途
    final text =
        utf8.decode(bytes, allowMalformed: true).replaceAll(_ansiSeq, '');
    final merged = _partial + text;
    final parts = merged.split(RegExp(r'\r\n|\r|\n'));
    setState(() {
      _partial = parts.removeLast();
      _lines.addAll(parts);
      if (_lines.length > _maxLines) {
        _lines.removeRange(0, _lines.length - _maxLines);
      }
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _submit() {
    final pty = _pty;
    final text = _input.text;
    if (pty == null || _exitCode != null || text.isEmpty) return;
    try {
      pty.write(utf8.encode('$text\r'));
    } catch (e) {
      setState(() => _error = '写入失败：$e');
    }
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final c = WbColors.of(context);
    final shown = _partial.isEmpty ? _lines : [..._lines, _partial];
    return Column(
      children: [
        SizedBox(
          height: 28,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Text(widget.command,
                    style: WbText.ui11.copyWith(color: c.textSecondary)),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(_statusText(c),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: WbText.ui11.copyWith(color: c.textTertiary))),
                if (_exitCode != null || _error != null)
                  TextButton(
                      onPressed: () => unawaited(_start()),
                      child: const Text('重启', style: WbText.ui12)),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: c.border),
        Expanded(
          child: ColoredBox(
            color: c.windowBg,
            child: ListView.builder(
              controller: _scroll,
              itemCount: shown.isEmpty ? 1 : shown.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
                child: Text(
                  shown.isEmpty ? '（等输出…）' : shown[i],
                  style: WbText.code12.copyWith(color: c.textPrimary),
                ),
              ),
            ),
          ),
        ),
        Divider(height: 1, color: c.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: TextField(
            controller: _input,
            onSubmitted: (_) => _submit(),
            textInputAction: TextInputAction.done,
            enabled: _pty != null && _exitCode == null,
            style: WbText.code12.copyWith(color: c.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              hintText: _exitCode != null
                  ? '进程已退出'
                  : '输入命令后回车（示例：dir）',
              hintStyle: WbText.code12.copyWith(color: c.textTertiary),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: c.border)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: c.border)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: c.accent)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
          ),
        ),
      ],
    );
  }

  String _statusText(WbColors c) {
    if (_error != null) return _error!;
    if (_starting) return '启动中…';
    final code = _exitCode;
    if (code != null) return '进程已退出（码 $code）';
    return '运行中 · pid ${_pty?.pid ?? 0}';
  }
}
