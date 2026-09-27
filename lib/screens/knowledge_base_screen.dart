import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_localizations.dart';
import '../models/api_config.dart';
import '../models/knowledge_base.dart';
import '../services/attachment_service.dart';
import '../services/rag_service.dart';
import '../services/storage_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/kb_retrieval_settings.dart';

/// build101（C1 知识库 RAG）：知识库管理页。
///
/// 两层结构：
/// - 列表页（[KnowledgeBaseListScreen]）：全部知识库 + 新建入口
/// - 详情页（[KnowledgeBaseDetailScreen]）：文档导入 / 切片查看 / 参数调整
///
/// RAG 的 embedding 与检索都在 [RagService]；本页只负责交互与落库。
class KnowledgeBaseListScreen extends StatefulWidget {
  const KnowledgeBaseListScreen({super.key});

  @override
  State<KnowledgeBaseListScreen> createState() =>
      _KnowledgeBaseListScreenState();
}

class _KnowledgeBaseListScreenState extends State<KnowledgeBaseListScreen> {
  List<KnowledgeBase> _list = const [];
  Map<String, int> _counts = {};
  bool _loading = true;

  /// build140（P0 缺口⑤）：检索阈值（余弦相似度下限）——**全局**旋钮。
  ///
  /// 为什么放在列表页而不是详情页：这条参数决定"AI 回答时到底注不注入资料"，
  /// 失败模式是全局的（换过 embedding 模型、库变大 ⇒ 全体检不到），
  /// 而详情页那个 `Icons.tune` 管的是**每个库**的切片长度/召回条数。
  /// 两个入口的图标故意不同（这里 `filter_alt_outlined`，详情 `tune`），免得混。
  ///
  /// 落 SharedPreferences 而不是 `knowledge_bases` 新列：新列要动 DB 迁移五重保险
  /// + 四同步，理由详见 `lib/utils/kb_retrieval_settings.dart` 头注。
  double _minScore = KbRetrievalSettings.kDefault;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = context.read<StorageService>();
    final list = await storage.listKnowledgeBases();
    final counts = <String, int>{};
    for (final kb in list) {
      counts[kb.id] = await storage.countChunks(kb.id);
    }
    // 偏好读取失败不得让整页空掉：阈值只影响"这一格显示什么"，
    // 检索链路自己也有回落（见 chat_screen_message.dart 的 _buildKnowledgeContext）。
    var minScore = KbRetrievalSettings.kDefault;
    try {
      minScore =
          await KbRetrievalSettings.load(await SharedPreferences.getInstance());
    } catch (_) {
      // 保持默认
    }
    if (!mounted) return;
    setState(() {
      _list = list;
      _counts = counts;
      _minScore = minScore;
      _loading = false;
    });
  }

  /// 调阈值。滑杆 + 一句人话说明档位含义 —— 阈值是纯数字，不解释没人调得动，
  /// 而这个功能的全部意义就是"检不到资料时用户知道该往哪边拧"。
  Future<void> _editMinScore() async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.showSnackBar(
        context,
        SnackBar(
          content: Text(zh
              ? '读取本地偏好失败，无法调整阈值'
              : 'Could not read local preferences; threshold not editable'),
        ),
      );
      return;
    }
    if (!mounted) return;
    var v = _minScore;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          // 取值在**弹层自己的 context** 上做（反馈①那条教训的同一原则：
          // 别把外层的主题值捕进来，弹层期间切主题就会显示陈旧配色）。
          final tt = Theme.of(ctx).textTheme;
          return AlertDialog(
          title: Text(zh ? '知识库检索阈值' : 'Retrieval threshold'),
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(zh ? '当前' : 'Current', style: tt.bodySmall),
                    Text(v.toStringAsFixed(2), style: tt.titleMedium),
                  ],
                ),
                Slider(
                  value: v,
                  min: KbRetrievalSettings.min,
                  max: KbRetrievalSettings.max,
                  // 0.02→0.60 步长 0.01 = 58 格；滑杆给的值仍会再过一次
                  // clampScore（唯一夹紧实现），不靠这里的 divisions 保证越界安全。
                  divisions: 58,
                  label: v.toStringAsFixed(2),
                  onChanged: (nv) => setDlg(() => v = nv),
                ),
                Text(
                  KbRetrievalSettings.describe(v, zh: zh),
                  style: tt.bodySmall,
                ),
                const SizedBox(height: 12),
                Text(
                  zh
                      ? '对所有知识库生效。太低会注入不相干的资料（白烧 token），'
                          '太高容易一条都检不到 —— AI 说"没有相关资料"时先来这里调低。'
                      : 'Applies to every knowledge base. Too low injects irrelevant '
                          'material (wasted tokens); too high retrieves nothing — '
                          'lower it here first when the AI says it found no material.',
                  style: tt.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  setDlg(() => v = KbRetrievalSettings.kDefault),
              child: Text(zh ? '恢复默认' : 'Reset'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(zh ? '取消' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(zh ? '保存' : 'Save'),
            ),
            ],
          );
        },
      ),
    );
    // 取消也要说清楚：滑杆是即时的，用户可能以为拖完就生效了。
    if (saved != true || !mounted) return;
    final clamped = KbRetrievalSettings.clampScore(v);
    await KbRetrievalSettings.save(prefs, clamped);
    if (!mounted) return;
    setState(() => _minScore = clamped);
    AppSnackBar.showSnackBar(
      context,
      SnackBar(
        content: Text(zh
            ? '检索阈值已设为 ${clamped.toStringAsFixed(2)}，下一轮回答生效'
            : 'Retrieval threshold set to ${clamped.toStringAsFixed(2)}; '
                'applies from the next answer'),
      ),
    );
  }

  Future<void> _create() async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '新建知识库' : 'New knowledge base'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: zh ? '名称' : 'Name',
                hintText: zh ? '例如：产品手册' : 'e.g. Product docs',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descCtrl,
              decoration: InputDecoration(
                labelText: zh ? '描述（可选）' : 'Description (optional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(zh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(zh ? '创建' : 'Create'),
          ),
        ],
      ),
    );
    // B-009：快照后无条件释放（取消 / 空值 / 保存）
    final name = nameCtrl.text.trim();
    final desc = descCtrl.text.trim();
    nameCtrl.dispose();
    descCtrl.dispose();
    if (ok != true) return;
    if (name.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final kb = KnowledgeBase(
      id: const Uuid().v4(),
      name: name,
      description: desc,
      createdAt: now,
      updatedAt: now,
    );
    if (!mounted) return;
    await context.read<StorageService>().upsertKnowledgeBase(kb);
    await _load();
  }

  Future<void> _open(KnowledgeBase kb) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => KnowledgeBaseDetailScreen(kbId: kb.id),
      ),
    );
    await _load();
  }

  Future<void> _delete(KnowledgeBase kb) async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '删除知识库' : 'Delete knowledge base'),
        content: Text(zh
            ? '将删除「${kb.name}」及其全部 ${_counts[kb.id] ?? 0} 条切片，不可恢复。'
            : 'This will delete "${kb.name}" and all its ${_counts[kb.id] ?? 0} '
                'chunks. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(zh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(zh ? '删除' : 'Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<StorageService>().deleteKnowledgeBase(kb.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    return Scaffold(
      appBar: AppBar(
        title: Text(zh ? '知识库' : 'Knowledge Base'),
        actions: [
          // build140（P0 缺口⑤）：检索阈值入口。tooltip 带上当前值——
          // 这个参数的意义就是"检不到时用户知道往哪拧"，藏起来等于没做。
          IconButton(
            icon: const Icon(Icons.filter_alt_outlined),
            tooltip: zh
                ? '检索阈值 ${_minScore.toStringAsFixed(2)}'
                : 'Retrieval threshold ${_minScore.toStringAsFixed(2)}',
            onPressed: _editMinScore,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: Text(zh ? '新建' : 'New'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _list.isEmpty
              ? _empty(zh)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                  itemCount: _list.length,
                  itemBuilder: (context, i) {
                    final kb = _list[i];
                    final n = _counts[kb.id] ?? 0;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.library_books_outlined),
                        ),
                        title: Text(kb.name.isEmpty
                            ? (zh ? '未命名' : 'Untitled')
                            : kb.name),
                        subtitle: Text(
                          [
                            if (kb.description.isNotEmpty) kb.description,
                            zh ? '$n 条切片' : '$n chunks',
                            if (kb.embeddingModel.isNotEmpty)
                              kb.embeddingModel,
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: zh ? '删除' : 'Delete',
                          onPressed: () => _delete(kb),
                        ),
                        onTap: () => _open(kb),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _empty(bool zh) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_books_outlined,
                size: 56,
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text(
              zh ? '还没有知识库' : 'No knowledge base yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              zh
                  ? '导入 PDF / Word / Excel / 文本资料，'
                      'AI 回答时会自动检索引用。'
                  : 'Import PDF / Word / Excel / text files. '
                      'They will be retrieved automatically when answering.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================================================

/// build101（C1）：知识库详情页——文档导入 / 切片管理 / 检索参数。
class KnowledgeBaseDetailScreen extends StatefulWidget {
  final String kbId;

  const KnowledgeBaseDetailScreen({super.key, required this.kbId});

  @override
  State<KnowledgeBaseDetailScreen> createState() =>
      _KnowledgeBaseDetailScreenState();
}

class _KnowledgeBaseDetailScreenState
    extends State<KnowledgeBaseDetailScreen> {
  final AttachmentService _attachmentService = AttachmentService();
  KnowledgeBase? _kb;
  List<({String docName, int count})> _docs = const [];
  bool _loading = true;
  bool _ingesting = false;

  /// 导入进度文案（如「正在向量化 3/12」）
  String _progress = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final storage = context.read<StorageService>();
    final kb = await storage.getKnowledgeBase(widget.kbId);
    final docs = await storage.listDocs(widget.kbId);
    if (!mounted) return;
    setState(() {
      _kb = kb;
      _docs = docs;
      _loading = false;
    });
  }

  /// 解析当前使用的 embedding 配置：优先知识库指定，否则用第一个 API 配置。
  Future<({ApiConfig config, String model})?> _resolveEmbeddingConfig() async {
    // B-014：用局部非空变量替代 `_kb!`，避免加载窗口期内被调用时崩溃
    final kb = _kb;
    if (kb == null) return null;
    final storage = context.read<StorageService>();
    final configs = await storage.getApiConfigs();
    if (configs.isEmpty) return null;
    ApiConfig? cfg;
    if (kb.embeddingConfigId.isNotEmpty) {
      cfg = configs.where((c) => c.id == kb.embeddingConfigId).firstOrNull;
    }
    cfg ??= configs.first;
    final model = kb.embeddingModel.trim();
    if (model.isEmpty) return null;
    return (config: cfg, model: model);
  }

  Future<void> _import() async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final resolved = await _resolveEmbeddingConfig();
    if (!mounted) return;
    if (resolved == null) {
      _snack(zh
          ? '请先在「Embedding 设置」里选择接口并填写 embedding 模型名'
          : 'Set an embedding endpoint and model in Embedding settings first');
      return;
    }
    final atts =
        await _attachmentService.pickDocumentsForKnowledge();
    if (!mounted || atts.isEmpty) return;

    setState(() {
      _ingesting = true;
      _progress = '';
    });
    final storage = context.read<StorageService>();
    // 给 RagService 注入写入钩子（避免 service 层互相依赖）
    RagService.chunkWriter = (chunks) async {
      await storage.insertKnowledgeChunks(chunks);
      return chunks.length;
    };

    var okDocs = 0;
    var totalChunks = 0;
    for (var i = 0; i < atts.length; i++) {
      final att = atts[i];
      if (mounted) {
        setState(() => _progress = zh
            ? '正在向量化 ${i + 1}/${atts.length}：${att.name}'
            : 'Embedding ${i + 1}/${atts.length}: ${att.name}');
      }
      try {
        // 同名文档重导 → 先清旧切片，避免重复内容
        await storage.deleteChunksByDoc(_kb!.id, att.name);
        final n = await RagService.ingest(
          config: resolved.config,
          model: resolved.model,
          kb: _kb!,
          docName: att.name,
          rawText: att.text,
        );
        totalChunks += n;
        okDocs++;
      } catch (e) {
        if (mounted) {
          _snack(zh ? '「${att.name}」导入失败：$e' : 'Failed "${att.name}": $e');
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _ingesting = false;
      _progress = '';
    });
    await _load();
    if (mounted) {
      _snack(zh
          ? '导入完成：$okDocs 篇文档，$totalChunks 条切片'
          : 'Imported $okDocs docs, $totalChunks chunks');
    }
  }

  Future<void> _deleteDoc(String docName) async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '移除文档' : 'Remove document'),
        content: Text(zh
            ? '将删除「$docName」在知识库中的全部切片。'
            : 'All chunks of "$docName" will be removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(zh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(zh ? '移除' : 'Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context
        .read<StorageService>()
        .deleteChunksByDoc(widget.kbId, docName);
    await _load();
  }

  Future<void> _editSettings() async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final kb = _kb!;
    final storage = context.read<StorageService>();
    final configs = await storage.getApiConfigs();
    if (!mounted) return;

    final modelCtrl = TextEditingController(text: kb.embeddingModel);
    final sizeCtrl = TextEditingController(text: '${kb.chunkSize}');
    final overlapCtrl = TextEditingController(text: '${kb.chunkOverlap}');
    final topKCtrl = TextEditingController(text: '${kb.topK}');
    // 全量缺陷扫描 §3（P3）：弹层内控制器此前未释放（可被 GC 回收、非内存泄漏，
    // 但会被 leak tracker 标记，将来启用 LeakTesting 会直接红）。
    // 这 4 个控制器在弹层关闭后**仍要读 .text**（见下方 upsertKnowledgeBase），
    // 所以不能像其它弹层那样在 await 后立刻释放；用局部函数集中释放，
    // 同时覆盖「取消」的提前 return 与正常结束两条路径。
    void disposeCtrls() {
      modelCtrl.dispose();
      sizeCtrl.dispose();
      overlapCtrl.dispose();
      topKCtrl.dispose();
    }
    var cfgId = kb.embeddingConfigId;
    // build102（E）：全局可用开关
    var isPublic = kb.isPublic;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(zh ? 'Embedding 设置' : 'Embedding settings'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (configs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      zh
                          ? '尚无 API 配置，请先在「API 设置」里添加。'
                          : 'No API config yet. Add one in API settings first.',
                      style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                    ),
                  )
                else
                  DropdownButtonFormField<String>(
                    initialValue: cfgId.isEmpty ? configs.first.id : cfgId,
                    decoration: InputDecoration(
                      labelText: zh ? '使用哪个接口' : 'Endpoint',
                    ),
                    items: [
                      for (final c in configs)
                        DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) => setDlg(() => cfgId = v ?? ''),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: modelCtrl,
                  decoration: InputDecoration(
                    labelText: zh ? 'embedding 模型名' : 'Embedding model',
                    hintText: 'text-embedding-3-small / bge-m3',
                    helperText: zh
                        ? '不同厂商模型名不同，需手动填写'
                        : 'Model names differ per provider',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: sizeCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: zh ? '切片长度' : 'Chunk size',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: overlapCtrl,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: zh ? '重叠' : 'Overlap',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: topKCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: zh ? '检索返回条数' : 'Top-K',
                  ),
                ),
                const SizedBox(height: 4),
                // build102（E）：全局可用 —— 所有会话自动检索本库
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(zh ? '全局可用' : 'Available in all chats'),
                  subtitle: Text(
                    zh
                        ? '开启后所有会话自动检索本库，无需逐会话绑定；会增加每轮注入 token'
                        : 'Retrieve this KB in every chat without per-chat binding; increases injected tokens',
                  ),
                  value: isPublic,
                  onChanged: (v) => setDlg(() => isPublic = v),
                ),
                const SizedBox(height: 8),
                Text(
                  zh
                      ? '修改切片参数只影响之后新导入的文档，'
                          '已有切片需重新导入才会生效。'
                      : 'Chunk settings apply to newly imported docs only; '
                          're-import existing ones to take effect.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(zh ? '取消' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(zh ? '保存' : 'Save'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) {
      disposeCtrls();
      return;
    }

    int intOf(TextEditingController c, int fallback) =>
        int.tryParse(c.text.trim()) ?? fallback;
    await storage.upsertKnowledgeBase(kb.copyWith(
      embeddingConfigId: cfgId,
      embeddingModel: modelCtrl.text.trim(),
      chunkSize: intOf(sizeCtrl, kb.chunkSize).clamp(200, 4000),
      chunkOverlap:
          intOf(overlapCtrl, kb.chunkOverlap).clamp(0, 1000),
      topK: intOf(topKCtrl, kb.topK).clamp(1, 20),
      isPublic: isPublic,
    ));
    await _load();
    disposeCtrls();
  }

  Future<void> _rename() async {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final kb = _kb!;
    final ctrl = TextEditingController(text: kb.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(zh ? '重命名' : 'Rename'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(zh ? '取消' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(zh ? '保存' : 'Save'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      ctrl.dispose(); // P3：弹层控制器须显式释放（理由见 _editSettings）
      return;
    }
    final name = ctrl.text.trim();
    if (name.isEmpty) {
      ctrl.dispose();
      return;
    }
    await context
        .read<StorageService>()
        .upsertKnowledgeBase(kb.copyWith(name: name));
    await _load();
    ctrl.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final kb = _kb;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (kb == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(zh ? '知识库不存在' : 'Not found')),
      );
    }

    final total = _docs.fold<int>(0, (s, d) => s + d.count);
    final hasEmbedding = kb.embeddingModel.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(kb.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.drive_file_rename_outline),
            tooltip: zh ? '重命名' : 'Rename',
            onPressed: _rename,
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: zh ? 'Embedding 设置' : 'Embedding settings',
            onPressed: _editSettings,
          ),
        ],
      ),
      // B-014：加载中 / 知识库对象尚未就绪时 FAB 必须禁用——此前只挡 _ingesting，
      // 在 _loading 分支返回的转圈 Scaffold 上 FAB 仍可点，点下走 _resolveEmbeddingConfig
      // 的 `_kb!` 抛 Null check operator（未捕获 → 整页红屏）。
      floatingActionButton: (_ingesting || _loading || _kb == null)
          ? null
          : FloatingActionButton.extended(
              onPressed: _import,
              icon: const Icon(Icons.upload_file),
              label: Text(zh ? '导入文档' : 'Import'),
            ),
      body: Column(
        children: [
          if (_ingesting)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _progress.isEmpty
                          ? (zh ? '准备中…' : 'Preparing…')
                          : _progress,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (!hasEmbedding)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Theme.of(context).colorScheme.errorContainer,
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      zh
                          ? '尚未设置 embedding 模型，无法导入文档。'
                              '点右上角 ⚙ 设置。'
                          : 'No embedding model set. Tap ⚙ to configure.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    zh
                        ? '共 ${_docs.length} 篇文档 / $total 条切片'
                        : '${_docs.length} docs / $total chunks',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Text(
                  // build102（E）：全局可用库在详情页角标提示
                  'Top-K ${kb.topK}${kb.isPublic ? (zh ? ' · 全局可用' : ' · Global') : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _docs.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        zh
                            ? '还没有文档。点右下角导入 PDF / Word / '
                                'Excel / 文本资料。'
                            : 'No documents yet. Tap the button to import '
                                'PDF / Word / Excel / text.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                    itemCount: _docs.length,
                    itemBuilder: (context, i) {
                      final d = _docs[i];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.description_outlined),
                        title: Text(
                          d.docName.isEmpty
                              ? (zh ? '未命名' : 'Untitled')
                              : d.docName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle:
                            Text(zh ? '${d.count} 条切片' : '${d.count} chunks'),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: zh ? '移除' : 'Remove',
                          onPressed: () => _deleteDoc(d.docName),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
