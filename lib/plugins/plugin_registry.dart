import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/chat_message.dart';
import '../services/builtin_prompt_catalog.dart';
import '../models/mcp_market_models.dart';
import '../services/mcp_client_service.dart';
import '../utils/ssrf_guard.dart';
import '../services/mcp_id_normalizer.dart';
import '../services/logger_service.dart';
import '../services/storage_service.dart';
import 'plugin_interface.dart';
import 'plugin_context.dart';
import 'installed_dynamic_plugin.dart';
import 'installed_mcp_plugin.dart';
// build173（S13/S19b）：宿主级裸 toolresult 通道收口到同一个信封构造函数。
// 只 show 一个纯函数 ⇒ 与 builtin_plugins.dart 的既有 import 形成环，Dart 允许
// 且这里只在运行时调用（不在任何顶层初始化器里读它的成员），无初始化成环风险。
import 'builtin_plugins.dart' show toolResultTag;

class PluginRegistry extends ChangeNotifier {
  final Map<String, ReActPlugin> _registry = {};
  final Map<String, ReActPlugin> _fallbacks = {};
  final Map<String, bool> _enabledMap = {};
  final StorageService? _storage;
  final McpClientService Function()? _mcpClientFactory;
  // v1.6.9 build42：每个插件 id 的 setEnabled 互斥锁（Future 串行队列）
  // 避免用户快速连点开关时：第1次 await 写DB(false)覆盖第2次内存=true，重启后状态回滚
  final Map<String, Future<void>> _enableLocks = {};
  ReActPlugin? _fallbackPlugin;

  /// build138（扫描 P1-7）：日志器。此前 registry 里所有 catch 只走 debugPrint，
  /// release 包里 debugPrint 不进导出日志 ⇒ 插件状态读取/落盘失败在真机上完全不可见。
  final LoggerService _logger = LoggerService.instance;

  /// 插件开关状态**读取**失败（DB 异常等）。true ＝ 本轮沿用的是出厂默认，
  /// 用户手动关过的插件可能被静默重新启用 —— 必须让上层有机会提示。
  bool pluginStatesLoadFailed = false;

  /// 本次启动以来落盘失败的开关**次数**（>0 表示有开关没能存住）。
  /// build145 起为累计口径：写侧已从"整表批量"改成"一次一条"（见 [_safePersistOne]），
  /// 每次变更只可能有 0/1 条失败，所以"最近一批"这个概念已经不存在了；
  /// 累计值对上层仍然是真话（banner 文案「有 N 个插件开关未能保存」照旧成立）。
  int pluginStatesPersistFailures = 0;

  /// build155（第 13 轮 P2）：启用 MCP 时刷新远端工具失败的累计次数。
  /// 失败不阻断用户意图（开关仍会打开），但必须留痕：上层可据此提示
  /// 「已启用，但工具列表是上次的缓存，端点可能已失效」。
  int mcpRefreshFailures = 0;

  /// 联网搜索插件 id（与 builtin_plugins.dart SearchPlugin 的 metadata.id 一致）
  static const String kSearchPluginId = 'nexus.builtin.search';

  /// AI 自我终止判定插件 id（与 builtin_plugins.dart SelfCheckPlugin 一致）
  static const String kSelfCheckPluginId = 'nexus.builtin.self_check';

  /// 文件与应用下载插件 id（与 builtin_plugins.dart DownloadPlugin 一致）
  static const String kDownloadPluginId = 'nexus.builtin.download';

  PluginRegistry(
      {StorageService? storage, McpClientService Function()? mcpClientFactory})
      : _storage = storage,
        _mcpClientFactory = mcpClientFactory {
    _initFromStorage();
  }

  Future<void> _initFromStorage() async {
    try {
      final s = _storage ?? StorageService.instance;
      if (!s.isInitialized) await s.init();

      // ✅ NEW-BUG-02 修复：从 DB plugins 表重新注册所有「非 system 插件」到内存
      //   - system 插件是 main.dart 里 registerBuiltinPlugins() 手动注册的（真实有 handle 实现）
      //     为避免重复注册/覆盖真实 handle 实现 → 跳过 source=system 的行
      //   - installed/community/market 来源插件都是占位（InstalledDynamicPlugin），
      //     需要从 DB 重新构造，否则重启后内存没对象 → 已安装列表空/prompt 不生效/dispatch 不命中
      try {
        final rows = await s.loadAllPlugins();
        for (final row in rows) {
          final src = (row['source'] as String?) ?? '';
          // 系统插件：main.dart 已经真正 register 过真实实现，跳过
          if (src == PluginSource.system.name) continue;
          // 已注册过（例如 market 安装后当时就 register 了）：跳过（避免重复）
          final id = row['id'] as String?;
          if (id == null || id.isEmpty) continue;
          if (_registry.containsKey(id)) continue;
          try {
            final plugin = InstalledDynamicPlugin.fromDbRow(row);
            // 注册到 registry（触发 dispatch/prompt 生效），同时 update fallback map
            register(plugin);
          } catch (e, st) {
            // 单条插件重建失败记录日志，继续其他插件（不阻塞整体启动）
            // build138（扫描 P1-7）：debugPrint 在 release 不进导出日志 ⇒ 真机上
            // "已安装插件重启后消失" 这类问题零痕迹，改走 LoggerService。
            _logger.warn('[Plugin] 重建已安装插件失败 $id：$e', tag: 'PluginBoot');
            _logger.debug('[Plugin] stack: $st', tag: 'PluginBoot');
          }
        }
      } catch (e, st) {
        _logger.warn('[Plugin] 从 DB 重载插件列表失败：$e', tag: 'PluginBoot');
        _logger.debug('[Plugin] stack: $st', tag: 'PluginBoot');
      }

      final states = await _safeLoadPluginStates(s);
      states.forEach((key, value) {
        _enabledMap[key] = value;
      });
    } catch (e, st) {
      // build138（扫描 P1-7）：debugPrint 在 release 包不进导出日志 ⇒ 启动期
      // 插件重建/状态加载失败在真机上零痕迹。改走 LoggerService（warn 分类）。
      _logger.warn('[Plugin] 启动期插件状态加载失败：$e', tag: 'PluginBoot');
      _logger.debug('[Plugin] stack: $st', tag: 'PluginBoot');
    }
    notifyListeners();
  }

  /// build138（扫描 P1-7）：签名是 `Future<Map<String,bool>> loadPluginStates()`，
  /// 旧代码写成 `(s as dynamic)` —— 编译期不检查，StorageService 改名即静默失效
  /// （catch 会把它吞成"没有状态"）。改为静态可检查的直接调用。
  Future<Map<String, bool>> _safeLoadPluginStates(StorageService s) async {
    try {
      return await s.loadPluginStates();
    } catch (e) {
      // 关键区别：过去失败与"表里就是没有行"**都返回空 map**，上层无从分辨，
      // 于是用户关掉的插件在下一次冷启动被出厂默认悄悄打开。
      pluginStatesLoadFailed = true;
      _logger.warn('[Plugin] loadPluginStates 失败，本轮沿用出厂默认：$e',
          tag: 'PluginState');
      return const <String, bool>{};
    }
  }

  /// build145（循环审查第 7 轮 P0-1）：从**整表回写**改成**只写这一条**。
  ///
  /// 旧实现（build138 的 `_safePersistEnabledMap`）遍历整个内存 `_enabledMap` 落盘，
  /// 看着稳妥（"反正内存是权威"），实际是一条静默的数据破坏路径：`:91` 的读取失败
  /// 与"表里就是没有行"**共用一个空 map**（build138 P1-7 只是把这件事**记下来**了，
  /// 没堵写侧），于是内存里躺着一整片出厂默认。用户之后随便拨一个开关 ⇒ 整片默认值
  /// 被当作"用户的选择"写回 DB，把他几个月前关掉的插件全悄悄打开，而 UI 只显示"这条存好了"。
  ///
  /// 语义上讲，一次用户动作只改变**一个 id** 的状态 —— 落盘范围与变更范围一致才是对的
  /// （设计法则 #62：一个语义一处实现，且实现只能覆盖它声称覆盖的东西）。
  /// 逐条 try 的口径沿用 build138：失败计数暴露给上层，不静默吞。
  /// 整表回写那个函数已**删除**而不是留着不用 —— 留着就还有人调，复发只是时间问题。
  Future<void> _safePersistOne(String id) async {
    final s = _storage ?? StorageService.instance;
    final value = _enabledMap[id];
    if (value == null) return; // 已随卸载移除，DB 行也删了：没有状态要写
    try {
      await s.savePluginState(id, enabled: value);
    } catch (e) {
      // build138（扫描 P1-7）：写失败必须是可导出的日志 + 可上屏的计数
      pluginStatesPersistFailures = pluginStatesPersistFailures + 1;
      _logger.warn('[Plugin] 开关落盘失败 $id=$value：$e', tag: 'PluginState');
      notifyListeners();
    }
  }

  /// v1.6.9 build42 修复问题2：联网搜索「插件开关」与「系统设置开关」双向同步。
  /// 这里是 registry → config 单向：插件管理里开关 SearchPlugin 时，同步写
  /// WebSearchConfig.webSearchEnabled，使设置页开关 / 输入框 🌐 保持一致。
  /// （反向 config → registry 在 settings_screen 的开关 onChanged 里调 setEnabled 完成。）
  Future<void> _syncSearchEnabledToConfig(bool value) async {
    try {
      final s = _storage ?? StorageService.instance;
      if (!s.isInitialized) await s.init();
      final cfg = await s.getWebSearchConfig();
      await s.saveWebSearchConfig(cfg.copyWith(webSearchEnabled: value));
    } catch (e) {
      _logger.warn('[Plugin] 搜索开关回写 config 失败：$e', tag: 'PluginState');
    }
  }

  void register(ReActPlugin plugin) {
    final id = plugin.metadata.id;
    _registry[id] = plugin;
    _fallbacks[plugin.triggerType] = plugin;
    if (!_enabledMap.containsKey(id)) {
      // 内置（system）插件默认开启，其余来源默认关闭
      _enabledMap[id] = plugin.source == PluginSource.system;
    }
    notifyListeners();
  }

  void registerAll(List<ReActPlugin> plugins) {
    for (final p in plugins) {
      register(p);
    }
  }

  void setFallback(ReActPlugin? plugin) {
    _fallbackPlugin = plugin;
  }

  /// v1.6.10 build44：完整卸载插件（内存 + DB），供插件管理界面删除第三方插件用。
  /// 清理：_registry（注册表）+ _fallbacks（triggerType 映射）+ _enabledMap（启用状态）+ plugins 表。
  /// build155（第 13 轮 P1-1）：新增 [enable] 参数，**更新场景必须沿用用户已有的开关**。
  ///
  /// 本函数同时服务两条路径：市场/Skill 代装的「首次安装」与
  /// `PluginUpdateService._updateSkill`（plugin_update_service.dart:112）的「覆盖式更新」。
  /// 旧实现在两条路径上都硬写 `enabled: 1` + `setEnabled(id, true)`，
  /// 于是用户手动关掉的 Skill 只要点一次「更新」就被悄悄打开 ——
  /// 开关只挡住了 dispatch，挡不住安装管线，属于「一半效力」。
  /// 现在：内存里已有该 id 的状态（＝不是首次安装）就原样保留，并写进 DB 行，
  /// 保证重启后 `loadPluginStates` 读回来的也是用户的选择。
  Future<void> installDeclarative(PluginMetadata metadata,
      {bool? enable}) async {
    final s = _storage ?? StorageService.instance;
    if (!s.isInitialized) await s.init();
    final hadState = _enabledMap.containsKey(metadata.id);
    final desired = enable ?? (hadState ? _enabledMap[metadata.id]! : true);
    await s.upsertPlugin({
      'id': metadata.id,
      'name': metadata.name,
      'version': metadata.version,
      'source': PluginSource.installed.name,
      'author': metadata.author,
      'description': metadata.description,
      'enabled': desired ? 1 : 0,
      'installedAt': DateTime.now().millisecondsSinceEpoch,
      'metadataJson': jsonEncode(metadata.toMap()),
    });
    register(
      InstalledDynamicPlugin(
          metadata: metadata, source: PluginSource.installed),
    );
    await setEnabled(metadata.id, desired);
    if (hadState && !desired) {
      _logger.info('[Plugin] 更新后沿用用户停用状态：${metadata.id}',
          tag: 'PluginState');
    }
  }

  Future<void> installRemoteMcp(
    McpRegistryServer server, {
    McpClientService? client,
    Map<String, String>? customHeaders,
    // build98（本地加强⑤）：扫描出 high/critical 的插件工具调用强制每次弹确认
    bool forceConfirmEveryCall = false,
    // build155（第 13 轮 P1-1）：null＝沿用该 id 已有的开关（更新场景），
    // true/false＝显式指定（市场点「安装」这类用户动作，UI 承诺「安装并启用」）。
    bool? enable,
  }) async {
    if (_registry.containsKey(server.name) &&
        !_registry[server.name]!.metadata.kind.isRemote) {
      throw const FormatException('A non-MCP plugin already uses this id');
    }
    final previous = _registry[server.name];
    final previousEnabled = _enabledMap[server.name];
    // v1.7.37（待办⑬）：更新场景（PluginUpdateService 重跑 install）未显式传 headers 时，
    // 沿用旧配置里已有的 customHeaders，避免更新后凭据丢失。
    final headers = (customHeaders == null && previous != null)
        ? sanitizeCustomHeaders(previous.metadata.extra['customHeaders'])
        : sanitizeCustomHeaders(customHeaders);
    // build153（SSRF）：生产构造点注入真解析器（口径同 `installed_mcp_plugin.dart:20`，
    // 那里写了完整理由）。`_mcpClientFactory` 是测试/自定义注入口，优先级保持不变。
    final mcpClient = client ??
        McpClientService(customHeaders: headers, ipLookup: defaultSsrfIpLookup);
    final s = _storage ?? StorageService.instance;
    if (!s.isInitialized) await s.init();
    final previousRows = await s.loadAllPlugins();
    Map<String, dynamic>? previousRow;
    for (final row in previousRows) {
      if (row['id'] == server.name) {
        previousRow = row;
        break;
      }
    }
    try {
      final rawTools =
          await mcpClient.discoverTools(server.endpoint.toString());
      final tools = rawTools
          .map((tool) => McpToolDefinition.fromJson(tool))
          .toList(growable: false);
      if (tools.isEmpty) throw const FormatException('MCP server has no tools');
      final config = InstalledMcpConfig(
        serverName: server.name,
        serverVersion: server.version,
        endpoint: server.endpoint,
        protocolVersion: '2025-03-26',
        tools: tools,
        lastVerifiedAt: DateTime.now().toUtc(),
        customHeaders: headers,
      );
      final metadata = PluginMetadata(
        id: server.name,
        name: server.title,
        version: server.version,
        author: 'MCP Registry',
        description: server.description,
        homepage: server.homepage?.toString() ?? '',
        promptProtocol:
            // O8-4（build96）：写明 401/403 语义——需授权，换工具/重试无意义。
            'MCP tools are available through plugin_id="${server.name}". '
            'If any tool returns HTTP 401/403 (未授权), stop calling this plugin '
            'immediately—retrying or switching tools is futile—and ask the user '
            'to configure/update its auth key in 插件管理.',
        tags: const ['MCP', '公开'],
        kind: PluginKind.mcpRemote,
        triggerType: 'mcp_call',
        extra: {
          ...config.toJson(),
          if (forceConfirmEveryCall) 'securityForceConfirm': true,
        },
      );
      final s = _storage ?? StorageService.instance;
      if (!s.isInitialized) await s.init();
      // build155（第 13 轮 P1-1）：更新场景沿用用户此前的开关（口径同 installDeclarative）。
      // `previousEnabled == null` 才认定为首次安装 → 默认启用；
      // 旧代码只在上方的 catch 回滚里用到 previousEnabled，成功路径一律强开。
      final desiredEnabled = previousEnabled ?? true;
      await s.upsertPlugin({
        'id': metadata.id,
        'name': metadata.name,
        'version': metadata.version,
        'source': PluginSource.installed.name,
        'author': metadata.author,
        'description': metadata.description,
        'enabled': desiredEnabled ? 1 : 0,
        'installedAt': DateTime.now().millisecondsSinceEpoch,
        'metadataJson': jsonEncode(metadata.toMap()),
      });
      final installed = InstalledMcpPlugin.fromMetadata(metadata);
      register(installed);
      _enabledMap[metadata.id] = desiredEnabled;
      notifyListeners();
      await _safePersistOne(metadata.id);
      if (previousEnabled != null && !desiredEnabled) {
        _logger.info('[Plugin] MCP 更新后沿用用户停用状态：${metadata.id}',
            tag: 'PluginState');
      }
    } catch (e) {
      // build155（第 13 轮 P2）：这里原来 `catch (_)` 直接回滚 + rethrow，
      // 原始失败原因（discoverTools 超时 / 端点 401 / 服务器零工具）在导出日志里
      // 一个字都没有；插件管理页只显示一句「安装失败」⇒ 真机不可排查。先记一行再回滚。
      _logger.warn('[Plugin] MCP 安装/更新失败，开始回滚 ${server.name}：$e',
          tag: 'PluginState');
      final current = _registry[server.name];
      if (current is InstalledMcpPlugin && !identical(current, previous)) {
        current.close();
      }
      if (previous == null) {
        _registry.remove(server.name);
        // L-3 修复：回滚已注册插件时同步清理其写入的 triggerType fallback 映射。
        if (current != null &&
            identical(_fallbacks[current.triggerType], current)) {
          _fallbacks.remove(current.triggerType);
        }
      } else {
        _registry[server.name] = previous;
        _fallbacks[previous.triggerType] = previous;
      }
      if (previousEnabled == null) {
        _enabledMap.remove(server.name);
      } else {
        _enabledMap[server.name] = previousEnabled;
      }
      try {
        if (previousRow == null) {
          await s.deletePlugin(server.name);
        } else {
          await s.upsertPlugin(previousRow);
        }
      } catch (e) {
        // build138（扫描 P1-7）：MCP 安装失败的回滚本身失败 ⇒ 数据库残留半条记录，
        // 必须是可导出的日志而不是一行 debugPrint。
        _logger.warn('[Plugin] 安装失败后回滚插件记录出错：$e', tag: 'PluginState');
      }
      notifyListeners();
      rethrow;
    } finally {
      if (client == null) mcpClient.close();
    }
  }

  Future<void> uninstall(String id) async {
    final plugin = _registry[id];
    if (plugin?.source == PluginSource.system) {
      throw StateError('System plugins cannot be uninstalled');
    }
    final s = _storage ?? StorageService.instance;
    if (!s.isInitialized) await s.init();
    await s.deletePlugin(id);
    if (plugin is InstalledMcpPlugin) {
      plugin.close();
    }
    _fallbacks.removeWhere((_, v) => v.metadata.id == id);
    _registry.remove(id);
    _enabledMap.remove(id);
    // build155（第 13 轮 P1-2）：卸载要把**这个 id 自己的**运行时残留一并清掉。
    // 旧实现留着两处：
    //  ① `_mcpFailStreaks` 的熔断计数 —— 同一 id 重装后立刻带着「已连失 2 次」的
    //     历史进来，新连接器第一次调用就被熔断（用户看到「宿主熔断：不可用」）；
    //  ② `_enableLocks` 的串行队列键。
    _mcpFailStreaks.removeWhere((k, _) => k.startsWith('$id|'));
    _enableLocks.remove(id);
    notifyListeners();
    // build145（第 7 轮 P0-1）：这里原来跟一句「整表回写」——卸载只需要删自己那行
    // （上面的 `deletePlugin` 已做），把别人的状态再写一遍纯属越权：
    // 读失败的那一轮里，别的插件的出厂默认就是在这一步覆盖用户选择的。
    await _cleanupSkillFiles(id, plugin);
  }

  /// build155（第 13 轮 P1-2）：卸载时删除 Skill 落盘目录。
  ///
  /// 卸载对话框的文案承诺「将移除该插件**及其配置**」（plugin_management_screen.dart:622），
  /// 旧实现只删了 DB 行与内存三态，`.skills/<pluginId>/` 里的 SKILL.md 与 zip 解出的
  /// 附带脚本永久留在磁盘（同 id 重装时才被覆盖）——卸载不清关联数据。
  /// 安全边界：**只删 .skills 根目录之下**的路径，且不跟随符号链接判断；
  /// 越界、异常一律不删并记日志（宁可留垃圾，也不能顺手删用户文件）。
  Future<void> _cleanupSkillFiles(String id, ReActPlugin? plugin) async {
    final dirPath = plugin?.metadata.extra['skillDir']?.toString().trim() ?? '';
    if (dirPath.isEmpty) return;
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return;
      final root = await _skillsRoot();
      final normDir = p.canonicalize(dir.path);
      final normRoot = p.canonicalize(root);
      if (!p.isWithin(normRoot, normDir)) {
        _logger.warn('[Plugin] 卸载 $id：skillDir 不在 .skills 根内，跳过删除 $normDir',
            tag: 'Plugin');
        return;
      }
      await dir.delete(recursive: true);
      _logger.info('[Plugin] 卸载 $id：已删除 Skill 目录 $normDir', tag: 'Plugin');
    } catch (e) {
      _logger.warn('[Plugin] 卸载 $id：删除 Skill 目录失败（不影响卸载）：$e',
          tag: 'Plugin');
    }
  }

  static Future<String> _skillsRoot() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, '.skills');
  }

  bool isEnabled(String id) {
    return _enabledMap[id] ?? (id == '__fallback_unknown__' ? true : false);
  }

  Future<void> setEnabled(String id, bool value) async {
    // per-id 串行队列：快速连点 A->B 时 B 一定等 A 的 await 持久化完成后再读内存最新值写 DB
    final currentLock = _enableLocks[id];
    final next = Future<void>(() async {
      try {
        if (currentLock != null) await currentLock;
      } catch (e) {
        // build138（扫描 P1-7）：排队等前一次落盘时前一次抛了 —— 不能吞掉，
        // 吞掉等于"上一次开关没存住"这件事永久无人知晓。
        _logger.warn('[Plugin] 前一次开关任务异常，继续本次：$e', tag: 'PluginState');
      }
      if (value &&
          (_enabledMap[id] ?? false) == false &&
          _registry[id] is InstalledMcpPlugin) {
        // build155（第 13 轮 P2）：刷新工具失败（端点宕了 / 401 / 超时）以前会直接把异常
        // 抛出 `setEnabled`：调用点是 `onChanged: (v) => registry.setEnabled(...)`
        // （plugin_management_screen.dart:344，未 await / 未 catch）⇒ 未处理异步异常，
        // 而且用户按了「开」却既没打开也没得到任何原因。
        // 现在：记下原因，仍按用户意图启用（沿用安装时存的旧工具表，
        // 真调用失败会走 dispatch 的熔断与 toolresult 回灌，比开关失灵更可排查）。
        try {
          await _refreshMcpPlugin(id);
        } catch (e) {
          _logger.warn('[Plugin] 启用 $id 前刷新 MCP 工具失败，沿用上次工具列表：$e',
              tag: 'PluginState');
          mcpRefreshFailures++;
        }
      }
      _enabledMap[id] = value;
      notifyListeners();
      await _safePersistOne(id);
      // v1.6.9 build42 修复问题2：联网搜索插件开关 → 同步写 WebSearchConfig.webSearchEnabled
      if (id == kSearchPluginId) {
        await _syncSearchEnabledToConfig(value);
      }
    });
    _enableLocks[id] = next;
    // ignore: avoid_catches_without_on_clauses
    next.then((_) {
      // 完成后如果当前 still == next，则清 key 减少内存占用
      if (identical(_enableLocks[id], next)) _enableLocks.remove(id);
    }, onError: (_) {
      if (identical(_enableLocks[id], next)) _enableLocks.remove(id);
    });
    return next;
  }

  Future<void> _refreshMcpPlugin(String id) async {
    final current = _registry[id];
    if (current is! InstalledMcpPlugin) return;
    final endpoint = current.metadata.extra['endpoint']?.toString() ?? '';
    // v1.7.37（待办⑬）：刷新时沿用已保存的鉴权头
    final headers =
        sanitizeCustomHeaders(current.metadata.extra['customHeaders']);
    // build153（SSRF）：真解析器（理由见 `installed_mcp_plugin.dart:20`）。
    final client = _mcpClientFactory?.call() ??
        McpClientService(
            customHeaders: headers, ipLookup: defaultSsrfIpLookup);
    try {
      final rawTools = await client.discoverTools(endpoint);
      final tools = rawTools
          .map((tool) => McpToolDefinition.fromJson(tool))
          .toList(growable: false);
      if (tools.isEmpty) throw const FormatException('MCP server has no tools');
      final extra = Map<String, dynamic>.from(current.metadata.extra);
      extra['tools'] =
          tools.map((tool) => tool.toJson()).toList(growable: false);
      extra['lastVerifiedAt'] = DateTime.now().toUtc().toIso8601String();
      final metadata = current.metadata.copyWith(extra: extra);
      final replacement = InstalledMcpPlugin.fromMetadata(metadata);
      _registry[id] = replacement;
      _fallbacks[replacement.triggerType] = replacement;
      final s = _storage ?? StorageService.instance;
      if (!s.isInitialized) await s.init();
      final rows = await s.loadAllPlugins();
      Map<String, dynamic>? row;
      for (final item in rows) {
        if (item['id'] == id) {
          row = item;
          break;
        }
      }
      if (row != null) {
        await s.upsertPlugin({
          ...row,
          'metadataJson': jsonEncode(metadata.toMap()),
          'enabled': 1,
        });
      }
      final oldFallback = _fallbacks[current.triggerType];
      _fallbacks[current.triggerType] = replacement;
      try {
        _registry[id] = replacement;
        current.close();
      } catch (_) {
        _registry[id] = current;
        if (oldFallback == null) {
          _fallbacks.remove(current.triggerType);
        } else {
          _fallbacks[current.triggerType] = oldFallback;
        }
        replacement.close();
        rethrow;
      }
    } finally {
      client.close();
    }
  }

  /// v1.7.37（待办⑬）：更新已安装 MCP 插件的自定义鉴权请求头。
  /// 重建 InstalledMcpPlugin（新 client 带新 headers）并持久化到 plugins 表 metadataJson。
  /// 敏感信息：headers 含凭据明文，绝不写日志。
  Future<void> updateMcpCustomHeaders(
      String id, Map<String, String> headers) async {
    final current = _registry[id];
    if (current is! InstalledMcpPlugin) {
      throw StateError('Plugin $id is not an installed MCP plugin');
    }
    final sanitized = sanitizeCustomHeaders(headers);
    final extra = Map<String, dynamic>.from(current.metadata.extra);
    if (sanitized.isEmpty) {
      extra.remove('customHeaders');
    } else {
      extra['customHeaders'] = sanitized;
    }
    final metadata = current.metadata.copyWith(extra: extra);
    final replacement = InstalledMcpPlugin.fromMetadata(metadata);
    final s = _storage ?? StorageService.instance;
    if (!s.isInitialized) await s.init();
    final rows = await s.loadAllPlugins();
    Map<String, dynamic>? row;
    for (final item in rows) {
      if (item['id'] == id) {
        row = item;
        break;
      }
    }
    if (row != null) {
      await s.upsertPlugin({
        ...row,
        'metadataJson': jsonEncode(metadata.toMap()),
      });
    }
    _registry[id] = replacement;
    if (identical(_fallbacks[current.triggerType], current)) {
      _fallbacks[current.triggerType] = replacement;
    }
    current.close();
    notifyListeners();
  }

  List<ReActPlugin> get plugins =>
      List<ReActPlugin>.unmodifiable(_registry.values);

  // N6（build94）：MCP 同 (pluginId, tool) 一条用户消息内连续失败熔断计数。
  // 达到 2 次后不再 dispatch，直接注入最终判定 toolresult，防止 AI 对着
  // 不存在的插件反复空转（真机日志实测 didi not_found 连调不停）。
  final Map<String, int> _mcpFailStreaks = {};

  /// 每条用户消息的 ReAct 循环开始前由宿主调用，清零熔断计数。
  void resetMcpCircuit() => _mcpFailStreaks.clear();

  List<ReActPlugin> listAll() => plugins;

  ReActPlugin? getById(String id) {
    return _registry[id];
  }

  Map<String, bool> get enabledSnapshot =>
      Map<String, bool>.unmodifiable(_enabledMap);

  /// v1.6.9 build42：给 PluginMarketScreen 安装流程写 DB 用。
  /// 因为 _storage 是 private，通过 StorageService.instance 兜底获取；
  /// 未初始化时返回 null，调用方应使用 await StorageService.instance.init()。
  StorageService? get storageOrNull {
    try {
      final s = _storage ?? StorageService.instance;
      return s;
    } catch (_) {
      return null;
    }
  }

  Future<bool> dispatch(
    BuildContext context,
    PluginContext pluginContext,
    String type,
    Map<String, dynamic> attrs,
  ) async {
    bool handled = false;
    ReActPlugin? primary;
    // build138（P1-4）：熔断键在 mcp_call 分支里算一次，handle 的成功/异常两处写侧复用
    // 同一个变量（那些写点在本方法末尾的公共段里，拿不到分支内的局部变量）。
    String mcpCircuitKey = '';
    if (type == 'mcp_call') {
      final rawPluginId = attrs['pluginId']?.toString() ?? '';
      final rawTool = attrs['tool']?.toString() ?? '';
      // build116（结构性修复）：id 方言统一收敛到 normalizeMcpTarget——
      // 目录给模型看的是三段式 `mcp:<id>:<tool>`，模型整串照抄时旧容错
      // （只剥 mcp: 前缀）认不出来 →「未找到插件」→ 模型放弃并自我怀疑。
      // 真机日志 nexus_export_2026-09-15T22-29 实锤。三处消费点共用同一函数，
      // 避免「每修一种方言漏下一种」。
      final target_ = normalizeMcpTarget(
        rawPluginId,
        rawTool,
        isKnownId: (id) => _registry.containsKey(id),
      );
      final pluginId = target_.pluginId;
      final toolName = target_.tool;
      // build107（U6）：id 容错——模型常把 id 写错形态（目录前缀 mcp:amap / 内置短名
      // log_query），能唯一对应到注册表真实插件时自动纠正，不消耗调用次数。
      // build116：三段式等全部方言已由 normalizeMcpTarget 在上方统一处理，
      // 这里只补「内置插件短名」这一支（log_query → nexus.builtin.log_query）。
      var target = _registry[pluginId];
      String? idFixNote = target_.wasFixed ? target_.fixNote : null;
      if (target == null && pluginId.isNotEmpty) {
        final alt = _registry['nexus.builtin.$pluginId'];
        if (alt != null && isEnabled(alt.metadata.id)) {
          target = alt;
          idFixNote = '$pluginId → ${alt.metadata.id}';
        }
      }
      // build138（P1-4）：熔断的**读键必须与写键同形**，为此把上面的 id 解析挪到算键之前。
      // 原读键 = `'$pluginId|$toolName'`（归一化 id + 归一化 tool），写键（本方法末尾的
      // handle 成功清零 / 异常自增）= `'${primary.metadata.id}|${attrs['tool']}'`
      // （真实注册表 id + 未归一化原始 tool）。两种已证实会不同的情形：
      //   ① 内置短名兜底（build107 U6）：log_query → nexus.builtin.log_query，两串必不同；
      //   ② tool 串带首尾空白：normalizeMcpTarget 已 trim，写键取原始值。
      // ⇒ 真正 handle() 抛异常这一类失败的计数写到没人读的键上，N6（build94）熔断对
      // 「最该断的那一类」永久失效（模型每轮重复撞同一个坏工具直到 maxRounds），
      // 反倒是 not_found /「插件未启用」这两类能熔断。两侧统一为「真实 id + 归一化 tool」；
      // 解析不到插件时（not_found）只有模型写的 id 可用，保持不变，读写的仍是同一个键。
      final circuitKey = '${target?.metadata.id ?? pluginId}|$toolName';
      mcpCircuitKey = circuitKey;
      final streak = _mcpFailStreaks[circuitKey] ?? 0;
      // N6（build94）：同 (pluginId, tool) 本消息内已连续失败 ≥2 次 → 熔断，
      // 不再进 handle，注入最终判定让 AI 直接答复（不再逐次喂错误）。
      if (streak >= 2) {
        pluginContext.addReasoningStep(
          'mcp_call',
          'MCP 熔断拦截',
          pluginId: pluginId.isEmpty ? null : pluginId,
          toolName: toolName.isEmpty ? null : toolName,
          arguments: attrs['arguments']?.toString(),
          status: 'circuit_open',
          resultSummary: '本消息内已连续失败 $streak 次，判定不可用',
        );
        pluginContext.addMessage(ChatMessage.create(
          conversationId: pluginContext.assistantMsg.conversationId,
          role: MessageRole.user,
          content: toolResultTag(
            pluginId: pluginId,
            tool: toolName,
            attrs: const {'is_error': 'true'},
            body: '宿主熔断：该工具在本消息内已连续失败 $streak 次，判定不可用。'
                '不要再调用，直接基于已有信息如实答复用户。',
          ),
        ));
        pluginContext.logger.warn(
            '[MCP] circuit open for $circuitKey after $streak consecutive failures',
            tag: 'Plugin');
        return false;
      }
      // build107（U6）：id 容错——模型常把 id 写错形态（目录前缀 mcp:amap / 内置短名
      // log_query），能唯一对应到注册表真实插件时自动纠正，不消耗调用次数。
      // build116：三段式等全部方言已由 normalizeMcpTarget 在上方统一处理，
      // 这里只补「内置插件短名」这一支（log_query → nexus.builtin.log_query）。
      // build138（P1-4）：这段解析**上移**到了熔断判据之前，见下方 circuitKey 的注释。
      if (target == null) {
        _mcpFailStreaks[circuitKey] = streak + 1;
        pluginContext.addReasoningStep(
          'mcp_call',
          'MCP 插件未找到',
          pluginId: pluginId.isEmpty ? null : pluginId,
          toolName: toolName.isEmpty ? null : toolName,
          arguments: attrs['arguments']?.toString(),
          status: 'not_found',
          resultSummary: '未找到插件（id 容错后仍无匹配）',
        );
        // build93(C1)：mcp 不可用也要喂回工作区，否则 AI 以为调用成功继续幻觉
        // build107（U6 日志实锤）：报错顺便教学——模型曾拿目录前缀 mcp:amap、内置短名
        // 当 id 反复空转，明确告知两种正确形态
        pluginContext.addMessage(ChatMessage.create(
          conversationId: pluginContext.assistantMsg.conversationId,
          role: MessageRole.user,
          content: toolResultTag(
            pluginId: pluginId,
            tool: 'mcp_call',
            attrs: const {'is_error': 'true'},
            // build173：正文里的 `<log_query …>` 是**给模型看的字面示例**，走信封后
            // 按不可信正文转义（示例仍然读得出，但它再也构造不出真标签）。
            body: '未找到插件「$pluginId」。提示：内置插件（目录里 nexus.builtin.* 开头）'
                '可直接输出其原生标签调用（如 <log_query category="ERROR" />）；'
                'MCP 连接器用安装后的完整 id（如 amap）。请停止重试并如实告知用户',
          ),
        ));
        return false;
      }
      if (!isEnabled(target.metadata.id)) {
        _mcpFailStreaks[circuitKey] = streak + 1;
        pluginContext.addReasoningStep(
          'mcp_call',
          '插件未启用',
          pluginId: target.metadata.id,
          toolName: toolName.isEmpty ? null : toolName,
          arguments: attrs['arguments']?.toString(),
          status: 'failed',
          resultSummary: '插件在插件管理里被停用',
        );
        pluginContext.addMessage(ChatMessage.create(
          conversationId: pluginContext.assistantMsg.conversationId,
          role: MessageRole.user,
          content: toolResultTag(
            pluginId: target.metadata.id,
            tool: 'mcp_call',
            attrs: const {'is_error': 'true'},
            body: '插件「${target.metadata.name}」当前被停用。'
                '请如实告知用户该能力不可用；用户可到 插件管理 手动开启。',
          ),
        ));
        return false;
      }
      if (idFixNote != null) {
        pluginContext.logger.info(
            '[MCP] mcp_call id auto-fix: $idFixNote (tool=$toolName)',
            tag: 'Plugin');
      }
      // build107（U6 通道归一）：内置声明式插件也接受 mcp_call——把 arguments JSON
      // 解码合并进 attrs（与标签通道属性同形入口）。日志实锤：FC 模型即使推对了
      // 标签用法，下一轮仍会因「函数列表里没有它」缩回 mcp_call——让通用入口
      // 真正通用，比反复教标签更可靠。
      if (!target.metadata.kind.isRemote && target is! InstalledMcpPlugin) {
        final rawArgs = attrs['arguments']?.toString() ?? '';
        try {
          final decoded =
              jsonDecode(rawArgs.isEmpty ? '{}' : rawArgs);
          if (decoded is Map) {
            attrs = {
              ...attrs,
              ...Map<String, dynamic>.from(decoded),
            };
          }
        } catch (_) {
          // arguments 不是合法 JSON 时按无参调用，由插件自行回灌错误
        }
      }
      primary = target;
    } else if (type == 'skill_call') {
      // v1.7.12：<skill_call name="skill.xxx"> 按名查找 Skill 插件。
      // 与 mcp_call 类似：用注册的 pluginId (skill.xxx) 精确匹配，
      // 找到的插件 handle 会注入 reasoning step 然后继续思考。
      final skillName = attrs['name']?.toString() ?? '';
      if (skillName.isEmpty) {
        pluginContext.addReasoningStep(
          'skill_call',
          'Skill 调用无名称',
          status: 'invalid',
          resultSummary: '缺少 Skill 名称',
        );
        return false;
      }
      // 1) 精确匹配 pluginId
      var target = _registry[skillName];
      // 2) 退化：按 metadata.name 匹配（有些 SKILL.md 名字带中文，pluginId 是 ASCII 化）
      if (target == null || !isEnabled(target.metadata.id)) {
        for (final p in _registry.values) {
          if (!isEnabled(p.metadata.id)) continue;
          if (p.metadata.name.toLowerCase() == skillName.toLowerCase() ||
              p.metadata.id.toLowerCase() == skillName.toLowerCase()) {
            target = p;
            break;
          }
        }
      }
      if (target == null ||
          !isEnabled(target.metadata.id) ||
          !target.metadata.kind.isDeclarative) {
        pluginContext.addReasoningStep(
          'skill_call',
          'Skill 不可用',
          pluginId: skillName,
          pluginName: skillName,
          arguments:
              attrs['arguments']?.toString() ?? attrs['content']?.toString(),
          status: target == null ? 'not_found' : 'failed',
          resultSummary: target == null ? '未找到或未启用 Skill' : '插件类型不匹配',
        );
        return false;
      }
      primary = target;
    }
    if (primary == null) {
      for (final p in _registry.values) {
        if (!isEnabled(p.metadata.id)) continue;
        if (p.triggerType == type) {
          primary = p;
          break;
        }
      }
    }
    if (type != 'mcp_call') primary ??= _fallbacks[type];
    if (primary == null) {
      final fb = _fallbackPlugin;
      if (fb != null && isEnabled(fb.metadata.id)) {
        try {
          await fb.handle(context, pluginContext, {'type': type, ...attrs});
          handled = true;
        } catch (e) {
          // build133（②）：兜底路径的异常不再用 debugPrint 吞掉 —— release 下
          // debugPrint 不输出、且绕开 LoggerService ⇒ 真机日志里完全看不到这类失败。
          // 与主链路（下面 primary 的 catch）同源，走 pluginContext.logger。
          pluginContext.logger.error(
              'Plugin fallback handle failed: type=$type plugin=${fb.metadata.id}',
              error: e,
              tag: 'Plugin');
        }
      }
      return handled;
    }
    if (!isEnabled(primary.metadata.id)) return false;
    try {
      await primary.handle(context, pluginContext, {...attrs, 'type': type});
      handled = true;
      // N6（build94）：mcp_call 成功即清零该 (pluginId, tool) 的连续失败计数
      // build138（P1-4）：键取分支里算好的 mcpCircuitKey（与读侧同一个串），
      // 不再就地用 `primary.metadata.id + 未归一化的 attrs['tool']` 拼一遍。
      if (type == 'mcp_call') {
        _mcpFailStreaks.remove(mcpCircuitKey);
      }
    } catch (e) {
      // v1.7.1 fix C2: 插件异常不再静默吞掉，注入错误消息让 AI 知道失败
      // build93(E4)：错误整形——只取首行、截 200 字，去掉堆栈噪音
      final shaped = _shapeError(e);
      if (type == 'mcp_call') {
        // build138（P1-4）：同上 —— 失败自增必须写进读侧真正查的那个键，
        // 否则熔断对「handle 真的抛异常」这一类永久失效。
        _mcpFailStreaks[mcpCircuitKey] =
            (_mcpFailStreaks[mcpCircuitKey] ?? 0) + 1;
        pluginContext.addReasoningStep(
          'mcp_call',
          'MCP 插件执行异常',
          pluginId: primary.metadata.id,
          pluginName: primary.metadata.name,
          toolName: attrs['tool']?.toString(),
          arguments: attrs['arguments']?.toString(),
          status: 'failed',
          resultSummary: shaped,
        );
        // build93(C1)：mcp 异常同样喂回工作区（此前只记步骤，AI 不知情继续幻觉）
        pluginContext.addMessage(ChatMessage.create(
          conversationId: pluginContext.assistantMsg.conversationId,
          role: MessageRole.user,
          content: toolResultTag(
            pluginId: primary.metadata.id,
            tool: 'mcp_call',
            attrs: const {'is_error': 'true'},
            // build173：`$shaped` 是**上游原文**（MCP 服务/插件异常），此前原样
            // 拼进外壳 ⇒ 一句 `</toolresult>` 就能越栏伪造第二条工具结果。
            body: 'MCP 调用失败：$shaped',
          ),
        ));
        return false;
      }
      final errorMsg = toolResultTag(
        pluginId: primary.metadata.id,
        tool: type,
        attrs: const {'is_error': 'true'},
        body: '插件执行失败: $shaped',
      );
      pluginContext.addMessage(ChatMessage.create(
        conversationId: pluginContext.assistantMsg.conversationId,
        role: MessageRole.user,
        content: errorMsg,
      ));
      pluginContext.logger.error('Plugin ${primary.metadata.id} handle failed',
          error: e, tag: 'Plugin');
    }
    if (!handled && type != 'mcp_call') {
      if (!context.mounted) return handled;
      for (final p in _registry.values) {
        if (identical(p, primary)) continue;
        if (!isEnabled(p.metadata.id)) continue;
        final legacy = p.legacyTrigger;
        final raw =
            attrs['raw']?.toString() ?? attrs['content']?.toString() ?? '';
        if (raw.isEmpty) continue;
        final match = legacy?.firstMatch(raw);
        final remoteMatch = BuiltinPromptCatalog.instance.matchesTriggerWords(
          p.triggerType,
          raw,
        );
        if (match == null && !remoteMatch) continue;
        final legacyAttrs = Map<String, dynamic>.from(attrs);
        legacyAttrs['legacyMatch'] = match;
        legacyAttrs['_legacyRaw'] = raw;
        try {
          await p.handle(context, pluginContext, legacyAttrs);
          handled = true;
          break;
        } catch (e) {
          // build133（②）：同型问题 —— legacy 触发词扫描路径也在用 debugPrint 吞异常，
          // release 下真机完全无痕。改走 LoggerService。
          pluginContext.logger.error(
              'Plugin legacy handle failed: plugin=${p.metadata.id}',
              error: e,
              tag: 'Plugin');
        }
      }
    }
    return handled;
  }

  // build93(E4)：错误整形——只取首行、截 200 字，避免把堆栈/HTML 错误页喂给模型
  static String _shapeError(Object e) {
    var s = e.toString().trim();
    final nl = s.indexOf('\n');
    if (nl > 0) s = s.substring(0, nl);
    if (s.length > 200) s = '${s.substring(0, 200)}…';
    return s;
  }
}
