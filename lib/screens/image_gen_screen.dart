import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/api_config.dart';
import '../models/chat_message.dart';
import '../screens/api_config_screen.dart';
import '../services/attachment_service.dart';
import '../services/biometric_service.dart';
import '../services/image_gen_service.dart';
import '../services/logger_service.dart';
import '../services/storage_service.dart';
import '../utils/app_snackbar.dart';
import '../ui/image_decode.dart';

/// 图片生成页（UI + 接线，服务层见 [ImageGenService]）。
///
/// 关键点：
/// - 生成是**花钱操作**，按张数+质量计费，提交前必须弹成本确认（项目规矩）；
/// - 图片可能耗时 1~2 分钟，期间禁用按钮 + 进度指示，且用户可随时离开页面
///   （不实现硬取消，但所有 await 后查 mounted，离开不崩）；
/// - 结果用 `Image.file` 展示（与服务层落盘路径一致）；每张可保存/分享，
///   分享走 `BiometricService.guardActivityTransition` 包裹（防返回误弹生物锁）。
class ImageGenScreen extends StatefulWidget {
  const ImageGenScreen({super.key});

  @override
  State<ImageGenScreen> createState() => _ImageGenScreenState();
}

class _ImageGenScreenState extends State<ImageGenScreen> {
  // await 前抓到手，避免跨 async gap 再读 context（项目规矩）
  late final StorageService _storage;

  List<ApiConfig> _configs = [];
  ApiConfig? _selectedConfig;

  final _promptController = TextEditingController();
  String _size = '1024x1024';
  int _n = 1;
  String? _quality; // null = 不指定（传 null 给服务层）

  bool _busy = false;
  List<File> _results = [];
  List<String> _revisedPrompts = [];

  /// build129：图生图的参考图（null = 纯文生图）。存附件而非 base64——base64 可能
  /// 有好几 MB，没必要常驻内存，提交那一刻现转（[AttachmentService.imageToBase64]）。
  MessageAttachment? _refImage;

  /// build129：参考图原始字节上限。上游 images/edits 普遍限 10MB 上下，
  /// 本地取 8MB 先拦，避免「等到超时/400 才发现图太大」。
  static const int _maxRefImageBytes = 8 * 1024 * 1024;

  static final LoggerService _logger = LoggerService.instance;

  static const List<String> _sizes = [
    '1024x1024',
    '1024x1536',
    '1536x1024',
  ];

  @override
  void initState() {
    super.initState();
    // initState 内 context 已就绪，provider 查找安全（仅读不监听）
    _storage = context.read<StorageService>();
    _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    final list = await _storage.getApiConfigs();
    if (!mounted) return;
    setState(() {
      _configs = list;
      // 默认选中第一个配置；用户可下拉切换
      _selectedConfig = list.isNotEmpty ? list.first : null;
    });
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  /// 质量下拉的可读文案（中文/英文随 isZh 切换）。
  String _qualityLabel(bool isZh) {
    switch (_quality) {
      case null:
        return isZh ? '不指定' : 'Auto';
      case 'low':
        return isZh ? '低' : 'Low';
      case 'medium':
        return isZh ? '中' : 'Medium';
      case 'high':
        return isZh ? '高' : 'High';
      default:
        return _quality!;
    }
  }

  Future<void> _onGenerate() async {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final config = _selectedConfig;
    if (config == null) {
      _toast(isZh ? '请先选择一个 API 配置' : 'Select an API config first');
      return;
    }
    if (_promptController.text.trim().isEmpty) {
      _toast(isZh ? '提示词不能为空' : 'Prompt cannot be empty');
      return;
    }

    // 花钱操作：先弹成本确认（项目规矩——生成按额度计费，不能一声不响就发请求）
    final confirmed = await _confirmImageCost(isZh, config);
    if (!confirmed) return;

    if (!mounted) return;
    setState(() => _busy = true);
    try {
      // build129：有参考图则现转 base64 走 images/edits（图生图）。
      // 读取失败不静默降级为文生图——用户选了图却被忽略等于骗他。
      String? refB64;
      final refImg = _refImage;
      if (refImg != null) {
        refB64 = await AttachmentService().imageToBase64(refImg);
        if (refB64 == null || refB64.isEmpty) {
          if (mounted) {
            setState(() => _busy = false);
            _toast(isZh ? '参考图读取失败（文件可能已被清理），请重新选择' : 'Failed to read the reference image');
          }
          return;
        }
      }
      if (!mounted) return;
      final result = await ImageGenService.generate(
        config,
        prompt: _promptController.text.trim(),
        size: _size,
        n: _n,
        quality: _quality,
        inputImageBase64: refB64,
        inputImageName: refImg?.fileName,
      );
      // 用户在生成中途离开页面——不崩、不强刷 UI（图片已落盘，回来也能看到）
      if (!mounted) return;
      setState(() {
        _results = result.files;
        _revisedPrompts = result.revisedPrompts;
      });
    } on ImageGenException catch (e) {
      if (!mounted) return;
      // 面向用户只给 message；detail 仅进日志，绝不把原始响应体甩给用户
      _logger.warn('image gen failed: ${e.detail ?? e.message}', tag: 'ImageGen');
      _toast(e.message);
    } catch (e) {
      if (!mounted) return;
      _logger.error('image gen unexpected: $e', tag: 'ImageGen');
      _toast(isZh ? '生成失败：$e' : 'Generation failed: $e');
    } finally {
      // finally 里也要查 mounted，避免对已卸载 widget setState
      if (mounted) setState(() => _busy = false);
    }
  }

  /// build129：选一张参考图（图生图 → images/edits）。
  ///
  /// 本地先拦大小：edits 要传 base64（体积 ×1.33），超限时上游只回语焉不详的 400，
  /// 而这笔请求本身要等十几秒到两分钟——先拦住比事后报错便宜。
  Future<void> _pickRefImage() async {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final att = await AttachmentService().pickImageFromGallery();
    if (!mounted || att == null) return;
    var size = att.sizeBytes ?? 0;
    if (size == 0 && att.localPath != null) {
      try {
        size = await File(att.localPath!).length();
      } catch (_) {
        size = 0; // 读不到大小就不拦（交给上游判断），不因体检失败阻断主流程
      }
    }
    if (size > _maxRefImageBytes) {
      _toast(isZh
          ? '参考图太大（${(size / 1024 / 1024).toStringAsFixed(1)}MB > '
              '${_maxRefImageBytes ~/ (1024 * 1024)}MB），请先压缩再试'
          : 'Reference image too large (max ${_maxRefImageBytes ~/ (1024 * 1024)}MB)');
      return;
    }
    if (!mounted) return;
    setState(() => _refImage = att);
  }

  /// 成本确认弹窗：说明将消耗额度 + 参数摘要，取消/继续两枚按钮（对齐下载确认风格）。
  Future<bool> _confirmImageCost(bool isZh, ApiConfig config) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isZh ? '确认生成图片' : 'Confirm Image Generation'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(isZh
                  ? '将消耗你的 API 额度（每次生成按张数计费）。'
                  : 'This will consume your API quota (billed per image).'),
              const SizedBox(height: 12),
              // build125：显示**实际会用于生图**的模型（专用模型优先，留空回落对话模型）。
              // 此前显示 config.model → 用户看到「模型 grok-4.6」而实际就是它导致 400，
              // 界面上完全看不出「这个模型不是图像模型」。
              _kv(
                isZh ? '模型' : 'Model',
                config.hasDedicatedImageModel
                    ? config.effectiveImageModel
                    : '${config.effectiveImageModel}${isZh ? '（对话模型·可在 API 配置里指定文生图模型）' : ' (chat model)'}',
              ),
              _kv(isZh ? '尺寸' : 'Size', _size),
              _kv(isZh ? '张数' : 'Count', '$_n'),
              _kv(isZh ? '质量' : 'Quality', _qualityLabel(isZh)),
              // build129：图生图时写明「用了哪张参考图」+ 走的是 edits 端点
              if (_refImage != null)
                _kv(
                  isZh ? '参考图' : 'Ref image',
                  '${_refImage!.fileName}${isZh ? '（图生图 · images/edits）' : ' (image-to-image)'}',
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isZh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isZh ? '继续' : 'Continue'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 分享：系统分享面板会切走前台，走 guard 防返回时误弹生物锁（照 conversation_list_screen）。
  Future<void> _share(File file) async {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    try {
      await BiometricService.guardActivityTransition(
        () => Share.shareXFiles(
          [XFile(file.path)],
          subject: _promptController.text.trim(),
          text: _promptController.text.trim(),
        ),
        fallbackDuration: const Duration(seconds: 120),
      );
    } catch (e) {
      if (!mounted) return;
      _toast(isZh ? '分享失败：$e' : 'Share failed: $e');
    }
  }

  /// 保存：原生保存选择器同样会切走前台，走 guard 防误锁。
  Future<void> _save(File file) async {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    try {
      final path = await BiometricService.guardActivityTransition(
        () => FilePicker.platform.saveFile(
          fileName: file.path.split(Platform.pathSeparator).last,
          bytes: file.readAsBytesSync(),
        ),
        fallbackDuration: const Duration(seconds: 120),
      );
      if (!mounted) return;
      if (path == null) return; // 用户取消或无返回值（移动端系统已直接保存）
      _toast(isZh ? '已保存到：$path' : 'Saved to: $path');
    } catch (e) {
      if (!mounted) return;
      _toast(isZh ? '保存失败：$e' : 'Save failed: $e');
    }
  }

  /// 未开启能力位时的可操作提示：跳到 API 配置设置页（不硬拦，用户在设置里开）。
  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ApiConfigScreen()),
    );
    if (!mounted) return;
    // 用户可能在设置里改了能力位/配置，回来后重载
    _loadConfigs();
  }

  void _toast(String msg) {
    if (!mounted) return;
    AppSnackBar.showSnackBar(
      context,
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Widget _kv(String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label,
                style: TextStyle(
                    color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(value, style: TextStyle(color: cs.onSurface))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(isZh ? 'AI 绘图' : 'AI Image'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // API 配置选择
            Text(isZh ? 'API 配置' : 'API config',
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            DropdownButton<ApiConfig>(
              value: _selectedConfig,
              isExpanded: true,
              hint: Text(isZh ? '选择 API 配置' : 'Select API config'),
              items: _configs
                  .map((c) => DropdownMenuItem(
                        value: c,
                        child: Text('${c.name} · ${c.model}'),
                      ))
                  .toList(),
              onChanged: (c) => setState(() => _selectedConfig = c),
            ),

            // 能力位提示（不硬拦）
            if (_selectedConfig != null && !_selectedConfig!.supportImageGen)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: cs.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isZh
                              ? '当前配置未开启「图片生成」能力位。若确定该端点支持，可前往设置手动开启；不拦截你继续尝试。'
                              : 'This config has not enabled the image-gen capability. '
                                  'If you know the endpoint supports it, enable it in Settings; we won\'t block you.',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ),
                      TextButton(
                        onPressed: _openSettings,
                        child: Text(isZh ? '去设置' : 'Settings'),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 16),
            Text(isZh ? '提示词' : 'Prompt',
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            TextField(
              controller: _promptController,
              maxLines: 4,
              minLines: 2,
              decoration: InputDecoration(
                hintText: isZh ? '描述你想生成的画面…' : 'Describe the image…',
                border: const OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 16),
            // build129：图生图（参考图）。选了图 → 走 images/edits；不选 → 纯文生图。
            Row(
              children: [
                Icon(Icons.add_photo_alternate_outlined,
                    size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  isZh ? '参考图（可选，图生图）' : 'Reference image (optional)',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (_refImage == null)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _pickRefImage,
                  icon: const Icon(Icons.photo_library_outlined, size: 18),
                  label: Text(isZh ? '选择图片' : 'Pick image'),
                ),
              )
            else
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(
                      File(_refImage!.localPath!),
                      width: 56,
                      height: 56,
                      // build138（扫描 P2-4）：参考图缩略图限宽解码
                      cacheWidth: decodeCacheWidth(context, 56),
                      fit: BoxFit.cover,
                      // 文件被系统清理时不崩，退回占位图标
                      errorBuilder: (_, __, ___) => Container(
                        width: 56,
                        height: 56,
                        color: cs.surfaceContainerHighest,
                        child: Icon(Icons.broken_image_outlined,
                            size: 20, color: cs.onSurfaceVariant),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _refImage!.fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  IconButton(
                    tooltip: isZh ? '移除参考图' : 'Remove',
                    onPressed:
                        _busy ? null : () => setState(() => _refImage = null),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),

            const SizedBox(height: 16),
            Text(isZh ? '尺寸' : 'Size',
                style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 6),
            DropdownButton<String>(
              value: _size,
              isExpanded: true,
              items: _sizes
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _size = v);
              },
            ),

            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(isZh ? '张数 (1~4)' : 'Count (1~4)',
                          style: Theme.of(context).textTheme.labelMedium),
                      const SizedBox(height: 6),
                      DropdownButton<int>(
                        value: _n,
                        isExpanded: true,
                        items: List.generate(
                          4,
                          (i) => DropdownMenuItem(
                            value: i + 1,
                            child: Text('${i + 1}'),
                          ),
                        ),
                        onChanged: (v) {
                          if (v != null) setState(() => _n = v);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(isZh ? '质量' : 'Quality',
                          style: Theme.of(context).textTheme.labelMedium),
                      const SizedBox(height: 6),
                      DropdownButton<String?>(
                        value: _quality,
                        isExpanded: true,
                        items: <MapEntry<String?, String>>[
                          MapEntry(null, _qualityLabel(isZh)),
                          const MapEntry('low', 'low'),
                          const MapEntry('medium', 'medium'),
                          const MapEntry('high', 'high'),
                        ]
                            .map((e) => DropdownMenuItem(
                                  value: e.key,
                                  child: Text(e.value),
                                ))
                            .toList(),
                        onChanged: (v) => setState(() => _quality = v),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                // 生成中禁用按钮（避免重复提交）
                onPressed: _busy ? null : _onGenerate,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(_busy
                    ? (isZh ? '生成中…（可能需 1~2 分钟）' : 'Generating… (may take 1–2 min)')
                    : (isZh ? '生成' : 'Generate')),
              ),
            ),

            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),

            if (_results.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(isZh ? '生成结果' : 'Results',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 200,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1,
                ),
                itemCount: _results.length,
                itemBuilder: (ctx, i) {
                  final file = _results[i];
                  final revised = i < _revisedPrompts.length
                      ? _revisedPrompts[i]
                      : '';
                  // build140（反馈①同源）：栅格项也是懒加载——itemBuilder 的 context 是
                  // SliverList 的**共享元素**，主题切换后已画出来的格子不重建，`cs` 必须在
                  // 每项自己的元素上读，否则改配色后缩略图下方的文字/图标颜色不刷新。
                  return Builder(builder: (context) {
                  final cs = Theme.of(context).colorScheme;
                  return Column(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(
                            file,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (revised.isNotEmpty)
                        Text(
                          revised,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: isZh ? '保存' : 'Save',
                            icon: Icon(Icons.save_alt, color: cs.primary),
                            onPressed: () => _save(file),
                          ),
                          IconButton(
                            tooltip: isZh ? '分享' : 'Share',
                            icon: Icon(Icons.share, color: cs.primary),
                            onPressed: () => _share(file),
                          ),
                        ],
                      ),
                    ],
                  );
                  });
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
