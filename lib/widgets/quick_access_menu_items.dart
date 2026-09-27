import 'package:flutter/material.dart';
import '../screens/about_screen.dart';
import '../screens/api_config_screen.dart';
import '../screens/conversation_list_screen.dart';
import '../screens/file_management_screen.dart';
import '../screens/image_gen_screen.dart';
import '../screens/plugin_market_screen.dart';
import '../screens/quick_self_check_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/video_gen_screen.dart';
import '../screens/web_search_settings_screen.dart';

class QuickAccessMenuItem {
  final IconData icon;
  final String zhLabel;
  final String enLabel;
  final WidgetBuilder targetBuilder;

  const QuickAccessMenuItem({
    required this.icon,
    required this.zhLabel,
    required this.enLabel,
    required this.targetBuilder,
  });
}

/// 快速菜单（左滑抽屉）条目 —— **唯一数据源，顺序即展示顺序**。
///
/// build130：按**重要性**重排（用户拍板），并把原先硬编码在
/// `quick_access_drawer.dart` 里的「AI 绘图 / AI 视频」两个 ListTile 收进本列表
/// （它们是同一形状的条目，硬编码导致生成入口永远只能排在末尾，且改顺序要动两处）。
///
/// 排布依据（越靠前越重要/越高频）：
///   ① 产出能力：AI 绘图 / AI 视频 —— 日常最主要的"用一下"动作；
///   ② 总入口与核心开关：设置 / 联网搜索；
///   ③ 配置与扩展：API 配置 / 插件市场；
///   ④ 排障与数据：快速自检 / 文件管理 / 归档会话；
///   ⑤ 关于。
/// 调整顺序只需移动本列表中的条目位置，无需改任何 UI 代码。
final List<QuickAccessMenuItem> kQuickAccessMenuItems = <QuickAccessMenuItem>[
  // ① 产出能力
  QuickAccessMenuItem(
    icon: Icons.auto_awesome,
    zhLabel: 'AI 绘图',
    enLabel: 'AI Image',
    targetBuilder: (_) => const ImageGenScreen(),
  ),
  QuickAccessMenuItem(
    icon: Icons.movie_creation_outlined,
    zhLabel: 'AI 视频',
    enLabel: 'AI Video',
    targetBuilder: (_) => const VideoGenScreen(),
  ),
  // ② 总入口与核心开关
  QuickAccessMenuItem(
    icon: Icons.settings_outlined,
    zhLabel: '设置',
    enLabel: 'Settings',
    targetBuilder: (_) => const SettingsScreen(),
  ),
  QuickAccessMenuItem(
    icon: Icons.travel_explore,
    zhLabel: '联网搜索',
    enLabel: 'Web Search',
    targetBuilder: (_) => const WebSearchSettingsScreen(),
  ),
  // ③ 配置与扩展
  QuickAccessMenuItem(
    icon: Icons.cloud_outlined,
    zhLabel: 'API 配置',
    enLabel: 'API Config',
    targetBuilder: (_) => const ApiConfigScreen(),
  ),
  QuickAccessMenuItem(
    icon: Icons.extension_outlined,
    zhLabel: '插件市场',
    enLabel: 'Plugin Market',
    targetBuilder: (_) => const PluginMarketScreen(),
  ),
  // ④ 排障与数据
  QuickAccessMenuItem(
    icon: Icons.verified_user_outlined,
    zhLabel: '快速自检',
    enLabel: 'Quick Self-Check',
    targetBuilder: (_) => const QuickSelfCheckScreen(),
  ),
  // build102（D）：文件管理（日志导出/备份/下载文件 浏览·打开·分享·删除）
  QuickAccessMenuItem(
    icon: Icons.folder_open,
    zhLabel: '文件管理',
    enLabel: 'File management',
    targetBuilder: (_) => const FileManagementScreen(),
  ),
  // build102（C）：归档入口从主页 AppBar 挪进抽屉（用户拍板）
  QuickAccessMenuItem(
    icon: Icons.archive_outlined,
    zhLabel: '归档会话',
    enLabel: 'Archived chats',
    targetBuilder: (_) => const ConversationListScreen(showArchivedOnly: true),
  ),
  // ⑤ 关于
  QuickAccessMenuItem(
    icon: Icons.info_outline,
    zhLabel: '关于',
    enLabel: 'About',
    targetBuilder: (_) => const AboutScreen(),
  ),
];
