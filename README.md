# LuCI Hybrid Subscription Manager

[![Test, build and release](https://github.com/Zerlight/luci-app-hybrid-subscription/actions/workflows/ci.yml/badge.svg)](https://github.com/Zerlight/luci-app-hybrid-subscription/actions/workflows/ci.yml)
[![Latest Release](https://img.shields.io/github/v/release/Zerlight/luci-app-hybrid-subscription?include_prereleases)](https://github.com/Zerlight/luci-app-hybrid-subscription/releases)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-24.10%20%7C%2025.12-00B5E2)](https://github.com/Zerlight/luci-app-hybrid-subscription/releases)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

[English](README.md) | [简体中文](README.zh-CN.md)

A native OpenWrt LuCI application for **multi-source subscription aggregation** and **visual routing rule orchestration**. It caches upstream proxy subscriptions locally, compiles policy groups and routing rules, and publishes versioned configurations for **Mihomo (Clash Meta)**, **Surge**, and **sing-box**.

```text
Upstream Subscriptions ──► Local Node Cache ──► LuCI Rule & Group Editor ──► Immutable Release ──► Client Pull (QR / URL)
   (Manual / Scheduled)    (/etc/hybrid-...)    (Mihomo / Surge / sing-box)   (SHA-256 Verified)    └──► OpenClash Apply
```

This application focuses on configuration compilation and distribution. Runtime traffic graphs and live node switching remain with client dashboards.

## Key Features

- **Read/Write Decoupled Subscription Fusion**: Combine multiple subscription sources into independent profiles, filter nodes by source or region regex templates, and serve client downloads directly from published local files—**client downloads never trigger upstream subscription requests**.
- **Native LuCI Rule Engine & Dependency Graph**: Edit policy groups, ordered routing rules, shared remote/inline rule sets, and Mihomo rematch/sub-rule trees using standard LuCI forms. Inspect group and sub-rule references with an in-browser SVG dependency graph.
- **Explicit Cross-Client Compatibility**: Retain raw Mihomo node fields in the local cache. When exporting to Surge or sing-box, unsupported protocols block the build and unsupported node/policy fields require explicit confirmation before publication—nothing is silently dropped.
- **Immutable Releases & Instant Rollback**: Validate drafts, preview redacted outputs, build immutable releases, publish, or roll back to any previously published release.
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
| **RAM (Client Download)** | **~10–14 MiB** transient (< 30 ms) | Authenticates the token, verifies the SHA-256 digest, and streams the static file. |
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

**OpenWrt 25.12+ (`apk`):**

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
4. **Build & Publish (`Overview`)**: Click **Build & Publish** on the profile card. Review any cross-client compatibility warnings, confirm publication, and use **Download / QR Code** to import the subscription into your clients.
5. **Apply to OpenClash (Optional)**: Open **Release Management** on a published profile to apply the Mihomo output to OpenClash manually, or enable **Auto-Apply to OpenClash on Publish** under **Global Settings**.

## Core Concepts & Details

### Quota & Expiration Queries

Quota parsing supports the standard `Subscription-Userinfo` response header (`upload; download; total; expire`) used by [OpenClash](https://github.com/vernesong/OpenClash/blob/master/luci-app-openclash/luasrc/controller/openclash.lua):

- **Dedicated Quota URL (`quota_url`)**: Write-only endpoint queried first without following redirects or falling back to the main subscription URL.
- **Subscription Header Opt-In (`quota_via_subscription`)**: Disabled by default. When enabled, clicking **Refresh Quota** sends a header-only `GET` request to the subscription URL. Keep this disabled for time-windowed or pull-limited subscriptions.
- **Local Provider Reuse**: Automatically reads local Mihomo `proxy-providers` quota metadata when OpenClash is installed and shares the same subscription URL.

### Region Matching Templates

Under **Global Settings → Region Matching**, built-in templates match flag emojis, Chinese/English names, and word-bounded ISO country codes. You can define per-source regex overrides and run **Preview Region Matches** against cached node names offline to spot unmatched or multi-region nodes before building.

### Access Control & Security

- **Access Modes**: Choose between **LAN + Download Token** (default), **Download Token (All Reachable Networks)**, or **Authenticated LuCI Session Only**.
- **Credential Protection**: State and artifacts live in `/etc/hybrid-subscription` (`0700` directories, `0600` files). Subscription and quota URLs are write-only in the UI, and previews redact server addresses, passwords, UUIDs, and query tokens.
- **Clean Uninstallation**: Switch OpenClash away from any `HybridSubscriptions-*.yaml` profile and run `scripts/uninstall-router.sh`.

## Internationalization (i18n)

- **Standard LuCI Catalogs**: Source strings use English `msgid`s across `htdocs/`, `menu.d/`, `acl.d/`, and Ruby backend modules, paired with `po/templates/hybrid-subscription.pot` and `po/zh_Hans/hybrid-subscription.po`.
- **Extensible Runtime Registry**: `htdocs/luci-static/resources/hybrid-subscription.js` exposes `hs.registerLocale(code, { separator, aliases, exact, patterns })` to translate dynamic backend validation errors and provide fallback translations on direct-script deployments.

## Testing & CI

```sh
sh scripts/test.sh
```

`scripts/test.sh` runs all Ruby unit tests (`test_engine.rb`, `test_backend.rb`, `test_openclash.rb`, `test_converter.rb`, `test_quota.rb`, `test_regions.rb`), JavaScript view/workbench tests (`frontend_test.js`, `workbench_test.js`), gettext `.po`/`.pot` format validation, and shell syntax checks. GitHub Actions runs this suite and builds `.ipk` (OpenWrt 24.10) and `.apk` (OpenWrt 25.12) packages on every push, pull request, and `v*` release tag.

## License

Copyright 2026 Zerlight Wu and contributors. Licensed under the [Apache License 2.0](LICENSE).

LuCI and optional external integrations (such as OpenClash and subconverter) retain their own licenses and are not bundled in this repository.
