/// 仓库端点的**唯一来源**（build171，27 日）。
///
/// 为什么单独一个文件：同一套 GitHub 地址此前散在 5 个文件里 8 处，其中
/// `rules.json` 那条在 `models/web_search_config.dart` 与
/// `screens/security_scan_settings_screen.dart` **各写了一遍**——
/// "同一条规则住在两个文件"在本仓已经付过三次账（教训 #62）。
///
/// 为什么现在必须收：27 日把对外仓库从**未公开的私有仓**迁到**公开的 Nexus** 之后，
/// 这些地址第一次真正可用。私有时期它们全部 404/403（见
/// `test/build138_g54_g56_datapack_test.dart` 的立项事实），所以"改一处漏一处"
/// 的代价只是"回退到内置默认"；迁到公开仓库之后，漏改的那一处会**继续指向私有仓库**，
/// 表现为"检查更新永远说已是最新 / 数据包永远拉不到"——从静默无害变成静默说谎。
///
/// 三条口径：
///  - **owner / 仓库名只在这里出现一次**，其余全部由它拼出来；
///  - 数据包的两个源（jsdelivr 优先、raw 兜底）只在这里定义顺序，
///    调用方拿到的是已经拼好相对文件名的列表；
///  - 这里**不放**任何本机路径、内网地址、也不放 token——私有仓库的凭据
///    一旦进这些常量就等于进公开源码。
library repo_endpoints;

const String kRepoOwner = 'songchuangchang';

/// 对外发布用的仓库（public，只放代码快照 + Release 资产）。
/// 内部那条完整历史仍在另一个未公开的私有仓库，不从这里走。
const String kRepoName = 'Nexus';

/// 设置页"GitHub 仓库"那一行**显示**用的短地址（不带 scheme，屏上更短）。
const String kRepoDisplayUrl = 'github.com/$kRepoOwner/$kRepoName';

/// 点它要跳转的完整地址。
const String kRepoHtmlUrl = 'https://github.com/$kRepoOwner/$kRepoName';

/// App 内「检查更新」：只认 latest release。
const String kRepoReleaseApiLatest =
    'https://api.github.com/repos/$kRepoOwner/$kRepoName/releases/latest';

/// 资产下载页（更新弹窗里"去下载"那一下）。
const String kRepoReleasesUrl = '$kRepoHtmlUrl/releases/latest';

/// 数据包的源前缀。调用方拼上仓库根目录下的文件名即可。
const String kRepoRawBase =
    'https://raw.githubusercontent.com/$kRepoOwner/$kRepoName/main/';
const String kRepoJsDelivrBase =
    'https://fastly.jsdelivr.net/gh/$kRepoOwner/$kRepoName@main/';

/// 扫描规则默认地址（原来在两个文件里各有一份字面量）。
const String kRepoRulesUrlDefault = '${kRepoJsDelivrBase}rules.json';

/// 按"镜像优先、直连兜底"的顺序给出某个仓库根文件的全部候选源。
/// 顺序是**这里**的口径，不是调用方的偏好：jsdelivr 在国内可达性更好，
/// 但它对刚推送的 commit 有缓存延迟，所以 raw 必须留在后面而不是省掉。
List<String> repoFileSources(String fileNameAtRoot) =>
    ['$kRepoJsDelivrBase$fileNameAtRoot', '$kRepoRawBase$fileNameAtRoot'];

/// 迁到公开仓**之前**对外用过的那些仓库名（未公开的私有仓，一条端点都不拼它）。
///
/// 为什么这份文件里还留着旧仓名：源码树在 build171 收口时把它删干净了，
/// 但**存量装机的 SharedPreferences 里还在**——`data_pack_service.dart` 读持久值时
/// 是"存了什么就用什么"，于是老装机 2026-09-30 仍在打私有仓（平板现读：
/// `api_templates 全部 1 个源失败 … a11@main/api_templates.json → HTTP 404`）。
/// 迁移判定需要的那一点历史信息只住在这里，调用方不许自己写字面量：
/// 本文件头的立项理由就是"漏改的那一处会从静默无害变成静默说谎"，
/// 而"旧地址散进第二个文件"是同一种漏。
const Set<String> kRepoLegacyPrivateNames = {'a11'};

/// 纯判定：这个 URL 指的是不是**我们自己的旧私有仓库**。
///
/// 两种形状都要覆盖（锚都是 `/<owner>/<旧仓名>`，旧仓名后面必须正好落到段界）：
///  - jsdelivr 镜像：`…/gh/<owner>/a11@main/<file>` ⇒ 段界是 `@`；
///  - raw 直连：`…/<owner>/a11/main/<file>` ⇒ 段界是 `/`；
///  - 镜像代理把整条 raw 地址接在自己的路径后面（`…/https://raw…/<owner>/a11/main/…`）
///    走的还是 raw 那一条锚，照样命中。
/// 段界**之外**不算命中：`…/<owner>/a11backup/…` 是别人的仓库，不是被迁走的那一个；
/// 新仓库名（`kRepoName`）永远不在旧仓名集合里 ⇒ 今天的有效源不可能被误判成旧的。
///
/// 只用来**读旧数据**，不参与任何端点拼接。GitHub 的 owner/仓库名只含字母数字与
/// `._-`，这三样在正则里都不是元字符 ⇒ 这里直接插值；真往集合里加带元字符的名字，
/// 先改这一处。
bool isLegacyPrivateRepoSource(String url) {
  final re = _legacyPrivateRepoSourceRe;
  return re != null && url.isNotEmpty && re.hasMatch(url);
}

final RegExp? _legacyPrivateRepoSourceRe = kRepoLegacyPrivateNames.isEmpty
    ? null
    : RegExp(
        '/$kRepoOwner/(?:${kRepoLegacyPrivateNames.join('|')})(?=[/@]|\$)',
        caseSensitive: false,
      );
