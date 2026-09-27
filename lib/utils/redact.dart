/// build153：备份导出与日志落盘共用的**按值/按形态**密钥脱敏（纯函数集）。
///
/// 为什么需要它（本仓已复发三次）：
///   v1.4.3 Bug#5（4 个 *ApiKey 只处理了 tavilyApiKey）、build138 P1-1
///   （virusTotalApiKey/mobsfApiKey 又漏）、build146（密钥根本不在字段名里，
///   而在 `extra.endpoint` 的 URL query 里）。**按字段名剥敏只能命中写代码那天
///   想到的名字**，所以这里补一层与名字无关的兜底：认形态不认字段。
///
/// 识别的形态：
///   1. `sk-…` / `pk-…` / `rk-…` / `gsk-…` 等厂商前缀 Key（OpenAI/Anthropic/DeepSeek 形状）
///   2. `Bearer ` / `Basic ` 段（含 base64 的 `+` `/` `=` 字符）
///   3. `Authorization` 行/头（多行安全：`(?im)`，token 字符类不含换行）
///   4. URL query / 表单里的 `?key=` `&token=` 等凭据位
///   5. JSON 片段中 `"api_key": "<value>"` 型字段（整值替换）
///   6. 整串即长 base64ish 不透明 token（≥32 位混合字符；canonical UUID 放行，
///      否则会把 messages/conversations 主键剥花，恢复路径就断了）
///
/// 替换约定：命中即替换成 [kRedactedPlaceholder]，**不保留原长度信息**；
/// 结构（键、类型、数组长度、其余值）一律不动 ⇒ 恢复路径照旧能读。
library;

const String kRedactedPlaceholder = '__REDACTED__';

/// 字段名兜底（深度遍历时用）：常规密钥字段名仍然优先整值替换
final RegExp secretNameRe = RegExp(
    r'(?:apikey|api_key|token|secret|password|passwd|credential|authorization)$',
    caseSensitive: false);

/// canonical UUID（8-4-4-12-12）——本仓主键形态，**不许**当不透明 token 剥掉
final RegExp _uuidStrictRe = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// 整串形态的长 base64ish 不透明 token
final RegExp _opaqueTokenRe = RegExp(r'^[A-Za-z0-9_\-+/]{32,}={0,2}$');

// ---- 内联形态（对任意文本生效；字符类都不含 \n，天然多行安全） ----
// 注意：Dart RegExp 不支持 `(?i)` 内联标志，大小写/多行一律走构造参数。

/// `Authorization: Bearer xxx` / 裸 `Bearer xxx` / `Basic <base64 含 +/>`
final RegExp _bearerRe =
    RegExp(r'\b(Bearer|Basic)[ \t]+([A-Za-z0-9+\/=_\-]{8,})',
        caseSensitive: false);

/// `Authorization` 头行（多行文本里逐行命中：multiLine + `^` 行首锚定，
/// token 字符类不含 `\n`）。兼容 `"Authorization": "…"` /
/// `'Authorization': 'Bearer …'`（Dart Map.toString 落日志就是单引号形态）。
final RegExp _authHeaderLineRe = RegExp(
    "^([ \\t]*(?:\"|')?Authorization(?:\"|')?[ \\t]*[:=][ \\t]*(?:\"|')?"
    "(?:[ \\t]*(?:Bearer|Basic)[ \\t]+)?)"
    "(?!(?:Bearer|Basic)\\b)([A-Za-z0-9+/=_-]{4,})",
    caseSensitive: false,
    multiLine: true);

/// 厂商/搜索服务商前缀 Key 形状：sk-/sk-ant-/sk-proj-/pk-/rk-/gsk-/ant-、
/// tvly-/tavily-/serpapi-/brave-/deepseek-/qwen- 等
final RegExp _prefixedKeyRe = RegExp(
    r'\b(?:sk|pk|rk|gsk|ant|sky|tvly|tavily|serpapi|brave|deepseek|qwen|vllm|glm|msk)'
    r'[_\-][A-Za-z0-9_\-]{10,}\b');

/// GitHub / Slack 形状
final RegExp _githubSlackRe = RegExp(
    r'\b(?:ghp|gho|ghu|ghr|ghs|github_pat|xox[baprs])[_\-][A-Za-z0-9_\-]{6,}\b');

/// AWS Access Key ID
final RegExp _awsAkiaRe = RegExp(r'\bAKIA[0-9A-Z]{16}\b');

/// URL query / 表单凭据位：?key= &api_key= &token= &access_token= &secret=
final RegExp _querySecretRe = RegExp(
    "([?&](?:key|api[_-]?key|token|access_token|secret|password)=)"
    "([^&#\\s\"'<>]+)",
    caseSensitive: false);

/// JSON / 类 JSON 片段里的密钥字段整值：`"apiKey": "<value>"`
final RegExp _jsonSecretFieldRe = RegExp(
    r'("(?:api[_-]?key|apikey|access[_-]?token|token|secret|password'
    r'|authorization|client[_-]?secret)"\s*:\s*")((?:[^"\\]|\\.)*)(")',
    caseSensitive: false);

/// build154（第 12 轮网络审计 B3 确证后由我补的这一支）：**URL 的 userinfo 段**。
/// WebDAV 允许把凭据直接写在 URL 里（`https://user:应用密码@host/dav`），
/// 而 baseUrl 这个串本身会进日志（失败时 `'$e'` 里带 URL）也会进备份导出 ——
/// 形态表以前只罩 `Bearer`/`?key=`/JSON 字段，**URL userinfo 是漏的**。
/// 口径：只剥密码、**保留用户名**（排查"是哪个账号连错"要用），
/// 且必须有 scheme ⇒ 裸 `a:b@c`（邮箱、`host:8080/path`）一律不匹配，避免误伤。
final RegExp _urlUserinfoRe =
    RegExp(r'([A-Za-z][A-Za-z0-9+.\-]*://)([^/\s:@]+):([^/\s@]+)@');

/// 对任意文本做按形态脱敏（日志单点写前过滤、备份字符串值共用）。
/// 多行输入逐行/逐段生效：token 字符类不含 `\n`，头行模式为 multiLine 逐行锚定。
String redactSecretsInText(String input) {
  if (input.isEmpty) return input;
  var s = input;
  // 头行最先：`Authorization: <非 Bearer 前缀的裸 token>` 也能命中
  s = s.replaceAllMapped(
      _authHeaderLineRe, (m) => '${m.group(1)}$kRedactedPlaceholder');
  s = s.replaceAllMapped(
      _bearerRe, (m) => '${m.group(1)} $kRedactedPlaceholder');
  s = s.replaceAllMapped(_prefixedKeyRe, (_) => kRedactedPlaceholder);
  s = s.replaceAllMapped(_githubSlackRe, (_) => kRedactedPlaceholder);
  s = s.replaceAllMapped(_awsAkiaRe, (_) => kRedactedPlaceholder);
  // URL userinfo：`scheme://user:pass@host` → `scheme://user:__REDACTED__@host`
  // （在 query/JSON 之前跑没关系：两者字符类不重叠，顺序只影响可读性）
  s = s.replaceAllMapped(_urlUserinfoRe,
      (m) => '${m.group(1)}${m.group(2)}:$kRedactedPlaceholder@');
  s = s.replaceAllMapped(
      _querySecretRe, (m) => '${m.group(1)}$kRedactedPlaceholder');
  s = s.replaceAllMapped(_jsonSecretFieldRe, (m) {
    final v = m.group(2)!;
    // 已脱敏的值（旧契约的 xxxx***xxxx / 占位符）原样通过：幂等，且
    // 不吞掉 logger_scrub_test 锁定的 `"Bearer ***…"` 历史格式
    if (v.isEmpty || v == kRedactedPlaceholder || v.contains('***')) {
      return m.group(0)!;
    }
    return '${m.group(1)}$kRedactedPlaceholder${m.group(3)}';
  });
  return s;
}

/// 整串形态判定：一个**独立字符串值**是否本身就是密钥
/// （内联形态先走；再判长 base64ish；canonical UUID 放行）。
String redactSecretValue(String v) {
  if (v.isEmpty) return v;
  final inline = redactSecretsInText(v);
  if (inline != v) return inline;
  if (_uuidStrictRe.hasMatch(v)) return v;
  if (_opaqueTokenRe.hasMatch(v) && _isMixedCharacterSecret(v)) {
    return kRedactedPlaceholder;
  }
  return v;
}

/// 长 token 还须"混合"（含字母 + 数字或符号），避免把纯数字/纯字母长串误伤
bool _isMixedCharacterSecret(String v) =>
    v.contains(RegExp('[A-Za-z]')) &&
    (v.contains(RegExp('[0-9]')) || v.contains(RegExp(r'[+/_=-]')));

/// 深度遍历 JSON 结构（Map/List/String/标量）：
///   - Map：键名命中 [secretNameRe] 且值为非空字符串 ⇒ 整值替换；
///     其余值递归。**键、类型、数组长度全部原样保留**（结构不坏）。
///   - String：走 [redactSecretValue]。
///   - 标量（int/bool/null）：原样。
Object? redactSecretsDeep(Object? node) {
  if (node is String) return redactSecretValue(node);
  if (node is Map) {
    return <dynamic, dynamic>{
      for (final e in node.entries) e.key: _redactMapValue(e.key, e.value),
    };
  }
  if (node is List) {
    return node.map(redactSecretsDeep).toList();
  }
  return node;
}

Object? _redactMapValue(Object? k, Object? v) {
  if (k is String &&
      secretNameRe.hasMatch(k) &&
      v is String &&
      v.isNotEmpty) {
    return kRedactedPlaceholder;
  }
  return redactSecretsDeep(v);
}
