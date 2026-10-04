import 'package:flutter/foundation.dart';

import 'logger_service.dart';

/// 刀二（浏览器四个动作）的**验收线格式**：线格式就是契约。
///
/// 为什么要这么早把格式定下来（而不是等外壳写完再补）：
/// WebView 渲染出来的东西**不进 uiautomator 语义树**（10-01 19:2x 真机取证：截图上大字标题与按钮
/// 都画出来了，同一时刻的树只有 16 个外壳节点、标记串命中 0）⇒ J 系列现有的
/// `expect_visible`／`absent` 读的就是这棵树，对这四个动作**按构造量不到**。
/// 唯一不依赖树、又能在真机上 grep 的通道就是这行日志。
///
/// 两条从 build169／178 交过的学费，这里当场用掉：
/// 1. **格式变了机械不报错、只会静默读到 0 条** ⇒ 字段名与顺序由
///    `test/build180_browser_action_log_test.dart` 逐字钉住，并配反向闸（改字段名／丢前缀都必须红）；
/// 2. **通道选错比没修更贵** ⇒ 这一行只报**数量与状态**：页面正文、元素文字、URL 一律不进日志
///    （签名层面就不给它们留参数，见测试里那把源码锁）。
const String kBrowserActionLogTag = 'BrowserAction';

/// `web act` 的结果词表——**闭集**。执行体只能填这几个值之一；
/// 填了表外的值会退成 `outcome=unknown`，机械侧一眼分得开"没执行"与"执行了但结果词写错"。
///
/// 第七轮扫描（入口面第 5 条）拆掉两处复用：旧表里 `reject_domain` 的**唯一写入点**其实
/// 是"blob／data 链接不自动下载"那一路 ⇒ 拿它统计域名闸必然得出反向数；
/// `not_found` 也被 JS 抛异常那一路复用 ⇒ "序号错"与"通道挂了"分不开。
/// 第五轮扫描（两席同报一条，B#7）再走一步：**`reject_domain` 现在没有生产者了**
/// （域名拒绝改由 `web navigate` 那行的 `why=domain` 报），留着它＝词表里一个死词，
/// 照表数 `outcome=reject_domain` 的人恒得 0，与刚修那个毛病是镜像 ⇒ 删。
/// 另外把 `read`／`act`／`back` 的"页面没开"与"宿主熔断"两条早退也纳入落行（A#5／B#1，
/// 第五轮扫描第 6 条补完：过去只有 `navigate` 做到每条出口都落行），所以这里补
/// `page_not_open` 与 `circuit_break` 两个词。
/// **落法分三路，别记成一套**（这三条线的字段集合本来就不一样，硬要统一会逼着改线格式）：
///  · `web act` 走 `outcome=page_not_open`／`outcome=circuit_break`（本表这两个词就是给它用的）；
///  · `web navigate` 走 `gated=1 why=page_not_open`／`why=circuit_break`（见 [kWebNavigateRejects]）；
///  · `web read` 没有 outcome 位 ⇒ 落一行**全 0**；`web back` 落 `ok=0 reread=0 failed=0`。
///    后两条线的"被拦了"只能由「有一行」＋「数量为 0」合起来读，这是线格式的既有边界，
///    不是漏接线（要合流就得给 read/back 加字段＝改契约，与仓外遍历同批做，已登账）。
const List<String> kWebActOutcomes = <String>[
  'ok', // 动作已派发给 WebView
  'reject_download', // blob／data 链接：不自动触发下载，转人工
  'reject_password', // 密码框：AI 不代填，转人工（§4.3）
  'reject_paused', // 人类接管中，AI 停手
  'reject_reread', // 接管刚交还，必须先 web_read 再动（§五.3）
  'not_found', // 模型给的元素序号在这一次快照里不存在
  'dispatch_error', // JS 派发本身抛了（通道故障，不是模型给的序号错）
  'page_not_open', // 浏览器页没开（没有 controller）
  'circuit_break', // 宿主给的步数上限到了
];

/// 结果词表之外的值统一落到这里，好让机械侧不用猜。
const String kWebActOutcomeUnknown = 'unknown';

/// `web act` 那行里 `tag` 的**契约长度上限**（理由见 [formatWebAct] 的文档：再长就会被
/// 日志层的通用脱敏洗成带 `*` 的值，锚定正则静默失效）。
const int kWebActTagMaxLen = 24;

/// `web navigate` 里 `why=` 的词表——**闭集**，只在 `gated=1` 时有意义（否则写 `none`）。
/// 五个值一一对应派发之前的五种退回，缺一个就有一族失败在机械侧与别的族混成一样。
const List<String> kWebNavigateRejects = <String>[
  'page_not_open', // 浏览器页没开（没有 controller）
  'circuit_break', // 宿主给的步数上限到了
  'permit', // 许可闸：接管中／快照不可信／总闸关着
  'address', // 地址闸：非 https、内网、解析不出来
  'domain', // 域名确认：用户没允许这一个站
];

/// `web read seq=3 chars=4210 full=9120 truncated=1 interactive=17 omitted=4`
///
/// `chars`＝本次真正交给模型的字符数；`full`＝截断**前**的全文长度
/// （两者不等就证明"喂给 AI 的页面"被削过，这是 §五.3 里 AI 会答得比屏幕上少的唯一解释）。
@visibleForTesting
String formatWebRead({
  required int seq,
  required int chars,
  required int fullChars,
  required bool truncated,
  required int interactive,
  required int omitted,
}) {
  return 'web read seq=$seq chars=$chars full=$fullChars '
      'truncated=${truncated ? 1 : 0} interactive=$interactive omitted=$omitted';
}

/// `web act seq=4 idx=12 tag=button outcome=ok`
///
/// `tag` 是 DOM 标签名（`button`／`input`…），属控件属性、不含用户数据。
/// 第七轮浏览器扫描（入口面第 4 条）改的是**字符集**：标签名来自
/// `web_dom_serializer.dart:162` 的 `el.tagName.toLowerCase()`，而那份选择器
/// （`:94`）含 `[role="button"]` ⇒ 任何自定义元素（`ion-button`、`vaadin-date-picker`、
/// `<my-toggle>`）都能进清单，而锚定正则原来只认 `[A-Za-z0-9]+` ⇒ **整行静默读不到**
/// （正是本文件第 13-15 行声明要防的那类事故，且是"部分页面读得到、部分读不到"这种
/// 最坏的样子：验收会得出"这一页 AI 没动手"的假结论）。
/// 收敛规则：空白与非 `[A-Za-z0-9_]` 一律换成 `_`，**保持行内一个空格都不出现**，
/// 同时让**长度以内**的不同标签收敛成不同的值（`ion-button` 与 `ion:button` 不会撞成一个空串）。
/// 还要**封顶 [kWebActTagMaxLen] 个字符**（第六轮扫描第 7 条）：`logger_service.dart` 那条
/// 通用长 token 脱敏（`<内网路径>)<内网路径>`）会把**任何 32 个字符及以上的
/// 那串字符**洗成 `abcd***wxyz`，而它在 `_buffer.add` 与写文件之前就跑 ⇒ 一个长自定义元素名
/// （`my_company_date_range_picker` 这一类）出来就是带 `*` 的值，`webActLineRx` 就此
/// **静默读不到**，现象与"这一页 AI 没动手"一模一样。自定义元素名没有长度上限，
/// 所以这一格不能靠"标签一般不长"：上限写进契约，判据两头钉（长的必须被截、短的必须原样）。
/// **这一刀不是无损的**（第七轮扫描第 3 条，如实记在这里）：只留前
/// [kWebActTagMaxLen] 个字符，意味着**前 24 个字符相同、要到后面才分开的两个长标签，
/// 落进日志就是同一个值**（`my_company_date_range_picker_v1` 与 `…_v2` 一模一样）——
/// 上面那句"不同的标签收敛成不同的值"只对**长度以内**成立，超限那一段换的就是唯一性。
/// 这条不算缺陷也不算待办：那一行的验收只看「动没动、动了几次、成没成」，
/// 行内唯一的键是 `seq`，位置键是 `idx`（DOM 清单里的下标），`tag` 只当"动的什么一类元素"的提示。
/// 写下来是给下一个读它的人**别以为截断还保唯一**：保唯一那条锁钉在长度以内，
/// 超限那一边钉的是"必须截到 24、且不许带 `*`"，两回事。
@visibleForTesting
String formatWebAct({
  required int seq,
  required int idx,
  required String tag,
  required String outcome,
}) {
  final String collapsedTag =
      tag.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  final String safeTag = collapsedTag.length <= kWebActTagMaxLen
      ? collapsedTag
      : collapsedTag.substring(0, kWebActTagMaxLen);
  final String safeOutcome =
      kWebActOutcomes.contains(outcome) ? outcome : kWebActOutcomeUnknown;
  return 'web act seq=$seq idx=$idx tag=$safeTag outcome=$safeOutcome';
}

/// `web navigate seq=2 ok=1 gated=0 why=none main_fail=0`
///
/// **为什么第七轮才补这一行**（入口面第 3 条）：文件头一直自称"四个动作的验收线格式"，
/// 实现却只有 read／act／back 三条，`web_navigate` 的方法体里 `logWeb*` 出现 0 次
/// ——包括**域名闸拒掉那一次**。四个动作里唯一会开窗口、唯一会弹授权框的那一个，
/// 在真机上一个字都不留，而 `web_browser_plugins.dart` 向模型承诺"每次执行恰好落一行"。
/// 更糟的是旧判据把这个洞**钉成了正确**（断言 tag 与 LogCat 各"恰好 3 处"）。
///
/// 字段只报状态，`host` 是 URL 的一部分、按本文件的签名层口径**不进日志**。
///  * `ok`＝这一跳真的把 URL 交给了 WebView（不代表加载完成）；
///  * `gated`＝派发之前就被退回，一次都没动；
///  * `why`＝**被谁退回**的闭集词（见 [kWebNavigateRejects]）。没有这一格，`gated=1`
///    把"页面没开／熔断／没许可／地址不合法／域名没被允许"五件事并成一个数，
///    而这正是入口面第 5 条报的那个毛病：`web act` 里 `reject_domain` 实际只由
///    "下载被拦"写入 ⇒ 拿日志统计域名闸，得出的数**只可能来自错的来源**。
///  * `main_fail`＝等完了主帧仍然报失败（缺陷三那一族的机械侧读数）。
@visibleForTesting
String formatWebNavigate({
  required int seq,
  required bool ok,
  required bool gated,
  required String why,
  required bool mainFrameFailure,
}) {
  final String safeWhy = gated ? (kWebNavigateRejects.contains(why) ? why : 'unknown') : 'none';
  return 'web navigate seq=$seq ok=${ok ? 1 : 0} gated=${gated ? 1 : 0} '
      'why=$safeWhy main_fail=${mainFrameFailure ? 1 : 0}';
}

/// `web back seq=5 ok=1 reread=1 failed=0`
///
/// `reread=1` 是**必须**的下一步提醒：后退之后页面快照作废，AI 得先 `web_read`（§五.3）。
/// `failed=1`＝退到的那一页主帧报了加载失败（第五轮扫描第 5 条）。为什么 `ok` 与 `failed`
/// 要分成两个字段而不是把 `ok` 写成 0：`ok` 讲的是"平台那一下退成了没有"，
/// `failed` 讲的是"退到的那一页是坏的"——合成一个字段就再也分不开
/// "没有历史可退"与"退到了坏页"，而这两件事的回法完全不同（前者换动作，后者如实告诉用户）。
/// 这一格是**扩字段**（老格式没有 `failed`），仓外的遍历只按 `BrowserAction` 这个 tag 数行、
/// 不解析字段名，所以同批不用改它；改的是本文件那把锚定正则与 `build180` 的逐字钉。
@visibleForTesting
String formatWebBack({
  required int seq,
  required bool ok,
  required bool reread,
  required bool failed,
}) {
  return 'web back seq=$seq ok=${ok ? 1 : 0} reread=${reread ? 1 : 0} '
      'failed=${failed ? 1 : 0}';
}

/// 四个执行体真正调用的入口：拼一行 + 落日志。
///
/// 类别选 `react`：这四行是"模型动了什么"的流水，与思考面板/排查同一条时间线，
/// 不该混进 UI 那一路（UI 里已经有 `CopyFeedback` 那种人眼可见反馈）。
void logWebRead({
  required int seq,
  required int chars,
  required int fullChars,
  required bool truncated,
  required int interactive,
  required int omitted,
}) {
  LoggerService.instance.info(
    formatWebRead(
      seq: seq,
      chars: chars,
      fullChars: fullChars,
      truncated: truncated,
      interactive: interactive,
      omitted: omitted,
    ),
    cat: LogCat.react,
    tag: kBrowserActionLogTag,
  );
}

void logWebAct({
  required int seq,
  required int idx,
  required String tag,
  required String outcome,
}) {
  LoggerService.instance.info(
    formatWebAct(seq: seq, idx: idx, tag: tag, outcome: outcome),
    cat: LogCat.react,
    tag: kBrowserActionLogTag,
  );
}

void logWebBack({
  required int seq,
  required bool ok,
  required bool reread,
  required bool failed,
}) {
  LoggerService.instance.info(
    formatWebBack(seq: seq, ok: ok, reread: reread, failed: failed),
    cat: LogCat.react,
    tag: kBrowserActionLogTag,
  );
}

/// `web_navigate` 的那一行。**每一条 return 路径都必须经过它**，否则机械侧
/// 分不开"没动手"与"动了但被拦"——那正是本文件存在的全部理由。
void logWebNavigate({
  required int seq,
  required bool ok,
  required bool gated,
  required String why,
  required bool mainFrameFailure,
}) {
  LoggerService.instance.info(
    formatWebNavigate(
      seq: seq,
      ok: ok,
      gated: gated,
      why: why,
      mainFrameFailure: mainFrameFailure,
    ),
    cat: LogCat.react,
    tag: kBrowserActionLogTag,
  );
}

/// 机械侧（`tablet_sweep`）读这四条线用的锚定正则——**每种动作一条，整行锚死**。
///
/// 为什么不做成一条"合并式"：合并式为了兼容四种动作，尾部只能写成宽松的字符类，
/// 结果 `truncated=true`、多一个空格、尾部多一节字段 全都还算命中——
/// 这正是本仓 build169 那条教训的形状（格式漂了机械不报错，只是静默读错）。
/// 首版就在这种地方咬住，别等功能写完再补。
///
/// ⚠ **这四条尺量的是"载荷"，不是日志文件里的那一行**（第五轮扫描·入口面第 3 条）：
/// `logger_service.dart:301-312` 写出去的行是
/// `2026-…T… [INFO][REACT][BrowserAction] web act seq=…`——带时间戳与三个方括号前缀，
/// 而下面每一条都以 `^web ` 起手且不带 `multiLine` ⇒ **拿它们去 `hasMatch` 一行真日志恒假**。
/// 真读日志要用 [webActionPayloadOf]（先把前缀切掉）或 [isWebActionLine]（内部就按这个顺序做）。
/// 现有的仓外探针之所以没出事，是因为它们各自用 `"BrowserAction" in l` 与
/// `re.search(r"web (read|act|back)")` 凑了个近似版——那既漏 `web navigate`，也不校验字段。
@visibleForTesting
final RegExp webReadLineRx = RegExp(
    r'^web read seq=[0-9]+ chars=[0-9]+ full=[0-9]+ truncated=[01] '
    r'interactive=[0-9]+ omitted=[0-9]+$');

@visibleForTesting
final RegExp webActLineRx =
    RegExp(r'^web act seq=[0-9]+ idx=[0-9]+ tag=[A-Za-z0-9_]+ outcome=\w+$');

@visibleForTesting
final RegExp webBackLineRx =
    RegExp(r'^web back seq=[0-9]+ ok=[01] reread=[01] failed=[01]$');

@visibleForTesting
final RegExp webNavigateLineRx = RegExp(
    r'^web navigate seq=[0-9]+ ok=[01] gated=[01] '
    r'why=(?:none|page_not_open|circuit_break|permit|address|domain|unknown) '
    r'main_fail=[01]$');

/// 从**一行真日志**里切出载荷：去掉 `时间戳 [LEVEL][CAT][BrowserAction] ` 那一段前缀。
///
/// 不是"这行含 BrowserAction 就算数"：切完之后还要过下面四条锚定正则，字段漂了照样读不出。
/// 返回 null ＝ 这一行不是浏览器动作日志。前缀按 `logger_service` 的
/// `lineParts.join(' ')` 形状剥（第一个方括号串之前的全部，加上那些方括号本身）。
String? webActionPayloadOf(String logLine) {
  // 载荷一定以 `web read`／`web act`／`web back`／`web navigate` 起手；
  // 所以先定位这个标记，再取到行尾——比"数方括号"稳（等级与类别的个数会变）。
  final int at = RegExp(r'\bweb (?:read|act|back|navigate) seq=').firstMatch(logLine)?.start ??
      -1;
  if (at < 0) return null;
  return logLine.substring(at);
}

/// 四选一（**含 navigate**，第五轮才补齐）：给机械侧做"这行是不是浏览器动作日志"的粗筛。
/// 细字段各自用上面四条锚定正则，输入是 [webActionPayloadOf] 切出来的载荷。
bool isWebActionLine(String line) {
  final String? payload = webActionPayloadOf(line) ?? (line.isEmpty ? null : line);
  if (payload == null) return false;
  return webReadLineRx.hasMatch(payload) ||
      webActLineRx.hasMatch(payload) ||
      webBackLineRx.hasMatch(payload) ||
      webNavigateLineRx.hasMatch(payload);
}
