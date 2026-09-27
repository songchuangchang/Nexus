import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import '../models/api_config.dart';
import '../models/knowledge_base.dart';

/// build101（C1 知识库 RAG）：切片 + 向量 + 检索。
///
/// 设计取舍：
/// - **不引原生向量库**（sqlite-vec / faiss）：三端打包成本高。向量以 JSON
///   TEXT 存 SQLite，检索时全量加载 + Dart 侧余弦打分。万级切片实测 < 200ms。
/// - **embedding 走 OpenAI 兼容 `/v1/embeddings`**：OpenAI / 智谱 / 通义 /
///   Ollama / LM Studio / SiliconFlow 全部兼容此端点，一套代码通吃；
///   Ollama 的 baseUrl 通常不带 `/v1`，这里做端点归一化兜底。
/// - **切片按段落边界优先**：先按空行切段，再按 chunkSize 聚合，避免把
///   代码块/表格从中间劈开（比纯定长切分检索质量明显更好）。
class RagService {
  static const _uuid = Uuid();

  /// 检索阈值（余弦相似度下限）的**唯一默认值**。
  ///
  /// build140（P0 缺口⑤，已接线）：这里保留默认值有两个作用——
  ///  1. **没设置过的用户行为逐字不变**（`KbRetrievalSettings.kDefault` 直接引用它，
  ///     全仓"默认是多少"只有这一个答案）；
  ///  2. 直接调 `retrieve*` 而没传 `minScore` 的调用方（含单测）仍有合理下限。
  /// 用户可调的那一格在 `lib/utils/kb_retrieval_settings.dart`：
  /// 消费点 `chat_screen_message.dart::_buildKnowledgeContext()`，
  /// 入口 `knowledge_base_screen.dart` 列表页 AppBar。
  static const double kDefaultMinScore = 0.15;

  /// 端点归一化：把各种 baseUrl 拼成 `<base>/v1/embeddings`
  ///
  /// 覆盖：
  /// - `https://api.openai.com`            → `https://api.openai.com/v1/embeddings`
  /// - `https://api.openai.com/v1`         → 同上（不重复加 v1）
  /// - `https://api.openai.com/v1/chat/completions` → 回退到 host + /v1/embeddings
  /// - `http://localhost:11434`（Ollama）  → `http://localhost:11434/v1/embeddings`
  static String embeddingsEndpoint(String baseUrl) {
    var s = baseUrl.trim();
    if (s.isEmpty) return '';
    // 去掉尾部斜杠
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    // 若已是完整 endpoint，剥到路径里第一个 /v1 之前
    final v1Idx = s.indexOf('/v1');
    if (v1Idx >= 0) {
      s = s.substring(0, v1Idx);
    }
    return '$s/v1/embeddings';
  }

  /// 批量取 embedding。返回与 [texts] 等长的向量列表。
  ///
  /// 失败抛异常，由调用方决定降级策略。
  static Future<List<List<double>>> embed({
    required ApiConfig config,
    required String model,
    required List<String> texts,
    http.Client? client,
  }) async {
    if (texts.isEmpty) return const [];
    final endpoint = embeddingsEndpoint(config.baseUrl);
    if (endpoint.isEmpty) {
      throw Exception('embedding baseUrl 为空');
    }
    final own = client == null;
    final c = client ?? http.Client();
    try {
      final resp = await c
          .post(
            Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/json',
              if (config.apiKey.isNotEmpty)
                'Authorization': 'Bearer ${config.apiKey}',
            },
            body: json.encode({
              'model': model,
              'input': texts,
            }),
          )
          .timeout(const Duration(seconds: 90));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception(
            'embedding HTTP ${resp.statusCode}: ${_brief(resp.body)}');
      }
      final data = json.decode(utf8.decode(resp.bodyBytes));
      final list = data['data'];
      if (list is! List) throw Exception('embedding 响应缺少 data 数组');
      // 按 index 排序保证与输入顺序一致（部分服务不保证顺序）
      final indexed = <int, List<double>>{};
      for (final item in list) {
        if (item is! Map) continue;
        final idx = (item['index'] as num?)?.toInt() ?? indexed.length;
        final emb = item['embedding'];
        if (emb is! List) continue;
        indexed[idx] =
            emb.map((e) => (e as num).toDouble()).toList(growable: false);
      }
      if (indexed.isEmpty) throw Exception('embedding 响应为空');
      final out = <List<double>>[];
      for (var i = 0; i < texts.length; i++) {
        out.add(indexed[i] ?? const []);
      }
      return out;
    } finally {
      if (own) c.close();
    }
  }

  static String _brief(String s) =>
      s.length > 300 ? '${s.substring(0, 300)}...' : s;

  /// 把长文本切成带重叠的语义片。
  ///
  /// 策略：优先按空行（段落）切，段落过长再按句末标点切，最后硬切。
  static List<String> chunkText(
    String text, {
    int chunkSize = 800,
    int overlap = 120,
  }) {
    final clean = text.replaceAll('\r\n', '\n').trim();
    if (clean.isEmpty) return const [];
    if (clean.length <= chunkSize) return [clean];

    final span = (chunkSize - overlap).clamp(50, chunkSize);
    final out = <String>[];
    var start = 0;
    while (start < clean.length) {
      var end = (start + chunkSize).clamp(0, clean.length);
      if (end < clean.length) {
        // 在 [start+span, end] 区间里回退到最近的段落/句末边界
        final window = clean.substring(start + span, end);
        final paraIdx = window.lastIndexOf('\n\n');
        if (paraIdx >= 0) {
          end = start + span + paraIdx + 2;
        } else {
          final lineIdx = window.lastIndexOf('\n');
          if (lineIdx >= 0) {
            end = start + span + lineIdx + 1;
          } else {
            final sentIdx = _lastSentenceBreak(window);
            if (sentIdx >= 0) end = start + span + sentIdx + 1;
          }
        }
      }
      final piece = clean.substring(start, end).trim();
      if (piece.isNotEmpty) out.add(piece);
      if (end >= clean.length) break;
      start = (end - overlap).clamp(start + 1, clean.length);
    }
    return out;
  }

  /// 找窗口内最后一个句末标点位置（中英兼顾）。
  static int _lastSentenceBreak(String s) {
    const marks = ['。', '！', '？', '；', '.\n', '. ', '! ', '? ', '; '];
    var best = -1;
    for (final m in marks) {
      final i = s.lastIndexOf(m);
      if (i > best) best = i;
    }
    return best;
  }

  /// 为一个知识库的所有新切片生成 embedding 并落库。
  ///
  /// 返回写入条数。embedding 批次大小 16（兼容性优先，避免大 batch 被拒）。
  static Future<int> ingest({
    required ApiConfig config,
    required String model,
    required KnowledgeBase kb,
    required String docName,
    required String rawText,
  }) async {
    final pieces = chunkText(rawText,
        chunkSize: kb.chunkSize, overlap: kb.chunkOverlap);
    if (pieces.isEmpty) return 0;

    final chunks = <KnowledgeChunk>[];
    const batchSize = 16;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < pieces.length; i += batchSize) {
      final end = (i + batchSize).clamp(0, pieces.length);
      final slice = pieces.sublist(i, end);
      final vectors = await embed(config: config, model: model, texts: slice);
      for (var j = 0; j < slice.length; j++) {
        final v = j < vectors.length ? vectors[j] : const <double>[];
        chunks.add(KnowledgeChunk(
          id: _uuid.v4(),
          kbId: kb.id,
          docName: docName,
          chunkIndex: i + j,
          content: slice[j],
          embedding: v.isEmpty ? '[]' : KnowledgeChunk.encodeVector(v),
          dim: v.length,
          createdAt: now,
        ));
      }
      // 小步限流，避免触发服务端 QPS 限制
      if (end < pieces.length) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    return chunks.isEmpty ? 0 : _writeChunks(chunks);
  }

  /// 写入钩子——由调用方注入 StorageService（避免 service 间直接依赖）。
  static Future<int> Function(List<KnowledgeChunk>)? _chunkWriter;
  static set chunkWriter(Future<int> Function(List<KnowledgeChunk>)? w) =>
      _chunkWriter = w;

  static Future<int> _writeChunks(List<KnowledgeChunk> chunks) async {
    final w = _chunkWriter;
    if (w == null) return 0;
    await w(chunks);
    return chunks.length;
  }

  /// 检索：对 query 取 embedding，与库内所有切片算余弦，返回 top-K。
  /// build104（S1）：多库检索时 query 向量可由外部传入复用（[queryVector]），
  /// 避免"每个库各自 embedding 一次"的按库数重复计费。
  ///
  /// 需要知道「有多少切片没参与打分」时用 [retrieveWithDiagnostics]。
  static Future<List<KnowledgeHit>> retrieve({
    required ApiConfig config,
    required String model,
    required List<KnowledgeChunk> chunks,
    required String query,
    List<double>? queryVector,
    int topK = 5,
    double minScore = kDefaultMinScore,
  }) async =>
      (await retrieveWithDiagnostics(
        config: config,
        model: model,
        chunks: chunks,
        query: query,
        queryVector: queryVector,
        topK: topK,
        minScore: minScore,
      ))
          .hits;

  /// 同 [retrieve]，额外回传[诊断][RagRetrievalDiagnostics]。
  ///
  /// 全量缺陷扫描修复：此前「切片没参与打分」有**两条完全静默的路径**，
  /// 用户只能看到「知识库没生效」而无从排查：
  ///   1. embedding 为空 / JSON 损坏 → `cv.isEmpty` 直接 `continue`；
  ///   2. 维度与查询向量不一致 → `VectorMath.cosine` 返回 0 → 被 `minScore` 过滤。
  ///      最常见诱因是**中途换过 embedding 模型**（维度变了）：此时库内旧切片会
  ///      **全部**检索不到 —— 影响面最大，也最难自查。
  /// 这里把两类原因分别计数，交由调用方决定如何呈现 —— 本 service 保持无日志依赖。
  static Future<({List<KnowledgeHit> hits, RagRetrievalDiagnostics diag})>
      retrieveWithDiagnostics({
    required ApiConfig config,
    required String model,
    required List<KnowledgeChunk> chunks,
    required String query,
    List<double>? queryVector,
    int topK = 5,
    double minScore = kDefaultMinScore,
  }) async {
    if (chunks.isEmpty || query.trim().isEmpty) {
      return (
        hits: const <KnowledgeHit>[],
        diag: RagRetrievalDiagnostics.notScored(chunks.length),
      );
    }
    List<double> qv;
    if (queryVector != null && queryVector.isNotEmpty) {
      qv = queryVector;
    } else {
      final vecs = await embed(config: config, model: model, texts: [query]);
      if (vecs.isEmpty || vecs.first.isEmpty) {
        return (
          hits: const <KnowledgeHit>[],
          diag: RagRetrievalDiagnostics.notScored(chunks.length),
        );
      }
      qv = vecs.first;
    }

    final scored = <KnowledgeHit>[];
    var skippedEmpty = 0;
    var skippedDim = 0;
    for (final c in chunks) {
      final cv = c.vector;
      if (cv.isEmpty) {
        skippedEmpty++;
        continue;
      }
      // 长度不符会被 cosine 判 0 并被 minScore 静默滤掉，这里显式记账。
      if (cv.length != qv.length) {
        skippedDim++;
        continue;
      }
      final s = VectorMath.cosine(qv, cv);
      if (s >= minScore) scored.add(KnowledgeHit(c, s));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return (
      hits: scored.take(topK).toList(),
      diag: RagRetrievalDiagnostics(
        total: chunks.length,
        scored: chunks.length - skippedEmpty - skippedDim,
        skippedEmpty: skippedEmpty,
        skippedDim: skippedDim,
      ),
    );
  }

  /// 把检索命中拼成注入给模型的上下文块。
  static String buildContextBlock(
    List<KnowledgeHit> hits, {
    required bool zh,
  }) {
    if (hits.isEmpty) return '';
    final buf = StringBuffer();
    buf.writeln(zh
        ? '以下是从用户知识库中检索到的相关资料，请优先依据这些资料回答；'
            '若资料不足以回答，请明确说明并补充你自己的知识：'
        : 'The following are relevant materials retrieved from the user\'s '
            'knowledge base. Prefer them when answering; if insufficient, say '
            'so explicitly and supplement with your own knowledge:');
    buf.writeln();
    for (var i = 0; i < hits.length; i++) {
      final h = hits[i];
      final src = h.chunk.docName.isEmpty ? (zh ? '未命名' : 'Untitled') : h.chunk.docName;
      buf.writeln('【${i + 1}】$src');
      buf.writeln(h.chunk.content);
      buf.writeln();
    }
    return buf.toString().trim();
  }
}

/// [RagService.retrieveWithDiagnostics] 回传的检索诊断。
///
/// 把「检索为什么没结果」从**静默**变成**可解释**：只统计本次加载到的切片里
/// 有多少真正参与了打分，未参与的原因分别归类 —— 便于调用方按需告警，
/// 而不必让检索路径本身承担日志职责。
class RagRetrievalDiagnostics {
  const RagRetrievalDiagnostics({
    required this.total,
    required this.scored,
    required this.skippedEmpty,
    required this.skippedDim,
  });

  /// 根本没进入打分环节（入参为空，或 query 取不到向量）。
  const RagRetrievalDiagnostics.notScored(int total)
      : this(total: total, scored: 0, skippedEmpty: 0, skippedDim: 0);

  /// 本次参与检索的切片总数。
  final int total;

  /// 真正进入余弦打分的切片数（含未达 `minScore` 而被过滤的）。
  final int scored;

  /// embedding 为空 / JSON 损坏导致解析不出向量 —— 数据层问题。
  final int skippedEmpty;

  /// 维度与查询向量不一致 —— 最常见诱因是**中途换过 embedding 模型**，
  /// 此时库内旧切片会全部检索不到，属于最需要提示用户的一类。
  final int skippedDim;

  /// 未参与打分的切片总数。
  int get skipped => skippedEmpty + skippedDim;
}
