/// B4 LSP 客户端（单语言：Dart，经 `dart language-server --protocol=lsp`）。
///
/// 解析与传输分离：LspDecoder/encodeLspMessage 是纯字节帧函数，测试不起进程；
/// LspClient 只负责 spawn + JSON-RPC 路由。dart:io 自带能力够用，不引三方包。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一条 publishDiagnostics 里的诊断项（行/列都是 LSP 的 0 基）。
class LspDiagnostic {
  const LspDiagnostic({
    required this.startLine,
    required this.startChar,
    required this.endLine,
    required this.endChar,
    required this.severity,
    required this.message,
    required this.source,
  });

  final int startLine;
  final int startChar;
  final int endLine;
  final int endChar;

  /// 1=Error 2=Warning 3=Information 4=Hint；缺省当 1。
  final int severity;
  final String message;
  final String source;

  static LspDiagnostic fromJson(Map<String, dynamic> j) {
    final range = (j['range'] as Map?)?.cast<String, dynamic>() ?? const {};
    final start = (range['start'] as Map?)?.cast<String, dynamic>() ?? const {};
    final end = (range['end'] as Map?)?.cast<String, dynamic>() ?? const {};
    return LspDiagnostic(
      startLine: (start['line'] as num?)?.toInt() ?? 0,
      startChar: (start['character'] as num?)?.toInt() ?? 0,
      endLine: (end['line'] as num?)?.toInt() ?? 0,
      endChar: (end['character'] as num?)?.toInt() ?? 0,
      severity: (j['severity'] as num?)?.toInt() ?? 1,
      message: j['message'] as String? ?? '',
      source: j['source'] as String? ?? '',
    );
  }
}

/// 一帧 LSP 消息编码：Content-Length 头 + \r\n\r\n + UTF-8 JSON 体。
List<int> encodeLspMessage(Map<String, dynamic> msg) {
  final body = utf8.encode(jsonEncode(msg));
  final header = utf8.encode('Content-Length: ${body.length}\r\n\r\n');
  return [...header, ...body];
}

/// 增量字节帧解码器：喂任意切片，吐出完整 JSON 消息。
/// 头部只认 Content-Length（LSP 允许其它头，dart language-server 不发；
/// 收到未知头跳过，缺 Content-Length 按协议错误抛出）。
class LspDecoder {
  final _buf = <int>[];

  List<Map<String, dynamic>> push(List<int> chunk) {
    _buf.addAll(chunk);
    final out = <Map<String, dynamic>>[];
    for (;;) {
      final headerEnd = _indexOfHeaderEnd();
      if (headerEnd < 0) break;
      final header = ascii.decode(_buf.sublist(0, headerEnd));
      var contentLength = -1;
      for (final line in header.split('\r\n')) {
        final i = line.indexOf(':');
        if (i < 0) continue;
        if (line.substring(0, i).trim().toLowerCase() == 'content-length') {
          contentLength =
              int.tryParse(line.substring(i + 1).trim()) ?? -1;
        }
      }
      if (contentLength < 0) {
        throw const FormatException('LSP 头缺 Content-Length');
      }
      final bodyStart = headerEnd + 4;
      if (_buf.length < bodyStart + contentLength) break;
      final body = utf8.decode(_buf.sublist(bodyStart, bodyStart + contentLength));
      _buf.removeRange(0, bodyStart + contentLength);
      out.add((jsonDecode(body) as Map).cast<String, dynamic>());
    }
    return out;
  }

  int _indexOfHeaderEnd() {
    for (var i = 0; i + 3 < _buf.length; i++) {
      if (_buf[i] == 13 && _buf[i + 1] == 10 && _buf[i + 2] == 13 && _buf[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }
}

/// 面向一个语言服务器进程的 JSON-RPC 客户端。
class LspClient {
  LspClient({required this.command, this.args = const [], this.cwd});

  /// 形如 <flutter>/bin/cache/dart-sdk/bin/dart.exe
  final String command;

  /// 形如 ['language-server', '--protocol=lsp']
  final List<String> args;
  final String? cwd;

  Process? _proc;
  final _decoder = LspDecoder();
  var _nextId = 1;
  final _pending = <int, Completer<Map<String, dynamic>?>>{};
  StreamSubscription? _stdoutSub;

  /// (uri, diagnostics) 广播流；面板按 uri 过滤。
  final _diagnostics =
      StreamController<(String, List<LspDiagnostic>)>.broadcast();

  Stream<(String, List<LspDiagnostic>)> get diagnostics => _diagnostics.stream;

  bool get running => _proc != null;

  Future<void> start() async {
    if (_proc != null) throw StateError('已启动');
    final proc = await Process.start(command, args,
        workingDirectory: cwd, mode: ProcessStartMode.normal);
    _proc = proc;
    _stdoutSub = proc.stdout.listen((chunk) {
      for (final msg in _decoder.push(chunk)) {
        _route(msg);
      }
    }, onDone: () {
      for (final c in _pending.values) {
        if (!c.isCompleted) c.complete(null);
      }
      _pending.clear();
      _proc = null;
    });
    // stderr 只作诊断日志 sink，不进协议；吞掉防管道背压。
    proc.stderr.drain<void>();
  }

  void _route(Map<String, dynamic> msg) {
    final id = (msg['id'] as num?)?.toInt();
    if (id != null && (msg.containsKey('result') || msg.containsKey('error'))) {
      final c = _pending.remove(id);
      if (c != null && !c.isCompleted) {
        if (msg.containsKey('error')) {
          c.completeError(StateError('LSP error: ${jsonEncode(msg['error'])}'));
        } else {
          c.complete((msg['result'] as Map?)?.cast<String, dynamic>());
        }
      }
      return;
    }
    // 服务端主动请求（如 workspace/configuration）：按规范回 null，别挂起对端。
    if (id != null && msg['method'] is String) {
      _send({'jsonrpc': '2.0', 'id': id, 'result': null});
      return;
    }
    if (msg['method'] == 'textDocument/publishDiagnostics') {
      final params = (msg['params'] as Map?)?.cast<String, dynamic>() ?? const {};
      final uri = params['uri'] as String? ?? '';
      final list = (params['diagnostics'] as List?) ?? const [];
      _diagnostics.add((
        uri,
        [
          for (final d in list)
            if (d is Map) LspDiagnostic.fromJson(d.cast<String, dynamic>()),
        ],
      ));
    }
  }

  void _send(Map<String, dynamic> obj) {
    final proc = _proc;
    if (proc == null) throw StateError('未启动');
    proc.stdin.add(encodeLspMessage(obj));
  }

  Future<Map<String, dynamic>?> _request(
      String method, Map<String, dynamic> params) {
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>?>();
    _pending[id] = c;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return c.future;
  }

  void _notify(String method, Map<String, dynamic> params) {
    _send({'jsonrpc': '2.0', 'method': method, 'params': params});
  }

  /// initialize + initialized 握手；返回服务端 capabilities 原文。
  Future<Map<String, dynamic>> initialize({required String rootUri}) async {
    final result = await _request('initialize', {
      'processId': pid,
      'rootUri': rootUri,
      'capabilities': <String, dynamic>{
        'textDocument': <String, dynamic>{
          'publishDiagnostics': <String, dynamic>{},
          'hover': <String, dynamic>{'contentFormat': ['plaintext']},
        },
      },
      'clientInfo': {'name': 'aichat-workbench', 'version': '1'},
    });
    _notify('initialized', const {});
    return (result?['capabilities'] as Map?)?.cast<String, dynamic>() ??
        const {};
  }

  Future<void> didOpen({
    required String uri,
    required String languageId,
    required String text,
    int version = 1,
  }) async {
    _notify('textDocument/didOpen', {
      'textDocument': {
        'uri': uri,
        'languageId': languageId,
        'version': version,
        'text': text,
      },
    });
  }

  Future<void> didChange({
    required String uri,
    required String text,
    required int version,
  }) async {
    // 全量同步（TextDocumentSyncKind.Full=1）：客户端最简，量大再升 incremental。
    _notify('textDocument/didChange', {
      'textDocument': {'uri': uri, 'version': version},
      'contentChanges': [
        {'text': text},
      ],
    });
  }

  /// hover 请求（证明 initialize 之外的请求/响应回路通）。无结果返回 null。
  Future<String?> hover({
    required String uri,
    required int line,
    required int character,
  }) async {
    final result = await _request('textDocument/hover', {
      'textDocument': {'uri': uri},
      'position': {'line': line, 'character': character},
    });
    if (result == null) return null;
    final contents = result['contents'];
    if (contents is Map) {
      final v = contents['value'];
      if (v is String) return v;
    }
    if (contents is String) return contents;
    return jsonEncode(contents);
  }

  /// shutdown + exit 的礼貌关闭；对端不响应就强杀。
  Future<void> dispose() async {
    final proc = _proc;
    if (proc == null) return;
    try {
      await _request('shutdown', const {})
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      _notify('exit', const {});
      await proc.exitCode
          .timeout(const Duration(seconds: 5), onTimeout: () => -1);
    } finally {
      proc.kill(); // 已到 exitCode 的进程 kill 返回 false；这里只兜底。
      await _stdoutSub?.cancel();
      _proc = null;
      await _diagnostics.close();
    }
  }
}
