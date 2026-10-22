# Compatibility Version Baselines
Last reviewed: **2026-10-22** (client subscription updates; protocol mappings remain at their recorded checkpoints).

This document records the protocol specifications, client release checkpoints, and upstream commits referenced by the subscription conversion engine. Recording exact revisions here provides a stable baseline when reviewing future upstream changes. Supported conversion behavior is defined by the [implementation contract](implementation-contract.md#shadowrocket-mapping-boundary) and [conversion engine](../root/usr/share/hybrid-subscription/engine.rb).

These revisions serve as **reference baselines for field mapping and documentation** rather than runtime dependency locks or mandatory client versions. Because this application compiles configuration files rather than implementing proxy protocols on the wire, protocol specifications, third-party converters, and local export tests each cover only part of the picture and do not by themselves guarantee end-to-end client connectivity.

## Protocol Revisions

The table below lists every protocol in the canonical node model alongside its reference specification and current mapping scope. Referencing a specification does not imply that every cipher, transport, or extension in that document is supported on every export target.

| Protocol | Reference Specification / Revision | Current Mapping Scope |
| :--- | :--- | :--- |
| AnyTLS | **v2** (with v1 negotiation fallback) per the [AnyTLS protocol specification](https://github.com/anytls/anytls-go/blob/fd6167acd6d73b9fa3e607659951847fbc9e6c50/docs/protocol.md). | Protocol version negotiation happens between client and server (`anytls-go v0.0.x` tracks the Go implementation rather than the wire protocol). Session reuse and idle-session fields on Shadowrocket require pre-publish review. |
| Trojan | Unversioned specification pinned at commit [`3e7bb9a`](https://github.com/trojan-gfw/trojan/blob/3e7bb9aecdc694f9bcae8d646fae395f773d60f8/docs/protocol.md). | Covers standard password/TLS and supported transport mappings; Trojan-derived custom extensions are not included. |
| Shadowsocks | **AEAD 2017 (SIP004/SIP007)** and **AEAD 2022 (SIP022)** specifications: [AEAD](https://github.com/shadowsocks/shadowsocks-org/blob/34598d65054dad975d330ff9d7317b0d41cf1efd/docs/doc/aead.md), [SIP022](https://github.com/shadowsocks/shadowsocks-org/blob/34598d65054dad975d330ff9d7317b0d41cf1efd/docs/doc/sip022.md). | AEAD 2017 and SIP022 are tracked separately rather than grouped under a generic version label. Cipher and plugin support still depends on each target client. |
| VMess | Wire version **1** per the [VMess specification](https://github.com/v2fly/v2fly-github-io/blob/094c084eef448fc573f2228acc847911ca78ae11/docs/en_US/developer/protocols/vmess.md) (AEAD is an authentication mechanism rather than a new wire version). | Surge export and native Shadowrocket node import require `alterId=0`. Shadowrocket YAML export preserves existing `alterId` values without guaranteeing legacy non-AEAD support on specific client builds. |
| VLESS | Wire version **0** per the [Xray implementation](https://github.com/XTLS/Xray-core/blob/92ccc939aaf4f8965f369cf0b142e005aeaa11d5/proxy/vless/encoding/encoding.go#L19). | Surge export is blocked. Supports UUID, flow, TLS, and mapped Reality fields; newer VLESS encryption extensions are not covered. |
| Hysteria 2 | **Hysteria 2** (used from implementation **2.0.0**, protocol **v4** internally) per the [Hysteria 2 specification](https://github.com/apernet/hysteria/blob/ca8fbd874fd6ca82413948de6dc5924405e103e1/PROTOCOL.md). | Covers `hysteria2` only (Hysteria v1 is excluded). Obfuscation and transport parameters remain target-specific. |
| TUIC | **v5 (`0x05`)** per the [TUIC specification](https://github.com/tuic-protocol/tuic/blob/8e118f242f24a17a9f487dc344cc50d7e63e557e/SPEC.md), tracked separately from legacy v4/token nodes. | sing-box rejects token-based v4 nodes. Surge distinguishes `tuic` from `tuic-v5`. Shadowrocket defaults `version: 5` only for UUID/password nodes without an explicit version and never upgrades token nodes to v5. |

Compatibility also depends on transport and security settings, including TLS, Reality, WebSocket, gRPC, HTTP/2, plugins, and client fingerprints. Unsupported combinations block export, while known behavioral differences require confirmation in a dedicated compatible profile.

## Client and Configuration Baselines

The releases below mark the documentation and source checkpoints reviewed for each target rather than universal minimum version requirements, except where an upstream manual explicitly states a feature minimum.

| Client / Target | Reference Checkpoint | Scope & Verification Notes |
| :--- | :--- | :--- |
| Mihomo (standard core) | **v1.19.32**, commit [`88dcbf7f1614a67c3b36b848ee3592dfa92ada36`](https://github.com/MetaCubeX/mihomo/tree/88dcbf7f1614a67c3b36b848ee3592dfa92ada36) ([release](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.32)). | Core source reference; the Meta-Docs revision below is pinned independently. |
| Mihomo (Smart variant) | Variant flag (`mihomo_core=smart`); exact build and commit not yet recorded. | Runtime verification requires the exact distribution, version, and commit of the Smart build. |
| sing-box | **v1.12.0**, commit [`2dcb86941f5db01bbe296acae555a3b1f38c0441`](https://github.com/SagerNet/sing-box/tree/2dcb86941f5db01bbe296acae555a3b1f38c0441) ([release](https://github.com/SagerNet/sing-box/releases/tag/v1.12.0)). | The [AnyTLS outbound documentation](https://github.com/SagerNet/sing-box/blob/2dcb86941f5db01bbe296acae555a3b1f38c0441/docs/configuration/outbound/anytls.md) notes `1.12.0` as the introducing release. |
| Surge Mac / iOS | **Mac 6.4.3 / iOS 5.17.0** (for AnyTLS). | Stated in the [official Surge AnyTLS manual](https://manual.nssurge.com/policies/anytls.html) for AnyTLS v2 support. `surge_version=modern` selects modern output syntax rather than probing the installed client version. |
| Shadowrocket | **2.2.80** (with historical milestones below). | Based on public release notes and the pinned Sub-Store mapping reference below; on-device YAML import, rule evaluation, and live connectivity remain untested. |

Because the Surge manual and Shadowrocket release channel are publisher-updated pages rather than immutable Git commits, both the version numbers and review date are recorded alongside their links.

## Client Subscription Update Baselines

The checkpoints below cover full-profile subscription updates (distinct from node health checks, remote rule-set refreshes, and upstream source polling). Review date: **2026-10-22**. The application exposes a **1–720 hour** interval range (default **24 hours**) as an application validation rule rather than a uniform client limit.

| Client | Reference Checkpoint | Scheduling & Failure Behavior |
| :--- | :--- | :--- |
| Surge Mac / iOS | [Official managed-profile manual](https://manual.nssurge.com/profile/managed-profile.html), reviewed 2026-10-22. | `#!MANAGED-CONFIG` takes an interval in seconds (upstream default `86400`) without a documented numeric minimum or maximum. Updates run only while the main app is active, treating the interval as an eligibility threshold. Exported configurations set `strict=false` so failed updates do not block use of the last saved profile. |
| Clash Verge Rev | **v2.5.8**, commit [`3fee9e8747c88580b67d28eff892ffc3418c07d4`](https://github.com/clash-verge-rev/clash-verge-rev/tree/3fee9e8747c88580b67d28eff892ffc3418c07d4). | [`Profile-Update-Interval`](https://github.com/clash-verge-rev/clash-verge-rev/blob/3fee9e8747c88580b67d28eff892ffc3418c07d4/src-tauri/src/config/prfitem.rs) is parsed as integer hours, though any existing local interval on the profile takes precedence. The UI suggests 24+ hours without enforcing a hard minimum. The [timer](https://github.com/clash-verge-rev/clash-verge-rev/blob/3fee9e8747c88580b67d28eff892ffc3418c07d4/src-tauri/src/core/timer.rs) keeps periodic retry scheduling active across failures while retaining the previous configuration. |
| Clash Meta Android | **v2.11.36**, commit [`043a6072225405b285a73e3d7b7e53431ccfc04c`](https://github.com/MetaCubeX/ClashMetaForAndroid/tree/043a6072225405b285a73e3d7b7e53431ccfc04c). | [`ProfileProcessor.kt`](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/043a6072225405b285a73e3d7b7e53431ccfc04c/service/src/main/java/com/github/kr328/clash/service/ProfileProcessor.kt) applies `Profile-Update-Interval` (integer hours) only on initial import when no local interval is set (`0` disables updates; non-zero values clamp to at least 15 minutes). [`ProfileWorker.kt`](https://github.com/MetaCubeX/ClashMetaForAndroid/blob/043a6072225405b285a73e3d7b7e53431ccfc04c/service/src/main/java/com/github/kr328/clash/service/ProfileWorker.kt) preserves the prior configuration on failure, but because each run is scheduled as a one-shot job, a failed update does not re-arm the next timer until a manual update succeeds or scheduling is reinitialized. |
| Shadowrocket | **2.2.92** ([App Store](https://apps.apple.com/us/app/shadowrocket/id932747118)); **2.1.42** ([release note](https://t.me/ShadowrocketNews/297)). | Release notes document background updates for node subscriptions, but do not specify unattended scheduling or `Profile-Update-Interval` behavior for full Clash YAML configurations. No auto-update declaration is emitted for `shadowrocket.yaml`; use the app's native configuration update controls. |

Surge managed downloads require a configured base URL and token-based access. The `#!MANAGED-CONFIG` line is prepended at download time after verifying the stored artifact's SHA-256 digest and remains present on subsequent updates. A LAN-only URL cannot serve updates while away from home, and cached profiles remain subject to upstream credential or external rule-set expiration.

Unattended background refresh, extended offline recovery, sleep/wake transitions, and app restart behavior have not been verified on live devices; the table above reflects upstream source and documentation review.

## Upstream Reference Pins

| Project | Pinned Revision | Role in This Repository |
| :--- | :--- | :--- |
| Sub-Store | **v2.42.6**, commit [`1f0318bc6feb46fbe204836f32ca7acab37ea67e`](https://github.com/sub-store-org/Sub-Store/blob/1f0318bc6feb46fbe204836f32ca7acab37ea67e/backend/package.json). | Reference for [Shadowrocket node mappings](https://github.com/sub-store-org/Sub-Store/blob/1f0318bc6feb46fbe204836f32ca7acab37ea67e/backend/src/core/proxy-utils/producers/shadowrocket.js) and [producer helpers](https://github.com/sub-store-org/Sub-Store/blob/1f0318bc6feb46fbe204836f32ca7acab37ea67e/backend/src/core/proxy-utils/producers/utils.js). The referenced producer converts node entries; policy groups and routing rules are compiled by this application. |
| MetaCubeX Meta-Docs | Commit [`c47fd7212afc3f0e6afe9c7cb18591ba55e5e79b`](https://github.com/MetaCubeX/Meta-Docs/tree/c47fd7212afc3f0e6afe9c7cb18591ba55e5e79b/docs/config/proxies). | Reference for canonical Mihomo proxy fields (e.g., [AnyTLS idle-session defaults and `client-metadata` changes in v1.19.30](https://github.com/MetaCubeX/Meta-Docs/blob/c47fd7212afc3f0e6afe9c7cb18591ba55e5e79b/docs/config/proxies/anytls.md)). |
| clash-skk | Commit [`cdb419f7d446c55b715261a8f5ff4b80f84fccbd`](https://github.com/Paxxs/clash-skk/blob/cdb419f7d446c55b715261a8f5ff4b80f84fccbd/README.md). | Community example of Shadowrocket HTTP `rule-providers` using classical YAML `payload` lists and `RULE-SET` references. |

## Shadowrocket Release Evidence

Protocol support, Clash YAML parsing fixes, and session-management updates appeared across separate Shadowrocket releases:

| Version | Documented Change | Source |
| :--- | :--- | :--- |
| **2.1.95** | Added Clash YAML configuration import. | [ShadowrocketNews #362](https://t.me/ShadowrocketNews/362) |
| **2.1.96** | Fixed Clash `proxy-groups` handling. | [ShadowrocketNews #363](https://t.me/ShadowrocketNews/363) |
| **2.2.33 beta / 2.2.34 beta** | Fixed Clash DNS `fake-ip-filter` and text `rule-set` parsing (beta release notes). | [ShadowrocketNews #420](https://t.me/ShadowrocketNews/420), [#427](https://t.me/ShadowrocketNews/427) |
| **2.2.64** | Added AnyTLS protocol support. | [ShadowrocketNews #937](https://t.me/ShadowrocketNews/937) |
| **2.2.65** | Fixed AnyTLS parsing in Clash YAML configs. | [ShadowrocketNews #960](https://t.me/ShadowrocketNews/960) |
| **2.2.70 beta (build 2776)** | Additional Clash YAML AnyTLS parser adjustments. | [ShadowrocketNews #1103](https://t.me/ShadowrocketNews/1103) |
| **2.2.78** | Updated AnyTLS session pooling and idle cleanup. | [ShadowrocketNews #1321](https://t.me/ShadowrocketNews/1321) |
| **2.2.80** | Fixed AnyTLS pool mode and idle-session management. | [ShadowrocketNews #1342](https://t.me/ShadowrocketNews/1342) |

These release notes do not imply support for Mihomo-specific `rematch`, sub-rules, `smart` groups, native Mihomo DNS policies, or every advanced TLS/idle-session parameter. Unverified advanced node fields are preserved with pre-publish warnings rather than dropping nodes, and remote rule sets require a dedicated classical YAML URL ([details](../README.md#shadowrocket-export)).

## Verification Status

- **Specification & reference review:** Covered by the pinned protocol docs, upstream converters, and release notes above.
- **Automated test coverage:** Exercised by [Shadowrocket mapping tests](../tests/test_shadowrocket.rb), [conversion matrix tests](../tests/test_conversion_matrix.rb), [compatibility planning tests](../tests/test_compatibility.rb), and [backend publication tests](../tests/test_backend.rb).
- **Pending real-client validation:** On-device Shadowrocket configuration import, subscription refresh, rule matching, and live proxy connectivity have not yet been tested. Version-specific runtime results for the other client checkpoints and legacy TUIC token nodes are not recorded here. When recording real-device test results in the future, include the client version and build number, OS version, server implementation and version, config format, test date, and observed TCP/UDP and routing behavior (without sensitive URLs or credentials).

## Updating a Baseline

1. Compare the new upstream commit, release note, or manual page against the current pin for field renames, changed defaults, removed options, transport combinations, and routing/DNS behavior.
2. Check how the change affects node imports, exporters, compatibility warnings, and saved conversion strategies without silently dropping nodes or disabling existing rules.
3. Update or add regression tests in `tests/` and record any untested real-client behavior explicitly.
4. Update the version pin, review date, and history table below together, recording both the previous and new revisions. Upstream version reviews are maintained manually, separately from source-profile change reminders.

## Baseline History

| Review Date | Summary | Verification |
| :--- | :--- | :--- |
| 2026-10-19 | Recorded initial baselines for all seven canonical protocols, four client targets, and Shadowrocket reference mappings. | Upstream source review and existing local regression coverage. |
| 2026-10-22 | Added complete-profile update baselines for Surge, Clash Verge Rev 2.5.8, Clash Meta Android 2.11.36, and Shadowrocket 2.2.92; existing protocol and conversion pins are unchanged. | Official documentation and pinned scheduling-source review; client runtime behavior remains untested. |
