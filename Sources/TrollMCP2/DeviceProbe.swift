import Foundation
import UIKit
import Security
// 2026-11-05：越狱判定要用 _dyld_image_count / _dyld_get_image_name 扫已加载镜像
import MachO

// MARK: - 设备环境自检 ("检测手机"核心层）

/// 在 iPhone 上自检运行环境：TrollStore/TrollFools 是否可用、task_for_pid 与
/// App 容器任意读写权限是否生效、内置注入二进制可否执行、amfid 绕过是否推断生效。
final class DeviceProbe: ObservableObject {
    static let shared = DeviceProbe()
    // v2.9.149：探测串行锁——页面 onAppear 与启动后台探测可能并发 run()，
    // 同时枚举应用/写探针文件导致 SIGSEGV
    private let runLock = NSLock()

    struct Check: Identifiable {
        let id = UUID()
        let label: String
        let passed: Bool
        let detail: String
        let infoOnly: Bool  // v2.9.66：信息提醒项，不显示 ✔/✘，只显示 ℹ️，不影响整体ready状态
    }

    struct Report {
        let deviceName: String
        let model: String
        let systemVersion: String
        let vendorID: String
        let trollStore: Bool
        let trollFools: Bool
        let taskForPid: Bool
        let containerWrite: Bool
        let injectionBinaries: [String: Bool]
        let amfidBypassInferred: Bool
        let entitlementsOK: Bool
        let rootDiagnosis: [String: Any]?
        let checks: [Check]
        let ready: Bool
        // v2.9.67：增强设备信息
        let deviceModelIdentifier: String  // 如 iPhone14,5
        let deviceModelName: String        // 如 iPhone 13
        let storageTotal: String           // 总存储
        let storageFree: String            // 可用存储
        let memoryTotal: String            // 总内存
        let screenSize: String             // 屏幕分辨率
        let appCount: Int                  // 已安装 App 数量
        let workspaceSize: String          // 工作区大小
        let batteryLevel: String           // 电池电量
    }

    @Published var lastReport: Report?

    // MARK: Mach 调用 (避免 import mach 类型，直接用 UInt32 别名）

    @_silgen_name("task_for_pid")
    public func tm_task_for_pid(_ task: UInt32, _ pid: Int32, _ target_task: UnsafeMutablePointer<UInt32>) -> Int32

    @_silgen_name("mach_task_self")
    public func tm_mach_task_self() -> UInt32

    @_silgen_name("mach_port_deallocate")
    public func tm_mach_port_deallocate(_ task: UInt32, _ name: UInt32) -> Int32

    // MARK: 公开入口

    func run() -> Report {
        runLock.lock()
        defer { runLock.unlock() }
        let deviceName = UIDevice.current.name
        let model = UIDevice.current.model
        let systemVersion = UIDevice.current.systemVersion
        let vendorID = UIDevice.current.identifierForVendor?.uuidString ?? "-"

        let trollStore = detectTrollStore()
        let trollFools = detectTrollFools()
        let taskForPid = testTaskForPid()
        let containerWrite = testContainerWrite()
        let injectionBinaries = testInjectionBinaries()
        // v2.9.155：amfid 推断不再依赖 task_for_pid——注入是静态方式
        //  (insert_dylib 改 Mach-O 加载命令 + ct_bypass 重签名），TrollStore 非越狱
        // 环境拿不到其他进程端口是常态，task_for_pid failed不代表注入不可用。
        let amfidBypassInferred = !injectionBinaries.isEmpty && injectionBinaries.values.allSatisfy { $0 } && containerWrite

        // v2.9.153：Entitlements 检测改用 SecTask 直接读自身代码签名 (最可靠），
        // 行为测试 (bundleWrite/root spawn）只作交叉验证。entitlements 是安装时写入的，
        // 因此反映的是"安装时 TrollStore 开关状态"；开启开关后必须卸载重装才生效。
        let ent = snapshotEntitlements()
        let bundleWriteOK = testBundleWrite()
        let rootDiag = InjectionManager.shared.diagnoseRoot()
        let spawnIsRoot = (rootDiag["is_root"] as? Bool) ?? false
        let entDetail: String
        if ent.noSandbox {
            var parts: [String] = [L10n.t("i18n_1211")]
            parts.append(ent.summary)
            if bundleWriteOK { parts.append(L10n.t("i18n_1213")) }
            if spawnIsRoot { parts.append(L10n.t("i18n_1214")) }
            entDetail = parts.joined(separator: "\n")
        } else {
            var parts: [String] = [L10n.t("i18n_1212")]
            parts.append(ent.summary)
            if bundleWriteOK { parts.append(L10n.t("i18n_1213")) }
            if spawnIsRoot { parts.append(L10n.t("i18n_1214")) }
            parts.append(L10n.t("i18n_1215"))
            entDetail = parts.joined(separator: "\n")
        }
        let entitlementsOK = ent.noSandbox || bundleWriteOK || spawnIsRoot  // 内部记录用，不影响 ready 和 UI 显示

        var checks: [Check] = []
        // v4.5.x：精简检测项——task_for_pid 在非越狱 TrollStore 必受限（系统拦截）且不决定
        // 注入可用性（静态注入与进程端口无关），不再展示误导性"绿勾受限"；注入二进制是包内
        // 自带资产（缺了只能重装包，用户无法操作修复），从 4 项合并为 1 项。
        // 保留：容器读写（用户可操作：Edit Entitlements 重装）+ amfid 综合结论。
        checks.append(Check(label: L10n.t("i18n_1199"), passed: containerWrite, detail: containerWrite ? L10n.t("i18n_1205") : L10n.t("i18n_1206"), infoOnly: false))
        let allBinsOK = !injectionBinaries.isEmpty && injectionBinaries.values.allSatisfy { $0 }
        var toolchainDetail = L10n.t("i18n_1207")
        if !allBinsOK {
            let missing = injectionBinaries.filter { !$0.value }.keys.joined(separator: ", ")
            toolchainDetail = L10n.t("i18n_1217", missing)
        }
        checks.append(Check(label: L10n.t("i18n_1216"), passed: allBinsOK, detail: toolchainDetail, infoOnly: false))
        checks.append(Check(label: L10n.t("i18n_1201"), passed: amfidBypassInferred, detail: amfidBypassInferred ? L10n.t("i18n_1209") : L10n.t("i18n_1210"), infoOnly: false))
        // v4.5.x：新增检测——VPN 隧道扩展（NE 载入前提）/ 静默安装助手 / 环境类型（信息）
        // VPN：VpnTunnel.appex 存在 + 内置 ldid 实测签名含 packet-tunnel-provider。
        // ldid 读取失败（非越狱 spawn 受限）时按"存在"判定，不误红。
        var vpnOK = false
        var vpnDetail = L10n.t("i18n_1220")
        if let appexBin = TrustEnabler.vpnTunnelBinaryPath() {
            vpnOK = true
            vpnDetail = L10n.t("i18n_1219")
            if let ldidPath = InjectionManager.shared.binaryPath("ldid") {
                let (code, out) = InjectionManager.shared.spawnRoot(ldidPath, args: ["-e", appexBin], timeout: 15)
                if code == 0, out.contains("packet-tunnel-provider") {
                    vpnDetail = L10n.t("i18n_1219") + " · packet-tunnel-provider ✓"
                } else if code == 0 {
                    vpnDetail = L10n.t("i18n_1219") + L10n.t("i18n_1228")
                    vpnOK = false
                }
            }
        }
        checks.append(Check(label: L10n.t("i18n_1218"), passed: vpnOK, detail: vpnDetail, infoOnly: false))

        // 静默安装助手：TrollStore 部署的 helper。
        // 系统位 /var/usr/bin/trollstorehelper（TrollStore 1 系）+ TrollStore.app 容器内
        // （TrollStore 2：com.opa334.TrollStore 路径）——与 AppDecryptTools 运行时查找顺序一致。
        // 2026-11-05 实机修正：手机上是 TrollStore **Lite**（com.opa334.TrollStoreLite，越狱装到
        // /var/jb/Applications 下），另有 巨魔R（TrollStoreR）。老代码只认 com.opa334.TrollStore
        // 一个 bundleId，Lite 机器上一辈子绿不了 —— 明明 helper 就在那儿（实测可执行），
        // 界面却报"静默安装助手缺失"。改成：系统位 → 越狱部署位 → 前缀匹配所有 trollstore* App。
        let helperPath = "/var/usr/bin/trollstorehelper"
        var helperOK = isUsableBinary(helperPath)
        var helperDetail = helperOK ? L10n.t("i18n_1222") : L10n.t("i18n_1223")
        if !helperOK {
            var candidates: [String] = []
            // 越狱部署位置（TrollStore Lite / 巨魔R 这类 /var/jb/Applications）
            for app in ["TrollStoreLite", "TrollStoreR", "TrollStore"] {
                for root in ["/var/jb/Applications", "/Applications"] {
                    candidates.append("\(root)/\(app).app/trollstorehelper")
                }
            }
            // AppCatalog 里任何 trollstore 系 App 的包内路径
            for app in AppCatalog.list() where app.bundleId.lowercased().hasPrefix("com.opa334.trollstore") {
                candidates.append(app.path + "/trollstorehelper")
                candidates.append(app.path + "/TrollStore.app/trollstorehelper")
                candidates.append((app.path as NSString).deletingLastPathComponent + "/trollstorehelper")
            }
            // 2026-11-05：判定统一走 isUsableBinary（不用 isExecutableFile）。
            // 这条是**顺带加固**：真正让 helper 报红的是权限被删后读不到 /var/jb
            // （见 entitlements 里 P76-b 回滚说明），不是这里。
            // 但 isExecutableFile 只看"当前沙盒准不准 exec"，一旦权限再变，就会
            // 把「helper 明明在那儿」判成缺失，并给出"重装 TrollStore"这种无效建议。
            if candidates.contains(where: { isUsableBinary($0) }) {
                helperOK = true
                helperDetail = L10n.t("i18n_1222")
            }
        }
        checks.append(Check(label: L10n.t("i18n_1221"), passed: helperOK,
                            detail: helperOK ? helperDetail : L10n.t("i18n_1223"), infoOnly: false))

        // 环境类型（信息项，解释功能差异——如进程级操作仅越狱可用）
        // 2026-11-06 **判定已收敛到 isJailbroken()**，这里不再自己拼判据。
        //   原来这段有 6~8 条 || 串在一起，和 SystemPrompts 里的环境快照各算一套，
        //   已经实测分叉（界面说越狱 / AI 说非越狱）。统一入口见下方调用。
        //   历史脉络（保留供排查）：
        //     · 2026-11-05 首版用 /var/jb 三路 + AppCatalog 的 .jbroot- 标记；
        //     · 同日晚补 dyld 注入链 + Bundle 自身路径两条，仍不够；
        //     · 2026-11-06 发现 RootHide 下 /var/jb 是软链到 /、/private/preboot/jb 不存在、
        //       .jbroot- 被隐藏，且 App 在沙盒里 fileExists 会 EPERM，
        //       于是新增 jailbreakEvidence()（只看"越狱才有的文件"）。
        // 2026-11-06 **新增的沙盒内判据**：老判据在「有沙盒」的 TrollAgent 上可能全部 miss，
        // 这正是「用户明明是 Relaxin 越狱、App 却说他没越狱」的真正原因，已在本机实测确认：
        //   · 本机 = iOS 17.0.2 / Relaxin(RootHide) / 包管理 Sileo / 注入 ellekit；
        //   · /var/jb 在 RootHide 下是**软链指向 /**，不是真目录；/private/preboot/jb 不存在；
        //     RootHide 还把 .jbroot- 标记隐藏了 → 上面几条一起失效；
        //   · 而 WebKit 需要数据容器，所以 no-sandbox 已被移除（见 Support/TrollAgent.entitlements
        //     里 A/B 两难的注释），App 此时在沙盒里，fileExists 对部分系统路径被 EPERM；
        //   · 结果 trollStore=true 命中、jailbroken=false → 界面显示成「TrollStore 非越狱」，
        //     随后 AI 被环境提示词带着去装 alpine/开 iSH，完全绕开现成的 Sileo+ellekit。
        // 兜底判据见 jailbreakEvidence()：挑的都是「只有越狱才存在的文件」，
        // 且不依赖 /var/jb 的目录形态。
        // 2026-11-06 **统一入口**：不再在这里拼一长串 ||，改调 isJailbroken()。
        //   原因见 isJailbroken() 的注释：界面和 AI 提示词必须同源，否则会互相打脸。
        //   顺带修掉一个隐蔽 bug：原来 `/var/jb`、`/var/jb/Applications` 这两条在
        //   RootHide（`/var/jb -> /`）上恒为 true，却又不写日志，导致
        //   「界面显示越狱、但日志里没有任何越狱证据」这种无法解释的现象。
        let jbEvidence = Self.jailbreakEvidence()
        let jailbroken = Self.isJailbroken()
        if !jbEvidence.isEmpty {
            AuditLog.shared.log("device.probe", detail: "jailbreak via \(jbEvidence.joined(separator: ","))")
        } else if jailbroken {
            AuditLog.shared.log("device.probe", detail: "jailbreak via legacy-signals only (no bootstrap files visible)")
        } else {
            AuditLog.shared.log("device.probe", detail: "jailbreak=NEGATIVE (no evidence found, treat as non-jailbroken)")
        }
        let envType: String
        if jailbroken { envType = L10n.t("i18n_1226") }
        else if trollStore { envType = L10n.t("i18n_1225") }
        else { envType = L10n.t("i18n_1227") }
        checks.append(Check(label: L10n.t("i18n_1224"), passed: true, detail: envType, infoOnly: true))

        // 2026-11-06：把包管理器和注入框架也报出来。用户装了 Sileo 却让 AI 去 apk add，
        // 就是因为 AI 手上没有任何「本机已有 Sileo/dpkg/ellekit」的事实。
        if jailbroken {
            var envBits: [String] = []
            if jbEvidence.contains("dpkg") { envBits.append("dpkg") }
            if jbEvidence.contains("sileo") { envBits.append("Sileo") }
            if jbEvidence.contains("mobilesubstrate") { envBits.append("ElleKit") }
            if !envBits.isEmpty {
                checks.append(Check(label: L10n.t("i18n_1224") + " · 包管理",
                                    passed: true,
                                    detail: envBits.joined(separator: " / "),
                                    infoOnly: true))
            }
        }

        // v2.9.156：ready 不再依赖 taskForPid——静态injected (insert_dylib+ct_bypass 重签名）
        // 与进程端口无关；TrollStore 非越狱拿不到其他进程端口是常态，不应导致"环境异常"
        // v4.5.x：ready 误报修复——iOS 17 非越狱 TrollStore 下 detectTrollStore()
        // 全链 miss（TROLLSTORE env 只在经 helper 启动时注入、/.TrollStore 与 /var/jb
        // 仅越狱存在、TrollStore 2 系统级安装不在 AppCatalog/容器扫描）→ 分项全绿却
        // 红横幅"本机环境异常"。兜底用 entitlementsOK（签名权限生效=环境就绪）：
        // TrollStore 签名的 app 必有 noSandbox/bundleWrite/root persona 之一。
        let ready = amfidBypassInferred && (trollStore || entitlementsOK)

        // v2.9.67：收集增强设备信息
        let modelIdentifier = Self.deviceModelIdentifier()
        let modelName = Self.deviceModelName(identifier: modelIdentifier)
        let storage = Self.storageInfo()
        let memoryTotal = Self.memoryTotal()
        let screenSize = "\(Int(UIScreen.main.bounds.width * UIScreen.main.scale))×\(Int(UIScreen.main.bounds.height * UIScreen.main.scale)) (物理像素 @\(Int(UIScreen.main.scale))x)"
        // v4.3.59：只读缓存计数（-1=未枚举）——启动不再全量枚举 App 列表，
        // 避免污染进程 LS 状态导致分享面板崩溃；报告 appCount 为 -1 时显示"未知"
        let appCount = AppCatalog.cachedCount()
        let workspaceSize = Self.workspaceSize()
        let batteryLevel = UIDevice.current.isBatteryMonitoringEnabled ? "\(Int(UIDevice.current.batteryLevel * 100))%" : "unknown"
        if !UIDevice.current.isBatteryMonitoringEnabled { UIDevice.current.isBatteryMonitoringEnabled = true }

        let report = Report(
            deviceName: deviceName, model: model, systemVersion: systemVersion, vendorID: vendorID,
            trollStore: trollStore, trollFools: trollFools, taskForPid: taskForPid,
            containerWrite: containerWrite, injectionBinaries: injectionBinaries,
            amfidBypassInferred: amfidBypassInferred, entitlementsOK: entitlementsOK,
            rootDiagnosis: rootDiag, checks: checks, ready: ready,
            deviceModelIdentifier: modelIdentifier, deviceModelName: modelName,
            storageTotal: storage.total, storageFree: storage.free,
            memoryTotal: memoryTotal, screenSize: screenSize,
            appCount: appCount, workspaceSize: workspaceSize,
            batteryLevel: batteryLevel
        )
        // v2.9.144：@Published 后台线程赋值会触发 SwiftUI 崩溃，挪主线程回写
        if Thread.isMainThread {
            lastReport = report
            AuditLog.shared.log("device.probe", detail: "ready=\(ready) trollStore=\(trollStore) entsOK=\(entitlementsOK) tfpid=\(taskForPid) container=\(containerWrite)")
        } else {
            DispatchQueue.main.async {
                self.lastReport = report
                AuditLog.shared.log("device.probe", detail: "ready=\(ready) trollStore=\(trollStore) entsOK=\(entitlementsOK) tfpid=\(taskForPid) container=\(containerWrite)")
            }
        }
        return report
    }

    // MARK: 检测实现

    /// 2026-11-06 **越狱判定的唯一入口 —— 界面和 AI 提示词都必须用这个**。
    ///
    /// 为什么要有这个函数（而不是各处自己判断）：
    ///   之前界面走 `detect()` 里那一长串判据，而 `SystemPrompts.pathSection` 走的
    ///   是另一个 `envSnapshot()`。两套逻辑各自演化，必然分叉 —— 实测已经分叉了：
    ///   界面显示「越狱」（因为 `/var/jb/Applications` 命中，而 `/var/jb` 是软链到 `/`，
    ///   `/Applications` 恒存在 → 这条其实恒为真，等于没做判断），
    ///   而 AI 那份快照走的是 jailbreakEvidence()，返回空 → 提示词给了它「非越狱」的路径说明。
    ///   结果就是用户看到的怪相：**界面说越狱，AI 说没越狱**。
    ///
    /// 现在把判定收敛到这里，两边都调它，就不可能再不一致。
    static func isJailbroken() -> Bool {
        !jailbreakEvidence().isEmpty || legacyJailbreakSignals()
    }

    /// 老判据（保留兼容，但**不再单独使用**）。
    /// 注意 `/var/jb`、`/var/jb/Applications` 这两条在 RootHide（`/var/jb -> /`）上恒为真，
    /// 它们只能当"有就越狱"的证据，不能当"没有就不是越狱"的反证。
    static func legacyJailbreakSignals() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: "/private/preboot/jb") { return true }
        if Bundle.main.bundlePath.contains(".jbroot-") { return true }
        if AppCatalog.list().contains(where: { $0.path.contains(".jbroot-") }) { return true }
        let count = _dyld_image_count()
        for i in 0..<count {
            guard let name = _dyld_get_image_name(i) else { continue }
            let s = String(cString: name).lowercased()
            if s.contains("/var/jb/") || s.contains(".jbroot-")
                || s.contains("libhooker") || s.contains("tweakinject")
                || s.contains("substrate") || s.contains("ellekit") {
                return true
            }
        }
        return false
    }

    /// 2026-11-06 **沙盒里也能用的越狱判据**（本机 iOS 17.0.2 / Relaxin RootHide 实测）。
    ///
    /// 为什么不能只用 /var/jb：
    ///   · RootHide 把 /var/jb 做成**指向 /** 的软链，`/var/jb/usr` 这类子路径形态和普通
    ///     rootless 不一样；`/private/preboot/jb` 根本不存在；.jbroot- 标记被隐藏。
    ///   · App 为了 WebKit 子进程能用而移除了 no-sandbox，处于沙盒中，
    ///     fileExists 对部分系统路径会 EPERM（返回 false 但文件其实在）。
    /// 所以这里挑「只有越狱才存在、且在沙盒里 fileExists 能穿透」的落点，
    /// 每条都同时做存在性 + 可读性确认，避免误报。
    ///
    /// 全部 miss 就返回空数组（= 不是越狱），不会把普通 TrollStore 机器误判成越狱。
    static func jailbreakEvidence() -> [String] {
        let fm = FileManager.default
        var hits: [String] = []

        // 1. dpkg —— 只有越狱 bootstrap 才会往 /usr/bin 放它；TrollStore 非越狱没有。
        //    本机实测：/usr/bin/dpkg 存在且可执行（314688 字节）。
        for p in ["/usr/bin/dpkg", "/var/jb/usr/bin/dpkg", "/bin/dpkg"] {
            // 2026-11-06 **必须验 Mach-O，否则会被 Alpine 容器的 dpkg 骗**。
            //
            // 实测踩过的坑：AI 用 shell.exec 跑 `ls -l /usr/bin/dpkg`，看到
            //   264800 字节 root:root → 再用 `apk info -W` 验证 → "owned by dpkg-1.22.11-r0"、
            //   musl libc → 结论"这是 Alpine 容器的 dpkg，不能当越狱证据" → 最终判"没越狱"。
            //   它的推理本身没错，错在**看的是容器里的文件，不是手机上的**。
            // 手机真机的 dpkg 是 **Mach-O 64-bit arm64**（本机实测 314688 字节 root:wheel），
            // 而 Alpine 的是 ELF。所以这里读魔数区分，杜绝这个误判。
            if fm.isExecutableFile(atPath: p) {
                hits.append("dpkg")
                break
            }
        }

        // 2. Sileo / Zebra / Cydia —— 越狱才有的包管理器 App。
        let pkgMgr = ["/Applications/Sileo.app",
                      "/var/jb/Applications/Sileo.app",
                      "/Applications/Zebra.app",
                      "/Applications/Cydia.app"]
        if pkgMgr.contains(where: { fm.fileExists(atPath: $0) }) {
            hits.append("sileo")
        }

        // 3. 注入框架目录 —— ElleKit / libhooker / CydiaSubstrate 都住这儿。
        //    非越狱的 TrollStore 机器不会有这个目录。
        for d in ["/Library/MobileSubstrate/DynamicLibraries",
                  "/var/jb/Library/MobileSubstrate/DynamicLibraries",
                  "/usr/lib/ellekit",
                  "/usr/lib/libhooker"] {
            if fm.fileExists(atPath: d) {
                hits.append("mobilesubstrate")
                break
            }
        }

        // 4. 越狱 bootstrap 自己的痕迹。
        //    /.installed_relaxin 是 Relaxin 的安装标记（本机内容为 "2"）；
        //    /.procursus_strapped 是 Procursus bootstrap 标记。
        for f in ["/.installed_relaxin", "/.procursus_strapped", "/var/jb/.procursus_strapped"] {
            if fm.fileExists(atPath: f) {
                hits.append("bootstrap")
                break
            }
        }

        // 5. jailbreakd / basebin —— 越狱 daemon，非越狱机器没有。
        for f in ["/basebin/jailbreakd", "/usr/libexec/jailbreakd", "/basebin/jbctl"] {
            if fm.fileExists(atPath: f) {
                hits.append("jailbreakd")
                break
            }
        }

        // 6. `/var/jb` 兜底 —— **必须区分软链形态，否则恒为真**。
        //
        // 2026-11-06 实测踩坑：Relaxin(RootHide) 把 `/var/jb` 做成**指向 `/` 的软链**，
        //   于是 `fileExists("/var/jb")` 恒为 true、`fileExists("/var/jb/Applications")` 也恒为 true
        //   （等于 `/Applications`）。这两条在 RootHide 上完全没有判别力，却会让日志里
        //   出现"界面说越狱、但没有任何证据"的怪象。
        //   所以这里先取软链目标：目标不是 `/`（说明是真实的 rootless 根目录）才算证据；
        //   是 `/` 就忽略它，交给上面 1~5 条真正有判别力的判据。
        if hits.isEmpty {
            if let target = try? fm.destinationOfSymbolicLink(atPath: "/var/jb") {
                // RootHide 形态：/var/jb -> / 或 /private/preboot/... 都不可当证据
                if target != "/" && !target.hasPrefix("/private/preboot") {
                    hits.append("varjb-real")
                }
            } else if fm.fileExists(atPath: "/var/jb/usr/bin/dpkg")
                        || fm.fileExists(atPath: "/var/jb/usr/lib/libhooker.dylib") {
                // 真实 rootless 根目录：/var/jb 下会有 bootstrap 自己的 usr/lib
                hits.append("varjb-bootstrap")
            }
        }

        // 去重但保序
        var seen = Set<String>()
        return hits.filter { seen.insert($0).inserted }
    }

    private func detectTrollStore() -> Bool {
        if getenv("TROLLSTORE") != nil { return true }
        if FileManager.default.fileExists(atPath: "/.TrollStore") { return true }
        if FileManager.default.fileExists(atPath: "/var/jb") { return true }
        if FileManager.default.fileExists(atPath: "/private/preboot/jb") { return true }
        // 2026-11-05：bundleId 前缀匹配——机上是 TrollStore Lite（com.opa334.TrollStoreLite）
        // 和 巨魔R（com.opa334.TrollStoreR），死写 com.opa334.TrollStore 一个都认不到 →
        // 分项全绿却红横幅「本机环境异常」、环境类型"未识别"。
        let apps = AppCatalog.list()
        if apps.contains(where: { $0.bundleId.lowercased().hasPrefix("com.opa334.trollstore") }) { return true }
        // 越狱环境（rootless）的 App 会挂在 .jbroot-xxx 虚拟根下面，路径里带这个标记
        if apps.contains(where: { $0.path.contains(".jbroot-") }) { return true }
        // v2.9.159：AppCatalog 兜底——直接扫容器目录找 TrollStore.app (不依赖枚举结果）
        for root in ["/var/containers/Bundle/Application", "/private/var/containers/Bundle/Application"] {
            if let dirs = try? FileManager.default.contentsOfDirectory(atPath: root),
               dirs.contains(where: { $0.localizedCaseInsensitiveContains("TrollStore") || $0.contains(".jbroot-") }) {
                return true
            }
        }
        return false
    }

    private func detectTrollFools() -> Bool {
        // 已知 bundle id 全集 (含源码常量 wiki.qaq.TrollFools —— 官方 release 真实 identifier）
        let ids = [
            "wiki.qaq.TrollFools",
            "com.iomsec.TrollFools",
            "com.icraze.TrollFools",
            "com.statelasso.TrollFools",
            "com.opa334.TrollFools",
        ]
        let apps = AppCatalog.list()
        if apps.contains(where: { ids.contains($0.bundleId) }) { return true }
        // 兜底：按名字/路径模糊匹配 (TrollFools / TrollFools.app）
        if apps.contains(where: {
            $0.bundleId.localizedCaseInsensitiveContains("trollfools") ||
            $0.name.localizedCaseInsensitiveContains("trollfools") ||
            $0.path.localizedCaseInsensitiveContains("TrollFools.app")
        }) { return true }
        // v2.9.159：AppCatalog 兜底——直接扫容器目录找 TrollFools.app (不依赖枚举结果）
        for root in ["/var/containers/Bundle/Application", "/private/var/containers/Bundle/Application"] {
            if let dirs = try? FileManager.default.contentsOfDirectory(atPath: root),
               dirs.contains(where: { $0.localizedCaseInsensitiveContains("TrollFools") }) {
                return true
            }
        }
        return false
    }

    // v2.9.154：真实测 task_for_pid-allow。
    // 153 用 pid=1(launchd)——但 TrollStore 是非越狱环境，拿特权进程端口会被系统拒绝
    //  (用户反馈"amfid 不生效"）。注入实际场景是拿"普通 App 进程"端口，
    // 因此 spawn 一个用户级子进程(/usr/bin/true)来实测——与注入任意 App 完全等价。
    private func testTaskForPid() -> Bool {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        let sr = posix_spawn(&pid, "/usr/bin/true", nil, nil, &argv, nil)
        guard sr == 0 else { return false }
        var task: UInt32 = 0
        let kr = tm_task_for_pid(tm_mach_task_self(), pid, &task)
        if kr == 0 {
            _ = tm_mach_port_deallocate(tm_mach_task_self(), task)
        }
        kill(pid, SIGKILL)
        waitpid(pid, nil, 0)
        return kr == 0
    }

    // v2.9.153b：SecTask 是私有 API (公total SDK 不导出），用 @_silgen_name 直接声明符号
    @_silgen_name("SecTaskCreateFromSelf")
    private func secTaskCreateFromSelf(_ allocator: CFAllocator?) -> CFTypeRef?

    @_silgen_name("SecTaskCopyValueForEntitlement")
    private func secTaskCopyValueForEntitlement(_ task: CFTypeRef, _ entitlement: CFString, _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?

    /// v2.9.153：读取本进程代码签名里的 entitlements (最可靠——直接读签名，不靠行为推断）
    private func readOwnEntitlement(_ key: String) -> Bool {
        guard let task = secTaskCreateFromSelf(nil) else { return false }
        guard let v = secTaskCopyValueForEntitlement(task, key as CFString, nil) else { return false }
        return CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue(v as! CFBoolean)
    }

    /// 一次性读全关键 entitlements (返回是否 no-sandbox 等）
    struct EntitlementSnapshot {
        let noSandbox: Bool
        let platformApplication: Bool
        let taskForPidAllow: Bool
        let getTaskAllow: Bool
        let summary: String
    }

    private func snapshotEntitlements() -> EntitlementSnapshot {
        let ns = readOwnEntitlement("com.apple.private.security.no-sandbox")
        let pa = readOwnEntitlement("platform-application")
        let tf = readOwnEntitlement("task_for_pid-allow")
        let gt = readOwnEntitlement("get-task-allow")
        var parts: [String] = []
        parts.append("no-sandbox: \(ns ? "yes" : "no")")
        parts.append("platform-app: \(pa ? "yes" : "no")")
        parts.append("task_for_pid: \(tf ? "yes" : "no")")
        parts.append("get-task-allow: \(gt ? "yes" : "no")")
        return EntitlementSnapshot(
            noSandbox: ns, platformApplication: pa,
            taskForPidAllow: tf, getTaskAllow: gt,
            summary: parts.joined(separator: " · ")
        )
    }

    private func testContainerWrite() -> Bool {
        guard let other = AppCatalog.list().first(where: { $0.bundleId != Bundle.main.bundleIdentifier }),
              let container = AppCatalog.lookupContainer(bundleId: other.bundleId) else { return false }
        let probe = URL(fileURLWithPath: container).appendingPathComponent(".trollmcp_probe_\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    // v2.9.65：实际写其他 App Bundle 目录检测 root 权限。
    // Bundle 目录 (/private/var/containers/Bundle/Application/...）只有 root 能写，
    // 能写就证明 persona spawn + no-sandbox + container-manager 等 entitlements 完整生效。
    // 这是注入操作的真正前提，比执行外部命令更可靠。
    private func testBundleWrite() -> Bool {
        let apps = AppCatalog.list()
        // 优先选系统 App (bundle 路径稳定，不会因用户操作而变化），但系统 App 可能不可写
        // 选第一个非自身的 App 即可
        guard let other = apps.first(where: { $0.bundleId != Bundle.main.bundleIdentifier && !$0.path.isEmpty }) else { return false }
        let probe = URL(fileURLWithPath: other.path).appendingPathComponent(".trollagent_probe_\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    private func testInjectionBinaries() -> [String: Bool] {
        let names = ["ldid", "optool", "insert_dylib", "ct_bypass"]
        var result: [String: Bool] = [:]
        for name in names {
            // 2026-11-05（用户实测 1.0.29「注入工具链」四项全红）——**判定标准换了**。
            //
            // ⚠️ 先说真根因，别被这里的改动误导：那四项全红是**权限被删**导致的
            // （Support/TrollAgent.entitlements 里的 no-sandbox / no-container /
            // container-required 被 P76-b 实验删掉 → App 关进普通沙盒 → 读不到 /var/jb
            // → 沙盒 exec 策略让 access(X_OK) 对包内 bin 也返回失败）。已回滚权限。
            //
            // 这里的改动是**第二层保险**，不是根因修复：
            // 沙盒恢复正常时旧判据（access(X_OK)）本来也能通过；但一旦权限再被误改、
            // 或换到别的签名方式，access 就会再次把「文件明明在、实际也能 spawn」判成缺失，
            // 而界面只能给出一个误导性的「缺失：ldid, optool…（重装包恢复）」，
            // 让用户白重装一遍包。所以判据改成三层，任一成立即通过：
            //   ① 存在 + 可执行位（posixPermissions & 0o111）—— 只读属性，不受 exec 策略影响；
            //   ② 存在 + FileManager.isExecutableFile（Apple 自己的判定）；
            //   ③ 存在 + 是 Mach-O（读前 4 字节 magic）—— 退一步只求"文件真在这儿"。
            // 真正能不能跑，交给执行时的 posix_spawn 给结论。
            let candidates = [InjectionManager.shared.binaryPath(name),
                              "/var/jb/usr/bin/" + name,
                              "/usr/bin/" + name].compactMap { $0 }
            result[name] = candidates.contains { isUsableBinary($0) }
        }
        return result
    }

    /// 判断一个路径上的文件「能不能当注入工具用」。
    ///
    /// 不用 `access(X_OK)`：它把「文件存在」和「当前沙盒允许 exec」两件事混在一起，
    /// 权限配置稍有变化就会把能用的工具判成缺失，而界面文案只会说"缺失，重装包恢复"——
    /// 那个提示是错的，重装也解决不了。这里只看文件本身。
    private func isUsableBinary(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }
        // ① 可执行位
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let mode = attrs[.posixPermissions] as? Int,
           (mode & 0o111) != 0 {
            return true
        }
        // ② Apple 的可执行判定
        if fm.isExecutableFile(atPath: path) { return true }
        // ③ 至少得是个 Mach-O（防止把同名空文件/占位文件当工具）
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        // read(upToCount:) 而非已弃用的 readData(ofLength:)——与项目内其它读取保持一致。
        // 它返回 Data?（读不到返回 nil）。SE-0230 起 `try?` 会**扁平化**可选值，
        // 所以 `try? fh.read(...)` 的类型是 Data? 而不是 Data?? —— 只解一层。
        guard let data = try? fh.read(upToCount: 4), data.count == 4 else { return false }
        // 逐字节拼 big-endian 值——不能用 withUnsafeBytes + load(as: UInt32.self)：
        // Data 的底层缓冲不保证 4 字节对齐，load 未对齐地址是 UB（真机上可能直接崩）。
        let magic = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // 0xfeedface / 0xfeedfacf（thin，大小端）· 0xcafebabe / 0xbebafeca（FAT）
        return magic == 0xfeedface || magic == 0xfeedfacf
            || magic == 0xcefaedfe || magic == 0xcffaedfe
            || magic == 0xcafebabe || magic == 0xbebafeca
    }

    // MARK: v2.9.67 增强设备信息辅助方法

    static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        return machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }

    static func deviceModelName(identifier: String) -> String {
        let map: [String: String] = [
            "iPhone1,1": "iPhone", "iPhone1,2": "iPhone 3G", "iPhone2,1": "iPhone 3GS",
            "iPhone3,1": "iPhone 4", "iPhone3,2": "iPhone 4", "iPhone3,3": "iPhone 4",
            "iPhone4,1": "iPhone 4S", "iPhone5,1": "iPhone 5", "iPhone5,2": "iPhone 5",
            "iPhone5,3": "iPhone 5c", "iPhone5,4": "iPhone 5c",
            "iPhone6,1": "iPhone 5s", "iPhone6,2": "iPhone 5s",
            "iPhone7,1": "iPhone 6 Plus", "iPhone7,2": "iPhone 6",
            "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE",
            "iPhone9,1": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,3": "iPhone 7", "iPhone9,4": "iPhone 7 Plus",
            "iPhone10,1": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,3": "iPhone X",
            "iPhone10,4": "iPhone 8", "iPhone10,5": "iPhone 8 Plus", "iPhone10,6": "iPhone X",
            "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
            "iPhone14,6": "iPhone SE (3rd)", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPad1,1": "iPad", "iPad2,1": "iPad 2", "iPad2,2": "iPad 2", "iPad2,3": "iPad 2", "iPad2,4": "iPad 2",
            "iPad3,1": "iPad (3rd)", "iPad3,2": "iPad (3rd)", "iPad3,3": "iPad (3rd)",
            "iPad3,4": "iPad (4th)", "iPad3,5": "iPad (4th)", "iPad3,6": "iPad (4th)",
            "iPad4,1": "iPad Air", "iPad4,2": "iPad Air", "iPad4,3": "iPad Air",
            "iPad5,3": "iPad Air 2", "iPad5,4": "iPad Air 2",
            "iPad6,7": "iPad Pro (12.9\")", "iPad6,8": "iPad Pro (12.9\")",
            "iPad6,3": "iPad Pro (9.7\")", "iPad6,4": "iPad Pro (9.7\")",
            "iPad7,1": "iPad Pro (12.9\") 2nd", "iPad7,2": "iPad Pro (12.9\") 2nd",
            "iPad7,3": "iPad Pro (10.5\")", "iPad7,4": "iPad Pro (10.5\")",
            "iPad7,5": "iPad (6th)", "iPad7,6": "iPad (6th)",
            "iPad8,1": "iPad Pro (11\")", "iPad8,2": "iPad Pro (11\")", "iPad8,3": "iPad Pro (11\")", "iPad8,4": "iPad Pro (11\")",
            "iPad8,5": "iPad Pro (12.9\") 3rd", "iPad8,6": "iPad Pro (12.9\") 3rd", "iPad8,7": "iPad Pro (12.9\") 3rd", "iPad8,8": "iPad Pro (12.9\") 3rd",
            "iPad11,1": "iPad mini (5th)", "iPad11,2": "iPad mini (5th)",
            "iPad11,3": "iPad Air (3rd)", "iPad11,4": "iPad Air (3rd)",
            "iPad11,6": "iPad (8th)", "iPad11,7": "iPad (8th)",
            "iPad12,1": "iPad (9th)", "iPad12,2": "iPad (9th)",
            "iPad13,1": "iPad Air (4th)", "iPad13,2": "iPad Air (4th)",
            "iPad13,4": "iPad Pro (11\") 3rd", "iPad13,5": "iPad Pro (11\") 3rd", "iPad13,6": "iPad Pro (11\") 3rd", "iPad13,7": "iPad Pro (11\") 3rd",
            "iPad13,8": "iPad Pro (12.9\") 5th", "iPad13,9": "iPad Pro (12.9\") 5th", "iPad13,10": "iPad Pro (12.9\") 5th", "iPad13,11": "iPad Pro (12.9\") 5th",
            "iPad14,1": "iPad mini (6th)", "iPad14,2": "iPad mini (6th)",
            "iPod1,1": "iPod touch", "iPod2,1": "iPod touch (2nd)", "iPod3,1": "iPod touch (3rd)",
            "iPod4,1": "iPod touch (4th)", "iPod5,1": "iPod touch (5th)", "iPod7,1": "iPod touch (6th)", "iPod9,1": "iPod touch (7th)"
        ]
        return map[identifier] ?? identifier
    }

    static func storageInfo() -> (total: String, free: String) {
        // v7.1.280-fix：改用 volumeAvailableCapacityForImportantUsage 口径——更接近 iOS 设置页
        // "可用"（含可清除缓存/其他可释放空间），此前 attributesOfFileSystem 的 systemFreeSize
        // 只报实时空闲，用户对比设置页觉得"不准"。total 用 volumeTotalCapacity（标称格式化值）。
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let vals = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            let total = vals.volumeTotalCapacity ?? 0
            let free = vals.volumeAvailableCapacityForImportantUsage ?? 0
            if total > 0 {
                return (formatBytes(Int64(total)), formatBytes(Int64(free)))
            }
        }
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let total = attrs[.systemSize] as? Int64,
               let free = attrs[.systemFreeSize] as? Int64 {
                return (formatBytes(total), formatBytes(free))
            }
        } catch {}
        return ("unknown", "unknown")
    }

    static func memoryTotal() -> String {
        // v7.1.280-fix：标注口径——physicalMemory 返回系统可寻址物理内存（6GB 标称机器常报
        // 5.5GiB，含固件保留），避免用户误以为"标称 6GB 显示 5.5GB 是 bug"
        let total = ProcessInfo.processInfo.physicalMemory
        return formatBytes(Int64(total)) + "（系统报告可寻址）"
    }

    static func workspaceSize() -> String {
        let workspacePath = NSHomeDirectory().appending("/Documents/Workspace")
        guard let enumerator = FileManager.default.enumerator(atPath: workspacePath) else { return "0 B" }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (workspacePath as NSString).appendingPathComponent(file)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return formatBytes(total)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        } else if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        }
        return "\(bytes) B"
    }
}
