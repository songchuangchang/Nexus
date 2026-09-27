/// 模型名清洗工具（v1.7.18 需求5）
///
/// 把原始模型 ID（如 `claude-3-5-sonnet-20241022`）清洗为可读显示名
///（如 `Claude 3.5 Sonnet`），供 ModelSwitcher 收起态与下拉项使用。
///
/// 清洗规则（决策 Q3/Q4 已锁）：
///   1. 去尾部日期后缀：`-20241022`（紧凑）/ `-2024-10-22`（带分隔）
///   2. 已是友好名（含空格）→ 仅去日期后缀，原样返回
///   3. `-` / `_` → 空格，分割 token
///   4. 相邻单数字 token 合并为 `X.Y`（如 3,5 → 3.5）
///   5. 每 token 规范化：已知厂商用规范名，混合大小写保留原样，
///      全小写首字母大写（数字开头不变）
///
/// 正则禁用 `(?i)`/`(?s)` 内联标志（release 必崩，铁律），
/// 大小写无关用 toLowerCase() 预小写匹配。
/// 本期仅内置 5 个主流厂商映射，未覆盖厂商退化为「去日期+连字符转空格+
/// 首字母大写」，原样返回保证可读不报错。
class ModelNameCleaner {
  ModelNameCleaner._();

  /// 内置厂商规范化映射（小写键 → 规范显示名）
  static const Map<String, String> _vendorMap = <String, String>{
    'claude': 'Claude',
    'gpt': 'GPT',
    'deepseek': 'DeepSeek',
    'gemini': 'Gemini',
    'qwen': 'Qwen',
  };

  /// 紧凑日期后缀 `-YYYYMMDD`（8 位连续数字）
  static final RegExp _compactDateSuffix = RegExp(r'-\d{8}$');

  /// 带分隔日期后缀 `-YYYY-MM-DD`
  static final RegExp _dashedDateSuffix = RegExp(r'-\d{4}-\d{2}-\d{2}$');

  /// 连字符/下划线分隔（连续多个合并）
  static final RegExp _separator = RegExp(r'[-_]+');

  /// 单个数字
  static final RegExp _singleDigit = RegExp(r'^\d$');

  /// 小写字母（用于首字母大写判定）
  static final RegExp _lowerLetter = RegExp(r'[a-z]');

  /// 清洗模型名。
  ///
  /// 输入空串返回空串；输入已是友好名（含空格）仅去日期后缀原样返回。
  static String cleanModelName(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return s;

    // 1) 去尾部日期后缀
    var name = s;
    if (_dashedDateSuffix.hasMatch(name)) {
      name = name.replaceAll(_dashedDateSuffix, '');
    } else if (_compactDateSuffix.hasMatch(name)) {
      name = name.replaceAll(_compactDateSuffix, '');
    }

    // 2) 已是友好名（含空格）→ 原样返回
    if (name.contains(' ')) return name;

    // 3) 连字符/下划线 → 空格，分割 token
    final tokens = name.split(_separator).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) return name;

    // 4) 相邻单数字 token 合并为 X.Y
    final merged = <String>[];
    for (final tk in tokens) {
      if (merged.isNotEmpty &&
          _singleDigit.hasMatch(merged.last) &&
          _singleDigit.hasMatch(tk)) {
        merged[merged.length - 1] = '${merged.last}.$tk';
      } else {
        merged.add(tk);
      }
    }

    // 5) 每 token 规范化后用空格拼接
    return merged.map(_normalizeToken).join(' ');
  }

  /// 单 token 规范化：已知厂商→规范名；混合大小写→保留；全小写→首字母大写。
  static String _normalizeToken(String tk) {
    if (tk.isEmpty) return tk;
    final low = tk.toLowerCase();
    final canonical = _vendorMap[low];
    if (canonical != null) return canonical;
    // 已含大写字母（混合大小写）→ 保留原样（如 72B / 4o / Instruct / Qwen2.5）
    if (_hasUpperCase(tk)) return tk;
    // 全小写 token → 首字母大写（如 sonnet→Sonnet, pro→Pro, chat→Chat）
    final first = tk[0];
    if (_lowerLetter.hasMatch(first)) {
      return first.toUpperCase() + tk.substring(1);
    }
    return tk; // 数字开头，原样
  }

  /// 判断字符串是否含大写字母 A-Z。
  static bool _hasUpperCase(String s) {
    for (final unit in s.codeUnits) {
      if (unit >= 65 && unit <= 90) return true; // 'A'=65, 'Z'=90
    }
    return false;
  }
}
