/// 真机诊断探针：**切后台那一段，流到底还在不在收**。
///
/// ## 为什么装这个（不猜第八轮）
///
/// 用户报（2026-09-24）：「思考中如果退出去，灵动岛已经出现了，但它会一直卡住；
/// 等回去之后，它又会继续思考。」这句话有两种完全不同的成因，修法互斥：
///
/// · **甲：进程活着、SSE 还在收**，只是岛没有任何独立心跳
///   （`live_task_center.dart` 里只有一个终态保留用的 `Timer`，
///   `LiveTaskService.kt` 里 `Handler`/`postDelayed` 计数为 0）
///   ⇒ 修法是在原生侧打 tick。
/// · **乙：整个进程被 Android 冻结**（OEM 省电/Doze 绕过前台服务），token 压根没到
///   ⇒ 这时原生侧的 tick 会被**一起冻住**，甲那条修法写了等于没写。
///
/// 分辨只需一个数：**后台期间 chunk 计数的增量**。
/// 增量 > 0 ⇒ 甲；增量 == 0 且确实离开过 ≥ 10 秒 ⇒ 乙。
///
/// ## 边界
///
/// 纯计数 + 纯字符串拼装：不 import LoggerService、不碰插件通道、不起 Timer，
/// 所以 `api_service.dart` 调它不引入任何新依赖，测试里可以直接读写。
class StreamProbe {
  StreamProbe._();

  /// 累计收到的 SSE chunk 数（整个进程生命周期内单调增）。
  static int chunksTotal = 0;

  /// 最近一个 chunk 到达的时刻（未收到过为 null）。
  static DateTime? lastChunkAt;

  static int _chunksAtPause = 0;
  static DateTime? _pausedAt;

  /// 当前有几条流正在被消费（`ApiService.streamChat` 的 try 头 ++ / finally 尾 --）。
  ///
  /// build158 补这一层的**唯一理由是防我自己误判**：机主 09:58 那份导出里
  /// `07:40:20 离开 981s，一个 chunk 都没收到 ⇒ 乙：整条流在后台停摆`
  /// 与 `07:57:30 离开 1014s …` 两条都是**假阳性** —— 那两次出去时**压根没有流在跑**
  /// （上一轮早在 07:19:55 就结束了）。旧判据只看"chunk 增量为 0"，
  /// 而"没流"与"流被冻"都读成 0，却是一个根本不需要修的问题。
  /// 这正是本仓反复出现过的形状：**把「我不知道」压成一个看起来很具体的结论**。
  static int _activeStreams = 0;
  static bool _streamActiveAtPause = false;

  static void noteStreamStart() => _activeStreams++;

  /// 结束一条流。夹下限保护：async* 的 finally 在"没开始就被取消"这种边角也会跑到，
  /// 计数一旦掉到负数，后面所有 `streamActive` 判断都会失真。
  static void noteStreamEnd() {
    if (_activeStreams > 0) _activeStreams--;
  }

  static bool get streamActive => _activeStreams > 0;

  /// SSE 每收到一个 `delta` 就调一次（`api_service.dart` 的流读循环）。
  static void noteChunk([DateTime? at]) {
    chunksTotal++;
    lastChunkAt = at ?? DateTime.now();
  }

  /// `paused` 时记快照。重复 paused（假事件）只更新基线，不会丢数据。
  static void notePaused([DateTime? at]) {
    _chunksAtPause = chunksTotal;
    _streamActiveAtPause = _activeStreams > 0;
    _pausedAt = at ?? DateTime.now();
  }

  /// `resumed` 时取结论。**没记过 paused 就返回 null**（冷启动直接进前台不该写日志）。
  static String? noteResumed([DateTime? at]) {
    final started = _pausedAt;
    if (started == null) return null;
    final now = at ?? DateTime.now();
    final secs = now.difference(started).inSeconds;
    final delta = chunksTotal - _chunksAtPause;
    final active = _streamActiveAtPause;
    _pausedAt = null;
    _streamActiveAtPause = false;
    return verdictFor(
        secondsInBackground: secs, chunksDuringPause: delta, streamActive: active);
  }

  /// 判定口径单独拆出来，好在测试里逐条钉（含"多久以下不下结论"这条防误判）。
  ///
  /// 小于 10 秒的后台（切出去看一眼就回来）一律报「太短，不定性」——
  /// 那种情况下即使 chunk 没涨，也说明不了是被冻还是那一瞬本来就没数据。
  /// [streamActive] 是 build158 加的第二道闸：**出去时没有流在跑，就不许提"停摆"**。
  static String verdictFor({
    required int secondsInBackground,
    required int chunksDuringPause,
    required bool streamActive,
    int minSampleSeconds = 10,
  }) {
    if (!streamActive) {
      return '后台探针: 离开 ${secondsInBackground}s，期间没有流在跑 ⇒ 不定性'
          '（"chunk 没涨"在没有流的时候是常态，别再拿去当"后台停摆"的证据）';
    }
    if (secondsInBackground < minSampleSeconds) {
      return '后台探针: 离开 ${secondsInBackground}s，收到 $chunksDuringPause 个 chunk'
          '（不足 ${minSampleSeconds}s，不定性）';
    }
    if (chunksDuringPause > 0) {
      return '后台探针: 离开 ${secondsInBackground}s，仍收到 $chunksDuringPause 个 chunk'
          ' ⇒ 甲：进程活着、流在收，卡在岛的刷新（岛没有独立心跳）';
    }
    return '后台探针: 离开 ${secondsInBackground}s，**一个 chunk 都没收到**'
        ' ⇒ 乙：整条流在后台停摆（进程被冻结或网络被省电策略掐）；'
        '注意这种情况下给岛加原生 tick 也会被一起冻住，先解决保活';
  }

  /// 测试用：把探针复位到"没跑过"的状态。
  static void resetForTest() {
    chunksTotal = 0;
    lastChunkAt = null;
    _chunksAtPause = 0;
    _pausedAt = null;
    _activeStreams = 0;
    _streamActiveAtPause = false;
  }
}
