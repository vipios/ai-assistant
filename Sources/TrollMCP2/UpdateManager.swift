import Foundation
import UIKit

// v2.9.68：自动更新管理器
// v4.3.30：多源检测——GitHub 被墙（国内常态）时自动切换备用源：
//   检查源链：GitHub API(最新成功构建) → jsDelivr CDN(主分支 plist) → 镜像代理(ghfast/gh-proxy 等)
//   下载源链：GitHub artifact → GitHub 滚动 Release(latest) → 各镜像前缀直连/代理
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var latestVersion: String?
    @Published var updateAvailable = false
    /// v4.3.39：新版红点——启动静默检查发现新版时点亮，设置页"检查更新"行显示红点；用户主动检查或安装成功后熄灭
    @Published var hasUpdateRedDot = false
    @Published var errorMessage: String?
    @Published var downloadedIPAURL: URL?
    /// v4.3.35：下载完成后的提示（副标题/状态行显示"安装包已下载好"）
    @Published var installMessage: String?
    /// v4.5.x：最近一次静默安装失败码（170/171/177/178/181 等），UI 可显示具体原因
    @Published var installFailureCode: Int32?
    /// v4.3.30：本次检查命中的源（GitHub / jsDelivr / 镜像），副标题可显示
    @Published var lastSource: String?
    /// 2026-11-05：最近一次检查的时间。界面靠它区分「没查过」和「查过且最新」——
    /// 以前这两种都渲染成 i18n_232「已是最新」，用户杀进程重进会以为升级功能坏了。
    @Published var lastCheckAt: Date?
    /// 2026-11-05：最近一次检查的结论（newer / same / fail），落盘用
    private var lastResult: String = ""

    // 落盘键：状态只在内存里的话，App 一被杀就全空，
    // 而空状态在界面上的兜底文案是「已是最新」——两头夹击，用户就永远看到"已是最新"。
    private let kCheckAt = "trollmcp2.update_check_at"
    private let kLatest = "trollmcp2.update_latest"
    private let kResult = "trollmcp2.update_result"
    /// 最近一次 GitHub API 的 HTTP 状态（403 = 限流，凭它给准确提示，别一律说"被墙"）
    private var lastHTTPStatus = 0

    /// v4.3.29：检查时记住最新成功构建 run，下载用同一个（旧逻辑下载时重新查 run，可能拿到别的 workflow）
    private var latestRunId: Int?
    /// v4.3.29：检查时记住 artifact 下载 URL（下载链第一候选）
    private var artifactDownloadURL: String?
    /// v4.3.29：保留下载进度观察者（不持有会被立即释放，进度不更新）
    private var progressObserver: NSKeyValueObservation?

    // v2.9.108：仓库与工作流改为动态读取（对齐 GitHub 账号页配置）
    // v7.1.285：默认仓库名 trollmcp2 → TrollAgent（旧名 API 301 / CDN 404），并迁移已存的旧值
    // 2026-11-02 定制版曾把默认仓库改为空（怕指向上游 7.x 把定制冲掉）。
    // 2026-11-04 改为「默认吃 vipios/ai-assistant」，因为留空会导致检查更新彻底不联网；
    // 对上游的防护改由下方 upstreamOwners / upstreamRepos 硬拦，效果更准（只拦上游，不拦自己）。
    private var repo: String {
        // 2026-11-04 修正（关键，修的是「发了新版但手机永远刷不出来」）：
        //   原来这里只读 UserDefaults 两个键，而写这两个键的是
        //   GitHubAccountStore.init → load() → persist()，那个 store 是**懒加载**的。
        //   只要用户还没进过「设置 → GitHub 账号」页，键就是空 →
        //   repo 为空 → checkForUpdate 一开始就 return，一次网络请求都不发 →
        //   界面显示 i18n_232「已是最新」。把「没配仓库」伪装成「已经最新」，
        //   结果就是永远收不到更新。
        //   修法：空值直接吃 GitHubAccountStore 的静态默认值（vipios/ai-assistant），
        //   不走 store 实例，避免在后台线程首次实例化 ObservableObject 触发跨线程告警。
        let owner = (UserDefaults.standard.string(forKey: "trollmcp2.github_repo_owner") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var name = (UserDefaults.standard.string(forKey: "trollmcp2.github_repo_name") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "trollmcp2" { name = "" }
        // 2026-11-03 硬保险：不管存着什么，绝不允许更新源指向上游作者。
        //   只要指过去，「检查更新」就会报 7.x，用户一点升级 = 定制版被原版覆盖。
        if GitHubAccountStore.upstreamOwners.contains(owner) { return "" }
        if GitHubAccountStore.upstreamRepos.contains(name) { return "" }
        // 缺哪一半就补默认值，而不是整串作废
        let o = owner.isEmpty ? GitHubAccountStore.defaultOwner : owner
        let n = name.isEmpty ? GitHubAccountStore.defaultRepo : name
        guard !o.isEmpty, !n.isEmpty else { return "" }
        return "\(o)/\(n)"
    }
    private var workflow: String {
        UserDefaults.standard.string(forKey: "trollmcp2.github_workflow_id") ?? "build-trollmcp2.yml"
    }

    // MARK: - 镜像源配置（v4.3.30）

    /// 默认镜像（国内可访问的 GitHub 代理，用于被墙时检查与下载；可在设置里改）
    static let defaultMirrors = ["https://ghfast.top/", "https://gh-proxy.com/"]
    var mirrors: [String] {
        let raw = UserDefaults.standard.string(forKey: "trollmcp2.update_mirrors") ?? ""
        let custom = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && ($0.hasPrefix("http://") || $0.hasPrefix("https://")) }
        return custom.isEmpty ? Self.defaultMirrors : custom
    }
    var mirrorsText: String { mirrors.joined(separator: ",") }
    func saveMirrors(_ text: String) {
        UserDefaults.standard.set(text.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "trollmcp2.update_mirrors")
    }

    private init() {
        // 2026-11-05：启动时把上次的检查结果捡回来。
        // 起因：用户在「下载到一半」杀掉 App，再进来看到的是「已是最新 v1.0.24」——
        // 因为内存状态全丢，界面拿 null 当成了"最新"。把上次结论落盘，
        // 重启后至少能照实显示"上次查到有新版"，不会凭空变成最新。
        let d = UserDefaults.standard
        if let v = d.string(forKey: kLatest), !v.isEmpty { latestVersion = v }
        if let t = d.object(forKey: kCheckAt) as? Date { lastCheckAt = t }
        lastResult = d.string(forKey: kResult) ?? ""
        if lastResult == "newer", let v = latestVersion, !v.isEmpty {
            updateAvailable = true
            hasUpdateRedDot = true
        }
    }

    /// 落盘一次结论（成功/最新/失败都写，界面才有话可说）
    private func persist(_ result: String) {
        lastResult = result
        let d = UserDefaults.standard
        let now = Date()
        d.set(now, forKey: kCheckAt)
        d.set(latestVersion ?? "", forKey: kLatest)
        d.set(result, forKey: kResult)
        lastCheckAt = now
    }

    /// 带 token（如已登录 GitHub 账号）的请求
    private func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = GitHubAccountStore.shared.activeToken {
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// 发起请求，回调 (data, httpStatus, error)
    ///
    /// 2026-11-05 关键修正：**一律不走缓存**。
    /// GitHub 的 /releases/latest 返回 `Cache-Control: max-age=60`，URLSession 默认会把
    /// 响应写进磁盘缓存（URLCache 是跨进程持久的）。于是出现这个经典现象：
    /// 推送后第一次检查拿到了新版、开始下载 → 用户杀掉 App → 重进再查 →
    /// **磁盘缓存把 60 秒前的旧响应原样吐回来** → 判定「已是最新」，点几次都一样。
    /// 加 no-cache 之后每次都是真去问一次服务器。
    private func perform(_ url: URL, timeout: TimeInterval = 25,
                         completion: @escaping (Data?, Int, Error?) -> Void) {
        var request = authorizedRequest(url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        URLSession.shared.dataTask(with: request) { data, resp, error in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            completion(data, status, error)
        }.resume()
    }

    // MARK: - 检查更新（v4.3.30 多源链，2026-11-05 改成单请求）

    /// 检查更新：源1 GitHub Releases（1 次请求）→ 源2 镜像 raw → 源3 jsDelivr。
    /// 完成回调传是否发现新版本。
    func checkForUpdate(currentVersion: String, completion: ((Bool) -> Void)? = nil) {
        // 2026-11-02 定制版：未配置自己的仓库时不做任何检查。
        // 否则会拼出 /repos//actions 这种空 owner 请求、白跑一轮并可能误点亮更新红点。
        guard !repo.isEmpty else {
            isChecking = false
            updateAvailable = false
            // 2026-11-04：不再静默返回「已是最新」。
            //   以前这里直接把 updateAvailable 置 false 就完事，界面显示 i18n_232「已是最新」——
            //   用户看到的是「已经是最新版」，实际是「仓库没配，压根没联网查」。
            //   把配置问题伪装成「最新」，等于让用户永远收不到更新。
            errorMessage = "未配置更新仓库，请到 设置 → GitHub 账号 填写 \(GitHubAccountStore.defaultOwner)/\(GitHubAccountStore.defaultRepo)"
            completion?(false)
            return
        }
        isChecking = true
        errorMessage = nil
        lastSource = nil
        // 每次检查重新记 HTTP 状态，避免上一轮的 403 影响这一轮的失败原因判断
        lastHTTPStatus = 0
        // 2026-11-05 关键瘦身：以前一次检查要打 **3 个** GitHub API
        //   （actions/runs + artifacts + releases/latest）。
        // 未登录时整台手机的额度只有 60 次/小时，用户点几下、App 再启动几次就耗光 →
        // 之后所有检查 403 → 备用源也不通 → 界面永远是"查不到/已是最新"。
        // 现在只打 releases/latest：它的 title 里就带着构建产物版本，一次就够。
        // artifact 只在真下载时才需要，而下载本来就有 Release 直链兜底。
        fetchLatestReleaseVersion(currentVersion: currentVersion, source: "GitHub",
                                  completion: completion)
    }

    /// 2026-11-05：原来的 checkViaGitHub（actions/runs）已删除。
    /// 它唯一的作用是拿 runId 去查 artifact，而版本号本来就要靠 releases/latest 的 title ——
    /// 等于每次检查白花 2 个 API 配额。额度被自己耗光后全是 403，
    /// 在用户这边表现就是"刚推的新版死活查不到"。

    private func fetchArtifactDownloadURL(runId: Int?) {
        guard let runId = runId,
              let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runs/\(runId)/artifacts") else { return }
        perform(url, timeout: 15) { [weak self] data, status, _ in
            DispatchQueue.main.async {
                guard status == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let artifacts = json["artifacts"] as? [[String: Any]],
                      let first = artifacts.first,
                      let dl = first["archive_download_url"] as? String else { return }
                self?.artifactDownloadURL = dl
            }
        }
    }

    /// 源4（最后兜底）：jsDelivr CDN
    ///
    /// 2026-11-05：降到最后。它的 @main 缓存回源有延迟，刚 bump 完版本时
    /// 会稳定返回上一个版本 —— 以前它排第二，直接导致「刚推的新版查不到」。
    /// 现在只有前面全挂才用它，而且 json 里来源会标明 jsDelivr，用户能看出这个值可能滞后。
    private func checkViaJsDelivr(currentVersion: String, completion: ((Bool) -> Void)?) {
        let parts = repo.split(separator: "/")
        guard parts.count == 2,
              let url = URL(string: "https://cdn.jsdelivr.net/gh/\(parts[0])/\(parts[1])@main/Support/Info.plist") else {
            finishCheckFail(completion: completion)
            return
        }
        perform(url) { [weak self] data, status, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if error != nil || status != 200 || data == nil {
                    self.finishCheckFail(completion: completion)
                    return
                }
                if let v = self.parseVersion(from: data!) {
                    self.latestRunId = nil
                    self.artifactDownloadURL = nil
                    self.applyVersion(v, currentVersion: currentVersion, source: "jsDelivr", completion: completion)
                } else {
                    self.finishCheckFail(completion: completion)
                }
            }
        }
    }

    /// 源2：镜像代理（走镜像读 main 分支 plist —— 无长缓存，比 jsDelivr 实时）
    ///
    /// 2026-11-05：把镜像提到 jsDelivr **之前**。
    /// jsDelivr 对 @main 分支文件的缓存按 commit 走，但回源有延迟，
    /// 刚 bump 完版本时它能稳定地返回「上一个版本」——用它当第二顺位，
    /// 表现就是"刚推的新版永远查不到"。镜像打的是 raw.githubusercontent，拿到的是当下内容。
    private func checkViaMirror(currentVersion: String, completion: ((Bool) -> Void)?) {
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else {
            checkViaJsDelivr(currentVersion: currentVersion, completion: completion)
            return
        }
        let mirrors = self.mirrors
        guard !mirrors.isEmpty else {
            checkViaJsDelivr(currentVersion: currentVersion, completion: completion)
            return
        }
        tryMirror(index: 0, mirrors: mirrors, parts: parts, currentVersion: currentVersion, completion: completion)
    }

    private func tryMirror(index: Int, mirrors: [String], parts: [Substring], currentVersion: String, completion: ((Bool) -> Void)?) {
        guard index < mirrors.count else {
            // 镜像全挂 → 最后才试 jsDelivr（它能通但可能滞后，总比彻底没结果强）
            checkViaJsDelivr(currentVersion: currentVersion, completion: completion)
            return
        }
        let mirror = mirrors[index]
        guard let runsURL = URL(string: "\(mirror)https://api.github.com/repos/\(repo)/actions/runs?workflow_id=\(workflow)&status=success&per_page=5") else {
            tryMirror(index: index + 1, mirrors: mirrors, parts: parts, currentVersion: currentVersion, completion: completion)
            return
        }
        perform(runsURL) { [weak self] data, status, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard error == nil, status == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let runs = json["workflow_runs"] as? [[String: Any]],
                      let latestRun = runs.first else {
                    self.tryMirror(index: index + 1, mirrors: mirrors, parts: parts,
                                   currentVersion: currentVersion, completion: completion)
                    return
                }
                let runId = latestRun["id"] as? Int
                let sha = (latestRun["head_sha"] as? String) ?? ""
                let title = (latestRun["display_title"] as? String) ?? ""
                self.latestRunId = runId
                self.fetchArtifactDownloadURL(runId: runId)
                // 经镜像读 main 分支 plist（v4.5.x：版本由 CI bump 写回 main，head_sha 快照是旧版本）
                guard let plistURL = URL(string: "\(mirror)https://raw.githubusercontent.com/\(self.repo)/main/Support/Info.plist") else {
                    self.tryMirror(index: index + 1, mirrors: mirrors, parts: parts,
                                   currentVersion: currentVersion, completion: completion)
                    return
                }
                self.perform(plistURL) { data2, status2, error2 in
                    DispatchQueue.main.async {
                        if error2 == nil, status2 == 200, let v = data2.flatMap({ self.parseVersion(from: $0) }) {
                            self.applyVersion(v, currentVersion: currentVersion, source: L10n.t("i18n_660"), completion: completion)
                        } else {
                            // plist 读不到就用 run 标题里的 vX.Y.Z 回退
                            let v = self.extractVersion(from: title)
                            if v == title {
                                self.tryMirror(index: index + 1, mirrors: mirrors, parts: parts,
                                               currentVersion: currentVersion, completion: completion)
                            } else {
                                self.applyVersion(v, currentVersion: currentVersion, source: L10n.t("i18n_660"), completion: completion)
                            }
                        }
                    }
                }
            }
        }
    }

    private func finishCheckFail(completion: ((Bool) -> Void)?) {
        isChecking = false
        // 2026-11-05：区分「被墙」和「被限流」。
        // GitHub 未登录时每个 IP 每小时只有 60 次 API 配额，超了返回 403。
        // 以前一律说"GitHub 与备用源均不可达（可能被墙）"，用户照着换镜像也没用——
        // 那根本不是网络问题。限流就把真实原因说清楚，等几分钟就好。
        if lastHTTPStatus == 403 || lastHTTPStatus == 429 {
            errorMessage = L10n.t("i18n_upd_limited")
        } else {
            errorMessage = L10n.t("i18n_661")
        }
        persist("fail")
        completion?(false)
    }

    /// v4.5.x：从 GitHub latest release 的 title 读构建产物版本（"TrollAgent latest (v7.0.4.123)"）。
    /// 产物版本由 CI RELEASE_VERSION 注入并随 run_number 递增——这是"检查更新"识别新版的唯一正确来源。
    private func fetchLatestReleaseVersion(currentVersion: String, source: String,
                                           completion: ((Bool) -> Void)?) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            checkViaMirror(currentVersion: currentVersion, completion: completion)
            return
        }
        perform(url) { [weak self] data, status, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if status == 403 || status == 429 { self.lastHTTPStatus = status }
                guard status == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = (json["name"] as? String) ?? (json["tag_name"] as? String) else {
                    // release 读不到（刚删了重建的那几秒会 404）→ 走镜像读 raw，别用 jsDelivr 的旧缓存下结论
                    self.checkViaMirror(currentVersion: currentVersion, completion: completion)
                    return
                }
                let v = self.extractVersion(from: name)
                if v != name {
                    self.applyVersion(v, currentVersion: currentVersion, source: source, completion: completion)
                } else {
                    self.checkViaMirror(currentVersion: currentVersion, completion: completion)
                }
            }
        }
    }

    /// 从 GitHub 最新构建 commit 的 Support/Info.plist 读版本号（v4.3.29 起；artifact 名无版本号）
    private func parseVersion(from data: Data) -> String? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            return plist["CFBundleShortVersionString"] as? String
        }
        return nil
    }

    private func applyVersion(_ v: String, currentVersion: String, source: String, completion: ((Bool) -> Void)?) {
        isChecking = false
        lastSource = source
        latestVersion = v
        let newer = isVersionNewer(v, than: currentVersion)
        updateAvailable = newer
        // v4.3.39：发现新版即点亮红点（启动静默检查/手动检查均生效）
        if newer { hasUpdateRedDot = true }
        // 2026-11-05：结论落盘。杀进程/重启后界面能照实说"上次查到有新版"，
        // 而不是因为内存清空就退回「已是最新」。
        persist(newer ? "newer" : "same")
        completion?(newer)
    }

    private func extractVersion(from name: String) -> String {
        // v4.5.x：支持 3/4 段（产物版本可能形如 7.0.4.123 / 7.0.5）
        let pattern = #"v?(\d+\.\d+\.\d+(?:\.\d+)?)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let range = Range(match.range(at: 1), in: name) {
            return String(name[range])
        }
        return name
    }

    private func isVersionNewer(_ v1: String, than v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(parts1.count, parts2.count) {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        return false
    }

    // MARK: - 一键更新（v4.3.29）

    /// 一键更新：检查（多源）→ 有新版自动下载（多源）→ 调起 TrollStore 安装
    func updateNow(currentVersion: String) {
        // v4.3.39：用户主动点检查更新 = 已看到红点，先熄灭
        hasUpdateRedDot = false
        checkForUpdate(currentVersion: currentVersion) { [weak self] newer in
            guard let self = self else { return }
            if newer {
                self.downloadAndInstall()
            } else if self.errorMessage == nil {
                self.errorMessage = L10n.t("i18n_662", currentVersion)
            }
        }
    }

    // MARK: - 下载 + 安装（v4.3.30 多源链）

    /// 2026-11-05：本次实际从哪个源下载（界面副标题显示）
    @Published var downloadSource: String?
    /// 2026-11-05：测速后记下的最快镜像前缀（空串 = GitHub 直连）。
    /// 只用于界面展示和落盘记录——**不再用于把直链交给 TrollStore**，
    /// 自动安装那条路已经整段删掉了（用户要求只走分享菜单手动装）。
    private(set) var bestPrefix: String = ""
    /// 2026-11-05：测速结果缓存（按速度降序）。空数组 = 还没测过。
    private var rankedCache: [(label: String, prefix: String, speed: Double)] = []
    /// 2026-11-05：正在测速时置 true。界面用它显示「正在测速…」
    @Published var isProbingSources = false
    /// 上次测速的时间。超过 `probeTTL` 就重测（网络环境会变）
    private var lastProbeAt: Date?
    /// 2026-11-05：测速结果有效期。
    ///
    /// 为什么需要过期：用户可能早上连 WiFi 测出 ghfast 最快，中午切到流量，
    /// 下午点更新还拿早上的结果去下——那时候 gh-proxy 可能才是通的。
    /// 10 分钟够覆盖「进设置页看一眼→回来点更新」这个真实使用节奏，
    /// 又不会把几小时前的旧排名当真。
    private let probeTTL: TimeInterval = 600

    /// 测速入口（可在进入更新页时提前调用）。
    ///
    /// 2026-11-05 用户要求：「进来就自动判定哪条线路最快，点更新就直接用最快的那个」。
    /// 所以测速不再绑在 `downloadAndInstall` 里等下载时才跑，
    /// 而是页面一进来就并发测好并缓存。点更新时如果缓存还新鲜（10 分钟内），
    /// 直接用它——用户点了按钮立刻就开始下，不用再干等 8 秒。
    ///
    /// `force = true` 用于「用户手动点重新测速」或上次测速全部失败的情况。
    func probeSourcesIfNeeded(force: Bool = false) {
        if !force, !rankedCache.isEmpty, let t = lastProbeAt,
           Date().timeIntervalSince(t) < probeTTL {
            return   // 缓存新鲜，不重复测（省流量也省时间）
        }
        probeSources(force: force)
    }

    private func probeSources(force: Bool) {
        guard !isProbingSources else { return }
        isProbingSources = true

        let releaseURL = Self.releaseURL(repo: repo)
        // 参与测速的源：GitHub 直连 + 各镜像。直连也测——它要是真的快（有梯子/海外网络），
        // 不该被硬性排到镜像后面。
        var targets: [(label: String, prefix: String, url: String)] = [("GitHub", "", releaseURL)]
        for m in mirrors { targets.append((Self.prettyHost(m), m, m + releaseURL)) }

        UpdateSourceProbe.shared.rank(targets) { [weak self] ranked in
            guard let self = self else { return }
            var ordered = Self.orderBySpeed(ranked)
            // 兜底：rank 在某些情况下会返回空（URL 构造失败、所有 target 都被过滤）。
            // 那时候不能直接报「所有源都失败」——测速失败不等于下载不了，
            // 老老实实按「镜像优先、直连垫底」的原顺序再走一遍。
            if ordered.isEmpty {
                // 注意这里必须显式写标签：Swift 的元组标签不会隐式推断，
                // 写成 `($0.label, $0.prefix, 0.0)` 得到的是无标签元组，
                // 跟 orderBySpeed 的签名对不上，编译直接报错。
                ordered = Self.orderBySpeed(targets.map {
                    (label: $0.label, prefix: $0.prefix, speed: 0.0)
                })
            }
            self.rankedCache = ordered
            self.lastProbeAt = Date()
            self.isProbingSources = false
            self.bestPrefix = ordered.first?.prefix ?? ""
            UserDefaults.standard.set(self.bestPrefix, forKey: "trollmcp2.update_best_prefix")
            // 落到 UserDefaults 的不只是前缀，还有"这次测出来哪个最快"的显示名，
            // 让设置页不用等第二次测速就能显示结果。
            UserDefaults.standard.set(ordered.first?.label ?? "", forKey: "trollmcp2.update_best_label")
        }
    }

    /// 当前测速结论的一句话（给界面显示，测过才有值）
    func bestSourceLabel() -> String? {
        if isProbingSources { return nil }
        if let l = rankedCache.first?.label, let s = rankedCache.first?.speed, s > 0 {
            return "\(l) · \(Int(s / 1024)) KB/s"
        }
        if let l = rankedCache.first?.label { return l }
        let saved = UserDefaults.standard.string(forKey: "trollmcp2.update_best_label") ?? ""
        return saved.isEmpty ? nil : saved
    }

    /// 下载链：**用已测好的排序**，从最快的源开始下，失败依次降级。
    ///
    /// 2026-11-05 改动（用户要求「哪个快用哪个」+「点更新直接用最快那条」）：
    ///   旧顺序是写死的 GitHub 直连 → ghfast → gh-proxy。
    ///   国内直连 GitHub 下载基本只能等到 30 秒超时，等于加速镜像是失败后的备胎，
    ///   主路径永远是「先白等半分钟」。
    ///   现在：测速在进入更新页时就已经做完（见 probeSourcesIfNeeded），
    ///   点更新时若缓存新鲜就直接开下；不新鲜才当场补测一次。
    func downloadAndInstall() {
        guard let version = latestVersion else {
            errorMessage = L10n.t("i18n_663")
            return
        }
        isDownloading = true
        downloadProgress = 0
        downloadSource = nil
        errorMessage = nil

        // 缓存新鲜 → 直接开下，不等测速。这是「点更新立刻就用最快线路」的关键：
        // 早先版本把测速塞在下载函数里，用户点一下要先看 8 秒「正在测速」才动，
        // 体感上就是"点了没反应"。
        if !rankedCache.isEmpty, let t = lastProbeAt,
           Date().timeIntervalSince(t) < probeTTL {
            startDownload(ordered: rankedCache, version: version)
            return
        }

        // 缓存是空的或过期了（用户可能没进过更新页直接点的更新）→ 当场补测一次
        phase = L10n.t("i18n_1635")
        isProbingSources = true
        let releaseURL = Self.releaseURL(repo: repo)
        var targets: [(label: String, prefix: String, url: String)] = [("GitHub", "", releaseURL)]
        for m in mirrors { targets.append((Self.prettyHost(m), m, m + releaseURL)) }

        UpdateSourceProbe.shared.rank(targets) { [weak self] ranked in
            guard let self = self else { return }
            self.isProbingSources = false
            var ordered = Self.orderBySpeed(ranked)
            if ordered.isEmpty {
                ordered = Self.orderBySpeed(targets.map {
                    (label: $0.label, prefix: $0.prefix, speed: 0.0)
                })
            }
            self.rankedCache = ordered
            self.lastProbeAt = Date()
            self.bestPrefix = ordered.first?.prefix ?? ""
            UserDefaults.standard.set(self.bestPrefix, forKey: "trollmcp2.update_best_prefix")
            UserDefaults.standard.set(ordered.first?.label ?? "", forKey: "trollmcp2.update_best_label")
            self.startDownload(ordered: ordered, version: version)
        }
    }

    /// 按已排序的源列表开下。分离出来是因为两条路（缓存命中 / 当场补测）最后都走这里。
    private func startDownload(ordered: [(label: String, prefix: String, speed: Double)],
                               version: String) {
        let releaseURL = Self.releaseURL(repo: repo)
        phase = nil
        // 尝试链：排序后的每个源先下 Release 本体；
        // artifact（需要 token 的 zip）统一压到最后——它是兜底，不该占主路径的时间。
        var attempts: [(url: String, isArtifact: Bool)] = []
        for s in ordered {
            attempts.append((s.prefix + releaseURL, false))
        }
        if let art = artifactDownloadURL {
            attempts.append((art, true))
            for s in ordered where !s.prefix.isEmpty {
                attempts.append((s.prefix + art, true))
            }
        }
        if let first = ordered.first {
            downloadSource = first.label
        }
        attemptDownload(attempts, index: 0, version: version)
    }

    private static func releaseURL(repo: String) -> String {
        "https://github.com/\(repo)/releases/download/latest/TrollAgent.tipa"
    }

    /// 当前阶段提示（测速中 / 下载中），界面优先显示这句
    @Published var phase: String?

    /// 测速结果排序 + 全挂时的人工兜底顺序。
    private static func orderBySpeed(_ ranked: [(label: String, prefix: String, speed: Double)])
        -> [(label: String, prefix: String, speed: Double)] {
        // rank() 已经按速度降序排好。这里只处理一种情况：**全都是 0**。
        // 全 0 说明测速时一个都没连上（机场抖动、镜像临时挂），
        // 此时镜像比直连更可能通，所以把镜像提到前面，直连垫底。
        let allZero = ranked.allSatisfy { $0.speed <= 0 }
        guard allZero else { return ranked }
        let mirrors = ranked.filter { !$0.prefix.isEmpty }
        let direct = ranked.filter { $0.prefix.isEmpty }
        return mirrors + direct
    }

    /// 镜像前缀 → 好读的域名（界面显示用，去掉协议和末尾斜杠）
    static func prettyHost(_ prefix: String) -> String {
        var s = prefix
        for p in ["https://", "http://"] where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? prefix : s
    }

    private func attemptDownload(_ attempts: [(url: String, isArtifact: Bool)], index: Int, version: String) {
        guard index < attempts.count else {
            isDownloading = false
            phase = nil
            errorMessage = L10n.t("i18n_664")
            return
        }
        let attempt = attempts[index]
        guard let url = URL(string: attempt.url) else {
            attemptDownload(attempts, index: index + 1, version: version)
            return
        }
        // 真正开始下载了，测速阶段那句话就该撤掉
        phase = nil
        // 界面照实说这次走的是哪个源（换源降级时也跟着变）
        downloadSource = Self.sourceLabel(for: attempt.url)
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let task = URLSession.shared.downloadTask(with: req) { [weak self] tempURL, resp, error in
            guard let self = self else { return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if error != nil || status != 200 || tempURL == nil {
                DispatchQueue.main.async {
                    self.attemptDownload(attempts, index: index + 1, version: version)
                }
                return
            }
            // v4.3.38: 解压+安装挪后台线程——之前整个 processDownloaded (含同步阻塞等待安装, 最长240s)
            // 跑在 DispatchQueue.main.async 里, 主线程无响应超过 iOS watchdog 阈值会被系统杀进程 (表现为"检查更新闪退")。
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = self.processDownloaded(tempURL!, isArtifact: attempt.isArtifact, version: version)
                if !ok {
                    DispatchQueue.main.async {
                        self.attemptDownload(attempts, index: index + 1, version: version)
                    }
                }
            }
        }
        progressObserver = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { self?.downloadProgress = p.fractionCompleted }
        }
        task.resume()
    }

    /// 从完整下载 URL 反推「这次走的是哪个源」，给界面显示用。
    /// 不用 bestPrefix —— 换源降级时那条已经不准了，直接看 URL 前缀最诚实。
    private static func sourceLabel(for url: String) -> String {
        if url.hasPrefix("https://github.com/") || url.hasPrefix("https://api.github.com/") {
            return "GitHub"
        }
        if let r = url.range(of: "://") {
            let rest = url[r.upperBound...]
            let host = rest.split(separator: "/").first.map(String.init) ?? ""
            return host.isEmpty ? "Mirror" : host
        }
        return "Mirror"
    }

    /// 处理下载结果：artifact zip → 解压出 TrollAgent.tipa；Release 资产 → tipa 本体。
    /// 返回是否成功（失败则由下载链换下一个源）。
    private func processDownloaded(_ tempURL: URL, isArtifact: Bool, version: String) -> Bool {
        do {
            let data = try Data(contentsOf: tempURL)
            let names = (try? ZipExtractor.entries(data).map { $0.name }) ?? []
            var finalURL: URL?
            if names.contains("TrollAgent.tipa") {
                // GitHub artifact zip（内含 tipa）
                let zipPath = tempURL.appendingPathExtension("zip")
                if FileManager.default.fileExists(atPath: zipPath.path) { try FileManager.default.removeItem(at: zipPath) }
                try FileManager.default.moveItem(at: tempURL, to: zipPath)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ta-update-\(Int(Date().timeIntervalSince1970))")
                try ZipExtractor.unzip(zipPath, to: dir)
                try? FileManager.default.removeItem(at: zipPath)
                finalURL = dir.appendingPathComponent("TrollAgent.tipa")
            } else if names.contains(where: { $0.hasPrefix("Payload/") }) || !isArtifact {
                // tipa 本体（zip 含 Payload/）
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("TrollAgent-v\(version).tipa")
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: tempURL, to: dest)
                finalURL = dest
            } else {
                // 既不是 artifact zip 也不是 tipa（镜像返回错误页等）→ 换源
                return false
            }
            guard let f = finalURL, FileManager.default.fileExists(atPath: f.path) else { return false }
            // ── 2026-11-05（用户要求）：关闭「下载完自动跳转 TrollStore 安装」 ──
            // 旧行为：open(file://) 把包丢给 TrollStore，然后 3.5 秒后判「有没有进过后台」；
            //   判不出来就走 apple-magnifier://install?url=<https 直链> 兜底 ——
            //   那条路是让 TrollStore **自己再下一遍**（用户实测：App 里下一遍、红魔 R 里又下一遍），
            //   而且 App 回到前台后这套判定还会再触发一次跳转，表现为「每次杀后台回来都跳一下红魔 R」。
            // 新行为：下载完只在本 App 内弹分享菜单（存储到文件 / 用 TrollStore 安装 / 取消），
            //   由用户自己点「用 TrollStore 安装」才跳，跳之前不会二次下载。
            // 原生系统分享面板（UIActivityViewController）在本机侧载环境会 SIGSEGV
            //   （ShareCenter 顶部注释有两次真机崩溃栈），所以这里用自建分享菜单。
            let staged = Self.stageIPAForInstall(f)
            DispatchQueue.main.async {
                self.isDownloading = false
                self.phase = nil
                self.downloadedIPAURL = staged
                self.installMessage = L10n.t("i18n_1620")
                // 2026-11-05：包已经下好、分享菜单也弹出来了，这一轮的「有新版」到此结束。
                // 原来这件事由 markHandedOff 做（它跟着自动安装那段一起被删了），
                // 现在归到这里——否则红点会一直亮着，用户以为没更新成功。
                self.updateAvailable = false
                self.hasUpdateRedDot = false
                UserDefaults.standard.set("same", forKey: self.kResult)
                self.lastResult = "same"
                SharePresenter.present([staged]) { [weak self] ok, error in
                    if let error = error {
                        self?.errorMessage = L10n.t("i18n_669", error.localizedDescription)
                    } else if !ok {
                        self?.errorMessage = L10n.t("i18n_1231")
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// 把下载好的包放到 Documents 下，交给分享菜单去处理（tmp 目录不可靠）。
    /// 后缀统一成 .ipa：TrollStore 的文件分支只认 ipa / tipa，而 .ipa 是系统已知类型，
    /// 交给系统时被正确识别的概率最高。
    private static func stageIPAForInstall(_ url: URL) -> URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return url
        }
        let dest = docs.appendingPathComponent("TrollAgent-update.ipa")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return url
        }
    }
}
