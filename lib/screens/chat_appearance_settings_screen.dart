import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../providers/chat_skin_provider.dart';
import '../services/logger_service.dart';
import '../ui/tokens.dart';
import '../services/biometric_service.dart';
import '../utils/app_snackbar.dart';

/// 聊天外观设置
///
/// v1.7.38：V2 朴素风常驻，皮肤开关已移除；保留输入框功能按钮显隐 + 顺序。
/// build101（D1~D5）：新增三大块 ——
///   ① 头像与背景（用户头像 / AI 头像 / 聊天背景图，全部可清除）
///   ② 显示开关族（头像 / 气泡 / 左对齐 / 时间戳 / 模型名 / token / 字数 /
///      首字耗时 / 隐藏系统提示词 / 自动滚顶 / 自动标题 / 长文转附件 / 注入元数据）
///   ③ 主题模式（跟随系统 / 浅色 / 深色）
///
/// 设计口径：**全部默认关**——朴素风是默认态，这些是可选装饰层。
class ChatAppearanceSettingsScreen extends StatelessWidget {
  const ChatAppearanceSettingsScreen({super.key});

  static const _buttonMeta = <String, (IconData, String, String)>{
    'model': (Icons.smart_toy_outlined, '模型选择', 'Model switcher'),
    'search': (Icons.travel_explore, '联网搜索', 'Web search'),
    'react': (Icons.psychology_alt_outlined, '思考强度', 'Reasoning'),
    'plugin': (Icons.extension_outlined, '插件提示', 'Plugin hints'),
  };

  /// 显示开关族的元数据：(key, 图标, 中文, English, 说明中, 说明En)
  static const _flagMeta =
      <(String, IconData, String, String, String, String)>[
    (
      'showAvatar',
      Icons.account_circle_outlined,
      '显示头像',
      'Show avatars',
      '在气泡旁显示用户/AI 头像（需先在上方设置头像）',
      'Show user/AI avatars beside bubbles'
    ),
    (
      'showBubble',
      Icons.chat_bubble_outline,
      'AI 消息气泡',
      'AI message bubble',
      '给 AI 回复加气泡底色（默认关 = 通栏无底色）',
      'Add bubble background to AI replies'
    ),
    (
      'leftAlign',
      Icons.format_align_left,
      '双向左对齐',
      'Left-align both sides',
      '用户消息也靠左（默认 = 用户右 / AI 左）',
      'User messages also align left'
    ),
    (
      'showTimestamp',
      Icons.schedule,
      '显示时间戳',
      'Show timestamps',
      '每条消息下方显示精确时间',
      'Show exact time under each message'
    ),
    (
      'showModelName',
      Icons.smart_toy_outlined,
      '显示模型名',
      'Show model name',
      '消息底部显示生成该条的模型',
      'Show the model that produced each reply'
    ),
    (
      'showTokenUsage',
      Icons.data_usage,
      '显示 token 消耗',
      'Show token usage',
      '消息底部显示 prompt/completion token',
      'Show prompt/completion tokens'
    ),
    (
      'showCharCount',
      Icons.abc,
      '显示字数统计',
      'Show character count',
      '消息底部显示字符数',
      'Show character count'
    ),
    (
      'showFirstTokenLatency',
      Icons.speed,
      '显示首字耗时',
      'Show first-token latency',
      '显示从发送到收到第一个字的时间',
      'Time from send to first token'
    ),
    (
      'hideSystemPrompt',
      Icons.visibility_off_outlined,
      '隐藏系统提示词',
      'Hide system prompt',
      '对话流中不渲染系统消息',
      'Hide system messages in the chat stream'
    ),
    (
      'autoScrollTop',
      Icons.vertical_align_top,
      '新消息滚到顶部',
      'New messages scroll to top',
      '新消息出现时滚到该条顶部（默认 = 滚到底部）',
      'Scroll new messages to their top'
    ),
    (
      'autoTitle',
      Icons.title,
      '自动生成对话标题',
      'Auto-generate chat title',
      '首轮问答后自动用 AI 生成标题',
      'Auto-title the chat after the first exchange'
    ),
    (
      'pasteAsFile',
      Icons.content_paste,
      '长文本粘贴为文件',
      'Paste long text as file',
      '粘贴超长文本时自动转成附件',
      'Convert very long pasted text into an attachment'
    ),
    (
      'injectMetadata',
      Icons.info_outline,
      '注入默认元数据',
      'Inject default metadata',
      '每轮注入当前日期等信息（放在 messages 末尾，不破缓存）',
      'Inject current date etc. at the end of messages'
    ),
  ];

  /// 从相册/文件选取图片并复制到应用文档目录（返回新路径，null = 取消/失败）
  ///
  /// 复制的原因：image_picker 返回的是缓存路径，系统可能随时清理；
  /// 存到应用私有目录才能长期有效，并被备份链路带走。
  static Future<String?> _pickAndPersistImage(
      BuildContext context, bool fromCamera) async {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    try {
      // B-003：选头像/背景/拍照同样拉起原生 Activity，必须走 guard——
      // 此前这里完全没设标志，从相册/相机返回时会被误判为「后台返回」而误弹生物锁。
      final String? srcPath =
          await BiometricService.guardActivityTransition<String?>(() async {
        if (fromCamera) {
          final picked = await ImagePicker()
              .pickImage(source: ImageSource.camera, maxWidth: 1024);
          return picked?.path;
        }
        final result = await FilePicker.platform.pickFiles(
          type: FileType.image,
        );
        return result?.files.single.path;
      });
      if (srcPath == null) return null;
      final src = File(srcPath);
      if (!await src.exists()) return null;
      if (await src.length() > 5 * 1024 * 1024) {
        if (context.mounted) {
          AppSnackBar.showSnackBar(context, SnackBar(
            content: Text(isZh ? '图片超过 5MB，请换小一点的' : 'Image exceeds 5MB'),
          ));
        }
        return null;
      }
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}appearance');
      if (!await dir.exists()) await dir.create(recursive: true);
      final ext = srcPath.contains('.') ? srcPath.split('.').last : 'png';
      final dst = File('${dir.path}${Platform.pathSeparator}'
          'img_${DateTime.now().millisecondsSinceEpoch}.$ext');
      await src.copy(dst.path);
      return dst.path;
    } catch (e) {
      LoggerService.instance.warn('选取外观图片失败：$e', tag: 'Appearance');
      if (context.mounted) {
        AppSnackBar.showSnackBar(context, SnackBar(
          content: Text(isZh ? '选取图片失败：$e' : 'Failed to pick image'),
        ));
      }
      return null;
    }
  }

  /// 弹来源选择（相册 / 拍照）
  static Future<String?> _chooseImage(
      BuildContext context, String title) async {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final fromCamera = await showModalBottomSheet<bool>(
      context: context,
      builder: (bctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(title, style: Theme.of(bctx).textTheme.titleSmall),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(isZh ? '从相册选择' : 'Choose from gallery'),
              onTap: () => Navigator.pop(bctx, false),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(isZh ? '拍照' : 'Take a photo'),
              onTap: () => Navigator.pop(bctx, true),
            ),
          ],
        ),
      ),
    );
    if (fromCamera == null || !context.mounted) return null;
    return _pickAndPersistImage(context, fromCamera);
  }

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final skin = context.watch<ChatSkinProvider>();
    final order = skin.fullOrder;
    return Scaffold(
      appBar: AppBar(title: Text(zh ? '聊天外观' : 'Chat Appearance')),
      body: ListView(
        padding: AppPad.page,
        children: [
          // ============ ① 头像与背景 ============
          AppSectionCard(
            title: zh ? '头像与背景' : 'Avatars & background',
            children: [
              _avatarTile(
                context: context,
                zh: zh,
                label: zh ? '我的头像' : 'My avatar',
                path: skin.userAvatarPath,
                onPick: () async {
                  final p = await _chooseImage(
                      context, zh ? '选择我的头像' : 'Choose my avatar');
                  if (p != null && context.mounted) {
                    await context
                        .read<ChatSkinProvider>()
                        .setAvatar(isUser: true, path: p);
                  }
                },
                onClear: () => context
                    .read<ChatSkinProvider>()
                    .setAvatar(isUser: true, path: ''),
              ),
              _avatarTile(
                context: context,
                zh: zh,
                label: zh ? 'AI 头像' : 'AI avatar',
                path: skin.aiAvatarPath,
                onPick: () async {
                  final p = await _chooseImage(
                      context, zh ? '选择 AI 头像' : 'Choose AI avatar');
                  if (p != null && context.mounted) {
                    await context
                        .read<ChatSkinProvider>()
                        .setAvatar(isUser: false, path: p);
                  }
                },
                onClear: () => context
                    .read<ChatSkinProvider>()
                    .setAvatar(isUser: false, path: ''),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading:
                    _thumb(context, skin.backgroundPath, Icons.wallpaper),
                title: Text(zh ? '聊天背景图' : 'Chat background'),
                subtitle: Text(
                  skin.backgroundPath.isEmpty
                      ? (zh ? '未设置' : 'Not set')
                      : (zh ? '已设置（点击可更换）' : 'Set'),
                ),
                trailing: skin.backgroundPath.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: zh ? '清除' : 'Clear',
                        onPressed: () => context
                            .read<ChatSkinProvider>()
                            .setBackground(''),
                      ),
                onTap: () async {
                  final p = await _chooseImage(
                      context, zh ? '选择聊天背景' : 'Choose chat background');
                  if (p != null && context.mounted) {
                    await context.read<ChatSkinProvider>().setBackground(p);
                  }
                },
              ),
              if (skin.backgroundPath.isEmpty &&
                  skin.userAvatarPath.isEmpty &&
                  skin.aiAvatarPath.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    zh
                        ? '提示：头像与背景图均为可选装饰，默认不显示，不影响朴素风布局'
                        : 'Optional decoration only — hidden by default',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
            ],
          ),

          // ============ ② 显示开关族 ============
          AppSectionCard(
            title: zh ? '显示开关' : 'Display toggles',
            children: [
              for (final (key, icon, zhLabel, enLabel, zhDesc, enDesc)
                  in _flagMeta)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: Icon(icon),
                  title: Text(zh ? zhLabel : enLabel),
                  subtitle: Text(
                    zh ? zhDesc : enDesc,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  value: skin.flagOf(key),
                  onChanged: (v) =>
                      context.read<ChatSkinProvider>().setFlag(key, v),
                ),
            ],
          ),

          // ============ ③ 主题模式 ============
          AppSectionCard(
            title: zh ? '主题模式' : 'Theme mode',
            children: [
              // build101：用 RadioGroup（Flutter 3.32+ 新 API，
              // RadioListTile.groupValue/onChanged 已弃用）
              RadioGroup<String>(
                groupValue: skin.themeMode,
                onChanged: (v) => context
                    .read<ChatSkinProvider>()
                    .setThemeMode(v ?? 'system'),
                child: Column(
                  children: [
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: 'system',
                      title: Text(zh ? '跟随系统' : 'Follow system'),
                    ),
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: 'light',
                      title: Text(zh ? '浅色' : 'Light'),
                    ),
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: 'dark',
                      title: Text(zh ? '深色' : 'Dark'),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // ============ ④ 输入框功能按钮 ============
          AppSectionCard(
            title: zh
                ? '输入框功能按钮（勾选显示，拖动排序）'
                : 'Input bar buttons (toggle & reorder)',
            children: [
              ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: true,
                onReorderItem: skin.reorderItem,
                children: [
                  for (final id in order)
                    CheckboxListTile(
                      key: ValueKey(id),
                      secondary: Icon(_buttonMeta[id]!.$1),
                      title:
                          Text(zh ? _buttonMeta[id]!.$2 : _buttonMeta[id]!.$3),
                      value: !skin.isHidden(id),
                      onChanged: (v) => skin.setButtonHidden(id, !(v ?? true)),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 头像行（带缩略图预览 + 清除按钮）
  Widget _avatarTile({
    required BuildContext context,
    required bool zh,
    required String label,
    required String path,
    required VoidCallback onPick,
    required VoidCallback onClear,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _thumb(context, path, Icons.person_outline),
      title: Text(label),
      subtitle: Text(
        path.isEmpty ? (zh ? '未设置' : 'Not set') : (zh ? '已设置' : 'Set'),
      ),
      trailing: path.isEmpty
          ? null
          : IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: zh ? '清除' : 'Clear',
              onPressed: onClear,
            ),
      onTap: onPick,
    );
  }

  /// 缩略图（无图时显示占位图标；文件不存在则回退占位）
  Widget _thumb(BuildContext context, String path, IconData fallback) {
    final cs = Theme.of(context).colorScheme;
    if (path.isEmpty || !File(path).existsSync()) {
      return CircleAvatar(
        backgroundColor: cs.surfaceContainerHighest,
        child: Icon(fallback, size: 20, color: cs.onSurfaceVariant),
      );
    }
    final f = File(path);
    return CircleAvatar(
      backgroundImage: FileImage(f),
      onBackgroundImageError: (_, __) {},
    );
  }
}
