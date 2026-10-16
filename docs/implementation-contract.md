# Architecture and API contract

The application manages subscription configuration and publication on OpenWrt. Its interface uses native LuCI form, JSONMap, GridSection, ui, rpc, and uqr components, with a browser-native SVG relationship graph. Runtime node switching and latency testing remain the responsibility of proxy dashboards.

Supported output formats: Mihomo, Surge, and sing-box. Multiple arbitrary sources merge into multiple profiles. Full group and remote-rule-set management. Target-specific output with compatibility warnings, explicit loss acceptance before publish. Draft -> validate/preview -> immutable release -> publish -> rollback. Source updates per-source manual or scheduled. Downloads never fetch upstream. Access configurable: LAN+token default, token from any reachable network, or LuCI-session-only. Do not open firewall ports or install tunnels. Optional OpenClash integration, manual apply button and configurable auto-apply checkbox, default false.

`contract.json` is shape/examples, not production seed (do not ship fake subscriptions). IDs ASCII `[a-z][a-z0-9_-]{0,47}`, globally unique within each collection. URLs/secrets only in private state. Browser config source URL is blank plus `has_url`; blank save preserves existing secret; new sources require URL or imported cache. `sources` list is global; each profile selects source IDs. Groups/rules belong to profile. Rule sets are shared. Members are group IDs, rematch IDs, or DIRECT/REJECT; source/filter expands concrete nodes. Name collisions, invalid regex, missing references, cycles, empty groups, target incompatibilities are validation errors. No silently discarded unsupported nodes or rule forms. Rules are ordered by array position. Rule types include DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, IP-CIDR, IP-CIDR6, GEOIP, GEOSITE, RULE-SET, DST-PORT, NETWORK, REMATCH-NAME and AND/OR/NOT logical conditions (with explicit per-target validation); final policy lives on profile. Client-specific unsupported conditions block that target until fixed. smart requires profile mihomo_core=smart; models and collection off. Surge smart excludes group/policy members (error rather than silent omission). sing-box URLTest/selector explicit.

Backend state under /etc/hybrid-subscription (0700), artifacts/secrets0600; worker runtime under /tmp/hybrid-subscription. Stable filenames are fixed/validated, no user filesystem paths. Snapshot/source node metadata returned without passwords. Cache is independent of published release. Private releases contain source config used, outputs and warnings/digest. Each release self-contained. Do not embed router controller secret, listeners or API password in downloads. Strong random per-profile download token; returned only through explicitly authorized read/UI action; download endpoint handles GET/HEAD and only immutable last-published artifact. A publication does not rotate token. Explicit rotation revokes old URLs.

Ruby backend can reuse installed YAML but needs standard ruby-json package, declare dependency. No bespoke JSON parser/encoder. All subprocesses argv arrays; no interpolated shell execution. Source URL schemes https/http only, bounded fetch, timeout, validate before atomically replacing cached file. Include sanitized status errors, source timestamps/counts and quota when upstream Subscription-Userinfo available; absence is unknown.

RPC object `luci.hybrid_subscription` with methods:
- status() => {ok:true,config_version, sources:[{id,name,cached_at,attempt_at,nodes,regions,quota,error}],profiles:[{id,name,published_release,formats,generated_at}],releases:[{id,profile,created_at,formats}],jobs:[{id,state,kind,error}],openclash:{installed,active_config,version,integration},converter:{available,version}}
- get_config() => {ok:true,config,version}; source URLs sanitized as above.
- save_config({config:JSON-string,version:string}) => {ok:true,version}; optimistic concurrency; global full config.
- refresh({source:string}) => {ok:true,job:string}; asynchronous
- import_source({source:string,content:string}) => {ok:true,...}; text upload via RPC bounded2MiB
- import_openclash() => {ok:true,...}; import existing source definitions/caches only; no policy/service changes
- validate({profile:string}) => {ok:true,errors:[],warnings:[{code,message,target}],summary}; no refresh
- compatibility({profile:string}) => {ok:true,profile,targets:[{format,compatible,errors,warnings,issues,summary}],choices,version}; checks all three targets using the saved draft and cached nodes.
- compatibility_plan({profile:string,format:string,id:string,name:string,resolutions:JSON-string}) => {ok:true,profile,format,changes:[{code,message}],errors,warnings,ready,plan_token,version}; read-only preview of an independent profile.
- compatibility_create({profile:string,format:string,id:string,name:string,resolutions:JSON-string,version:string,plan_token:string,accepted_changes:[string]}) => {ok:true,...plan,created:true}; creates a saved draft only after revalidating the plan and confirming every change.
- preview({profile:string,format:string}) => {ok:true,content:redacted-string,warnings:[],errors:[]}; bounded display, export content never secrets in preview
- build({profile:string}) => {ok:true,job:string}; asynchronous immutable candidate; may have warnings awaiting publish
- publish({release:string,accepted_warnings:[string]}) => {ok:true,...}; reject omitted loss codes. Auto-apply only if enabled/selected.
- rollback({release:string}) => {ok:true,...}; update published pointer, optional autoapply checked.
- download_info({profile:string}) => {ok:true,token:string,formats:[],published_release,access_mode,base_url}; protected ACL
- rotate_token({profile:string}) => {ok:true,...}
- apply_openclash({profile:string}) => {ok:true,job:string}; selected published mihomo, validate and backup; managed profile file name HybridSubscriptions-<id>.yaml; existing unmanaged configurations are preserved.
- job_status({job:string}) => {ok:true,job:{...}}
Errors consistently `{ok:false,error:"sanitized readable"}`. Frontend handles missing methods/errors, shows compatibility errors; never reports job dispatch as success before completion. Use refresh polling for jobs/status only.

Engine interface:
`HybridSubscription::Engine.new(config, caches)` where caches sourceID -> {"nodes"=>Mihomo raw node Hash array,"meta"=>Hash}; methods `validate(profile_id)` -> {"errors"=>[],"warnings"=>[{"code","message","target"}],"summary"=>...}, `render(profile_id,format,redact:false)` -> {"content"=>string,"warnings"=>array,"errors"=>array}; `Engine.import_nodes(content,format='auto')` -> raw Mihomo node array or raises clear Error. Cache canonical raw Mihomo preserves fields. Engine reads no live router state, no subprocess/network except explicit converter adapter implemented separately. Use JSON/YAML library safely. Tests standard minitest or assert script runnable Ruby2.6 local /3.4 router.

The LuCI frontend communicates through RPC. The Ruby backend implements state storage, compilation, publication, CGI downloads, and integration adapters.

## Structured Mihomo policy extensions

`rematches` entries contain `id`, `profile`, `name`, `target_sub_rule` (sub-rule ID), and optional `rematch_name`. `sub_rules` entries contain `id`, `profile`, `name`, and `final_policy`. Rules can carry `sub_rule` (empty = main rule list); their relative array order is retained within each rule table. Logical rule `conditions` are recursive arrays of `{type,value,no_resolve?}` or `{type,conditions}` objects. Policies and group members reference bare IDs; name and ID collisions are rejected. The editor displays these as ordinary LuCI tables and includes their references in the dependency graph.

Rule sets support `source_type: remote|inline`. `inline_rules` is multiline, policy-free rule text. Inline sets are embedded in generated artifacts: Mihomo inline providers, Surge native conditions, or sing-box inline rule sets. Logical `AND`/`OR`/`NOT` conditions compile recursively to each target, provided all leaves are representable. Unsupported inline leaves still block that target. Exported files do not depend on private paths on the router. `mihomo_proxy` optionally selects the provider-download policy. Group options include `default_member`, `empty_fallback`, and `lazy`; models/training remain disabled for Smart.

Profiles may contain `mihomo_dns` and `mihomo_policy` objects for explicitly allowed native DNS/geodata/sniffer settings. Runtime listener/controller/authentication/TUN/interface fields are excluded. The managed OpenClash hook keeps its generated DNS listening address while applying exported DNS policy. Native features without an equivalent target representation block that target instead of being silently dropped. Users can create separate target profiles with different policies.

When an OpenClash core is installed, building Mihomo output invokes isolated core syntax validation before creating a candidate release. This validation reuses existing geodata and rule caches without fetching subscription sources. Failed validation leaves published downloads and live routing unchanged.

## Subscription conversion and independent compatibility profiles

Source imports accept Mihomo proxy arrays, Surge `[Proxy]` definitions, sing-box proxy outbounds, and supported URI subscriptions. The cache contains nodes only. Source policies, route tables, DNS, API credentials and listeners are not imported; generated routing comes from the application's own saved profile. An invalid node or an unknown Surge/sing-box node option rejects the complete import before cache replacement. Unknown Mihomo fields remain in the raw cache and receive explicit loss warnings on targets without a mapping.

Imports preserve target defaults explicitly when they differ from the canonical format. For example, sing-box's omitted `network` permits TCP and UDP, while Mihomo's omitted `udp` disables UDP for TCP-based protocols; imported sing-box nodes therefore carry an explicit `udp` flag. Surge Shadowsocks requires `udp-relay=true`, whereas the other supported Surge protocols provide UDP automatically. The parser rejects duplicate Surge options, mutually exclusive Hysteria2 obfuscators, and legacy VMess instead of inventing an AEAD conversion. These mappings follow the [Mihomo common fields](https://github.com/MetaCubeX/Meta-Docs/blob/main/docs/config/proxies/index.en.md), [sing-box network fields](https://sing-box.sagernet.org/configuration/outbound/shadowsocks/), [Surge UDP relay](https://manual.nssurge.com/policies/udp.html), and [Surge VMess](https://manual.nssurge.com/policies/vmess.html) documentation.

The Compatibility LuCI view uses `form.JSONMap`, `NamedSection`, standard form tabs/options, `ui.showModal`, and native tables. It reports every output target, including unselected formats. Errors prevent target generation; warnings remain subject to explicit acceptance on publication. Checks never refresh upstream sources or expose raw node credentials.

The wizard's `resolutions` object accepts:

- `group_modes`: a map from original group IDs to `manual`, `url-test`, or `fallback`. This changes only the target-specific group type in the copy: Mihomo/Surge use `select`, `url-test`, or `fallback`; sing-box uses `selector` or `urltest` and rejects `fallback`. The map is allowed for Mihomo copies too, including replacing Smart with manual selection when using the standard core. Existing candidate order, source expansion, filters, and rule references are retained.
- `rematches`: a map from original rematch IDs to either a fixed existing original group ID/`DIRECT`/`REJECT`, or `{mode:"manual"|"url-test",members:[originalGroupID|"DIRECT"|"REJECT"]}`. The object creates a replacement group with the rematch's name and an explicit, nonempty, unique candidate list in the submitted order. These replacements are for non-Mihomo copies; no candidate is inferred from conditional sub-rule paths. sing-box still rejects `REJECT` as an outbound group member. Replacements that introduce dependency cycles remain blocked.
- `abandon_sub_rules`: explicitly remove named sub-rules and their scoped rules from the copy.
- `omit_dns`: explicitly remove `mihomo_dns`, using the generated target system/local DNS defaults.
- `omit_mihomo_policy`: explicitly remove native Mihomo runtime/geodata policy from the copy.
- `disable_rules`: original enabled rule IDs to disable only in the copy.

No resolution is automatic. Unresolved unsupported nodes, group constraints, rules, and missing target-specific rule-set URLs keep `ready:false`. Changing routing semantics must appear in `changes` and be accepted individually. Supported logical rules and inline rule sets convert automatically without being removed.

Changing a group's selection mode does not convert matching predicates, remove routing rules, or remove sub-rule scopes. Replacing a rematch entry stops its secondary matching; abandoning its sub-rules remains a separate decision, with each removed scope and rule included in the confirmation plan. `manual` means the user chooses among this group's candidates; a candidate that is itself an automatic group retains that behavior. `url-test` retains native latency-based selection, and Surge `fallback` uses declared member priority and native availability tests. None of these modes preserves Smart history, per-destination rematch decisions, or the original DNS policy.

The client implementations also differ operationally. sing-box selectors require controls backed by the Clash API; the exporter does not create a controller listener, and an uncontrolled selector uses the first candidate initially. Modern Surge ignores group-level `url=` and uses its native test URL settings, so explicitly configured group URLs produce a compatibility warning for automatic testing groups. Surge's test interval is a result freshness interval checked on use, not a promise of a fixed test schedule. These boundaries follow the [Surge group overview](https://manual.nssurge.com/policy-groups/overview.html), [Surge URL-test](https://manual.nssurge.com/policy-groups/url-test.html), [Surge fallback](https://manual.nssurge.com/policy-groups/fallback.html), [sing-box selector](https://sing-box.sagernet.org/configuration/outbound/selector/), and [sing-box URLTest](https://sing-box.sagernet.org/configuration/outbound/urltest/) documentation.

An independent copy selects one target format and receives new IDs for its profile-scoped groups, rematches, sub-rules and rules; internal references are remapped. Sources and cached nodes remain shared. Rule sets remain shared unless a profile-local provider download policy requires a copied rule set. The original profile and its output formats are unchanged. Creating a copy does not publish it, issue a download token, apply OpenClash, or rewrite an existing release.

Creation checks the saved configuration version, regenerates the plan under the state lock, verifies its token against current configuration and cached node contents, requires every change code exactly once, and refuses remaining errors. Any edit or cache update that changes the plan requires a fresh preview. The normal build/publish process still applies to the new draft, including separate acceptance of field-loss warnings.

## Reusable regions and independent quota status

`regions` is a global list of `{id,name,pattern,source_patterns:{sourceID:pattern}}`; omitted legacy lists backfill to `[]`. Patterns must be nonempty, bounded and not match an empty name. `group.region` optionally references a region. Matching uses original source node names; source overrides replace only the region pattern, and existing group filters/exclusions still apply. Empty `group.region` preserves legacy rendering. Generated outputs contain only expanded nodes; regex dialects are evaluated by the backend rather than copied to client filters.

`source.quota_url` is write-only like `url`, with `has_quota_url` for UI state. An empty value preserves the saved address; `clear_quota_url:true` explicitly clears it. `quota_max_age` determines staleness (seconds, 60..31536000), never a polling schedule. Quota metadata has its own optimistic generation and cannot overwrite node cache updates.

- `region_defaults()` returns `{regions:[...]}`.
- `preview_regions({config:optionalJSON,sources:optionalIDs})` returns `{regions:[{id,name}],sources:[{id,name,total,nodes:[{name,regions:[ids]}],counts,unmatched,ambiguous}]}` from existing caches only.
- `refresh_quota({source})` returns an asynchronous job. It uses an independent HTTP(S) endpoint first, or an explicitly opted-in subscription response header when no independent URL is configured. Local provider state can also supply cached quota information. A failed independent query never falls back to the subscription URL. Identical configured subscription URLs are rejected as independent quota endpoints. No redirects are followed.
- `status.sources[].quota_status` has `state`, `origin`, `updated_at`, `attempt_at`, `stale`, `available`, `can_refresh`, `query_mode`, `error`. A missing value is not zero. Failed queries retain previous values; fresh local cache may supersede older persisted state.

The overview is the publish/download workbench. Global settings contain no publishing controls. Editor tabs and filters only change visible rows; the full draft collection and rule order survive parsing and saving. Raw identifiers remain editable in native modal forms, while tables display names.

## Internationalization (i18n)

- **Default English `msgid`**: All frontend view modules (`htdocs/luci-static/resources/`), menu definitions (`root/usr/share/luci/menu.d/`), ACL descriptions (`root/usr/share/rpcd/acl.d/`), and Ruby backend modules (`root/usr/share/hybrid-subscription/`) use English as the canonical source language.
- **OpenWrt LuCI PO/POT Standard**: Translation templates are maintained in `po/templates/hybrid-subscription.pot` and Simplified Chinese translations in `po/zh_Hans/hybrid-subscription.po`.
- **Extensible Runtime Locale Registry**: `htdocs/luci-static/resources/hybrid-subscription.js` provides `registerLocale(code, { separator, aliases, exact, patterns })`, `t(msgid)`, and `translateMessage(message)` to support additional languages, direct router deployments without pre-compiled `.lmo` files, and client-side localization of parameterized backend validation/error messages.

## Resource Footprint and Router Hardware Targets

- **On-Demand Execution Model**: The frontend renders natively in the browser (`form`, `ui`, `uqr`, and SVG dependency graph), and the backend runs as short-lived RPCD/CGI workers without a persistent Ruby or Node.js web daemon. The scheduler (`/etc/init.d/hybrid-subscription`) is a minimal POSIX `/bin/sh` loop (`sleep 60`) with `< 1 MiB` resident memory and `0%` idle CPU overhead.
- **Storage Footprint**: `luci-app-hybrid-subscription` and `luci-i18n-hybrid-subscription-zh-cn` occupy `~350 KiB` installed (`~5–6.5 MiB` total including `ruby` and stdlib packages if not already present on the firmware). Persistent state under `/etc/hybrid-subscription` requires `~50–300 KiB` per cached source and `~100–800 KiB` per published release.
- **Transient Worker Memory & CPU**:
  - Client artifact download: `~10–14 MiB` RSS for `< 30 ms`.
  - Three-format compilation (`mihomo`, `surge`, `singbox`): `~16–28 MiB` peak RSS for 100–300 nodes (`~0.1–0.4 s` on ARM Cortex-A53, `~12.5 ms` on desktop x86_64/ARM64) and `~35–65 MiB` peak RSS for 1,000–4,000 nodes (`~0.5–1.5 s` on dual-core ARM, `~90 ms` on desktop x86_64/ARM64).
  - Isolated OpenClash syntax verification (`clash_meta -t`): `+50–120 MiB` transient RSS when OpenClash is installed on the router.
- **Hardware Recommendations**:
  - **Standalone Subscription Hub** (no local OpenClash): Minimum `128 MiB RAM` and `16 MiB` free flash (`256 MiB+ RAM` and `32 MiB+` flash recommended). Keep cached nodes under `~500` on `128 MiB` devices.
  - **Co-Deployed with OpenClash**: Minimum `256 MiB RAM` with ZRAM/Swap and `"geodata-loader": "memconservative"` (`512 MiB+ RAM` and `64 MiB+` flash recommended on ARM64/x86_64).
