/// 把一段 markdown 正文收成**一行摘要**的唯一所有者（build182 / #159 第一、二条）。
///
/// ## 现象
/// 会话列表那一条副标题吃的是 `conversations.lastMessage`，而它是在
/// `storage_service.dart:2705` 由 `msg.content` **截前 50 字**直接落库的。于是助手回答里
/// 的 markdown 语法字符原样摆进列表：
///  · `**结论**：` ⇒ 屏幕上真的显示两个星号（气泡里同样的字是**加粗**，列表里是星号
///    ⇒ 同一份内容两种读法，用户 10-03 逐屏看时第一条报的就是它）；
///  · 代码块 ⇒ 副标题整条被 ```` ```python ```` 占满，真正的正文一个字都看不见。
///
/// ## 为什么修在显示侧、不修写入侧
/// 库里已经存了几百条带星号的旧行；只改写入路径等于"新对话干净、老对话永远脏"。
/// 显示侧收一次 ⇒ 新旧同形，而且**原文一个字都没动**（复制、导出、重开会话仍是原 markdown）。
/// 这也是本仓一贯的口径：改渲染，不改用户的数据。
///
/// ## 只剥语法，不剥内容
/// 星号、井号、反引号、链接括号这些是**标记**；表情、正文、标点内容是模型写的。
/// 所以这里**不**过滤 emoji（用户报的"🔉 那一类字符"回读后确认来自模型正文，不是我们的文案
/// —— 我们的文案有 `test/v2_ui_guard_*` 盯着，emoji 不在其中）。把内容悄悄删掉＝替模型撒谎。
///
/// ## 兜底方向
/// 剥完变空（整条就是一个代码块 / 只有一张图片）时**不许显示空白**：
/// 空白会让用户以为这条对话没内容，那是比星号更坏的谎。
/// 兜底的内容是"原文里去掉围栏记号"，**不是**原文本身 —— 带 ``` 的原文上屏，
/// 等于这条摘要白修了（10-04 扫描席报的第六格，落库截断把代码块截在里头时必现）。
///
/// ## 与气泡那条路的关系（10-04 扫描席第五条）
/// `message_bubble_v2` 的**读屏标签**原来自己另写了一套剥标记的字符类
/// （`[#*`>\-\[\]()]`），它会把 `-`、`(`、`)` 这类**内容字符**一起删掉，
/// 于是"同一个事实两个口径"在这个文件外面又长了一个。那一处现在转手给本文件，
/// 本文件是"把 markdown 收成可读文本"的唯一所有者。
abstract final class AppPreview {
  /// 一行、至多 [maxChars] 个字符的摘要。
  ///
  /// [emptyText] 是**空那一支的落点**，默认空串。为什么要有这个参数
  /// （10-04 扫描席第二条，那是本包自己引进的回归）：调用点原来写的是
  /// `conv.lastMessage ?? l.tr('noConversations')`，我换成 `?.isEmpty == true` 之后
  /// 把 `null` 那一支漏了 —— 新建的会话没发过东西时库里存的就是 NULL
  /// （`models/conversation.dart` 的 `create()` 不写 `lastMessage`），
  /// 于是副标题一片空白，用户读作"这条对话没内容"。
  /// 把落点交给调用方传，是为了这条规矩有**唯一一处**实现，而不是每个列表各判一次
  /// —— 而"各判一次"正是漏掉 null 的那种写法会长出来的地方。
  static String of(String? raw,
      {int maxChars = 50, String emptyText = '', bool keepCode = false}) {
    if (raw == null || raw.trim().isEmpty) return emptyText;
    final cleaned = _strip(raw, keepCode: keepCode);
    // 兜底那一格在 10-04 扫描轮改过一次：原来"退回原文"，而原文里的围栏记号会跟着一起上屏。
    // 触发条件很平常 —— `storage_service.dart:2705` 落库时就截断了 50 字，
    // 一条以代码块开头的回答被截在块**里面** ⇒ `_fence` 找不到闭合的 ``` ⇒ 整段被删空 ⇒
    // 旧兜底把带 ``` 的原文贴回去 ⇒ #159 第二条在这条路上一个字都没修。
    // 现在兜底只多剥一层"围栏记号"，内容一个字不删。
    final text = cleaned.trim().isEmpty ? _dropFenceMarks(raw) : cleaned;
    final oneLine = _collapse(text);
    // 连兜底都空 ⇒ 落 emptyText。10-04 第二轮扫描第五条（成立，我核过触发输入）：
    // `raw == '```'` 这种"非空白但剥光"的行**原来也**返回 emptyText ⇒ 自动标题那一格
    // 拿到的就是哨兵 `'New Chat'` 本身 ⇒ 调用点那句 `title == 'New Chat'` 每一轮都重新成立 ⇒
    // 每发一条消息就多一次 `updateConversationTitle` **加一次 30 秒的 AI 起名调用**
    //（`_maybeAutoGenerateTitle`），而且 `agent_orchestrator` 那里按标题语言判中英文，
    // 全中文的会话被读成 isZh=false。所以这一支宁可露出围栏记号（文件头自己定的方向：
    // 不许显示空白），也不许交回哨兵词。
    //
    // 兜底那一支以前**不截断**（第三轮第五条，成立）：真 Dart 读数
    // `titleFrom('```python\n\n```\n\n' × 4)` 回 **55** 字符，而文件头写的是"至多 [maxChars]"，
    // 而这一份文本要落进 `conversations.title`、还要当导出文件名 ⇒
    // 方向不动，只把它并回**同一条**截断路径（不再另写一条"直接 return"）。
    final body = oneLine.isEmpty ? _collapse(raw) : oneLine;
    if (body.isEmpty) return emptyText; // 原文本来就空白（第 45 行那道闸之外唯一的一条路）
    if (body.length <= maxChars) return body;
    final end = _graphemeEnd(body, _unsplit(body, maxChars));
    return '${body.substring(0, end)}...';
  }

  /// 读屏（TalkBack）那一份：同一套清洗，但**代码内容不许丢**。
  ///
  /// 为什么和摘要分两档（10-04 第二轮扫描第三条，成立）：`of` 里"围栏整段让位给正文"
  /// 是列表那一格的设计（50 字里塞不进代码，代码块把行占满才是真正的抱怨），
  /// 但同一句话念给读屏用户时，眼睛看得见代码卡、耳朵里一个字都没有 ⇒ 那是剥夺不是精简。
  /// 所以这里不是"再写一套清洗"，而是**同一个所有者换一个参数**：
  /// 标记一律剥，围栏之内的内容留下（`_fence` 换成只删 ```` ``` ```` 记号）。
  static String spoken(String? raw, {int maxChars = 200}) =>
      of(raw, maxChars: maxChars, keepCode: true);

  /// 会话**自动标题**：从首条消息切一段出来当名字。
  ///
  /// 为什么这条也要走这里（10-04 真机轮抓到的，不在扫描席那 14 条里）：
  /// `chat_screen_message.dart` 有**三处**各拼了一遍 `text.substring(0, 30)}...`，
  /// 三处都不剥 markdown ⇒ 列表里那条会话的名字写着 `MARK182 **bold** and \`code\` ta...`
  /// （平板 8d1506a8 10:4x 现读原文，同一条会话的**摘要**那行是干净的，
  /// 说明清洗在、只是名字这一路没接上）。一个规则三个家，正是本包要收的那件事。
  ///
  /// 空那一支落 `'New Chat'` 不是随手挑的：调用点靠 `title == 'New Chat'` 判"还没起过名"，
  /// 首条消息全是空白时旧写法会把标题写成空格串，那个哨兵从此再也不成立 ⇒ 以后再没机会改名。
  static String titleFrom(String raw, {int maxChars = 30}) =>
      of(raw, maxChars: maxChars, emptyText: 'New Chat');

  static bool _isHighSurrogate(int code) => code >= 0xD800 && code <= 0xDBFF;
  static bool _isLowSurrogate(int code) => code >= 0xDC00 && code <= 0xDFFF;

  /// 截断点落在代理对中间时，先退一格。
  static int _unsplit(String s, int end) =>
      end > 0 && end <= s.length && _isHighSurrogate(s.codeUnitAt(end - 1)) ? end - 1 : end;

  static int _codePointUnits(int cp) => cp > 0xFFFF ? 2 : 1;

  /// 第 [i] 个单元起的**码点**（代理对合成一个；末尾残缺就只回高位那个单元）。
  static int? _cpAt(String s, int i) {
    if (i < 0 || i >= s.length) return null;
    final cu = s.codeUnitAt(i);
    if (_isHighSurrogate(cu) && i + 1 < s.length && _isLowSurrogate(s.codeUnitAt(i + 1))) {
      return 0x10000 + ((cu - 0xD800) << 10) + (s.codeUnitAt(i + 1) - 0xDC00);
    }
    return cu;
  }

  /// 贴在前一个码点上的那些：**连接符／变体选择符／组合附标／肤色／键帽／tag 字符**。
  ///
  /// 10-04 第三轮扫描第三条（成立，真 Dart 读数）：这张表原来只有 ZWJ、VS15/16、键帽、
  /// U+0300–036F，**肤色修饰符 U+1F3FB–1F3FF 不在里面**
  /// ⇒ `of('👍🏽'×20, maxChars: 22)` 切在拇指与肤色中间（列表上是个**黄**拇指，
  /// 气泡里是**中棕**那个＝同一份内容两个读法，正是 #159 报的那一形）。
  /// 一并补齐的四类同一性质（自己不是图形，切在它前面就是啃掉上一个图形的一角）：
  /// ZWNJ `U+200C`、整段 VS1–VS16 `U+FE00–FE0F`（原来只有 FE0E/FE0F 两格）、
  /// 组合旗的 tag 字符 `U+E0020–E007F`（`🏴󠁧󠁢󠁥󠁮󠁧󠁿` 这类）。
  static bool _isJoiner(int cp) =>
      cp == 0x200D ||
      cp == 0x200C ||
      cp == 0x20E3 ||
      (cp >= 0xFE00 && cp <= 0xFE0F) ||
      (cp >= 0x0300 && cp <= 0x036F) ||
      (cp >= 0x1F3FB && cp <= 0x1F3FF) ||
      (cp >= 0xE0020 && cp <= 0xE007F);

  /// 区域指示符（旗帜 emoji 的半个）：`🇨🇳` 是两个码点拼一个图形，
  /// 每一半自己都是合法代理对 ⇒ 切在中间不会留下孤立半代理（`_unsplit` 拦不住这种），
  /// 屏幕上却是个拉丁字母 `C`（10-04 第一轮扫描第三条）。
  static bool _isRegionalIndicator(int cp) => cp >= 0x1F1E6 && cp <= 0x1F1FF;

  /// 从 [start] 这个码点的**起点**走到它所在图形簇的终点（不含）。
  ///
  /// 三条规矩都直接读"这一簇由哪些码点组成"：
  ///  · 区域指示符**两个一双**：`🇨🇳`＝RI+RI 算一簇，`🇨🇳🇺🇸` 算**两**簇（不是越长越好，
  ///    第三轮扫描第二条栽就在这里）；
  ///  · 连接符/组合符（[_isJoiner]）一律贴在前面那个码点上，吃掉它不算新开一簇；
  ///  · ZWJ 是**胶水**：它后面那一个码点还在同一簇里（`👨‍👩‍👧` 整条一簇），
  ///    所以吃完 ZWJ 必须再吃一个基字，否则退回去仍是半条序列。
  static int _clusterEnd(String s, int start) {
    final base = _cpAt(s, start);
    if (base == null) return start;
    var i = start + _codePointUnits(base);
    if (_isRegionalIndicator(base)) {
      final nx = _cpAt(s, i);
      if (nx != null && _isRegionalIndicator(nx)) i += _codePointUnits(nx);
      return i;
    }
    var glue = false; // 刚吃掉一个 ZWJ ⇒ 下一个码点也属于这一簇
    for (var guard = 0; guard < 64 && i < s.length; guard++) {
      final nx = _cpAt(s, i);
      if (nx == null) break;
      if (nx != 0x200D && !_isJoiner(nx) && !glue) break;
      i += _codePointUnits(nx);
      glue = nx == 0x200D;
    }
    return i;
  }

  /// 把截断点退到**图形簇边界**上：只退不超，退到的是"被切开那一簇的起点"。
  ///
  /// 为什么换成前向扫（10-04 第三轮扫描第一条，成立）：第二轮那版是**从切点往回看**，
  /// 每步问两件事——"结尾那个是不是连接符"、"结尾后面是不是还贴着连接符"。
  /// 这两问在往回退的路上**互相打**：刚把结尾的 ZWJ/VS 退掉，下一轮"后面贴着连接符"
  /// 看到的就是自己刚退掉的那一个 ⇒ 于是把基字也退掉，再接着退……一路吃到 `guard<24` 用尽。
  /// 真 Dart 读数（`temp/b184_pack/readback_184.dart`）：
  ///  · `of('⚠️'×40, maxChars: 48)` ⇒ 27 单元（装得下 24 簇的预算只给了 12 簇）；
  ///  · `maxChars: 49` ⇒ 结尾是个**裸 U+26A0**（文件头说"不可能"的那半条序列真的出现了）；
  ///  · NFD 的 `a+U+0302+U+0301` 那一档切完剩 `a+U+0302` ⇒ **字母自己变了**（ấ→â）；
  ///  · 两面旗 `🇨🇳🇺🇸` 摆在第 43 格起：43/45/47/49 四档预算**都**回 46 单元，
  ///    也就是明明装得下的那面 🇨🇳 也被退掉了——因为旧尺子分不清"RI 是一双的后面那半"
  ///    还是"下一双的前面那半"。
  /// 前向扫没有这个自指：切点正落在某个簇的**终点**上时一格都不退（那就是干净边界），
  /// 只有落在簇**里面**才退到该簇起点。
  static int _graphemeEnd(String s, int target) {
    if (target >= s.length) return s.length;
    var i = 0;
    for (var guard = 0; guard < 4096 && i < s.length; guard++) {
      final next = _clusterEnd(s, i);
      if (next <= i) return target; // 畸形输入算出零长簇：按原切点走，绝不原地打转
      if (target <= next) return target == next ? target : i;
      i = next;
    }
    return target;
  }

  static final RegExp _fence = RegExp(r'```[\s\S]*?(?:```|$)');
  static final RegExp _fenceMark = RegExp(r'```[ \t]*[A-Za-z0-9_+.\-]*[ \t]*');
  /// 读屏那一路用这一条：把围栏**里面的内容**抓出来保管，只让记号（``` 与语言名）消失。
  static final RegExp _fenceKeep =
      RegExp(r'```[ \t]*[A-Za-z0-9_+.\-]*[ \t]*([\s\S]*?)(?:```|$)');
  static final RegExp _inlineCode = RegExp(r'`([^`]*)`');
  static final RegExp _image = RegExp(r'!\[[^\]]*\]\([^)]*\)');
  static final RegExp _link = RegExp(r'\[([^\]]+)\]\([^)]*\)');
  static final RegExp _heading = RegExp(r'^[ \t]*#{1,6}[ \t]*', multiLine: true);
  static final RegExp _quote = RegExp(r'^[ \t]*>[ \t]?', multiLine: true);
  static final RegExp _bullet = RegExp(r'^[ \t]*(?:[-*+]|\d+\.)[ \t]+', multiLine: true);

  /// 代码段保护哨兵（见 [_strip]）。NUL 不属于 `\s`，所以合并空白那步拆不散它。
  static const String _maskCh = '\u0000';
  static final RegExp _maskToken = RegExp('\u0000(\\d+)\u0000');

  /// 认识的 HTML 标签名（**闭集**：只列模型真会往正文里写的那几十个）。
  static const List<String> _htmlTags = <String>[
    'a', 'abbr', 'b', 'blockquote', 'br', 'caption', 'code', 'col', 'dd', 'del',
    'div', 'dl', 'dt', 'em', 'figcaption', 'figure', 'footer', 'h1', 'h2', 'h3',
    'h4', 'h5', 'h6', 'header', 'hr', 'i', 'img', 'input', 'ins', 'kbd', 'li',
    'main', 'mark', 'ol', 'p', 'pre', 's', 'section', 'small', 'span', 'strong',
    'sub', 'summary', 'sup', 'table', 'tbody', 'td', 'tfoot', 'th', 'thead',
    'tr', 'u', 'ul',
  ];

  /// 只剥**认识**的标签，而且属性区里不许出现汉字（10-04 第三轮扫描第四条，成立）。
  ///
  /// 旧尺子 `<[a-zA-Z/][^>]*>` 是"看形状"的，它把正文里的**比较运算**当标签吞了——
  /// 真 Dart 读数（`temp/b184_pack/readback_184.dart`，改动前）：
  ///  · `of('若 a<b 且 c>d 则返回真')` ⇒ `若 a d 则返回真`（"b 且 c" 三个字没了）；
  ///  · `of('取 x[i]<y 且 z>w 的那些')` ⇒ `取 x[i] w 的那些`。
  /// 文件头"只剥语法，不剥内容"这句话在实现上只有一种站法：**认不出来的当内容留着**。
  /// 假阴＝屏上多一对尖括号，假阳＝替模型撒谎，本仓一贯取前者（成对强调那一层同一道理）。
  /// ⚠ 属性那一串只收 HTML 里会出现的字符，**汉字不在其中**——少了这一条，
  /// `a<b 且 c>d` 里那个 `b` 因为真是标签名而照样被吞（白名单单独挡不住这种）。
  static final RegExp _html = RegExp(
      '</?(?:${_htmlTags.join('|')})(?:[ \t]+[A-Za-z0-9_:./#\\-="",;+() \t]*)?/?>',
      caseSensitive: false);
  static final RegExp _ws = RegExp(r'\s+');

  /// 强调标记：从"两头各自判一次"改成**成对才剥**（10-04 扫描席报的 P1）。
  ///
  /// 旧写法栽在哪：`把 **kwargs 传进去` 里那对星号前面是空格、后面是 `k` ⇒ 按旧规则算
  /// "合法 opening" ⇒ 被剥掉 ⇒ 摘要变成 `把 kwargs 传进去`。Python 的 `**kwargs`
  /// 是**内容**，不是标记；气泡里同样的字照原样渲染 ⇒ 同一份内容两个读法。
  /// 同类还有 `指针 int *p 说明`、行尾的 `my_var_`（文件头承诺过"标识符一个字不动"）。
  ///
  /// 为什么"成对"不会栽回 `2*3*4`：这一条**叠在**旧的外面那个判据之上，不是替换它 ——
  /// `*` 两边都是数字 ⇒ 连"合法 opening"这一关都进不来，成对这一关根本走不到。
  /// `a * b * c` 同理（星号两头都是空格）。所以两层判据都要过，方向仍是保守：
  /// 假阴＝多留两个星号，假阳＝撒谎。
  ///
  /// 顺带修掉的两条：没配对的行内反引号以前也会被当标记吃掉。
  /// 10-04 第二轮扫描第四条（成立）：这张表**同时是"极大分隔串"的合法长度名单**
  /// （`_runsAt` 要求整串左右不再粘同一个字符），所以 `****加粗****` 这种四星写法
  /// 在旧名单里没有长度＝整条被跳过 ⇒ 星号原样上屏，正是用户报的那个形状。
  /// 名单按长度从长到短排：`****` 先于 `***` 先于 `**` 先于 `*`，长的那条先吃，短的就碰不到它。
  static const List<String> _runs = <String>[
    '****',
    '____',
    '***',
    '___',
    '**',
    '__',
    '*',
    '_',
    '~~',
    '`',
  ];

  /// 字 = 拉丁字母/数字/汉字。`：`、`，`、括号、空白都算**非**字。
  static bool _isWord(int cu) =>
      (cu >= 0x41 && cu <= 0x5A) ||
      (cu >= 0x61 && cu <= 0x7A) ||
      (cu >= 0x30 && cu <= 0x39) ||
      (cu >= 0x4E00 && cu <= 0x9FFF);

  /// 极大分隔串：整串的长度**恰好**等于 run，左右不许再粘着同一个字符。
  /// 这条是 `***` 与 `**` 分开处理却互不打架的前提。
  static List<int> _runsAt(String s, String run) {
    final ch = run.codeUnitAt(0);
    final out = <int>[];
    for (var i = 0; i < s.length; i++) {
      if (!s.startsWith(run, i)) continue;
      final end = i + run.length;
      if (i > 0 && s.codeUnitAt(i - 1) == ch) continue;
      if (end < s.length && s.codeUnitAt(end) == ch) continue;
      out.add(i);
      i = end - 1; // 整串一起跳，不在串里重复起算
    }
    return out;
  }

  static bool _isOpener(String s, int at, String run) {
    if (at > 0 && _isWord(s.codeUnitAt(at - 1))) return false; // 外面必须是"非字"
    final end = at + run.length;
    if (end >= s.length) return false;
    return !_ws.hasMatch(s[end]); // opening 后面不许是空白
  }

  static bool _isCloser(String s, int at, String run) {
    if (at == 0 || _ws.hasMatch(s[at - 1])) return false; // closing 前面不许是空白
    final end = at + run.length;
    return end >= s.length || !_isWord(s.codeUnitAt(end));
  }

  static String _stripRun(String src, String run) {
    var s = src;
    // 上限从 8 提到 64（10-04 第三轮扫描第六条，成立）：一轮剥**一对**，8 轮之后剩下的
    // 照旧上屏——真 Dart 读数 `titleFrom('**项1** **项2** … **项12**')` ⇒
    // `项1 项2 项3 项4 项5 项6 项7 项8 **项9**...`，也就是用户报的那个"屏幕上真的有两个星号"
    // 在**加粗条目多于 8 条**的第一条消息上又回来了（`of` 50 字那一档同形）。
    // 这一层本来就不会转圈：每命中一对串就**严格变短** 2×run 个单元，配不上对时立刻 break，
    // 所以护栏只是防"模型写一长串同字符"那种畸形输入，不是防正常列表 ⇒ 64 档够用且仍有界。
    for (var guard = 0; guard < 64; guard++) {
      final at = _runsAt(s, run);
      if (at.length < 2) break;
      int? opener;
      for (final p in at) {
        if (_isOpener(s, p, run)) {
          opener = p;
          break;
        }
      }
      if (opener == null) break;
      int? closer;
      for (final p in at) {
        if (p > opener && _isCloser(s, p, run)) {
          closer = p;
          break;
        }
      }
      if (closer == null) break;
      // 先删后面的：opener 的下标不受影响。
      s = s.replaceRange(closer, closer + run.length, '')
          .replaceRange(opener, opener + run.length, '');
    }
    return s;
  }

  static String _dropFenceMarks(String raw) => raw.replaceAll(_fenceMark, ' ');

  static String _strip(String raw, {bool keepCode = false}) {
    // **代码段先请出去**（10-04 第三轮扫描第四条的另一半，成立）：`keepCode` 原来只放过
    // `_fence` 这一条，其余八条照咬代码内容 ⇒ 读屏那一路
    // `spoken('解释如下\n```cpp\nvector<int> v; // 容器\n```')` 念出来是 `解释如下 vector v; // 容器`
    // ——类型名 `int` 在耳朵里消失了，而屏幕上明明写着。摘要那一路同一层也欠：
    // `` `**kwargs**` `` 是代码，里面那两对星号是**内容**，但成对强调那一步不知道它身在围栏。
    //
    // 做法＝把代码段整体取出存进 `kept`，原位留一个 `NUL 序号 NUL` 的哨兵跑完清洗，
    // 最后一步再原样放回去。哨兵选 NUL 的理由：`\s` 不含它 ⇒ `_ws` 那一步拆不散它，
    // 而 `_heading`/`_bullet`/`_quote` 都要求行首有 `#`/`-`/`>`，也咬不到它。
    // 代价：正文里**真**带 NUL 时序号会串位 ⇒ 见到 NUL 就整层不保护（退回旧行为），
    // 这比"悄悄把内容换成另一段代码"划算。
    if (raw.contains(_maskCh)) {
      // 退回**改动前那条流水线**的样子：围栏按旧口径处理，其余八条照跑，不做保护。
      var bare = raw.replaceAll(keepCode ? _fenceMark : _fence, ' ');
      bare = bare.replaceAllMapped(_inlineCode, (m) => m.group(1) ?? ' ');
      return _stripBare(bare);
    }
    final kept = <String>[];
    String mask(Match m, int group, {bool trailingSpace = false}) {
      kept.add(m.group(group) ?? '');
      return '$_maskCh${kept.length - 1}$_maskCh${trailingSpace ? ' ' : ''}';
    }

    var s = raw;
    if (keepCode) {
      // 读屏：围栏里的**内容**留下，记号（``` 与语言名）不进后续清洗。
      s = s.replaceAllMapped(_fenceKeep, (m) => mask(m, 1, trailingSpace: true));
    } else {
      // 摘要：代码块整段让位给正文（50 字塞不进代码，围栏占满一行才是抱怨本体）。
      s = s.replaceAll(_fence, ' ');
    }
    // 行内代码两种口径都保护内容：记号去掉、里面的字一个字不动。
    s = s.replaceAllMapped(_inlineCode, (m) => mask(m, 1));
    s = _stripBare(s);
    return s.replaceAllMapped(_maskToken, (m) {
      final i = int.tryParse(m.group(1) ?? '');
      // 越界/解析不了一律丢掉：这只能是正文里本来就有的怪 NUL 串（上面已经让开一次，
      // 但被 `_link` 那类"把内容搬到别处"的规则搬动过的哨兵也可能拼歪）。
      // 搬回来还是丢掉？搬回来＝把不知哪儿的一段字插在这里，那是**造内容**；丢掉顶多少几个字。
      return (i != null && i >= 0 && i < kept.length) ? kept[i] : '';
    });
  }

  /// 除了"围栏／行内代码"之外的八条清洗（[_strip] 把代码段藏好之后才跑它）。
  static String _stripBare(String s) {
    s = s.replaceAllMapped(_image, (m) => ' ');
    s = s.replaceAllMapped(_link, (m) => m.group(1) ?? ' ');
    s = s.replaceAll(_html, ' ');
    s = s.replaceAllMapped(_heading, (m) => ' ');
    s = s.replaceAllMapped(_quote, (m) => ' ');
    s = s.replaceAllMapped(_bullet, (m) => ' ');
    for (final run in _runs) {
      s = _stripRun(s, run);
    }
    return s;
  }

  static String _collapse(String s) => s.replaceAll(_ws, ' ').trim();
}
