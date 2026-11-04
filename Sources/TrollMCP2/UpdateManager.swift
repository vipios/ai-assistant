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
    /// 2026-11-05：本次下载的包在 Documents 里的落点（安装与兜底分享都用它）
    private var stagedURL: URL?
    /// v4.3.35：自动安装成功提示（副标题/状态行显示"已自动安装"）
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

    /// 下载链：GitHub artifact(直连) → 滚动 Release(latest, 直连) → 各镜像前缀 × (artifact / Release)
    func downloadAndInstall() {
        guard let version = latestVersion else {
            errorMessage = L10n.t("i18n_663")
            return
        }
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        let releaseURL = "https://github.com/\(repo)/releases/download/latest/TrollAgent.tipa"
        var attempts: [(url: String, isArtifact: Bool)] = []
        if let art = artifactDownloadURL { attempts.append((art, true)) }
        attempts.append((releaseURL, false))
        for m in mirrors {
            if let art = artifactDownloadURL { attempts.append((m + art, true)) }
            attempts.append((m + releaseURL, false))
        }
        attemptDownload(attempts, index: 0, version: version)
    }

    private func attemptDownload(_ attempts: [(url: String, isArtifact: Bool)], index: Int, version: String) {
        guard index < attempts.count else {
            isDownloading = false
            errorMessage = L10n.t("i18n_664")
            return
        }
        let attempt = attempts[index]
        guard let url = URL(string: attempt.url) else {
            attemptDownload(attempts, index: index + 1, version: version)
            return
        }
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
            isDownloading = false
            downloadedIPAURL = f
            installIPA(at: f)
            return true
        } catch {
            return false
        }
    }

    /// 更新安装交给 TrollStore 接管（根治自覆盖闪退/半覆盖）。
    /// 背景：trollstorehelper install 装的是本 App 自己——helper 安装前先杀运行中进程，
    /// 本 App 被 kill → 闪退 + 后续 UI 全部丢失；若安装/注册失败则半覆盖（TrollStore 不显示）。
    /// 交给 TrollStore 后由它完成 杀进程→安装→注册→失败回滚，全程它的 UI。
    func installIPA(at url: URL) {
        // v7.1.96：强制主线程——downloadTask 完成回调在后台线程，后台线程
        // canOpenURL/open 静默失败 → 更新完不跳 TrollStore（用户实测：
        // '检查更新没跳转到巨魔安装，只有分享菜单的储存按钮有效'）
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.installIPA(at: url) }
            return
        }
        // 先把包挪出 tmp，并统一成 .ipa 后缀（TrollStore 只认 ipa / tipa 两种后缀）
        let target = Self.stageIPAForInstall(url)
        stagedURL = target

        // ── 2026-11-05 重写：这次是照着 TrollStore 真源码改的，不是猜 ──
        // 源码（TSSceneDelegate.m）里 TrollStore 只有两条收包入口：
        //   ① 文件 URL 直接打进来（isFileURL 分支）→ 读本地包 → 弹安装确认 → 安装。
        //      这是从 1.x 起就有的「把 ipa 交给 TrollStore」正路，也是你在「文件」里
        //      分享给 TrollStore 走的那条 —— **跟版本无关，Lite 版同一条代码**。
        //   ② apple-magnifier://install?url=... → 走 handleAppInstallFromRemoteURL，
        //      内部是 NSURLSessionDownloadTask，**只认 http/https**。
        //      给它 file:// 必报 "unsupported URL" —— 这就是「跳过去了却装不上」的真因。
        //      以前那几个 trollstore:// 前缀更是白写：TrollStore 根本没注册这个 scheme。
        // 所以顺序改成：本地包直投 → 没接住再让 TrollStore 自己去下直链。
        UIApplication.shared.open(target, options: [:]) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard ok else {
                    // 没有任何 App 认领 ipa/tipa（TrollStore 没装或被禁用）
                    self.installViaRemotePackage()
                    return
                }
                // open 返回 true 也可能是「其实没人接」——系统有时会静默吞掉。
                // 判据很简单：真把包交出去了，本 App 一定会被切到后台。
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if UIApplication.shared.applicationState == .active {
                        self.installViaRemotePackage()
                    } else {
                        self.markHandedOff()
                    }
                }
            }
        }
    }

    /// 兜底二：把公开 Release 里的 tipa 直链交给 TrollStore，由它自己下载并安装。
    /// 仓库是公开的，这条 https 直链不需要任何 token —— 和「浏览器里点链接直装」是同一条路。
    ///
    /// 2026-11-05：**不绑定 TrollStore 版本**。用户机上是 com.opa334.TrollStoreLite，不是 2.1.1，
    /// 而 scheme 名字在历史上换过：1.3 以前用 trollstore://，1.3 起改成顶替系统的
    /// apple-magnifier://。所以两个都试一遍，哪个能打开就用哪个，都打不开才走分享。
    private func installViaRemotePackage() {
        let rel = "https://github.com/\(repo)/releases/latest/download/TrollAgent.tipa"
        // 整段完全百分号编码：TrollStore 拿到的是 queryItems 里已经解码的值，
        // 少编一个 `&` `#` 它就只读到半截地址。
        let encoded = rel.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? rel
        tryRemoteSchemes(prefixes: ["apple-magnifier://install?url=",
                                    "trollstore://install?url=",
                                    "trollstore://install/?url="],
                         encoded: encoded, index: 0)
    }

    private func tryRemoteSchemes(prefixes: [String], encoded: String, index: Int) {
        guard index < prefixes.count else {
            giveUpToShare()
            return
        }
        guard let u = URL(string: prefixes[index] + encoded) else {
            tryRemoteSchemes(prefixes: prefixes, encoded: encoded, index: index + 1)
            return
        }
        UIApplication.shared.open(u, options: [:]) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if ok { self.markHandedOff() }
                else { self.tryRemoteSchemes(prefixes: prefixes, encoded: encoded, index: index + 1) }
            }
        }
    }

    /// 两条自动路径都不通 → 分享菜单兜底（用户自己选 TrollStore / 储存）
    private func giveUpToShare() {
        guard let f = stagedURL ?? downloadedIPAURL else {
            errorMessage = L10n.t("i18n_1231")
            return
        }
        errorMessage = L10n.t("i18n_1231")
        fallbackShareInstall(f)
    }

    /// 已经交出去了：熄灭红点、清掉落盘的「有新版」，并提示别在安装过程中打开本 App
    private func markHandedOff() {
        isDownloading = false
        downloadedIPAURL = nil
        updateAvailable = false
        hasUpdateRedDot = false
        installMessage = L10n.t("i18n_1230")
        UserDefaults.standard.set("same", forKey: kResult)
        lastResult = "same"
    }

    /// 把下载好的包放到 Documents 下再交给 TrollStore（tmp 不可靠）
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

    /// 分享菜单兜底：TrollStore OpenIn 或保存安装包（不再 spawnRoot 自装——自装=闪退根因）
    private func fallbackShareInstall(_ url: URL) {
        SharePresenter.present([url]) { [weak self] completed, error in
            if let error = error {
                self?.errorMessage = L10n.t("i18n_669", error.localizedDescription)
            }
        }
    }
}
