# LuCI 混合订阅管理器 (luci-app-hybrid-subscription)

[![Test, build and release](https://github.com/Zerlight/luci-app-hybrid-subscription/actions/workflows/ci.yml/badge.svg)](https://github.com/Zerlight/luci-app-hybrid-subscription/actions/workflows/ci.yml)
[![Latest Release](https://img.shields.io/github/v/release/Zerlight/luci-app-hybrid-subscription?include_prereleases)](https://github.com/Zerlight/luci-app-hybrid-subscription/releases)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10%20%7C%2025.12-00B5E2)](https://github.com/Zerlight/luci-app-hybrid-subscription/releases)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

[English](README.md) | [简体中文](README.zh-CN.md)

一款面向 OpenWrt LuCI 的原生**多订阅源聚合**与**可视化分流规则编排**工具。支持将多个订阅源缓存至路由器本地，编排策略组与分流规则，并为 **Mihomo (Clash Meta)**、**Surge**、**sing-box** 与 **Shadowrocket**（Clash YAML 格式）生成带版本管理与一键回滚能力的配置文件。

```text
上游订阅源 ──► 本地节点缓存 ──► LuCI 策略组与规则编排 ──► 不可变发布版本 ──► 客户端拉取 (二维码 / URL)
(手动/定时)    (/etc/hybrid-...)   (各客户端独立格式)          (SHA-256 校验)    └──► 同步应用至 OpenClash
```

本工具专注于订阅聚合、规则编译与版本分发；实时连接监控与运行期节点切换仍由各客户端面板负责。

## 核心特性

- **拉取与分发解耦（保护限时/限次订阅）**：支持将任意数量的订阅源组合为多套独立配置（Profile），按来源或地区正则模板筛选节点。客户端扫码或更新订阅时仅读取本地已发布的静态文件，**绝不触发上游订阅拉取**。
- **原生 LuCI 规则引擎与依赖图**：基于 LuCI 原生组件编辑策略组、有序分流规则、共享远程/内联规则集，支持 Mihomo 重匹配入口（`rematch`）、命名子规则（`sub-rules`）与递归逻辑条件（`AND` / `OR` / `NOT`），并提供浏览器端原生 SVG 策略依赖关系图。
- **多客户端订阅互转与兼容性向导**：支持导入 Mihomo、Surge、sing-box 或 Shadowrocket 节点订阅，并按目标客户端导出对应配置。内置原生 LuCI **兼容性**检查页与向导，可逐端排查兼容问题，按需将策略组调整为手动选择或受支持的自动模式，预览确认后生成独立的客户端配置。遇到不支持的协议或规则会直接报错拦截，存在字段差异时则需在发布前手动确认。
- **不可变版本与历史回滚**：遵循“保存草稿 → 校验与脱敏预览 → 构建版本 → 确认兼容性差异 → 发布 / 历史回滚”流程，改坏草稿不会影响正在使用的订阅链接。
- **OpenClash 安全协同**：支持一键导入现有 OpenClash 订阅源与本地节点缓存；将已发布版本应用至 OpenClash 前会自动执行 `clash_meta -t` 隔离语法校验并启动超时回滚守卫，防止坏配置导致断网。
- **无常驻 Web 进程的轻量设计**：完全复用路由器现有的 `uhttpd` 与 `rpcd`，无需额外部署 Node.js、Docker 或独立 Web 后端。

## 资源占用评估与路由器硬件要求

许多硬路由的存储空间（Flash）与内存（RAM）较为有限。本项目采用**按需短进程（On-Demand Worker）架构**，不在后台运行常驻的应用服务器：

- **前端零后端渲染开销**：界面表单、二维码（`luci-lib-uqr`）及 SVG 依赖关系图均在浏览器本地渲染，路由器仅提供约 140 KiB 的静态 JS 脚本。
- **空闲状态近乎零占用**：后台服务（`/etc/init.d/hybrid-subscription`）仅为一个极简的 POSIX `/bin/sh` 睡眠循环（`sleep 60`），每分钟唤醒一次检查是否有到期的定时订阅源；若无任务则立即休眠，**平时无常驻 Ruby 进程，空闲 CPU 占用为 0%**。
- **用完即走的工作进程**：仅在打开配置页面、更新订阅源、构建版本或客户端请求下载时按需拉起短生命周期 Ruby 进程，执行完毕后内存立即归还系统。

### 实测资源占用指标

| 评估维度 | 实测占用范围 | 说明 |
| :--- | :--- | :--- |
| **闪存占用（软件包）** | **~350 KiB**（主程序 + 中文包）<br>**~5–6.5 MiB**（含 Ruby 标准库依赖） | 若固件未预装 Ruby，首次安装 `ruby` 及 `ruby-yaml` / `ruby-json` 等子包约需 5–6.5 MiB 可用空间。 |
| **闪存占用（数据区）** | **~50–300 KiB** / 每个订阅源缓存<br>**~100–800 KiB** / 每个已发布版本 | 存放在 `/etc/hybrid-subscription`，具体大小取决于节点数量与启用的导出格式数量。 |
| **内存占用（日常空闲）** | **< 1 MiB** | 仅驻留 `/bin/sh` 定时轮询外壳，无常驻 Ruby 进程。 |
| **内存占用（客户端下载）** | **~10–14 MiB**（瞬时，耗时 < 30 ms） | 校验下载令牌与文件 SHA-256 后直接返回静态文件，进程随即退出。 |
| **内存占用（构建与校验）** | **~16–28 MiB**（100–300 节点）<br>**~35–65 MiB**（1,000–4,000 节点） | 同时编译 Mihomo、Surge、sing-box 三端配置时的后台单进程内存峰值（构建完成后立即释放）。 |
| **内存占用（OpenClash 预校验）** | **+50–120 MiB**（瞬时，仅安装 OpenClash 时） | 构建或应用 Mihomo 配置时调用 `clash_meta -t` 校验语法与 GeoIP/GeoSite 数据库产生的瞬时内存占用。 |
| **CPU 耗时（三端完整构建）** | **~0.1–0.4 秒**（100–300 节点，ARM A53）<br>**~10–90 毫秒**（x86_64 软路由） | 1,000 节点规模在常见双核 ARM 路由器（如 MT7981 / IPQ6000）上构建耗时约 0.5–1.5 秒。 |

### 路由器硬件配置建议

| 使用场景 | 最低配置要求 | 推荐配置 | 小内存路由器优化建议 |
| :--- | :--- | :--- | :--- |
| **仅作为独立订阅聚合与分发中心**<br>*(本机不运行 OpenClash，仅向手机/电脑分发配置)* | **128 MiB RAM**<br>16 MiB 可用闪存<br>MIPS / ARM 580 MHz+ | **256 MiB+ RAM**<br>32 MiB+ 可用闪存<br>双核 ARMv8 / x86_64 | 常见 128 MiB 硬路由（如 MT7621 机型）即可流畅运行；建议将总缓存节点数控制在 500 个以内，并定期清理旧的历史版本。 |
| **与 OpenClash 同机运行**<br>*(同时在本机运行 Mihomo 透明代理)* | **256 MiB RAM** *(建议开启 ZRAM/Swap)*<br>32 MiB 可用闪存<br>双核 ARM / MIPS | **512 MiB+ RAM**<br>64 MiB+ 可用闪存<br>ARM64 (MT7981/7986、IPQ) / x86_64 | 在 256 MiB 内存机型上与 OpenClash 同跑时，建议在**订阅配置 → 高级策略**中设置 `"geodata-loader": "memconservative"` 并开启 ZRAM/Swap，避免 `clash_meta -t` 预校验与重载时触发内存不足（OOM）。 |

## 安装与部署

### 1. 使用 Release 预编译包安装（推荐）

前往 [GitHub Releases](https://github.com/Zerlight/luci-app-hybrid-subscription/releases) 下载对应 OpenWrt 版本的安装包（**OpenWrt 24.10 使用 `.ipk`**，**OpenWrt 25.12+ 使用 `.apk`**），使用随附的 `SHA256SUMS` 校验文件哈希后上传至路由器 `/tmp` 目录安装：

**OpenWrt 24.10 (`opkg`)：**

```sh
opkg update
opkg install /tmp/luci-app-hybrid-subscription_*.ipk
# 安装简体中文语言包（可选）：
opkg install /tmp/luci-i18n-hybrid-subscription-zh-cn_*.ipk
```

**OpenWrt 25.12+ (`apk`)：**

```sh
apk update
apk add --allow-untrusted /tmp/luci-app-hybrid-subscription-*.apk
# 安装简体中文语言包（可选）：
apk add --allow-untrusted /tmp/luci-i18n-hybrid-subscription-zh-cn-*.apk
```

> Release 中的安装包由 GitHub Actions 调用官方 OpenWrt SDK 构建，未使用 OpenWrt 官方软件源私钥签名，因此在 `apk` 体系下需携带 `--allow-untrusted` 参数。运行时依赖（`ruby`、`luci-lib-uqr`、`curl` 等）将自动从路由器软件源解析安装。

### 2. 使用 OpenWrt SDK 编译

将本仓库放入 OpenWrt SDK 的 `package/luci-app-hybrid-subscription` 目录后执行：

```sh
make package/luci-app-hybrid-subscription/compile V=s
```

### 3. 开发环境一键直装

在开发调试阶段，可通过 SSH 将工作区代码直接部署至已安装依赖的路由器：

```sh
# 需预先在路由器上安装依赖：
# apk add luci-base luci-lib-uqr rpcd curl ruby ruby-json ruby-yaml ruby-digest ruby-open3 ruby-fileutils ruby-uri ruby-timeout ruby-ipaddr ruby-socket
./scripts/deploy.sh root@192.168.1.1
```

安装过程会自动备份原有的同名文件，不会重启 OpenClash 或改动其当前配置。安装后可在 LuCI 导航栏 **服务 → 混合订阅** 中访问。

## 快速上手

1. **添加订阅源（订阅源）**：点击**从 OpenClash 导入**可直接复用本机已有的订阅定义与节点缓存（不会请求上游服务器），也可手动新建订阅源。对于限制拉取次数或仅限时开放的订阅源，请将更新方式保持为**仅手动**。
2. **创建订阅配置（订阅配置）**：点击**快速创建订阅配置**生成包含默认节点选择组的基础配置（同时支持 Mihomo、Surge 与 sing-box），或按需添加地区策略组与 Mihomo 重匹配/子规则。
3. **编排规则（分流规则）**：按需添加有序分流规则（支持 `DOMAIN-SUFFIX`、`IP-CIDR`、`RULE-SET`、`GEOIP`、`GEOSITE` 及递归 `AND`/`OR`/`NOT` 逻辑组合）与共享规则集。
4. **检查兼容性（兼容性）**：基于已保存配置与本地节点缓存，逐一检查 Mihomo、Surge、sing-box、Shadowrocket 四端兼容性。若使用了目标端不支持的专属分流特性，可通过**兼容性向导**拆分为独立的客户端配置。
5. **构建与发布（状态概览）**：在配置卡片上点击**构建并发布**，核对跨客户端兼容性提示后确认发布，即可点击**下载 / 二维码**在各端导入订阅。
6. **同步至 OpenClash（可选）**：在已发布配置的**版本管理**中可手动将 Mihomo 配置应用至 OpenClash，也可在**全局设置**中开启**发布后自动应用至 OpenClash**。

## 功能机制说明

### 订阅互转与兼容性向导

各协议版本、客户端更新记录、上游参考提交与验证范围见[兼容性版本基线](docs/compatibility-versions.md)。

在**订阅源**中可选择自动识别或手动指定订阅格式，随后刷新缓存或导入订阅文本。导入过程仅提取**代理节点**（Mihomo 的 `proxies`、Surge / Shadowrocket 的 `[Proxy]`、sing-box 的代理 `outbounds`），忽略上游配置自带的策略组、分流规则、DNS、监听端口与控制器密钥；最终导出的分流结构完全由本工具中的“订阅配置”与“分流规则”决定。若 Surge、Shadowrocket 或 sing-box 节点包含无法准确映射的未知参数，导入会直接报错拒绝；Mihomo 节点的原始字段则完整保存在缓存中，导出至其他客户端时若有字段无法等价转换，会在发布前给出明确的差异提示。

**兼容性**页面会同时检查四种目标客户端（包括当前未勾选导出的格式），且仅读取已保存的配置与本地节点缓存，不会请求上游订阅。页面按当前选中的目标客户端归类汇总兼容性问题，支持展开查看具体受影响条目及导出校验详情。内置向导采用 LuCI 原生表单与对话框，处理流程如下：

1. 选择目标客户端，并填写新配置的标识符与名称。
2. 为需要调整的策略组选择手动选择、延迟测速，或目标端支持的故障转移模式；对于重匹配入口（`rematch`），可替换为固定出口策略，也可指定候选策略列表来新建手动选择组或延迟测速组。
3. 按需选择是否在副本中移除子规则分流、移除 Mihomo 专属 DNS / 高级策略，或停用特定分流规则。注意：仅调整策略组的切换方式不会自动转换不兼容的规则条件，也无法还原重匹配（Rematch）的二次分流逻辑。
4. 预览变更方案，按类别展开核对具体变更明细，并逐类勾选确认。若仍存在不支持的节点协议、缺失目标端规则集地址等阻断性错误，须先解决后方可创建副本。
5. 生成独立的配置草稿，随后前往**状态概览**执行构建与发布。原配置及其导出格式保持不变；若原配置仅用于 Mihomo，可在**订阅配置**中单独将其导出格式改为仅 Mihomo。

点击**使用推荐设置**（或向导内的**填入推荐设置**）仅会为尚未设置的策略组和重匹配入口预填推荐方案，不会覆盖已手动选择的项；点击**应用至受影响策略组**则会将所有受影响策略组的切换方式统一替换为所选批量模式，未受影响的策略组保持不变（可通过**显示全部策略组**展开查看）。批量选择**推荐模式**时，没有可用建议的策略组保留当前选择。对于重匹配入口，系统会按目标子规则内已启用规则及兜底策略的先后顺序提取候选策略组（不保留原匹配条件）；若子规则链路中包含 `DIRECT` / `REJECT`、缺失引用、循环依赖或不支持的条件，则需手动指定。所有自动推荐均不会默认勾选移除分流规则、子规则或 DNS 策略。

将策略组改为手动选择仅影响该组自身的出口切换方式，其下属候选子组仍保持原有模式。延迟测速模式由目标客户端根据连通性测速结果自动优选；Surge 故障转移模式则按候选列表顺序依次回退。上述模式调整均不保留 Smart 权重记录或重匹配 / 子规则的二次判断逻辑。对于 sing-box，手动选择（`selector`）依赖客户端图形界面或 Clash API 切换节点，而本工具导出的配置默认不开启控制器监听；若客户端无切换入口，将默认固定使用列表中的第一个候选策略。详见 [Surge 策略组文档](https://manual.nssurge.com/policy-groups/overview.html)与 [sing-box selector 文档](https://sing-box.sagernet.org/configuration/outbound/selector/)。

| 特性 | 跨客户端处理方式 |
| :--- | :--- |
| `AND` / `OR` / `NOT` 逻辑规则 | 当所有子条件均受目标端支持时，自动编译为目标客户端的原生逻辑规则。 |
| 内联 `classical` 规则集（可包含域名 / IP 条件） | 展开并内嵌为目标客户端原生规则或内联规则集；若含不兼容条目则直接拦截导出。 |
| 目标端不支持的策略组模式（如 `smart` / `load-balance`） | 在向导副本中显式改为手动选择或受支持的基础自动模式，绝不静默丢弃候选策略或分流条件。 |
| 重匹配入口（`rematch`）与 Mihomo 子规则（`sub-rules`） | 将各重匹配入口替换为固定出口或指定候选列表的手动 / 测速组；移除子规则需另行确认。 |
| Mihomo 专属 DNS 策略 | 需在副本中显式移除并改用目标客户端生成的系统 / 本地默认 DNS。 |
| `GEOSITE`、`REMATCH-NAME` 规则 | 需改写为目标客户端支持的规则，或在向导副本中显式停用。 |
| sing-box 下的非 `LAN` `GEOIP` 及 `no-resolve` | 需改用 sing-box 原生规则集（`rule_set`）或兼容规则。 |
| 目标端不支持的代理协议或传输层参数 | 直接拦截导出，向导不会自动剔除不兼容节点。 |

注：上表兼容性范围以本工具已验证的转换映射为准，并非代表各客户端全部版本的能力上限。通过向导生成的配置草稿在正式构建发布时，若仍存在非阻断性的字段差异，依然需要二次勾选确认；向导本身仅保存草稿，不会自动发布或同步至 OpenClash。

向导在生成兼容草稿的同时会记录其转换方案与来源关联，后续可直接对该配置执行构建、发布与分发。仅当来源配置的策略组、分流规则、DNS 或引用的依赖项发生变更时，**状态概览**与**兼容性**页面才会提示复核；日常刷新节点缓存、查询流量额度或修改无关全局设置不会触发提醒。进入复核时，系统会自动恢复仍然有效的历史选项，并单独列出因上游变动而需重新指定的项目。

确认更新后，新生成的配置会直接写回原兼容草稿，完整保留其配置名称、标识符与订阅下载链接（线上已发布的下载内容仍需再次构建并发布后才会生效）。若该兼容草稿曾被手动修改，更新前会列出将被覆盖的差异项供你确认；若来源配置已被删除，现有兼容草稿及已发布订阅仍可正常使用，但无法再从来源配置同步更新。旧版向导生成的配置不含来源追踪记录，需通过新版向导重新创建一次后方可启用方案记忆与变更追踪。

### Shadowrocket 导出

Shadowrocket 作为独立的导出目标（`shadowrocket`）按需启用，生成的 **`shadowrocket.yaml` 包含节点、策略组、规则集与有序分流规则**。使用时请在 Shadowrocket 的**配置**页面通过链接或文件导入，选中后开启按配置分流；仅作为普通节点订阅导入不会启用分流规则。快速创建配置默认仍勾选 Mihomo、Surge 与 sing-box。

节点字段转换参考了 [Sub-Store 的 Shadowrocket 转换实现](https://github.com/sub-store-org/Sub-Store/blob/1f0318bc6feb46fbe204836f32ca7acab37ea67e/backend/src/core/proxy-utils/producers/shadowrocket.js)，覆盖 AnyTLS、Shadowsocks、Trojan、VMess、VLESS、Hysteria2 与 TUIC，策略组与分流规则则由本工具根据配置一并编译生成。若存在不支持的参数组合或无法解析的节点依赖，导出会直接报错中止，不会静默剔除节点；对于客户端实际表现尚待确认的高级字段，导出时会予以保留并在发布前提示确认。

策略组支持手动选择、延迟测速、故障转移和负载均衡；分流规则保留原有顺序、策略目标、逻辑条件与兜底策略，内联规则集会直接展开为普通规则条件。远程规则集需单独填写 **Shadowrocket 地址**，且必须指向规则内容等价、包含 `payload` 列表的 **Clash classical YAML 规则集**（导出为 `behavior: classical` 的 HTTP `rule-provider`），即使其他客户端使用的是域名或 IP 列表，也不会自动混用 Surge 规则文本、Mihomo MRS 或其他格式的规则地址。

支持导入 Clash YAML 并不代表完整兼容 Mihomo 专有特性：`rematch`、子规则、`GEOSITE`、`REMATCH-NAME` 及 Mihomo 原生 DNS 仍需在兼容副本中调整或移除，`smart` 策略组需改为受支持的替代模式，移除原生 DNS 后将使用客户端默认 DNS 设置。默认节点选择、空组回退、惰性测速（`lazy`）等行为差异也会在发布前提示确认，转换方案保存、来源变更提醒与复核更新流程与其他客户端一致。目前原生 `.conf` 导出已移除，仅保留基础 SS、Trojan、VMess、VLESS 的原生节点导入（需显式指定 `udp=0/1`，不支持未验证的引号或转义写法）；若导入的原生节点文本缺少格式标记、无法与 Surge 自动区分，请手动选择 Shadowrocket 格式。

相关客户端版本记录、Sub-Store 转换实现及 clash-skk 规则集参考提交详见[兼容性版本基线](docs/compatibility-versions.md#shadowrocket-release-evidence)。目前自动化测试已覆盖字段映射与发布流程，尚未在 Shadowrocket 真机上完成导入、规则命中与连通性实测。

### 流量与到期查询

额度解析兼容 [OpenClash](https://github.com/vernesong/OpenClash/blob/master/luci-app-openclash/luasrc/controller/openclash.lua) 使用的 `Subscription-Userinfo` 响应头格式（`upload; download; total; expire`）：

- **独立额度查询地址（`quota_url`）**：支持为每个订阅源设置独立查询接口，刷新额度时优先调用，不跟随重定向，失败时不会回退请求原订阅地址。
- **订阅响应头查询开关（`quota_via_subscription`）**：默认关闭。普通订阅源开启后，手动点击**刷新额度**时会向订阅地址发送 `GET` 请求并仅读取响应头；限时或限次订阅请保持关闭。
- **本地缓存复用**：若系统已安装 OpenClash，后台会自动读取相同订阅地址对应的 Mihomo `proxy-providers` 本地额度信息。

### 国家与地区匹配模板

在**全局设置 → 地区匹配**中可一键添加常用国家/地区模板（支持国旗 Emoji、中英文名称与带边界匹配的 ISO 国家代码），并支持为特定订阅源单独设置专属正则。点击**预览地区匹配结果**可基于当前本地缓存离线测试匹配效果，排查未命中或同时命中多个地区的节点。

### 访问控制与存储安全

- **三种下载鉴权方式**：支持**局域网访问 + 下载令牌**（默认）、**仅校验下载令牌（所有可达网络）**与**仅限已登录的 LuCI 会话**。
- **凭据隔离与脱敏**：后台配置与版本文件存储于权限受限的 `/etc/hybrid-subscription`（目录 `0700`，文件 `0600`）。日常读取配置列表时不返回订阅地址与额度查询地址；仅当具备编辑权限的用户打开单个订阅源的编辑窗口时，才会按需载入该源已保存的地址（默认掩码隐藏，可点击显示按钮查看）。预览界面会自动脱敏服务器地址、密码与私有令牌。
- **卸载方式**：将 OpenClash 切换至非 `HybridSubscriptions-*.yaml` 配置后，运行 `scripts/uninstall-router.sh` 即可卸载程序（`/etc/hybrid-subscription` 下的配置数据将保留以备恢复）。

## 国际化与开发测试

- **标准 LuCI i18n**：源码默认使用英文 `msgid`，提供 `po/templates/hybrid-subscription.pot` 模板与 `po/zh_Hans/hybrid-subscription.po` 简体中文翻译，并在 `hybrid-subscription.js` 中内置 `hs.registerLocale` 运行时语言注册表，支持对后端动态参数化校验报错进行本地化转换。
- **运行完整测试套件**：

项目开发环境提供 Ruby 3.4、Minitest、Node.js 24 和 gettext。安装 [devenv](https://devenv.sh/) 后运行：

```sh
devenv shell -- sh scripts/test.sh
```

`scripts/test.sh` 会依次执行全部 `tests/test_*.rb` Ruby 单元测试（包括格式转换矩阵、Shadowrocket 映射与兼容性方案测试）、JavaScript 前端与工作台测试、`msgfmt` 翻译格式检查及 Shell 脚本语法校验。GitHub Actions 在每次推送、Pull Request 及推送 `v*` 版本标签时均会自动执行测试并构建 OpenWrt 24.10 (`.ipk`) 与 25.12 (`.apk`) 安装包。

## 许可证

Copyright 2026 Zerlight Wu and contributors。本项目基于 [Apache License 2.0](LICENSE) 开源。

LuCI 及独立安装的 OpenClash、subconverter 等外部组件遵循各自的开源许可证，本仓库不捆绑其源码或二进制文件。
