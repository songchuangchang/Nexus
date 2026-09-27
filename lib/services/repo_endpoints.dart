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
