import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

/// build178（#135）：AI 答案里的 LaTeX 公式真的画出来。
///
/// **形状抄上游，不自己发明**（用户 10-02 定调："git 有的话我们就尽量借鉴一下，
/// 不要自主创新太多 bug 了，数学这个是必考"）。参照件逐字读过并落盘
/// `<本机路径>`：
///  * `mylxsw/aidea` `lib/page/component/chat/markdown/latex/` 三件套
///    （[LatexInlineSyntax] / [LatexBlockSyntax] / [LatexElementBuilder]：
///    元素 tag 统一 `latex`、行间/行内用 attribute 传），
///    与 `daodao97/chatmcp` `lib/widgets/markdown/widgets/latex.dart` 同型
///    ——两家各自独立长成了同一个形状，说明这就是 flutter_markdown 里走得通的那条路。
///  * 渲染器 `flutter_math_fork 0.7.4`（KaTeX 风格解析器＋20 个 KaTeX 字体随包，
///    **零联网、零新平台依赖**——它自己的 pubspec 现读没有 `plugin:` 段＝纯 Dart，
///    传递依赖只多出 `flutter_svg` 与 `tuple`）。可行性 10-02 在仓外独立工程实测过
///    （`<本机路径>`）：分数 `16.9×18.7`、
///    积分上下限 `87.9×34.7`、pmatrix `70.0×33.6`、坏语法不抛异常。
///
/// 有意偏离上游17处（这句里的数字必须与下面编号条数对上，判据盯着），
/// 每处都有判据钉着（`test/build179_latex_render_test.dart`）：
///  1. 分隔符表砍掉 aidea 的空格版 `( `…` )` 与 `[ `…` ]`——聊天正文里
///     "（ 见下表 ）"这种写法太常见，拿它们当定界符是拿正文换公式；
///     也砍掉 `\pu{`/`\ce{`（mhchem 宏，flutter_math_fork 不认，
///     列为定界符只会把化学式推进"报错回落"，不如留在正文里可读）。
///  2. `$…$` 命中后在 Dart 里再校验一次（内容首尾不贴空白、整段不是纯空白、
///     内容里不许再出现这一对定界符本身），
///     挡的是"打 \$5 和 \$10"这种钱数。aidea 把这条塞进正则尾部的 lookahead，
///     读不出来也测不出来；显式判定才写得反向闸。
///     **拒绝路径必须自己 `advanceBy(1)` 再返回 false**：markdown 7.3.1 的
///     `InlineSyntax.tryMatch`（inline_syntax.dart:48）不管 onMatch 返回什么
///     都 `return true`，外层 `if (syntaxes.any((s) => s.tryMatch(this))) continue;`
///     （inline_parser.dart:111）于是永远走不到它那句 `advanceBy(1)`——
///     **onMatch 只 return false 不推进 ＝ 死循环，UI isolate 当场钉死**。
///  3. 上游没传 `onErrorFallback`，flutter_math_fork 的默认回落是
///     `SelectableText(解析器英文原文)`（实测字面：`Parser Error: Expected group
///     after \frac`），会把内部报错语言摆进气泡。这里显式回落**原始 LaTeX 文本**：
///     用户至少看得见写了什么，也 copy 得走。
///  4. 缩放系数不走上游那句 `MediaQuery.of(context).textScaleFactor`（3.47 已弃用），
///     改 `MediaQuery.textScalerOf(context).scale(1)`——"公式跟随大字号"这条不变。
///  5. 块级认**两对**定界符（[LatexBlockSyntax._pairs]）：跨行 `$$…$$` 与整行的 `\[…\]`，
///     两对都要求"行首至多三个空格"才算开号；上游那条 `\${1,2}` 允许一行只写一个 `$`
///     就开数学块，会把正文吞进公式里——这一条从 179 起没松过。
///     `\(…\)` 哪一张表都不在：它是 markdown 的转义括号，不是定界符（第三轮从行内撤掉）。
///
/// 下面 6–9 是**第一轮静态扫描**（10-02，两个只读子代理并行扫本包 diff）报回来之后加的，
/// 每条都先在 179 那版代码上跑出红才动手——红因写在用例的 reason 里：
///  6. 块级**先找得到闭合行才开块**（[LatexBlockSyntax.canParse]）：旧写法只往前探一行，
///     然后一路吃到文末 ⇒ 流式途中 `$$` 后面接正文（`$$\n由此可得 a 为正数。`）会把整篇
///     余下的字并成一个"公式"。找不到闭合就不开块，宁可留源码。
///  7. 块级**两头都不吞字**：开号行可以带字（`$$a+b` 换行 `$$` 也渲染），闭合行后面那半行
///     交回正文（`$$\na+b\n$$ 因此得证。` 的"因此得证"与后面的标题都还在）。
///     `\[ … \]` 那一支**第三轮搬回块级、只接整行形状**（`_pairs` 第二对）：它先前挂在
///     行内时没有行首锚点，`所以 \[a+b\]` 实测只剩 `a+b`（前半句静默消失）；
///     收成"行首才算开号"之后那一形再也接不到，正文照旧是正文。
///  8. 长度上限 [kLatexMaxExpressionChars]：超了不进解析器，直接摆源码。
///     `Math.tex` 在 factory 里同步解析、flutter_markdown 每来一段重建整段 ⇒ 上游两家
///     都没有的这层闸，我们要有（模型输出＝不可信输入，流式还会放大次数）。
///  9. 渲染层**永远不许产出"什么都没有"**：空白内容／超长一律回落成原文本，
///     不再回 `SizedBox.shrink()`（builder 的返回值会覆盖已排好的原文＝那几个字符消失）；
///     回落文本**只钉上限**（`ConstrainedBox(maxWidth:)`，见本条末与 [_LatexFallback]：
///     一开始用 `SizedBox(width:)` 是紧约束，会把外层 `Wrap` 挤成三行），
///     公式外面包一层 `Semantics(label: 源码)`——flutter_math_fork 自己不带语义，
///     不包的话读屏会整段跳过公式。**但包了之后回落那一路会念两遍**（第五轮第 3 条：
///     回落用的是自家 `Text`，它自己就带语义，与外层 label 是**同一句字**）⇒
///     公式格内的回落文本走 `ExcludeSemantics`，由 [_LatexWidthScope] 的 `labeled` 传递；
///     尺寸闸／超长／空白那三路是**直接**交回回落文本、没有外层 label，
///     那三条不许也关掉自家语义（关了＝那一格对读屏彻底消失）。
///
/// 下面 10–14 是**第二轮静态扫描**（10-02 18:3x 起，三个并行只读子代理，镜头＝块级互抢／
/// 对抗输入／渲染布局）报回来的。同样每条先在修完第一轮的树上跑出红再动手。
/// **15–17 是后面几轮陆续补的**：15 靠第三～四轮那两席的绕过样本，16 与 17 分别是第六轮与
/// 第七轮报回来的形状（各自轮次也写在条目里）——把这三条挂在"第二轮"名下，
/// 下一个人会以为递归那一刀两年前就有，去改错那一层（证伪要在对应那一层改才咬得住）。
///  10. 开号那一侧**行首空白最多三个空格**（[LatexBlockSyntax._pairs] 每条 `open` 都带
///     `^ {0,3}`，粗筛在 [LatexBlockSyntax.pattern]）。
///     包里每条块级 pattern 都是这个上限（`patterns.dart:23` 的 indentPattern、`:20` 的
///     blockquotePattern），而自定义 syntax 排在 `CodeBlockSyntax` 之前
///     （`block_parser.dart:80` 对 `:70`）⇒ 我们多允许缩进，`    $$PORT=8080` 这种
///     四空格代码就被数学抢走。闭合那一侧仍放宽（闭合只截断，不抢块）。
///  11. 闭合扫描碰到**别的块级起点就不吞**（[LatexBlockSyntax._otherBlockStarts]）：
///     问的是包自己的 `BlockSyntax.isAtBlockEnd`，不重抄一份"什么算块起点"——
///     重抄的那份一定会跟标准语法漂（旧写法把 `$$` 后面的整张表格并进了公式内容）。
///  12. "同行已经闭合"的判据从行尾 `endsWith` 改成**这一行里出现过闭合号**：
///     旧判据一遇到 `$$a+b$$ 因此得证` 就失效，接着把**下一块**的开号当成自己的闭合。
///  13. 行内单 `$` 的**前一个字符还是 `$`** ⇒ 拒（那是 `$$` 的一部分）。
///     收下的话，流式途中 `$$\frac{1}{2}$`（差最后一个字符那一帧）会被单号那一对接受，
///     用户先看到小一号分数、下一帧跳回大字号，还少显示一个 `$`。
///     同批删掉的是旧的"前一个字符是反斜杠就拒"那道闸：`EscapeSyntax`
///     （escape_syntax.dart:21-31 ＋ patterns.dart:136 的标点表含 `$`）早就把 `\$` 整对
///     拿走了，走不到这道闸 ⇒ 它能命中的只剩误判（`<内网路径>`＝字面反斜杠＋公式被判成转义）。
///  14. 全空白（NBSP／全角空格）那一行**不算块内容**：`isBlankLine` 用 `[ \t]*`
///     （patterns.dart:6），而 Dart 的 `trim()` 认 NBSP ⇒ 两把尺子中间夹着一条路，
///     走过去块开出来了、内容是空，兜底那格会把整块重写成单个 `$$`＝删字。
///     兜底现在也把**原始行**原样还回正文（[LatexBlockSyntax._blockNode] 的 rawLines）。
///  15. 尺寸闸 [latexSizeGuardHits]：**六道**各自独立的尺寸判据——大整数／花括号嵌套／
///     `\left…\right` 嵌套／`\rule` 的高度／**参数开头**的"数字＋TeX 单位"／
///     **带尺寸控制字时不带花括号也能长成尺寸的**"数字＋TeX 单位"——后者还连带看它
///     **括号参数里面任何位置**（上游对带括号的参数用不锚定的 `firstMatch`，
///     第十轮扫描第 2 条；数字那一段也跟着上游放宽到允许尾点，第 1 条）——命中任一
///     就不进解析器。长度闸只量字符数，
///     量不到"30 个字换几万级字形"那一形：根因在依赖里，flutter_math_fork 0.7.4 把
///     KaTeX 的 `maxSize` 整行注释掉了（`src/ast/options.dart:51`），而
///     `\left( … \right)` 的堆叠重复次数没钳（`src/ast/nodes/left_right.dart:244-247`），
///     于是 `\left(\rule{0pt}{100000pt}\right)` 在 **build 阶段**产出几万级字形且
///     **不抛异常** ⇒ `onErrorFallback` 接不到，用户看到的是气泡冻住／进程被系统杀掉。
///     尺寸那一段的量级感：`\rule` 的高度写 `9999pt` 就是 **3.5 米**
///     （1pt = 0.35146 mm，换算由判据现算；第九轮之前注释里那个更大的数是错的）。
///     摘闸复放实测：同一条判据那一格跑 **314 秒**（整份判据文件正常 7 秒）——这不是推断。
///     参照件逐字读过并落盘 `<本机路径>`：aidea 那版只有
///     "报错回显原文"这一层，无任何长度／尺寸上限（它的 pattern 是
///     `(\$\$[\s\S]+\$\$)|(\$.+?\$)`，`$$` 那支连行都不换就吞），两家上游都撞不到这一形
///     ⇒ 这层闸钉的是我们自己的输入空间。
///     第三、四道是 10-02 23:2x **另一席**独立构造的绕过样本逼出来的（60 对 `\left(`
///     配 `\rule{0pt}{9999pt}`：长度 798、最长数字 4 位、花括号峰深 1，前两道全放行），
///     逐字复放进判据。
///     打击面（同一席按**表达式**粒度在 1200 行语料上复算，不是我按整行数出来的）：
///     配对出来的 919 条表达式里 **42 条**被退回源码显示，其中"本来要画成公式"
///     （`expect_math>=1`）的只有 **4 行**；代价（记着，别当已修）：正文里真写五位以上
///     整数字面量的公式（`n = 100000`）会退回源码；**订正**：上一版这里举的例子是 `6.02214076e23`，而它**根本不被挡**——第一道闸跳过小数点后面那一串，科学计数法那形六道全放行（第九轮扫描第 6 条）——可读、可复制，只是没画成公式。
///     订正一条我自己写错的数：上一版这里写"语料里有 60 行是这一族"，**没有出处**
///     （七种数法 23／24／25／42／65／80／107 都对不上 60），已换成上面那两个有出处的数。
///  16. **解析只做一次，改变宽度不许重解**（[_LatexFormula]）：`Math.tex` 是 factory，
///     构造它＝在 `src/widgets/math.dart:147` 同步跑一遍 `TexParser`；上一版把它放在
///     `LayoutBuilder.builder` 闭包里，而 SDK 的 `LayoutBuilder` 只要 constraints 一变
///     就重跑 builder（`layout_builder.dart:265-268`）⇒ 转屏／分屏拖动会把一个气泡里
///     **所有**公式逐帧重解析。现在解析结果存在 State 里，只有**正文／档位／字号**变了
///     才重解（`didUpdateWidget`）；回落文本要的那"这一格多宽"改由 [_LatexWidthScope]
///     在 build 时传进来，所以钉住宽度不再需要重造一个 `Math`。
///  17. **块级前扫不许递归回自己**（[LatexBlockSyntax._scanning] ＋
///     [kLatexMaxBlockScanLines]）：`BlockSyntax.isAtBlockEnd` 遍历 `blockSyntaxes` 时
///     问的也是 `canParse`（现读 markdown 7.3.1 `block_syntax.dart:51-56`），而 custom
///     排在 standard **之前**（`block_parser.dart:80`）⇒ 上一版"先往下找得到闭合行再开块"
///     那圈前扫，每碰到另一个未闭合的开号行就**递归进自己**。本机现跑的 Stopwatch 读数：
///     连续 `\[` 的 8／10／12／14／16 行＝**7／31／94／226／803 毫秒**（每两行约 ×3），
///     同样 12 行夹空行＝1 毫秒，普通正文同样行数＝1 毫秒。上游两家要么没有这圈前扫、
///     要么只找闭合行不查"别的块起点"，撞不到这一形 ⇒ 钉的是我们自己的输入空间：
///     卡住的模型最爱吐的正是"行首 `\[` 通篇没有 `\]`"，而 flutter_markdown 在 data
///     一变就重解析（`widget.dart:371-377`）⇒ 冻住的是整条消息列表所在的 isolate。
///
/// 已知代价（flutter_markdown 自身结构，换谁都得付）：行内公式不能并进段落的
/// RichText，包会把一句话拆成"若干 Text.rich ＋公式 Widget"再套一层 `Wrap`
/// （见 `flutter_markdown-0.7.7+1/lib/src/builder.dart` 的 `_InlineElement` 注释），
/// 所以公式与前后文字**不共享基线**、窄屏上可能换行。这是取舍，不是缺陷。
/// 另一条已知代价（与 GitHub／remark-math 同款，不是我们改坏的）：两个单 `$` 之间夹的是
/// **中文**时（`符号的和$号`）会被当公式——挡住它要么放宽数学本身（`$a + b$` 也带空格），
/// 没有既兼容正文又兼容公式的判别式，所以这一格记在代价里而不是记成已修。

/// 送进 `Math.tex` 之前允许的最大长度（字符）。
///
/// 超了就**不解析**，直接把源码摆出来。为什么要有这一条：`Math.tex` 在 factory 里就
/// 同步解析（flutter_math_fork 0.7.4 `math.dart:147`），而 flutter_markdown 每来一段
/// 都要重建整段（`widget.dart:387`）⇒ 一个 3k 字的"公式"（真实场景几乎都是被块语法
/// 吞进去的正文）会被**逐帧**重解。上游两家没有这层上限——这是文件头第 8 条，
/// 钉的是我们自己的输入空间（模型输出＝不可信输入，且流式会放大次数）。
/// 它只量**字符数**，量不到尺寸那一族，所以还有第 15 条那六道尺寸闸。
const int kLatexMaxExpressionChars = 2000;

/// 尺寸闸之一：出现**连续这么多位及以上的阿拉伯数字** ⇒ 不进解析器。
///
/// **小数点后面那一串不算**（`(?<!\.)`）：第五轮扫描报回来的误杀——
/// `\pi \approx 3.14159` 里 `14159` 是连续五位，被这一道判成炸弹，
/// 而这类常数在答案正文里比"把尺寸写成大数"常见得多。小数位不影响任何布局尺寸，
/// 真正能撑大版面的整数与大数仍然照挡（`\rho = 100000` 仍被挡）。
///
/// 为什么单挑数字（文件头第 15 条）：flutter_math_fork 0.7.4 没有可用的尺寸上限——
/// KaTeX 那个 `maxSize` 在 `src/ast/options.dart:51` 是**注释掉的一行**，而
/// `\left( … \right)` 的堆叠重复次数没钳
/// （`src/ast/nodes/left_right.dart:244-247`：`repeatCount =
/// ceil((minDelimiterHeight - minHeight) / (repeatHeight * middleFactor))`，
/// 分母是个常数级的小量，分子由**内容高度**决定）⇒ 一个 30 字符的串能把 build 阶段
/// 变成几万级字形，且**不抛异常**，`onErrorFallback` 接不到，唯一的表现是界面卡死。
/// 实测过一次的代价：把这道闸摘掉跑同一条判据，那一格跑了 **314 秒**（正常整份文件 7 秒）。
/// 字符数闸（2000）拦不住它。
///
/// 阈值定在 5 位是取舍不是定理：日常公式里的整数数字字面量极少到五位数，而炸弹要的正是
/// "把尺寸写成一个大数"。四位（`x^{1024}`）照旧渲染，由反向闸钉着。
const int kLatexMaxNumberDigits = 5;

/// 尺寸闸之五：`数字＋TeX 长度单位` 里数字达到这么多位 ⇒ 不进解析器。
///
/// 这一道是第五轮扫描补的**通用面**：第四道只认 `\rule{宽}{高}` 那一个写法，而把内容顶高
/// 的路不止它一条（`\raisebox{3000pt}{…}` 同样进 `left_right.dart:244-247` 那个除法），
/// 而且 `\rule` 还允许一个方括号移位参数（现读 `katex_base/rule.dart:28` 的
/// `numArgs: 2, numOptionalArgs: 1`）——`\rule[0pt]{0pt}{9999pt}` 当时整条查不到。
/// 单位表现读 `src/ast/size.dart:63-81`。
///
/// 定 4 位（≥1000 个单位）而不是 3 位：`150pt` 这种"画一条长横线"是正当写法，
/// 而 1000pt 已经远超一块屏幕。数字与单位**必须紧邻**，
/// `a\,100\,\text{px}` 那种中间隔着 `\,\text{` 的不是 TeX 尺寸，不许误杀。
const int kLatexMaxDimensionDigits = 4;

/// 第一道闸的式子：**整数位**上出现连续 [kLatexMaxNumberDigits] 位及以上的数字才算命中。
///
/// 写成循环而不是 `(?<!\.)` 那种后视断言：Dart 的 RegExp 引擎对后视的支持按版本漂，
/// 而这条闸一旦构造失败＝**整道闸静默失效**（本仓最不该赌的就是"尺子没装上看起来却像绿"）。
/// 小数点后面那一串不算（`\pi \approx 3.14159` 不是炸弹），理由写在 [kLatexMaxNumberDigits] 上面。
bool latexLongIntegerRun(String expression) {
  for (final run in RegExp(r'[0-9]+').allMatches(expression)) {
    if (run.group(0)!.length < kLatexMaxNumberDigits) continue;
    final before = run.start - 1;
    if (before >= 0 && expression[before] == '.') continue;
    return true;
  }
  return false;
}

/// 尺寸闸之四：`\rule{宽}{高}` 的**高度**写成三位及以上数字 ⇒ 不进解析器。
///
/// 只量第二个参数：宽度不驱动 `repeatCount`（`\rule{200pt}{1pt}` 是一条无害的横线，
/// 照旧渲染），高度才是那道除法里的分子。四位已经够堆出几千层（`9999pt ≈ 3.5 米`）（1pt = 1/72.27 英寸 = 0.35146mm；上一版这里那个更大的数是错的，第九轮扫描第 6 条纠正）。
/// 方括号那个移位参数是**可选的第一个参数**（上游 `rule.dart:28`），必须跳过它再取高度，
/// 否则 `\rule[0pt]{0pt}{9999pt}` 从这条闸边上走过去（第五轮扫描抓到的洞）。
final RegExp _tallRule = RegExp(
    r'\\rule\s*(?:\[[^\]]*\])?\s*\{[^{}]*\}\s*\{\s*[-+]?\s*[0-9]{3,}');

/// 尺寸闸之五的式子：**参数开头**的数字（可带小数、可隔空格）紧跟 TeX 单位。
///
/// 为什么要"参数开头"这个锚（第六轮第 3 条）：只按字面邻接判，`$1m = 1000mm$`、
/// `$S = 2000cm^2$` 这种单位换算整条被退回源码——那是小学数学答案里最常见的写法。
/// 锚在参数开头**保住的是正文**，但它**不是**上游读尺寸的唯一路子（第十轮扫描第 2 条把我
/// 上一版那句"真能顶高内容的尺寸都出现在 `{…}`／`[…]` 的第一个 token 上"改正）：
/// 上游对**带括号的**参数用**不锚定**的 `firstMatch`，所以 `[…]`／`{…}` 里面任何位置上的
/// 四位数字＋单位都算尺寸 ⇒ 覆盖面由第五道（行首那形）＋第六道（名单控制字之后的参数，
/// 含**组内部**）合起来盖，两道都不按"第一个 token"收。
/// 数字语法照上游的两条路一起放宽（第十轮扫描第 1 条）：
///  · `_parseSizeRegex`（`parser.dart:532-533`）＝ `^[-+]? *(?:$|\d+|\d+\.\d*|\.\d*) *[a-z]{0,2} *$`
///    ⇒ **尾点**合法：`\rule{0pt}{9999.}` 之外，`$<内网路径>` 也是 9999.0pt（≈3.5 米）；
///    旧写法 `(?:\.[0-9]+)?` 要求点后还有数字 ⇒ 那一形六道全放行；
///  · `_parseMeasurementRegex`（`:534-535`）＝ `([-+]?) *(\d+(?:\.\d*)?|\.\d+) *([a-z]{2})`
///    ⇒ 空整数位（`.5pt`）合法但只有半 pt，不危险；它仍要能被**参数跳读器**消费掉，
///    否则 `$<内网路径>` 里那个 `.5pt` 挡在真尺寸前面，跳读器一走就停（同第 1 条的另一半）。
/// 小数、空格、以及**正负号与数字之间那个空格**也一起收（第六轮第 1 条补前两种、
/// 第七轮第 4 条补第三种：

/// `[-+]?` 后面原来没有 `\s*`，于是 `\raisebox{+ 9999pt}{x}` 与 `\rule{0pt}{+ 9999pt}`
/// 那五道（第六道出现之前的全部）全放行，而 `+ 9999pt` 是被咬住那一形 `9999pt` 的**同一个高度**）。
/// 第五道与第六道不是包含关系：第五道认"参数花括号开头"（连 `\mycmd{9999pt}` 这种
/// 名单外的控制字也挡），第六道认"名单内控制字 ＋ 不带花括号"（`\rule1pt9999pt`）。
// 三段**相邻字面量**拼出来（不用 `+`：analyzer 的 prefer_adjacent_string_concatenation
// 会报，而这里必须混用 raw 与非 raw——中间那段要插 `kLatexMaxDimensionDigits`）。
final RegExp _bigDimension = RegExp(
    r'[{[]\s*[-+]?\s*[0-9]{'
    '$kLatexMaxDimensionDigits,'
    r'}(?:\.[0-9]*)?\s*(?:pt|bp|pc|dd|cc|nd|nc|sp|px|ex|em|mu|mm|cm|lp)');

/// 上游那条**不锚定**的读数（`_parseMeasurementRegex.firstMatch`）的位置版反面：
/// **参数组内部**任何位置上的四位及以上数字＋TeX 单位都算尺寸。
/// 与 [_bigDimension] 同一族写法：**中间那段必须是非 raw**（插值），
/// 第三道同族常驻哨见本文件里"第八轮"与"第九轮"那两组共用的那条锁。
final RegExp _dimensionInsideArgument = RegExp(
    r'[-+]?\s*[0-9]{'
    '$kLatexMaxDimensionDigits,'
    r'}(?:\.[0-9]*)?\s*(?:pt|bp|pc|dd|cc|nd|nc|sp|px|ex|em|mu|mm|cm|lp)');

/// 尺寸闸之六：表达式里**既有吃尺寸的控制字、又有"四位及以上数字＋TeX 单位"** ⇒ 不进解析器。
///
/// 为什么第五道不够（第八轮扫描第 1 条，与已登记的 #27 同一条）：第五道要求数字前面是
/// `{`／`[`，可上游吃尺寸的参数**可以不带花括号**——现读 `flutter_math_fork`
/// `parser/tex/parser.dart:548`：`if (!optional && this.fetch().text != '{')
/// res = _parseRegexGroup(_parseSizeRegex, 'size')`，而 `katex_base/rule.dart:32-33`
/// 的 width／height 都是 `optional: false` ⇒ `\rule1pt9999pt` 与 `\rule{1pt}{9999pt}`
/// 是**同一个东西**：一个 `SpaceNode(height: 9999pt)`，外面还是那台没钳的
/// `left_right.dart:244-247`。文件头第 15 条原来那句"真能顶高内容的尺寸都出现在
/// `{…}`／`[…]` 的第一个 token 上"就是错的，现在改口。
///
/// 为什么不干脆去掉锚、回到"任何四位数字＋单位都挡"（第七轮之前那一版）：那一版会把
/// `$1m = 1000mm$`、`$S = 2000cm^2$` 整条退回源码（第六轮第 3 条修的正是那个误杀）。
/// 加一道"必须同时出现吃尺寸的控制字"的与式，就把两件事分开了：
/// 数学里 `1000mm` 单独出现是"数字 × 斜体 m × 斜体 m"，只有紧跟在 `\rule`／`\kern`／
/// `\raisebox` 这一族后面它才被读成尺寸。名单取自 `katex_base`／`left_right` 那几处
/// 真正会调 `parseArgSize` 的控制字（上游没有 `_parseSize` 这个名字——第十轮扫描第 5 条
/// 挑出我这里写错的那半句；私有的正则叫 `_parseSizeRegex`，公开的方法叫 `parseArgSize`）。
/// 名单是**穷举出来的**（第九轮扫描第 1、4 条）：现读 flutter_math_fork 0.7.4，
/// 全库会调 `parseArgSize` 的只有九处，其中 `cr.dart:47` 传的是 `optional: true`
/// （那是 `<内网路径>` 那一形，不吃裸尺寸）⇒ **能不吃花括号就把一串数字读成尺寸的，
/// 只有下面这几个名字**：
///  · `rule.dart:31-33` → `<内网路径>`（可选移位＋宽＋高，后两个都不带花括号也成立）；
///  · `raise_box.dart:31` → `<内网路径>`；
///  · `kern.dart:27` 一条 spec 同时注册 `<内网路径>`／`<内网路径>`／`<内网路径>`／`<内网路径>`，
///    `:34` 调 `parseArgSize(optional: false)`；
///  · `genfrac.dart:185`（`<内网路径>` 的横线粗细）、`:242`（`<内网路径>`）、`:256`（`<内网路径>`）。
/// 上一版列的 13 个名字**两头都不对**：漏了 `hskip`／`mskip`／`above`／`genfrac`／`abovefrac`
/// （⇒ `$<内网路径> b\\right)$` 六道全放行，与 #27 那条绕路同一个量级）；
/// 又多列了 `mspace`／`hspace`／`vspace`／`lower`／`higher`（这份依赖里 0 处实现，抄自 KaTeX 名字表）
/// 与 `!`／`quad`／`qquad`（零参数定宽宏，**根本不读尺寸参数**）——
/// 它们只把与式的左边放宽，除了制造误杀没有任何作用，全删。
final RegExp _sizeEater = RegExp(
    r'\\(?:rule|raisebox|kern|mkern|hskip|mskip|genfrac|abovefrac|above)(?![a-zA-Z])');


/// 这一族控制字各自的**参数次序**（现读上游每个 handler 里 `parseArgSize`／`parseArgNode`
/// 的先后：`rule.dart:31-33`、`raise_box.dart:31-32`、`kern.dart:34`、`genfrac.dart:183-188`
/// 与 `:240-256`）。第十轮扫描第 2 条逼出来的这张表。
///
/// 只有标成 `size`／`optsize` 的那几格会被读成尺寸；标成 `group`／`hbox` 的是**正文**——
/// 里面写着 `9999pt` 也只是几个字形。不分开写就会把 `\raisebox{1pt}{2000pt}` 这种
/// "位移正常、正文里带单位"的式子整条退回源码（第九轮第 3 条那次误杀的同族形状）。
const Map<String, List<String>> _eaterArgKinds = <String, List<String>>{
  'rule': <String>['optsize', 'size', 'size'],
  'raisebox': <String>['size', 'hbox'],
  'kern': <String>['size'],
  'mkern': <String>['size'],
  'hskip': <String>['size'],
  'mskip': <String>['size'],
  'genfrac': <String>['group', 'group', 'size', 'group', 'group', 'group'],
  'above': <String>['size'],
  'abovefrac': <String>['group', 'size', 'group'],
};

/// 沿上游 `parseArgSize` 的读法走完这一族的参数，回答"其中哪一格会长成尺寸"。
///
/// 两条路都要盖（这就是上一版漏的那一半）：
///  · **裸着写**（`\rule1pt9999pt`）⇒ 那一格由 [_dimensionPrefix] 判开头；
///  · **带花括号**（`\rule{0pt}{x9999pt}`）⇒ 上游 `_parseStringGroup` 取了整组文字之后
///    用**不锚定**的 `firstMatch` ⇒ 组里**任何位置**的四位以上数字＋单位都算，
///    所以这一格交给 [_dimensionInsideArgument] 在组内部找。
/// 组的收尾按**第一个** `]`／`}` 切（不做括号配平）：`{\text{see 9999pt}}` 切出来的是
/// `\text{see 9999pt`——尺寸还在里面，方向保守，不会因此放过。
bool _eaterArgumentsCarryBigDimension(String expression, int from, List<String> kinds) {
  var i = from;
  for (final kind in kinds) {
    if (i >= expression.length) return false;
    // 上游 `parseArgSize` 之前会**先跳过空白**，再收可选的正负号 ⇒ `\kern -9999pt` 这一格的真值
    // 就是 `-9999pt`。不跳空白的后果是：`_anyDimension` 的式子以 `[-+]?` 开头，第一个字符是空格就
    // 整族 `return false` ⇒ 带空格的负尺寸从闸边上走过去（10-04 形状表实测：六格全 false）。
    while (i < expression.length &&
        (expression[i] == ' ' || expression[i] == '\t' || expression[i] == '\n')) {
      i++;
    }
    if (i >= expression.length) return false;
    final rest = expression.substring(i);
    final bracket = rest.startsWith('[');
    final braced = rest.startsWith('{');
    if (kind == 'optsize') {
      if (!bracket) continue; // 可选那一格没出现：往后让，不算读不到
      final end = rest.indexOf(']');
      if (end < 0) return false;
      if (_dimensionInsideArgument.hasMatch(rest.substring(1, end))) return true;
      i += end + 1;
      continue;
    }
    if (kind == 'size') {
      if (braced) {
        final end = rest.indexOf('}');
        if (end < 0) return false;
        if (_dimensionInsideArgument.hasMatch(rest.substring(1, end))) return true;
        i += end + 1;
        continue;
      }
      final size = _anyDimension.matchAsPrefix(rest);
      if (size == null || size.end == 0) return false; // 这一格读不出尺寸 ⇒ 整族到此为止
      if (_dimensionPrefix.hasMatch(rest)) return true;
      i += size.end;
      continue;
    }
    // group／hbox：吃掉这一格，但**不看里面**（正文里的 `9999pt` 不是尺寸）
    if (braced) {
      final end = rest.indexOf('}');
      if (end < 0) return false;
      i += end + 1;
      continue;
    }
    return false;
  }
  return false;
}

/// 单位表取自上游 `src/ast/size.dart` 的 `_parseMeasurementRegex` 能认的那几个两字母单位，
/// 与 [_bigDimension] 同源（第九轮席上也照着这份表核过一遍：`inches`／`cssEm` 那两条
/// 是 `([a-z]{2})` 走不到的路径，不该出现在名单里）。
/// 数字那一段带**尾点**那一形，并且额外认 `.5pt`（空整数位）——后者不是为了挡它，
/// 而是为了跳读器能把它**消费掉**：`\rule.5pt9999pt` 里危险的是第二个尺寸（第十轮第 1 条）。
final RegExp _anyDimension = RegExp(
    r'[-+]?\s*(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\s*'
    r'(?:pt|bp|pc|dd|cc|nd|nc|sp|px|ex|em|mu|mm|cm|lp)');

/// **开头**就是一个四位及以上的尺寸（与式右边那半的位置版）。
/// 与 [_bigDimension] 同一族写法：**中间那段必须是非 raw**。
/// 第一版整条写成 `r'…[0-9]{$kLatexMaxDimensionDigits,}…'`，raw 串不认 `$` 插值 ⇒
/// 编译出的 pattern 是字面 `{`＋行尾锚＋一串字母，**没有任何输入能匹配**，
/// 而 Dart 的 `RegExp`（非 unicode 模式）把这视为合法字面量、一声不吭 ⇒
/// 第八轮那版 `_looseDimension` 就此是一道**永不成立的死闸**，本文件里"第五道闸上方那三行
/// 关于相邻字面量拼法"的注释自己就写了这一点（第十轮扫描第 5 条把我这里原先那个
/// 指向本文件二百二十几行的**自指行号引用**去掉了——自己文件的行号引用一定会漂，
/// 漂了没人报错，比不引用更坏；要指就指名字，或指它上面那句话）。
/// 现在这个名字已经没了（与式改判位置之后由 [_dimensionPrefix] 承担），但这条规矩留给**下一个带插值的式子**：判据见本文件里"第八轮"与"第九轮"那两组，摘掉闸或把插值写回 raw 都必须红。

final RegExp _dimensionPrefix = RegExp(
    r'^[-+]?\s*[0-9]{'
    '$kLatexMaxDimensionDigits,'
    r'}(?:\.[0-9]*)?\s*'
    r'(?:pt|bp|pc|dd|cc|nd|nc|sp|px|ex|em|mu|mm|cm|lp)');

/// `<内网路径>` 那一形：行末跳的**方括号参数**里、任何位置的四位及以上数字＋TeX 单位。
///
/// 上游 `cr.dart:47` 传的是 `optional: true` ⇒ 它**不吃裸尺寸**（这正是第九轮把 `<内网路径>`
/// 排除在 [_sizeEater] 之外的理由，那一半仍然成立，别照这句话把它加回名单）。
/// 但它照旧走 `_parseStringGroup` ＋**不锚定**的 `firstMatch` ⇒ `<内网路径>` 被读成
/// 9999pt（第十轮扫描第 2 条的后半）。所以这一族只钉"带方括号的那一形"：
/// 裸着的 `a\\9999pt` 里那串是正文，挡它就是误杀。
final RegExp _rowSkipOpener = RegExp(r'\\\\[ \t]*\[');

bool _rowSkipArgumentCarriesBigDimension(String expression) {
  for (final m in _rowSkipOpener.allMatches(expression)) {
    final open = m.end - 1; // 锚点吃进去的那个 `[`
    final close = expression.indexOf(']', open + 1);
    if (close < 0) continue; // 没有收尾＝这一形不成立
    if (_dimensionInsideArgument
        .hasMatch(expression.substring(open + 1, close))) {
      return true;
    }
  }
  return false;
}

/// 第六道闸的谓词：**与式还要配位置**（第九轮扫描第 3 条），
/// 而"位置"要跟着上游的**参数次序**走，并且包含**括号参数内部**（第十轮扫描第 2 条）。
///
/// 上一版只看"两样都在"，于是 `$S = 2000cm^2 \quad \rule{2pt}{3pt}$` 整条退回源码——
/// `2000cm` 与 `\rule` 中间隔着 `\quad`，它压根不是那条控制字的参数。
/// 现在按 [_eaterArgKinds] 逐格走：**尺寸格**里（裸着的或带花括号的）出现四位以上的尺寸就挡，
/// **正文格**里出现的不算。距离与结构都跟着 `parseArgSize` 的读法，不再是我自己发明的窗口。
bool latexUnbracedDimensionHit(String expression) {
  for (final eater in _sizeEater.allMatches(expression)) {
    // `eater.group(0)` 形如 `\rule`；名单与 [_eaterArgKinds] 的键必须同步，
    // 少一个键就退回"看不见参数"那一形——同步由判据里那条结构锁钉住（第十轮新增）。
    final word = eater.group(0)!.substring(1);
    final kinds = _eaterArgKinds[word];
    if (kinds == null) continue;
    if (_eaterArgumentsCarryBigDimension(expression, eater.end, kinds)) return true;
  }
  return _rowSkipArgumentCarriesBigDimension(expression);
}

/// 第五道闸单独露一个谓词，理由与 [latexTallRuleHit] 同：归因要落到"哪一道咬的"。
bool latexBigDimensionHit(String expression) => _bigDimension.hasMatch(expression);

/// 尺寸闸之二：花括号嵌套**超过**这么多层 ⇒ 不进解析器。
///
/// 没有大数字也能炸：`\frac{` 的嵌套高度按层乘，12 层就是四个数量级。
/// 日常写法 `\frac{\frac{a}{b}+c}{d-e}` 只有两三层 ⇒ 上限 10 不误杀。
const int kLatexMaxBraceDepth = 10;

/// 尺寸闸之三：`\left`／`\right` 的**对数嵌套深度**超过这么多层 ⇒ 不进解析器。
///
/// 这条是补洞，不是重复：`\left(` 后面跟的是圆括号，**一个花括号都不产生**，
/// 所以第二条闸对下面这串完全看不见（实测峰深＝1）：
/// 60 对 `\left( … \right)` 包一根 `\rule{0pt}{9999pt}`——长度 798（第一条闸放行）、
/// 最长连续数字 4（第一条也不命中）、花括号峰深 1（第二条放行），
/// 而按 `left_right.dart:244-247` 那个式子，每一对都要按内容高度堆几百到几千层。
/// 这条串是 10-02 23:2x **另一席**独立构造出来的（`<本机路径>`），
/// 不是我自己的推断 ⇒ 判据里逐字复放它。
const int kLatexMaxStretchDepth = 10;

/// 花括号嵌套的最深层数，转义整体跳过（`\{` `\}` 是字面括号，不是分组）。
/// 多余的 `}` 不许把计数压成负数（`a}b{c` 那种畸形串在模型输出里真的会出现）。
int latexBraceDepthPeak(String expression) {
  var depth = 0;
  var peak = 0;
  for (var i = 0; i < expression.length; i++) {
    final ch = expression[i];
    if (ch == r'\') {
      i++;
      continue;
    }
    if (ch == '{') {
      depth++;
      if (depth > peak) peak = depth;
    } else if (ch == '}' && depth > 0) {
      depth--;
    }
  }
  return peak;
}

/// 第四道闸单独露一个谓词：判据要能说出"这一条是被哪道挡下的"。
/// 六道全并进一个布尔也行，但那样任何一道被摘掉都只是"少了一格红"，
/// 归因不出红的是哪一层（本仓 10-02 注进注释不红、注进真 import 才红是同一条教训）。
bool latexTallRuleHit(String expression) => _tallRule.hasMatch(expression);

/// `\left`／`\right` 的嵌套峰深：每一对 `\left` 算一层（`\right` 收一层）。
///
/// 与 [latexBraceDepthPeak] **分开数**是故意的：这两族的高度放大器不是同一个源，
/// 合并成一个数就没法说清"这条被哪道闸挡下"，而证伪时要在**对应那一层**改才咬得住
/// （10-02 注进注释不红、注进真 import 才红是同一条教训）。
int latexStretchDepthPeak(String expression) {
  var depth = 0;
  var peak = 0;
  for (final match in RegExp(r'\\(?:left|right)(?![a-zA-Z])').allMatches(expression)) {
    if (match.group(0) == r'\left') {
      depth++;
      if (depth > peak) peak = depth;
    } else if (depth > 0) {
      depth--;
    }
  }
  return peak;
}

/// 这条"看起来是公式"的串，尺寸上会不会把渲染器打死？
///
/// 只答是／否，不答为什么——两处调用点（行内与块级都汇到渲染层）共用一条判据，
/// 少一处接线就是一条漏路。真正的拦截动作在 [LatexElementBuilder]：命中就摆源码。
bool latexSizeGuardHits(String expression) =>
    latexLongIntegerRun(expression) ||
    latexBraceDepthPeak(expression) > kLatexMaxBraceDepth ||
    latexStretchDepthPeak(expression) > kLatexMaxStretchDepth ||
    latexTallRuleHit(expression) ||
    latexBigDimensionHit(expression) ||
    // 第六道（第八轮扫描第 1 条）：不带花括号那一形，`\rule1pt9999pt`
    latexUnbracedDimensionHit(expression);

/// 数学元素在 flutter_markdown `builders` 里的标签名。
/// aidea 与 chatmcp 两家都叫 `latex`，改名等于放弃可对照的上游实现。
const String kLatexElementTag = 'latex';

/// 元素 attribute：这一格按行间（display）还是行内（text）排。
/// 取值只有下面两个字面量，`build179_latex_render_test` 钉着（第八轮第 6 条：这里原来写着
/// 一个**不存在的**文件名 `build178_latex_render_test`，下一个人按它去找判据会找不到）。
const String kLatexMathStyleAttr = 'MathStyle';
const String kLatexDisplayValue = 'display';
const String kLatexTextValue = 'text';

/// 一对数学定界符。
class LatexDelimiter {
  const LatexDelimiter(
    this.left,
    this.right, {
    this.display = false,

    /// 单美元号专用：内容首尾贴空白就不算公式（挡住 "打 \$5 和 \$10"）。
    this.rejectPaddedContent = false,
  });

  final String left;
  final String right;

  /// true = 行间样式（上下限竖排、分数更大）。
  final bool display;
  final bool rejectPaddedContent;
}

/// 顺序即优先级：`$$` 必须排在 `$` 前面，否则 `$$x$$` 会被单号先咬掉一半。
///
/// 第三轮扫描（回归席）之后**只剩这两对**：`<内网路径>` 与 `<内网路径>` 都在 markdown 的转义标点表里
/// （patterns.dart:136 ＋ escape_syntax.dart:18），而我们的行内语法排在 EscapeSyntax 之前
/// （inline_parser.dart:63 对 :80）⇒ 旧表把 `输入 <内网路径> 确认`、`步骤<内网路径>)：开机`
/// 整段吞成公式，反斜杠与中括号从屏上消失，而复制／导出读的是原文＝所见非所复制。
/// 与 GitHub／remark-math 也是同一口径：行内只认 `$`／`$$`。
/// `<内网路径>` 没有消失，它搬到了块级（[LatexBlockSyntax]），只在"整行"形状下接。
const List<LatexDelimiter> kLatexDelimiters = [
  LatexDelimiter(r'$$', r'$$', display: true),
  LatexDelimiter(r'$', r'$', rejectPaddedContent: true),
];

/// 定界符里的 `$` `[` `(` `<内网路径>` 全是正则元字符，逐个转义后再拼。
String escapeLatexForRegExp(String raw) => raw.replaceAllMapped(
      RegExp(r'[-\/\\^$*+?.()|[\]{}]'),
      (match) => '\\${match.group(0)}',
    );

/// 行内数学：`$x$` 与同一行内的 `$$x$$`——**只有这两对**，取值由 [kLatexDelimiters]
/// 那一张表说了算（第七轮扫描第 3 条：这一句原来还写着 `\(x\)`、`\[x\]`，
/// 而 `\(…\)` 第三轮就被赶回 markdown 的转义括号、哪一张表都不在；
/// 下一个人照这句把 `LatexDelimiter(r'\(', r'\)')` 加回行内表，`test` 里那张
/// "整等断言"当场红——**注释能把人引到一次红上，它就是缺陷**，判据见
/// 「文件头那些 dartdoc 引用必须指向真实成员」旁边那把定界符集合锁。
///
/// 内容段 `(?:<内网路径>)*?`：`<内网路径>` 让 `\{`、`\$`、`<内网路径>` 这类转义整体吃掉，
/// `[^<内网路径>` 保证不跨行（跨行的 `$$…$$` 归 [LatexBlockSyntax]）。
/// 尾部 `(?=[^0-9A-Za-z_]|$)` 要求闭合定界符后面不许紧跟词字符——
/// "从 \$5 涨到 \$10" 里第二个 `$` 后面是数字 `1`，于是那条候选整体不成立。
String buildLatexInlinePattern(List<LatexDelimiter> delimiters) {
  final parts = <String>[];
  for (final d in delimiters) {
    parts.add('${escapeLatexForRegExp(d.left)}'
        r'((?:\\.|[^\\\n])*?)'
        '${escapeLatexForRegExp(d.right)}');
  }
  return '(?:${parts.join('|')})' r'(?=[^0-9A-Za-z_]|$)';
}

/// 正文里的行内公式。挂进 `MarkdownBody(inlineSyntaxes: [...])`。
class LatexInlineSyntax extends md.InlineSyntax {
  LatexInlineSyntax() : this.withDelimiters(kLatexDelimiters);

  /// 只换分隔符表构造（判据要用窄表复现"没有这条校验会怎样"）。
  ///
  /// **正则与校验必须吃同一张表**：早先把校验写成"永远查全局表"，结果
  /// `withDelimiters` 只换了正则、校验还在看全局 ⇒ 那条证伪用例根本换不出世界 B，
  /// 看着像"反向闸绿了"，其实是尺子没跟着变（本仓踩过的"取值撞上旧常数"同型）。
  LatexInlineSyntax.withDelimiters(this.delimiters)
      : super(buildLatexInlinePattern(delimiters));

  /// 本实例用的分隔符表（正则由它生成，判定也由它做）。
  final List<LatexDelimiter> delimiters;

  /// 上一条**被本实例接受**的公式，其闭合定界符第一个字符在 `parser.source` 里的下标。
  /// 没接受过就是 -1。配 [_closerSource] 一起用（只认同一份原文里的位置）。
  ///
  /// 为什么必须有这两个字段（第七轮扫描第 1 条，P1 形）：B-2 那道闸要分清
  /// 「前一个 `$` 是上一条刚消费的闭合号」（`$a$$b$`，两条都该成公式）与
  /// 「前一个 `$` 还是活文本」（流式途中 `$$\frac{1}{2}$` 差最后一个字符那一帧）。
  /// 上一版是**从不消费的原文里往前猜**（`_dollarAtIsCloser`：往前找一对 `$`、中间非空
  /// 就算闭合号）——可那段话里只要已经出现过一条 `$…$`，"中间非空"就恒成立，
  /// 于是这道闸在**最常见的"一段里多条公式"里整条失效**：`$p$ 得 $$a$$b` 实测把中间
  /// 那截 `$a$` 收成一条公式，6 个 `$` 屏上只剩 2 个，还多出一条谁也没要的公式。
  /// 猜＝没有信息源；记下来才是判据。
  int _lastCloserAt = -1;
  String? _closerSource;

  /// 「前一格的 `$` 就是上一条公式刚消费掉的闭合号」——同一份原文才算数。
  /// 比 `==` 而不是 `identical`：`InlineParser` 内部怎么造这份字符串不由我们保证，
  /// 而"同一个下标落在另一份同样内容的原文里"这种巧合，值比较一样能拦住。
  bool _closerJustConsumed(md.InlineParser parser, int index) =>
      _lastCloserAt == index && _closerSource == parser.source;

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final raw = match.group(0) ?? '';
    final content = _firstUsedGroup(match);
    final delimiter = _delimiterOf(raw, delimiters);

    // 拒绝路径：本语法不认，但正则已经命中 ⇒ 必须自己推进一格再交回，
    // 否则解析器原地不动＝死循环（见文件头第 2 条）。
    void rejectAsText() => parser.advanceBy(1);

    if (delimiter == null ||
        content == null ||
        // **整段是空白也算空**：`答案 $$ $$ 如下` 的内容是一个空格，旧写法只判
        // `isEmpty` ⇒ 开出元素、渲染层只能回空盒，而 builder 的返回值会**覆盖**
        // flutter_markdown 已经排好的原文（builder.dart:576）＝那几个字符从屏上消失。
        // 这一条来自第一轮静态扫描 B-3。
        content.trim().isEmpty) {
      rejectAsText();
      return false;
    }
    if (delimiter.rejectPaddedContent &&
        (RegExp(r'^\s').hasMatch(content) || RegExp(r'\s$').hasMatch(content))) {
      rejectAsText();
      return false;
    }
    // **定界符的内容里不许再出现它自己**（第七轮第 2 条把这一格从"只配单字符"放宽到整串）：
    // `$$$$` 在 pos0 走到"空内容"被拒、前进一格之后，剩下三个 `$` 会被单号那一条咬成
    // 「内容是 `$` 的公式」；而 `$$a$$b$$` 在只配单字符那一版里**永远走不到这条闸**
    // （`delimiter.left.length == 1` 对 `$$` 恒假），于是整串被并成一条内容是 `a$$b` 的
    // display 公式——`$` 在 math 模式里有字形（现读 flutter_math_fork
    // `ast/symbols/symbols.dart:3784-3787` 的 `'\$'`，`AtomType.ord`）⇒ **不抛**，
    // `onErrorFallback` 接不到：屏上画出一条谁也没要的 `a$$b`，两条真公式的边界被吞，
    // 6 个 `$` 只剩 2 个，用户与复制文本都看不见少了什么。
    // 代价：`$a\$b$`（正文里要一个字面美元号）与 `$$1$$2$$` 这类会被整体退回源码——
    // 罕见，且退回是**可读**的（一个字都不丢，由 `_expectNothingDropped` 那一族钉着）。
    if (content.contains(delimiter.left)) {
      rejectAsText();
      return false;
    }
    // B-1（第二轮）：**这道闸删了**。原来那句读的是"原始 source 里前一个字符是不是反斜杠"，
    // 而 `\$x$` 那种真转义早在 `EscapeSyntax`（escape_syntax.dart:21-31 ＋ patterns.dart:136
    // 的标点表含 `$`）就被整对拿走了，走不到这里 ⇒ 能走到这里的只剩误判：
    // `<内网路径>`（一个字面反斜杠 ＋ 一条公式）前一个字符也是反斜杠，合法公式被判成转义、
    // 屏上留源码。行为由 `\$x$` 那条用例继续钉着（它现在钉的是 EscapeSyntax，不是我们）。
    //
    // B-2（第二轮）：单 `$` 定界符的前一个字符还是 `$` ⇒ 那本来就是 `$$` 的一部分。
    // 不收的话，流式途中 `$$\frac{1}{2}$`（差最后一个字符）会在 pos1 被单号那一对接受，
    // 那一帧用户看到的是**小一号**的分数、还少一个 `$`，下一帧又跳回大字号＝高度抖一次。
    // B-2（第二轮）＋第三轮修正：单 `$` 的开号前面那个字符如果是 `$`，**先看它是不是
    // 上一条公式刚消费掉的闭合号**——是就放行（`$a$$b$` 两条都要成公式），
    // 不是才拒（流式途中 `$$\frac{1}{2}$` 那一帧，那个 `$` 还是活文本）。
    // 上一版只读 `parser.source` 的前一字符、不分辨这两种情况 ⇒ 相邻两条公式只剩一条
    // （第三轮逐行席 A-1）；补的那一版改成"往前猜一对非空"⇒ 段里只要出现过一条 `$…$`
    // 就恒真，闸在**最常见**的那一形里又整条失效（第七轮第 1 条，实测输入
    // `$p$ 得 $$a$$b` 与流式那一帧 `由 $E=mc^2$ 得 $$x+1$`）。现在只认**自己刚消费的
    // 那个闭合号的下标**，不猜。
    if (delimiter.left == r'$' &&
        match.start > 0 &&
        parser.source[match.start - 1] == r'$' &&
        !_closerJustConsumed(parser, match.start - 1)) {
      rejectAsText();
      return false;
    }

    final element = md.Element.text(kLatexElementTag, content);
    element.attributes[kLatexMathStyleAttr] =
        delimiter.display ? kLatexDisplayValue : kLatexTextValue;
    // 接受＝记下这一对的闭合号第一个字符落在哪儿，下一条紧挨着它时要用（上面那道闸）。
    _lastCloserAt = match.end - delimiter.right.length;
    _closerSource = parser.source;
    parser.addNode(element);
    return true;
  }
}

/// 跨行的数学块：`$$`…`$$` 与整行的 `\[ … \]`（同一行内就闭合那一形也算，见 [canParse]）。
///
/// 包成 `Element('p', [latex])` 而不是自造块级标签：flutter_markdown 的
/// `builders` 只对段落里的 inline 子元素生效，aidea 也是这么绕过去的。
/// 内容是 `md.Text` 不是 `md.UnparsedContent` ⇒ `Document._parseInlineContent`
/// （document.dart:100）不会再对它跑 inline 语法，公式里的 `_` 不会被吃成 `<em>`。
///
/// 两对定界符共用一套纪律（三轮扫描一条条撞出来的）：
///  * **先找得到闭合才开块**——找不到就整块不开，宁可留源码（第一轮 A-1／B-1）；
///  * 开号限"行首至多三个空格"——与包里每条块级 pattern 同口径，多允许一个缩进就会
///    抢走四空格代码块（第二轮 A-1／B-疑问）；
///  * 闭合扫描碰到别的块起点就退——问的是包自己的 `BlockSyntax.isAtBlockEnd`，
///    不重抄一份"什么算块起点"（第二轮 A-3）；
///  * 闭合行后面那半行交回正文，全空白行不算内容，空块不开（第一轮 B-3／第二轮 B-3）；
///  * `\( … \)` 不在这里、也不在行内表里：它是 markdown 的转义括号，不是定界符（第三轮）。
class LatexBlockPair {
  const LatexBlockPair({
    required this.open,
    required this.close,
    required this.openText,
    required this.closeText,
  });

  final RegExp open;
  final RegExp close;
  final String openText;
  final String closeText;
}

/// 块级跨行前扫最多看这么多行（第七轮扫描第 1 条的第二道闸）。
///
/// 第一道闸是 [LatexBlockSyntax._scanning]（递归掐断），这一道是**上限**：
/// 就算递归没了，n 行连续开号在无上限前扫下仍是 O(n²)，而"要跨 64 行以上才闭合"的
/// 输入在模型输出里不会是公式，只可能是被吞掉的正文——那种一律不开块。
/// 上下限成对钉着（只写下限的闸对"把上限改成 10 万行"是绿的）：见
/// `test/build179_latex_render_test.dart` 的「块级前扫的形状」那一组。
const int kLatexMaxBlockScanLines = 64;

class LatexBlockSyntax extends md.BlockSyntax {
  /// 粗筛：这一行是不是数学块的开号。真正判定在 [canParse]。
  ///
  /// `pattern` **不是只有 `canParse` 的默认实现在用**（第九轮扫描第 5 条把我这句话改正）：
  /// 包里 `BlockSyntax.canParse` 那一行默认实现我们确实覆盖了，可
  /// `block_syntaxes/footnote_def_syntax.dart:47,78` 会把**每一条已注册块级语法**的
  /// `pattern` 拿出来单独 `hasMatch(line)`，用它判"这一行算不算块起点、脚注定义该不该在这里断"，
  /// 且它**不问 `canParse`**。生产里这条路径是活的（`flutter_markdown` 的
  /// `widget.dart:398` 默认 `extensionSet.gitHubFlavored`，里面就有 `FootnoteDefSyntax`）。
  /// 后果如实记：`[^1]: 注` 后面跟一行**永不闭合**的 `$$` 时，脚注定义会在这一行断掉
  /// ——我们自己在 `canParse` 里拒绝开块，但它的 `pattern` 先被脚注那一格用掉了。
  /// 不丢字符（那一行仍是正文），所以这一格记成**已知代价**而不是"已修"；
  /// 要收口就把 `pattern` 收成"同行带闭合号"那一种，那属下一次改块级形状时一起做。
  /// 上面那两句要**合起来读**（第十轮扫描第 5 条挑出我上一版留在这里的自相矛盾）：
  /// `pattern` 在包里有**两个**消费者——`BlockSyntax.canParse` 的默认实现（我们已经覆盖它，
  /// 所以那个消费者走的是下面那套校验）与 `FootnoteDefSyntax`（它直接用 `pattern`，
  /// **不问 `canParse`**，所以那一个我们盖不住）。
  /// 而 markdown 7.3.1 的 `interruptedBy`／`isAtBlockEnd`（block_syntax.dart:44／:53）
  /// 问的是 `canParse` ⇒ 段落中间那行会不会中断，全看下面那两道校验；
  /// 脚注那一格是唯一不受 `canParse` 管的通路，也就是上面那条**已知代价**的来源。
  @override
  RegExp get pattern => RegExp(r'^ {0,3}(?:\$\$|\\\[)');

  static final List<LatexBlockPair> _pairs = [
    LatexBlockPair(
      open: RegExp(r'^ {0,3}\$\$'),
      close: RegExp(r'^\s*\$\$'),
      openText: r'$$',
      closeText: r'$$',
    ),
    LatexBlockPair(
      open: RegExp(r'^ {0,3}\\\['),
      close: RegExp(r'^\s*\\\]'),
      openText: r'\[',
      closeText: r'\]',
    ),
  ];

  static LatexBlockPair? _pairOf(String line) {
    for (final p in _pairs) {
      if (p.open.hasMatch(line)) return p;
    }
    return null;
  }

  static String _after(String line, RegExp head) => line.replaceFirst(head, '');

  /// 把读位临时挪到"往前第 ahead 行"，问包自己的块边界判据，再挪回来。
  ///
  /// **不自己重抄一份"什么算块起点"**：抄了就会跟标准语法漂——第二轮 A-3 的根因就是
  /// 旧闭合扫描只认"行首 `$$` ＋空行"，于是 `$$\n| A | B |\n…` 把整张表并进公式内容。
  bool _otherBlockStarts(md.BlockParser parser, int ahead) {
    for (var i = 0; i < ahead; i++) {
      parser.advance();
    }
    try {
      return md.BlockSyntax.isAtBlockEnd(parser);
    } finally {
      // 读位**必须**挪回来：这条是在驱动循环的中途借道，留着偏移会把后面的行跳掉。
      parser.retreatBy(ahead);
    }
  }

  /// 同一行内第一个闭合号的位置（没有则 -1）。
  int _indexOfClose(String opened, LatexBlockPair pair) =>
      opened.indexOf(pair.closeText);

  /// **两个**块级闭合号（双美元与 `\]`）都算——第十轮扫描第 3 条。
  ///
  /// 上一版那道"中途出现闭合号就不开块"只认**自己这一对**的闭合号，于是混着写的两形
  /// 照样从旁边走过去：一行写反斜杠方括号开头、下一行写 `a $$ b`、再下一行写它的闭合号；
  /// 更短的一形是同一行里 `\[ a $$ b \]`。块开出来之后内容就是 `a $$ b`，而**块级内容
  /// 不再过行内那一遍** ⇒ 两个美元符号直接进数学模式（`$` 在 math 里有字形，
  /// `symbols.dart:3784-3787`）⇒ 不抛、兜底接不到 ⇒ 屏上那一条与原文各是一套
  /// （第九轮 #149 那一形的同族，只是这次跨的是两种定界符）。
  /// 所以这道闸问的是"这一段里有没有**任何**块级闭合号"，有就不开块——退回正文一个字不丢：
  /// 行内那一道会自己去认双美元那一对，认不到就原样印出来。
  static final RegExp _anyBlockCloser = RegExp(r'\$\$|\\\]');

  /// 跨行前扫期间为真——这条是第七轮扫描第 1 条（P0 形）逼出来的。
  ///
  /// 机制（两处都是现读，不是我推的）：`md.BlockSyntax.isAtBlockEnd`（markdown 7.3.1
  /// `block_syntax.dart:51-56`）写的是 `parser.blockSyntaxes.any((s) => s.canParse(parser)
  /// && s.canEndBlock(parser))`，而 `block_parser.dart:80` 把 custom syntax 排在 standard
  /// **之前** ⇒ 下面那个前扫每遇到另一个未闭合的开号行，就**递归回自己**。
  /// 本机实测（`flutter test` 现跑的 Stopwatch 读数，不是外推）：n＝8／10／12／14／16 行
  /// "每行只有 `\[`" 各花 **7／31／94／226／803 毫秒**，每多两行约 ×3 ⇒ 递推式
  /// T(i)＝Σ_{j>i}T(j)＝指数级；同样 12 行**夹空行**只要 1 毫秒（空行把前扫截断），
  /// 普通正文同样行数 1 毫秒。24 行就是几十秒，而 flutter_markdown 在 data 一变就重解析
  /// （`widget.dart:371-377`）⇒ 卡住的是整条消息列表所在的那个 isolate，不是这一格。
  /// 尺寸闸那一族管不到它：那六道量的是**已经成形**的表达式，这里还在"要不要开块"。
  bool _scanning = false;

  @override
  bool canParse(md.BlockParser parser) {
    final line = parser.current.content;
    final pair = _pairOf(line);
    if (pair == null) return false;
    final opened = _after(line, pair.open);
    final sameLine = _indexOfClose(opened, pair);
    if (sameLine >= 0) {
      // 同一行里就闭合（`$$x$$`、`\[x\]`）⇒ 块自己接：内容取闭合号之前、闭合号之后那截
      // 交回正文，两种形状都不会吃掉开号之前的字。
      // 这条**原本是 `sameLineToInline` 一个开关**：变异复放 Q5 把它翻成"永远块接"之后
      // 59 例一条没红 ⇒ 那个开关是死支，删掉（留着一个谁也不改变的分岔＝下一次改的人要猜）。
      // 但"闭合号之前那一段"里不许藏着**另一对**的闭合号（第十轮扫描第 3 条，
      // 理由见 [_anyBlockCloser]）：`\[ a $$ b \]` 开出来的内容带着那两个 `$`，
      // 而块级内容不会再过行内那一遍。
      if (_anyBlockCloser.hasMatch(opened.substring(0, sameLine))) return false;
      return true;
    }
    // 递归进来＝包正在问"这一行会不会开一个数学块"。上面那条"同行就闭合"已经答过 true，
    // 走到这里说明这一行自己不闭合 ⇒ 直接 false，**不再向前扫**（向前扫就是递归）。
    // 语义代价（如实记，别当没写）：跨行 `$$ … $$` 的前扫中途问到"中间某行算不算 latex
    // 起点"时答"不算"——那一行本来就没有同行闭合，块要么被标准语法中断、要么在真正的
    // 闭合行开出来，块边界与递归那版一致，变的只有耗时形状。
    if (_scanning) return false;
    // 跨行：**先确认往下找得到闭合行再决定开不开块**，且**最多看 [kLatexMaxBlockScanLines] 行**。
    // 开号那一行的**残余**也要过同一道闸（第十轮扫描第 3 条的另一半）：
    // 一行写 `\[ a $$ b`、下一行才写闭合号，那 `a $$ b` 是 body 的第一格，
    // 而下面那个逐行循环只看"往后探的那几行"，不查它自己。
    if (_anyBlockCloser.hasMatch(opened.trim())) return false;
    final body = <String>[if (opened.trim().isNotEmpty) opened.trim()];
    _scanning = true;
    try {
      for (var ahead = 1; ahead <= kLatexMaxBlockScanLines; ahead++) {
        final next = parser.peek(ahead);
        if (next == null || next.isBlankLine) return false; // 没有闭合＝这不是块
        if (pair.close.hasMatch(next.content)) return body.isNotEmpty;
        // `isBlankLine` 用 `[ \t]*`（patterns.dart:6），Dart 的 `trim()` 却认 NBSP／全角空格
        // ⇒ 两把尺子中间那条路会让块开出来而内容是空，兜底把整块重写成开号＝删字。
        final trimmed = next.content.trim();
        if (trimmed.isEmpty) return false;
        // 闭合号出现在**中途**（`a $$ b`）⇒ 不开块（第九轮扫描第 2 条；与行内那一道
        // `content.contains(delimiter.left)` 同一口径）。上一版只认行首的闭合号，
        // 于是
        //   $$
        //   a $$ b
        //   $$
        // 开出一条内容是 `a $$ b` 的 display 公式：`$` 在 math 模式里有字形
        // （flutter_math_fork `ast/symbols/symbols.dart:3784-3787`）⇒ 不抛、
        // `onErrorFallback` 接不到 ⇒ 六个 `$` 屏上剩两个，三行并成一条，
        // 而"复制/导出"读的是原文＝所见非所复制。退回源码：一个字都不丢。
        if (_anyBlockCloser.hasMatch(trimmed)) return false;
        if (_otherBlockStarts(parser, ahead)) return false; // 别的块起点 ⇒ 不吞
        body.add(trimmed);
      }
      // 上限内没找到闭合＝不开块。这一形正是耗时的来源，而"64 行以上才闭合的公式"
      // 在模型输出里不会是公式，只可能是被吞掉的正文——宁可留源码（可读、可复制）。
      return false;
    } finally {
      // `_scanning` **必须**跟着落回 false：这条是在驱动循环中途借道，
      // 留着 true 会把之后每一个跨行开号一律判成"不开块"＝块级数学整条静默失效。
      _scanning = false;
    }
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final line = parser.current.content;
    final pair = _pairOf(line)!;
    final opened = _after(line, pair.open);
    final sameLine = _indexOfClose(opened, pair);
    if (sameLine >= 0) {
      // 单行形式（`\[a+b\]`）：内容取闭合号之前，闭合号之后那截交回正文。
      parser.advance();
      return _blockNode(
        opened.substring(0, sameLine),
        rawLines: [line],
        closerRemainder:
            opened.substring(sameLine + pair.closeText.length).trim(),
      );
    }
    final body = <String>[if (opened.trim().isNotEmpty) opened.trim()];
    final rawLines = <String>[line]; // 兜底要原样还回去的行，一个字不改
    parser.advance();
    var remainder = '';
    while (!parser.isDone) {
      final current = parser.current;
      if (pair.close.hasMatch(current.content)) {
        // 闭合号那行**后面还可以带字**（第一轮 A-1）：那半行交回正文，不并进公式内容。
        remainder = _after(current.content, pair.close).trim();
        parser.advance();
        break;
      }
      if (current.isBlankLine) break; // canParse 已保证走不到；真到了也不许继续吞
      body.add(current.content.trim());
      rawLines.add(current.content);
      parser.advance();
    }
    return _blockNode(body.join('\n'),
        rawLines: rawLines, closerRemainder: remainder);
  }

  /// 块的产出只有一个形状：`p[latex]`（＋闭合号那行的剩余文字）。
  md.Node _blockNode(String content,
      {required List<String> rawLines, required String closerRemainder}) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      // 走不到这里（canParse 把"光杆开号／空块／全空白行"都挡在门外）；
      // 真走到了就**把原始行原样还回正文**，一个字都不许少。
      final back = [...rawLines, if (closerRemainder.isNotEmpty) closerRemainder]
          .join('\n')
          .trimRight();
      return md.Element('p', [md.Text(back)]);
    }
    final element = md.Element.text(kLatexElementTag, trimmed);
    element.attributes[kLatexMathStyleAttr] = kLatexDisplayValue;
    return md.Element('p', [
      element,
      // `UnparsedContent` 才会被 `Document._parseInlineContent`（document.dart:100）
      // 再走一遍行内语法；用 `md.Text` 的话那半行里的 `**粗体**` 就永远不解析了。
      if (closerRemainder.isNotEmpty) md.UnparsedContent(closerRemainder),
    ]);
  }
}

/// 把 `latex` 元素画成公式。挂在 `MarkdownBody(builders: {kLatexElementTag: ...})`。
class LatexElementBuilder extends MarkdownElementBuilder {
  LatexElementBuilder({this.textStyle});

  /// 要覆盖正文字号时用；null 则沿用 markdown 段落给下来的样式。
  final TextStyle? textStyle;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final expression = element.textContent;
    if (expression.trim().isEmpty ||
        expression.length > kLatexMaxExpressionChars ||
        latexSizeGuardHits(expression)) {
      // 三种情况都**不交给解析器**，但都必须把原文摆出来：
      //  * 空／纯空白：旧写法回 `SizedBox.shrink()`，而 builder 的返回值会覆盖
      //    flutter_markdown 已排好的原文（builder.dart:576）＝那几个字符从屏上消失。
      //    这一条是"渲染层永远不许产出'什么都没有'"的通则，扫描 B-3。
      //  * 超长：见 [kLatexMaxExpressionChars]。
      //  * 尺寸炸弹（大数字／深嵌套）：见 [latexSizeGuardHits]——它只有 30 个字符，
      //    长度闸放它过去，代价是整屏卡死，而且**不抛异常**所以回落那条路接不到。
      // 这里不给 `wrapWidth`：这一格不在横向滚动视图里面，段落约束自然会让它折行。
      return _LatexFallback(expression: expression);
    }

    final isDisplay =
        element.attributes[kLatexMathStyleAttr] == kLatexDisplayValue;
    final style = textStyle ?? preferredStyle ?? parentStyle;

    return _LatexFormula(
      expression: expression,
      isDisplay: isDisplay,
      style: style,
      textScale: MediaQuery.textScalerOf(context).scale(1),
    );
  }
}

/// 一条公式的渲染单元：**解析只做一次**，改变宽度不许重解（文件头第 16 条）。
///
/// 上一版把 `Math.tex(...)` 写在 `LayoutBuilder.builder` 的闭包里，而 `Math.tex` 是
/// factory——**构造它＝同步解析一遍**（flutter_math_fork 0.7.4
/// `src/widgets/math.dart:147`）；`LayoutBuilder` 只要 constraints 一变就重跑 builder
/// （SDK `layout_builder.dart:265-268`）⇒ 转屏／分屏拖动会把这个气泡里**所有**公式
/// 逐帧重解析一遍。解析结果挪进 State 之后，只有正文／档位／字号变了才重解。
class _LatexFormula extends StatefulWidget {
  const _LatexFormula({
    required this.expression,
    required this.isDisplay,
    required this.style,
    required this.textScale,
  });

  final String expression;
  final bool isDisplay;
  final TextStyle? style;
  final double textScale;

  @override
  State<_LatexFormula> createState() => _LatexFormulaState();
}

class _LatexFormulaState extends State<_LatexFormula> {
  /// 解析一次、反复交回**同一个** widget 实例（Widget 不可变， reused 是合法的）。
  late Math _math = _parse();

  Math _parse() => Math.tex(
        widget.expression,
        mathStyle: widget.isDisplay ? MathStyle.display : MathStyle.text,
        textStyle: widget.style,
        textScaleFactor: widget.textScale,
        // 回落**不许在这里钉死宽度**：它画在横向滚动视图里面，那一刻拿到的约束是
        // `maxWidth=∞`；宽度改由 [_LatexWidthScope] 在 build 时供，见 [_LatexFallback]。
        // 上游没传这一句，默认回落会把 `Parser Error: Expected group after \frac`
        // 这种内部英文摆进气泡（文件头第 3 条）。
        onErrorFallback: (_) => _LatexFallback(expression: widget.expression),
      );

  @override
  void didUpdateWidget(covariant _LatexFormula oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expression != widget.expression ||
        oldWidget.isDisplay != widget.isDisplay ||
        oldWidget.style != widget.style ||
        oldWidget.textScale != widget.textScale) {
      // 流式途中正文每帧都在长——**内容变了才重解**，这是必需的成本，
      // 也是 [_LatexFormula] 必须是 StatefulWidget 而不是全局缓存的理由。
      _math = _parse();
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
        // flutter_math_fork 0.7.4 自己 lib/ 里 `semantics` 命中 0，`Math` 也不可选
        // ⇒ 不包这一层，读屏会整段跳过公式（`由 $E=mc^2$ 可知` 念成"由 可知"），
        // 而报错回落那一路反倒念得到——**安静的错着、能读的却读不出**是不可接受的不对称。
        // 标签用 LaTeX 源码：不假装念成数学语言，只保证"这一格有东西"。扫描 B-4。
        label: widget.expression,
        // LayoutBuilder 只为拿"这一格实际有多宽"并把它交给回落文本；
        // 它**不再包住 `Math.tex(...)` 那行构造**，否则文件头第 16 条又回来了。
        child: LayoutBuilder(
          builder: (context, constraints) => _LatexWidthScope(
            width: constraints.maxWidth,
            // 这一格外面就有 `Semantics(label: 源码)` ⇒ 告诉回落文本别再往语义树塞第二份
            labeled: true,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.antiAlias,
              // 超长公式横向可滚，不许把气泡撑出屏幕右边界（#128 那一族毛病）。
              // `ExcludeSemantics`：`Math` 里面**每个字形都是一个带语义的 RichText**
              // （`make_symbol.dart:136`，它自己 lib/ 里 `ExcludeSemantics` 命中 0），
              // 外面那条 `Semantics(label: 源码)` 一加，读屏就变成"念源码＋逐个念碎片"
              // （第六轮第 3 条）。碎片到底念不念得出来只有真机读屏判得了（J 系列），
              // 这一格先钉住"我们已经把这一层关掉"这个事实。
              child: ExcludeSemantics(child: _math),
            ),
          ),
        ),
      );
}

/// 把"这一格实际多宽"传进公式子树——只在回落那一路用得到。
///
/// 为什么不用构造参数：那个宽度是**逐帧的布局事实**，而 `Math` 实例（连里面的回落 widget）
/// 现在要跨帧复用；把宽度塞进构造函数就等于每变一次宽造一个 `Math` ＝ 重解一遍。
/// `InheritedWidget` 让依赖它的子树自己重绘，`Math` 实例一个字都不用动。
class _LatexWidthScope extends InheritedWidget {
  const _LatexWidthScope({
    required this.width,
    required this.labeled,
    required super.child,
  });

  final double width;

  /// 这一格的祖先里是不是已经有一层 `Semantics(label: 源码)`。
  /// 回落文本自己也是 `Text`，会往语义树里再塞一份同样的字 ⇒ 读屏念两遍
  /// （第五轮扫描第 3 条）。有 label 的时候就把自家这份关掉，没有的时候留着——
  /// 尺寸闸／超长／空白那三路是**直接**交回回落文本的，没有外层 label，
  /// 关掉语义就等于让那一格对读屏消失，那是把缺陷改成另一个缺陷。
  final bool labeled;

  static _LatexWidthScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_LatexWidthScope>();

  @override
  bool updateShouldNotify(_LatexWidthScope oldWidget) =>
      oldWidget.width != width || oldWidget.labeled != labeled;
}

/// 解析失败／不该解析 ⇒ 原样把 LaTeX 文本摆出来（可读、可复制、不抛、不空白）。
///
/// 宽度从 [_LatexWidthScope] 现取：这一格如果站在横向 `SingleChildScrollView` 的 child
/// 位上，拿到的约束是 `maxWidth=∞`（SDK `single_child_scroll_view.dart:457`）
/// ⇒ 一段中文正文会以"不换行、超出部分被裁"的样子摆出来，要横拖才读得完（扫描 B-1 第二半）；
/// 不在那个位置（超长／空白／尺寸闸那三条）时没有 scope，沿用段落约束自然折行。
class _LatexFallback extends StatelessWidget {
  const _LatexFallback({required this.expression});

  final String expression;

  @override
  Widget build(BuildContext context) {
    final scope = _LatexWidthScope.maybeOf(context);
    Widget text = Text(expression, style: DefaultTextStyle.of(context).style);
    final width = scope?.width;
    if (width != null && width.isFinite) {
      // `maxWidth` 而不是 `SizedBox(width:)`：紧约束会让这一格恒等于整行宽，
      // 外层 `Wrap`（builder.dart:827）于是必然给它另起一行 ⇒ 「错的是」／大块空白／「这一句」。
      text = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: text,
      );
    }
    if (scope?.labeled != true) return text;
    // 公式格里面：外层已经有 `Semantics(label: 源码)`，自家这份 `Text` 就不要再念一遍。
    return ExcludeSemantics(child: text);
  }
}

// （这里原来住着 `_dollarAtIsCloser`，第七轮第 1 条把它删了：猜"前面是不是闭合号"
// 在段里出现过一条 `$…$` 之后恒真 ⇒ B-2 那道闸整条失效。判据改由
// [LatexInlineSyntax._lastCloserAt] 记消费位置，见上面那两个字段的注释。）

String? _firstUsedGroup(Match match) {
  for (var i = 1; i <= match.groupCount; i++) {
    final group = match.group(i);
    if (group != null) return group;
  }
  return null;
}

LatexDelimiter? _delimiterOf(
    String matched, List<LatexDelimiter> delimiters) {
  for (final candidate in delimiters) {
    if (matched.length > candidate.left.length + candidate.right.length &&
        matched.startsWith(candidate.left) &&
        matched.endsWith(candidate.right)) {
      return candidate;
    }
  }
  return null;
}
