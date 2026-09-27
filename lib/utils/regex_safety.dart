/// 把**别人给的文本**当正则跑之前的一道静态闸（build157，第 15 轮扫描 P1）。
///
/// 为什么必须有：`ws_grep` 的 pattern 是模型写的，`RegExp(p)` 只在**语法**上会抛
/// `FormatException`，**代价**上没有任何保护 —— 全仓唯一的兜底是"整条 pattern 长度上限"。
/// 实测 `^(a+)+b` 配 32 个字符的输入要 **113 秒**，而这行代码跑在 UI isolate 上
/// （`workspace_service.dart` 的 grep 循环里 `re.hasMatch(line)`），
/// 于是 App 整个冻死，且用户看不出为什么。32 个字符 = 一行普通文本。
///
/// 这道闸只拦"嵌套量词"这一族（正则引擎灾难性回溯的经典形状，`(a+)+` / `(a*)*` /
/// `(|a){2,}` 等）：**能静态判定**、**误杀面小**（正常检索极少这么写）、
/// 且拦下时报错文案直接教模型改写成人能跑的形态。
///
/// 它不是完备的：`(a|ab)+` 这类"分支共享前缀又被重复"的形状仍会漏
/// （那需要判定分支间的前缀关系，属于另一个量级的实现）。漏的那些由
/// [grepTimeBudget] 那种**时间预算**兜住 —— 两道闸的分工写在这，别以为有一道就够。
library;

/// 命中风险时返回**给人看的原因**，安全返回 null。
///
/// 不追求解析尽一切写法：语法错误这里一律放行（返回 null），因为下一步
/// `RegExp(p)` 本来就会抛 `FormatException` 并回一条现成的错误 —— 抢它的活只会多一处会写歪的地方。
String? catastrophicBacktrackRisk(String pattern) {
  // 栈：每层"体内是否出现过量词"。
  final frames = <bool>[];
  var classDepth = 0; // >0 表示在 [ ] 字符类里，内部一律不按结构解析

  void markInner() {
    if (frames.isNotEmpty) frames[frames.length - 1] = true;
  }

  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == r'\') {
      i++; // 转义符吃掉下一个字符
      continue;
    }
    if (classDepth > 0) {
      if (c == ']') classDepth--;
      continue;
    }
    switch (c) {
      case '[':
        classDepth++;
        break;
      case '(':
        frames.add(false);
        break;
      case ')':
        if (frames.isEmpty) return null; // 括号不配对 → 交给 RegExp 报语法错
        final hadQuantifier = frames.removeLast();
        final rep = _repeatLenAt(pattern, i + 1);
        if (rep == 0) break;
        i += rep - 1; // 量词整体消费掉，避免后面的循环把 `+` 再数一遍
        if (hadQuantifier) {
          return '分组内部已含量词，整个分组又被重复（嵌套量词）';
        }
        markInner(); // 重复过的分组本身成为"含量子的原子"
        break;
      case '*':
      case '+':
        markInner();
        break;
      case '?':
        break; // `?` 是 0/1 次，不构成重复爆炸
      case '{':
        final rep = _braceLenAt(pattern, i);
        if (rep == 0) break;
        if (_braceIsRepetitive(pattern.substring(i, i + rep))) {
          markInner();
        }
        i += rep - 1;
        break;
      default:
        break;
    }
  }
  return null;
}

/// `i` 处开始是不是一个"重复量词"（`*` `+` `{n,}` / `{n,m}` 且 m-n ≥ 1 或无上界）。
/// 返回要跳过的长度，0 表示不是。
int _repeatLenAt(String s, int i) {
  if (i >= s.length) return 0;
  final c = s[i];
  if (c == '*') {
    return 1 + (_nextIsLazy(s, i + 1) ? 1 : 0);
  }
  if (c == '+') {
    return 1 + (_nextIsLazy(s, i + 1) ? 1 : 0);
  }
  if (c == '{') {
    final len = _braceLenAt(s, i);
    if (len == 0) return 0;
    if (!_braceIsRepetitive(s.substring(i, i + len))) return 0;
    var extra = len;
    if (_nextIsLazy(s, i + extra)) extra += 1;
    return extra;
  }
  return 0;
}

bool _nextIsLazy(String s, int i) => i < s.length && s[i] == '?';

/// `{...}` 的完整长度（含花括号），不合法返回 0。
int _braceLenAt(String s, int i) {
  final close = s.indexOf('}', i);
  if (close < 0) return 0;
  final body = s.substring(i + 1, close);
  if (body.isEmpty || body.length > 13) return 0;
  final parts = body.split(',');
  if (parts.length > 2) return 0;
  for (final p in parts) {
    if (p.isEmpty) continue;
    if (!RegExp('^[0-9]+\$').hasMatch(p)) return 0;
  }
  return close - i + 1;
}

/// `{2}` 这种固定次数不会放大回溯（只重复一次判定）；`{2,}` / `{2,5}` 会。
bool _braceIsRepetitive(String brace) {
  final body = brace.replaceAll(RegExp('[{}]'), '');
  final parts = body.split(',');
  if (parts.length == 1) return false; // {n} 固定
  final min = parts[0].isEmpty ? 0 : int.tryParse(parts[0]) ?? 0;
  if (parts[1].isEmpty) return true; // {n,} 无上界
  final max = int.tryParse(parts[1]) ?? min;
  return max - min >= 1;
}

/// 给"扫很多行"的正则用武之力预算：每处理 [checkEvery] 行问一次是否超预算。
///
/// 抽成纯函数是为了能被单测钉住（`nowMs` 由调用方给，不在这里读时钟）。
/// 超预算时调用方必须**明说被截断**，绝不能把"没扫完"报成"没命中"——
/// 后者是用户会照着做决定的假事实。
bool grepOverBudget(
        {required int startedAtMs, required int nowMs, required int budgetMs}) =>
    nowMs - startedAtMs > budgetMs;
