import 'dart:convert';
import 'dart:math' as math;

/// build101（C1 知识库 RAG）：知识库元信息。
class KnowledgeBase {
  final String id;
  String name;
  String description;

  /// 用哪个 API 配置做 embedding（空 = 用默认配置）
  String embeddingConfigId;

  /// embedding 模型名（如 text-embedding-3-small / bge-m3 / nomic-embed-text）
  String embeddingModel;

  /// 切片长度（字符数）
  int chunkSize;

  /// 相邻切片重叠字符数（保证跨切片语义不断裂）
  int chunkOverlap;

  /// 检索返回条数
  int topK;

  /// build102（E）：全局可用 —— 开启后所有会话自动检索注入该库，
  /// 不再要求逐会话绑定（conversation.knowledgeBaseId）。
  /// 注意：全局库会增加每轮注入 token（管理页卡片上有提示文案）。
  bool isPublic;

  final int createdAt;
  int updatedAt;

  KnowledgeBase({
    required this.id,
    required this.name,
    this.description = '',
    this.embeddingConfigId = '',
    this.embeddingModel = '',
    this.chunkSize = 800,
    this.chunkOverlap = 120,
    this.topK = 5,
    this.isPublic = false,
    required this.createdAt,
    required this.updatedAt,
  });

  KnowledgeBase copyWith({
    String? name,
    String? description,
    String? embeddingConfigId,
    String? embeddingModel,
    int? chunkSize,
    int? chunkOverlap,
    int? topK,
    bool? isPublic,
  }) {
    return KnowledgeBase(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      embeddingConfigId: embeddingConfigId ?? this.embeddingConfigId,
      embeddingModel: embeddingModel ?? this.embeddingModel,
      chunkSize: chunkSize ?? this.chunkSize,
      chunkOverlap: chunkOverlap ?? this.chunkOverlap,
      topK: topK ?? this.topK,
      isPublic: isPublic ?? this.isPublic,
      createdAt: createdAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'description': description,
        'embeddingConfigId': embeddingConfigId,
        'embeddingModel': embeddingModel,
        'chunkSize': chunkSize,
        'chunkOverlap': chunkOverlap,
        'topK': topK,
        'isPublic': isPublic ? 1 : 0,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory KnowledgeBase.fromMap(Map<String, dynamic> m) => KnowledgeBase(
        id: m['id'] as String,
        name: (m['name'] as String?) ?? '',
        description: (m['description'] as String?) ?? '',
        embeddingConfigId: (m['embeddingConfigId'] as String?) ?? '',
        embeddingModel: (m['embeddingModel'] as String?) ?? '',
        chunkSize: (m['chunkSize'] as int?) ?? 800,
        chunkOverlap: (m['chunkOverlap'] as int?) ?? 120,
        topK: (m['topK'] as int?) ?? 5,
        isPublic: ((m['isPublic'] as int?) ?? 0) == 1,
        createdAt: (m['createdAt'] as int?) ?? 0,
        updatedAt: (m['updatedAt'] as int?) ?? 0,
      );
}

/// build101（C1）：知识库切片（含向量）。
class KnowledgeChunk {
  final String id;
  final String kbId;

  /// 来源文档名（用于检索结果标注「来自 X」）
  String docName;
  int chunkIndex;
  String content;

  /// embedding 向量（JSON 数组字符串，如 "[0.12,-0.03,...]"）
  String embedding;
  int dim;

  final int createdAt;

  KnowledgeChunk({
    required this.id,
    required this.kbId,
    this.docName = '',
    this.chunkIndex = 0,
    required this.content,
    this.embedding = '[]',
    this.dim = 0,
    required this.createdAt,
  });

  /// 解析 embedding 向量。
  ///
  /// 全量缺陷扫描修复（原实现 `list.map((e) => (e as num).toDouble())`）：
  /// - **不能强转**：`e as num` 只要**任一**元素类型不符就抛，被外层 `catch`
  ///   吞掉后整条向量退回空 → 该切片在检索里**永久隐形且无任何日志**。
  /// - **也不能跳过坏元素**：那会改变向量长度。`VectorMath.cosine` 见到长度
  ///   不等会直接返回 0，同样被 `minScore` 过滤 —— 还是隐形。
  /// - 故采用**保维替代**：坏元素记为 `0.0`。该维度不贡献相似度，但长度契约
  ///   与其余维度的信息完整保留，切片仍可被检索到。可见性由调用方
  ///   （`RagService` 的回传诊断）负责，本模型层保持纯函数、不引日志依赖。
  List<double> get vector {
    if (embedding.isEmpty || embedding == '[]') return const [];
    try {
      final list = json.decode(embedding);
      if (list is List) {
        return list.map((e) => e is num ? e.toDouble() : 0.0).toList();
      }
    } catch (_) {}
    return const [];
  }

  static String encodeVector(List<double> v) =>
      json.encode(v.map((e) => double.parse(e.toStringAsFixed(6))).toList());

  Map<String, dynamic> toMap() => {
        'id': id,
        'kbId': kbId,
        'docName': docName,
        'chunkIndex': chunkIndex,
        'content': content,
        'embedding': embedding,
        'dim': dim,
        'createdAt': createdAt,
      };

  factory KnowledgeChunk.fromMap(Map<String, dynamic> m) => KnowledgeChunk(
        id: m['id'] as String,
        kbId: m['kbId'] as String,
        docName: (m['docName'] as String?) ?? '',
        chunkIndex: (m['chunkIndex'] as int?) ?? 0,
        content: (m['content'] as String?) ?? '',
        embedding: (m['embedding'] as String?) ?? '[]',
        dim: (m['dim'] as int?) ?? 0,
        createdAt: (m['createdAt'] as int?) ?? 0,
      );
}

/// build101（C1）：检索命中（切片 + 相似度得分）。
class KnowledgeHit {
  final KnowledgeChunk chunk;
  final double score;

  const KnowledgeHit(this.chunk, this.score);
}

/// build101（C1）：向量工具。
class VectorMath {
  /// 余弦相似度。任一向量为空或维度不一致返回 0。
  static double cosine(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return 0;
    double dot = 0, na = 0, nb = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }
}
