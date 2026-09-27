import 'dart:convert';

/// build93 阶段1（T2/T4）：原生工具通道（function calling）与标签通道的统一动作模型。
///
/// 设计要点（对应任务书四点八-B2/B3）：
/// - 主循环 tools 只含 web_search / ask_user / download / todo / memory_write /
///   memory_delete / mcp_call / get_location，**不含 suggest**（推荐走答案定稿后的独立轻量生成）。
/// - parallel_tool_calls=false：一轮至多一个 tool_call；一次多条靠 entries/items 数组承载。
/// - 最终答案不走工具，仍由 content 承载。
/// - MCP 远程工具按 6000 字符预算动态拼入为原生工具，命名 mcp__{pluginId}__{tool}。

/// 统一动作模型：工具调用与标签文本两条通道都归一成 AgentAction。
/// [fields] 与 react_parser 产出的 piece Map 同构（type/content/depth/scope/key/value/items...），
/// 使 chat_screen_react 分发循环不关心来源。
class AgentAction {
  final String type;
  final Map<String, String> fields;

  /// 'tools' = 原生工具通道；'tags' = 标签回退通道
  final String source;

  const AgentAction(this.type, this.fields, {this.source = 'tags'});

  /// 转回标签 piece 形态（分发循环零摩擦复用）
  Map<String, String> toPiece() => {'type': type, ...fields};

  @override
  String toString() => 'AgentAction($type, $fields, $source)';
}

// ---------------------------------------------------------------------------
// T2：内置动作工具 schema（OpenAI tools 格式）
// ---------------------------------------------------------------------------

Map<String, dynamic> _tool(
        String name, String description, Map<String, dynamic> parameters) =>
    {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': parameters,
      },
    };

Map<String, dynamic> _obj(Map<String, dynamic> props, List<String> required) =>
    {'type': 'object', 'properties': props, 'required': required};

/// build110（U9）：可路由的内置插件 triggerType——模型常把内置插件「函数化」
/// 调用（如直接调 log_query，实机日志实锤），同名时路由为对应动作而不是
/// 静默丢弃。已有专用 case 的（web_search/ask_user/download/todo/memory_*/
/// get_location/query_quota/mcp_call）到不了 default 分支，无需列入。
const Set<String> kBuiltinRoutableTriggers = {
  'self_check',
  'install_mcp',
  'install_skill',
  'connector_guide',
  'log_query',
  'ip_locate',
  // build122：生成类——FC 模型用同名函数调用时，路由为对应标签动作
  'image_gen',
  'video_gen',
};

/// 内置动作 tools（build113 起 9+6=15 个：9 原有 + ws_ 工作区 6 个，顺序即优先级）。
List<Map<String, dynamic>> builtinAgentToolSchemas() => [
      _tool(
        'web_search',
        '联网搜索。需要实时/不确定信息时调用，结果会以工具消息返回。',
        _obj({
          'query': {'type': 'string', 'description': '搜索关键词'},
          'depth': {
            'type': 'string',
            'enum': ['basic', 'advanced'],
            'description': '搜索深度，默认 basic'
          },
        }, ['query']),
      ),
      _tool(
        'ask_user',
        '信息不足必须向用户反问时调用。一轮至多调用一次；options 给 2~8 条候选，每条 ≤30 字，给不出就省略 options 只留问题。',
        _obj({
          'question': {'type': 'string', 'description': '要问用户的问题'},
          'options': {
            'type': 'array',
            'items': {'type': 'string', 'maxLength': 30},
            'minItems': 2,
            'maxItems': 8,
            'description': '候选选项（2~8 条，每条 ≤30 字，不重复）；不满足则省略',
          },
        }, ['question']),
      ),
      _tool(
        'download',
        '用户要下载/安装 App 时调用，触发下载流程。',
        _obj({
          'intent': {'type': 'string', 'description': '下载意图，如 wechat'},
          'canonical': {'type': 'string', 'description': '规范化应用名'},
          'platform': {'type': 'string', 'description': '目标平台，如 android'},
          'keywords': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '搜索关键词'
          },
          'domains': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '可信域名'
          },
        }, ['intent']),
      ),
      _tool(
        'todo',
        '多步任务（≥3 步）规划/更新待办清单。一次多条用 items 数组承载。',
        _obj({
          'action': {
            'type': 'string',
            'enum': ['add', 'done', 'clear'],
            'description': 'add=新增/替换清单；done=勾掉已完成项；clear=清空'
          },
          'items': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': '待办文本列表（action=add/done 时必填）'
          },
        }, ['action']),
      ),
      _tool(
        'memory_write',
        '把值得长期记住的用户偏好/事实写入记忆。一次多条用 entries 数组；scope 默认 global。',
        _obj({
          'entries': {
            'type': 'array',
            'items': _obj({
              'scope': {
                'type': 'string',
                'enum': ['global', 'project'],
                'description': '缺省或不确定一律 global；仅内容明显项目相关且当前会话属于项目时才 project'
              },
              'key': {'type': 'string', 'description': '记忆键，如 饮食偏好'},
              'value': {'type': 'string', 'description': '记忆值'},
            }, ['key', 'value']),
            'minItems': 1,
            'description': '要写入的记忆条目（可多条）'
          },
        }, ['entries']),
      ),
      _tool(
        // N8（build94）：记忆删除，与标签通道 <memory_delete> 对齐
        'memory_delete',
        '用户明确要求"忘掉/删除"某条记忆时调用，按 key 删除对应记忆；scope 默认 global。',
        _obj({
          'scope': {
            'type': 'string',
            'enum': ['global', 'project'],
            'description': '缺省或不确定一律 global'
          },
          'key': {'type': 'string', 'description': '要删除的记忆键，如 饮食偏好'},
        }, ['key']),
      ),
      _tool(
        'get_location',
        // build106：设备 GPS 精确定位（与标签通道 <get_location /> 同一插件分发）。
        '获取设备当前 GPS 位置（街道级，GCJ-02 高德坐标）。当用户问「我在哪/附近的/最近的/导航/打车/路线」等需要用户实时位置的问题时调用；'
            '用户已给出明确地址或只要城市级信息时不要调用。结果会以工具消息返回，坐标可直接传给高德 MCP 工具（注意用 "lng,lat" 顺序）。',
        _obj({}, []),
      ),
      _tool(
        'query_quota',
        // build108（Q1）：API 余额查询（与标签通道 <query_quota /> 同一插件分发）。
        '查询 API 配置的余额/用量（用户问「我的 API 还剩多少钱/余额/额度/用量」时调用）。结果逐条列出各配置的余额；不支持的端点会标注。',
        _obj({}, []),
      ),
      _tool(
        'mcp_call',
        '调用已安装的 MCP 远程工具（通用入口）。仅当目标工具没有作为独立原生工具列出时使用。',
        _obj({
          'plugin_id': {'type': 'string', 'description': 'MCP 插件 id'},
          'tool': {'type': 'string', 'description': '工具名'},
          'arguments': {
            'type': 'object',
            'description': '工具参数（顶层必须是 object）'
          },
        }, ['plugin_id', 'tool']),
      ),
      _tool(
        'ws_list',
        '列出 AI 文件工作区（沙箱目录）内的全部文本文件（相对路径+大小）。无参数。',
        _obj({}, []),
      ),
      _tool(
        'ws_read',
        '读取工作区内的文件并回灌（超 3 万字截断标注）：文本原样返回，'
        'xlsx/docx/pdf 走 App 的文档解析器抽成文本，所以自己生成的表格也能读回来核对。',
        _obj({
          'path': {'type': 'string', 'description': '工作区内相对路径，如 notes/todo.md'},
        }, ['path']),
      ),
      _tool(
        'ws_write',
        '向工作区写入/改写文本文件（写前用户会看到确认框，取消则不写；默认不覆盖，覆盖需 overwrite=true）。单次 ≤8000 字。',
        _obj({
          'path': {'type': 'string', 'description': '工作区内相对路径'},
          'content': {'type': 'string', 'description': '要写入的文本内容（≤8000 字）'},
          'overwrite': {'type': 'boolean', 'description': '是否覆盖同名文件，默认 false'},
        }, ['path', 'content']),
      ),
      _tool(
        'ws_delete',
        '删除工作区内的文件（删前用户会看到确认框，取消则不删）。',
        _obj({
          'path': {'type': 'string', 'description': '工作区内相对路径'},
        }, ['path']),
      ),
      _tool(
        'ws_download',
        '把网络上的文本类文件下载进工作区（仅 https、≤10MB、txt/md/json/csv/log/xml/html/代码文本；二进制拒绝）。',
        _obj({
          'url': {'type': 'string', 'description': 'https 直链'},
          'filename': {'type': 'string', 'description': '保存文件名（缺省取 URL 末段）'},
        }, ['url']),
      ),
      _tool(
        'ws_export',
        '把工作区文件分享出去（系统分享面板）或用系统方式打开。',
        _obj({
          'path': {'type': 'string', 'description': '工作区内相对路径'},
          'mode': {'type': 'string', 'enum': ['share', 'open'], 'description': 'share=分享面板（默认） open=系统打开'},
        }, ['path']),
      ),
      // build136（G66/G67）：写代码两件套（与标签通道同构）
      _tool(
        'ws_patch',
        '在工作区文件内做定位式替换（事务式：find 找不到或不唯一则整体不改并回报行号）。改代码优先用它，不要整文件重写。',
        _obj({
          'path': {'type': 'string', 'description': '工作区内相对路径'},
          'find': {'type': 'string', 'description': '原文片段，须与原文逐字一致并带足上下文使其唯一'},
          'replace': {'type': 'string', 'description': '替换成的新片段'},
          'all': {'type': 'boolean', 'description': '是否替换全部匹配，默认 false（仅第一处）'},
        }, ['path', 'find', 'replace']),
      ),
      _tool(
        'ws_grep',
        '在工作区文本文件里按正则检索，返回「文件:行号: 内容」（上限 200 行），用于定位符号再精确作业。',
        _obj({
          'pattern': {'type': 'string', 'description': '正则表达式'},
          'glob': {'type': 'string', 'description': '文件名过滤，如 *.dart；缺省扫全部文本文件'},
          'ignore_case': {'type': 'boolean', 'description': '是否忽略大小写，默认 false'},
        }, ['pattern']),
      ),
      // build138（G61–G64）：生成真文件。注意 schema **只有文本字段**——
      // 没有 base64 / bytes / dataUrl 之类的口子（任务书 G64 红线：
      // 「ws_make_file schema 无 base64/二进制字段」），二进制一律由
      // 设备本地渲染器产出，不从模型侧传字节。
      _tool(
        'ws_make_file',
        '把文本数据在设备本地渲染成真正的 Excel(.xlsx) / Word(.docx) / PDF(.pdf) 文件存进工作区'
            '（纯数据兜底用 .csv）。content 只接受文本：表格用 CSV 或制表符分隔（一行一条记录，'
            '多工作表用「## sheet: 名称」分节），文档用 markdown 正文（# 标题、段落、|a|b| 表格行）。'
            '写前用户会看到确认框，取消则不生成。禁止传 base64/二进制（会被拒）。'
            '生成后用 ws_export（mode=open|share）打开或分享，不要编造下载链接。',
        _obj({
          'path': {
            'type': 'string',
            'description': '工作区内相对路径，建议 exports/名称.xlsx；缺省按类型自动命名'
          },
          'kind': {
            'type':
                'string', // 缺省取 path 的扩展名；两者都给时必须一致
            'enum': ['xlsx', 'docx', 'pdf', 'csv', 'md', 'txt'],
            'description': '生成类型'
          },
          'content': {
            'type': 'string',
            'description': '文本载荷（≤16000 字符），不接受 base64/二进制'
          },
          'title': {'type': 'string', 'description': '文档标题（docx/pdf 首页）'},
          'overwrite': {
            'type': 'boolean',
            'description': '是否覆盖同名文件，默认 false'
          },
        }, ['content']),
      ),
    ];

// ---------------------------------------------------------------------------
// MCP 远程工具动态拼入（6000 字符预算，与 api_service 提示词预算一致）
// ---------------------------------------------------------------------------

const int kMcpToolSchemaBudget = 6000;

String _sanitizeToolNamePart(String s) =>
    s.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

/// N10：MCP 工具名注册表不再是全局单例——按一次 ReAct 循环（一条用户消息）
/// 为界创建局部实例，多会话/多插件并发互不串名。
typedef McpToolNameRegistry = Map<String, (String, String)>;

/// 原生工具名 → (pluginId, tool)。非 MCP 命名返回 null。
/// 注意：pluginId 中的分隔符已被替换为 _，无法无损还原，
/// 因此必须携带 buildAgentTools 同期写入的 [registry] 做精确反查。
(String, String)? parseMcpToolName(String name, McpToolNameRegistry registry) {
  final hit = registry[name];
  if (hit != null) return hit;
  return null;
}

/// 组装完整 tools 列表：内置 6 个 + MCP 远程工具（预算内）。
/// [mcpPlugins] 元素需有 metadata.id 与 metadata.extra['tools']（List of Map，
/// 含 name/description/inputSchema）。为避免耦合插件接口，传入解构后的记录。
/// [registry]：MCP 原生名反查表，由调用方持有（随本次循环生命周期），
/// 本函数每次调用先 clear 再重建；不传则无法反查 MCP 原生名。
List<Map<String, dynamic>> buildAgentTools({
  List<({String pluginId, List<Map<String, dynamic>> tools})> mcpPlugins =
      const [],
  McpToolNameRegistry? registry,
}) {
  final tools = builtinAgentToolSchemas();
  registry?.clear();
  if (mcpPlugins.isEmpty) return tools;

  var used = 0;
  for (final plugin in mcpPlugins) {
    for (final raw in plugin.tools) {
      final name = raw['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final description = (raw['description']?.toString() ?? '').trim();
      final schema = raw['inputSchema'] ?? raw['input_schema'];
      final schemaMap = schema is Map
          ? Map<String, dynamic>.from(schema)
          : <String, dynamic>{'type': 'object', 'properties': {}};
      final nativeName =
          'mcp__${_sanitizeToolNamePart(plugin.pluginId)}__${_sanitizeToolNamePart(name)}';
      final entry = _tool(
        nativeName,
        description.isEmpty ? 'MCP 工具 $name（来自 ${plugin.pluginId}）' : description,
        schemaMap,
      );
      final cost = jsonEncode(entry).length;
      if (used + cost > kMcpToolSchemaBudget) continue;
      tools.add(entry);
      registry?[nativeName] = (plugin.pluginId, name);
      used += cost;
    }
  }
  return tools;
}

// ---------------------------------------------------------------------------
// T4：双通道归一化适配器
// ---------------------------------------------------------------------------

/// tool_calls（非流式已 jsonDecode 完毕，或流式聚合完毕后）→ List<AgentAction>
/// [calls] 元素：{'id': String?, 'name': String, 'arguments': Map<String,dynamic>}
/// [registry]：N10 局部注册表（buildAgentTools 同期产物），用于反查 MCP 原生名。
List<AgentAction> actionsFromToolCalls(List<Map<String, dynamic>> calls,
    {McpToolNameRegistry? registry}) {
  final out = <AgentAction>[];
  for (final call in calls) {
    final name = call['name']?.toString() ?? '';
    final args = call['arguments'];
    final argMap = args is Map
        ? Map<String, dynamic>.from(args)
        : <String, dynamic>{};
    final action = _actionFromSingleCall(name, argMap, registry);
    if (action != null) out.add(action);
  }
  return out;
}

AgentAction? _actionFromSingleCall(
    String name, Map<String, dynamic> args, McpToolNameRegistry? registry) {
  switch (name) {
    case 'web_search':
      return AgentAction('search', {
        'content': (args['query'] ?? '').toString(),
        if (args['depth'] != null) 'depth': args['depth'].toString(),
      }, source: 'tools');
    case 'ask_user':
      // N1（build94）：选项并入 content（与标签协议同构：content = 问题||选项1||选项2），
      // 消费端 AskUserPlugin.handle 只 split content，独立 options 字段会被丢弃。
      final question = (args['question'] ?? '').toString();
      final options = args['options'] is List
          ? (args['options'] as List)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .join('||')
          : '';
      return AgentAction('ask_user', {
        'content': options.isEmpty ? question : '$question||$options',
      }, source: 'tools');
    case 'download':
      String joinList(String k) => args[k] is List
          ? (args[k] as List).map((e) => e.toString()).join(',')
          : (args[k]?.toString() ?? '');
      // build97 (P1-4 修复)：双通道语义对齐。
      // schema 里 intent 的描述是「下载意图，如 wechat」——模型把意图/应用名
      // 填进 intent；而标签插件把 intent 当布尔标记（true/1/yes/是），
      // 直接透传会导致 intentTrue=false → 静默 return（tools 通道下
      // 「帮我下载微信」完全无反应）。模型调用 download 工具本身即代表意图成立，
      // 故 intent 固定为 'true'；canonical 缺省时 intent 的值当应用名兜底。
      final intentVal = (args['intent'] ?? '').toString().trim();
      final canonicalVal = (args['canonical'] ?? '').toString().trim();
      final effectiveCanonical =
          canonicalVal.isNotEmpty ? canonicalVal : intentVal;
      return AgentAction('download', {
        'intent': 'true',
        'content': effectiveCanonical,
        'platform': (args['platform'] ?? '').toString(),
        'keywords': joinList('keywords'),
        'domains': joinList('domains'),
      }, source: 'tools');
    case 'todo':
      final items = args['items'] is List
          ? (args['items'] as List).map((e) => e.toString()).join('||')
          : '';
      return AgentAction('todo', {
        'action': (args['action'] ?? 'add').toString(),
        'items': items,
      }, source: 'tools');
    case 'memory_write':
      // entries 数组 → 一次调用展开成多条 memory_write 动作（B3）
      final entries = args['entries'];
      if (entries is! List || entries.isEmpty) return null;
      final first = entries.first;
      if (first is! Map) return null;
      // 多条时由 actionsFromToolCalls 外层展开，这里只处理单条形态
      return _memoryEntryToAction(Map<String, dynamic>.from(first));
    case 'memory_delete':
      // N8（build94）：与标签通道 piece 同构（scope/key）
      return AgentAction('memory_delete', {
        'scope': (args['scope'] ?? 'global').toString(),
        'key': (args['key'] ?? '').toString(),
      }, source: 'tools');
    case 'get_location':
      // build106：无参数定位动作，与标签通道 <get_location /> 同构（空字段）
      return const AgentAction('get_location', {}, source: 'tools');
    case 'query_quota':
      // build108（Q1）：无参数余额查询动作，与标签通道 <query_quota /> 同构
      return const AgentAction('query_quota', {}, source: 'tools');
    // build113（任务五 WS-2）：AI 文件工作区 6 动作（与标签通道同构）
    case 'ws_list':
      return const AgentAction('ws_list', {}, source: 'tools');
    case 'ws_read':
      return AgentAction('ws_read', {
        'path': (args['path'] ?? '').toString(),
      }, source: 'tools');
    case 'ws_write':
      return AgentAction('ws_write', {
        'path': (args['path'] ?? '').toString(),
        'content': (args['content'] ?? '').toString(),
        'overwrite': (args['overwrite'] == true).toString(),
      }, source: 'tools');
    case 'ws_delete':
      return AgentAction('ws_delete', {
        'path': (args['path'] ?? '').toString(),
      }, source: 'tools');
    case 'ws_download':
      return AgentAction('ws_download', {
        'url': (args['url'] ?? '').toString(),
        'filename': (args['filename'] ?? '').toString(),
      }, source: 'tools');
    case 'ws_export':
      return AgentAction('ws_export', {
        'path': (args['path'] ?? '').toString(),
        'mode': (args['mode'] ?? 'share').toString(),
      }, source: 'tools');
    // build136（G66/G67）：写代码两件套
    case 'ws_patch':
      return AgentAction('ws_patch', {
        'path': (args['path'] ?? '').toString(),
        'find': (args['find'] ?? '').toString(),
        'replace': (args['replace'] ?? '').toString(),
        'all': (args['all'] == true).toString(),
      }, source: 'tools');
    case 'ws_grep':
      return AgentAction('ws_grep', {
        'pattern': (args['pattern'] ?? '').toString(),
        'glob': (args['glob'] ?? '').toString(),
        'ignore_case': (args['ignore_case'] == true).toString(),
      }, source: 'tools');
    // build138（G61-G64）：生成真文件（与标签通道 <ws_make_file/> 同一个插件，
    // 两条通道各调一次的结果必须一致 —— 见 build138_g63_g64_workspace_test）
    case 'ws_make_file':
      return AgentAction('ws_make_file', {
        'path': (args['path'] ?? '').toString(),
        'kind': (args['kind'] ?? '').toString(),
        'content': (args['content'] ?? '').toString(),
        'title': (args['title'] ?? '').toString(),
        'overwrite': (args['overwrite'] == true).toString(),
      }, source: 'tools');
    case 'mcp_call':
      final arguments = args['arguments'];
      return AgentAction('mcp_call', {
        'pluginId': (args['plugin_id'] ?? '').toString(),
        'tool': (args['tool'] ?? '').toString(),
        'arguments':
            arguments is Map ? jsonEncode(arguments) : '{}',
      }, source: 'tools');
    default:
      // build110（U9 日志实锤）：模型把内置插件当函数调用（如 log_query）——
      // 与内置插件 triggerType 同名时路由为对应动作（参数键值平移进 fields），
      // 不再静默丢弃。build116（检测批）：大小写不敏感（模型偶发 LOG_QUERY）
      final lowerName = name.toLowerCase();
      if (kBuiltinRoutableTriggers.contains(lowerName)) {
        final fields = <String, String>{};
        args.forEach((key, value) {
          if (value == null) return;
          fields[key.toString()] = value is bool
              ? (value ? 'true' : 'false')
              : (value is List || value is Map)
                  ? jsonEncode(value)
                  : value.toString();
        });
        return AgentAction(lowerName, fields, source: 'tools');
      }
      // MCP 原生工具（mcp__plugin__tool）
      final mcp = registry == null ? null : parseMcpToolName(name, registry);
      if (mcp != null) {
        return AgentAction('mcp_call', {
          'pluginId': mcp.$1,
          'tool': mcp.$2,
          'arguments': jsonEncode(args),
        }, source: 'tools');
      }
      return null;
    }
}

AgentAction? _memoryEntryToAction(Map<String, dynamic> entry) => AgentAction(
      'memory_write',
      {
        'scope': (entry['scope'] ?? 'global').toString(),
        'key': (entry['key'] ?? '').toString(),
        'value': (entry['value'] ?? '').toString(),
      },
      source: 'tools',
    );

/// memory_write 的 entries 数组需要展开成多条动作（一次调用写多条）。
/// 对其它工具等价于 actionsFromToolCalls。
List<AgentAction> actionsFromToolCallsExpanded(
    List<Map<String, dynamic>> calls,
    {McpToolNameRegistry? registry}) {
  final out = <AgentAction>[];
  for (final call in calls) {
    final name = call['name']?.toString() ?? '';
    final args = call['arguments'];
    final argMap =
        args is Map ? Map<String, dynamic>.from(args) : <String, dynamic>{};
    if (name == 'memory_write' && argMap['entries'] is List) {
      for (final e in (argMap['entries'] as List)) {
        if (e is Map) {
          final a = _memoryEntryToAction(Map<String, dynamic>.from(e));
          if (a != null) out.add(a);
        }
      }
      continue;
    }
    final action = _actionFromSingleCall(name, argMap, registry);
    if (action != null) out.add(action);
  }
  return out;
}

/// 标签通道 piece（parseReActOutput 产出）→ List<AgentAction>
List<AgentAction> actionsFromTagPieces(List<Map<String, String>> parsed) =>
    parsed
        .where((p) => p['type'] != null)
        .map((p) => AgentAction(p['type']!,
            Map<String, String>.from(p)..remove('type'),
            source: 'tags'))
        .toList();

// ---------------------------------------------------------------------------
// N2（build94）：双通道合流排序 + 跨通道去重
//
// 问题：此前 chat_screen_react 把 FC 动作无脑 addAll 到标签解析数组尾部，导致——
//  ① 同轮 content 先出 answer、tool_calls 带 ask_user 时，answer 先置 answered，
//     FC 的 ask_user 被 P1 守卫当主动件丢弃（信息没补全却定稿）；
//  ② 同轮标签一个 ask_user + FC 一个 ask_user 时不去重，连弹两个窗（U1 真机现象）。
// 本函数是纯函数，输出顺序：thinking → memory_write/memory_delete/todo → answer → suggest → 交互动作；
// ask_user 跨通道全局只保留一个（选项更完整者优先）；answer 与 ask_user 同轮时 ask_user 优先。
// ---------------------------------------------------------------------------

const List<String> _kPassiveTypes = [
  'memory_write',
  'memory_delete',
  'todo',
  'suggest',
];

int _mergeRank(String type) {
  switch (type) {
    case 'thinking':
      return 0;
    case 'memory_write':
    case 'memory_delete':
    case 'todo':
      return 1;
    case 'answer':
      return 2;
    case 'suggest':
      return 3;
    default: // ask_user / search / download / mcp_call / card / self_check 等交互动作
      return 4;
  }
}

/// ask_user 的「选项完整度」：选项多则内容更长，用于跨通道去重时选优
int _askUserCompleteness(AgentAction a) =>
    (a.fields['content'] ?? '').length;

/// 工作区动作的「目标文件」键：类型 + 生成类型 + 相对路径。
/// path 缺省（两通道都可能不写）时留空——同类型缺省名相同，仍是同一目标。
String _wsTargetKey(AgentAction a) =>
    '${a.type}|${(a.fields['kind'] ?? '').trim()}|${(a.fields['path'] ?? '').trim()}';

/// 工作区动作的归一化字段签名（跨通道同参比对的口径）。
///
/// 两通道对同一个动作的字段形态并不一致：FC 通道由 [_actionFromSingleCall]
/// 补齐全部键（不传即空串），标签通道只有模型真写了的属性；`overwrite` 一边
/// 省略一边显式 `"false"` 也是同一件事。不归一就会「看起来已去重」实则漏掉。
String _wsNormalizedFields(AgentAction a) {
  // 布尔开关缺省 false：FC 会显式补齐（overwrite:'false'），标签只写模型
  // 真给了的属性。不归一就会「看起来已去重」实则漏掉。
  const boolSwitches = {'overwrite', 'all'};
  final norm = <String, String>{};
  for (final e in a.fields.entries) {
    final v = e.value.trim();
    if (v.isEmpty) continue;
    if (boolSwitches.contains(e.key) && v.toLowerCase() == 'false') continue;
    norm[e.key] = v;
  }
  final keys = norm.keys.toList()..sort();
  return keys.map((k) => '$k=${norm[k]}').join('&');
}

/// 合流：把标签通道动作与 FC 通道动作合并成统一序列。
/// [tagActions] 已按解析顺序；[toolActions] 为 FC 通道动作。
List<AgentAction> mergeChannelActions(
  List<AgentAction> tagActions,
  List<AgentAction> toolActions, {
  void Function(String)? onLog,
}) {
  // 1) 跨通道 ask_user 去重：只保留一个（选项更完整者优先；并列时 FC 优先，因其经过 schema 约束）
  final all = [...tagActions, ...toolActions];
  final asks = all.where((a) => a.type == 'ask_user').toList();
  AgentAction? keepAsk;
  if (asks.isNotEmpty) {
    keepAsk = asks.reduce((best, cur) {
      final bc = _askUserCompleteness(best);
      final cc = _askUserCompleteness(cur);
      if (cc > bc) return cur;
      if (cc == bc && cur.source == 'tools') return cur;
      return best;
    });
    if (asks.length > 1) {
      onLog?.call(
          'N2 merge: ${asks.length} 个 ask_user 跨通道/同通道去重，保留 ${keepAsk.source} 源（${asks.map((a) => '${a.source}:${_askUserCompleteness(a)}字').join(' vs ')}）');
    }
  }

  // 2) answer 与 ask_user 同轮：ask_user 优先，answer 丢弃（信息没补全不定稿）
  AgentAction? answer =
      all.where((a) => a.type == 'answer').cast<AgentAction?>().firstOrNull;
  if (keepAsk != null && answer != null) {
    onLog?.call(
        'N2 merge: answer 与 ask_user 同轮，ask_user 优先，丢弃 answer（${answer.source} 源 ${(answer.fields['content'] ?? '').length} 字）');
    answer = null;
  }

  // 3) build138（G64 红线）：工作区落盘类动作跨通道去重，两条规则——
  //  3a. 「同一目标文件」规则（ws_make_file / ws_write）：
  //      同一轮里标签通道与 FC 通道各发一个指向同一个文件的生成/写入时，
  //      第二次必然撞 overwrite 语义被拒（或把第一次的成果覆盖掉），用户看到的
  //      就是「同一份文件生成两次 / 报一次错」—— 与 U1 的双弹窗同型。
  //      目标键 = 类型 + 生成类型 + 相对路径（缺省名视为同一目标，因同类型缺省名相同）；
  //      同键只保留 content 更完整的那个（并列时留 FC，因其经过 schema 约束）。
  const oncePerTarget = {'ws_make_file', 'ws_write'};
  //  3b. 「完全同参」规则（全部工作区动作，含 ws_patch / ws_delete / ws_download）：
  //      同一份补丁应用两遍＝第二遍 find 文本已不存在 → 整体拒绝并回灌 failed，
  //      模型下一轮看到「刚改完又说找不到」，自相矛盾。同参即同一件事，只跑一次。
  //      两通道字段形态不同（FC 会补齐空串、标签只给写了的属性），故先归一化再比对。
  const exactOnceTypes = {
    'ws_make_file',
    'ws_write',
    'ws_patch',
    'ws_delete',
    'ws_download',
    'ws_export',
  };
  final bestByTarget = <String, AgentAction>{};
  final droppedTargets = <String>[];
  for (final a in all) {
    if (!oncePerTarget.contains(a.type)) continue;
    final key = _wsTargetKey(a);
    final prev = bestByTarget[key];
    if (prev == null) {
      bestByTarget[key] = a;
      continue;
    }
    final pc = (prev.fields['content'] ?? '').length;
    final cc = (a.fields['content'] ?? '').length;
    AgentAction keep = prev;
    if (cc > pc || (cc == pc && a.source == 'tools')) keep = a;
    droppedTargets.add('$key（丢弃 ${keep == prev ? a.source : prev.source} 源）');
    bestByTarget[key] = keep;
  }
  if (droppedTargets.isNotEmpty) {
    onLog?.call('N2 merge: 同目标文件跨通道去重 ${droppedTargets.length} 个：'
        '${droppedTargets.join('；')}');
  }
  bool isDupTarget(AgentAction a) {
    if (!oncePerTarget.contains(a.type)) return false;
    return !identical(bestByTarget[_wsTargetKey(a)], a);
  }

  // 4) 被动件跨通道去重：同 type+同内容只留一份（两通道各写一个 memory_write 不重复落库）
  final seenPassive = <String>{};
  final seenExactWs = <String>{};
  bool isDupPassive(AgentAction a) {
    if (!_kPassiveTypes.contains(a.type)) return false;
    // N15 修复：scope 缺省两通道不一致（标签=''，FC='global'），签名前归一，否则同记忆去重失效
    final norm = Map<String, String>.from(a.fields);
    if ((norm['scope'] ?? '').isEmpty) norm['scope'] = 'global';
    final sig = '${a.type}|${norm.toString()}';
    if (seenPassive.contains(sig)) return true;
    seenPassive.add(sig);
    return false;
  }

  bool isDupExactWs(AgentAction a) {
    if (!exactOnceTypes.contains(a.type)) return false;
    final sig = '${a.type}|${_wsNormalizedFields(a)}';
    if (seenExactWs.contains(sig)) return true;
    seenExactWs.add(sig);
    return false;
  }

  final out = <AgentAction>[];
  final thinking = <AgentAction>[];
  final passive = <AgentAction>[];
  final interactive = <AgentAction>[];
  for (final a in all) {
    if (a.type == 'ask_user' && !identical(a, keepAsk)) continue;
    if (a.type == 'answer') {
      if (answer != null && identical(a, answer)) {
        // answer 由下方统一插入（保证在 passive 之后、suggest 之前）
      } else {
        continue;
      }
      continue;
    }
    if (isDupTarget(a)) {
      onLog?.call('N2 merge: 丢弃同目标重复生成件 ${a.type}（${a.source} 源）');
      continue;
    }
    if (isDupExactWs(a)) {
      onLog?.call('N2 merge: 丢弃跨通道同参工作区动作 ${a.type}（${a.source} 源）');
      continue;
    }
    if (isDupPassive(a)) {
      onLog?.call('N2 merge: 丢弃跨通道重复被动件 ${a.type}');
      continue;
    }
    switch (_mergeRank(a.type)) {
      case 0:
        thinking.add(a);
      case 1:
      case 3:
        passive.add(a);
      default:
        interactive.add(a);
    }
  }
  out.addAll(thinking);
  out.addAll(passive.where((a) => _mergeRank(a.type) == 1));
  if (answer != null) out.add(answer);
  out.addAll(passive.where((a) => _mergeRank(a.type) == 3));
  out.addAll(interactive);
  return out;
}

// ---------------------------------------------------------------------------
// T3b：流式 tool_calls 分片聚合器
// delta.tool_calls[] 按 index 区分多次调用；id/name 通常只在首片；
// function.arguments 是分片 JSON 字符串，必须按 index 累加后再 jsonDecode。
// ---------------------------------------------------------------------------

class ToolCallDeltaAccumulator {
  final Map<int, _MutableToolCall> _byIndex = {};

  /// 喂入一个 delta.tool_calls 数组元素（Map）
  void applyDelta(Map<String, dynamic> delta) {
    final idx = (delta['index'] as num?)?.toInt() ?? 0;
    final slot = _byIndex.putIfAbsent(idx, () => _MutableToolCall());
    final id = delta['id']?.toString();
    if (id != null && id.isNotEmpty) slot.id = id;
    final fn = delta['function'];
    if (fn is Map) {
      final name = fn['name']?.toString();
      if (name != null && name.isNotEmpty) slot.name = name;
      final argsChunk = fn['arguments']?.toString();
      if (argsChunk != null && argsChunk.isNotEmpty) {
        slot.args.write(argsChunk);
      }
    }
  }

  bool get isEmpty => _byIndex.isEmpty;

  /// 流末聚合：按 index 排序，逐个 jsonDecode arguments。
  /// arguments JSON 损坏时该条跳过（记 invalidCount），不拖垮其它调用。
  List<Map<String, dynamic>> finish({void Function(String)? onInvalid}) {
    final keys = _byIndex.keys.toList()..sort();
    final out = <Map<String, dynamic>>[];
    for (final k in keys) {
      final slot = _byIndex[k]!;
      if (slot.name.isEmpty) continue;
      Map<String, dynamic> args;
      final raw = slot.args.toString();
      if (raw.trim().isEmpty) {
        args = <String, dynamic>{};
      } else {
        try {
          final decoded = jsonDecode(raw);
          args = decoded is Map
              ? Map<String, dynamic>.from(decoded)
              : <String, dynamic>{};
        } catch (_) {
          onInvalid?.call('tool_call[$k] ${slot.name} arguments JSON 损坏: '
              '${raw.length > 80 ? raw.substring(0, 80) : raw}');
          continue;
        }
      }
      out.add({'id': slot.id, 'name': slot.name, 'arguments': args});
    }
    return out;
  }
}

class _MutableToolCall {
  String id = '';
  String name = '';
  final StringBuffer args = StringBuffer();
}
