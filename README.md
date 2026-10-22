# LuCI Hybrid Subscription Manager

[![Test, build and release](https://github.com/Zerlight/luci-app-hybrid-subscription/actions/workflows/ci.yml/badge.svg)](https://github.com/Zerlight/luci-app-hybrid-subscription/actions/workflows/ci.yml)
[![Latest Release](https://img.shields.io/github/v/release/Zerlight/luci-app-hybrid-subscription?include_prereleases)](https://github.com/Zerlight/luci-app-hybrid-subscription/releases)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10%20%7C%2025.12-00B5E2)](https://github.com/Zerlight/luci-app-hybrid-subscription/releases)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

[English](README.md) | [简体中文](README.zh-CN.md)

A native OpenWrt LuCI application for **multi-source subscription aggregation** and **visual routing rule orchestration**. It caches upstream proxy subscriptions locally, compiles policy groups and routing rules, and publishes versioned configurations for **Mihomo (Clash Meta)**, **Surge**, **sing-box**, and **Shadowrocket** (supported Clash YAML subset).

```text
Upstream Subscriptions ──► Local Node Cache ──► LuCI Rule & Group Editor ──► Immutable Release ──► Client Pull (QR / URL)
   (Manual / Scheduled)    (/etc/hybrid-...)    (Client-specific formats)    (SHA-256 Verified)    └──► OpenClash Apply
```

This application focuses on configuration compilation and distribution. Runtime traffic graphs and live node switching remain with client dashboards.

## Key Features

- **Read/Write Decoupled Subscription Fusion**: Combine multiple subscription sources into independent profiles, filter nodes by source or region regex templates, and serve client downloads directly from published local files—**client downloads never trigger upstream subscription requests**.
- **Native LuCI Rule Engine & Dependency Graph**: Edit policy groups, ordered routing rules, shared remote/inline rule sets, and Mihomo rematch/sub-rule trees using standard LuCI forms. Inspect group and sub-rule references with an in-browser SVG dependency graph.
- **Multi-Client Conversion & Compatibility Wizard**: Import node subscriptions from Mihomo, Surge, sing-box, or Shadowrocket and export configurations tailored to each target client. A native LuCI **Compatibility** tab inspects all four targets and helps you spin off client-specific profiles—adapting policy group modes, replacing Mihomo rematch entries, or disabling incompatible rules with explicit confirmation before saving. Unsupported protocols and rule semantics block output, while field differences require confirmation before publication.
- **Immutable Releases & Instant Rollback**: Validate drafts, preview redacted outputs, build immutable releases, publish, or roll back to any previously published release.
- **Client Subscription Updates**: Opt in per profile to Surge `#!MANAGED-CONFIG` headers and Clash `Profile-Update-Interval` response headers. Clients always fetch the latest published release without triggering upstream source refreshes or publishing drafts.
- **Safe OpenClash Integration**: Import existing OpenClash subscription definitions and local caches in one click. Apply a published Mihomo release to OpenClash manually or automatically, guarded by isolated `clash_meta -t` syntax checks and an automatic rollback watchdog.
- **Zero-Daemon Lightweight Architecture**: Built with native LuCI JavaScript and on-demand Ruby CGI/RPCD workers—no persistent Node.js, Docker, or web server process required on the router.

## Resource Footprint & Router Hardware Requirements

Many OpenWrt routers run with tight RAM, CPU, and flash constraints. Because this project uses an **on-demand short-lived worker architecture** rather than a persistent application server, its idle overhead is near zero:

- **No Persistent Web Daemon**: All UI forms, QR codes (`luci-lib-uqr`), and SVG dependency graphs render in your browser. The background scheduler (`/etc/init.d/hybrid-subscription`) is a minimal POSIX `/bin/sh` loop (`sleep 60`) that wakes briefly once per minute to check scheduled source timestamps.
- **Short-Lived On-Demand Workers**: Ruby processes run only when you open the editor, refresh a source, build a release, or fetch a subscription link, and exit immediately afterward—returning all memory to the OS.

### Measured Resource Usage

| Metric | Footprint / Measurement | Notes |
| :--- | :--- | :--- |
| **Flash / Disk (Packages)** | **~350 KiB** (app + `zh-cn` i18n) / **~5–6.5 MiB** (with Ruby stdlib dependencies) | Total uncompressed size on OverlayFS when Ruby is not already installed. |
| **Flash / Disk (Data)** | **~50–300 KiB** per cached source / **~100–800 KiB** per published release | Stored under `/etc/hybrid-subscription` (Depends on node count and enabled target formats). |
| **RAM (Idle)** | **< 1 MiB** | Only the `/bin/sh` timer loop remains resident; **0 MB** of resident Ruby memory when idle. |
| **RAM (Client Download)** | **~10–14 MiB** transient (< 30 ms) | Authenticates the token, verifies the stored SHA-256 digest, and delivers the published configuration. |
| **RAM (Build & Validation)** | **~16–28 MiB** (100–300 nodes) / **~35–65 MiB** (1,000–4,000 nodes) | Peak RSS of the temporary worker process while compiling Mihomo, Surge, and sing-box outputs. |
| **RAM (OpenClash Pre-Check)** | **+50–120 MiB** transient (only if OpenClash is installed) | Invokes `clash_meta -t` to validate Mihomo syntax and GeoIP/GeoSite databases before release/apply. |
| **CPU Time (3-Format Build)** | **~0.1–0.4 s** (100–300 nodes on ARM Cortex-A53) / **~10–90 ms** (on x86_64) | 1,000 nodes across all 3 formats takes ~0.5–1.5 s on typical dual-core ARM routers and ~90 ms on x86_64. |

### Recommended Router Specifications

| Deployment Scenario | Minimum Hardware | Recommended Hardware | Practical Guidance for Low-Memory Routers |
| :--- | :--- | :--- | :--- |
| **Standalone Subscription Hub** *(No local OpenClash)* | **128 MiB RAM**<br>16 MiB free flash<br>MIPS / ARM 580 MHz+ | **256 MiB+ RAM**<br>32 MiB+ free flash<br>Dual-core ARMv8 / x86_64 | Runs comfortably on entry-level routers (e.g., MT7621 / IPQ4019). Keep total cached nodes under ~500 on 128 MiB devices. |
| **Co-Deployed with OpenClash** *(Running Mihomo on the same router)* | **256 MiB RAM** *(with ZRAM/Swap)*<br>32 MiB free flash<br>Dual-core ARM / MIPS | **512 MiB+ RAM**<br>64 MiB+ free flash<br>ARM64 (MT7981/7986, IPQ) / x86_64 | On 256 MiB routers running OpenClash, set `"geodata-loader": "memconservative"` in **Mihomo Advanced Policy** and enable ZRAM/Swap to avoid OOM spikes during `clash_meta -t` validation and service reloads. |

## Installation

### 1. Install from GitHub Releases (Recommended)

Download the prebuilt packages from [GitHub Releases](https://github.com/Zerlight/luci-app-hybrid-subscription/releases) matching your OpenWrt version (**24.10 uses `.ipk`**, **25.12+ uses `.apk`**), verify checksums against `SHA256SUMS`, and install on your router:

**OpenWrt 24.10 (`opkg`):**

```sh
opkg update
opkg install /tmp/luci-app-hybrid-subscription_*.ipk
# Optional Simplified Chinese translation package:
opkg install /tmp/luci-i18n-hybrid-subscription-zh-cn_*.ipk
```

**OpenWrt 25.12+ (`apk`)：**

```sh
apk update
apk add --allow-untrusted /tmp/luci-app-hybrid-subscription-*.apk
# Optional Simplified Chinese translation package:
apk add --allow-untrusted /tmp/luci-i18n-hybrid-subscription-zh-cn-*.apk
```

> Release packages are built in CI with the official OpenWrt SDK and are not signed by upstream OpenWrt feed keys, so `--allow-untrusted` is required on `apk`-based releases. Always verify package hashes against `SHA256SUMS` before installing.

### 2. Build from OpenWrt SDK

Place this repository in `package/luci-app-hybrid-subscription` inside an OpenWrt SDK tree and run:

```sh
make package/luci-app-hybrid-subscription/compile V=s
```

### 3. Direct Deployment (Development)

To deploy directly from a working checkout to a router over SSH:

```sh
# Ensure dependencies are installed on the router first:
# apk add luci-base luci-lib-uqr rpcd curl ruby ruby-json ruby-yaml ruby-digest ruby-open3 ruby-fileutils ruby-uri ruby-timeout ruby-ipaddr ruby-socket
./scripts/deploy.sh root@192.168.1.1
```

The installer backs up replaced files and never restarts OpenClash or switches its active configuration. Once installed, open **Services → Hybrid Subscription** (**服务 → 混合订阅**).

## Quick Start

1. **Add Sources (`Subscription Sources`)**: Click **Import from OpenClash** to reuse existing subscription definitions and node caches without contacting upstream servers, or add a new source manually. Leave **Update Mode** set to **Manual Only** for rate-limited or time-windowed providers.
2. **Create a Profile (`Subscription Profiles`)**: Click **Quick Create Profile** to generate a starter profile with a manual selection group for Mihomo, Surge, and sing-box, or build custom policy groups, region filters, and Mihomo rematch/sub-rule chains.
3. **Configure Rules (`Routing Rules`)**: Add ordered routing rules (`DOMAIN-SUFFIX`, `IP-CIDR`, `RULE-SET`, `GEOIP`, `GEOSITE`, or recursive `AND`/`OR`/`NOT` conditions) and shared remote or inline rule sets.
4. **Check Compatibility (`Compatibility`)**: Evaluate your saved profile against Mihomo, Surge, sing-box, and Shadowrocket using local caches. When a profile uses client-specific routing features, open the **Compatibility Wizard** to create an adapted, standalone draft for that target.
5. **Build & Publish (`Overview`)**: Click **Build & Publish** on the profile card. Review any cross-client compatibility warnings, confirm publication, and use **Download / QR Code** to import the subscription into your clients.
6. **Apply to OpenClash (Optional)**: Open **Release Management** on a published profile to apply the Mihomo output to OpenClash manually, or enable **Auto-Apply to OpenClash on Publish** under **Global Settings**.

## Core Concepts & Details

### Subscription Conversion and Compatibility

Protocol revisions, client release evidence, upstream commit pins, and validation limits are maintained in the [compatibility version baselines](docs/compatibility-versions.md).

Under **Subscription Sources**, choose automatic format detection or specify the source format explicitly, then refresh the cache or import subscription text. The importer extracts **proxy nodes only** (Mihomo `proxies`, Surge/Shadowrocket `[Proxy]`, or sing-box proxy `outbounds`) and ignores upstream policy groups, routing rules, DNS settings, listeners, and controller credentials; all exported routing structure is compiled from the profiles and rules managed in this application. Unknown Surge, Shadowrocket, or sing-box node parameters without a verified mapping reject the import immediately, whereas raw Mihomo node fields are preserved in the cache and surface explicit compatibility warnings when a target client cannot represent them.

The **Compatibility** tab evaluates all four target clients—including formats not currently enabled on the profile—using saved configuration and local caches without contacting upstream subscriptions. It groups related issues for the selected client with expandable affected items and export validation details. Its wizard uses native LuCI forms and modal dialogs:

1. Select a target client and enter an identifier and name for the new profile.
2. Choose how each affected policy group selects its outbound: manual selection, latency testing, or priority-based fallback (where supported). For Mihomo rematch entries, either map them to a fixed policy or create a manual/latency-test group from an explicit candidate list.
3. Decide separately whether to strip sub-rule routing, omit Mihomo DNS/advanced policies, or disable specific rules in the new copy. Adjusting a group's selection mode does not translate unsupported rule predicates or replicate rematch routing logic.
4. Preview the resulting plan, expand each change category to review its underlying changes, and confirm each category. Any remaining blocking errors (such as unsupported proxy protocols or missing target rule-set URLs) must be resolved before the copy can be created.
5. Create the standalone draft, then build and publish it from **Overview**. The original profile and its enabled export formats remain untouched; if the original profile should serve Mihomo only, update its **Export Formats** under **Subscription Profiles**.

**Use Suggestions** (or **Fill Unset Suggestions** inside the wizard) populates only unset policy group and rematch fields for review while preserving any existing selections. **Apply to Affected Groups** overwrites the mode of all affected policy groups with the chosen batch mode, leaving unaffected groups untouched (toggle **Show All Groups** to inspect or edit them). In **Suggested modes**, groups without an available suggestion keep their current choice. For rematch entries, suggestions collect candidate groups in order from enabled sub-rule entries and fallback policies without preserving their matching conditions; if a sub-rule path references `DIRECT`/`REJECT`, missing targets, dependency cycles, or malformed conditions, you must choose a replacement manually. Suggestions never auto-select rule disabling, sub-rule removal, or DNS policy removal.

Switching a group to manual selection only changes how that group chooses its immediate outbound—nested candidate groups keep their own modes. Latency testing delegates automatic selection to the target client's health checks, while Surge fallback follows the declared candidate order. None of these adaptations preserves Smart weight history or conditional rematch/sub-rule evaluation. On sing-box, manual selection (`selector`) requires a client UI or Clash API controls, and generated configurations do not enable an external controller listener; without external controls, `selector` defaults to its first candidate. See the [Surge policy group documentation](https://manual.nssurge.com/policy-groups/overview.html) and [sing-box selector documentation](https://sing-box.sagernet.org/configuration/outbound/selector/) for client details.

| Feature | Cross-Client Handling |
| :--- | :--- |
| `AND` / `OR` / `NOT` logical rules | Compiled into target-native logical rules when all nested leaf conditions are supported. |
| Inline `classical` rule sets containing domain/IP conditions | Embedded using target-native conditions or inline rule sets; unsupported entries block export for that target. |
| Unsupported group automation (`smart`, `load-balance`) | Explicitly switch to manual selection or a supported automatic mode in the copy; candidates and rule conditions are never silently dropped. |
| Rematch entries & Mihomo sub-rules | Replace each rematch entry with a fixed policy or an explicitly populated manual/latency-test group; removing sub-rules requires separate confirmation. |
| Native Mihomo DNS policy | Omit in the copy to use the target client's generated system/local DNS defaults, or configure DNS in the client separately. |
| `GEOSITE` & `REMATCH-NAME` rules | Replace with target-native rules or explicitly disable in the copy. |
| sing-box non-`LAN` `GEOIP` & `no-resolve` | Replace with a sing-box native `rule_set` or compatible rule. |
| Unsupported proxy protocols or transport options | Block conversion; the wizard never deletes incompatible nodes automatically. |

Compatibility reflects the mappings verified by this exporter rather than every capability of every client version. Drafts created through the wizard may still report field-level differences that require confirmation at publish time, and the wizard never publishes a release or reloads OpenClash automatically.

When creating a compatible draft, the wizard records its source profile and conversion choices for future reuse. **Overview** and **Compatibility** flag relevant changes to the source profile's policy groups, routing rules, DNS settings, or referenced dependencies, whereas routine node-cache refreshes, quota updates, and unrelated global settings never trigger a review notice. Opening a review restores all choices that remain valid and highlights any items whose upstream definitions changed.

Confirming an update writes the regenerated configuration back to the existing compatible draft while preserving its name, identifier, and download URL; the live subscription artifact changes only after you build and publish the updated draft. Any manual edits made directly to the compatible draft are surfaced for overwrite confirmation before saving, and if the source profile is deleted, the compatible draft and its published release remain usable as a standalone profile. Profiles created before strategy tracking was introduced do not carry source metadata and must be recreated once through the wizard to enable change tracking.

### Shadowrocket Export

Shadowrocket is an opt-in target (`shadowrocket`) that generates **`shadowrocket.yaml` containing proxy nodes, policy groups, rule providers, and ordered routing rules**. Import the generated file or URL under Shadowrocket's **Config** tab and enable configuration-based routing; importing it as a node-only subscription will not apply routing rules. **Quick Create Profile** continues to enable Mihomo, Surge, and sing-box by default.

Node field conversion follows [Sub-Store's Shadowrocket producer](https://github.com/sub-store-org/Sub-Store/blob/1f0318bc6feb46fbe204836f32ca7acab37ea67e/backend/src/core/proxy-utils/producers/shadowrocket.js) for AnyTLS, Shadowsocks, Trojan, VMess, VLESS, Hysteria2, and TUIC, while policy groups and routing rules are compiled from your saved profile. Unsupported parameter combinations or unresolved node dependencies block export rather than silently dropping nodes, and advanced fields with unverified client behavior are preserved with pre-publish warnings.

Policy groups support manual selection, URL tests, fallback, and load balancing. Routing rules preserve their order, targets, logical conditions, and final policy, with inline rule sets expanded into direct conditions. Each remote rule set's **Shadowrocket URL** must point to an equivalent **Clash classical YAML rule set containing a `payload` list** (emitted as an HTTP `rule-provider` with `behavior: classical`), even if other targets use domain or IP lists; Surge text lists, Mihomo MRS files, and other target URLs are never reused automatically.

Clash YAML support in Shadowrocket does not cover Mihomo-only extensions: `rematch`, sub-rules, `GEOSITE`, `REMATCH-NAME`, and native Mihomo DNS must still be adapted or omitted in a compatible copy, and `smart` groups must switch to a supported mode. Removing native Mihomo DNS falls back to Shadowrocket's default DNS handling, and behavioral differences such as default selections, empty-group fallback, and lazy health checks are flagged for confirmation before publishing. Strategy tracking and source-change reviews work the same way as for other targets. Native `.conf` export has been removed, while basic SS, Trojan, VMess, and VLESS native node lines remain supported on import (requiring explicit `udp=0/1` without unverified quoting or escaping). When importing an unmarked native node list that cannot be distinguished from Surge automatically, select the Shadowrocket format explicitly.

See the [compatibility version baselines](docs/compatibility-versions.md#shadowrocket-release-evidence) for Shadowrocket release notes and pinned [Sub-Store](https://github.com/sub-store-org/Sub-Store/blob/1f0318bc6feb46fbe204836f32ca7acab37ea67e/backend/src/core/proxy-utils/producers/shadowrocket.js) and [clash-skk](https://github.com/Paxxs/clash-skk/blob/cdb419f7d446c55b715261a8f5ff4b80f84fccbd/README.md) references. Automated tests verify field mapping and publication workflows, while on-device import, rule matching, and live connectivity in Shadowrocket have not yet been tested.

### Client Subscription Updates

**Client Updates** is disabled by default. When enabled on a profile, configure an update interval in whole hours (default **24**, range **1–720**), then build and publish. Client downloads read the update settings recorded in the active published release, so editing a draft does not affect live subscriptions until published.

For unattended background updates, configure a stable **Subscription Base URL** under **Global Settings** and use token-based download access. A LAN-only address is unreachable away from home unless you connect through a home VPN or overlay network—changing the access mode alone does not expose the router to the internet. **Authenticated LuCI Session Only** requires an active browser login and cannot be used for scheduled client updates.

| Client | Setup & Behavior |
| :--- | :--- |
| Surge Mac / iOS | Prepends a `#!MANAGED-CONFIG` header with `strict=false`, keeping the local profile usable if an update fails. Building with client updates enabled requires a configured base URL and token-based access. Updates run only while the main Surge app is active and are not guaranteed to fire at the exact interval. |
| Clash Verge Rev | Import the **Mihomo** subscription URL; the response includes `Profile-Update-Interval` (in hours). Any interval already saved in the client takes precedence, so check the profile's update settings in the client after changing this value. |
| Clash Meta Android | Import the **Mihomo** subscription URL. The reviewed version (`v2.11.36`) reads `Profile-Update-Interval` only during initial import when no local interval is set; existing profiles must be updated in the app. If a scheduled update fails while offline, trigger one manual update after reconnecting to resume background scheduling. |
| Shadowrocket | Import the **Shadowrocket YAML** URL under **Config** and use the app's built-in configuration update controls. Because unattended update headers for full Clash YAML configs have not been verified on device, no automatic-update declaration is injected. |

If you change the **Subscription Base URL** or rotate a download token, re-import the new URL on your clients. If the base URL is cleared or becomes invalid after publication, token-authenticated Surge downloads return an error rather than silently stripping the `#!MANAGED-CONFIG` header and converting a managed profile into a static one. Browser downloads authenticated via a LuCI session remain plain files without auto-update headers, and the download dialog highlights any transport configuration issues.

Client pulls never refresh upstream sources or publish drafts; updated source caches reach clients only after you build and publish a new release. Actual refresh timing depends on client scheduling and OS background restrictions, and retaining a cached profile locally does not prevent upstream node credentials or external rule sets from expiring. See the [client-update baselines](docs/compatibility-versions.md#client-subscription-update-baselines) for reviewed versions and scheduling details.

### Quota & Expiration Queries

Quota parsing supports the standard `Subscription-Userinfo` response header (`upload; download; total; expire`) used by [OpenClash](https://github.com/vernesong/OpenClash/blob/master/luci-app-openclash/luasrc/controller/openclash.lua):

- **Dedicated Quota URL (`quota_url`)**: An independent endpoint queried first without following redirects or falling back to the main subscription URL.
- **Subscription Header Opt-In (`quota_via_subscription`)**: Disabled by default. When enabled, clicking **Refresh Quota** sends a header-only `GET` request to the subscription URL. Keep this disabled for time-windowed or pull-limited subscriptions.
- **Local Provider Reuse**: Automatically reads local Mihomo `proxy-providers` quota metadata when OpenClash is installed and shares the same subscription URL.

### Region Matching Templates

Under **Global Settings → Region Matching**, built-in templates match flag emojis, Chinese/English names, and word-bounded ISO country codes. You can define per-source regex overrides and run **Preview Region Matches** against cached node names offline to spot unmatched or multi-region nodes before building.

### Access Control & Security

- **Access Modes**: Choose between **LAN + Download Token** (default), **Download Token (All Reachable Networks)**, or **Authenticated LuCI Session Only**.
- **Credential Protection**: State and artifacts live in `/etc/hybrid-subscription` (`0700` directories, `0600` files). Subscription and quota URLs are omitted from general configuration reads and loaded on demand only when a user with edit permission opens a source for editing, where they remain masked in password fields until revealed. Previews redact server addresses, passwords, UUIDs, and query tokens.
- **Clean Uninstallation**: Switch OpenClash away from any `HybridSubscriptions-*.yaml` profile and run `scripts/uninstall-router.sh`.

## Internationalization (i18n)

- **Standard LuCI Catalogs**: Source strings use English `msgid`s across `htdocs/`, `menu.d/`, `acl.d/`, and Ruby backend modules, paired with `po/templates/hybrid-subscription.pot` and `po/zh_Hans/hybrid-subscription.po`.
- **Extensible Runtime Registry**: `htdocs/luci-static/resources/hybrid-subscription.js` exposes `hs.registerLocale(code, { separator, aliases, exact, patterns })` to translate dynamic backend validation errors and provide fallback translations on direct-script deployments.

## Testing & CI

The project development shell provides Ruby 3.4 with Minitest, Node.js 24, and gettext. With [devenv](https://devenv.sh/) installed, run:

```sh
devenv shell -- sh scripts/test.sh
```

`scripts/test.sh` runs all `tests/test_*.rb` Ruby suites, including subscription conversion matrices, Shadowrocket mapping tests, and compatibility planning tests, JavaScript view/workbench tests, gettext `.po`/`.pot` format validation, and shell syntax checks. GitHub Actions runs this suite and builds `.ipk` (OpenWrt 24.10) and `.apk` (OpenWrt 25.12) packages on every push, pull request, and `v*` release tag.

## License

Copyright 2026 Zerlight Wu and contributors. Licensed under the [Apache License 2.0](LICENSE).

LuCI and optional external integrations (such as OpenClash and subconverter) retain their own licenses and are not bundled in this repository.
