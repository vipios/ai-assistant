import Foundation
import UIKit

// MARK: - GitHub 线上编译工具 (v2.9.9）
// 让 AI 感知 App 内 GitHub 账号登录状态，并可触发线上编译、查进度、下载产物到本地工作区。
// 账号/仓库配置与 GitHubAccountStore (UI 层）共享同一份 UserDefaults 持久化。

private enum GHStoreKeys {
    static let owner = "trollmcp2.github_repo_owner"
    static let repo = "trollmcp2.github_repo_name"
    static let workflow = "trollmcp2.github_workflow_id"
    static let branch = "trollmcp2.github_branch"
    static let accounts = "trollmcp2.github_accounts"
    static let active = "trollmcp2.github_active"
    static let clientID = "trollmcp2.github_client_id"
}

/// 轻量读取 GitHub 账号配置 (不依赖 UI 层 ObservableObject，可在工具线程安全读取）
/// v4.3.66：由 private 改为 internal（InstallTools.swift 跨文件引用）
struct GHConfig {
    /// 2026-11-06 **默认仓库必须和 GitHubAccountStore 完全一致，并且共用同一份上游值黑名单**。
    ///
    /// 原来的默认值写死成上游作者的 `zrrt/TrollAgent`，而 GitHubAccountStore 早就
    /// 改成 `vipios/ai-assistant` 并在 load() 里做了迁移。两边不一致的直接后果：
    ///   · 工具层（github.trigger_build / fetch_runs）读 UserDefaults，一旦键还没写进去
    ///     就退回 `zrrt/TrollAgent`——那是别人的只读仓库，我们对它只有 pull 权限；
    ///   · dispatch 打到那里必然 403/404，而且上游压根没有 build-ios-dylib.yml。
    /// 这就是「让它编 deb 一直做不出来」的根因：请求根本没到能编 deb 的那个仓库。
    ///
    /// 现在改成引用 GitHubAccountStore 的常量，并用同一套迁移规则，杜绝两边再漂。
    static var repoOwner: String {
        let raw = UserDefaults.standard.string(forKey: GHStoreKeys.owner) ?? ""
        // 上游作者仓库一律视为「尚未配置」，迁移到我们自己的仓库。
        if raw.isEmpty || GitHubAccountStore.upstreamOwners.contains(raw) {
            return GitHubAccountStore.defaultOwner
        }
        return raw
    }
    static var repoName: String {
        let raw = UserDefaults.standard.string(forKey: GHStoreKeys.repo) ?? ""
        // 上游仓库名（TrollAgent / trollmcp2）同样视为未配置。
        if raw.isEmpty || GitHubAccountStore.upstreamRepos.contains(raw) {
            return GitHubAccountStore.defaultRepo
        }
        return raw
    }
    static var workflowId: String { UserDefaults.standard.string(forKey: GHStoreKeys.workflow) ?? "build-trollmcp2.yml" }
    static var branch: String { UserDefaults.standard.string(forKey: GHStoreKeys.branch) ?? "main" }
    static var clientID: String { UserDefaults.standard.string(forKey: GHStoreKeys.clientID) ?? "Ov23li890n3hM15edlcw" }
    static var apiBase: String { "https://api.github.com" }

    /// 当前激活账号 token (与 UI 层同源）
    static var activeToken: String? {
        let active = UserDefaults.standard.string(forKey: GHStoreKeys.active)
        guard let data = UserDefaults.standard.data(forKey: GHStoreKeys.accounts),
              let accounts = try? JSONDecoder().decode([GitHubAccount].self, from: data) else { return nil }
        return accounts.first { $0.login == active }?.token
    }
    static var activeLogin: String? {
        UserDefaults.standard.string(forKey: GHStoreKeys.active)
    }
}

/// GitHub 同步请求辅助：semaphore 桥接 URLSession
/// v4.3.66：由 private 改为 internal（InstallTools.swift 跨文件引用）
enum GHAPI {
    static func get(_ urlString: String, token: String?) -> (Int, [String: Any]?, Data?) {
        var result: (Int, [String: Any]?, Data?) = (0, nil, nil)
        guard let url = URL(string: urlString) else { return (0, nil, nil) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        setHTTPMethod("GET", on: &req)
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            result = (code, json, data)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 35)
        return result
    }

    static func post(_ urlString: String, token: String?, body: [String: Any]) -> (Int, [String: Any]?) {
        var result: (Int, [String: Any]?) = (0, nil)
        guard let url = URL(string: urlString) else { return result }
        var req = URLRequest(url: url, timeoutInterval: 30)
        setHTTPMethod("POST", on: &req)
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            result = (code, json)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 35)
        return result
    }
}

/// 查看 GitHub 账号登录状态 + 最近编译 run (AI 感知）
final class GitHubAccountStatusTool: MCPTool {
    let definition = ToolDefinition(
        name: "github.account_status",
        summary: "Check in-app GitHub account login status, repos, recent CI build records",
        parameters: [:],
        verified: true, category: "build")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let login = GHConfig.activeLogin
        let owner = GHConfig.repoOwner
        let repo = GHConfig.repoName
        var out: [String: Any] = [
            "logged_in": login != nil,
            "active_login": login ?? "",
            "repo": "\(owner)/\(repo)",
            "workflow": GHConfig.workflowId,
            "branch": GHConfig.branch,
        ]
        // 尝试拉最近 run (有 token 才拉）
        if let token = GHConfig.activeToken {
            let (code, json, _) = GHAPI.get("\(GHConfig.apiBase)/repos/\(owner)/\(repo)/actions/runs?per_page=5&event=workflow_dispatch", token: token)
            if code == 200, let arr = json?["workflow_runs"] as? [[String: Any]] {
                out["http_status"] = code
                out["runs"] = arr.map { d -> [String: Any] in
                    [
                        "id": d["id"] as? Int ?? 0,
                        "status": d["status"] as? String ?? "unknown",
                        "conclusion": d["conclusion"] as? String ?? "",
                        "display_title": d["display_title"] as? String ?? "run",
                    ]
                }
            } else {
                out["http_status"] = code
                out["runs_error"] = "cannot read build runs (HTTP \(code)), check token permission"
            }
        }
        return out
    }
}

/// 触发线上编译 (build-trollmcp2 打包 / build-ios-dylib 编 dylib、deb)
///
/// 2026-11-03 重写：以前这个工具只会发 `{"ref":…, "inputs":{"tweak":…}}`，
/// 只认 build-tweak.yml 那一个写法。用户在手机上要求「编译一个 dylib / 插件 deb」
/// 时，模型没有任何可用入口 —— 要么被指去 build-tool.yml（那个 `|| true`
/// 吞掉所有编译错误，永远绿但产物为空），要么干脆告诉用户「手机编不了」。
/// 现在按 workflow 分派参数：
///   · build-ios-dylib.yml → name / kind / source_mode / source / inline_code / arch / min_ios
///   · build-trollmcp2.yml → 无 inputs（只是重新打包 IPA）
///   · build-tweak.yml     → tweak 名
final class GitHubTriggerBuildTool: MCPTool {
    let definition = ToolDefinition(
        name: "github.trigger_build",
        summary: "Trigger GitHub Actions build: compile a dylib/deb/tweak, or repackage the app IPA. Use for: build tweak/dylib/deb from source code, build new IPA version. Don't use for: run local shell commands (use shell.exec), download files (use github.download_artifact). NOTE: iPhone cannot compile iOS Mach-O locally (needs macOS SDK) — this workflow IS the compile chain. Prerequisite: GitHub account logged in. Example: user says 'compile this into a dylib' → workflow=build-ios-dylib.yml, kind=dylib, source_mode=inline, inline_code=<source>.",
        parameters: [
            "workflow": "Workflow file: build-ios-dylib.yml (compile dylib/deb/binary — use this for tweaks and plugins) or build-trollmcp2.yml (repackage IPA, default) or build-tweak.yml (legacy)",
            "name": "Artifact name for dylib/deb build (e.g. MyTweak)",
            "kind": "For build-ios-dylib: dylib | deb | binary",
            "source_mode": "For build-ios-dylib: inline (source given in inline_code) | self (this repo) | remote (source=repo URL)",
            "source": "For source_mode=remote: repository URL",
            "inline_code": "For source_mode=inline: the full source code. Multiple files separated by lines '// ==== FILE: name.ext ====' (ObjC/C/Swift/Makefile all supported)",
            "project": "Alternative to inline_code: a tweak project name under workspace/projects/<name>; its files are collected and packed automatically (use this after project.generate_tweak)",
            "arch": "For build-ios-dylib: arm64 (default) | arm64e",
            "min_ios": "For build-ios-dylib: minimum iOS version (default 15.0)",
            "tweak": "Legacy, only for build-tweak.yml: tweak project name",
            "ref": "Git branch (default main)"
        ], verified: true, category: "build")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let token = GHConfig.activeToken else {
            throw MCPError.failed("not logged in to GitHub, log in first in Settings - GitHub Account")
        }
        let owner = GHConfig.repoOwner
        let repo = GHConfig.repoName
        // workflow 显式传入优先；否则按「有没有源码要编」自动选。
        // 自动选很重要：模型经常忘了传 workflow，然后 IPA 打包流程跑起来，
        // 用户等了十分钟拿到一个和上次一样的包。
        var workflow = params["workflow"] as? String ?? ""
        if workflow.isEmpty {
            let hasCode = !(params["inline_code"] as? String ?? "").isEmpty
            workflow = hasCode ? "build-ios-dylib.yml" : GHConfig.workflowId
        }
        let ref = params["ref"] as? String ?? GHConfig.branch
        var body: [String: Any] = ["ref": ref]

        var inputs: [String: String] = [:]
        if workflow.contains("ios-dylib") {
            var code = params["inline_code"] as? String ?? ""
            // 2026-11-03：project=xxx 时直接从工作区读工程源码，自动拼成 inline_code。
            // 为什么要这个：模型先 project.generate_tweak 生成 Makefile/Tweak.x/plist，
            // 然后得自己把三个文件按 "// ==== FILE: x ====" 拼成一个大字符串再塞进
            // inline_code —— 少一个文件、漏一行分隔符，CI 就编不出来，而模型很难自查。
            // 交给这里读目录，比让模型手拼可靠得多。
            if code.isEmpty, let proj = params["project"] as? String, !proj.isEmpty {
                code = Self.collectProjectSource(proj) ?? ""
                if code.isEmpty {
                    throw MCPError.failed("project '\(proj)' not found or empty under workspace/projects/\(proj)")
                }
            }
            let mode = (params["source_mode"] as? String)
                ?? (code.isEmpty ? "self" : "inline")
            if code.isEmpty && mode == "inline" {
                throw MCPError.failed("source_mode=inline but inline_code is empty: pass the source code in inline_code, or pass project=<name> to auto-collect it from the workspace")
            }
            inputs["name"] = params["name"] as? String
                ?? params["project"] as? String
                ?? "build_\(Int(Date().timeIntervalSince1970))"
            inputs["kind"] = params["kind"] as? String ?? "dylib"
            inputs["source_mode"] = mode
            inputs["source"] = params["source"] as? String ?? ""
            inputs["inline_code"] = code
            inputs["arch"] = params["arch"] as? String ?? "arm64"
            inputs["min_ios"] = params["min_ios"] as? String ?? "15.0"
            // GitHub 单 input 上限 64KB，超了 dispatch 会 422 而报错信息很含糊。
            if code.utf8.count > 60000 {
                throw MCPError.failed("inline_code is \(code.utf8.count) bytes, over GitHub's 64KB workflow-input limit. Reduce the sources (drop build junk / split into multiple builds)")
            }
        } else if workflow.contains("build-tweak") {
            if let tweak = params["tweak"] as? String, !tweak.isEmpty {
                inputs["tweak"] = tweak
            }
        }
        if !inputs.isEmpty { body["inputs"] = inputs }

        let (code, json) = GHAPI.post(
            "\(GHConfig.apiBase)/repos/\(owner)/\(repo)/actions/workflows/\(workflow)/dispatches",
            token: token, body: body)
        if code == 204 {
            return ["triggered": true, "workflow": workflow, "ref": ref,
                    "inputs": inputs,
                    "note": "triggered. Wait ~10s then poll with github.fetch_runs; when conclusion=success call github.download_artifact to fetch the dylib/deb."]
        }
        return ["triggered": false, "workflow": workflow,
                "http_status": code,
                "message": (json?["message"] as? String) ?? "trigger failed",
                "hint": code == 404
                    ? "workflow file not found or not on the default branch yet; push it first"
                    : (code == 403 ? "token lacks 'workflow' scope" : "")]
    }

    /// 把一个 tweak 工程的源码目录打成一个 inline_code 字符串。
    ///
    /// 为什么要它：CI 端（build-ios-dylib.yml）用
    /// `// ==== FILE: 名字 ====` 这种分隔符还原多文件工程。
    /// 由模型手拼太容易出错（漏文件、写错分隔行、把 Makefile 的 tab 换成空格），
    /// 每错一次就要白等一轮 CI（macOS runner 排队 + 编译 3~8 分钟）。
    /// 这里直接读盘，按固定顺序、原样保留缩进（Makefile 必须是真 tab）。
    static func collectProjectSource(_ name: String) -> String? {
        let root = Workspace.root.appendingPathComponent("projects/\(name)")
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return nil }
        // 只要这些类型；其它（.o/.dSYM/隐藏文件）一律不收，否则会把体积和
        // 64KB 上限浪费在中间产物上。
        let exts: Set<String> = ["x", "xm", "m", "mm", "c", "cc", "cpp", "h", "hpp",
                                 "swift", "plist", "storyboard", "xib", "json", "sh"]
        let exact: Set<String> = ["Makefile", "makefile", "GNUmakefile"]
        var parts: [String] = []
        let base = root.standardizedFileURL.path.count
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                  options: [.skipsHiddenFiles]) {
            for case let f as URL in en {
                let isFile = (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                guard isFile else { continue }
                let fn = f.lastPathComponent
                guard exact.contains(fn) || exts.contains(f.lowercasedExtension) else { continue }
                guard let txt = try? String(contentsOf: f, encoding: .utf8) else { continue }
                var rel = String(f.standardizedFileURL.path.dropFirst(base))
                if rel.hasPrefix("/") { rel.removeFirst() }
                parts.append("// ==== FILE: \(rel) ====\n\(txt)")
            }
        }
        if parts.isEmpty { return nil }
        return parts.joined(separator: "\n")
    }
}

private extension URL {
    var lowercasedExtension: String { pathExtension.lowercased() }
}

/// 查询最近线上编译进度
final class GitHubFetchRunsTool: MCPTool {
    let definition = ToolDefinition(
        name: "github.fetch_runs",
        summary: "Query recent CI build run status and conclusion",
        parameters: ["limit": "Max results (default 5)"], verified: true, category: "build")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let token = GHConfig.activeToken else {
            throw MCPError.failed("not logged in to GitHub")
        }
        let limit = params["limit"] as? Int ?? 5
        let owner = GHConfig.repoOwner
        let repo = GHConfig.repoName
        let (code, json, _) = GHAPI.get("\(GHConfig.apiBase)/repos/\(owner)/\(repo)/actions/runs?per_page=\(limit)&event=workflow_dispatch", token: token)
        guard code == 200, let arr = json?["workflow_runs"] as? [[String: Any]] else {
            return ["http_status": code, "error": (json?["message"] as? String) ?? "query failed"]
        }
        return ["runs": arr.map { d -> [String: Any] in
            [
                "id": d["id"] as? Int ?? 0,
                "status": d["status"] as? String ?? "unknown",
                "conclusion": d["conclusion"] as? String ?? "",
                "display_title": d["display_title"] as? String ?? "run",
            ]
        }]
    }
}

/// 下载最近OK编译的 artifact 到本地工作区 (注入测试闭环的关键）
final class GitHubDownloadArtifactTool: MCPTool {
    let definition = ToolDefinition(
        name: "github.download_artifact",
        summary: "Download CI build artifact from GitHub Actions. Use for: download the built IPA/dylib after CI finishes. Don't use for: trigger CI build (use github.trigger_build), check build status (use github.account_status). Example: user says 'download the IPA just built' → download artifact.",
        parameters: ["run_id": "Specific run ID (optional, uses latest successful)", "artifact_name": "Artifact name (optional, auto-detects)"], verified: true, category: "build")
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let token = GHConfig.activeToken else {
            throw MCPError.failed("not logged in to GitHub")
        }
        let owner = GHConfig.repoOwner
        let repo = GHConfig.repoName

        // 1. 确定 run_id
        var runID = params["run_id"] as? Int
        if runID == nil {
            let (rc, rj, _) = GHAPI.get("\(GHConfig.apiBase)/repos/\(owner)/\(repo)/actions/runs?per_page=10&event=workflow_dispatch", token: token)
            guard rc == 200, let arr = rj?["workflow_runs"] as? [[String: Any]] else {
                return ["downloaded": false, "error": "cannot read run list (HTTP \(rc))"]
            }
            guard let latest = arr.first(where: { ($0["conclusion"] as? String) == "success" }) else {
                return ["downloaded": false, "error": "no recent successful build run"]
            }
            runID = latest["id"] as? Int
        }
        guard let rid = runID else { throw MCPError.failed("cannot determine run id") }

        // 2. 查该 run 的 artifacts
        let (ac, aj, _) = GHAPI.get("\(GHConfig.apiBase)/repos/\(owner)/\(repo)/actions/runs/\(rid)/artifacts", token: token)
        guard ac == 200, let arts = aj?["artifacts"] as? [[String: Any]], let first = arts.first else {
            return ["downloaded": false, "error": "this run has no artifact (HTTP \(ac))"]
        }
        let artID = first["id"] as? Int ?? 0
        let artName = (params["artifact_name"] as? String) ?? (first["name"] as? String ?? "artifact")

        // 3. 下载 zip
        var data: Data?
        var status = 0
        guard let url = URL(string: "\(GHConfig.apiBase)/repos/\(owner)/\(repo)/actions/artifacts/\(artID)/zip") else {
            throw MCPError.failed("invalid URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        setHTTPMethod("GET", on: &req)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, resp, _ in
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            data = d
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 65)

        guard status == 200, let zipData = data else {
            return ["downloaded": false, "error": "download failed (HTTP \(status), artifact may be expired or deleted"]
        }

        // 4. 写入工作区 downloads 并解压
        let outDir = try Workspace.resolve("downloads")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let zipPath = outDir.appendingPathComponent("\(artName)_\(rid).zip")
        try zipData.write(to: zipPath)
        let unzipDir = outDir.appendingPathComponent("run_\(rid)")
        try? FileManager.default.removeItem(at: unzipDir)
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        try? ZipExtractor.unzip(zipPath, to: unzipDir)

        var entries: [String] = []
        if let en = FileManager.default.enumerator(at: unzipDir, includingPropertiesForKeys: nil) {
            for case let u as URL in en {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
                    entries.append(u.path.replacingOccurrences(of: unzipDir.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                }
            }
        }
        let dylibs = entries.filter { $0.hasSuffix(".dylib") }
        let debs = entries.filter { $0.hasSuffix(".deb") }
        return [
            "downloaded": true,
            "run_id": rid,
            "artifact_name": artName,
            "zip_path": zipPath.path,
            "unzip_dir": unzipDir.path,
            "bytes": zipData.count,
            "entries": entries,
            "dylibs": dylibs,
            "debs": debs,
            "note": "artifacts extracted to the directory above. Use .dylib with injection.enable into target App; .deb contains tweak package.",
        ]
    }
}
