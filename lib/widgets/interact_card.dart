import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/biometric_service.dart';
import '../ui/tokens.dart';
import '../utils/app_snackbar.dart';
import '../utils/launcher_utils.dart';

/// v1.7.38 build90（第 3 步）：聊天流富交互卡片 `<card>` 协议。
///
/// 对标千问「对话内小屏幕」：AI 在 <answer> 里输出
/// `<card type="..." title="...">JSON</card>`，气泡渲染时提取成原生
/// 交互卡片（选项/订单/支付三类），敏感操作只落到「待确认」，
/// 最终一步必须用户亲手点（支付跳转走生物锁守卫）。
///
/// 卡片标签保留在消息 content 里随 DB 持久化，渲染期提取，零迁移。

/// 单张卡片解析结果。type ∈ {options, order, pay}。
class InteractCardData {
  const InteractCardData({
    required this.type,
    required this.title,
    required this.data,
  });

  final String type;
  final String title;
  final Map<String, dynamic> data;
}

/// `<card ...>...</card>` 块匹配（属性宽松顺序 + 大小写不敏感）。
final _cardBlockRe = RegExp(
  r'<card\b([^>]*)>([\s\S]*?)</card\s*>',
  caseSensitive: false,
);

/// 从消息 content 里提取全部卡片块。
///
/// 返回 (剥离卡片后的 markdown 正文, 卡片列表)；JSON 解析失败的块
/// 原样保留在正文里（可见=可调试，不静默吞）。
(String, List<InteractCardData>) splitCardBlocks(String content) {
  // build97 (P2-12 修复)：守卫与解析正则一致用大小写不敏感，
  // 否则模型输出 <Card> 时卡片不渲染、原始标签留在气泡。
  if (!content.toLowerCase().contains('<card')) return (content, const []);
  final cards = <InteractCardData>[];
  var text = content;
  for (final m in _cardBlockRe.allMatches(content)) {
    final attrs = m.group(1) ?? '';
    final body = (m.group(2) ?? '').trim();
    String grab(String k) {
      final am = RegExp('$k="([^"]*)"', caseSensitive: false).firstMatch(attrs);
      return (am?.group(1) ?? '').trim();
    }

    final type = grab('type').toLowerCase();
    final title = grab('title');
    if (type.isEmpty) continue;
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      continue; // JSON 坏 → 保留原文
    }
    if (decoded is! Map<String, dynamic>) continue;
    cards.add(InteractCardData(type: type, title: title, data: decoded));
    text = text.replaceFirst(m.group(0)!, '');
  }
  return (text.trim(), cards);
}

/// 卡片本体渲染（V2 朴素风 tokens）。
class InteractCard extends StatelessWidget {
  const InteractCard({
    super.key,
    required this.card,
    required this.zh,
    this.onQuickReply,
  });

  final InteractCardData card;
  final bool zh;
  final void Function(String text)? onQuickReply;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(top: AppGap.sm),
      padding: AppPad.card,
      decoration: BoxDecoration(
        color: cs.appPanelLight,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: cs.appBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconFor(card.type), size: 16, color: cs.appTextSub),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  card.title.isEmpty ? _defaultTitle(zh) : card.title,
                  style: tt.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600, color: cs.appTextSub),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppGap.sm),
          ..._buildBody(context, cs, tt),
        ],
      ),
    );
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'options':
        return Icons.compare_arrows_outlined;
      case 'order':
        return Icons.receipt_long_outlined;
      case 'pay':
        return Icons.account_balance_wallet_outlined;
    }
    return Icons.dashboard_outlined;
  }

  String _defaultTitle(bool zh) => zh ? '卡片' : 'Card';

  List<Widget> _buildBody(BuildContext context, ColorScheme cs, TextTheme tt) {
    switch (card.type) {
      case 'options':
        return _buildOptions(cs, tt);
      case 'order':
        return _buildOrder(cs, tt);
      case 'pay':
        return _buildPay(context, cs, tt);
    }
    return [
      Text(zh ? '未知卡片类型：${card.type}' : 'Unknown card type: ${card.type}',
          style: tt.bodySmall?.copyWith(color: cs.appTextSub)),
    ];
  }

  /// 比价/选项选择卡：每行一个可点选项，点选即以快捷回复发送
  ///
  /// build139（真机反馈④同源排查）：**兼容 `options:["A","B"]` 这种纯字符串数组**。
  /// 原写法只有 `if (raw is Map)` 一支，模型按更省事的形式吐一串字符串时，
  /// 整张卡片渲染成"有标题、里面空的"——没有一行可点、也没有一句原因，
  /// 用户看到的就是「推荐用不了」（本仓库口径：A 级静默降级）。
  /// 现在：字符串按 label 渲染；既无 Map 也无字符串时，明确写出缺了什么。
  /// 「没拿到可选项」的人话说法：这句会直接落在 AI 气泡正文里，所以不写
  /// options / label 这类协议术语（用户会把它当成 AI 的回答继续读）。
  String get _noOptionsMsg => zh
      ? '这张卡片没拿到可选项，请直接回复文字'
      : 'No options here — please reply with text';

  List<Widget> _buildOptions(ColorScheme cs, TextTheme tt) {
    final options = card.data['options'];
    if (options is! List || options.isEmpty) {
      return [_missing(_noOptionsMsg, cs, tt)];
    }
    final rows = <Widget>[];
    // 同名字段两种写法混用时（`[{"label":"A"}, "A"]` 是模型常给的形态）去重，
    // 否则一张卡里出现两行一模一样的可点项。
    final seenLabels = <String>{};
    for (final raw in options) {
      // 两个分支**都要** trim：Map 分支原先漏了，`{"label":"   "}` 就通过
      // `label.isEmpty` 那道闸 ⇒ 渲染出一行"只有箭头、没有字"的可点空行，
      // 点下去把一串空白当答案发回模型（用户体感仍是"推荐点了没反应"）。
      final label =
          (raw is Map ? '${raw['label'] ?? ''}' : (raw is String ? raw : ''))
              .trim();
      if (label.isEmpty || !seenLabels.add(label)) continue;
      final detail =
          raw is Map ? '${raw['detail'] ?? ''}'.trim() : '';
      final price = raw is Map ? '${raw['price'] ?? ''}'.trim() : '';
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: AppGap.xs),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.inline),
            onTap: onQuickReply == null
                ? null
                : () => onQuickReply!('${zh ? '我选择' : 'I choose'}：$label'),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              // build139 扫描：宿主没传 onQuickReply 时这一行点不动，那就**不许**
              // 再画描边和箭头 —— "看着能点、点了没反应"正是本仓库的 A 级静默降级。
              decoration: onQuickReply == null
                  ? null
                  : BoxDecoration(
                      borderRadius: BorderRadius.circular(AppRadius.inline),
                      border: Border.all(color: cs.appBorder),
                    ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: tt.bodyMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        if (detail.isNotEmpty)
                          Text(detail,
                              style:
                                  tt.bodySmall?.copyWith(color: cs.appTextSub),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  if (price.isNotEmpty) ...[
                    const SizedBox(width: AppGap.sm),
                    Text(price,
                        style:
                            tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  ],
                  if (onQuickReply != null) ...[
                    const SizedBox(width: AppGap.xs),
                    Icon(Icons.chevron_right,
                        size: 18, color: cs.appTextSub),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (rows.isEmpty) {
      return [
        // 协议层的说法（每项要有 label，或直接给字符串）留在上面的文档注释里，
        // 写给下一个 AI 看，不写给用户看。
        _missing(_noOptionsMsg, cs, tt),
      ];
    }
    return rows;
  }

  /// 订单/状态卡：k-v 行展示
  List<Widget> _buildOrder(ColorScheme cs, TextTheme tt) {
    final rows = card.data['rows'];
    if (rows is! List || rows.isEmpty) {
      return [_missing(zh ? '缺少 rows 数组' : 'missing rows array', cs, tt)];
    }
    return [
      for (final raw in rows)
        if (raw is Map)
          Padding(
            padding: const EdgeInsets.only(bottom: AppGap.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${raw['k'] ?? ''}',
                    style: tt.bodySmall?.copyWith(color: cs.appTextSub)),
                const SizedBox(width: AppGap.sm),
                Expanded(
                  child: Text('${raw['v'] ?? ''}',
                      style: tt.bodyMedium,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
    ];
  }

  /// 支付确认卡：金额+收款方+确认按钮（跳转走生物锁守卫，绝不静默支付）
  List<Widget> _buildPay(BuildContext context, ColorScheme cs, TextTheme tt) {
    final amount = '${card.data['amount'] ?? ''}';
    final payee = '${card.data['payee'] ?? ''}';
    final url = '${card.data['url'] ?? ''}';
    return [
      Text(amount.isEmpty ? '-' : amount,
          style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
      if (payee.isNotEmpty)
        Text(zh ? '收款方：$payee' : 'Payee: $payee',
            style: tt.bodySmall?.copyWith(color: cs.appTextSub)),
      const SizedBox(height: AppGap.sm),
      SizedBox(
        width: double.infinity,
        child: FilledButton.tonal(
          onPressed: url.isEmpty
              ? null
              : () async {
                  // B1（N-9）：第三通道此前是裸 Uri.tryParse + launchUrl，
                  // **无 percent-encode** —— 高德导航链 `toName=朱村地铁站`
                  // 等中文 query 在 Android Intent 层拉起失败（弹框却跳不动）。
                  // 现统一过归一入口（与 LauncherUtils/链接弹层同一实现）。
                  final uri = LauncherUtils.normalizeLaunchUri(url);
                  if (uri == null) {
                    if (context.mounted) {
                      AppSnackBar.showSnackBar(context, SnackBar(
                        content: Text(zh
                            ? '链接格式无效，无法打开'
                            : 'Invalid link, cannot open'),
                        backgroundColor: cs.error,
                      ));
                    }
                    return;
                  }
                  try {
                    // 与外链守卫同款：防锁屏状态被拉起支付页面
                    await BiometricService.guardActivityTransition(
                      () =>
                          launchUrl(uri, mode: LaunchMode.externalApplication),
                      fallbackDuration: const Duration(seconds: 120),
                    );
                  } catch (e) {
                    // build98（P2）：支付跳转失败给用户反馈，不再静默吞掉
                    debugPrint('支付跳转失败: $e');
                    if (context.mounted) {
                      AppSnackBar.showSnackBar(context, SnackBar(
                        content: Text(zh
                            ? '无法打开支付页面：$e'
                            : 'Failed to open payment page: $e'),
                        backgroundColor: cs.error,
                      ));
                    }
                  }
                },
          child: Text(zh ? '确认支付（跳转外部）' : 'Confirm & open externally'),
        ),
      ),
    ];
  }

  Widget _missing(String msg, ColorScheme cs, TextTheme tt) =>
      Text(msg, style: tt.bodySmall?.copyWith(color: cs.appTextSub));
}
