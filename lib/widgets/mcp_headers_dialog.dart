import 'package:flutter/material.dart';

import '../models/mcp_market_models.dart';

/// v1.7.37（待办⑬）：MCP 自定义鉴权请求头编辑弹窗。
/// 供插件管理页「请求头（鉴权）」编辑入口 + 市场安装 MCP 时引导填凭据共用。
/// 内置模板：Bearer Token / API-Key 一键填充。
/// 敏感信息：对话框返回值含凭据明文，调用方严禁写日志。
Future<Map<String, String>?> showMcpHeadersEditorDialog(
  BuildContext context, {
  Map<String, String> initial = const {},
  List<McpHeaderSpec> specs = const [],
  bool isInstall = false,
}) {
  final isZh = Localizations.localeOf(context).languageCode == 'zh';
  return showDialog<Map<String, String>>(
    context: context,
    builder: (_) => _McpHeadersEditorDialog(
      isZh: isZh,
      initial: initial,
      specs: specs,
      isInstall: isInstall,
    ),
  );
}

/// build155：HTTP 头名**不区分大小写**，所以两行 `Authorization` / `authorization`
/// 在真正发请求时只会留下一把（后写覆盖先写）。旧 `_save()` 按字面 key 塞 Map
/// ⇒ 「填 3 行、存回 2 行」，用户以为两把凭据都在，实际第一把静默丢掉，
/// 重开弹窗也看不见它。现在把重名变成显式错误。
/// 返回第一个（剥空白 + 小写后）重复的名字；空名跳过（由 `isValidHeaderName` 管）；
/// 没有重复则 null。
String? mcpHeaderDuplicateName(Iterable<String> names) {
  final seen = <String>{};
  for (final n in names) {
    final t = n.trim().toLowerCase();
    if (t.isEmpty) continue;
    if (!seen.add(t)) return t;
  }
  return null;
}
class _HeaderRow {
  final TextEditingController nameController;
  final TextEditingController valueController;
  bool obscure;
  bool required;

  _HeaderRow({
    required this.nameController,
    required this.valueController,
    this.obscure = true,
    this.required = false,
  });

  void dispose() {
    nameController.dispose();
    valueController.dispose();
  }
}

class _McpHeadersEditorDialog extends StatefulWidget {
  final bool isZh;
  final Map<String, String> initial;
  final List<McpHeaderSpec> specs;
  final bool isInstall;

  const _McpHeadersEditorDialog({
    required this.isZh,
    required this.initial,
    required this.specs,
    required this.isInstall,
  });

  @override
  State<_McpHeadersEditorDialog> createState() =>
      _McpHeadersEditorDialogState();
}

class _McpHeadersEditorDialogState extends State<_McpHeadersEditorDialog> {
  final List<_HeaderRow> _rows = [];
  String? _error;

  bool get isZh => widget.isZh;

  @override
  void initState() {
    super.initState();
    // registry 声明的 header 规格优先生成行（required 标记），initial 里的值回填
    for (final spec in widget.specs) {
      _rows.add(_HeaderRow(
        nameController: TextEditingController(text: spec.name),
        valueController:
            TextEditingController(text: widget.initial[spec.name] ?? ''),
        obscure: spec.isSecret,
        required: spec.isRequired,
      ));
    }
    for (final entry in widget.initial.entries) {
      if (widget.specs.any((s) => s.name == entry.key)) continue;
      _rows.add(_HeaderRow(
        nameController: TextEditingController(text: entry.key),
        valueController: TextEditingController(text: entry.value),
      ));
    }
    if (_rows.isEmpty) _addRow();
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _addRow({String name = '', String value = ''}) {
    setState(() {
      _rows.add(_HeaderRow(
        nameController: TextEditingController(text: name),
        valueController: TextEditingController(text: value),
      ));
      _error = null;
    });
  }

  void _applyTemplate(String name, String valuePrefix) {
    // 已存在同名行 → 只补值前缀；否则新增一行
    for (final row in _rows) {
      if (row.nameController.text.trim().toLowerCase() == name.toLowerCase()) {
        if (row.valueController.text.isEmpty) {
          row.valueController.text = valuePrefix;
        }
        setState(() => _error = null);
        return;
      }
    }
    _addRow(name: name, value: valuePrefix);
  }

  void _save() {
    // 重名是**跨行**的属性，逐行判不出来 ⇒ 先做整表检查。
    final dup = mcpHeaderDuplicateName(_rows.map((r) => r.nameController.text));
    if (dup != null) {
      setState(() => _error = isZh
          ? '请求头名称重复：$dup（头名不区分大小写，两行只会发出一把，请合并）'
          : 'Duplicate header name: $dup (names are case-insensitive) — merge the rows');
      return;
    }
    final headers = <String, String>{};
    for (final row in _rows) {
      final name = row.nameController.text.trim();
      // build155：先剥首尾空白再校验。从 1Password / 文档里粘 Key 常带尾部换行，
      // 而 `isValidHeaderValue` 是**拒** CR/LF 的 ⇒ 旧写法弹一句「值无效」，
      // 可这一格默认是密文，用户既看不见那个换行在哪也删不掉，只能反复试。
      final value = row.valueController.text.trim();
      if (name.isEmpty && value.isEmpty) continue;
      if (!isValidHeaderName(name)) {
        setState(() =>
            _error = isZh ? '请求头名称无效：$name' : 'Invalid header name: $name');
        return;
      }
      if (!isValidHeaderValue(value) || value.isEmpty) {
        setState(() => _error =
            isZh ? '请求头 $name 的值无效' : 'Invalid value for header $name');
        return;
      }
      headers[name] = value;
    }
    for (final spec in widget.specs) {
      if (spec.isRequired &&
          (headers[spec.name] == null || headers[spec.name]!.isEmpty)) {
        setState(() => _error = isZh
            ? '必填请求头 ${spec.name} 不能为空'
            : 'Required header ${spec.name} must not be empty');
        return;
      }
    }
    Navigator.pop(context, headers);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.isInstall
          ? (isZh ? '填写鉴权凭据' : 'Enter Credentials')
          : (isZh ? '请求头（鉴权）' : 'Headers (Auth)')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isZh
                  ? '将随每次 MCP 请求发送。属敏感信息，仅保存在本机，请勿泄露。'
                  : 'Sent with every MCP request. Sensitive — stored locally only, do not share.',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.key, size: 16),
                  label: const Text('Bearer Token'),
                  onPressed: () => _applyTemplate('Authorization', 'Bearer '),
                ),
                ActionChip(
                  avatar: const Icon(Icons.vpn_key, size: 16),
                  label: const Text('API-Key'),
                  onPressed: () => _applyTemplate('X-API-Key', ''),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _rows.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _rows[i].nameController,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: isZh ? '名称' : 'Name',
                          suffixText: _rows[i].required ? '*' : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _rows[i].valueController,
                        obscureText: _rows[i].obscure,
                        decoration: InputDecoration(
                          isDense: true,
                          labelText: isZh ? '值' : 'Value',
                          suffixIcon: IconButton(
                            icon: Icon(
                              _rows[i].obscure
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              size: 18,
                            ),
                            onPressed: () => setState(
                                () => _rows[i].obscure = !_rows[i].obscure),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, size: 20),
                      onPressed: () => setState(() {
                        _rows[i].dispose();
                        _rows.removeAt(i);
                      }),
                    ),
                  ],
                ),
              ),
            if (widget.specs.any((s) => s.description.isNotEmpty))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final spec in widget.specs)
                      if (spec.description.isNotEmpty)
                        Text(
                          '${spec.name}: ${spec.description}',
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant),
                        ),
                  ],
                ),
              ),
            TextButton.icon(
              icon: const Icon(Icons.add, size: 18),
              label: Text(isZh ? '添加请求头' : 'Add header'),
              onPressed: _addRow,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: cs.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isZh ? '取消' : 'Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(isZh ? '保存' : 'Save'),
        ),
      ],
    );
  }
}
