// v1.7.15：拆分自 settings_screen.dart 的 _buildSecurityScanSection（原 L1022-L1391）
//
// 目的：把安全审查设置从主 SettingsScreen 拆到独立 sub-screen，让 Switch 切换的
// 高度突变只发生在本页面里。
//
// 数据流：通过 Provider<StorageService> 直接读写 web_search_configs 表，自带 5 个
// TextEditingController + 3 个 _testing* 状态字段，不再依赖主 SettingsScreenState。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/web_search_config.dart';
import '../services/custom_scan_rules.dart';
import '../services/local_scan_service.dart';
import '../services/security_scan_service.dart';
import '../services/storage_service.dart';
import '../ui/tokens.dart';
import '../utils/launcher_utils.dart';
import 'security_audit_screen.dart';
import '../utils/app_snackbar.dart';

class SecurityScanSettingsScreen extends StatefulWidget {
  const SecurityScanSettingsScreen({super.key});

  @override
  State<SecurityScanSettingsScreen> createState() =>
      _SecurityScanSettingsScreenState();
}

class _SecurityScanSettingsScreenState
    extends State<SecurityScanSettingsScreen> {
  // v1.7.5 安全审查 controllers
  final TextEditingController _skillspectorEndpointCtrl =
      TextEditingController();
  final TextEditingController _mobsfEndpointCtrl = TextEditingController();
  // v1.7.10 本地扫描规则源
  final TextEditingController _localScanRulesUrlCtrl = TextEditingController();
  // v1.7.11 VirusTotal + MobSF API Key
  final TextEditingController _virusTotalApiKeyCtrl = TextEditingController();
  final TextEditingController _mobsfApiKeyCtrl = TextEditingController();

  // 自有 _searchCfg
  WebSearchConfig? _searchCfg;

  // 3 个测试连接状态字段
  bool _testingSkillSpector = false;
  bool _testingMobSF = false;
  bool _testingVirusTotal = false;

  // P2-3：远程规则同步状态
  bool _syncingRules = false;
  String? _syncResultMsg;
  bool _syncOk = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _skillspectorEndpointCtrl.dispose();
    _mobsfEndpointCtrl.dispose();
    _localScanRulesUrlCtrl.dispose();
    _virusTotalApiKeyCtrl.dispose();
    _mobsfApiKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final storage = context.read<StorageService>();
    final cfg = await storage.getWebSearchConfig();
    if (!mounted) return;
    setState(() {
      _searchCfg = cfg;
      _skillspectorEndpointCtrl.text = cfg.skillspectorEndpoint;
      _mobsfEndpointCtrl.text = cfg.mobsfEndpoint;
      _localScanRulesUrlCtrl.text = cfg.localScanRulesUrl;
      _virusTotalApiKeyCtrl.text = cfg.virusTotalApiKey;
      _mobsfApiKeyCtrl.text = cfg.mobsfApiKey;
    });
    // P2-3：进入页面自动同步远程规则
    if (cfg.localScanRulesUrl.isNotEmpty && cfg.enableLocalScan) {
      _syncRules();
    }
  }

  Future<void> _saveConfig() async {
    final cfg = _searchCfg;
    if (cfg == null) return;
    final newCfg = cfg.copyWith(
      skillspectorEndpoint: _skillspectorEndpointCtrl.text.trim(),
      mobsfEndpoint: _mobsfEndpointCtrl.text.trim(),
      localScanRulesUrl: _localScanRulesUrlCtrl.text.trim(),
      virusTotalApiKey: _virusTotalApiKeyCtrl.text.trim(),
      mobsfApiKey: _mobsfApiKeyCtrl.text.trim(),
    );
    setState(() => _searchCfg = newCfg);
    await context.read<StorageService>().saveWebSearchConfig(newCfg);
  }

  // P2-3：同步远程规则
  Future<void> _syncRules() async {
    if (_syncingRules) return;
    final url = _localScanRulesUrlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _syncingRules = true;
      _syncResultMsg = null;
    });
    final result = await LocalScanService.prefetchRules(url);
    if (!mounted) return;
    setState(() {
      _syncingRules = false;
      _syncOk = result.ok;
      _syncResultMsg = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final zh = l.locale.languageCode == 'zh';
    final cfg = _searchCfg;
    return Scaffold(
      appBar: AppBar(title: Text(l.tr('securityScan'))),
      body: cfg == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: _buildSection(l, colorScheme, cfg, zh),
            ),
    );
  }

  Widget _buildSection(
    AppLocalizations l,
    ColorScheme colorScheme,
    WebSearchConfig cfg,
    bool zh,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.appPanelLight,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: colorScheme.appBorder),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Row(
            children: [
              Icon(Icons.security_outlined, color: colorScheme.appTextSub),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      zh ? '安全审查' : 'Security Scan',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      zh
                          ? '本地规则扫描（默认开启，零配置）+ 可选 SkillSpector/MobSF 深度审查'
                          : 'Local rule scan (on by default, zero-config) + optional SkillSpector/MobSF deep scan',
                      style: TextStyle(
                          fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // v1.7.10：本地规则扫描开关（默认开，零配置）
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(zh ? '启用本地规则扫描' : 'Enable Local Rule Scan'),
            subtitle: Text(
              zh
                  ? '安装 Skill/MCP 前用内置规则离线检查（无需部署服务，仅供参考）'
                  : 'Offline rule-based check before installing Skill/MCP (no service needed, for reference)',
              style: const TextStyle(fontSize: 12),
            ),
            value: cfg.enableLocalScan,
            onChanged: (v) {
              setState(() => _searchCfg = cfg.copyWith(enableLocalScan: v));
              _saveConfig();
            },
          ),
          const SizedBox(height: 4),

          // v1.7.10：远程规则源 URL（预留，留空走内置规则）
          // P2-3：增强为默认 GitHub 仓库 + 自动同步 + 手动刷新
          Text(
            zh ? '远程规则源 URL（自动同步）' : 'Remote rules URL (auto-sync)',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _localScanRulesUrlCtrl,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: zh ? '规则 JSON 地址' : 'Rules JSON URL',
              hintText: zh
                  ? '默认 GitHub 仓库；留空使用内置规则'
                  : 'Default GitHub repo; empty = builtin only',
              prefixIcon: const Icon(Icons.rule_outlined, size: 18),
              suffixIcon: _syncingRules
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : _syncResultMsg != null
                      ? IconButton(
                          icon: Icon(
                            _syncOk ? Icons.check_circle : Icons.error,
                            size: 18,
                            color: _syncOk
                                ? colorScheme.primary
                                : colorScheme.error,
                          ),
                          tooltip: _syncResultMsg,
                          onPressed: null,
                        )
                      : null,
            ),
            keyboardType: TextInputType.url,
            onChanged: (_) {
              _saveConfig();
              _syncResultMsg = null;
            },
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _syncingRules ? null : _syncRules,
                icon: _syncingRules
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync, size: 16),
                label: Text(zh ? '立即同步' : 'Sync Now'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () {
                  const defaultUrl =
                      'https://fastly.jsdelivr.net/gh/songchuangchang/a11@main/rules.json';
                  _localScanRulesUrlCtrl.text = defaultUrl;
                  _saveConfig();
                  _syncRules();
                },
                icon: const Icon(Icons.restore, size: 16),
                label: Text(zh ? '重置默认' : 'Reset'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
            ],
          ),
          if (_syncResultMsg != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  _syncOk ? Icons.check_circle_outline : Icons.error_outline,
                  size: 14,
                  color: _syncOk ? colorScheme.primary : colorScheme.error,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    _syncResultMsg!,
                    style: TextStyle(
                      fontSize: 11,
                      color: _syncOk ? colorScheme.primary : colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (LocalScanService.lastSyncTime != null) ...[
            const SizedBox(height: 2),
            Text(
              '${zh ? '上次同步' : 'Last sync'}: ${_formatTime(LocalScanService.lastSyncTime!, zh)}',
              style:
                  TextStyle(fontSize: 10, color: colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),

          // build98（本地加强⑥⑦）：自定义规则 + 审计时间线入口
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.add_moderator_outlined,
                size: 20, color: colorScheme.appTextSub),
            title: Text(zh ? '自定义扫描规则' : 'Custom Scan Rules',
                style: const TextStyle(fontSize: 13)),
            subtitle: Text(
              zh ? '添加自己的正则规则，随本地扫描生效' : 'Your own regex rules, applied in local scan',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _showCustomRulesDialog(zh),
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.history_toggle_off,
                size: 20, color: colorScheme.appTextSub),
            title: Text(zh ? '安全审计时间线' : 'Security Audit Timeline',
                style: const TextStyle(fontSize: 13)),
            subtitle: Text(
              zh ? '安装 / 扫描 / 拒绝记录可回溯' : 'Install / scan / reject history',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const SecurityAuditScreen()),
              );
            },
          ),
          const SizedBox(height: 12),

          // SkillSpector 配置
          Text(
            zh ? 'SkillSpector 服务地址' : 'SkillSpector Endpoint',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _skillspectorEndpointCtrl,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: zh ? 'SkillSpector 服务地址' : 'SkillSpector Endpoint',
              hintText: zh
                  ? '例如：http://192.168.1.100:8000'
                  : 'e.g., http://192.168.1.100:8000',
              prefixIcon: const Icon(Icons.dns_outlined, size: 18),
              suffixIcon: _testingSkillSpector
                  ? const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            keyboardType: TextInputType.url,
            onChanged: (_) => _saveConfig(),
          ),
          // build98（P2-9a）：审查开关已开但 endpoint 为空 → 红字提示
          if ((cfg.enableSkillSecurityScan || cfg.enableMcpSecurityScan) &&
              cfg.skillspectorEndpoint.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                zh
                    ? '⚠️ 已开启 Skill/MCP 深度审查但未填 SkillSpector 地址，远程审查不会生效'
                    : '⚠️ Skill/MCP deep scan is on but SkillSpector endpoint is empty; remote scan disabled',
                style: TextStyle(fontSize: 11, color: colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _testingSkillSpector
                    ? null
                    : () async {
                        await _saveConfig();
                        if (!mounted) {
                          return; // v1.7.9 (M9)：await 后 context 失效保护
                        }
                        final endpoint = _skillspectorEndpointCtrl.text.trim();
                        if (endpoint.isEmpty) {
                          AppSnackBar.showSnackBar(context, 
                            SnackBar(
                              content: Text(zh
                                  ? '请先填写 SkillSpector 地址'
                                  : 'Please enter SkillSpector endpoint first'),
                              backgroundColor: colorScheme.tertiary,
                            ),
                          );
                          return;
                        }
                        setState(() => _testingSkillSpector = true);
                        final (ok, msg, _) = await SecurityScanService
                            .testSkillSpectorConnection(endpoint);
                        if (mounted) {
                          setState(() => _testingSkillSpector = false);
                          AppSnackBar.showSnackBar(context, 
                            SnackBar(
                              content: Text(ok ? '✅ $msg' : '❌ $msg'),
                              backgroundColor:
                                  ok ? colorScheme.primary : colorScheme.error,
                            ),
                          );
                        }
                      },
                icon: const Icon(Icons.network_check, size: 18),
                label: Text(zh ? '测试 SkillSpector' : 'Test SkillSpector'),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Skill 审查开关
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(zh ? '启用 Skill 安全审查' : 'Enable Skill Security Scan'),
            subtitle: Text(
              zh
                  ? '安装 Skill 前自动检查安全性'
                  : 'Auto-check security before installing Skill',
              style: const TextStyle(fontSize: 12),
            ),
            value: cfg.enableSkillSecurityScan,
            onChanged: (v) {
              setState(
                  () => _searchCfg = cfg.copyWith(enableSkillSecurityScan: v));
              _saveConfig();
            },
          ),

          // MCP 审查开关
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(zh ? '启用 MCP 安全审查' : 'Enable MCP Security Scan'),
            subtitle: Text(
              zh
                  ? '安装 MCP 前自动检查安全性'
                  : 'Auto-check security before installing MCP',
              style: const TextStyle(fontSize: 12),
            ),
            value: cfg.enableMcpSecurityScan,
            onChanged: (v) {
              setState(
                  () => _searchCfg = cfg.copyWith(enableMcpSecurityScan: v));
              _saveConfig();
            },
          ),

          const Divider(height: 20),

          // MobSF 配置
          Text(
            zh ? 'MobSF 服务地址' : 'MobSF Endpoint',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _mobsfEndpointCtrl,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: zh ? 'MobSF 服务地址' : 'MobSF Endpoint',
              hintText: zh
                  ? '例如：http://192.168.1.100:8080'
                  : 'e.g., http://192.168.1.100:8080',
              prefixIcon: const Icon(Icons.phone_android_outlined, size: 18),
              suffixIcon: _testingMobSF
                  ? const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            keyboardType: TextInputType.url,
            onChanged: (_) => _saveConfig(),
          ),
          // build98（P2-9a）：APK 审查开关已开但 MobSF 地址为空 → 红字提示
          if (cfg.enableApkSecurityScan && cfg.mobsfEndpoint.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                zh
                    ? '⚠️ 已开启 APK 安全审查但未填 MobSF 地址，审查不会生效'
                    : '⚠️ APK scan is on but MobSF endpoint is empty; scan disabled',
                style: TextStyle(fontSize: 11, color: colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _testingMobSF
                    ? null
                    : () async {
                        await _saveConfig();
                        if (!mounted) {
                          return; // v1.7.9 (M9)：await 后 context 失效保护
                        }
                        final endpoint = _mobsfEndpointCtrl.text.trim();
                        if (endpoint.isEmpty) {
                          AppSnackBar.showSnackBar(context, 
                            SnackBar(
                              content: Text(zh
                                  ? '请先填写 MobSF 地址'
                                  : 'Please enter MobSF endpoint first'),
                              backgroundColor: colorScheme.tertiary,
                            ),
                          );
                          return;
                        }
                        setState(() => _testingMobSF = true);
                        final (ok, msg, _) =
                            await SecurityScanService.testMobSFConnection(
                                endpoint);
                        if (mounted) {
                          setState(() => _testingMobSF = false);
                          AppSnackBar.showSnackBar(context, 
                            SnackBar(
                              content: Text(ok ? '✅ $msg' : '❌ $msg'),
                              backgroundColor:
                                  ok ? colorScheme.primary : colorScheme.error,
                            ),
                          );
                        }
                      },
                icon: const Icon(Icons.network_check, size: 18),
                label: Text(zh ? '测试 MobSF' : 'Test MobSF'),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // APK 审查开关
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(zh ? '启用 APK 安全审查' : 'Enable APK Security Scan'),
            subtitle: Text(
              zh
                  ? '下载 APK 后自动检查安全性'
                  : 'Auto-check security after downloading APK',
              style: const TextStyle(fontSize: 12),
            ),
            value: cfg.enableApkSecurityScan,
            onChanged: (v) {
              setState(
                  () => _searchCfg = cfg.copyWith(enableApkSecurityScan: v));
              _saveConfig();
            },
          ),

          // v1.7.11: MobSF API Key（P0 修复：自部署 MobSF 也可配认证）
          const SizedBox(height: 8),
          TextField(
            controller: _mobsfApiKeyCtrl,
            decoration: InputDecoration(
              isDense: true,
              labelText: zh ? 'MobSF API Key（可选）' : 'MobSF API Key (optional)',
              hintText: zh ? '自部署通常留空' : 'Usually empty for self-deployed',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.vpn_key, size: 18),
            ),
            onChanged: (_) => _saveConfig(),
          ),

          // v1.7.11: VirusTotal 云端查毒
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              zh ? 'VirusTotal 云端查毒' : 'VirusTotal Cloud Scan',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: colorScheme.appTextSub),
            ),
          ),
          TextField(
            controller: _virusTotalApiKeyCtrl,
            decoration: InputDecoration(
              isDense: true,
              labelText: zh ? 'VirusTotal API Key' : 'VirusTotal API Key',
              hintText: zh
                  ? '免费注册：virustotal.com → 500次/天'
                  : 'Free at virustotal.com → 500 req/day',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.key, size: 18),
              suffixIcon: _testingVirusTotal
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : IconButton(
                      icon: const Icon(Icons.check_circle_outline, size: 18),
                      tooltip: zh ? '测试 Key' : 'Test Key',
                      onPressed: _testingVirusTotal
                          ? null
                          : () async {
                              final key = _virusTotalApiKeyCtrl.text.trim();
                              if (key.isEmpty) {
                                if (!mounted) return;
                                AppSnackBar.showSnackBar(context, 
                                  SnackBar(
                                      content: Text(zh
                                          ? '请先填写 API Key'
                                          : 'Please enter API Key first')),
                                );
                                return;
                              }
                              await _saveConfig();
                              if (!mounted) return;
                              setState(() => _testingVirusTotal = true);
                              final (ok, msg, _) = await SecurityScanService
                                  .testVirusTotalConnection(key);
                              if (!mounted) return;
                              setState(() => _testingVirusTotal = false);
                              AppSnackBar.showSnackBar(context, 
                                SnackBar(
                                    content: Text(msg),
                                    backgroundColor: ok
                                        ? colorScheme.primary
                                        : colorScheme.error),
                              );
                            },
                    ),
            ),
            onChanged: (_) => _saveConfig(),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(zh ? '启用 VirusTotal 查毒' : 'Enable VirusTotal Scan'),
            subtitle: Text(
              zh
                  ? 'APK/文档/EXE 下载后自动查 SHA-256 哈希（秒回、不上传文件）'
                  : 'Auto SHA-256 hash check after downloading APK/docs/EXE',
              style: const TextStyle(fontSize: 12),
            ),
            value: cfg.enableVirusTotalScan,
            onChanged: (v) {
              setState(
                  () => _searchCfg = cfg.copyWith(enableVirusTotalScan: v));
              _saveConfig();
            },
          ),
          // build98（P2-9a）：VirusTotal 开关已开但 Key 为空 → 红字提示
          if (cfg.enableVirusTotalScan && cfg.virusTotalApiKey.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                zh
                    ? '⚠️ 已开启 VirusTotal 查毒但未填 API Key，查毒不会生效'
                    : '⚠️ VirusTotal scan is on but API Key is empty; scan disabled',
                style: TextStyle(fontSize: 11, color: colorScheme.error),
              ),
            ),

          const SizedBox(height: 8),
          // v1.7.18（需求4）：3 域名改为可点击官网链接（InkWell + 外链图标）
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  zh
                      ? '💡 本地规则扫描开箱即用（离线、零配置、仅供参考，不能保证查出所有问题）。\nVirusTotal 云端查毒：填 API Key 即用（免费 500次/天），下载后自动查哈希。\n深度审查为可选增强，需自部署服务，访问官网注册 / 查文档：'
                      : '💡 Local rule scan works out of the box (offline, zero-config, reference only, not exhaustive).\nVirusTotal cloud scan: just enter API Key (free 500 req/day), auto hash check after download.\nDeep scan is an optional enhancement requiring self-deployed services. Visit official sites to signup / read docs:',
                  style: TextStyle(
                      fontSize: 11, color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                _buildOfficialLink(
                  url: 'https://github.com/NVIDIA/SkillSpector',
                  label: zh ? '• SkillSpector 官网' : '• SkillSpector official',
                  color: colorScheme.primary,
                ),
                _buildOfficialLink(
                  url:
                      'https://github.com/MobSF/Mobile-Security-Framework-MobSF',
                  label: zh ? '• MobSF 官网' : '• MobSF official',
                  color: colorScheme.primary,
                ),
                _buildOfficialLink(
                  url: 'https://www.virustotal.com/gui/my-apikey',
                  label: zh
                      ? '• VirusTotal（注册 / 查 API Key）'
                      : '• VirusTotal (signup / API key)',
                  color: colorScheme.primary,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// build98（本地加强⑥）：自定义扫描规则管理对话框
  Future<void> _showCustomRulesDialog(bool zh) async {
    await showDialog(
      context: context,
      builder: (ctx) => _CustomRulesDialog(zh: zh),
    );
    // 规则变更后清缓存，下次扫描即生效
    LocalScanService.clearCache();
  }

  /// P2-3：格式化同步时间
  String _formatTime(DateTime dt, bool zh) {
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return zh ? '${dt.year}-$m-$d $h:$min:$s' : '${dt.year}-$m-$d $h:$min:$s';
  }

  /// v1.7.18（需求4）：访问官网链接（InkWell + 外链图标 + 浅色下划线文字）
  Widget _buildOfficialLink({
    required String url,
    required String label,
    required Color color,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: InkWell(
        onTap: () => LauncherUtils.openExternalUrl(url),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.open_in_new, size: 13, color: color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: color,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                    decorationColor: color.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// build98（本地加强⑥）：自定义扫描规则管理对话框
class _CustomRulesDialog extends StatefulWidget {
  final bool zh;
  const _CustomRulesDialog({required this.zh});

  @override
  State<_CustomRulesDialog> createState() => _CustomRulesDialogState();
}

class _CustomRulesDialogState extends State<_CustomRulesDialog> {
  List<LocalScanRule>? _rules;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final rules = await CustomScanRules.load();
    if (mounted) setState(() => _rules = rules);
  }

  Future<void> _addRule() async {
    final titleCtrl = TextEditingController();
    final patternCtrl = TextEditingController();
    String severity = 'medium';
    final zh = widget.zh;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: Text(zh ? '新增自定义规则' : 'Add Custom Rule'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: InputDecoration(
                      isDense: true,
                      labelText: zh ? '规则名称' : 'Rule title'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: patternCtrl,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: zh ? '正则表达式' : 'Regex pattern',
                    hintText: r'curl\s+.*\|\s*sh',
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: severity,
                  decoration: InputDecoration(
                      isDense: true,
                      labelText: zh ? '严重度' : 'Severity'),
                  items: const [
                    DropdownMenuItem(value: 'low', child: Text('low')),
                    DropdownMenuItem(value: 'medium', child: Text('medium')),
                    DropdownMenuItem(value: 'high', child: Text('high')),
                    DropdownMenuItem(
                        value: 'critical', child: Text('critical')),
                  ],
                  onChanged: (v) => setInner(() => severity = v ?? 'medium'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(zh ? '取消' : 'Cancel')),
            FilledButton(
                onPressed: () {
                  // 正则合法性预检
                  try {
                    RegExp(patternCtrl.text);
                  } catch (_) {
                    Navigator.pop(ctx, false);
                    AppSnackBar.showSnackBar(context, SnackBar(
                        content:
                            Text(zh ? '正则表达式无效' : 'Invalid regex')));
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: Text(zh ? '添加' : 'Add')),
          ],
        ),
      ),
    );
    // B-009：快照后无条件释放（取消 / 正则无效 / 空值 / 保存四路径全覆盖）
    final title = titleCtrl.text.trim();
    final pattern = patternCtrl.text.trim();
    titleCtrl.dispose();
    patternCtrl.dispose();
    if (ok != true) return;
    if (title.isEmpty || pattern.isEmpty) return;
    // build99（验收 N6）：数量/长度上限由 CustomScanRules 校验，错误回显给用户
    final addError = await CustomScanRules.add(LocalScanRule(
      id: 'UR-${DateTime.now().millisecondsSinceEpoch}',
      title: title,
      description: zh ? '用户自定义规则' : 'User-defined rule',
      severity: LocalScanRule.fromJson({'severity': severity}).severity,
      category: 'custom',
      pattern: pattern,
    ));
    if (addError != null) {
      if (!mounted) return;
      AppSnackBar.showSnackBar(context, SnackBar(
          content: Text(addError), behavior: SnackBarBehavior.floating));
      return;
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final zh = widget.zh;
    final rules = _rules;
    return AlertDialog(
      title: Text(zh ? '自定义扫描规则' : 'Custom Scan Rules'),
      content: SizedBox(
        width: 420,
        child: rules == null
            ? const Center(child: CircularProgressIndicator())
            : rules.isEmpty
                ? Text(zh ? '暂无自定义规则' : 'No custom rules yet')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: rules.length,
                    itemBuilder: (_, i) {
                      final r = rules[i];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(r.title,
                            style: const TextStyle(fontSize: 13)),
                        subtitle: Text('/${r.pattern}/ · ${r.severity.name}',
                            style: const TextStyle(fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () async {
                            await CustomScanRules.remove(r.id);
                            await _reload();
                          },
                        ),
                      );
                    },
                  ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _addRule,
          icon: const Icon(Icons.add, size: 18),
          label: Text(zh ? '新增' : 'Add'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(zh ? '完成' : 'Done'),
        ),
      ],
    );
  }
}

