/// B2 Gateway 客户端：配对 + WebSocket 事件流。dart:io 自带 HttpClient/WebSocket，
/// 不引任何三方包。解析与传输分离：parseGatewayMessage 是纯函数，测试不用网络。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一条落库事件（WS 的 {"type":"event"} 与 hello 回放里的元素统一成这个形状）。
class GatewayEvent {
  const GatewayEvent({
    required this.id,
    required this.sid,
    required this.role,
    required this.kind,
    required this.payload,
  });

  final int id;
  final String sid;
  final String role;
  final String kind;
  final Map<String, dynamic> payload;

  String get text => (payload['text'] as String?) ?? '';
}

/// 传输层上来的东西：要么是一条事件，要么是一条控制消息（session/accepted/
/// busy/error/pong/hello）。
sealed class GatewayMsg {
  const GatewayMsg();
}

class GmEvent extends GatewayMsg {
  const GmEvent(this.event);
  final GatewayEvent event;
}

class GmControl extends GatewayMsg {
  const GmControl(this.type, this.raw);
  final String type;
  final Map<String, dynamic> raw;
}

/// hello 里的回放逐条转成 GmEvent，hello 本身也发一条（客户端拿它当"已连上"）。
GatewayMsg? parseGatewayMessage(Map<String, dynamic> j) {
  final type = j['type'] as String? ?? '';
  if (type == 'event') {
    return GmEvent(GatewayEvent(
      id: (j['id'] as num?)?.toInt() ?? 0,
      sid: j['sid'] as String? ?? '',
      role: j['role'] as String? ?? '',
      kind: j['kind'] as String? ?? '',
      payload: (j['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
    ));
  }
  if (type == 'hello') {
    // 回放展开成事件流由调用方做（replay 是个列表）；hello 本体只作信号。
    return GmControl('hello', j);
  }
  return GmControl(type, j);
}

/// hello 回放元素 → GatewayEvent（与 event 消息同一形状）。
List<GatewayEvent> parseReplay(Map<String, dynamic> hello) {
  final list = (hello['replay'] as List?) ?? const [];
  return [
    for (final r in list)
      if (r is Map)
        GatewayEvent(
          id: (r['id'] as num?)?.toInt() ?? 0,
          sid: r['sid'] as String? ?? '',
          role: r['role'] as String? ?? '',
          kind: r['kind'] as String? ?? '',
          payload: (r['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
  ];
}

/// S1b：gateway 会话快照里的一行（GET /api/sessions/snapshot 的 sessions 元素）。
/// updatedAt 是 epoch **秒**（服务端 time.time() 落库的口径），不是毫秒。
class GwSession {
  const GwSession({
    required this.sid,
    required this.title,
    required this.cwd,
    required this.updatedAt,
  });

  final String sid;
  final String title;
  final String cwd;
  final double updatedAt;
}

/// sessions 数组 → GwSession 列表（纯函数，测试不用网络）。
List<GwSession> parseSessions(Map<String, dynamic> j) {
  final list = (j['sessions'] as List?) ?? const [];
  return [
    for (final s in list)
      if (s is Map)
        GwSession(
          sid: s['sid'] as String? ?? '',
          title: s['title'] as String? ?? '',
          cwd: s['cwd'] as String? ?? '',
          updatedAt: (s['updated_at'] as num?)?.toDouble() ?? 0,
        ),
  ];
}

/// P2：WS history 响应 → 事件列表（正序，老→新）。
/// 注意 gateway.py 的 history 分支**不做** json.loads——payload 落库是
/// TEXT，回包里是 JSON 字符串；hello replay 分支才是已解析的 dict。
/// 两种形状都兼容，别赌服务端实现。
List<GatewayEvent> parseHistory(Map<String, dynamic> j) {
  final sid = j['sid'] as String? ?? '';
  final list = (j['items'] as List?) ?? const [];
  final out = <GatewayEvent>[];
  for (final r in list) {
    if (r is! Map) continue;
    final item = r.cast<String, dynamic>();
    final raw = item['payload'];
    Map<String, dynamic> payload = const {};
    if (raw is String) {
      payload =
          (jsonDecode(raw) as Map?)?.cast<String, dynamic>() ?? const {};
    } else if (raw is Map) {
      payload = raw.cast<String, dynamic>();
    }
    out.add(GatewayEvent(
      id: (item['id'] as num?)?.toInt() ?? 0,
      sid: sid,
      role: item['role'] as String? ?? '',
      kind: item['kind'] as String? ?? '',
      payload: payload,
    ));
  }
  return out;
}

/// 面板只依赖这个接口；测试用 FakeGateway，真机用 LiveGateway。
abstract class GatewayApi {
  /// 已收到的事件+控制消息流（broadcast，面板订阅）。
  Stream<GatewayMsg> get messages;

  bool get connected;

  Future<void> connect();

  /// 发 new_session，返回服务端给的 sid。
  Future<String> newSession({required String cwd, required String title});

  /// local=true 可写档；false（默认）= 只读档 —— 提案流必须走 false。
  void send(String sid, String text, {bool local = false});

  void cancel(String sid);

  /// S1b：任务槽真列表 = GET /api/sessions/snapshot 的 sessions 数组。
  Future<List<GwSession>> listSessions();

  /// P2：按 sid 拉历史事件（WS {"type":"history"}，gateway.py:569 已有，
  /// 无需服务端改动）。旧 gateway 不认识该消息时响应永不回来，所以
  /// LiveGateway 实现自带 5s 超时，调用方按「拉不到」处理即可。
  Future<List<GatewayEvent>> history(String sid, {int limit = 200});

  Future<void> dispose();
}

class LiveGateway implements GatewayApi {
  LiveGateway({required this.baseUrl, required this.secretPath});

  /// 形如 http://127.0.0.1:8765
  final String baseUrl;

  /// .device_secret 全路径（本机自配对用）。
  final String secretPath;

  WebSocket? _ws;
  String? _token;
  final _out = StreamController<GatewayMsg>.broadcast();
  StreamSubscription? _sub;
  Completer<String>? _sessionCompleter;

  /// P2 回合 3：history 按 sid 挂 waiter，不止单例——快速连点两行会话时
  /// 两个请求都在飞，响应按 raw['sid'] 各自归位；单例会让先到站的响应
  /// 完成后发者的等待、后到站的被丢（数据张冠李戴，A 复审退件点）。
  final _historyWaiters = <String, Completer<List<GatewayEvent>>>{};

  @override
  Stream<GatewayMsg> get messages => _out.stream;

  @override
  bool get connected => _ws != null;

  /// 本机自配对：读 .device_secret → begin → confirm，全程只打 127.0.0.1。
  Future<String> pair() async {
    final secret = (await File(secretPath).readAsString()).trim();
    final client = HttpClient();
    try {
      Future<Map<String, dynamic>> post(String path) async {
        final req = await client.postUrl(Uri.parse('$baseUrl$path'));
        final resp = await req.close();
        final body = await resp.transform(utf8.decoder).join();
        if (resp.statusCode != 200) {
          throw StateError('配对失败 ${resp.statusCode}: $body');
        }
        return (jsonDecode(body) as Map).cast<String, dynamic>();
      }

      final begin = await post(
          '/api/pair/begin?secret=${Uri.encodeQueryComponent(secret)}');
      final code = begin['code'] as String;
      final confirm = await post(
          '/api/pair/confirm?code=${Uri.encodeQueryComponent(code)}'
          '&name=${Uri.encodeQueryComponent('desktop-workbench')}');
      return confirm['token'] as String;
    } finally {
      client.close();
    }
  }

  @override
  Future<void> connect() async {
    _token ??= await pair();
    final wsBase = baseUrl.replaceFirst('http', 'ws');
    final ws = await WebSocket.connect('$wsBase/ws?token=$_token');
    _ws = ws;
    _sub = ws.listen((data) {
      final j = (jsonDecode(data as String) as Map).cast<String, dynamic>();
      final msg = parseGatewayMessage(j);
      if (msg == null) return;
      if (msg is GmControl && msg.type == 'session') {
        final sid = msg.raw['sid'] as String? ?? '';
        if (!(_sessionCompleter?.isCompleted ?? true)) {
          _sessionCompleter!.complete(sid);
        }
      }
      if (msg is GmControl && msg.type == 'hello') {
        for (final e in parseReplay(msg.raw)) {
          _out.add(GmEvent(e));
        }
      }
      if (msg is GmControl && msg.type == 'history') {
        final sid = msg.raw['sid'] as String? ?? '';
        final waiter = _historyWaiters.remove(sid);
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(parseHistory(msg.raw));
        }
        // 对不上 waiter 的 sid（等待方已超时弃单等）直接丢弃，不乱配。
      }
      _out.add(msg);
    }, onDone: () {
      _ws = null;
      _out.add(const GmControl('closed', {}));
    }, onError: (Object e) {
      _out.add(GmControl('socket_error', {'error': '$e'}));
    });
  }

  void _send(Map<String, dynamic> obj) {
    final ws = _ws;
    if (ws == null) throw StateError('未连接');
    ws.add(jsonEncode(obj));
  }

  @override
  Future<String> newSession({required String cwd, required String title}) {
    _sessionCompleter = Completer<String>();
    _send({'type': 'new_session', 'cwd': cwd, 'title': title});
    return _sessionCompleter!.future;
  }

  @override
  void send(String sid, String text, {bool local = false}) {
    _send({'type': 'send', 'sid': sid, 'text': text, 'local': local});
  }

  @override
  void cancel(String sid) {
    _send({'type': 'cancel', 'sid': sid});
  }

  /// P2：按 sid 拉历史。WS 请求发出去就等 type=='history' 的响应，按
  /// raw['sid'] 归位到自己的 waiter；并发多路各拿各的，响应互不串线。
  /// 旧 gateway 不回话时 5s 超时按失败走（调用方显示真话，不挂死）。
  @override
  Future<List<GatewayEvent>> history(String sid, {int limit = 200}) {
    final completer = Completer<List<GatewayEvent>>();
    _historyWaiters[sid] = completer;
    _send({'type': 'history', 'sid': sid, 'limit': limit});
    return completer.future.timeout(const Duration(seconds: 5)).whenComplete(() {
      // 摘掉自己；若同 sid 已被更新的请求重新占位（旧的单例竞态教训），
      // 别误删别人。
      if (identical(_historyWaiters[sid], completer)) {
        _historyWaiters.remove(sid);
      }
    });
  }

  /// S1b：会话快照。token 走 query 参数（gateway.py check_device 的口径），
  /// 配对令牌复用 connect() 的 _token ??= await pair()。
  @override
  Future<List<GwSession>> listSessions() async {
    final token = _token ??= await pair();
    final client = HttpClient();
    try {
      final uri = Uri.parse('$baseUrl/api/sessions/snapshot')
          .replace(queryParameters: {'token': token});
      final req = await client.getUrl(uri);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        throw StateError('会话快照失败 ${resp.statusCode}: $body');
      }
      return parseSessions((jsonDecode(body) as Map).cast<String, dynamic>());
    } finally {
      client.close();
    }
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _ws?.close();
    _ws = null;
    await _out.close();
  }
}
