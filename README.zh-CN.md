# LuCI 混合订阅管理器 (luci-app-hybrid-subscription)

[English](README.md) | [简体中文](README.zh-CN.md)

一款原生 OpenWrt LuCI 订阅聚合与配置管理应用，用于集中管理多订阅源节点缓存、共享分流规则集、策略组编排，并生成支持版本化管理的 Mihomo、Surge 与 sing-box 配置文件。本应用定位于配置编译与发布服务，而非运行期代理监控面板。

## 核心功能

- **多源聚合与多配置隔离**：支持将任意数量的订阅源按需组合为多套独立的订阅配置（Profile）。
- **多格式节点解析**：原生支持导入 Mihomo（Clash Meta）YAML、Surge 配置、sing-box JSON 以及主流代理协议分享链接（URI / Base64）。
- **无损字段保留与显式兼容校验**：完整保留 Mihomo 原始节点字段。导出至其他客户端格式时，对无法映射的字段生成显式兼容性提示，对目标客户端不支持的协议予以阻断，杜绝静默丢弃节点或规则。
- **策略编排与依赖可视化**：支持按订阅源与正则表达式筛选节点、配置多客户端策略组类型、编排有序分流规则及管理远程/内联规则集，并内置原生 SVG 依赖关系图。
- **Mihomo 高级路由特性**：支持重匹配入口（`rematch`）、命名子规则（`sub-rules`）、递归逻辑组合条件（`AND` / `OR` / `NOT`）、内联规则集以及受控的 DNS、地理数据库（GeoIP / GeoSite）与域名嗅探策略。凡无跨客户端等价实现的特性均会显式拦截不兼容的目标格式。
- **全生命周期版本发布**：遵循“保存草稿 → 校验与脱敏预览 → 构建不可变版本 → 确认兼容性差异 → 正式发布 / 历史版本回滚”的发布流程。
- **受控下载与二维码导入**：支持“局域网访问 + 下载令牌”、“仅校验下载令牌（所有可达网络）”和“仅限已登录的 LuCI 会话”三种访问控制模式，并使用 LuCI 内置 `uqr` 库生成订阅二维码。
- **读写分离的缓存架构**：各订阅源支持独立配置“仅手动”或“定时更新”。客户端请求下载链接时仅读取已发布的静态构建产物，**绝不触发上游订阅拉取**。
- **OpenClash 深度协同**：支持一键导入现有 OpenClash 订阅源定义与本地节点缓存；可将已发布的 Mihomo 配置手动或自动应用至 OpenClash，应用前自动执行内核语法隔离校验并启动超时回滚守卫。
- **本地转换器比对**：支持将原生解析的缓存节点与本机回环地址运行的 `subconverter` 转换结果进行无副作用比对。

本应用仅面向现代 Mihomo、Surge 与 sing-box 客户端格式，不提供旧版 Clash、SSR 或 Quantumult 等历史格式的导出支持。

## 安装与部署

项目 `Makefile` 遵循 OpenWrt LuCI 标准软件包规范，可放入 OpenWrt SDK 的 LuCI 应用目录中直接编译打包。所有运行时依赖均已在 `Makefile` 中声明。

在开发调试阶段，也可直接部署至已配置好依赖的 OpenWrt 路由器：

```sh
apk add ruby-json ruby-open3 ruby-fileutils ruby-uri ruby-timeout ruby-ipaddr ruby-socket
./scripts/deploy.sh root@router.example
```

安装脚本会自动备份被替换的文件，且不会重启 OpenClash 或改动其当前激活的配置文件。安装完成后，可在 LuCI 顶部导航栏 **服务 → 混合订阅**（英文界面为 **Services → Hybrid Subscription**）中访问。路由器需预先安装 `luci-base`、`luci-lib-uqr`、Ruby 标准库（YAML / Digest 等）、`curl` 与 `rpcd`。

## 快速上手

1. **添加订阅源**：前往**订阅源**页面，从 OpenClash 导入现有订阅或手动新增订阅源。若计划通过本地文件导入节点，订阅地址可留空保存。
2. **保护限时/限次订阅**：对于存在拉取时间窗口或次数限制的订阅源，请将更新方式保持为**仅手动**。从 OpenClash 导入订阅源时仅读取本地既有缓存，不会向上游发起网络请求。
3. **配置策略组与规则**：在**订阅配置**页面创建配置（可使用**快速创建订阅配置**生成包含默认手动选择策略组的基础模板），按需添加地区策略组与分流规则。
4. **校验、构建与发布**：前往**状态概览**页面，点击**构建并发布**完成配置校验与版本构建，核对兼容性差异后确认发布。发布成功后即可获取订阅下载链接与二维码。
5. **应用至 OpenClash**：将配置应用至 OpenClash 与版本发布相互独立（默认关闭自动应用），应用过程可能短暂重载代理连接。受管配置文件统一命名为 `HybridSubscriptions-<id>.yaml`，不会覆盖用户原有的其他 OpenClash 配置。

## 日常使用指南

- **状态概览**：查看各订阅源缓存状态与流量额度，跳转配置编辑，执行构建、发布、下载与扫码；点击**版本管理**可查看历史构建记录、回滚版本、重置下载令牌或手动同步至 OpenClash。
- **订阅源**：管理节点缓存更新、导入本地订阅文件、配置独立额度查询接口，以及执行 `subconverter` 兼容性比对。
- **订阅配置**：通过顶部筛选器切换当前订阅配置，集中编辑导出格式、策略组及 Mihomo 重匹配/子规则；页签切换不会丢失当前页面尚未保存的草稿修改。
- **分流规则**：按所属订阅配置与规则域（主规则链或子规则）筛选并拖拽调整规则顺序；下方可独立管理跨配置共享的远程或内联规则集。
- **全局设置**：维护国家/地区匹配模板、下载访问控制策略、OpenClash 自动应用开关及本地 `subconverter` 地址。页面底部**保存**按钮仅更新配置草稿，版本发布均在**状态概览**页面确认执行。

## 流量与到期状态查询

额度解析遵循 OpenClash 所采用的 `Subscription-Userinfo` 响应头规范（`upload; download; total; expire`，参见 [OpenClash 状态查询实现](https://github.com/vernesong/OpenClash/blob/master/luci-app-openclash/luasrc/controller/openclash.lua)）：

- **独立额度查询地址**：支持为每个订阅源配置独立的额度查询接口（`quota_url`），保存后不会回传至浏览器。刷新额度时优先请求独立接口，不跟随重定向，失败时亦不会回退请求原订阅地址。
- **订阅响应头查询开关**：普通订阅源可显式勾选**允许通过订阅地址查询额度**（`quota_via_subscription`，默认关闭）。开启后，手动点击**刷新额度**时会向订阅地址发送 `GET` 请求并仅读取响应头；限时或限次拉取的订阅源请保持关闭。
- **本地缓存复用**：若系统已安装 OpenClash，后台会自动匹配相同订阅地址的 Mihomo `proxy-providers` 本地额度信息。
- **纯手动触发**：**刷新额度**仅更新流量与到期元数据，不触发节点拉取或版本构建。页面定时轮询、后台计划任务及客户端下载请求均不会发起额度查询。

## 国家与地区匹配模板

在**全局设置 → 地区匹配**中可添加常用国家/地区模板或自定义匹配规则：

- 内置模板支持匹配国旗 Emoji、中英文名称以及带单词边界断言的两字母/三字母国家代码，避免短代码误命中普通英文单词。
- 支持按订阅源单独设置专属正则表达式，覆盖通用匹配规则。
- **预览地区匹配结果**基于当前本地缓存中的原始节点名称进行离线试算，清晰展示未匹配节点与命中多个地区的冲突节点，不产生网络请求，也不会自动保存草稿。
- 策略组选择**地区匹配模板**后，将与该策略组自身的包含、排除正则表达式取交集生效。地区匹配仅依据节点名称归类，不代表节点实际出口 IP 归属地。

## 访问安全与存储隔离

默认下载访问鉴权方式为**局域网访问 + 下载令牌**，也可按需切换为**仅校验下载令牌（所有可达网络）**或**仅限已登录的 LuCI 会话**。修改**订阅链接基础地址**仅改变生成的链接前缀，不会自动开放防火墙端口或配置内网穿透服务。

后台状态、节点缓存与历史发布产物均保存在权限受限的 `/etc/hybrid-subscription` 目录中（目录权限 `0700`，文件权限 `0600`）。订阅地址与额度查询地址在前端均为只写字段，配置预览界面会自动对服务器地址、连接密码及私有查询令牌进行脱敏处理。

执行**停止发布**将立即吊销对应下载令牌并停用下载链接，同时保留历史版本记录与当前正在运行的 OpenClash 配置。如需卸载本应用，请先将 OpenClash 切换至非受管配置，再运行 `scripts/uninstall-router.sh`。

## 国际化与多语言扩展 (i18n)

本项目采用 OpenWrt LuCI 标准国际化体系，并内置运行时多语言扩展注册表以兼顾 SDK 编译与脚本直装场景：

- **英文基准词条（`msgid`）**：前端视图（`htdocs/luci-static/resources/`）、菜单定义（`root/usr/share/luci/menu.d/`）、ACL 权限描述（`root/usr/share/rpcd/acl.d/`）及后端 Ruby 模块（`root/usr/share/hybrid-subscription/`）均以规范英文作为默认源字符串。
- **标准 PO / POT 目录结构**：翻译模板位于 `po/templates/hybrid-subscription.pot`，简体中文翻译位于 `po/zh_Hans/hybrid-subscription.po`。通过 OpenWrt SDK 编译时由 `luci.mk` 自动生成 `.lmo` 二进制语言包；使用 `scripts/install-router.sh` 直装时，若路由器具备 `po2lmo` 也会自动编译安装。
- **可扩展的运行时语言注册表**：`htdocs/luci-static/resources/hybrid-subscription.js` 提供 `hs.registerLocale(code, { separator, aliases, exact, patterns })` 接口，既可在未编译 `.lmo` 的直装环境中提供完整翻译回退，又能对后端返回的动态参数化校验错误与告警信息进行本地化匹配。后续新增其他语言时，只需在 `po/<lang>/hybrid-subscription.po` 中补充翻译，并通过 `hs.registerLocale` 注册对应语种词典即可。

## 单元测试

```sh
ruby tests/test_engine.rb
ruby tests/test_backend.rb
ruby tests/test_openclash.rb
ruby tests/test_converter.rb
ruby tests/test_quota.rb
ruby tests/test_regions.rb
node tests/frontend_test.js
node tests/workbench_test.js
```

所有测试均使用合成凭据与临时目录运行，不会请求外部上游订阅服务或改动宿主系统配置。

## 许可证

Copyright 2026 Zerlight Wu and contributors。本项目采用 [Apache License 2.0](LICENSE)。

LuCI 及独立安装的 OpenClash、subconverter 等集成组件仍遵循各自的许可证；本仓库不捆绑它们的源码或二进制文件。
