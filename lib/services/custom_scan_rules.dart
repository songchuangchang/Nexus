/// 用户自定义扫描规则（build98 安全审查本地加强⑥）
///
/// 存储在应用支持目录 `custom_scan_rules.json`，格式与远程 rules.json 的
/// rules 数组一致。LocalScanService._getEffectiveRules 合并时追加
/// （ID 前缀建议 UR-，与内置 LS-/远程规则区分）。
///
/// build99（验收 N6）：加数量/长度上限——自定义规则每次安装扫描全量跑正则，
/// 无上限会被塞到卡顿、扩大 ReDoS 面。
library custom_scan_rules;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'local_scan_service.dart';
import 'logger_service.dart';

class CustomScanRules {
  static final LoggerService _logger = LoggerService.instance;
  static const String _fileName = 'custom_scan_rules.json';

  /// 上限（build99 验收 N6）：条数 / 单条正则长度 / 标题长度
  static const int maxRules = 50;
  static const int maxPatternLength = 500;
  static const int maxTitleLength = 100;

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<List<LocalScanRule>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final data = jsonDecode(await f.readAsString());
      final list = data is List ? data : (data['rules'] as List? ?? []);
      final rules = list
          .map((e) => LocalScanRule.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((r) =>
              r.id.isNotEmpty &&
              r.pattern.isNotEmpty &&
              r.pattern.length <= maxPatternLength &&
              r.title.length <= maxTitleLength)
          .toList();
      // 兜底：文件被外部编辑塞爆时截断（正则全量跑是同步开销）
      if (rules.length > maxRules) {
        _logger.warn(
            '自定义规则超上限 ${rules.length} 条，截断到 $maxRules',
            tag: 'CustomRules');
        return rules.take(maxRules).toList();
      }
      return rules;
    } catch (e) {
      _logger.warn('自定义规则读取失败: $e', tag: 'CustomRules');
      return [];
    }
  }

  static Future<void> save(List<LocalScanRule> rules) async {
    final f = await _file();
    await f.writeAsString(
        jsonEncode({'version': 1, 'rules': rules.map((r) => r.toJson()).toList()}));
  }

  /// 添加（同 id 覆盖）。返回 null=成功，否则返回给用户看的错误文案。
  static Future<String?> add(LocalScanRule rule) async {
    if (rule.pattern.length > maxPatternLength) {
      return '规则正则过长（超过 $maxPatternLength 字符）';
    }
    if (rule.title.length > maxTitleLength) {
      return '规则标题过长（超过 $maxTitleLength 字符）';
    }
    final rules = await load();
    final replacing = rules.any((r) => r.id == rule.id);
    if (!replacing && rules.length >= maxRules) {
      return '自定义规则已达上限（$maxRules 条），请先删除部分规则';
    }
    rules.removeWhere((r) => r.id == rule.id);
    rules.add(rule);
    await save(rules);
    return null;
  }

  static Future<void> remove(String id) async {
    final rules = await load();
    rules.removeWhere((r) => r.id == id);
    await save(rules);
  }
}
