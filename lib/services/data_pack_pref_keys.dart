// build138 / G54：数据包（DataPack）的 SharedPreferences 键，**单独一个叶子文件**。
//
// 为什么单独：三个 catalog 与统一服务层都要用同一批键，谁也不该为了拿键名去
// import 谁（否则 catalog ↔ service 互相指）。这里放常量，两边单向依赖它。
//
// 键名全部沿用既有实现，一个都没改 —— 老用户升级后缓存与自定义源原样可读。
// `*_url` 键的**值**从「单个 URL」升级为「换行分隔的有序列表」，
// 由 parseDataPackSources/encodeDataPackSources 负责向后兼容（单 URL 即长度 1 列表）。
abstract final class DataPackPrefKeys {
  static const apiTemplateUrl = 'remote_api_templates_url';
  static const apiTemplateJson = 'remote_api_templates_json';
  static const apiTemplateUpdatedAt = 'remote_api_templates_updated_at';
  static const apiTemplateRetryPending = 'remote_api_templates_retry_pending';

  static const promptsUrl = 'remote_builtin_prompts_url';
  static const promptsJson = 'remote_builtin_prompts_json';
  static const promptsUpdatedAt = 'remote_builtin_prompts_updated_at';
  static const promptsRetryPending = 'remote_builtin_prompts_retry_pending';

  /// MCP 目录沿用既有缓存键（值改为存**原始信封**，McpCatalog 解码时读 entries）。
  static const mcpUrl = 'remote_mcp_catalog_url';
  static const mcpJson = 'mcp_catalog_remote_v1';
  static const mcpUpdatedAt = 'remote_mcp_catalog_updated_at';
  static const mcpRetryPending = 'remote_mcp_catalog_retry_pending';

  // ---- S1（build172）：apiTemplates 包「改写内置厂商 baseUrl」二次确认 ----

  /// 检出改写后**暂存**的原始载荷（用户确认前不进正式缓存、不应用）。
  static const apiTemplatePendingRaw = 'remote_api_templates_pending_json';

  /// 用户**确认过**的载荷 sha256 指纹：命中 ⇒ 缓存重放/再拉取不再进确认闸
  /// （否则确认一次、之后每次启动又被挂起一次）；远程同版本换内容对不上指纹，
  /// 照常重新检出。
  static const apiTemplateConfirmedSha = 'remote_api_templates_confirmed_sha';
}
