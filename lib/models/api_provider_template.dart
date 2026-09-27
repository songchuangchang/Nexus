import 'dart:convert';

import 'package:flutter/material.dart';

import '../constants.dart';

/// 单个模型版本选项（用户在 API 配置页可以一键切换）
class ModelOption {
  final String id; // 真实发到 API 的 model 字段
  final String nameZh; // 中文 UI 显示名
  final String nameEn; // 英文 UI 显示名
  final bool recommended; // 是否为推荐默认
  final bool isFreeModel; // 这个具体模型是否官方免费
  final String? noteZh; // 简短特点说明（可选）
  final String? noteEn;

  const ModelOption({
    required this.id,
    required this.nameZh,
    required this.nameEn,
    this.recommended = false,
    this.isFreeModel = false,
    this.noteZh,
    this.noteEn,
  });

  String displayName(bool isZh) => isZh ? nameZh : nameEn;
  String? note(bool isZh) => isZh ? noteZh : noteEn;

  /// v1.7.24 (#7)：JSON 序列化，供模板远程配置（JSON）使用。
  Map<String, dynamic> toJson() => {
        'id': id,
        'nameZh': nameZh,
        'nameEn': nameEn,
        'recommended': recommended,
        'isFreeModel': isFreeModel,
        'noteZh': noteZh,
        'noteEn': noteEn,
      };

  factory ModelOption.fromJson(Map<String, dynamic> j) => ModelOption(
        id: (j['id'] ?? '').toString(),
        nameZh: (j['nameZh'] ?? j['name'] ?? '').toString(),
        nameEn: (j['nameEn'] ?? j['name'] ?? '').toString(),
        recommended: j['recommended'] == true,
        isFreeModel: j['isFreeModel'] == true,
        noteZh: j['noteZh']?.toString(),
        noteEn: j['noteEn']?.toString(),
      );
}

/// 预置的 OpenAI 兼容 API Provider 模板
///
/// 数据基于 2026-08 官方公开价格/文档核实。
/// 免费标记 **超级严格**（避免误导用户以为"永远白嫖"）：
///   hasFreeTier=true  仅当：该服务商在 API 层面提供
///                        「永久免费、不限调用总次数 / 总量」的免费层
///                        （如 ERNIE-Speed、Gemini-3-Flash 免费 RPM、
///                         Spark-Lite、Ollama 本地）。
///                       *包括 Groq 那种 RPM/RPD 有上限但永久可循环用的也算。
///   hasFreeTier=false  其余所有情况：
///                      · 只有一次性新人赠金 / 限时代金券 / 30 天有效 Tokens
///                        （DeepSeek / Kimi / 腾讯混元 / 阿里云 / 豆包 等）
///                      · 纯网页端免费但 API 全付费（MiniMax 等）
///                      · 欢迎赠金永久有效但总量有限，用完即止（Kimi 15元）
///   isFreeModel=true   仅对「这个具体模型名」真的是永久免费API层时才标。
///
/// 排序规则：按国内开发者真实调用量（OpenRouter/社区数据）从高到低：
///   国内：DeepSeek → Qwen → 智谱GLM → Kimi → 硅基流动 → MiniMax → 豆包 → 千帆 → 混元 → 星火
///   国际：OpenRouter → OpenAI → Gemini → Groq → Claude → Together
///   本地：Ollama → LM Studio
class ApiProviderTemplate {
  final String id;
  final String nameZh;
  final String nameEn;
  final String defaultConfigName;
  final String baseUrl;
  final String defaultModel;
  final List<ModelOption> models;
  final ApiProviderGroup group;

  /// 是否提供 API 层面的永久免费模型或永久免费额度
  final bool hasFreeTier;

  /// 免费方式的简短说明（用在提示小气泡里）
  final String freeDetailZh;
  final String freeDetailEn;

  final String descZh;
  final String descEn;
  final Color color;
  final IconData icon;

  /// build98：厂商图标远程 URL（远程模板 JSON 下发）。
  /// build99：内置模板填 lobe-icons CDN（npmmirror 国内可达，400+ 厂商），
  /// VendorAvatar 下载 → 磁盘缓存 → 失败记忆不重试。
  /// 内置模板留空 → 仍走色块+IconData 内置兜底（未知厂商/新增模板）。
  final String iconUrl;

  const ApiProviderTemplate({
    required this.id,
    required this.nameZh,
    required this.nameEn,
    required this.defaultConfigName,
    required this.baseUrl,
    required this.defaultModel,
    this.models = const [],
    required this.group,
    this.hasFreeTier = false,
    this.freeDetailZh = '',
    this.freeDetailEn = '',
    this.descZh = '',
    this.descEn = '',
    this.color = Colors.blue,
    this.icon = Icons.cloud,
    this.iconUrl = '',
  });

  static const String customId = 'custom';
  static const List<ApiProviderTemplate> all = _all;

  /// v1.5.2：服务商官网链接映射（用户点击跳转去注册账号 / 查 API Key）
  static const Map<String, String> _officialUrls = {
    'deepseek': 'https://platform.deepseek.com/',
    'dashscope': 'https://bailian.console.aliyun.com/',
    'glm': 'https://open.bigmodel.cn/',
    'kimi': 'https://platform.moonshot.cn/',
    'siliconflow': 'https://siliconflow.cn/',
    'minimax': 'https://platform.minimaxi.com/',
    'doubao': 'https://console.volcengine.com/ark',
    'qianfan': 'https://qianfan.cloud.baidu.com/',
    'hunyuan': 'https://cloud.tencent.com/product/hunyuan',
    'xfyun': 'https://xinghuo.xfyun.cn/',
    'openrouter': 'https://openrouter.ai/',
    'openai': 'https://platform.openai.com/',
    'gemini': 'https://ai.google.dev/',
    'groq': 'https://console.groq.com/',
    'claude': 'https://console.anthropic.com/',
    'together': 'https://www.together.ai/',
    'ollama': 'https://ollama.com/',
    'lmstudio': 'https://lmstudio.ai/',
  };

  /// 官网链接（无则空字符串）
  String get officialUrl => _officialUrls[id] ?? '';

  static List<ApiProviderTemplate> byGroup(ApiProviderGroup g) =>
      all.where((e) => e.group == g).toList();

  String get recommendedModelId => models.isNotEmpty
      ? models.firstWhere((m) => m.recommended, orElse: () => models.first).id
      : defaultModel;

  // ================================================================
  // v1.7.24 (#7)：JSON 序列化 + 颜色/图标字符串映射（供远程模板配置）
  // ================================================================

  static const Map<String, Color> _colorByName = {
    'purple': Colors.purple,
    'orange': Colors.orange,
    'teal': Colors.teal,
    'lightBlue': Colors.lightBlue,
    'cyan': Colors.cyan,
    'indigo': Colors.indigo,
    'red': Colors.red,
    'blueGrey': Colors.blueGrey,
    'amber': Colors.amber,
    'green': Colors.green,
    'blueAccent': Colors.blueAccent,
    'deepOrange': Colors.deepOrange,
    'brown': Colors.brown,
    'pinkAccent': Colors.pinkAccent,
    'black87': Colors.black87,
    'blue': Colors.blue,
  };

  static const Map<String, IconData> _iconByName = {
    'all_inclusive': Icons.all_inclusive,
    'cloud': Icons.cloud,
    'smart_toy': Icons.smart_toy,
    'dark_mode': Icons.dark_mode,
    'lan': Icons.lan,
    'animation': Icons.animation,
    'volcano': Icons.volcano,
    'public': Icons.public,
    'brightness_auto': Icons.brightness_auto,
    'local_fire_department': Icons.local_fire_department,
    'hub': Icons.hub,
    'generating_tokens': Icons.generating_tokens,
    'auto_awesome': Icons.auto_awesome,
    'bolt': Icons.bolt,
    'wb_sunny': Icons.wb_sunny,
    'account_tree': Icons.account_tree,
    'computer': Icons.computer,
    'desktop_mac': Icons.desktop_mac,
  };

  /// 解析颜色：支持 'purple' 等名称，或 '0xFF20B2AA' 十六进制。
  static Color colorFromName(String? name) {
    if (name == null || name.isEmpty) return Colors.blue;
    final named = _colorByName[name];
    if (named != null) return named;
    final v = int.tryParse(name.replaceFirst('0x', ''), radix: 16);
    if (v != null) return Color(v);
    return Colors.blue;
  }

  static String colorToName(Color c) {
    for (final e in _colorByName.entries) {
      if (e.value == c) return e.key;
    }
    return '0x${c.toARGB32().toRadixString(16).toUpperCase()}';
  }

  static IconData iconFromName(String? name) =>
      _iconByName[name] ?? Icons.cloud;

  static String iconToName(IconData i) {
    for (final e in _iconByName.entries) {
      if (e.value == i) return e.key;
    }
    return 'cloud';
  }

  /// v1.7.24 (#7)：导出为 JSON（供资产/远程配置复用）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'nameZh': nameZh,
        'nameEn': nameEn,
        'defaultConfigName': defaultConfigName,
        'baseUrl': baseUrl,
        'defaultModel': defaultModel,
        'group': group.name,
        'hasFreeTier': hasFreeTier,
        'freeDetailZh': freeDetailZh,
        'freeDetailEn': freeDetailEn,
        'descZh': descZh,
        'descEn': descEn,
        'color': colorToName(color),
        'icon': iconToName(icon),
        if (iconUrl.isNotEmpty) 'iconUrl': iconUrl,
        'models': models.map((m) => m.toJson()).toList(),
      };

  /// v1.7.24 (#7)：从 JSON 解析模板。
  factory ApiProviderTemplate.fromJson(Map<String, dynamic> j) {
    final modelsRaw = (j['models'] as List?) ?? const [];
    return ApiProviderTemplate(
      id: (j['id'] ?? '').toString(),
      nameZh: (j['nameZh'] ?? j['name'] ?? '').toString(),
      nameEn: (j['nameEn'] ?? j['name'] ?? '').toString(),
      defaultConfigName: (j['defaultConfigName'] ?? j['name'] ?? '').toString(),
      baseUrl: (j['baseUrl'] ?? '').toString(),
      defaultModel: (j['defaultModel'] ?? '').toString(),
      group: ApiProviderGroup.values.firstWhere((g) => g.name == j['group'],
          orElse: () => ApiProviderGroup.international),
      hasFreeTier: j['hasFreeTier'] == true,
      freeDetailZh: (j['freeDetailZh'] ?? '').toString(),
      freeDetailEn: (j['freeDetailEn'] ?? '').toString(),
      descZh: (j['descZh'] ?? '').toString(),
      descEn: (j['descEn'] ?? '').toString(),
      color: colorFromName(j['color']?.toString()),
      icon: iconFromName(j['icon']?.toString()),
      iconUrl: (j['iconUrl'] ?? '').toString(),
      models: modelsRaw
          .whereType<Map>()
          .map((m) => ModelOption.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
    );
  }
}

enum ApiProviderGroup {
  domestic, // 国内
  international, // 国际
  local, // 本地模型
}

// =====================================================================
// 20 个模板 + 自定义：按使用频率从高到低排序
// 免费标记规则（超级严格）：
//   ✅ hasFreeTier=true  → 提供「永久可循环用」的免费 API 层/模型
//                         （不限总量用完作废、不一次性、不过期）
//   ❌ hasFreeTier=false → 其他情况：一次性赠金、限时代金券、
//                          API 全付费但网页端免费、欢迎额度用完就没
// =====================================================================
const _all = <ApiProviderTemplate>[
  // ================================================================
  // 国内组（按 OpenRouter 全球 Token 量 + 国内社区口碑排序）
  // ================================================================

  // ① DeepSeek —— 全球#3调用量，V4系列2026主推
  ApiProviderTemplate(
    id: 'deepseek',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/deepseek.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: 'DeepSeek',
    nameEn: 'DeepSeek',
    defaultConfigName: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    // build138（C 批）：官方定价页 2026-09-20 已不再列 deepseek-v4-flash，
    // 且第三方镜像标其停用日期 2026-10-31 ⇒ 默认模型换成仍在售的 V4-Pro。
    defaultModel: 'deepseek-v4-pro',
    group: ApiProviderGroup.domestic,
    hasFreeTier: false,
    freeDetailZh: '仅新账号赠 500 万 Tokens（30天有效），过期/用完后 API 全付费',
    freeDetailEn:
        'New-account 5M tokens (30 days only); API paid after credit expires',
    descZh: '2026 最新 V4 系列，V4-Flash 性价比极高，API 按量付费',
    descEn: 'Latest V4 lineup 2026; V4-Flash best cost/performance',
    color: Colors.purple,
    icon: Icons.all_inclusive,
    models: [
      ModelOption(
          id: 'deepseek-v4-flash',
          nameZh: 'V4-Flash · 性价比',
          nameEn: 'V4-Flash · Value',
          // build138（C 批）：官方定价页已不列本 ID，镜像标 2026-10-31 停用。
          // 条目保留（存量配置还在用），但不再推荐，并在名字下面写清楚。
          noteZh: '官方即将停用（2026-10-31）→ 请转 V4-Pro',
          noteEn: 'Vendor-retired 2026-10-31 - switch to V4-Pro'),
      ModelOption(
          id: 'deepseek-v4-pro',
          nameZh: 'V4-Pro · 旗舰',
          nameEn: 'V4-Pro · Flagship',
          recommended: true,
          noteZh: '1M 上下文，更强推理；现为默认',
          noteEn: '1M ctx, strongest reasoning; now default'),
      // C 批 2026-09-20 官方核对新增：https://api-docs.deepseek.com/quick_start/pricing
      ModelOption(
          id: 'deepseek-flash',
          nameZh: 'Flash · 标准',
          nameEn: 'Flash · Standard',
          noteZh: '1M 上下文 · 128K 输出，与 V4 同价',
          noteEn: '1M ctx / 128K out, V4-level pricing'),

      // build137：按用户要求删掉两条「没有意义」的条目 ——
      //   V3 · 兼容旧版（2026-07-24 已废弃）、R1 · 推理旧版（已迁移到 V4 思考模式）。
      //   它们的存在只会让模型列表变长、还得靠 note 解释「别选我」。
      //   旧配置里若仍存着 deepseek-chat / deepseek-reasoner，属用户自填 model 字符串，
      //   不走这张预设表，不会被本次删除影响。
    ],
  ),

  // ② 通义千问 Qwen —— 国内生态最广，3.7/3.8系列
  ApiProviderTemplate(
    id: 'dashscope',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/qwen.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: '阿里云 百炼 (Qwen)',
    nameEn: 'DashScope (Qwen)',
    defaultConfigName: '阿里云·百炼',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen3.7-plus',
    group: ApiProviderGroup.domestic,
    hasFreeTier: false,
    freeDetailZh: '仅新用户一次性赠 Tokens + 月度赠送额度，额度用完全付费',
    freeDetailEn:
        'One-time welcome + monthly free quota; API paid after quota runs out',
    descZh: '国内首选，模型最全；Qwen3.7/3.8 长上下文 1M',
    descEn: 'Broadest model lineup in China; 1M context on 3.7/3.8',
    color: Colors.orange,
    icon: Icons.cloud,
    models: [
      ModelOption(
          id: 'qwen3.7-plus',
          nameZh: 'Qwen3.7-Plus · 均衡',
          nameEn: 'Qwen3.7-Plus · Balanced',
          recommended: true,
          noteZh: '1M 上下文，日常主力',
          noteEn: '1M ctx, daily workhorse'),
      ModelOption(
          id: 'qwen3.7-flash',
          nameZh: 'Qwen3.7-Flash · 极速',
          nameEn: 'Qwen3.7-Flash · Fast',
          noteZh: '便宜大量调用',
          noteEn: 'Cheap for bulk calls'),
      // C 批 2026-09-20 官方核对新增：https://help.aliyun.com/zh/model-studio/models
      ModelOption(
          id: 'qwen3.8-flash',
          nameZh: 'Qwen3.8-Flash · 快',
          nameEn: 'Qwen3.8-Flash · Fast',
          noteZh: '2026-09 官方模型总览新增',
          noteEn: 'New in official model list 2026-09'),
      ModelOption(
          id: 'qwen3.8-max',
          nameZh: 'Qwen3.8-Max · 旗舰',
          nameEn: 'Qwen3.8-Max · Flagship',
          noteZh: '2026 最新旗舰，1M 上下文',
          noteEn: '2026 newest flagship, 1M ctx'),
      ModelOption(
          id: 'qwen3.7-max',
          nameZh: 'Qwen3.7-Max · 上一代旗舰',
          nameEn: 'Qwen3.7-Max · Prev Flagship',
          noteZh: '长期折扣中',
          noteEn: 'Running promo discount'),
      ModelOption(
          id: 'qwen-long',
          nameZh: 'Qwen-Long · 长文',
          nameEn: 'Qwen-Long',
          noteZh: '超长上下文',
          noteEn: 'Ultra-long context'),
      ModelOption(
          id: 'qwen-vl-max',
          nameZh: 'Qwen-VL-Max · 多模态',
          nameEn: 'Qwen-VL-Max · Vision',
          noteZh: '图片理解',
          noteEn: 'Image understanding'),
    ],
  ),

  // ③ 智谱 GLM —— 开源代码SOTA，4.7-Flash真正永久免费API
  ApiProviderTemplate(
    id: 'glm',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/zhipu.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: '智谱 GLM',
    nameEn: 'Zhipu GLM',
    defaultConfigName: '智谱 GLM',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-4.7-flash',
    group: ApiProviderGroup.domestic,
    hasFreeTier: true,
    freeDetailZh: 'GLM-4-Flash / GLM-4.7-Flash 永久免费；新用户赠 2000 万 Tokens',
    freeDetailEn: 'GLM-4/4.7-Flash FREE forever; new users get 20M tokens',
    descZh: 'Coding 能力开源 SOTA；4.7-Flash 永久免费 API',
    descEn: 'Open-source coding SOTA; 4.7-Flash free API forever',
    color: Colors.teal,
    icon: Icons.smart_toy,
    models: [
      ModelOption(
          id: 'glm-4.7-flash',
          nameZh: 'GLM-4.7-Flash · 永久免费',
          nameEn: 'GLM-4.7-Flash · Free Forever',
          isFreeModel: true,
          recommended: true,
          noteZh: '200K 上下文，免费',
          noteEn: '200K ctx, free'),
      ModelOption(
          id: 'glm-4-flash',
          nameZh: 'GLM-4-Flash · 永久免费',
          nameEn: 'GLM-4-Flash · Free Forever',
          isFreeModel: true,
          noteZh: '128K 上下文，免费',
          noteEn: '128K ctx, free'),
      ModelOption(
          id: 'glm-4.5-air',
          nameZh: 'GLM-4.5-Air · 高性价比',
          nameEn: 'GLM-4.5-Air · Value',
          noteZh: '¥0.8/¥2 每百万',
          noteEn: '¥0.8/¥2 per M'),
      ModelOption(
          id: 'glm-4.7',
          nameZh: 'GLM-4.7 · 主力',
          nameEn: 'GLM-4.7 · Mainstream',
          noteZh: '高智能主力档',
          noteEn: 'Balanced intelligence'),
      ModelOption(
          id: 'glm-5.2',
          nameZh: 'GLM-5.2 · 旗舰',
          nameEn: 'GLM-5.2 · Flagship',
          noteZh: '1M 上下文，Coding SOTA',
          noteEn: '1M ctx, coding SOTA'),
      // C 批 2026-09-20 官方核对新增：https://docs.bigmodel.cn/cn/coding-plan/latest-model
      ModelOption(
          id: 'glm-5.3-flash',
          nameZh: 'GLM-5.3-Flash',
          nameEn: 'GLM-5.3-Flash',
          noteZh: '2026-09 官方「最新模型」页新增',
          noteEn: 'New on official latest-model page'),
      ModelOption(
          id: 'glm-5.3',
          nameZh: 'GLM-5.3 · 最新旗舰',
          nameEn: 'GLM-5.3 · Newest Flagship',
          noteZh: '2026-08 最新发布',
          noteEn: 'Released Aug 2026'),
    ],
  ),

  // ④ Kimi Moonshot —— 全球#2调用量，256K/1M长上下文
  ApiProviderTemplate(
    id: 'kimi',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/moonshot.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: 'Kimi · 月之暗面',
    nameEn: 'Kimi (Moonshot)',
    defaultConfigName: 'Kimi',
    baseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'kimi-k2.5',
    group: ApiProviderGroup.domestic,
    hasFreeTier: false,
    freeDetailZh: '仅新用户赠 15 元代金券（总量有限用完即止），API 按用量付费',
    freeDetailEn:
        'New-account ~¥15 credit (finite, used up then paid); API pay-per-use',
    descZh: '256K/1M 超长上下文；编程 Agent 强',
    descEn: '256K/1M long context; strong coding agent',
    color: Colors.lightBlue,
    icon: Icons.dark_mode,
    models: [
      ModelOption(
          id: 'kimi-k2.5',
          nameZh: 'Kimi-K2.5 · 主力',
          nameEn: 'Kimi-K2.5 · Main',
          recommended: true,
          noteZh: '256K 上下文，多模态',
          noteEn: '256K ctx, multimodal'),
      ModelOption(
          id: 'kimi-k2.6',
          nameZh: 'Kimi-K2.6 · 高性能',
          nameEn: 'Kimi-K2.6 · Performance',
          noteZh: '延迟更低，393 tps',
          noteEn: 'Low latency, 393 tps'),
      ModelOption(
          id: 'kimi-k2.7-code',
          nameZh: 'Kimi-K2.7-Code · 编码',
          nameEn: 'Kimi-K2.7-Code',
          noteZh: '编程专项模型',
          noteEn: 'Coding specialized'),
      // C 批 2026-09-20 官方核对新增：https://platform.kimi.com/docs/pricing/chat
      ModelOption(
          id: 'kimi-k2.7-code-highspeed',
          nameZh: 'K2.7-Code 高速',
          nameEn: 'K2.7-Code HighSpeed',
          noteZh: '官方定价页新增高速档',
          noteEn: 'High-speed tier on official pricing page'),
      ModelOption(
          id: 'kimi-k3',
          nameZh: 'Kimi-K3 · 旗舰',
          nameEn: 'Kimi-K3 · Flagship',
          noteZh: '2026-07 发布，1M 上下文',
          noteEn: 'Released Jul 2026, 1M ctx'),
    ],
  ),

  // ⑤ 硅基流动 SiliconFlow —— 开源聚合，9B以下永久免费
  ApiProviderTemplate(
    id: 'siliconflow',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/siliconcloud.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: '硅基流动',
    nameEn: 'SiliconFlow',
    defaultConfigName: '硅基流动',
    baseUrl: 'https://api.siliconflow.cn/v1',
    defaultModel: 'deepseek-ai/DeepSeek-V4-Flash',
    group: ApiProviderGroup.domestic,
    hasFreeTier: true,
    freeDetailZh: '9B 以下开源模型永久免费；新用户赠 2000 万 Tokens',
    freeDetailEn: 'Models ≤9B FREE forever; new users get 20M tokens',
    descZh: '开源模型聚合平台；国内访问快',
    descEn: 'Open-source model hub; low latency in China',
    color: Colors.cyan,
    icon: Icons.lan,
    models: [
      ModelOption(
          id: 'deepseek-ai/DeepSeek-V4-Flash',
          nameZh: 'DeepSeek V4-Flash',
          nameEn: 'DeepSeek V4-Flash',
          recommended: true,
          noteZh: '最新 V4',
          noteEn: 'Latest V4'),
      ModelOption(
          id: 'Qwen/Qwen2.5-7B-Instruct',
          nameZh: 'Qwen2.5-7B · 永久免费',
          nameEn: 'Qwen2.5-7B · Free Forever',
          isFreeModel: true,
          noteZh: '≤9B 免费',
          noteEn: '≤9B, free'),
      ModelOption(
          id: 'Qwen/Qwen2.5-72B-Instruct',
          nameZh: 'Qwen2.5-72B',
          nameEn: 'Qwen2.5-72B'),
      ModelOption(
          id: 'THUDM/glm-4.7-flash',
          nameZh: 'GLM-4.7-Flash · 免费',
          nameEn: 'GLM-4.7-Flash · Free',
          isFreeModel: true),
      ModelOption(
          id: 'meta-llama/Llama-3.3-70B-Instruct',
          nameZh: 'Llama-3.3-70B',
          nameEn: 'Llama-3.3-70B'),
    ],
  ),

  // ⑥ MiniMax —— 全球#1调用量(M2.5/M3)
  ApiProviderTemplate(
    id: 'minimax',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/minimax.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: 'MiniMax',
    nameEn: 'MiniMax',
    defaultConfigName: 'MiniMax',
    baseUrl: 'https://api.minimaxi.com/v1',
    defaultModel: 'MiniMax-M3',
    group: ApiProviderGroup.domestic,
    hasFreeTier: false,
    freeDetailZh: 'API 全付费；仅网页端个人免费',
    freeDetailEn: 'API is paid; only web chat is free for individuals',
    descZh: '全球 Token 量最大(M2.5/M3)；多模态强',
    descEn: 'Highest global token volume; strong multimodal',
    color: Colors.indigo,
    icon: Icons.animation,
    models: [
      ModelOption(
          id: 'MiniMax-M3',
          nameZh: 'MiniMax-M3 · 最新旗舰',
          nameEn: 'MiniMax-M3 · Newest',
          recommended: true,
          noteZh: '2026 最新',
          noteEn: '2026 latest'),
      // C 批 2026-09-20 官方核对新增：https://platform.minimax.cn/docs/guides/text-generation
      ModelOption(
          id: 'MiniMax-M2.7',
          nameZh: 'M2.7 · 主力',
          nameEn: 'M2.7 · Mainline',
          noteZh: '2026-09 官方文本生成文档新增',
          noteEn: 'In official text-gen docs 2026-09'),
      // C 批 2026-09-20 官方核对新增：https://platform.minimax.cn/docs/guides/text-generation
      ModelOption(
          id: 'MiniMax-M2.7-highspeed',
          nameZh: 'M2.7 高速',
          nameEn: 'M2.7 HighSpeed',
          noteZh: '官方文档新增',
          noteEn: 'Listed in official docs'),
      ModelOption(
          id: 'MiniMax-M2.5',
          nameZh: 'MiniMax-M2.5',
          nameEn: 'MiniMax-M2.5',
          noteZh: '全球周调用量第一',
          noteEn: 'Global #1 weekly tokens'),
      ModelOption(
          id: 'MiniMax-Text-01',
          // build138（C 批）：官方文本生成文档的模型列表里**已找不到**这个 ID。
          // 不删（存量配置可能还在跑），但必须提示用户以官方为准。
          nameZh: 'MiniMax-Text-01',
          nameEn: 'MiniMax-Text-01'),
    ],
  ),

  // ⑦ 豆包 火山引擎 —— Seed 2.0 Pro 综合能力强
  ApiProviderTemplate(
    id: 'doubao',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/doubao.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: '豆包 · 火山引擎',
    nameEn: 'Doubao (VolcEngine)',
    defaultConfigName: '豆包 (火山)',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    defaultModel: 'doubao-seed-2-pro-32k',
    group: ApiProviderGroup.domestic,
    hasFreeTier: false,
    freeDetailZh: '仅有"安心体验"一次性额度 + 协作活动奖励，用完即止，API 非永久免费',
    freeDetailEn:
        'Safe-mode one-time quota + activity rewards only; non-permanent free API',
    descZh: 'Seed-2.0 Pro 中文综合体验最佳；支持所有主流模型',
    descEn: 'Best Chinese chat experience; supports all major models',
    color: Colors.red,
    icon: Icons.volcano,
    models: [
      ModelOption(
          id: 'doubao-seed-2-pro-32k',
          nameZh: 'Seed 2.0 Pro · 32K',
          nameEn: 'Seed 2.0 Pro · 32K',
          recommended: true,
          noteZh: '中文综合第一',
          noteEn: 'Best Chinese overall'),
      ModelOption(
          id: 'doubao-seed-2-lite-32k',
          nameZh: 'Seed 2.0 Lite',
          nameEn: 'Seed 2.0 Lite',
          noteZh: '轻量便宜',
          noteEn: 'Light & cheap'),
      ModelOption(
          id: 'doubao-1-5-pro-32k',
          nameZh: '豆包 1.5 Pro · 32K',
          nameEn: 'Doubao 1.5 Pro · 32K'),
      ModelOption(
          id: 'doubao-1-5-lite-32k',
          nameZh: '豆包 1.5 Lite',
          nameEn: 'Doubao 1.5 Lite'),
    ],
  ),

  // ⑧ 百度千帆 —— ERNIE-Speed永久免费
  ApiProviderTemplate(
    id: 'qianfan',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/wenxin.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: '百度 千帆 (ERNIE)',
    nameEn: 'Baidu Qianfan (ERNIE)',
    defaultConfigName: '百度千帆',
    baseUrl: 'https://qianfan.baidubce.com/v2',
    defaultModel: 'ernie_speed_8k',
    group: ApiProviderGroup.domestic,
    hasFreeTier: true,
    freeDetailZh: 'ERNIE-Speed-8K / ERNIE-3.5-8K 永久免费，QPS 50',
    freeDetailEn: 'ERNIE-Speed-8K / ERNIE-3.5-8K free forever, QPS 50',
    descZh: '百度出品；ERNIE-Speed 永久免费不限量',
    descEn: 'Baidu; ERNIE-Speed free forever unlimited',
    color: Colors.blueGrey,
    icon: Icons.public,
    models: [
      ModelOption(
          id: 'ernie_speed_8k',
          nameZh: 'ERNIE-Speed-8K · 永久免费',
          nameEn: 'ERNIE-Speed-8K · Free Forever',
          isFreeModel: true,
          recommended: true,
          noteZh: '永久免费，QPS 50',
          noteEn: 'Free forever, QPS 50'),
      ModelOption(
          id: 'ernie-3.5-8k',
          nameZh: 'ERNIE-3.5-8K · 永久免费',
          nameEn: 'ERNIE-3.5-8K · Free Forever',
          isFreeModel: true,
          noteZh: '永久免费',
          noteEn: 'Free forever'),
      // C 批 2026-09-20 官方核对新增：https://cloud.baidu.com/doc/qianfan/s/rmh4stp0j
      ModelOption(
          id: 'ernie-5.0',
          nameZh: 'ERNIE 5.0',
          nameEn: 'ERNIE 5.0',
          noteZh: '2026-09 官方模型列表新增',
          noteEn: 'New in official model list 2026-09'),
      // C 批 2026-09-20 官方核对新增：https://cloud.baidu.com/doc/qianfan/s/rmh4stp0j
      ModelOption(
          id: 'ernie-5.0-thinking-preview',
          nameZh: 'ERNIE 5.0 思考',
          nameEn: 'ERNIE 5.0 Thinking',
          noteZh: '官方模型列表新增（思考档）',
          noteEn: 'Official list, thinking variant'),
      ModelOption(
          id: 'ernie-4.5-turbo-vl-preview',
          nameZh: 'ERNIE-4.5 · 旗舰',
          nameEn: 'ERNIE-4.5 · Flagship',
          noteZh: '多模态',
          noteEn: 'Multimodal'),
      ModelOption(
          id: 'ernie-tiny-8k',
          nameZh: 'ERNIE-Tiny · 极速',
          nameEn: 'ERNIE-Tiny · Fastest',
          noteZh: '最快最轻',
          noteEn: 'Fastest, lightest'),
    ],
  ),

  // ⑨ 腾讯混元
  ApiProviderTemplate(
    id: 'hunyuan',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/hunyuan.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: '腾讯 混元',
    nameEn: 'Tencent Hunyuan',
    defaultConfigName: '腾讯混元',
    baseUrl: 'https://api.hunyuan.tencent.com/v1',
    defaultModel: 'hunyuan-standard',
    group: ApiProviderGroup.domestic,
    hasFreeTier: false,
    freeDetailZh: '仅新用户一次性 100 万 Token 资源包，用完即止，API 全付费',
    freeDetailEn:
        'New-user one-time 1M token package only; API fully paid afterward',
    descZh: '腾讯官方；微信/腾讯生态集成',
    descEn: 'Tencent official; WeChat/Tencent ecosystem',
    color: Color(0xFF20B2AA),
    icon: Icons.brightness_auto,
    models: [
      ModelOption(
          id: 'hunyuan-standard',
          nameZh: '混元-Standard · 均衡',
          nameEn: 'Hunyuan-Standard',
          recommended: true),
      // C 批 2026-09-20 官方核对新增：https://cloud.tencent.com/document/product/1823/130079
      ModelOption(
          id: 'hy3',
          nameZh: 'Hy3',
          nameEn: 'Hy3',
          noteZh: '2026-09 官方模型总览新增',
          noteEn: 'New in official model overview'),
      // C 批 2026-09-20 官方核对新增：https://cloud.tencent.com/document/product/1823/130079
      ModelOption(
          id: 'hy4-preview',
          nameZh: 'Hy4 · 预览',
          nameEn: 'Hy4 · Preview',
          noteZh: '官方模型总览新增',
          noteEn: 'Official model overview'),
      ModelOption(
          id: 'hunyuan-large',
          nameZh: '混元-Large · 旗舰',
          nameEn: 'Hunyuan-Large · Flagship'),
      ModelOption(
          id: 'hunyuan-lite',
          nameZh: '混元-Lite · 轻量',
          nameEn: 'Hunyuan-Lite · Light'),
      ModelOption(
          id: 'hunyuan-code', nameZh: '混元-Code · 编码', nameEn: 'Hunyuan-Code'),
    ],
  ),

  // ⑩ 讯飞星火
  ApiProviderTemplate(
    id: 'xfyun',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/spark.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: '讯飞 星火',
    nameEn: 'XFYun Spark',
    defaultConfigName: '讯飞星火',
    baseUrl: 'https://spark-openapi.cn-huabei-1.xf-yun.com/v1',
    defaultModel: 'spark-lite',
    group: ApiProviderGroup.domestic,
    hasFreeTier: true,
    freeDetailZh: 'Spark-Lite 永久免费（总量不限，QPS 2）',
    freeDetailEn: 'Spark-Lite free forever (unlimited tokens, QPS 2)',
    descZh: '中文理解强；Spark-Lite 永久免费',
    descEn: 'Strong Chinese understanding; Spark-Lite free forever',
    color: Color(0xFF1E90FF),
    icon: Icons.local_fire_department,
    models: [
      ModelOption(
          id: 'spark-lite',
          nameZh: 'Spark-Lite · 永久免费',
          nameEn: 'Spark-Lite · Free Forever',
          isFreeModel: true,
          recommended: true,
          noteZh: '永久免费，QPS 2',
          noteEn: 'Free forever, QPS 2'),
      ModelOption(
          id: 'spark-pro',
          nameZh: 'Spark-Pro · 主力',
          nameEn: 'Spark-Pro · Main'),
      ModelOption(
          id: 'spark-max',
          nameZh: 'Spark-Max · 旗舰',
          nameEn: 'Spark-Max · Flagship'),
      ModelOption(
          id: 'spark-ultra',
          nameZh: 'Spark-Ultra · 最强',
          nameEn: 'Spark-Ultra · Strongest'),
    ],
  ),

  // ================================================================
  // 国际组（按全球开发者使用频率排序）
  // ================================================================

  // ⑪ OpenRouter —— 一把 Key 用 400+ 模型
  ApiProviderTemplate(
    id: 'openrouter',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/openrouter.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: 'OpenRouter (400+ 模型)',
    nameEn: 'OpenRouter (400+ Models)',
    defaultConfigName: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    defaultModel: 'openrouter/auto',
    group: ApiProviderGroup.international,
    hasFreeTier: false,
    freeDetailZh: '仅部分模型偶有免费促销；平台本身无稳定永久免费层',
    freeDetailEn:
        'Occasional free-tier model promos only; no stable permanent free tier on platform',
    descZh: '一把 Key 访问全球所有主流大模型',
    descEn: 'One API key for 400+ models worldwide',
    color: Colors.amber,
    icon: Icons.hub,
    models: [
      ModelOption(
          id: 'openrouter/auto',
          nameZh: 'Auto · 自动路由',
          nameEn: 'Auto · Auto Route',
          recommended: true,
          noteZh: '自动选最便宜',
          noteEn: 'Auto cheapest'),
      ModelOption(
          id: 'deepseek/deepseek-v4-flash',
          nameZh: 'DeepSeek V4-Flash',
          nameEn: 'DeepSeek V4-Flash'),
      ModelOption(
          id: 'anthropic/claude-sonnet-4.6',
          nameZh: 'Claude Sonnet 4.6',
          nameEn: 'Claude Sonnet 4.6'),
      // build138（C 批）：google/gemini-3-flash 在 OpenRouter 自家公共 API
      // （GET /api/v1/models/<slug>/endpoints）返回 **404** ⇒ 换成该 API 确认
      // 存在的 google/gemini-3.5-flash（1,048,576 上下文）。这是本批唯一一条
      // 删除，依据是厂商自营目录的直连证据，不是猜测。
      // C 批 2026-09-20 官方核对新增：https://openrouter.ai/api/v1/models/google/gemini-3.5-flash/endpoints
      ModelOption(
          id: 'google/gemini-3.5-flash',
          nameZh: 'Gemini 3.5 Flash',
          nameEn: 'Gemini 3.5 Flash',
          noteZh: 'OpenRouter 目录确认存在（1M 上下文）',
          noteEn: 'Confirmed live in OpenRouter catalog (1M ctx)'),
      // C 批 2026-09-20 官方核对新增：https://openrouter.ai/api/v1/models/anthropic/claude-sonnet-5/endpoints
      ModelOption(
          id: 'anthropic/claude-sonnet-5',
          nameZh: 'Claude Sonnet 5',
          nameEn: 'Claude Sonnet 5',
          noteZh: 'OpenRouter 目录确认存在（1M 上下文）',
          noteEn: 'Confirmed live in OpenRouter catalog (1M ctx)'),

      ModelOption(
          id: 'openai/gpt-5.4-mini',
          nameZh: 'GPT-5.4 Mini',
          nameEn: 'GPT-5.4 Mini'),
    ],
  ),

  // ⑫ OpenAI —— 行业标杆
  ApiProviderTemplate(
    id: 'openai',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/openai.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: 'OpenAI (GPT)',
    nameEn: 'OpenAI (GPT)',
    defaultConfigName: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-5.4-mini',
    group: ApiProviderGroup.international,
    hasFreeTier: false,
    freeDetailZh: 'API 全付费；无免费额度（需绑卡）',
    freeDetailEn: 'API fully paid; no free tier (credit card required)',
    descZh: 'GPT-5.5 / 5.4 系列；Agent 能力突破基线',
    descEn: 'GPT-5.5 / 5.4; agent capability beat human baseline',
    color: Colors.green,
    icon: Icons.generating_tokens,
    models: [
      ModelOption(
          id: 'gpt-5.4-mini',
          nameZh: 'GPT-5.4 Mini · 轻量',
          nameEn: 'GPT-5.4 Mini · Light',
          recommended: true,
          noteZh: '便宜快',
          noteEn: 'Cheap & fast'),
      ModelOption(
          id: 'gpt-5.4',
          nameZh: 'GPT-5.4 · 旗舰',
          nameEn: 'GPT-5.4 · Flagship',
          noteZh: '多模态',
          noteEn: 'Multimodal'),
      ModelOption(
          id: 'gpt-5.5',
          nameZh: 'GPT-5.5 · 最新旗舰',
          nameEn: 'GPT-5.5 · Newest Flagship',
          noteZh: '2026 最新',
          noteEn: '2026 newest'),
      // C 批 2026-09-20 官方核对新增：https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure
      ModelOption(
          id: 'gpt-5.4-nano',
          nameZh: 'GPT-5.4-nano · 最省',
          nameEn: 'GPT-5.4-nano · Cheapest',
          noteZh: '400K 上下文；来源 Azure 目录（OpenAI 文档本次不可达）',
          noteEn: '400K ctx; via Azure catalog (openai.com unreachable here)'),
      // C 批 2026-09-20 官方核对新增：https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure
      ModelOption(
          id: 'gpt-5.6-sol',
          nameZh: 'GPT-5.6-sol · 最新',
          nameEn: 'GPT-5.6-sol · Newest',
          noteZh: '1.05M 上下文；来源 Azure 目录，未在 OpenAI 文档二次确认',
          noteEn: '1.05M ctx; Azure-sourced, not re-confirmed on openai.com'),
      ModelOption(
          id: 'o3-mini',
          nameZh: 'o3-mini · 推理',
          nameEn: 'o3-mini · Reasoner',
          noteZh: '链式思考',
          noteEn: 'Chain-of-thought'),
    ],
  ),

  // ⑬ Google Gemini —— Gemini 3 系列
  ApiProviderTemplate(
    id: 'gemini',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/gemini.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: 'Google Gemini',
    nameEn: 'Google Gemini',
    defaultConfigName: 'Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    defaultModel: 'gemini-3-flash',
    group: ApiProviderGroup.international,
    hasFreeTier: true,
    freeDetailZh: 'Gemini 3 Flash / 2.5 Flash 免费层（限 RPM/RPD）',
    freeDetailEn: 'Gemini 3/2.5 Flash free tier (RPM/RPD limits)',
    descZh: 'Gemini 3 系列；多模态标杆',
    descEn: 'Gemini 3 lineup; multimodal benchmark leader',
    color: Colors.blueAccent,
    icon: Icons.auto_awesome,
    models: [
      ModelOption(
          id: 'gemini-3-flash',
          nameZh: 'Gemini 3 Flash · 免费层',
          nameEn: 'Gemini 3 Flash · Free Tier',
          isFreeModel: true,
          recommended: true,
          noteZh: '免费层可用',
          noteEn: 'Free tier'),
      ModelOption(
          id: 'gemini-3.5-flash',
          nameZh: 'Gemini 3.5 Flash',
          nameEn: 'Gemini 3.5 Flash'),
      ModelOption(
          id: 'gemini-3.1-pro',
          nameZh: 'Gemini 3.1 Pro · 旗舰',
          nameEn: 'Gemini 3.1 Pro · Flagship',
          noteZh: '16项基准赢13项',
          noteEn: 'Won 13/16 benchmarks'),
      ModelOption(
          id: 'gemini-2.5-flash',
          nameZh: 'Gemini 2.5 Flash · 免费',
          nameEn: 'Gemini 2.5 Flash · Free',
          isFreeModel: true),
    ],
  ),

  // ⑭ Groq —— LPU 极速推理
  ApiProviderTemplate(
    id: 'groq',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/groq.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: 'Groq (极速推理)',
    nameEn: 'Groq (Ultra Fast)',
    defaultConfigName: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    defaultModel: 'llama-3.3-70b-versatile',
    group: ApiProviderGroup.international,
    hasFreeTier: true,
    freeDetailZh: '免费层：RPM 30、RPD 14400、TPD 500K',
    freeDetailEn: 'Free tier: 30 RPM, 14,400 RPD, 500K TPD',
    descZh: 'LPU 加速；推理 <100ms 响应',
    descEn: 'LPU-accelerated; sub-100ms inference',
    color: Colors.deepOrange,
    icon: Icons.bolt,
    models: [
      ModelOption(
          id: 'llama-3.3-70b-versatile',
          nameZh: 'Llama-3.3-70B',
          nameEn: 'Llama-3.3-70B',
          recommended: true),
      ModelOption(
          id: 'llama-3.1-8b-instant',
          nameZh: 'Llama-3.1-8B · 极速',
          nameEn: 'Llama-3.1-8B · Instant',
          noteZh: '最快',
          noteEn: 'Fastest'),
      ModelOption(
          id: 'qwen/qwen3-32b', nameZh: 'Qwen3-32B', nameEn: 'Qwen3-32B'),
    ],
  ),

  // ⑮ Anthropic Claude (兼容接口)
  ApiProviderTemplate(
    id: 'claude',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/claude.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: 'Anthropic Claude',
    nameEn: 'Anthropic Claude',
    defaultConfigName: 'Claude',
    baseUrl: 'https://api.anthropic.com/v1',
    // build138（C 批）：默认位交给 Sonnet 5（1M 上下文、自适应思考，Azure/Bedrock
    // 官方模型卡均列为现行在售）；4.6 一代在官方定价页已进 Legacy 面板。
    defaultModel: 'claude-sonnet-5',
    group: ApiProviderGroup.international,
    hasFreeTier: false,
    freeDetailZh: 'API 全付费；无免费额度',
    freeDetailEn: 'API fully paid; no free tier',
    descZh: '综合体验最佳（Claude Opus）；编程 SWE-bench 80.8%',
    descEn: 'Best overall experience; 80.8% on SWE-bench',
    color: Colors.brown,
    icon: Icons.wb_sunny,
    models: [
      ModelOption(
          id: 'claude-sonnet-4.6',
          nameZh: 'Claude Sonnet 4.6 · 均衡',
          nameEn: 'Claude Sonnet 4.6 · Balanced',
          // build138（C 批）：官方定价页把 4.6 一代列在 Legacy 面板 ⇒ 让出推荐位，
          // 条目保留（存量配置还在用）。
          noteZh: '官方已列入 Legacy 面板',
          noteEn: 'Listed under Legacy on official pricing'),
      // C 批 2026-09-20 官方核对新增：https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html
      ModelOption(
          id: 'claude-sonnet-5',
          nameZh: 'Sonnet 5 · 新默认',
          nameEn: 'Sonnet 5 · New default',
          recommended: true,
          noteZh: '1M 上下文 · 自适应思考；来源 Azure/Bedrock 官方模型卡',
          noteEn: '1M ctx, adaptive thinking; via Azure/Bedrock model cards'),
      // C 批 2026-09-20 官方核对新增：https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/claude-models
      ModelOption(
          id: 'claude-fable-5-1',
          nameZh: 'Fable 5.1 · 旗舰',
          nameEn: 'Fable 5.1 · Flagship',
          noteZh: '1M 上下文 · 仅自适应思考（USD 10 入 / 50 出 每百万 token）',
          noteEn: '1M ctx, adaptive-thinking only (USD 10 in / 50 out per MTok)'),
      ModelOption(
          id: 'claude-haiku-4.5',
          nameZh: 'Claude Haiku 4.5 · 极速',
          nameEn: 'Claude Haiku 4.5 · Fast',
          noteZh: '最快最便宜',
          noteEn: 'Fastest & cheapest'),
      ModelOption(
          id: 'claude-opus-4.6',
          nameZh: 'Claude Opus 4.6 · 旗舰',
          nameEn: 'Claude Opus 4.6 · Flagship',
          noteZh: '综合体验第一',
          noteEn: 'Best overall LMArena #1'),
      ModelOption(
          id: 'claude-opus-5',
          nameZh: 'Claude Opus 5 · 最新旗舰',
          nameEn: 'Claude Opus 5 · Newest',
          noteZh: '2026 最新',
          noteEn: '2026 newest'),
    ],
  ),

  // ⑯ Together AI
  ApiProviderTemplate(
    id: 'together',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/together.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: 'Together AI',
    nameEn: 'Together AI',
    defaultConfigName: 'Together AI',
    baseUrl: 'https://api.together.xyz/v1',
    defaultModel: 'meta-llama/Llama-3.3-70B-Instruct-Turbo',
    group: ApiProviderGroup.international,
    hasFreeTier: false,
    freeDetailZh: 'API 全付费；新账户限时赠金',
    freeDetailEn: 'API paid; new-account time-limited credit',
    descZh: '开源模型推理云；性价比',
    descEn: 'Open source model cloud inference',
    color: Colors.pinkAccent,
    icon: Icons.account_tree,
    models: [
      ModelOption(
          id: 'meta-llama/Llama-3.3-70B-Instruct-Turbo',
          nameZh: 'Llama-3.3-70B Turbo',
          nameEn: 'Llama-3.3-70B Turbo',
          recommended: true),
      ModelOption(
          id: 'deepseek-ai/DeepSeek-V4-Pro',
          nameZh: 'DeepSeek V4-Pro',
          nameEn: 'DeepSeek V4-Pro',
          noteZh: '1.6T MoE',
          noteEn: '1.6T MoE'),
      ModelOption(
          id: 'meta-llama/Llama-4-Ultra',
          nameZh: 'Llama-4-Ultra',
          nameEn: 'Llama-4-Ultra',
          noteZh: 'Meta 最新旗舰',
          noteEn: 'Meta newest flagship'),
    ],
  ),

  // ================================================================
  // 本地模型组（模型实际运行在电脑上，完全免费，无需 API Key）
  // 适配：电脑本地运行的量化模型；手机只是客户端，通过局域网连接
  // ================================================================

  // ⑰ Ollama 本地模型（模型跑在电脑上，手机通过局域网连接）
  // v1.3.9：baseUrl 默认留空，避免误用 localhost（手机上 localhost 指手机本身，
  //   永远连不到电脑的 Ollama 服务）。用户需手动填电脑局域网 IP，如 http://192.168.1.100:11434/v1
  ApiProviderTemplate(
    id: 'ollama',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/ollama.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: 'Ollama (本地模型)',
    nameEn: 'Ollama (Local Models)',
    defaultConfigName: 'Ollama 本地',
    baseUrl: '',
    defaultModel: 'qwen2.5:3b-instruct-q4_K_M',
    group: ApiProviderGroup.local,
    hasFreeTier: true,
    freeDetailZh: '完全免费，本地运行，无需 API Key',
    freeDetailEn: '100% free, runs locally, no API Key',
    descZh:
        '模型实际跑在电脑上，手机只是客户端。⚠️ 手机端必须填电脑局域网 IP（如 http://192.168.1.100:11434/v1），不能用 localhost（localhost 在手机上指手机本身，连不到电脑的 Ollama）',
    descEn:
        'Models actually run on your PC; phone is just the client. ⚠️ On phone you MUST use PC LAN IP (e.g. http://192.168.1.100:11434/v1), NOT localhost (localhost on phone means the phone itself, cannot reach PC Ollama)',
    color: Colors.black87,
    icon: Icons.computer,
    models: [
      // —— 电脑轻量（低配电脑也能跑）——
      ModelOption(
          id: 'qwen2.5:0.5b-instruct-q4_0',
          nameZh: 'Qwen2.5-0.5B · 电脑轻量',
          nameEn: 'Qwen2.5-0.5B · PC Light',
          isFreeModel: true,
          noteZh: '~400MB，电脑低配流畅',
          noteEn: '~400MB, smooth on low-end PC'),
      ModelOption(
          id: 'qwen2.5:1.5b-instruct-q4_0',
          nameZh: 'Qwen2.5-1.5B · 电脑主力',
          nameEn: 'Qwen2.5-1.5B · PC Main',
          isFreeModel: true,
          recommended: true,
          noteZh: '~1GB，电脑对话主力',
          noteEn: '~1GB, main for PC chat'),
      ModelOption(
          id: 'minicpm3-v2_5:2b-instruct-q4_K_M',
          nameZh: 'MiniCPM3-2B · 中文强',
          nameEn: 'MiniCPM3-2B · Good Chinese',
          isFreeModel: true,
          noteZh: '中文能力强，~1.4GB',
          noteEn: 'Strong Chinese, ~1.4GB'),
      ModelOption(
          id: 'llama3.2:1b-instruct-q4_0',
          nameZh: 'Llama3.2-1B',
          nameEn: 'Llama3.2-1B',
          isFreeModel: true,
          noteZh: '~730MB',
          noteEn: '~730MB'),
      ModelOption(
          id: 'qwen2.5:3b-instruct-q4_K_M',
          nameZh: 'Qwen2.5-3B · 电脑进阶',
          nameEn: 'Qwen2.5-3B · PC Advanced',
          isFreeModel: true,
          noteZh: '~2GB，电脑进阶首选',
          noteEn: '~2GB, PC advanced pick'),
      ModelOption(
          id: 'llama3.2:3b-instruct-q4_0',
          nameZh: 'Llama3.2-3B',
          nameEn: 'Llama3.2-3B',
          isFreeModel: true,
          noteZh: '~1.8GB，电脑进阶',
          noteEn: '~1.8GB, PC advanced'),
      // —— 桌面级（需较好电脑配置，8GB+ VRAM / 大内存）——
      ModelOption(
          id: 'qwen2.5:7b-instruct-q4_K_M',
          nameZh: 'Qwen2.5-7B · 桌面级',
          nameEn: 'Qwen2.5-7B · Desktop',
          isFreeModel: true,
          noteZh: '桌面 / 高配电脑',
          noteEn: 'Desktop / high-end PC'),
      ModelOption(
          id: 'gemma3:4b-instruct-q4_K_M',
          nameZh: 'Gemma3-4B',
          nameEn: 'Gemma3-4B',
          isFreeModel: true),
      ModelOption(
          id: 'phi3:mini-4k-instruct',
          nameZh: 'Phi-3-Mini',
          nameEn: 'Phi-3-Mini',
          isFreeModel: true,
          noteZh: '~2.3GB',
          noteEn: '~2.3GB'),
    ],
  ),

  // ⑱ LM Studio（桌面端 GUI 本地模型）
  // v1.3.9：baseUrl 默认留空（同 Ollama），避免误用 localhost
  ApiProviderTemplate(
    id: 'lmstudio',
    iconUrl: 'https://registry.npmmirror.com/@lobehub/icons-static-png/latest/files/light/lmstudio.png',      // build99：厂商图标真实化（lobe-icons npmmirror，已 curl 验证 200 + 真实 PNG；VendorIconCache 下载缓存）
    nameZh: 'LM Studio (桌面本地)',
    nameEn: 'LM Studio (Desktop Local)',
    defaultConfigName: 'LM Studio 本地',
    baseUrl: '',
    defaultModel: 'local-model',
    group: ApiProviderGroup.local,
    hasFreeTier: true,
    freeDetailZh: '完全免费，桌面端使用，无需 API Key',
    freeDetailEn: '100% free for desktop; no API Key',
    descZh:
        '电脑端本地模型 GUI；推荐 GGUF 量化模型。⚠️ 手机端必须填电脑局域网 IP（如 http://192.168.1.100:1234/v1），不能用 localhost',
    descEn:
        'Desktop local model GUI; GGUF quantized recommended. ⚠️ On phone use PC LAN IP (e.g. http://192.168.1.100:1234/v1), NOT localhost',
    color: Colors.brown,
    icon: Icons.desktop_mac,
    models: [
      ModelOption(
          id: 'bartowski/Qwen2.5-14B-Instruct-GGUF/qwen2.5-14b-instruct.Q4_K_M.gguf',
          nameZh: 'Qwen2.5-14B · 桌面推荐',
          nameEn: 'Qwen2.5-14B · Desktop Rec',
          recommended: true,
          isFreeModel: true),
      ModelOption(
          id: 'lmstudio-community/Meta-Llama-3.1-8B-Instruct-GGUF/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf',
          nameZh: 'Llama3.1-8B',
          nameEn: 'Llama3.1-8B',
          isFreeModel: true),
    ],
  ),
];

/// v1.7.24 (#7)：API 模板目录 —— 内置默认 + 远程 JSON 更新。
///
/// 远程 JSON 格式（二选一）：
///   A. `{"templates": [ {ApiProviderTemplate.toJson()}, ... ]}`
///   B. 直接是一个模板数组 `[ {...}, ... ]`
///
/// 远程模板按 id 覆盖内置模板；全新 id 自动追加。
/// 这样「加新服务商」只需更新远程 JSON，无需发版。
class ApiProviderTemplateCatalog {
  ApiProviderTemplateCatalog._();

  static final ApiProviderTemplateCatalog instance =
      ApiProviderTemplateCatalog._();

  /// 远程模板（按 id 索引），初始为空。
  Map<String, ApiProviderTemplate> _remote = {};

  /// 测试钩子：清空远程模板与合并缓存。
  ///
  /// [ApiProviderTemplateCatalog] 是单例，[_remote] 是进程级状态；
  /// 单测之间必须能隔离，否则「远程没提供 color 就不该覆盖」这类用例
  /// 会被前一个用例留下的远程数据污染。
  @visibleForTesting
  void resetForTest() {
    clearRemotePayload();
    lastMessage = '';
    lastUpdatedAt = null;
  }

  /// build138（G54–G56）：丢弃已应用的远程模板，回落纯内置。
  /// 由 `DataPackService` 在「缓存被版本/校验闸门挡下」或「陈旧自愈」时调用。
  void clearRemotePayload() {
    _remote = {};
    _mergedCache = null;
  }

  /// 最近一次拉取/应用结果信息（供 UI 展示）。
  String lastMessage = '';

  DateTime? lastUpdatedAt;

  bool get hasRemote => _remote.isNotEmpty;

  /// 合并结果缓存（[_remote] 变化时置空）。
  List<ApiProviderTemplate>? _mergedCache;

  /// 生效模板列表：内置 + 远程（G46：字段级合并，只增不删）。
  ///
  /// build136 前这里是 `merged.addAll(_remote)`——**按厂商 id 整体替换**。
  /// 于是 fastly 节点一旦可达，仓库里停在 1.7.32 的旧 JSON（deepseek 只有
  /// chat/reasoner）会把内置的 V4-Flash/V4-Pro 整个抹掉（任务书第一节隐患 1）。
  List<ApiProviderTemplate> get all =>
      _mergedCache ??= mergeRemoteOntoBuiltin(
        ApiProviderTemplate.all,
        _remote.values.toList(),
      );

  /// G46（build136）：远程对内置只做**字段级合并**，绝不让远程把内置抹旧。
  ///
  /// 严格照任务书四.1：
  /// - **可覆盖**字段：`baseUrl` / `color` / `descZh` / `descEn` / `iconUrl`
  ///   （`icon` 同属展示位，一并按「显式提供才覆盖」处理）；
  /// - `models` 按 [ModelOption.id] **以内置为底**合并：同 id 覆盖（显示名/免费标/
  ///   note 跟随远程）、新 id 追加、**远程不得删除内置模型**；远程 models 缺失或
  ///   为空一律保留内置；
  /// - 其余字段（id/nameZh/nameEn/defaultConfigName/defaultModel/group/hasFreeTier/
  ///   freeDetail*）一律以内置为准 —— 远程改不动，防「远程 JSON 一改，用户看到的
  ///   厂商名/分组/免费口径就跟着变」；
  /// - 内置没有的 id → 作为**新厂商**整体追加（现有能力，保持并测）。
  ///
  /// ⚠️ color/icon 的兜底值陷阱：`fromJson` 对缺失值回落 `Colors.blue`/`Icons.cloud`，
  /// 而 SP 缓存写的是 `toJson()`（**所有字段都被实体化**）。所以「等于兜底值」一律
  /// 视为「远程没提供」，否则第二次启动读缓存时会把内置配色冲成蓝色。
  @visibleForTesting
  static List<ApiProviderTemplate> mergeRemoteOntoBuiltin(
    List<ApiProviderTemplate> builtin,
    List<ApiProviderTemplate> remote,
  ) {
    final pending = <String, ApiProviderTemplate>{
      for (final t in remote)
        if (t.id.isNotEmpty) t.id: t,
    };
    final out = <ApiProviderTemplate>[];
    for (final base in builtin) {
      final r = pending.remove(base.id);
      out.add(r == null ? base : _mergeOne(base, r));
    }
    // 内置没有的 id：远程新增厂商整体追加（只增不删）。
    out.addAll(pending.values);
    return out;
  }

  static ApiProviderTemplate _mergeOne(
    ApiProviderTemplate base,
    ApiProviderTemplate r,
  ) {
    return ApiProviderTemplate(
      id: base.id,
      nameZh: base.nameZh,
      nameEn: base.nameEn,
      defaultConfigName: base.defaultConfigName,
      baseUrl: r.baseUrl.isNotEmpty ? r.baseUrl : base.baseUrl,
      defaultModel: base.defaultModel,
      group: base.group,
      hasFreeTier: base.hasFreeTier,
      freeDetailZh: base.freeDetailZh,
      freeDetailEn: base.freeDetailEn,
      descZh: r.descZh.isNotEmpty ? r.descZh : base.descZh,
      descEn: r.descEn.isNotEmpty ? r.descEn : base.descEn,
      color: r.color == Colors.blue ? base.color : r.color,
      icon: r.icon == Icons.cloud ? base.icon : r.icon,
      iconUrl: r.iconUrl.isNotEmpty ? r.iconUrl : base.iconUrl,
      models: _mergeModels(base.models, r.models),
    );
  }

  /// models 以内置为底：同 id 覆盖、新 id 追加，**绝不删内置模型**。
  static List<ModelOption> _mergeModels(
    List<ModelOption> base,
    List<ModelOption> remote,
  ) {
    if (remote.isEmpty) return base;
    final pending = <String, ModelOption>{
      for (final m in remote)
        if (m.id.isNotEmpty) m.id: m,
    };
    final out = <ModelOption>[];
    for (final m in base) {
      out.add(pending.remove(m.id) ?? m);
    }
    out.addAll(pending.values);
    return out;
  }

  /// 按分组取模板（含远程）。
  List<ApiProviderTemplate> byGroup(ApiProviderGroup g) =>
      all.where((e) => e.group == g).toList();

  /// 从远程 URL 拉取 JSON 模板并合并。
  /// build138（G54）：网络与缓存编排已上移到 `DataPackService`（多源有序回退 +
  /// dataVersion/minAppVersion/sha256 闸门），这里只留「把已校验的 JSON 应用进内存」。
  /// 用原始 JSON 字符串更新（本地资产 / 测试复用）。
  bool applyJson(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      final list = _extractTemplates(decoded);
      if (list.isEmpty) return false;
      _remote = {for (final t in list) t.id: t};
      _mergedCache = null;
      lastUpdatedAt = DateTime.now();
      lastMessage = '已更新 ${list.length} 个模板';
      return true;
    } catch (e) {
      lastMessage = '解析失败: $e';
      return false;
    }
  }

  List<ApiProviderTemplate> _extractTemplates(Object? decoded) {
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map(
              (m) => ApiProviderTemplate.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    }
    if (decoded is Map && decoded['templates'] is List) {
      return (decoded['templates'] as List)
          .whereType<Map>()
          .map(
              (m) => ApiProviderTemplate.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    }
    return const [];
  }

  /// 序列化当前生效模板为 JSON（供导出 / 调试 / 数据仓库生成）。
  ///
  /// build136：`version` 原先**硬编码 `'1.7.32'`** —— 用它生成/导出的
  /// api_templates.json 会永远自称 1.7.32，正是任务书四.2 要根除的那个坑
  /// （仓库里那份停在 1.7.32、只有 deepseek chat/reasoner 的旧文件）。
  /// 改为跟随应用版本，并带上生成时间。
  String toJsonString() => jsonEncode({
        'version': kAppVersionConst,
        'generatedAt': DateTime.now().toIso8601String(),
        'count': all.length,
        'templates': all.map((t) => t.toJson()).toList(),
      });
}
