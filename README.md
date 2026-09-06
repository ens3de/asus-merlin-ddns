# 家庭网络 DDNS：独立记录配置与交互管理

本项目面向 Asuswrt-Merlin 的 Shell 环境。保留公共 `.conf` 设置，将每个域名的配置分开保存为 `conf.d/域名.json`，例如 `conf.d/wg.ens3.de.json`。记录文件始终通过 `jq` 解析，绝不作为 Shell 执行。

**当前仅实现 Cloudflare。** 地址获取、状态管理与供应商 API 已分层；未来增加供应商时，需要实现并测试对应适配器，而不是仅修改配置中的名称。

## 目录与依赖

```text
cloudflare-ddns                  统一入口：更新和配置管理
cloudflare-ddns.conf             私有公共设置，保留现有凭据
cloudflare-ddns.conf.example     无凭据公共配置示例
conf.d/                         每个域名一个紧凑 JSON 文件
lib/init-manager.sh            全局设置交互初始化模块
lib/common.sh                   日志、锁、文件校验、逐记录状态
lib/sources.sh                  四种地址来源
lib/ip.jq                      地址校验与规范化
lib/schema.jq                  记录格式校验
lib/providers.sh               Cloudflare API 与供应商分发边界
lib/config-manager.sh          交互配置管理模块（无独立入口）
tests/                          完全离线的模拟测试
```

运行依赖：POSIX `sh`、`jq >= 1.6`、`curl`、支持 `-o addr` 的 `ip`、`awk`、`grep -E`、`sed`、`cut`、`tr`、`cksum`、`mktemp` 和常规文件工具。无 Python、Docker、图形桌面、dialog 或 whiptail 运行依赖。Python 仅用于开发测试。脚本会自动将已有的 Entware `/opt/bin`、`/opt/sbin` 加入 `PATH`，因此 Merlin 的非交互 DDNS 调用也能找到 `/opt/bin/jq`。

首次运行 `init` 会检查 `jq`、`curl`、`mktemp`、`cksum`。缺少可由 Entware 提供的项目时，`init` 会显示包名、执行 `opkg update`，并自动安装最新候选版本（`jq-full`、`libcurl`、`coreutils-mktemp`、`coreutils-cksum`）。基础 BusyBox 命令缺失或 `opkg` 本身不可用时会安全失败并说明原因。

也可以先手动检查依赖：

```sh
type jq
jq --version
type curl
ip -6 -o addr show scope global
```

## 部署和迁移边界

开发副本不会自动上传路由器，不修改 Cloudflare，不修改路由器防火墙，也不会自动安装定时任务。

1. 先暂停旧 DDNS 的定时/事件调用，避免迁移中途使用空的 `conf.d`。
2. 将脚本及 `lib/` 一起部署到原 DDNS 目录，不要只复制主脚本。
3. 运行 `cloudflare-ddns init` 交互生成公共设置。工具会隐藏 Token 输入，并从 Cloudflare 返回的 Zone 列表中选择，不要求填写 Zone ID。
4. 用 `cloudflare-ddns config add` 逐个创建原有域名和 WG 域名。原先 A、AAAA 使用不同域名的，创建两个任务，不要合并成一个域名。
5. 先校验和预览，最后启用，并手动进行第一次真实更新；验证后再恢复定时/事件调用。

```sh
cd /jffs/scripts/ddns
chmod 700 cloudflare-ddns
chmod 600 cloudflare-ddns.conf
sh ./cloudflare-ddns config
```

公共设置中以下旧字段继续保留作用：`CF_API_TOKEN`、`CF_ZONE_ID`、`LOG_LEVEL`、`LOG_TAG`、`LOG_FILE`、`STATE_FILE`、`NO_CHANGE_WINDOW_SECONDS`、Bark 设置。新名称 `REFRESH_INTERVAL_SECONDS` 优先于旧的 `NO_CHANGE_WINDOW_SECONDS`。

**旧 `CF_RECORDS` 及全局 `IPV4_*`、`IPV6_*` 地址来源不再参与更新。** 必须用管理工具将各域名迁移为独立任务。这样不会出现新旧来源混合、隐式回退到 router 地址的情况。目录为空时更新器会报错，不会执行 DNS 更新。

旧 Shell 状态文件不会被执行；首次成功更新后会转换为按记录保存的 JSON 状态。其他无法识别的损坏状态会报错，不能静默覆盖。

## 全局初始化

```sh
sh ./cloudflare-ddns init
# 初始化其他位置的公共设置：
sh ./cloudflare-ddns init --config /path/cloudflare-ddns.conf
```

`init` 负责生成 `cloudflare-ddns.conf`：输入 Cloudflare API Token 后，工具分页读取可见 Zone，按序号选择域名空间，再设置记录目录、状态文件、日志、刷新间隔、HTTP 超时和可选 Bark 通知。Token 与 Bark Key 在终端中隐藏输入；最终预览也只显示脱敏状态。

API Token 至少需要目标 Zone 的 `Zone / Zone / Read` 与 `Zone / DNS / Read` 权限；新增记录和日常 DDNS 更新还需要 `Zone / DNS / Edit`。建议把 Token 的 Zone Resources 限制到实际管理的 Zone。

只有在最后输入 `yes` 后，工具才会创建 `CONF_DIR` 并原子替换公共配置；不会生成自动备份。新文件权限设置为 `600`。重新运行时，敏感字段直接回车可保留现有值，取消确认则原文件不变。改变 `CONF_DIR` 只会切换后续使用的记录目录，不会搬迁原目录中的 JSON。

## 交互管理

```sh
sh ./cloudflare-ddns config                     # 菜单
sh ./cloudflare-ddns config add                 # 以域名作为唯一标识，问答创建并默认启用
sh ./cloudflare-ddns config edit                # 列表选择后逐项修改
sh ./cloudflare-ddns config list                # 显示本地来源当前解析出的 A/AAAA
sh ./cloudflare-ddns config enable              # 列表选择；必须确认
sh ./cloudflare-ddns config disable             # 列表选择；不删除 DNS
sh ./cloudflare-ddns config delete              # 列表选择；只删除本地配置
```

配置管理模块没有独立命令入口，只能通过 `cloudflare-ddns config` 调用。新增时不要求输入任务名，所选域名就是唯一标识和文件名，例如 `wg.ens3.de` 对应 `conf.d/wg.ens3.de.json`。修改、启用、停用和删除省略域名时都会显示已有配置并按序号选择。它不会要求输入 Cloudflare Record ID、启动编辑器或要求手工编辑 JSON。

新增任务时，工具只从当前 Zone 的 A/AAAA 记录提取已有域名；CNAME、MX、TXT 等其他类型不会出现在域名选择列表。域名选择没有默认项，必须明确输入序号，最后一项始终是“新增域名”。选择新增后只输入相对主机名，例如输入 `abc` 会生成 `abc.ens3.de`；输入 `@` 表示 Zone 根域。为防止意外重复后缀，输入完整域名会被拒绝。

选定域名后，只需一次选择管理 `1. A`、`2. AAAA` 或 `3. A 和 AAAA`。已有域名根据 Cloudflare 当前记录自动设置默认值；新域名默认同时管理 A 和 AAAA。编辑任务时以该任务当前管理的类型为默认，避免意外增加管理范围。随后工具分别列出所选类型匹配的 Cloudflare 记录及代理状态。Token 需要该 Zone 的 DNS 读取权限；需要新增记录或执行更新时还需要 DNS 编辑权限。

地址来源同样使用编号菜单，不需要输入内部类型名称。菜单会逐项解释：命令参数适合由 Merlin 或调用方传入地址；本机网卡只读取脚本所在设备；HTTP 查询得到请求的实际出口地址；AAAA 额外提供“LAN `/64` 前缀 + 固定 IID”，用于从 router 的 LAN 前缀推导其他设备的稳定 IPv6。新记录默认选择本机网卡，编辑时默认保持当前来源。

选择阶段不会再逐条显示或询问 Cloudflare Record ID。若某个域名/类型恰有一条 DNS-only 记录，工具自动关联；没有记录则标记为待创建；多条同类型记录会报歧义，要求先在 Cloudflare 整理。保存前会统一展示本地 JSON 与每条 DNS 的 Type、Name、Content、Proxy、TTL、Action。只有最后确认后，才会实际创建待创建的 DNS-only 记录并写入本地 JSON。

如果你在 macOS 等非部署设备上准备配置，且“本机网卡”来源无法解析目标接口，工具会要求输入该新记录的初始公网地址，用于这一次 Cloudflare 创建；保存的动态来源配置不会因此改变。Linux/router 环境仍优先自动读取 `ip`，其他系统可使用 `ifconfig`。

如果没有匹配记录，工具会在最终预览中标记为待创建；只有输入 `yes` 后才创建 DNS-only 记录并保存单行紧凑 JSON。普通问答直接回车保留显示的默认值。停止管理 A/AAAA 会额外确认。

如果使用另一份公共配置，`--config` 必须放在管理器命令之前：

```sh
sh ./cloudflare-ddns config --config /path/settings.conf add
```

也支持通过工具导入已有的独立 JSON object（不是数组）：

```sh
sh ./cloudflare-ddns config import wg.ens3.de /path/wg-export.json
```

导入只允许新任务，强制设置为停用，不执行 JSON 中的代码。现有任务通过 `edit` 修改。A/AAAA 至少保留一种；删除本地任务不能恢复为原配置，需重新创建或从自己导出的文件导入；云端 DNS 保留。

## 记录结构

以下仅用于理解管理工具生成的结果，不要将占位符示例直接放入 `conf.d`：

```json
{
  "schema_version": 1,
  "enabled": false,
  "provider": "cloudflare",
  "name": "wg.ens3.de",
  "AAAA": {
    "id": "REPLACE_WITH_AAAA_RECORD_ID",
    "source": {
      "type": "prefix_iid",
      "interface": "br0",
      "iid": "0011:32ff:fe29:0a81"
    }
  }
}
```

文件名必须是 JSON 内域名的小写规范形式，例如 `wg.ens3.de.json` 的 JSON `name` 必须为 `wg.ens3.de`。只扫描目录第一层 `*.json`，拒绝符号链接、旧式大写任务名、文件名与域名不一致及未知字段。A、AAAA 独立配置；省略的类型不管理，也不会从云端删除。

同一个 Zone 内不允许两个任务重复管理相同 Record ID 或相同域名/类型，包括停用任务。当前一份公共配置管理一个 Cloudflare Zone、一套凭据。多个 Zone 应使用独立配置目录和状态路径；尚未实现多账号混用。

## 地址来源

| type | A | AAAA | 附加字段 |
|---|---|---|---|
| `argument` | 支持 | 支持 | 无 |
| `interface` | 支持 | 支持 | `interface` |
| `http` | 支持 | 支持 | `url`，可选 `timeout_seconds`、`json_field` |
| `prefix_iid` | 不支持 | 支持 | `interface`、`iid` |

### 参数

更新器兼容 Merlin 传入单个 IP 参数，也可以分别传入两个地址族：

```sh
sh ./cloudflare-ddns --dry-run --ipv4 203.0.113.2 --ipv6 2001:db8::2
sh ./cloudflare-ddns --dry-run --task router.ens3.de --ipv4 203.0.113.2
```

文档示例地址是保留的说明地址，不用于真实部署。参数只用于 `argument` 来源。接口、HTTP、前缀拼接来源绝不被参数覆盖，获取失败也不回退到其他来源。

Merlin 的 DDNS 页面即使启用了“IPv6 更新”，实际回调也可能只传 IPv4 参数。因此 AAAA 记录不能依赖 `argument` 作为常规来源；router 自身应使用 `interface`，局域网其他设备应使用 `prefix_iid`。`argument` 只适合已确认调用方会显式传入 IPv6 的场景。

### 本地接口

读取运行脚本那台设备的接口；router 上的 `ens3` 不能代表 vm2 的 `ens3`。候选地址过滤临时、弃用、DAD 失败、尚在 DAD 中的地址以及 ULA/link-local。`mngtmpaddr` 本身不被视为临时地址。

IPv4 拒绝私网、CGNAT、环回、链路本地、组播等明显不能作为公网入口的地址。IPv6 当前支持原生 `2000::/3` 全局单播地址，拒绝 IPv4-mapped 等其他文本形式；校验不代表公网可达性验证。

多个不同可用地址时拒绝猜测，不按第一条选择。

### HTTP

按记录类型使用 IPv4 或 IPv6 请求。默认响应为纯文本 IP；`json_field` 可提取 JSON 对象的一个顶层字符串字段（字段名是数据，不是 jq 表达式）。只接受 HTTP 200，不跟随重定向，使用有限超时。不支持从记录 JSON 执行任意 Shell 解析命令。

旧 `IPV*_REMOTE_CMD` 不会迁移为可执行 JSON 字段。如果旧接口返回复杂数据，需先确认格式，再增加受限解析方式。

HTTP 来源得到的是请求出口地址，可能受 NAT/dae 影响。vm2 公网入口应使用固定后缀拼接或在 vm2 上读取接口，不要使用可能走代理的公网查询。

### LAN /64 前缀与 IID

从指定接口的有效全局 IPv6 地址取得 `/64` 前缀；多个地址属于同一前缀可去重，多个不同有效前缀则跳过并报告歧义。正确展开 `::` 后再组合，不能直接拼接原始字符串。

`iid` 必须是四组十六进制，不能全零。例如 vm2 当前为 `0011:32ff:fe29:0a81`；它与 MAC `02:11:32:29:0a:81` 的 EUI-64 结果一致。更改 MAC 或地址生成策略后需在工具中更新 IID。

`br0` 必须先确认是实际 router LAN 接口；不能把 WAN `ppp0` 的前缀或 PD `/60` 直接当作 LAN `/64`。这里是推导地址，不验证 vm2 在线、DAD 成功或服务监听。

## 更新行为与安全边界

- `--check` 不访问网络；`--dry-run` 只获取来源地址，HTTP 模式会访问查询服务，但不访问 Cloudflare 写接口、不写成功状态、不通知 Merlin/Bark。
- 所有配置先校验，再执行任何记录更新。配置格式错误会阻止整次运行；运行中的地址获取/API 失败只影响相应记录，其他记录继续，进程最终返回非零并汇总通知。
- 正常 DDNS 更新首先 GET 核对 Record ID、域名和类型，再 PATCH `content`，不创建/删除记录，也不改变 TTL 等无关字段。只有配置工具中的 `new` 操作可以创建记录。
- 当前为 VPN 入口场景要求 DNS-only（灰云）。发现 `proxied=true` 时拒绝更新，而不是自动关闭代理。
- Token 使用 curl 的 stdin 配置传入，不出现在 curl 命令行参数；API 原始响应不记日志。不要用 `sh -x` 调试真实凭据。
- 状态键包含供应商、Zone、Record ID、类型、域名；重排或改任务文件名不影响缓存。只有成功更新并验证返回地址后才保存状态。
- 配置及状态使用原子替换；管理工具保存前会检查并发修改，更新器与管理器共用排他锁。一次更新期间锁会保持，不允许管理工具修改。进程被强制杀死后若残留锁，应确认没有实例运行，再人工清理指定 `.lock` 目录；不按 PID 猜测自动抢锁。
- `CONF_DIR` 的相邻锁目录会被临时创建，检查/预览也需要该位置可写。仅同一个配置目录共享锁；不要让多个独立配置目录共用同一个 STATE_FILE。
- 公共 `.conf` 仍是可信 Shell，限制其写权限；凭据不放入记录 JSON。
- 保存启用任务意味着下次调度可能使用新配置。除明确选择 `new` 并确认外，配置工具不写 Cloudflare。创建记录是即时的真实 API 写操作；如果随后取消本地配置保存，云端新记录仍会保留，并可在下次配置时从列表中选择。

**DDNS 不是完整的动态 IPv6 容灾：** 前缀变化后，router 的固定目标地址防火墙规则仍需同步；WireGuard 客户端可能需要重新连接才能重新解析域名。本项目不自动操作防火墙、WG 或网络接口。IPv6 前缀变化时也需确保旧地址失效后定时任务仍会重试。

## 开发与验证

```sh
python3 -m unittest discover -s ddns/tests -v
```

测试只用临时目录、虚构凭据和模拟 `ip`/`curl`/`logger`，不读取真实 `.conf`，不执行实际 DNS 请求。可以使用 `DDNS_TEST_SHELL` 指定另一种 POSIX shell 重跑。源码按 POSIX shell 编写，但真实 Merlin 的 BusyBox/ip/curl/jq 组合仍需要先执行 `--check` 与 `--dry-run` 验证。
