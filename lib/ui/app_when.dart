/// "这件事发生在什么时候"那一行字的**唯一所有者**（build182 / #159 第三、四条）。
///
/// ## 为什么要立这一条
/// 用户 10-03 在平板上逐屏看的时候报的第 3 条是"列表右侧那个时间看不懂"。回读代码，
/// 全仓有**两处**各说各的时间口径：
///  · `chat_screen.dart` 的 `_fmtDayLabel`：今天 / 昨天 / MM月dd日（跨年补年）—— 消息流里的日期头；
///  · `conversation_list_screen.dart:829`：`'${conv.updatedAt.hour}:${minute.padLeft(2,'0')}'`
///    —— 会话列表右侧那一格。它**只有时分、没有日期**：上周那条对话写着 `9:05`，
///    看着像"刚刚"；而且 `hour` 没补零 ⇒ 同一列里 `9:05` 与 `09:05` 两种宽度并存。
/// 这就是"同一个事实两个口径"的第三种形态（前两种是高度与宽度）。列表这一格真正要回答的
/// 不是"几点"，而是"哪一天、那一天里几点"，所以它必须复用日期头那一条判据，而不是自己再拼一次。
///
/// ## 档位取自厂商共性（不是自己发明）
/// 今天→时分、昨天→"昨天"、本周内→星期、今年内→月日、跨年→补年。
/// 这五档是微信/Telegram/系统短信列表共同的形状（越近越具体、越远越粗）；
/// 本项目原来那条日期头已经覆盖了后三档，这里只把前两档接上，**不重定义**它。
///
/// ## 为什么 [now] 是参数
/// 与 `lib/ui/app_elapsed.dart` 同一条教训：拿 `DateTime.now()` 现取的文案函数**没法单测**
/// （"思考过程 58225 秒"就是躲过只能断言常量存在的护栏活下来的）。所以这两个函数都吃
/// 显式 `now`，跨日/跨周/跨年三条边界能在单测里逐格判。
abstract final class AppWhen {
  /// 日期头那一档：今天 / 昨天 / MM月dd日（跨年补年份）。
  ///
  /// 这一条是**从 `chat_screen._fmtDayLabel` 原样搬过来的**，措辞与补零规则一字未改
  /// （改了就是把已装机版本的文案偷偷挪动）。
  static String dayLabel(DateTime dt, bool isZh, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final diff = dayGap(dt, n);
    if (diff == 0) return isZh ? '今天' : 'Today';
    if (diff == 1) return isZh ? '昨天' : 'Yesterday';
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    if (dt.year != n.year) {
      return isZh ? '${dt.year}年$mm月$dd日' : '${dt.year}-$mm-$dd';
    }
    return isZh ? '$mm月$dd日' : '$mm-$dd';
  }

  /// 跨了几个**日历日**。
  ///
  /// 为什么不是 `DateTime(y,m,d)` 相减再取 `inDays`（这是 10-04 扫描席报的 P1，
  /// 我回读后确认成立）：那两个"本地零点"之间的小时数在**实行夏令时的地区**不是 24 的整数倍
  /// —— 春季推进那天两格零点只差 **23 小时**，`inDays` 是截断的 ⇒ 差 0 ⇒
  /// 昨天的对话写着"今天"，正是 #159 第三条抱怨的那个形状。
  /// 走 `DateTime.utc` 是把时区这条变量整个摘掉：utc 日历没有夏令时，差值恒为 24h 的整数倍。
  /// 中国没有夏令时，所以用户这台机上两种写法同形 —— 但这个 App 不是只给一台机用的。
  static int dayGap(DateTime older, DateTime newer) =>
      DateTime.utc(newer.year, newer.month, newer.day)
          .difference(DateTime.utc(older.year, older.month, older.day))
          .inDays;

  /// 列表右侧那一格：越近越具体。
  ///
  /// 未来时间（服务器时钟偏、手动改过系统时间）不报错、不显示负数：退到"时分"那一档，
  /// 与今天同形 —— 这一格是**提示**，不是判据，宁可少说也不能说反。
  static String listRow(DateTime dt, bool isZh, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final diff = dayGap(dt, n);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    if (diff <= 0) return '$hh:$mi'; // 今天（含时钟超前的"稍后"）
    // 「昨天」那一档**转手给 dayLabel**：这条措辞不许在这个文件里出现两次，
    // 否则本函数就是它的第二个所有者（同一个文件里也能犯这条毛病）。
    // `now: n` 而不是 `now: now`（10-04 扫描席第二条）：传那个**可能为 null**的入参
    // ＝让 dayLabel 再现取一次时钟 ⇒ 一行代码读两次表。跨过午夜那一瞬，
    // 这一格会先按 A 判档、再按 B 出文案，同一行里出现两种口径。
    if (diff == 1) return dayLabel(dt, isZh, now: n);
    if (diff < 7) {
      // 本周内：星期。zh 用"周一"，en 用三字母缩写（列表那一格宽度有限）。
      const zh = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      const en = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return isZh ? zh[dt.weekday - 1] : en[dt.weekday - 1];
    }
    return dayLabel(dt, isZh, now: n);
  }
}
