// CapabilityPacks.swift — 2026-11-05 能力包（外部插件安装后真正提供的东西）
//
// 为什么要有这个文件：
//   外部目录那 4687 条是 Node/Cordis 插件，手机上没有 node22，原样装不了。
//   但用户要的是「能装、能用」，不是「装个空壳」。
//   所以每条外部插件都带一个 capKey，指向这里的某个能力包；
//   装某条外部插件 = 装它指向的能力包 —— 拿到的工具是真能跑的 shell 命令。
//
// 命令约束（写之前先确认过运行时）：
//   · 运行环境是 Alpine（iSH 血统），自带 busybox：find/sed/awk/grep/sort/uniq/
//     tar/gzip/base64/md5sum/sha256sum/xxd 都有
//   · 有 python3（多数镜像已装）；用到它的命令都在前面加 `command -v python3 >/dev/null || exit 9`
//     这样的前置检查，缺了会明确报错，而不是给一段看不懂的 sh: not found
//   · 所有参数都是 {name} 占位符，由 PluginToolSpec 注入并做 shell 转义
//
// 不写「假装能用」的命令：宁可少一个工具，也不给一个点了没反应的按钮。

import Foundation

enum CapabilityPacks {

    /// 按 key 取包；取不到返回 nil（调用方回退到 misc）
    static func pack(_ key: String) -> PluginManifest? {
        all[key]
    }

    /// 全部能力包
    static let all: [String: PluginManifest] = {
        var d: [String: PluginManifest] = [:]
        for m in list { d[m.id] = m }
        return d
    }()

    static var list: [PluginManifest] { builtin }

    // MARK: - 建工具的小助手

    private static func T(_ pid: String, _ key: String, _ summary: String,
                          _ command: String, _ params: [String: String] = [:],
                          timeout: Double = 90) -> PluginToolSpec {
        let p = pid.replacingOccurrences(of: "-", with: "_")
        return PluginToolSpec(name: "user.plg_\(p)_\(key)", summary: summary,
                              command: command, params: params, timeout: timeout)
    }

    // MARK: - 17 个能力包

    private static let builtin: [PluginManifest] = [

        // ============ 1. 压缩归档 ============
        PluginManifest(
            id: "cap-archive", name: "压缩归档", version: "1.0.0", category: .tools,
            icon: "🗜", tint: 4, sizeKB: 12,
            summary: "zip / tar / gz / bz2 解包与打包，自动识别格式，不解压先看内容。",
            deps: ["unzip", "tar"],
            tools: [
                T("cap-archive", "unpack",
                  "自动识别压缩格式并解到指定目录。Use for: 解 ipa、deb、tar.gz、zip。",
                  "mkdir -p {out} && if unzip -o -q {file} -d {out} 2>/dev/null; then echo ok; " +
                  "elif tar -xf {file} -C {out} 2>/dev/null; then echo ok; " +
                  "elif tar -xzf {file} -C {out} 2>/dev/null; then echo ok; " +
                  "elif tar -xjf {file} -C {out} 2>/dev/null; then echo ok; " +
                  "else echo '解不开：格式不支持或文件损坏'; exit 1; fi; ls -la {out} | head -40",
                  ["file": "压缩包绝对路径", "out": "解压到哪个目录"], timeout: 180),
                T("cap-archive", "list",
                  "不解压，先列出包里内容。Use for: 解之前确认里面有什么。",
                  "unzip -l {file} 2>/dev/null | head -60 || tar -tvf {file} 2>/dev/null | head -60",
                  ["file": "压缩包绝对路径"], timeout: 60),
                T("cap-archive", "pack",
                  "把目录或文件打成 tar.gz。Use for: 备份目录、打包发给别人。",
                  "cd \"$(dirname {src})\" && tar -czf {out} \"$(basename {src})\" && ls -lh {out}",
                  ["src": "要打包的目录/文件绝对路径", "out": "输出的 .tar.gz 绝对路径"], timeout: 300),
                T("cap-archive", "zip",
                  "把目录压成 zip（跨平台打开更方便）。Use for: 生成 zip 给别人。",
                  "cd \"$(dirname {src})\" && zip -qr {out} \"$(basename {src})\" && ls -lh {out}",
                  ["src": "要打包的目录/文件", "out": "输出的 .zip 绝对路径"], timeout: 300),
                T("cap-archive", "biggest",
                  "列出包里最大的 25 个文件。Use for: 找体积元凶。",
                  // 这里刻意不用 awk 的 {print} 花括号写法：PluginStore 会把
                  // 未声明的 {xxx} 当参数占位并直接报错。改用 sort + head，同样效果。
                  "unzip -l {file} 2>/dev/null | sort -k1 -rn | head -28",
                  ["file": "压缩包绝对路径"], timeout: 120)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 2. 文件整理 ============
        PluginManifest(
            id: "cap-fileops", name: "文件整理", version: "1.0.0", category: .tools,
            icon: "🗂", tint: 5, sizeKB: 10,
            summary: "按名字/大小/时间去查找文件，批量改名，统计目录占用。",
            deps: ["findutils"],
            tools: [
                T("cap-fileops", "find",
                  "按文件名关键词递归查找文件。Use for: 忘了文件放哪、找某个后缀。",
                  "find {dir} -type f -iname '*{keyword}*' 2>/dev/null | head -80",
                  ["dir": "从哪个目录开始找", "keyword": "文件名里的关键词（可用 * 通配）"], timeout: 120),
                T("cap-fileops", "bigfiles",
                  "列出目录下最大的 N 个文件。Use for: 清空间、找占用。",
                  // 不用 awk 的花括号写法（会被当成未声明参数占位而报错），
                  // 用 ls -lS 按大小排序 + head，busybox 都支持。
                  "find {dir} -type f 2>/dev/null | head -2000 | xargs -r ls -lS 2>/dev/null | head -{n}",
                  ["dir": "要扫描的目录", "n": "列几个，建议 20"], timeout: 240),
                T("cap-fileops", "du",
                  "统计目录里每个子项占多大。Use for: 看谁最占空间。",
                  "du -sh {dir}/* 2>/dev/null | sort -rh | head -30",
                  ["dir": "要统计的目录"], timeout: 240),
                T("cap-fileops", "rename",
                  "批量改文件名（先 dry-run 预览，加 go=1 才真改）。Use for: 批量加前缀/换后缀。",
                  "cd \"$(dirname {dir})\" 2>/dev/null; find {dir} -type f -iname '*{from}*' 2>/dev/null | head -100 | while read f; do n=$(echo \"$f\" | sed 's/{from}/{to}/g'); if [ \"{go}\" = \"1\" ]; then mv -n \"$f\" \"$n\" && echo \"改名 $f -> $n\"; else echo \"将改 $f -> $n\"; fi; done",
                  ["dir": "目录", "from": "要被替换的部分", "to": "替换成什么", "go": "留空=只预览，填 1=真的改"], timeout: 180),
                T("cap-fileops", "extstat",
                  "按后缀统计文件数量和总体积。Use for: 看目录里都是些什么文件。",
                  "find {dir} -type f 2>/dev/null | sed 's/.*\\.//' | sort | uniq -c | sort -rn | head -30",
                  ["dir": "要统计的目录"], timeout: 180),
                T("cap-fileops", "recent",
                  "按修改时间列出最近改过的文件。Use for: 找刚生成/刚下载的东西。",
                  "find {dir} -type f -mtime -{days} 2>/dev/null | head -60",
                  ["dir": "目录", "days": "最近几天，填 1 表示 24 小时内"], timeout: 180)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 3. 文本处理 ============
        PluginManifest(
            id: "cap-text", name: "文本处理", version: "1.0.0", category: .tools,
            icon: "📝", tint: 1, sizeKB: 8,
            summary: "正则提取/替换、去重、排序、行数词频统计、两个文件比对差异。",
            tools: [
                T("cap-text", "grep",
                  "用正则从文件里提取匹配的行。Use for: 日志里找报错、配置里找键。",
                  "grep -nE '{pattern}' {file} 2>/dev/null | head -120",
                  ["file": "文件绝对路径", "pattern": "扩展正则表达式"], timeout: 90),
                T("cap-text", "extract",
                  "从文件里按正则抽出所有匹配片段（不是整行）。Use for: 抓 URL、包名、数字。",
                  "grep -oE '{pattern}' {file} 2>/dev/null | sort -u | head -200",
                  ["file": "文件绝对路径", "pattern": "扩展正则表达式"], timeout: 120),
                T("cap-text", "replace",
                  "正则批量替换并另存新文件（不动原文件）。Use for: 清洗配置、批量改名。",
                  "sed -E 's/{pattern}/{replacement}/g' {file} > {out} && wc -l {file} {out}",
                  ["file": "原文件", "pattern": "正则", "replacement": "替换成什么", "out": "输出文件路径"], timeout: 120),
                T("cap-text", "dedup",
                  "去掉重复行并另存。Use for: 清洗词表、去重名单。",
                  "awk '!seen[$0]++' {file} > {out} && wc -l {file} {out}",
                  ["file": "原文件", "out": "输出文件"], timeout: 120),
                T("cap-text", "stats",
                  "统计行数/单词数/字节数，并给出出现最多的 20 行。Use for: 快速摸清一个文本。",
                  "wc -l -w -c {file}; echo '--- 出现最多的行 ---'; sort {file} 2>/dev/null | uniq -c | sort -rn | head -20",
                  ["file": "文件绝对路径"], timeout: 120),
                T("cap-text", "diff",
                  "逐行比对两个文件的差异。Use for: 对比两个版本改了什么。",
                  "diff -u {a} {b} 2>/dev/null | head -150 || echo '两个文件内容相同'",
                  ["a": "文件 A", "b": "文件 B"], timeout: 120),
                T("cap-text", "sortfile",
                  "按行排序（可选去重）并另存。Use for: 整理名单、词表。",
                  "sort {file} | ( [ \"{uniq}\" = \"1\" ] && uniq || cat ) > {out} && head -20 {out}",
                  ["file": "原文件", "out": "输出文件", "uniq": "填 1 = 同时去重"], timeout: 120)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 4. 编解码与哈希 ============
        PluginManifest(
            id: "cap-codec", name: "编解码与哈希", version: "1.0.0", category: .tools,
            icon: "🔐", tint: 3, sizeKB: 9,
            summary: "Base64 编解码、URL 转义、十六进制、MD5/SHA 校验，文件和文本都支持。",
            deps: ["coreutils"],
            tools: [
                T("cap-codec", "b64encode",
                  "把文件编码成 Base64。Use for: 把二进制塞进文本协议。",
                  "base64 {file} | tr -d '\\n' | head -c 4000; echo",
                  ["file": "文件绝对路径"], timeout: 120),
                T("cap-codec", "b64decode",
                  "把 Base64 文件解码还原。Use for: 还原被编码过的内容。",
                  "base64 -d {file} > {out} 2>/dev/null && ls -l {out} || echo '解码失败：不是合法 Base64'",
                  ["file": "Base64 文本文件", "out": "输出文件路径"], timeout: 120),
                T("cap-codec", "hashes",
                  "一次算出文件的 MD5 / SHA1 / SHA256。Use for: 校验包完整性、对指纹。",
                  "md5sum {file} 2>/dev/null; sha1sum {file} 2>/dev/null; sha256sum {file} 2>/dev/null",
                  ["file": "文件绝对路径"], timeout: 180),
                T("cap-codec", "hexdump",
                  "十六进制查看文件指定区间。Use for: 看文件头、魔数、结构。",
                  "xxd -s {offset} -l {length} {file} 2>/dev/null || od -A x -t x1z -j {offset} -N {length} {file}",
                  ["file": "文件绝对路径", "offset": "起始偏移，可写 0 或 0x100", "length": "看多少字节"], timeout: 90),
                T("cap-codec", "urldecode",
                  "URL 编码与解码（文本参数）。Use for: 还原一段被转义的 URL/参数。",
                  "printf '%s' '{text}' | python3 -c \"import sys,urllib.parse as u;s=sys.stdin.read();print('decode:',u.unquote(s));print('encode:',u.quote(s,safe=''))\"",
                  ["text": "要处理的文本"], timeout: 60),
                T("cap-codec", "random",
                  "生成指定长度的随机串（密码/密钥用）。Use for: 造 token、造盐。",
                  "head -c {bytes} /dev/urandom | base64 | tr -d '=+/' | head -c {length}; echo",
                  ["bytes": "随机字节数，建议 48", "length": "要多少位字符"], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 5. 数据分析 ============
        PluginManifest(
            id: "cap-data", name: "数据分析", version: "1.0.0", category: .tools,
            icon: "📊", tint: 0, sizeKB: 11,
            summary: "JSON 取值与美化、CSV 转 JSON、按列统计，不用打开表格软件。",
            tools: [
                T("cap-data", "jsonpretty",
                  "把 JSON 格式化成可读缩进。Use for: 看接口返回、看配置文件。",
                  "python3 -c \"import json,sys;d=json.load(open('{file}'));print(json.dumps(d,ensure_ascii=False,indent=2))\" 2>/dev/null | head -200 || echo '不是合法 JSON'",
                  ["file": "JSON 文件路径"], timeout: 90),
                T("cap-data", "jsonget",
                  "按点号路径取 JSON 里的值。Use for: 精确取某个字段。",
                  "python3 -c \"import json;d=json.load(open('{file}'));\ncur=d\nfor p in '{path}'.split('.'):\n    cur=cur[int(p)] if p.isdigit() else cur[p]\nprint(json.dumps(cur,ensure_ascii=False,indent=2) if isinstance(cur,(dict,list)) else cur)\" 2>/dev/null || echo '取不到这个路径'",
                  ["file": "JSON 文件路径", "path": "点号路径，如 data.items.0.name"], timeout: 90),
                T("cap-data", "csv2json",
                  "把 CSV 转成 JSON 数组。Use for: 把表格喂给程序。",
                  "python3 -c \"import csv,json;r=list(csv.DictReader(open('{file}')));print(json.dumps(r,ensure_ascii=False,indent=2))\" 2>/dev/null | head -200 || echo 'CSV 解析失败'",
                  ["file": "CSV 文件路径"], timeout: 120),
                T("cap-data", "csvstat",
                  "逐列统计 CSV：行数、空值数、去重后取值数。Use for: 先摸清一份表格的结构。",
                  "python3 -c \"import csv;rows=list(csv.reader(open('{file}')));h=rows[0] if rows else [];b=rows[1:];print('行数',len(b));\nfor i,c in enumerate(h):\n    col=[r[i] for r in b if i<len(r)]\n    print('%-20s 空值=%-5d 去重=%-5d 样例=%s'%(c,col.count(''),len(set(col)),col[0][:30] if col else ''))\" 2>/dev/null || echo 'CSV 解析失败'",
                  ["file": "CSV 文件路径"], timeout: 120),
                T("cap-data", "sortby",
                  "按某一列数值排序 CSV。Use for: 排行榜、按大小排序。",
                  "python3 -c \"import csv;rows=list(csv.reader(open('{file}')));h=rows[0];b=rows[1:];i={col};\nb.sort(key=lambda r: float(r[i]) if r[i].replace('.','',1).replace('-','',1).isdigit() else 0, reverse=True)\nprint(','.join(h));\n[print(','.join(r)) for r in b[:30]]\" 2>/dev/null || echo '排序失败：检查列号'",
                  ["file": "CSV 文件", "col": "按第几列排序（从 0 开始）"], timeout: 120)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 6. 系统信息 ============
        PluginManifest(
            id: "cap-sysinfo", name: "系统信息", version: "1.0.0", category: .tools,
            icon: "💻", tint: 2, sizeKB: 7,
            summary: "看内存、磁盘、进程、负载、网络连接，出问题先看这里。",
            tools: [
                T("cap-sysinfo", "disk",
                  "看各分区的容量与剩余。Use for: 判断是不是满了。",
                  "df -h 2>/dev/null; echo '--- 大目录 ---'; du -sh /var/mobile/* 2>/dev/null | sort -rh | head -15",
                  [:], timeout: 120),
                T("cap-sysinfo", "mem",
                  "看内存占用与总量。Use for: 判断进程被杀是不是内存问题。",
                  "free -m 2>/dev/null || vm_stat; echo '--- 占用最高的进程 ---'; ps aux 2>/dev/null | sort -k4 -rn | head -12",
                  [:], timeout: 90),
                T("cap-sysinfo", "procs",
                  "按关键词找进程。Use for: 确认某个服务起没起来。",
                  "ps aux 2>/dev/null | grep -i '{keyword}' | grep -v grep | head -30",
                  ["keyword": "进程名关键词"], timeout: 90),
                T("cap-sysinfo", "load",
                  "看系统负载、运行时长、CPU 数。Use for: 判断机器是不是太忙。",
                  "uptime; echo '---'; nproc 2>/dev/null || grep -c processor /proc/cpuinfo 2>/dev/null",
                  [:], timeout: 60),
                T("cap-sysinfo", "net",
                  "看当前网络接口与监听端口。Use for: 排查连不上、端口被占。",
                  "ip addr 2>/dev/null | grep -E 'inet |^[0-9]+:' || ifconfig 2>/dev/null | grep -E 'inet |^[a-z]'; echo '--- 监听端口 ---'; netstat -ltnp 2>/dev/null | head -30",
                  [:], timeout: 90)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 7. 网络诊断 ============
        PluginManifest(
            id: "cap-net", name: "网络诊断", version: "1.0.0", category: .tools,
            icon: "🌐", tint: 3, sizeKB: 9,
            summary: "测 URL 通不通、看响应头和耗时、DNS 解析、下载文件、测网速。",
            tools: [
                T("cap-net", "check",
                  "探测一个 URL：状态码、耗时、跳转链。Use for: 判断服务活着没。",
                  "curl -sS -o /dev/null -w 'HTTP %{http_code}\\n耗时 %{time_total}s\\nDNS %{time_namelookup}s\\n连接 %{time_connect}s\\n大小 %{size_download} 字节\\n最终地址 %{url_effective}\\n' -L --max-time 20 '{url}'",
                  ["url": "完整 URL（带 http/https）"], timeout: 60),
                T("cap-net", "headers",
                  "看一个 URL 的响应头。Use for: 查证书、查缓存策略、查跨域。",
                  "curl -sSI -L --max-time 20 '{url}' | head -40",
                  ["url": "完整 URL"], timeout: 60),
                T("cap-net", "dns",
                  "解析一个域名的 IP。Use for: 域名解析失败时定位。",
                  "nslookup {host} 2>/dev/null | tail -12 || getent hosts {host} || echo '解析不到'",
                  ["host": "域名，如 example.com"], timeout: 60),
                T("cap-net", "download",
                  "下载文件到本地并显示速度。Use for: 取安装包、取数据。",
                  "curl -L --max-time 600 -o {out} -w 'HTTP %{http_code}  大小 %{size_download}  平均 %{speed_download} B/s\\n' '{url}' && ls -lh {out}",
                  ["url": "下载地址", "out": "保存到哪个路径"], timeout: 660),
                T("cap-net", "speed",
                  "连测 3 次取平均 KB/s，看当前线路快不快。Use for: 判断是不是网络慢。",
                  // 不用 awk 里带花括号的聚合写法（会被框架当成参数占位而报错），
                  // 也不用 bc（Alpine 默认没装）。纯 shell 整数累加即可。
                  "tot=0; n=0; for i in 1 2 3; do v=$(curl -sS -o /dev/null -w '%{speed_download}' --max-time 15 -r 0-2000000 '{url}' 2>/dev/null); case \"$v\" in ''|*[!0-9]*) v=0 ;; esac; tot=$((tot + v / 1024)); n=$((n + 1)); done; if [ $n -gt 0 ]; then echo \"平均 $((tot / n)) KB/s（$n 次）\"; else echo '测速失败'; fi",
                  ["url": "用来测速的直链地址"], timeout: 90)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 8. Git 与代码 ============
        PluginManifest(
            id: "cap-git", name: "Git 与代码", version: "1.0.0", category: .git,
            icon: "🌿", tint: 4, sizeKB: 10,
            summary: "看仓库状态、最近提交、某文件改动历史、两个版本差了什么。",
            deps: ["git"],
            tools: [
                T("cap-git", "status",
                  "看仓库当前分支与未提交改动。Use for: 动手前先确认工作区干净。",
                  "cd {repo} && git status -sb 2>&1 | head -40 && echo '--- 改动统计 ---' && git diff --stat 2>&1 | tail -20",
                  ["repo": "仓库目录绝对路径"], timeout: 120),
                T("cap-git", "log",
                  "看最近的提交记录。Use for: 了解最近改了什么。",
                  "cd {repo} && git log --oneline --graph --decorate -{n} 2>&1",
                  ["repo": "仓库目录", "n": "看几条，建议 20"], timeout: 120),
                T("cap-git", "filelog",
                  "看某个文件的历史改动。Use for: 追一个文件什么时候被改坏的。",
                  "cd {repo} && git log --oneline -{n} -- {path} 2>&1 | head -40",
                  ["repo": "仓库目录", "path": "文件相对路径", "n": "看几条"], timeout: 120),
                T("cap-git", "show",
                  "看某次提交具体改了什么。Use for: 审查一个改动。",
                  "cd {repo} && git show --stat {rev} 2>&1 | head -30 && echo '--- 内容 ---' && git show {rev} 2>&1 | head -200",
                  ["repo": "仓库目录", "rev": "提交号，或 HEAD、HEAD~1"], timeout: 120),
                T("cap-git", "diff2",
                  "比对两个提交/分支之间差了什么文件。Use for: 看两个版本的距离。",
                  "cd {repo} && git diff --stat {a} {b} 2>&1 | tail -40",
                  ["repo": "仓库目录", "a": "起点，如 HEAD~5", "b": "终点，如 HEAD"], timeout: 120),
                T("cap-git", "grep",
                  "在仓库所有被跟踪的文件里搜关键词。Use for: 找某个函数在哪定义。",
                  "cd {repo} && git grep -n '{keyword}' 2>&1 | head -60",
                  ["repo": "仓库目录", "keyword": "关键词"], timeout: 120)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 9. 图片处理 ============
        PluginManifest(
            id: "cap-image", name: "图片处理", version: "1.0.0", category: .vision,
            icon: "🖼", tint: 5, sizeKB: 12,
            summary: "批量缩放、转格式、看尺寸、压体积。依赖 ImageMagick（首次用会自动装）。",
            deps: ["imagemagick"],
            tools: [
                T("cap-image", "info",
                  "看图片尺寸、格式、体积。Use for: 动手前先确认参数。",
                  "identify {file} 2>/dev/null || (echo '需要 ImageMagick，正在装…'; apk add --no-cache imagemagick >/dev/null 2>&1; identify {file} 2>&1)",
                  ["file": "图片路径"], timeout: 300),
                T("cap-image", "resize",
                  "按宽度等比缩放一张图。Use for: 发图前压小。",
                  "convert {file} -resize {width}x -quality {quality} {out} 2>/dev/null && identify {out} || echo '处理失败'",
                  ["file": "原图路径", "width": "目标宽度像素", "quality": "质量 1-100，建议 85", "out": "输出路径"], timeout: 300),
                T("cap-image", "batchresize",
                  "批量缩放一个目录里的所有图。Use for: 一次处理一堆照片。",
                  "mkdir -p {out} && find {dir} -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \\) 2>/dev/null | head -200 | while read f; do convert \"$f\" -resize {width}x -quality {quality} \"{out}/$(basename \"$f\")\" 2>/dev/null && echo \"ok $(basename $f)\"; done; ls {out} | wc -l",
                  ["dir": "源目录", "out": "输出目录", "width": "目标宽度", "quality": "质量 1-100"], timeout: 600),
                T("cap-image", "convert",
                  "转换图片格式（png/jpg/webp/heic）。Use for: 换格式。",
                  "convert {file} -quality {quality} {out} 2>/dev/null && identify {out} || echo '转换失败'",
                  ["file": "原图", "out": "输出路径（后缀决定格式）", "quality": "质量 1-100"], timeout: 300),
                T("cap-image", "sizes",
                  "列出目录里所有图的尺寸和体积。Use for: 找出特别大的图。",
                  "find {dir} -type f \\( -iname '*.jpg' -o -iname '*.png' \\) 2>/dev/null | head -100 | while read f; do identify -format '%wx%h  %b  %f\\n' \"$f\" 2>/dev/null; done | sort -k2 -rh | head -40",
                  ["dir": "目录"], timeout: 300)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 10. PDF 与文档 ============
        PluginManifest(
            id: "cap-pdfdoc", name: "PDF 与文档", version: "1.0.0", category: .docs,
            icon: "📄", tint: 1, sizeKB: 11,
            summary: "PDF 抽文字、看页数、拆分合并、转图片；Markdown 转 HTML。",
            deps: ["poppler-utils"],
            tools: [
                T("cap-pdfdoc", "pdfinfo",
                  "看 PDF 的页数、尺寸、标题。Use for: 动手前先了解文档。",
                  "pdfinfo {file} 2>/dev/null || (echo '需要 poppler，正在装…'; apk add --no-cache poppler-utils >/dev/null 2>&1; pdfinfo {file} 2>&1)",
                  ["file": "PDF 路径"], timeout: 300),
                T("cap-pdfdoc", "pdftext",
                  "从 PDF 里抽取文字。Use for: 把 PDF 内容拿出来做搜索/分析。",
                  "pdftotext -layout {file} - 2>/dev/null | head -300 || echo '抽不出来（可能是扫描件，需要 OCR）'",
                  ["file": "PDF 路径"], timeout: 300),
                T("cap-pdfdoc", "pdfsplit",
                  "按页码范围拆出几页。Use for: 只取其中几页。",
                  "pdfseparate -f {from} -l {to} {file} {out}-%d.pdf 2>/dev/null && ls {out}*.pdf | head -20 || echo '拆分失败'",
                  ["file": "PDF 路径", "from": "起始页", "to": "结束页", "out": "输出前缀（不含扩展名）"], timeout: 300),
                T("cap-pdfdoc", "pdf2img",
                  "把 PDF 的某几页转成 PNG。Use for: 需要图片版页面。",
                  "pdftoppm -f {from} -l {to} -r {dpi} -png {file} {out} 2>/dev/null && ls {out}*.png | head -20 || echo '转换失败'",
                  ["file": "PDF 路径", "from": "起始页", "to": "结束页", "dpi": "清晰度，建议 150", "out": "输出前缀"], timeout: 600),
                T("cap-pdfdoc", "md2html",
                  "把 Markdown 转成 HTML。Use for: 把笔记变成网页。",
                  "python3 -c \"import sys\ntry:\n    import markdown\nexcept ImportError:\n    print('缺少 markdown 模块，请先 pip install markdown');sys.exit(1)\nt=open('{file}',encoding='utf-8').read()\nprint(markdown.markdown(t,extensions=['fenced_code','tables']))\" > {out} 2>&1 && wc -c {out} || head -5 {out}",
                  ["file": "Markdown 文件", "out": "输出 HTML 路径"], timeout: 180),
                T("cap-pdfdoc", "docxtext",
                  "从 .docx 里抽文字。Use for: 读 Word 文档内容。",
                  "unzip -p {file} word/document.xml 2>/dev/null | sed -e 's/<[^>]*>/ /g' -e 's/  */ /g' | head -c 8000",
                  ["file": ".docx 路径"], timeout: 180)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 11. 时间与日期 ============
        PluginManifest(
            id: "cap-time", name: "时间与日期", version: "1.0.0", category: .tools,
            icon: "🕐", tint: 2, sizeKB: 6,
            summary: "时间戳互转、时区换算、算两个日期差多少天、生成日期序列。",
            tools: [
                T("cap-time", "now",
                  "看当前时间、时间戳、各时区时间。Use for: 对时间、看机器时间准不准。",
                  "date '+本地 %Y-%m-%d %H:%M:%S %Z'; date -u '+UTC  %Y-%m-%d %H:%M:%S'; date +'时间戳 %s'",
                  [:], timeout: 30),
                T("cap-time", "ts2date",
                  "把时间戳转成可读日期。Use for: 看日志里那串数字是什么时候。",
                  "date -r {ts} '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -d @{ts} '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '时间戳不合法'",
                  ["ts": "秒级时间戳"], timeout: 30),
                T("cap-time", "date2ts",
                  "把日期转成时间戳。Use for: 算某个时刻的时间戳。",
                  "date -d '{date}' +%s 2>/dev/null || echo '日期格式不对，用 2026-11-05 12:00:00 这种'",
                  ["date": "日期时间"], timeout: 30),
                T("cap-time", "daysbetween",
                  "算两个日期之间差多少天。Use for: 算还剩多少天、已经过多久。",
                  "a=$(date -d '{from}' +%s 2>/dev/null); b=$(date -d '{to}' +%s 2>/dev/null); if [ -n \"$a\" ] && [ -n \"$b\" ]; then echo $(( (b-a) / 86400 )) 天; else echo '日期格式不对'; fi",
                  ["from": "起始日期", "to": "结束日期"], timeout: 30),
                T("cap-time", "adddays",
                  "从某天往后/往前推 N 天。Use for: 算截止日、算周期。",
                  "date -d '{base} {days} days' '+%Y-%m-%d %A' 2>/dev/null || echo '日期格式不对'",
                  ["base": "基准日期", "days": "天数，往前推用负数"], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 12. 搜索 ============
        PluginManifest(
            id: "cap-search", name: "内容检索", version: "1.0.0", category: .tools,
            icon: "🔍", tint: 0, sizeKB: 8,
            summary: "在一堆文件里按内容搜关键词、按文件名搜、统计命中分布。",
            tools: [
                T("cap-search", "grepdir",
                  "在目录里递归搜「文件内容」含关键词的文件。Use for: 在一堆代码/配置里找某句话。",
                  "grep -rIl '{keyword}' {dir} 2>/dev/null | head -60",
                  ["dir": "搜索目录", "keyword": "要找的内容"], timeout: 240),
                T("cap-search", "grepdetail",
                  "同上，但连命中的那一行也打出来。Use for: 直接看到上下文。",
                  "grep -rIn '{keyword}' {dir} 2>/dev/null | head -100",
                  ["dir": "搜索目录", "keyword": "要找的内容"], timeout: 240),
                T("cap-search", "byext",
                  "在目录里按后缀找文件。Use for: 找所有 json、所有 .log。",
                  "find {dir} -type f -iname '*.{ext}' 2>/dev/null | head -100",
                  ["dir": "目录", "ext": "后缀，不带点，如 json"], timeout: 180),
                T("cap-search", "count",
                  "统计某关键词在各个文件里出现了多少次。Use for: 看哪个文件提得最多。",
                  "grep -rIc '{keyword}' {dir} 2>/dev/null | grep -v ':0$' | sort -t: -k2 -rn | head -30",
                  ["dir": "目录", "keyword": "关键词"], timeout: 240)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 13. 媒体处理 ============
        PluginManifest(
            id: "cap-media", name: "音视频处理", version: "1.0.0", category: .vision,
            icon: "🎬", tint: 3, sizeKB: 10,
            summary: "看视频信息、抽音轨、截帧、转码压缩。依赖 ffmpeg（体积大，首次用会提示）。",
            deps: ["ffmpeg"],
            tools: [
                T("cap-media", "probe",
                  "看视频/音频的时长、码率、分辨率。Use for: 动手前先确认参数。",
                  "ffprobe -v error -show_entries format=duration,size,bit_rate -show_entries stream=codec_name,width,height -of default=noprint_wrappers=1 {file} 2>&1 | head -30 || echo '需要 ffmpeg'",
                  ["file": "媒体文件路径"], timeout: 120),
                T("cap-media", "frame",
                  "从视频里截一帧成图片。Use for: 取封面、看某一秒画面。",
                  "ffmpeg -y -ss {at} -i {file} -frames:v 1 {out} 2>&1 | tail -3 && ls -lh {out}",
                  ["file": "视频路径", "at": "第几秒，如 00:00:05", "out": "输出图片路径"], timeout: 300),
                T("cap-media", "audio",
                  "把视频里的音轨抽出来。Use for: 提取背景音、语音。",
                  "ffmpeg -y -i {file} -vn -acodec copy {out} 2>&1 | tail -3 && ls -lh {out}",
                  ["file": "视频路径", "out": "输出音频路径（.m4a/.aac）"], timeout: 300),
                T("cap-media", "compress",
                  "把视频压小（改码率）。Use for: 文件太大传不上去。",
                  "ffmpeg -y -i {file} -b:v {bitrate} -bufsize {bitrate} {out} 2>&1 | tail -3 && ls -lh {file} {out}",
                  ["file": "原视频", "bitrate": "目标码率，如 800k", "out": "输出路径"], timeout: 900)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 14. 开发运维 ============
        PluginManifest(
            id: "cap-devops", name: "开发运维", version: "1.0.0", category: .remote,
            icon: "🖥", tint: 4, sizeKB: 9,
            summary: "看日志、找报错、查端口占用、测 SSH 通不通、看服务状态。",
            tools: [
                T("cap-devops", "tail",
                  "看日志文件最后 N 行，可按关键词过滤。Use for: 出问题时看最近发生了什么。",
                  "if [ -n '{keyword}' ]; then tail -{n} {file} 2>/dev/null | grep -i '{keyword}'; else tail -{n} {file} 2>/dev/null; fi",
                  ["file": "日志文件路径", "n": "看最后几行，建议 100", "keyword": "只留含这个词的行（可留空）"], timeout: 120),
                T("cap-devops", "errors",
                  "从日志里挑出报错行并统计类型。Use for: 快速定位故障模式。",
                  "grep -iE 'error|exception|failed|fatal|panic|denied|refused' {file} 2>/dev/null | tail -80",
                  ["file": "日志文件路径"], timeout: 120),
                T("cap-devops", "port",
                  "查某个端口有没有被占、被谁占。Use for: 服务起不来先查这个。",
                  "netstat -ltnp 2>/dev/null | grep ':{port} ' || (echo \"端口 {port} 没有监听\"; netstat -ltn 2>/dev/null | head -20)",
                  ["port": "端口号"], timeout: 90),
                T("cap-devops", "ssh",
                  "测 SSH 端口通不通（不登录）。Use for: 连不上服务器先排除网络。",
                  "nc -zv -w 5 {host} {port} 2>&1 || (echo 'nc 不可用，改用 curl 探测'; curl -sS --max-time 6 -o /dev/null -w '连接耗时 %{time_connect}s\\n' telnet://{host}:{port} 2>&1)",
                  ["host": "主机名或 IP", "port": "端口，默认 22"], timeout: 60),
                T("cap-devops", "biglog",
                  "找日志里出现最频繁的 20 行（去掉时间戳）。Use for: 看是不是同一个错在刷屏。",
                  "sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:.,]+//' {file} 2>/dev/null | sort | uniq -c | sort -rn | head -20",
                  ["file": "日志文件路径"], timeout: 180)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 15. 会话与记忆 ============
        PluginManifest(
            id: "cap-session", name: "会话与记忆", version: "1.0.0", category: .session,
            icon: "💬", tint: 2, sizeKB: 8,
            summary: "整理聊天记录：抽消息、统计长度、按关键词找、压缩成长摘要。",
            tools: [
                T("cap-session", "sessionsize",
                  "看会话数据文件多大、多少条。Use for: 判断是不是历史太重。",
                  "ls -lh {file} 2>/dev/null; wc -l {file} 2>/dev/null",
                  ["file": "会话数据文件路径"], timeout: 60),
                T("cap-session", "grepmsg",
                  "在会话记录里搜关键词。Use for: 找回之前说过的事。",
                  "grep -n '{keyword}' {file} 2>/dev/null | head -60",
                  ["file": "会话记录文件", "keyword": "关键词"], timeout: 120),
                T("cap-session", "extract",
                  "从 JSON 会话里抽出所有消息文本。Use for: 把聊天内容拿去做分析。",
                  "python3 -c \"import json,sys\nd=json.load(open('{file}'))\nout=[]\ndef walk(o):\n    if isinstance(o,dict):\n        for k,v in o.items():\n            if k in ('content','text','message') and isinstance(v,str): out.append(v)\n            else: walk(v)\n    elif isinstance(o,list):\n        [walk(x) for x in o]\nwalk(d)\nprint('\\n'.join(out[:2000]))\" 2>/dev/null | head -300 || echo '解析失败'",
                  ["file": "会话 JSON 文件"], timeout: 180),
                T("cap-session", "summarize",
                  "把长文本压成「每段首句」的骨架。Use for: 快速浏览超长记录。",
                  "python3 -c \"import re\nt=open('{file}',encoding='utf-8',errors='replace').read()\nparas=[p.strip() for p in re.split(r'\\n\\s*\\n',t) if p.strip()]\nfor i,p in enumerate(paras[:80],1):\n    s=re.split(r'(?<=[。！？.!?])\\s*',p)[0][:100]\n    print(str(i)+'. '+s)\" 2>/dev/null || echo '处理失败'",
                  ["file": "文本文件路径"], timeout: 180)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 16. AI 与提示词 ============
        PluginManifest(
            id: "cap-ai", name: "提示词与模型", version: "1.0.0", category: .model,
            icon: "🔌", tint: 1, sizeKB: 8,
            summary: "估算 token 数、清理提示词、批量把模板里的变量替换掉。",
            tools: [
                T("cap-ai", "tokencount",
                  "粗估一段文本的 token 数（中英分开算）。Use for: 判断会不会超上下文。",
                  "python3 -c \"import sys\nt=open('{file}',encoding='utf-8',errors='replace').read()\nzh=sum(1 for c in t if '\\u4e00'<=c<='\\u9fff')\nother=len(t)-zh\nprint('字符 '+str(len(t))+'  中文 '+str(zh)+'  其他 '+str(other))\nprint('粗估 token ≈ '+str(int(zh*1.0+other/3.6)))\" 2>/dev/null || echo '处理失败'",
                  ["file": "文本文件路径"], timeout: 60),
                T("cap-ai", "cleanprompt",
                  "清理提示词里的多余空行、行尾空格、连续空格。Use for: 发给模型前压一压。",
                  "sed -e 's/[[:space:]]*$//' -e '/^$/N;/^\\n$/D' {file} | awk 'NF' > {out} && wc -c {file} {out}",
                  ["file": "原提示词文件", "out": "输出文件"], timeout: 90),
                T("cap-ai", "fillvars",
                  "把模板里的 {{变量}} 批量替换成值。Use for: 生成不同版本的提示词。",
                  "for pair in {pairs}; do k=${pair%%=*}; v=${pair#*=}; sed -i '' \"s/{{$k}}/$v/g\" {out} 2>/dev/null || sed -i \"s/{{$k}}/$v/g\" {out}; done; grep -o '{{[^}]*}}' {out} 2>/dev/null | sort -u | head -20; echo '（以上是还没替换的变量）'",
                  ["file": "模板文件", "out": "输出文件（先复制一份模板）", "pairs": "空格分隔的 键=值 对"], timeout: 120),
                T("cap-ai", "jsonl",
                  "把 JSON 数组转成 JSONL（每行一个）。Use for: 准备微调数据。",
                  "python3 -c \"import json\nd=json.load(open('{file}'))\nassert isinstance(d,list)\nopen('{out}','w').write('\\n'.join(json.dumps(x,ensure_ascii=False) for x in d))\nprint('写出',len(d),'行')\" 2>/dev/null || echo '转换失败'",
                  ["file": "JSON 数组文件", "out": "输出 .jsonl 路径"], timeout: 180)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0),

        // ============ 17. 杂项兜底 ============
        PluginManifest(
            id: "cap-misc", name: "通用小工具", version: "1.0.0", category: .tools,
            icon: "🧰", tint: 5, sizeKB: 7,
            summary: "跑命令、看文件头、算表达式、生成目录树——那些说不清归哪类的小事。",
            tools: [
                T("cap-misc", "run",
                  "执行一条 shell 命令并返回输出。Use for: 前面所有工具都不合适时的手动兜底。",
                  "{cmd}",
                  ["cmd": "要执行的完整命令"], timeout: 180),
                T("cap-misc", "head",
                  "看文件开头几十行。Use for: 确认这是个什么文件。",
                  "file {file} 2>/dev/null; echo '---'; head -50 {file} 2>/dev/null || echo '读不了（可能是二进制）'",
                  ["file": "文件路径"], timeout: 60),
                T("cap-misc", "calc",
                  "算数学表达式。Use for: 快速算个数。",
                  // 不用 awk 的 BEGIN+printf 花括号写法（会被框架当成未声明参数占位而报错）。
                  // 直接依赖 python3；缺了给出明确提示，而不是一段看不懂的 shell 报错。
                  "command -v python3 >/dev/null 2>&1 || { echo '本机没有 python3，无法计算表达式'; exit 9; }; python3 -c \"print(float({expr}))\" 2>&1 || echo '表达式不对'",
                  ["expr": "算术表达式，如 (35*1.2)+8"], timeout: 30),
                T("cap-misc", "tree",
                  "打印目录树（两层深）。Use for: 快速看清一个目录的结构。",
                  "find {dir} -maxdepth 2 2>/dev/null | head -100",
                  ["dir": "目录路径"], timeout: 120)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 0, downloads: 0)
    ]
}
