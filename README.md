# LuCI Hybrid Subscription Manager

[English](README.md) | [简体中文](README.zh-CN.md)

A native OpenWrt LuCI application featuring **multi-source subscription fusion** and a **GUI rule engine**. Combine subscription sources, compose routing policies, and publish versioned configurations for Mihomo, Surge, and sing-box.

## Highlights

- **Subscription fusion**: Combine multiple sources in one profile, filter nodes by source or custom region patterns, and configure each client's output separately. Published downloads use cached nodes, so downloading a fused subscription never fetches upstream sources.
- **GUI rule engine**: Edit policy groups, ordered routing rules, and shared remote or inline rule sets with native LuCI components. Inspect group dependencies in an interactive graph, and express Mihomo rematch entries, named sub-rules, and recursive logical conditions. Advanced structured fields use JSON editors; cross-client compatibility differences require review before publication.

The application manages configuration and publication. Runtime connection monitoring and node switching remain with client dashboards.

## Capabilities

- Merge any number of supported subscription sources into multiple independent subscription profiles.
- Import Mihomo YAML, Surge configurations, sing-box JSON, and standard proxy node URIs.
- Preserve canonical Mihomo node fields. Other target formats report unsupported options as explicit compatibility warnings and block unsupported protocols rather than silently dropping nodes.
- Configure source selection, node regular-expression filters, policy group hierarchies, per-client group types, ordered routing rules, and remote or inline rule sets. Inspect policy dependencies via an interactive SVG graph inside LuCI.
- Support Mihomo rematch entries, named sub-rules, recursive logical conditions (`AND`, `OR`, `NOT`), inline rule sets, and explicit DNS/geodata/sniffer policies. Features without portable equivalents block incompatible target formats instead of being silently discarded.
- Follow a strict publication lifecycle: save drafts, validate configurations, preview redacted outputs, build immutable releases, review and accept compatibility warnings, publish, or roll back to any previously published release.
- Serve downloads via revocable per-profile tokens (`LAN + Token` or `Token` across reachable networks) or restrict downloads to authenticated LuCI sessions. QR codes are rendered locally using LuCI's `uqr` library.
- Update each subscription source manually or on an independent schedule. Client download requests read only published release artifacts and **never trigger upstream subscription fetches**.
- Import existing OpenClash subscription definitions and node caches. Apply a published Mihomo release to OpenClash manually or enable automatic application for a designated profile, backed by pre-flight core validation and an automatic rollback guard.
- Audit the native parser against a local loopback `subconverter` instance without modifying cached node data.

Only modern Mihomo, Surge, and sing-box formats are targeted. Legacy Clash, SSR, and Quantumult formats are intentionally excluded.

## Installation

Download packages from [GitHub Releases](https://github.com/Zerlight/luci-app-hybrid-subscription/releases). Choose the package matching your OpenWrt series: **24.10 uses `.ipk`**, while **25.12 uses `.apk`**. Install the base application and, optionally, the Simplified Chinese language package from the same release. Runtime dependencies are declared in the package and resolved from your router's configured feeds.

On OpenWrt 24.10, upload the `.ipk` files to the router and install them with `opkg install /tmp/<package>.ipk`. On OpenWrt 25.12, use `apk add --allow-untrusted /tmp/<package>.apk` for these independently built packages. Release packages are not signed by the official OpenWrt feed keys. Download them from this repository's releases and check their hashes against the accompanying `SHA256SUMS` file before installation.

For SDK builds, the `Makefile` follows standard OpenWrt LuCI package conventions. Place the repository inside your OpenWrt LuCI package tree and build it with a matching SDK.

For direct deployment to a configured OpenWrt router during development:

```sh
apk add ruby-json ruby-open3 ruby-fileutils ruby-uri ruby-timeout ruby-ipaddr ruby-socket
./scripts/deploy.sh root@router.example
```

The installer backs up any files it replaces and does not restart OpenClash or alter its active configuration. Once installed, the application appears under **Services → Hybrid Subscription** (**服务 → 混合订阅** in Simplified Chinese). Required packages (`luci-base`, `luci-lib-uqr`, Ruby YAML/Digest libraries, `curl`, and `rpcd`) must be present on the router.

## Getting Started

1. **Add Subscription Sources**: Import sources from OpenClash or create new source entries under **Subscription Sources**. You may leave the subscription URL blank if you intend to import a local subscription file.
2. **Protect Rate-Limited Sources**: Keep time-windowed or rate-limited subscriptions in **Manual Only** update mode. Importing an existing OpenClash source reuses its local cache without contacting the upstream provider.
3. **Configure Profiles & Groups**: Under **Subscription Profiles**, create a profile, select its sources and target formats, and define policy groups and routing rules. Use **Quick Create Profile** to scaffold a basic manual-selection profile.
4. **Validate, Build & Publish**: On the **Overview** page, click **Build & Publish** to validate the draft and generate an immutable release, confirm any cross-client compatibility warnings, and publish. Download links and QR codes become available after publication.
5. **OpenClash Integration**: Applying a release to OpenClash is decoupled from publication by default and may briefly reload proxy connections. Managed OpenClash configurations use the `HybridSubscriptions-<id>.yaml` naming convention so existing profiles remain untouched.

## Daily Workflow

- **Overview**: Monitor source cache status and traffic quota, jump to profile editors, build and publish releases, view download links and QR codes, or open **Release Management** to roll back releases and manage OpenClash integration.
- **Subscription Sources**: Trigger manual cache updates, import local subscription files, configure dedicated quota endpoints, and run `subconverter` compatibility audits.
- **Subscription Profiles**: Select an active profile filter to edit export targets, policy groups, or Mihomo rematch/sub-rule entries. Switching tabs preserves unsaved draft changes on the current page.
- **Routing Rules**: Filter and reorder rules by profile and rule scope (main rules or sub-rules), and manage shared remote or inline rule sets.
- **Global Settings**: Maintain region matching templates, download access controls, OpenClash auto-apply preferences, and the local `subconverter` loopback address. Clicking **Save** writes to the draft configuration; publication always takes place on the **Overview** page.

## Quota & Expiration Queries

Quota parsing follows the `Subscription-Userinfo` HTTP response header convention (`upload; download; total; expire`) used by OpenClash ([reference implementation](https://github.com/vernesong/OpenClash/blob/master/luci-app-openclash/luasrc/controller/openclash.lua)):

- **Dedicated Quota URL**: Each source can configure a write-only dedicated quota endpoint (`quota_url`) that is never echoed back to the browser. Dedicated endpoints take priority, never follow HTTP redirects, and never fall back to the main subscription URL on failure.
- **Subscription Header Opt-In**: Standard subscriptions may explicitly enable **Query Quota via Subscription URL** (`quota_via_subscription`, disabled by default), which sends a header-only `GET` request to the subscription URL when manually refreshing quota. Keep this option disabled for time-windowed or pull-limited subscriptions.
- **Local Provider Cache**: When OpenClash is installed, the backend also reads local Mihomo provider metadata associated with matching subscription URLs.
- **Manual Trigger Only**: Clicking **Refresh Quota** updates only quota metadata without refreshing nodes or invalidating published releases. Page polling, scheduled tasks, and client downloads never issue quota requests.

## Region Matching Templates

Under **Global Settings → Region Matching**, you can add default region templates or define custom regular expressions:

- Default templates match flag emojis, Chinese and English region names, and word-bounded two- or three-letter ISO country codes.
- Per-source override patterns supersede the general regular expression for that specific source.
- **Preview Region Matches** evaluates current cached node names offline without saving the draft or contacting upstream servers, highlighting unmatched nodes and multi-region ambiguities.
- When a policy group selects a **Region Template**, the region pattern is combined (`AND`) with the group's include and exclude regular expressions. Region matching classifies nodes by name and does not guarantee the physical egress IP location.

## Access Control & Storage

The default download access mode is **LAN + Download Token**. You may switch to **Download Token (All Reachable Networks)** or **Authenticated LuCI Session Only**. Specifying a custom **Subscription Base URL** updates generated download links without opening firewall ports or configuring network tunnels.

Configuration state, cached nodes, and published releases are stored under `/etc/hybrid-subscription` with restricted permissions (`0700` directories, `0600` files). Source URLs are write-only in the UI, and configuration previews redact server addresses, credentials, and private query tokens.

Unpublishing a profile revokes its download token and disables external downloads while retaining release history and the active OpenClash configuration. To uninstall from a router, switch OpenClash to a non-managed configuration and run `scripts/uninstall-router.sh`.

## Internationalization (i18n)

The application follows OpenWrt LuCI internationalization standards while providing a runtime locale registry for direct deployments and backend diagnostics:

- **Canonical Source Strings**: All UI views (`htdocs/luci-static/resources/`), menu definitions (`root/usr/share/luci/menu.d/`), ACL descriptions (`root/usr/share/rpcd/acl.d/`), and Ruby backend modules (`root/usr/share/hybrid-subscription/`) use formal English as the default `msgid`.
- **Standard PO Catalogs**: Translation templates live in `po/templates/hybrid-subscription.pot`, with Simplified Chinese translations in `po/zh_Hans/hybrid-subscription.po`. OpenWrt SDK builds (`include ../../luci.mk`) automatically compile `.po` files into `.lmo` binary catalogs, and `scripts/install-router.sh` compiles `.lmo` catalogs on the router whenever `po2lmo` is available.
- **Extensible Runtime Locale Registry**: `htdocs/luci-static/resources/hybrid-subscription.js` exposes `hs.registerLocale(code, { separator, aliases, exact, patterns })`. This provides automatic fallback when `.lmo` files are not pre-compiled and translates parameterized backend validation, build, and runtime messages. To add another language, add `po/<lang>/hybrid-subscription.po` and register the locale in `hybrid-subscription.js`.

## Testing

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

All test suites use synthetic credentials and temporary directories without making external network requests or modifying system configurations.

## Continuous Integration & Releases

GitHub Actions runs the Ruby and JavaScript tests, translation checks, and OpenWrt SDK package builds for OpenWrt 24.10 and 25.12 on pushes and pull requests. Successful builds provide downloadable workflow artifacts containing the application and language packages.

Pushing a version tag in the form `v<major>.<minor>.<patch>` runs the same checks and creates a GitHub Release with `.ipk` and `.apk` installation packages and `SHA256SUMS`. Package builds validate SDK packaging; they do not replace testing on a router running the matching OpenWrt version.

## License

Copyright 2026 Zerlight Wu and contributors. Licensed under the [Apache License 2.0](LICENSE).

LuCI and separately installed integrations, including OpenClash and subconverter, retain their own licenses. This repository does not bundle their source code or binaries.
