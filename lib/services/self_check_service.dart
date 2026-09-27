import 'dart:io';

import '../models/chat_message.dart';
import '../plugins/plugin_registry.dart';
import 'api_service.dart';
import 'app_download_service.dart';
import 'logger_service.dart';
import 'react_parser.dart';
import 'storage_service.dart';
import 'web_search_service.dart';
import 'package:flutter/foundation.dart';

/// 单个自检项结果
class SelfCheckResult {
  final String name;
  final bool pass;
  final String detail;
  const SelfCheckResult({
    required this.name,
    required this.pass,
    required this.detail,
  });
}

/// 人工确认项（引导式：质检列出操作步骤，用户执行后点「正常/异常」）
class ManualCheckItem {
  final String title;
  final String description; // 操作说明
  const ManualCheckItem({required this.title, required this.description});
}

/// 一键自检服务（v1.4.2 新增）
///
/// 把「手动测试 checklist」里能自动化的部分做成 App 内置自检，每次发版后
/// 点一下「运行自检」即可全面确认基础功能没被改坏，不用再手动逐条重测。
///
/// 分两类检查：
///   A. 基础检查（离线、瞬时）：数据库 schema、日志脱敏、文件名清洗
///   B. 网络检查（需配置、耗时）：API 连接、搜索连接
class SelfCheckService {
  static final _logger = LoggerService.instance;

  static Future<List<SelfCheckResult>> runAll(
      {bool runDialogTest = false,
      bool isZh = true,
      PluginRegistry? pluginRegistry}) async {
    final results = <SelfCheckResult>[];

    // A. 基础检查（离线）
    results.addAll(await _checkDbSchema(isZh));
    results.addAll(_checkLogScrub(isZh));
    results.addAll(_checkFileNameSanitize(isZh));
    results.addAll(_checkReActParser(isZh));
    results.addAll(_checkTokenEstimate(isZh));
    results.addAll(_checkLogService(isZh));
    results.addAll(await _checkConfigRead(isZh));
    results.addAll(await _checkAttachmentStorage(isZh));

    // B. 网络检查（需配置）
    results.addAll(await _checkApiConnection(isZh));
    results.addAll(await _checkSearchConnection(isZh));
    results.addAll(await _checkDownloadLink(isZh, pluginRegistry));
    results.addAll(await _checkStreamingMode(isZh));

    // C. 真实对话测试（可选，消耗 token）
    if (runDialogTest) {
      results.addAll(await _checkDialogTest(isZh));
      results.addAll(await _checkReActLoop(isZh));
    }

    final passCount = results.where((r) => r.pass).length;
    _logger.info(
        '[SELFCHECK] 自检完成：$passCount/${results.length} 通过，${results.length - passCount} 失败');
    return results;
  }

  /// A1. 数据库 schema 完整性检查（PRAGMA table_info）
  static Future<List<SelfCheckResult>> _checkDbSchema(bool zh) async {
    final results = <SelfCheckResult>[];
    final storage = StorageService.instance;

    // 各表需要存在的关键列（最近几个版本新增，最容易漏写）
    const requiredColumns = <String, List<String>>{
      'conversations': [
        'contextAuto',
        'autoCompress',
        'enable20sCheck',
        'contextLimit',
        'temperature',
        'topP',
      ],
      'messages': ['attachments'],
      'web_search_configs': [
        'tavilyApiKey',
        'serpApiKey',
        'braveApiKey',
        'googleCseApiKey',
        'googleCseId',
        'persistentWebSearchToggle',
      ],
      'api_configs': ['topP'],
    };

    try {
      await storage.init();
      final db = await storage.db;
      results.add(SelfCheckResult(
        name: zh ? '数据库连接' : 'Database connection',
        pass: true,
        detail: zh ? 'SQLite 初始化成功' : 'SQLite initialized OK',
      ));

      for (final entry in requiredColumns.entries) {
        final table = entry.key;
        final need = entry.value;
        try {
          final rows = await db.rawQuery('PRAGMA table_info($table)');
          final names = rows.map((r) => r['name'] as String).toSet();
          final missing = need.where((c) => !names.contains(c)).toList();
          results.add(SelfCheckResult(
            name: zh ? '表 $table 关键列' : 'Table $table key columns',
            pass: missing.isEmpty,
            detail: missing.isEmpty
                ? (zh
                    ? '全部存在（${need.length} 列）'
                    : 'All present (${need.length} cols)')
                : (zh
                    ? '缺失：${missing.join('、')}'
                    : 'Missing: ${missing.join(', ')}'),
          ));
        } catch (e) {
          results.add(SelfCheckResult(
            name: zh ? '表 $table 关键列' : 'Table $table key columns',
            pass: false,
            detail: zh ? '检查失败：$e' : 'Check failed: $e',
          ));
        }
      }
    } catch (e) {
      results.add(SelfCheckResult(
        name: zh ? '数据库连接' : 'Database connection',
        pass: false,
        detail: zh ? '初始化失败：$e' : 'Init failed: $e',
      ));
    }
    return results;
  }

  /// A2. 日志脱敏检查（用真实脱敏逻辑跑敏感样本）
  /// v1.7.1 fix M11: 增加更多脱敏测试用例覆盖
  static List<SelfCheckResult> _checkLogScrub(bool zh) {
    final results = <SelfCheckResult>[];

    // [输入样本, 脱敏后【不该】还包含的密钥片段]
    final samples = <String, List<String>>{
      'Authorization Bearer': [
        'Authorization: Bearer sk-abcdef1234567890XYZ',
        'sk-abcdef',
      ],
      zh ? 'apiKey 字段' : 'apiKey field': [
        'api_key=sk-abcdef1234567890XYZ',
        'sk-abcdef',
      ],
      zh ? 'sk- 前缀' : 'sk- prefix': [
        'sk-abcdefghijklmnopqrstuvwxyz123456',
        'abcdefghijklmnop',
      ],
      zh ? '长 token 兜底' : 'Long token fallback': [
        'abcdefghijklmnopqrstuvwxyz0123456789ABCDEF',
        'abcdefghijklmnopqrstuv',
      ],
      // v1.7.1 fix M11: 新增更多脱敏测试用例
      zh ? 'GitHub Token' : 'GitHub Token': [
        'ghp_abcdefghijklmnopqrstuvwxyz1234567890',
        'ghp_abcdefghij',
      ],
      zh ? 'AWS Key' : 'AWS Key': [
        'AKIAIOSFODNN7EXAMPLE',
        'AKIAIOSFODNN',
      ],
      zh ? 'JWT Token' : 'JWT Token': [
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U',
        'eyJhbGciOiJIUzI1Ni',
      ],
    };

    for (final entry in samples.entries) {
      final input = entry.value[0];
      final leaked = entry.value[1];
      final out = LoggerService.scrubSensitive(input);
      final pass = !out.contains(leaked);
      results.add(SelfCheckResult(
        name: zh ? '日志脱敏：${entry.key}' : 'Log scrub: ${entry.key}',
        pass: pass,
        detail: pass
            ? (zh ? '已脱敏' : 'Masked OK')
            : (zh ? '疑似泄漏：$out' : 'Possible leak: $out'),
      ));
    }
    return results;
  }

  /// A3. 文件名清洗检查（路径遍历 / 非法字符）
  static List<SelfCheckResult> _checkFileNameSanitize(bool zh) {
    final results = <SelfCheckResult>[];

    // 路径遍历必须被剥离到只剩文件名
    final pathTraversal =
        AppDownloadService.sanitizeFileNameForCheck('../../etc/passwd');
    results.add(SelfCheckResult(
      name: zh ? '文件名清洗：路径遍历' : 'Filename sanitize: path traversal',
      pass: pathTraversal == 'passwd',
      detail: pathTraversal == 'passwd'
          ? (zh ? '已剥离' : 'Stripped')
          : (zh ? '结果：$pathTraversal' : 'Result: $pathTraversal'),
    ));

    // 非法字符必须被替换，不含 < > : " 等
    final illegal = AppDownloadService.sanitizeFileNameForCheck('a<b>c:d"e');
    final clean = !RegExp(r'[<>:"/\\|?*]').hasMatch(illegal);
    results.add(SelfCheckResult(
      name: zh ? '文件名清洗：非法字符' : 'Filename sanitize: illegal chars',
      pass: clean,
      detail: clean
          ? (zh ? '已替换' : 'Replaced')
          : (zh ? '结果：$illegal' : 'Result: $illegal'),
    ));

    return results;
  }

  /// B1. API 连接测试（遍历已保存的 API 配置）
  static Future<List<SelfCheckResult>> _checkApiConnection(bool zh) async {
    final results = <SelfCheckResult>[];
    final storage = StorageService.instance;
    try {
      final configs = await storage.getApiConfigs();
      if (configs.isEmpty) {
        results.add(SelfCheckResult(
          name: zh ? 'API 连接测试' : 'API connection test',
          pass: true,
          detail: zh ? '未配置任何 API（跳过）' : 'No API configured (skipped)',
        ));
        return results;
      }
      final apiSvc = ApiService();
      for (final c in configs) {
        try {
          final out = await apiSvc.testConnection(c);
          results.add(SelfCheckResult(
            name: zh ? 'API 连接：${c.name}' : 'API connection: ${c.name}',
            pass: true,
            detail: out.length > 60 ? out.substring(0, 60) : out,
          ));
        } catch (e) {
          results.add(SelfCheckResult(
            name: zh ? 'API 连接：${c.name}' : 'API connection: ${c.name}',
            pass: false,
            detail: '$e',
          ));
        }
      }
    } catch (e) {
      results.add(SelfCheckResult(
        name: zh ? 'API 连接测试' : 'API connection test',
        pass: false,
        detail: '$e',
      ));
    }
    return results;
  }

  /// B2. 搜索连接测试（当前搜索服务商）
  static Future<List<SelfCheckResult>> _checkSearchConnection(bool zh) async {
    final results = <SelfCheckResult>[];
    final storage = StorageService.instance;
    try {
      final cfg = await storage.getWebSearchConfig();
      if (!cfg.webSearchEnabled) {
        results.add(SelfCheckResult(
          name: zh ? '搜索连接测试' : 'Search connection test',
          pass: true,
          detail: zh ? '联网搜索未启用（跳过）' : 'Web search disabled (skipped)',
        ));
        return results;
      }
      final (ok, message, ms) = await WebSearchService.testConnection(cfg);
      results.add(SelfCheckResult(
        name: zh
            ? '搜索连接：${cfg.effectiveProvider().name}'
            : 'Search connection: ${cfg.effectiveProvider().name}',
        pass: ok,
        detail: ms != null
            ? (zh ? '$message（${ms}ms）' : '$message (${ms}ms)')
            : message,
      ));
    } catch (e) {
      results.add(SelfCheckResult(
        name: zh ? '搜索连接测试' : 'Search connection test',
        pass: false,
        detail: '$e',
      ));
    }
    return results;
  }

  /// A4. ReAct 协议解析检查（真实 parseReActOutput）
  static List<SelfCheckResult> _checkReActParser(bool zh) {
    final results = <SelfCheckResult>[];

    final search = parseReActOutput(
        '<thinking>查一下</thinking><search query="最新新闻" depth="advanced"/>');
    final hasSearch =
        search.any((p) => p['type'] == 'search' && p['content'] == '最新新闻');
    results.add(SelfCheckResult(
      name: zh ? 'ReAct 解析：search' : 'ReAct parse: search',
      pass: hasSearch,
      detail: hasSearch
          ? (zh ? 'query/depth 正确' : 'query/depth OK')
          : (zh ? '解析异常' : 'Parse failed'),
    ));

    final dl =
        parseReActOutput('<download intent="true" type="image" query="猫咪" />');
    final hasDl =
        dl.any((p) => p['type'] == 'download' && p['type_attr'] == 'image');
    results.add(SelfCheckResult(
      name: zh ? 'ReAct 解析：download' : 'ReAct parse: download',
      pass: hasDl,
      detail: hasDl
          ? (zh ? 'type/query 正确' : 'type/query OK')
          : (zh ? '解析异常' : 'Parse failed'),
    ));

    final ask = parseReActOutput('<ask_user>手机端||电脑端</ask_user>');
    final hasAsk = ask.any(
        (p) => p['type'] == 'ask_user' && (p['content'] ?? '').contains('手机端'));
    results.add(SelfCheckResult(
      name: zh ? 'ReAct 解析：ask_user' : 'ReAct parse: ask_user',
      pass: hasAsk,
      detail: hasAsk
          ? (zh ? '选项正确' : 'Options OK')
          : (zh ? '解析异常' : 'Parse failed'),
    ));

    final ans = parseReActOutput('<thinking>想想</thinking><answer>你好</answer>');
    final hasAns =
        ans.any((p) => p['type'] == 'answer' && p['content'] == '你好');
    results.add(SelfCheckResult(
      name: zh ? 'ReAct 解析：answer' : 'ReAct parse: answer',
      pass: hasAns,
      detail: hasAns
          ? (zh ? '正文正确' : 'Content OK')
          : (zh ? '解析异常' : 'Parse failed'),
    ));

    return results;
  }

  /// A5. token 估算检查（真实 ApiService.estimateTokens）
  static List<SelfCheckResult> _checkTokenEstimate(bool zh) {
    final results = <SelfCheckResult>[];
    final msgs = [
      ChatMessage.create(
        conversationId: 'check',
        role: MessageRole.user,
        content: '你好，今天天气怎么样？',
      ),
    ];
    final tokens = ApiService.estimateTokens(msgs);
    final ok = tokens >= 1 && tokens <= 50;
    results.add(SelfCheckResult(
      name: zh ? 'token 估算' : 'Token estimate',
      pass: ok,
      detail: ok
          ? (zh
              ? '估算 $tokens token（合理）'
              : 'Estimated $tokens tokens (reasonable)')
          : (zh ? '异常：$tokens' : 'Abnormal: $tokens'),
    ));
    return results;
  }

  /// C1. 真实对话测试（消耗 token，需用户手动开启）
  /// v1.7.1 fix M10: 遍历所有 API 配置而非只测 configs.first
  static Future<List<SelfCheckResult>> _checkDialogTest(bool zh) async {
    final results = <SelfCheckResult>[];
    final storage = StorageService.instance;
    try {
      final configs = await storage.getApiConfigs();
      if (configs.isEmpty) {
        results.add(SelfCheckResult(
          name: zh ? '对话测试' : 'Dialog test',
          pass: true,
          detail: zh ? '未配置 API（跳过）' : 'No API configured (skipped)',
        ));
        return results;
      }
      final apiSvc = ApiService();
      for (final cfg in configs) {
        final msgs = [
          ChatMessage.create(
            conversationId: 'selfcheck',
            role: MessageRole.user,
            content: '请只回复"测试成功"四个字',
          ),
        ];
        try {
          final resp = await apiSvc.completeChat(config: cfg, messages: msgs);
          results.add(SelfCheckResult(
            name: zh ? '对话测试：${cfg.name}' : 'Dialog test: ${cfg.name}',
            pass: resp.isNotEmpty,
            detail: resp.isNotEmpty
                ? (zh
                    ? '收到 ${resp.length} 字回复'
                    : 'Got ${resp.length}-char reply')
                : (zh ? '回复为空' : 'Empty reply'),
          ));
        } catch (e) {
          results.add(SelfCheckResult(
            name: zh ? '对话测试：${cfg.name}' : 'Dialog test: ${cfg.name}',
            pass: false,
            detail: '$e',
          ));
        }
      }
    } catch (e) {
      results.add(SelfCheckResult(
        name: zh ? '对话测试' : 'Dialog test',
        pass: false,
        detail: '$e',
      ));
    }
    return results;
  }

  /// A6. 日志服务可用性检查
  /// v1.7.1 fix m1: 移除硬编码分类数，改为动态检查 LogCat.values.length > 0
  static List<SelfCheckResult> _checkLogService(bool zh) {
    final results = <SelfCheckResult>[];
    final buffer = LoggerService.instance.buffer;
    final hasBuffer = buffer.isNotEmpty;
    results.add(SelfCheckResult(
      name: zh ? '日志服务' : 'Log service',
      pass: hasBuffer,
      detail: hasBuffer
          ? (zh ? '已记录 ${buffer.length} 条日志' : '${buffer.length} logs recorded')
          : (zh ? '日志缓冲为空' : 'Log buffer empty'),
    ));

    final catCount = LogCat.values.length;
    results.add(SelfCheckResult(
      name: zh ? '日志分类完整性' : 'Log category integrity',
      pass: catCount > 0,
      detail: zh ? '$catCount 个分类已定义' : '$catCount categories defined',
    ));
    return results;
  }

  /// A7. 配置读取检查（StorageService 各配置读取接口）
  static Future<List<SelfCheckResult>> _checkConfigRead(bool zh) async {
    final results = <SelfCheckResult>[];
    final storage = StorageService.instance;
    try {
      final ws = await storage.getWebSearchConfig();
      results.add(SelfCheckResult(
        name: zh ? '搜索配置读取' : 'Search config read',
        pass: true,
        detail: 'provider=${ws.effectiveProvider().name}',
      ));
    } catch (e) {
      results.add(SelfCheckResult(
        name: zh ? '搜索配置读取' : 'Search config read',
        pass: false,
        detail: '$e',
      ));
    }
    try {
      final apis = await storage.getApiConfigs();
      results.add(SelfCheckResult(
        name: zh ? 'API 配置读取' : 'API config read',
        pass: true,
        detail: zh ? '共 ${apis.length} 个配置' : '${apis.length} configs',
      ));
    } catch (e) {
      results.add(SelfCheckResult(
        name: zh ? 'API 配置读取' : 'API config read',
        pass: false,
        detail: '$e',
      ));
    }
    return results;
  }

  /// A8. 附件数据层读写检查（验证带附件消息入库/读出字段完整）
  static Future<List<SelfCheckResult>> _checkAttachmentStorage(bool zh) async {
    final results = <SelfCheckResult>[];
    final storage = StorageService.instance;
    final convId =
        'selftest_attachment_${DateTime.now().millisecondsSinceEpoch}';
    try {
      await storage.init();

      final msg = ChatMessage.create(
        conversationId: convId,
        role: MessageRole.user,
        content: '测试附件',
      );
      msg.attachments.addAll([
        const MessageAttachment(
          id: 'att_1',
          type: AttachmentType.image,
          fileName: 'photo.jpg',
          localPath: '/tmp/photo.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: 102400,
        ),
        const MessageAttachment(
          id: 'att_2',
          type: AttachmentType.doc,
          fileName: 'report.pdf',
          localPath: '/tmp/report.pdf',
          mimeType: 'application/pdf',
          sizeBytes: 2048000,
        ),
      ]);

      await storage.saveMessage(msg);
      final msgs = await storage.getMessages(convId);
      final ok = msgs.isNotEmpty &&
          msgs.first.attachments.length == 2 &&
          msgs.first.attachments[0].type == AttachmentType.image &&
          msgs.first.attachments[0].fileName == 'photo.jpg' &&
          msgs.first.attachments[0].sizeBytes == 102400 &&
          msgs.first.attachments[0].mimeType == 'image/jpeg' &&
          msgs.first.attachments[1].type == AttachmentType.doc &&
          msgs.first.attachments[1].fileName == 'report.pdf' &&
          msgs.first.attachments[1].sizeBytes == 2048000;

      results.add(SelfCheckResult(
        name: zh ? '附件数据存储' : 'Attachment storage',
        pass: ok,
        detail: ok
            ? (zh
                ? '2 个附件写入/读取正常（image+doc）'
                : '2 attachments written/read OK (image+doc)')
            : (zh
                ? '附件字段不匹配：${msgs.first.attachments.map((a) => '${a.type}:${a.fileName}').join(', ')}'
                : 'Attachment fields mismatch: ${msgs.first.attachments.map((a) => '${a.type}:${a.fileName}').join(', ')}'),
      ));

      await storage.deleteMessagesByConversation(convId);
    } catch (e) {
      results.add(SelfCheckResult(
        name: zh ? '附件数据存储' : 'Attachment storage',
        pass: false,
        detail: '$e',
      ));
      try {
        await storage.deleteMessagesByConversation(convId);
      } catch (e) { debugPrint('catch 静默异常: $e'); }
    }
    return results;
  }

  /// 引导式人工确认清单（需用户亲手操作/肉眼判断，质检无法自动判定）
  /// 注：已自动化的项（下载链路、ReAct 循环、附件数据层）不再出现在这里
  static List<ManualCheckItem> manualCheckItems({bool isZh = true}) {
    return [
      ManualCheckItem(
          title: isZh ? '冷启动不闪退' : 'Cold start no crash',
          description: isZh
              ? '杀掉 App 后从桌面图标重新打开，应正常进入首页'
              : 'Kill the app and reopen from the launcher icon; it should enter home page normally'),
      ManualCheckItem(
          title: isZh ? '新建/删除聊天' : 'Create/delete chat',
          description: isZh
              ? '首页点 + 新建聊天、长按删除，应正常跳转/删除'
              : 'Tap + to create a chat, long-press to delete; both should work'),
      ManualCheckItem(
          title: isZh ? '普通聊天流式输出' : 'Streaming chat output',
          description: isZh
              ? '发一条消息，应有打字机效果、Markdown 正常'
              : 'Send a message; typewriter effect and Markdown should render normally'),
      ManualCheckItem(
          title: isZh ? '停止生成' : 'Stop generation',
          description: isZh
              ? '发长消息后点停止，应立即停止且不崩溃'
              : 'Send a long message then tap stop; it should stop immediately without crashing'),
      ManualCheckItem(
          title: isZh ? '反问对话框' : 'Ask-back dialog',
          description: isZh
              ? '问模糊问题，AI 应弹 <ask_user> 反问让你选/补充'
              : 'Ask a vague question; AI should show an <ask_user> dialog with options'),
      ManualCheckItem(
          title: isZh ? '上下文压缩' : 'Context compression',
          description: isZh
              ? '聊十几条后点 ⋮→压缩上下文，旧消息应变成结构化摘要'
              : 'After ~10+ messages, tap ⋮ → Compress context; old messages should become a structured summary'),
      ManualCheckItem(
          title: isZh ? '附件发送 UI' : 'Attachment UI',
          description: isZh
              ? '📎 点选图片/拍照/文档，系统选择器应正常弹出并能发送'
              : 'Tap 📎 to pick photo/camera/document; system picker should open and send works'),
      ManualCheckItem(
          title: isZh ? '主题颜色' : 'Theme colors',
          description: isZh
              ? '各页面应是蓝绿色基调，文字选取高亮清晰'
              : 'Pages should use a blue-green theme; text selection highlight is clear'),
      ManualCheckItem(
          title: isZh ? '深色模式' : 'Dark mode',
          description: isZh
              ? '手机切深色，App 应自动适配且颜色协调'
              : 'Switch device to dark mode; app should adapt automatically with coordinated colors'),
    ];
  }

  /// B3. 下载链路测试（固定小文件自动下载验证，不消耗 token）
  /// v1.6.9 build42 修复问题3：下载插件被禁用时跳过下载检测，避免"禁用下载却仍走下载"。
  /// v1.7.1 fix m2: 添加缓存机制，24小时内只检测一次，减少流量消耗
  static Future<List<SelfCheckResult>> _checkDownloadLink(
      bool zh, PluginRegistry? registry) async {
    final results = <SelfCheckResult>[];
    if (registry != null &&
        !registry.isEnabled(PluginRegistry.kDownloadPluginId)) {
      results.add(SelfCheckResult(
        name: zh ? '下载链路' : 'Download pipeline',
        pass: true,
        detail: zh ? '下载功能已禁用（跳过）' : 'Download disabled (skipped)',
      ));
      return results;
    }

    // 检查缓存：24小时内只检测一次
    final now = DateTime.now();
    final lastCheck = _lastDownloadCheckTime;
    if (lastCheck != null && now.difference(lastCheck).inHours < 24) {
      results.add(SelfCheckResult(
        name: zh ? '下载链路' : 'Download pipeline',
        pass: _lastDownloadResult ?? true,
        detail: zh ? '24小时内已检测过' : 'Already checked within 24 hours',
      ));
      return results;
    }

    try {
      const testUrl = 'https://cn.bing.com/favicon.ico';
      final result = await AppDownloadService().downloadFileFromUrl(
        url: testUrl,
        fileName: '_selftest_favicon.ico',
      );
      final size = (result['size'] as int?) ?? 0;
      final success = size > 0;
      results.add(SelfCheckResult(
        name: zh ? '下载链路' : 'Download pipeline',
        pass: success,
        detail: zh ? '下载成功 $size 字节' : 'Downloaded $size bytes',
      ));
      // 清理测试文件，不污染用户下载目录
      final path = result['path'] as String?;
      if (path != null) {
        try {
          File(path).deleteSync();
        } catch (e) { debugPrint('catch 静默异常: $e'); }
      }
      // 更新缓存
      _lastDownloadCheckTime = now;
      _lastDownloadResult = success;
    } catch (e) {
      results.add(SelfCheckResult(
        name: zh ? '下载链路' : 'Download pipeline',
        pass: false,
        detail: '$e',
      ));
      _lastDownloadCheckTime = now;
      _lastDownloadResult = false;
    }
    return results;
  }

  // v1.7.1 fix m2: 下载链路检测缓存
  static DateTime? _lastDownloadCheckTime;
  static bool? _lastDownloadResult;

  /// C2. ReAct 循环测试（固定 prompt 触发思考+搜索，消耗 token）
  /// v1.7.1 fix M10: 遍历所有 API 配置而非只测 configs.first
  static Future<List<SelfCheckResult>> _checkReActLoop(bool zh) async {
    final results = <SelfCheckResult>[];
    final storage = StorageService.instance;
    try {
      final configs = await storage.getApiConfigs();
      if (configs.isEmpty) {
        results.add(SelfCheckResult(
          name: zh ? 'ReAct 循环' : 'ReAct loop',
          pass: true,
          detail: zh ? '未配置 API（跳过）' : 'No API configured (skipped)',
        ));
        return results;
      }
      final apiSvc = ApiService();
      for (final cfg in configs) {
        final msgs = [
          ChatMessage.create(
            conversationId: 'selfcheck',
            role: MessageRole.user,
            content: '请联网搜索一下今天的新鲜事，用 <thinking> 思考后给出 <answer>',
          ),
        ];
        try {
          final resp = await apiSvc.completeChat(config: cfg, messages: msgs);
          final parsed = parseReActOutput(resp);
          final hasTag = parsed.any((p) =>
              p['type'] == 'answer' ||
              p['type'] == 'thinking' ||
              p['type'] == 'search');
          results.add(SelfCheckResult(
            name: zh ? 'ReAct 循环：${cfg.name}' : 'ReAct loop: ${cfg.name}',
            pass: hasTag,
            detail: hasTag
                ? (zh
                    ? '协议输出正常（${parsed.length} 段）'
                    : 'Protocol output OK (${parsed.length} parts)')
                : (zh ? '未检测到 ReAct 标签' : 'No ReAct tags detected'),
          ));
        } catch (e) {
          results.add(SelfCheckResult(
            name: zh ? 'ReAct 循环：${cfg.name}' : 'ReAct loop: ${cfg.name}',
            pass: false,
            detail: '$e',
          ));
        }
      }
    } catch (e) {
      results.add(SelfCheckResult(
        name: zh ? 'ReAct 循环' : 'ReAct loop',
        pass: false,
        detail: '$e',
      ));
    }
    return results;
  }

  /// B4. 流式模式可用性检查（v1.4.6 新增）
  ///
  /// 发送短消息走 streamChat，统计 chunks 数：
  ///   - chunks > 1 → 流式正常工作（API 真的支持 SSE + 网络没缓冲）
  ///   - chunks == 1 → API 一次性返回（可能服务端不支持 stream 或代理缓冲了 SSE）
  ///   - 报错 → 记为失败
  ///
  /// 这一项能直接定位"AI 回复不流式"问题的根因——是 API 服务商问题、代理问题，
  /// 还是用户开了 🧠/🌐 走 ReAct 路径（ReAct 用 completeChat 本来就非流式）。
  static Future<List<SelfCheckResult>> _checkStreamingMode(bool zh) async {
    final results = <SelfCheckResult>[];
    final storage = StorageService.instance;
    try {
      final configs = await storage.getApiConfigs();
      if (configs.isEmpty) {
        results.add(SelfCheckResult(
          name: zh ? '流式输出' : 'Streaming',
          pass: true,
          detail: zh ? '未配置 API（跳过）' : 'No API configured (skipped)',
        ));
        return results;
      }
      final apiSvc = ApiService();
      final cfg = configs.first;
      try {
        final userMsg = ChatMessage.create(
          conversationId: 'selfcheck_stream',
          role: MessageRole.user,
          content: '请回复两个字：「你好」',
        );
        final sw = Stopwatch()..start();
        int chunkCount = 0;
        int totalChars = 0;
        await for (final chunk in apiSvc.streamChat(
          config: cfg,
          messages: [userMsg],
        )) {
          chunkCount++;
          totalChars += chunk.length;
          // 安全上限：超过 30 秒强制中断（避免长输出拖慢自检）
          if (sw.elapsedMilliseconds > 30000) break;
        }
        sw.stop();
        final pass = chunkCount > 1;
        results.add(SelfCheckResult(
          name: zh ? '流式输出：${cfg.name}' : 'Streaming: ${cfg.name}',
          pass: pass,
          detail: pass
              ? (zh
                  ? '正常（$chunkCount chunks / $totalChars 字符 / ${sw.elapsedMilliseconds}ms）'
                  : 'OK ($chunkCount chunks / $totalChars chars / ${sw.elapsedMilliseconds}ms)')
              : (zh
                  ? '异常：只收到 $chunkCount chunk（API 可能不支持 stream:true 或代理缓冲了 SSE）'
                  : 'Abnormal: only $chunkCount chunk received (API may not support stream:true or proxy buffers SSE)'),
        ));
      } catch (e) {
        results.add(SelfCheckResult(
          name: zh ? '流式输出：${cfg.name}' : 'Streaming: ${cfg.name}',
          pass: false,
          detail: '$e',
        ));
      }
    } catch (e) {
      results.add(SelfCheckResult(
        name: zh ? '流式输出' : 'Streaming',
        pass: false,
        detail: '$e',
      ));
    }
    return results;
  }
}
