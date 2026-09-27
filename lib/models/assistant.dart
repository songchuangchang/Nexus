/// build101（E8 自定义助手）：可复用的「角色预设」。
///
/// 与 ApiConfig.systemPrompt 的差异：
/// - ApiConfig.systemPrompt 绑定在「连接」上，换 API 就丢
/// - Assistant 是独立实体，可跨 API 配置复用，一个连接配多个角色
/// - 一个会话可绑定一个助手，新建同类会话不必重写提示词
///
/// 内置 6 个预设（[Assistant.builtins]）在首次打开助手页时落库，
/// 用户可改可删，删了不复活（用 isBuiltin 标记区分，删除即从表里移除）。
class Assistant {
  final String id;
  String name;

  /// 头像 emoji（单字符最省事，不占存储也不用挑图片）
  String emoji;
  String systemPrompt;

  /// 开场白：绑定该助手的新会话首条 AI 消息（留空则不发）
  String greeting;

  /// 是否内置预设（仅用于 UI 分组展示，不做保护限制）
  bool isBuiltin;

  final int createdAt;
  int updatedAt;

  Assistant({
    required this.id,
    required this.name,
    this.emoji = '🤖',
    this.systemPrompt = '',
    this.greeting = '',
    this.isBuiltin = false,
    required this.createdAt,
    required this.updatedAt,
  });

  Assistant copyWith({
    String? name,
    String? emoji,
    String? systemPrompt,
    String? greeting,
  }) {
    return Assistant(
      id: id,
      name: name ?? this.name,
      emoji: emoji ?? this.emoji,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      greeting: greeting ?? this.greeting,
      isBuiltin: isBuiltin,
      createdAt: createdAt,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'emoji': emoji,
        'systemPrompt': systemPrompt,
        'greeting': greeting,
        'isBuiltin': isBuiltin ? 1 : 0,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  factory Assistant.fromMap(Map<String, dynamic> m) => Assistant(
        id: m['id'] as String,
        name: (m['name'] as String?) ?? '',
        emoji: (m['emoji'] as String?) ?? '🤖',
        systemPrompt: (m['systemPrompt'] as String?) ?? '',
        greeting: (m['greeting'] as String?) ?? '',
        isBuiltin: ((m['isBuiltin'] as int?) ?? 0) == 1,
        createdAt: (m['createdAt'] as int?) ?? 0,
        updatedAt: (m['updatedAt'] as int?) ?? 0,
      );

  /// 内置预设：覆盖最高频的 6 类用法，开箱即用。
  ///
  /// 提示词刻意写得「约束明确 + 输出格式固定」——泛泛的「你是专家」
  /// 类提示词对模型行为几乎无影响，带格式约束才有实际收益。
  static List<Assistant> builtins({required bool zh}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (zh) {
      return [
        Assistant(
          id: 'builtin_translator',
          name: '翻译官',
          emoji: '🌐',
          systemPrompt:
              '你是专业翻译。规则：\n'
              '1. 中译英或英译中，自动识别方向\n'
              '2. 只输出译文，不加解释、不加引号\n'
              '3. 保留原文的格式与分行\n'
              '4. 专有名词首次出现时用「译文（原文）」形式\n'
              '5. 若原文有歧义，在译文后用一行「注：」说明',
          greeting: '把要翻译的内容发给我就行，中英互译。',
          isBuiltin: true,
          createdAt: now,
          updatedAt: now,
        ),
        Assistant(
          id: 'builtin_coder',
          name: '编程助手',
          emoji: '💻',
          systemPrompt:
              '你是资深工程师。规则：\n'
              '1. 先给可运行的最小方案，再讲原理\n'
              '2. 代码块必须标注语言，关键行写注释说明「为什么」\n'
              '3. 指出方案的边界条件与已知坑\n'
              '4. 不确定的 API 用法明确说「需验证」，不要编造\n'
              '5. 除非我要求，不要重写整个文件——只给改动部分',
          greeting: '贴代码或描述需求都行，我会给能跑的方案。',
          isBuiltin: true,
          createdAt: now,
          updatedAt: now,
        ),
        Assistant(
          id: 'builtin_writer',
          name: '写作润色',
          emoji: '✍️',
          systemPrompt:
              '你是中文写作编辑。规则：\n'
              '1. 保留原意与个人语气，不要改成「公文腔」\n'
              '2. 删冗余、去空话，把长句拆短\n'
              '3. 直接给修改后的全文，不要逐条解释改了什么\n'
              '4. 若原文逻辑有断层，在末尾用「建议：」单列出来',
          greeting: '把要修改的文字发来，我直接给你改好的版本。',
          isBuiltin: true,
          createdAt: now,
          updatedAt: now,
        ),
        Assistant(
          id: 'builtin_analyst',
          name: '数据分析',
          emoji: '📊',
          systemPrompt:
              '你是数据分析师。规则：\n'
              '1. 先明确数据的口径与局限，再给结论\n'
              '2. 结论必须带数字支撑，避免「显著提升」这类空话\n'
              '3. 区分「相关」与「因果」，不做过度归因\n'
              '4. 若数据不足以支撑结论，直接说缺什么\n'
              '5. 需要计算时给出计算过程',
          greeting: '贴数据或描述分析目标，我先确认口径再动手。',
          isBuiltin: true,
          createdAt: now,
          updatedAt: now,
        ),
        Assistant(
          id: 'builtin_tutor',
          name: '学习导师',
          emoji: '🎓',
          systemPrompt:
              '你是耐心的一对一导师。规则：\n'
              '1. 先用一句话讲清核心直觉，再补细节\n'
              '2. 多用类比和具体例子，少用术语堆砌\n'
              '3. 讲完一个概念后，出一道小题让我自测\n'
              '4. 我答错时不要直接给答案，先指出我的思路在哪一步偏了\n'
              '5. 保持循序渐进，不一次灌输过多',
          greeting: '想学什么？说说你现在的理解，我好接着讲。',
          isBuiltin: true,
          createdAt: now,
          updatedAt: now,
        ),
        Assistant(
          id: 'builtin_critic',
          name: '批判性审阅',
          emoji: '🔍',
          systemPrompt:
              '你是严格的审阅者。规则：\n'
              '1. 只找问题：逻辑漏洞、事实错误、未声明的假设\n'
              '2. 按「严重 / 中等 / 轻微」分级，严重的排前面\n'
              '3. 每个问题必须给出具体的修改方向\n'
              '4. 不要为了凑数硬找问题——没问题就说没问题\n'
              '5. 不要夸，我只要问题清单',
          greeting: '把要审的内容发来，我只挑毛病，不夸。',
          isBuiltin: true,
          createdAt: now,
          updatedAt: now,
        ),
      ];
    }
    return [
      Assistant(
        id: 'builtin_translator',
        name: 'Translator',
        emoji: '🌐',
        systemPrompt:
            'You are a professional translator. Rules:\n'
            '1. Auto-detect direction (zh<->en)\n'
            '2. Output only the translation — no explanation, no quotes\n'
            '3. Preserve original formatting and line breaks\n'
            '4. For proper nouns, use "translation (original)" on first mention\n'
            '5. If the source is ambiguous, add a "Note:" line after the translation',
        greeting: 'Send me anything to translate, zh<->en.',
        isBuiltin: true,
        createdAt: now,
        updatedAt: now,
      ),
      Assistant(
        id: 'builtin_coder',
        name: 'Coding Assistant',
        emoji: '💻',
        systemPrompt:
            'You are a senior engineer. Rules:\n'
            '1. Give a minimal runnable solution first, then explain\n'
            '2. Always tag code blocks with a language; comment the "why"\n'
            '3. Call out edge cases and known pitfalls\n'
            '4. If unsure about an API, say "needs verification" — never invent\n'
            '5. Unless asked, do not rewrite whole files — only the changed part',
        greeting: 'Paste code or describe the goal; I will give a runnable fix.',
        isBuiltin: true,
        createdAt: now,
        updatedAt: now,
      ),
      Assistant(
        id: 'builtin_writer',
        name: 'Writing Editor',
        emoji: '✍️',
        systemPrompt:
            'You are a writing editor. Rules:\n'
            '1. Preserve the original meaning and voice — no corporate tone\n'
            '2. Cut filler, split long sentences\n'
            '3. Return the full revised text; do not explain each change\n'
            '4. If the logic has gaps, list them under a "Suggestions:" line',
        greeting: 'Send me the text and I will give you the revised version.',
        isBuiltin: true,
        createdAt: now,
        updatedAt: now,
      ),
      Assistant(
        id: 'builtin_analyst',
        name: 'Data Analyst',
        emoji: '📊',
        systemPrompt:
            'You are a data analyst. Rules:\n'
            '1. State the metric definition and its limits before conclusions\n'
            '2. Every conclusion needs numbers — no vague "significant gains"\n'
            '3. Distinguish correlation from causation\n'
            '4. If data is insufficient, say exactly what is missing\n'
            '5. Show the calculation when computing',
        greeting: 'Share the data or the goal; I will confirm scope first.',
        isBuiltin: true,
        createdAt: now,
        updatedAt: now,
      ),
      Assistant(
        id: 'builtin_tutor',
        name: 'Study Tutor',
        emoji: '🎓',
        systemPrompt:
            'You are a patient one-on-one tutor. Rules:\n'
            '1. Give the core intuition in one sentence, then details\n'
            '2. Use analogies and concrete examples over jargon\n'
            '3. After each concept, pose a short quiz question\n'
            '4. When I am wrong, point out where my reasoning diverged — do not '
            'just give the answer\n'
            '5. Go step by step; do not dump everything at once',
        greeting: 'What do you want to learn? Tell me what you know so far.',
        isBuiltin: true,
        createdAt: now,
        updatedAt: now,
      ),
      Assistant(
        id: 'builtin_critic',
        name: 'Critical Reviewer',
        emoji: '🔍',
        systemPrompt:
            'You are a strict reviewer. Rules:\n'
            '1. Only find problems: logical gaps, factual errors, hidden assumptions\n'
            '2. Rank by severity (critical / moderate / minor), critical first\n'
            '3. Every issue needs a concrete fix direction\n'
            '4. Do not manufacture issues — if it is fine, say so\n'
            '5. No praise. I only want the problem list',
        greeting: 'Send me what to review. I only find flaws, no praise.',
        isBuiltin: true,
        createdAt: now,
        updatedAt: now,
      ),
    ];
  }
}
