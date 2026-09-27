import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'security_gate.dart';

/// build101（C3 深度阅读）：网页正文抽取。
///
/// **为什么不能直接把搜索摘要喂给模型**：搜索 API 只回 1~2 行 snippet，
/// 深度研究时模型拿到的信息量严重不足，容易把摘要的措辞当成事实。
/// 本服务抓取搜索结果指向的真实页面并抽正文，让「联网搜索」真正看到内容。
///
/// 抽取策略（不引 html 解析库，保持零新增依赖）：
/// 1. 用正则剥掉 `script/style/noscript/svg/iframe/head` 等非正文区块
/// 2. 优先在 `<article>` / `<main>` / `role="main"` 容器内取文本
/// 3. 退化时全文档取文本，按块级标签切段
/// 4. 按「行密度」过滤掉导航/侧栏/页脚短行，保留长段落
/// 5. HTML 实体反转义 + 空白归一
class ArticleExtractor {
  static const _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0 Mobile Safari/537.36';

  /// 抓取并抽取正文。失败返回 null（调用方静默降级到 snippet）。
  ///
  /// [maxBytes] 限制下载量，避免误抓大文件（视频/压缩包）把内存打爆。
  static Future<({String title, String text})?> fetch(
    String url, {
    int maxBytes = 512 * 1024,
    Duration timeout = const Duration(seconds: 20),
    http.Client? client,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    // build146（行业分歧安全批 ①）·纵深防御第二道：**抓取前**再过一次私网闸。
    // 为什么这里还要判一遍：`isFetchable` 与 `fetch` 之间隔着调用方
    // （`builtin_plugins.dart::_deepReadTopResults` 先 where 后 map），
    // 待抓清单在别处拼装 ⇒ 只修判定函数等于把安全性外包给"调用方记得调用"。
    // 与本仓库既有做法一致：ws_download 在发请求前先过 SecurityGate（auditUrl），
    // 这条读回通道此前谁都没过。
    if (isPrivateTarget(url)) return null;
    final own = client == null;
    final c = client ?? http.Client();
    try {
      final req = http.Request('GET', uri)
        ..headers['User-Agent'] = _ua
        ..headers['Accept'] =
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
        ..headers['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8';
      final streamed = await c.send(req).timeout(timeout);
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) return null;
      final ctype = streamed.headers['content-type'] ?? '';
      if (!ctype.contains('html') && !ctype.contains('text')) return null;

      final bytes = <int>[];
      await for (final chunk in streamed.stream) {
        bytes.addAll(chunk);
        if (bytes.length >= maxBytes) break;
      }
      if (bytes.isEmpty) return null;
      final html = _decodeBytes(bytes, ctype);
      return extract(html, baseUrl: url);
    } catch (e) {
      return null;
    } finally {
      if (own) c.close();
    }
  }

  /// 从 HTML 字符串抽正文（离线可用，便于单测）。
  static ({String title, String text})? extract(
    String html, {
    String baseUrl = '',
  }) {
    if (html.trim().isEmpty) return null;
    final title = _extractTitle(html);

    // 1) 剥非正文区块
    var body = html;
    for (final tag in const [
      'script',
      'style',
      'noscript',
      'svg',
      'iframe',
      'head',
      'nav',
      'footer',
      'aside',
      'form',
      'button',
      'select',
    ]) {
      body = body.replaceAll(
        RegExp('<$tag\\b[^>]*>[\\s\\S]*?</$tag>', caseSensitive: false),
        ' ',
      );
      // 自闭合/未闭合兜底
      body = body.replaceAll(RegExp('<$tag\\b[^>]*/?>', caseSensitive: false), ' ');
    }

    // 2) 优先取语义容器
    final container = _pickContainer(body);

    // 3) 块级标签 → 换行，剥掉剩余标签
    var text = container
        .replaceAll(
            RegExp(
                r'</(p|div|section|article|main|h[1-6]|li|tr|br|blockquote|pre)>',
                caseSensitive: false),
            '\n')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), ' ');
    text = _unescape(text);
    text = _cleanLines(text);
    if (text.length < 80) return null;
    return (title: title, text: text);
  }

  /// 在候选语义容器里选文本最长的那个（正文通常在 article/main 里）。
  static String _pickContainer(String body) {
    final candidates = <String>[];
    for (final pattern in const [
      r'<article\b[^>]*>([\s\S]*?)</article>',
      r'<main\b[^>]*>([\s\S]*?)</main>',
      r'<div\b[^>]*role\s*=\s*"main"[^>]*>([\s\S]*?)</div>',
      r'<div\b[^>]*class\s*=\s*"[^"]*(?:article|content|post|entry|markdown|body)[^"]*"[^>]*>([\s\S]*?)</div>',
      r'<div\b[^>]*id\s*=\s*"[^"]*(?:article|content|post|entry|markdown|body)[^"]*"[^>]*>([\s\S]*?)</div>',
    ]) {
      for (final m in RegExp(pattern, caseSensitive: false).allMatches(body)) {
        final g = m.group(1);
        if (g != null && g.trim().isNotEmpty) candidates.add(g);
      }
    }
    if (candidates.isEmpty) return body;
    candidates.sort((a, b) => b.length.compareTo(a.length));
    return candidates.first;
  }

  static String _extractTitle(String html) {
    for (final pattern in const [
      r'<meta[^>]+property\s*=\s*"og:title"[^>]+content\s*=\s*"([^"]*)"',
      r'<meta[^>]+content\s*=\s*"([^"]*)"[^>]+property\s*=\s*"og:title"',
      r'<title[^>]*>([\s\S]*?)</title>',
      r'<h1[^>]*>([\s\S]*?)</h1>',
    ]) {
      final m = RegExp(pattern, caseSensitive: false).firstMatch(html);
      final t = m?.group(1);
      if (t != null && t.trim().isNotEmpty) {
        return _unescape(t.replaceAll(RegExp(r'<[^>]+>'), ' ')).trim();
      }
    }
    return '';
  }

  /// 按行清理：去短行（导航/侧栏碎片），合并连续空行。
  ///
  /// 阈值 24 字符：正文段落极少短于这个长度，而导航链接几乎都短于它。
  /// 首行不受限（标题常常很短）。
  static String _cleanLines(String text) {
    final lines = text.split('\n').map((s) => s.trim()).toList();
    final out = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final ln = lines[i].replaceAll(RegExp(r'[ \t]+'), ' ');
      if (ln.isEmpty) {
        if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
        continue;
      }
      final isCjk = RegExp(r'[\u4e00-\u9fff]').hasMatch(ln);
      final minLen = isCjk ? 12 : 24;
      if (i > 0 && ln.length < minLen) continue;
      out.add(ln);
    }
    final joined = out.join('\n');
    return joined.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static String _decodeBytes(List<int> bytes, String ctype) {
    // charset 优先从 header，其次从 HTML meta，最后按 UTF-8 兜底
    try {
      final m = RegExp(r'charset=([\w-]+)', caseSensitive: false)
          .firstMatch(ctype);
      final cs = m?.group(1)?.toLowerCase();
      if (cs == 'gbk' || cs == 'gb2312' || cs == 'gb18030') {
        return _decodeGbk(bytes);
      }
      if (cs == 'latin1' || cs == 'iso-8859-1') {
        return latin1.decode(bytes, allowInvalid: true);
      }
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// GBK 解码：Dart 标准库不含 GBK 表，这里用「按 UTF-8 试解 + 无效字节丢弃」
  /// 的保守方案，保证不抛异常。中文站点主流已 UTF-8，命中率低不影响主流程。
  static String _decodeGbk(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// HTML 实体反转义（覆盖常见命名实体 + 全部数字实体）。
  static String _unescape(String s) {
    var out = s;
    const named = {
      '&nbsp;': ' ',
      '&amp;': '&',
      '&lt;': '<',
      '&gt;': '>',
      '&quot;': '"',
      '&#39;': "'",
      '&apos;': "'",
      '&mdash;': '—',
      '&ndash;': '–',
      '&hellip;': '…',
      '&ldquo;': '“',
      '&rdquo;': '”',
      '&lsquo;': '‘',
      '&rsquo;': '’',
      '&middot;': '·',
      '&times;': '×',
      '&laquo;': '«',
      '&raquo;': '»',
      '&copy;': '©',
      '&reg;': '®',
      '&trade;': '™',
      '&deg;': '°',
    };
    named.forEach((k, v) => out = out.replaceAll(k, v));
    // 数字实体：&#123; / &#x1F600;
    out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final cp = int.tryParse(m.group(1)!, radix: 16);
      return cp == null ? m.group(0)! : String.fromCharCode(cp);
    });
    out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final cp = int.tryParse(m.group(1)!);
      return cp == null ? m.group(0)! : String.fromCharCode(cp);
    });
    return out;
  }

  /// 供 OCR / 附件服务复用：判断是否为可抓取的公开网页
  static bool isFetchable(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return false;
    if (!(u.isScheme('http') || u.isScheme('https'))) return false;
    if (u.host.isEmpty) return false;
    // build146（行业分歧安全批 ①）：深度阅读的 URL 来自**网页搜索结果**，
    // 而搜索结果可被 SEO 投毒 ⇒ 这是一条由外部可控目标构成的读回通道，
    // 此前只过 scheme + 扩展名，等于没过 SSRF 闸（`http://127.0.0.1:8000/api`
    // 会直接被去抓本机服务）。闸复用仓库里已有的**句法**私网判定
    // 与本仓库 ws_download 用的是**同一个**主机判定（它经 SecurityGate.auditUrl
    // 间接调 isPrivateHost，这里直连——auditUrl 会真发 HEAD 请求且强制 https，
    // 深度阅读要的正是"只判主机、不预发请求"）。
    // 覆盖：回环 / RFC1918 / CGNAT 100.64/10 / IPv6 ULA·链路本地·
    // IPv4-mapped / 数字化主机文本形态（127.1、2130706433、0x7f000001）。
    //
    // **http:// 仍然放行**（有意为之，不是漏网）：正文源是公网站点，
    // 大量中小站与老页面没有 https，禁 http 会让深度阅读直接退化成摘要；
    // 本机自己的 AI 端点是否走 http 与这条通道无关（那是 api_service 的事）。
    // 代价与边界：放行 http ⇒ 明文抓取可被中间人改写，但**私网闸对 http
    // 与 https 同等生效**，所以「借道抓本机/内网服务」这条 SSRF 主路径已断。
    //
    // 已核（不在本次射程，别当已修）：这道闸是句法闸、**不做 DNS**（做 DNS 会
    // 引入 TOCTOU/DNS rebinding 窗口，理由见 security_gate.dart::isPrivateHost
    // 的文档注释，此处不重述）⇒ 一个解析到 127.0.0.1 的域名照样能过闸。
    // 要堵这一层得靠出口网络策略/代理白名单。
    if (isPrivateTarget(url)) return false;
    // 排除明显是文件下载的 URL
    final lower = url.toLowerCase();
    for (final ext in const [
      '.pdf',
      '.zip',
      '.rar',
      '.7z',
      '.apk',
      '.exe',
      '.dmg',
      '.mp4',
      '.mp3',
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
    ]) {
      if (lower.endsWith(ext)) return false;
    }
    return true;
  }

  /// 目标主机是否落在私网/回环/保留段（纯函数，可单测）。
  ///
  /// fail-closed：URL 解析不了、host 为空 ⇒ 按私网处理（交调用方拒抓），
  /// 与 SecurityGate 的「不能确信是公网就当私网」口径一致。
  static bool isPrivateTarget(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return true;
    // `isPrivateHost` 上的 @visibleForTesting 是 build138 为了「这道闸此前
    // 没有任何可断言入口」才加的（见 security_gate.dart:353-376 的注释），
    // 它本身就是 auditUrl 在生产路径里用的同一个函数——不是测试专用替身。
    // 这里直接复用它：另写一份私网判定就是第二个漏网的闸。
    // ignore: invalid_use_of_visible_for_testing_member
    return SecurityGate.isPrivateHost(u.host);
  }

  /// 判断当前是否处于离线环境（用于提前放弃，避免每个 URL 都等超时）
  static Future<bool> hasConnectivity() async {
    try {
      final r = await InternetAddress.lookup('example.com')
          .timeout(const Duration(seconds: 3));
      return r.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
