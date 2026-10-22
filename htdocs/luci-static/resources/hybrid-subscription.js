'use strict';
'require baseclass';
'require form';
'require rpc';
'require ui';
'require poll';
'require uqr';

if (typeof String.prototype.format !== 'function') {
	String.prototype.format = function() {
		const args = arguments;
		let index = 0;
		return this.replace(/%([%sd])/g, function(match, specifier) {
			if (specifier === '%') return '%';
			return index < args.length ? String(args[index++]) : match;
		});
	};
}

const nativeTr = typeof _ === 'function' ? _ : function(value) { return value; };
const locales = {
	'en': { separator: '; ', exact: {}, patterns: [] }
};
const localeAliases = {
	'zh': 'zh-cn', 'zh-cn': 'zh-cn', 'zh_cn': 'zh-cn', 'zh-hans': 'zh-cn', 'zh_hans': 'zh-cn', 'zh-sg': 'zh-cn',
	'en': 'en', 'en-us': 'en', 'en_us': 'en', 'en-gb': 'en', 'en_gb': 'en'
};
let activeLocale = null;

function normalizeLocale(code) {
	if (!code || typeof code !== 'string') return 'en';
	const key = code.trim().toLowerCase();
	if (localeAliases[key]) return localeAliases[key];
	const hyphenated = key.replace(/_/g, '-');
	if (localeAliases[hyphenated]) return localeAliases[hyphenated];
	if (locales[hyphenated]) return hyphenated;
	const prefix = hyphenated.split('-')[0];
	return localeAliases[prefix] || (locales[prefix] ? prefix : hyphenated);
}

function registerLocale(code, spec) {
	const key = normalizeLocale(code);
	const current = locales[key] || { separator: '; ', exact: {}, patterns: [] };
	if (spec && spec.separator) current.separator = spec.separator;
	if (spec && spec.exact) Object.assign(current.exact, spec.exact);
	if (spec && Array.isArray(spec.patterns)) current.patterns = current.patterns.concat(spec.patterns);
	if (spec && Array.isArray(spec.aliases)) {
		spec.aliases.forEach(function(alias) { localeAliases[String(alias).trim().toLowerCase()] = key; });
	}
	locales[key] = current;
	return current;
}

function getLocale() {
	if (activeLocale) return activeLocale;
	const envLang = (typeof L === 'object' && L && L.env && L.env.lang) ||
		(typeof document === 'object' && document && document.documentElement && document.documentElement.getAttribute && document.documentElement.getAttribute('lang')) ||
		'en';
	return normalizeLocale(envLang);
}

function setLocale(code) {
	activeLocale = code ? normalizeLocale(code) : null;
	return getLocale();
}

function t(value) {
	if (typeof value !== 'string' || !value) return value;
	const translated = nativeTr(value);
	if (translated && translated !== value) return translated;
	const pack = locales[getLocale()];
	if (pack && Object.prototype.hasOwnProperty.call(pack.exact, value)) return pack.exact[value];
	return value;
}

function translateSingle(text) {
	if (typeof text !== 'string' || !text) return text;
	const direct = t(text);
	if (direct !== text) return direct;
	const pack = locales[getLocale()];
	if (!pack || !Array.isArray(pack.patterns)) return text;
	for (let i = 0; i < pack.patterns.length; i++) {
		const entry = pack.patterns[i], match = text.match(entry[0]);
		if (match) return typeof entry[1] === 'function' ? entry[1].apply(null, match) : text.replace(entry[0], entry[1]);
	}
	return text;
}

function translateMessage(text) {
	if (typeof text !== 'string' || !text) return text;
	const direct = translateSingle(text);
	if (direct !== text) return direct;
	if (text.indexOf('; ') >= 0) {
		const pack = locales[getLocale()];
		const sep = (pack && pack.separator) || '; ';
		const parts = text.split('; ').map(translateSingle);
		if (parts.some(function(part, i) { return part !== text.split('; ')[i]; })) return parts.join(sep);
	}
	return text;
}

registerLocale('zh-cn', {
	separator: '；',
	aliases: ['zh', 'zh-cn', 'zh_cn', 'zh-hans', 'zh_hans', 'zh-sg'],
	exact: {
		// Compatibility wizard
		"Apply to Affected Groups": "应用至受影响策略组",
		"Replaces choices for affected groups. Other groups are kept.": "批量更新受影响策略组的切换方式，其他策略组保持不变。",
		"%s group choices updated.": "已更新 %s 个策略组的切换方式。",
		"Policy group modes": "策略组切换方式",
		"Conditional routing": "重匹配分流",
		"Sub-rules": "子规则",
		"DNS policy": "DNS 策略",
		"Runtime settings": "运行设置",
		"Routing rules": "分流规则",
		"Mihomo: %s → %s: %s": "Mihomo：%s → %s：%s",
		"New profile": "新配置",
		"Sub-rule removal": "移除子规则",
		"Disabled rules": "停用规则",
		"Rule set copies": "规则集副本",
		"Other changes": "其他变更",
		"Compare clients, review the differences, then prepare a separate draft. Checks use saved settings and cached nodes.": "基于已保存配置与本地节点缓存，比对各客户端的兼容性差异，并按需派生独立的客户端草稿。",
		"Items to review": "待处理项",
		"View Suggestions": "查看建议",
		"%s issue types. Expand a row to see the affected items.": "共 %s 类待处理项，点击展开可查看涉及的具体条目。",
		"Issue": "问题类型",
		"Details and suggestions": "说明与处理建议",
		"%s · %s items": "%s · %s 项",
		"%s suggestions can fill unset choices. Rules and DNS settings still need your decision.": "共有 %s 项推荐设置可供自动填入；分流规则与 DNS 策略仍需手动确认。",
		"Use Suggestions": "使用推荐设置",
		"Adjust Manually": "手动调整",
		"Export validation details": "导出校验详情",
		"%s unset choices filled. Existing choices were kept.": "已自动填入 %s 项未设置项，原有手动选择保持不变。",
		"Manual selects a candidate; URL Test selects by latency; Fallback follows availability and order. Changes apply only to the listed groups.": "手动选择需人工切换节点；延迟测速按最低延迟自动优选；故障转移按列表顺序选择首个可用项。此处仅调整列表中策略组的自身模式。",
		"Replacing conditional routing changes how traffic selects a policy. Review the proposed candidates; rules are never removed automatically.": "替换重匹配入口将改变流量的二次分流方式。请核对候选策略列表；原有分流规则不会被自动删除。",
		"Batch choice": "批量设置模式",
		"Suggested modes": "推荐模式",
		"Affected groups only": "仅针对受影响的策略组",
		"Fill Unset Groups": "填入未设置的策略组",
		"Group visibility": "显示范围",
		"Show All Groups": "显示全部策略组",
		"Policy Group": "策略组",
		"Mihomo → target": "Mihomo → 目标端",
		"Use in the copy": "新配置采用模式",
		"Keep current mode": "保持当前模式",
		"Conditional entry": "重匹配入口",
		"Replacement": "替代方式",
		"Needs a decision": "请选择处理方式",
		"Manual candidate group": "手动选择组",
		"Latency-test candidate group": "延迟测速组",
		"Candidates in order": "候选策略（按顺序）",
		"Disable incompatible rules": "停用不兼容规则",
		"Optional. Unselected rules stay enabled and may still block export. Rules inside removed sub-rules are already covered by that removal.": "选填。未勾选的规则将保持启用（若不兼容仍会拦截导出）；已随子规则一并移除的规则无需在此重复勾选。",
		"Show Affected Groups": "仅显示受影响策略组",
		"Suggestions fill choices for review. Saving creates a separate draft; the original profile stays unchanged.": "推荐设置仅用于预填表单供你核对；确认创建后将生成独立草稿，不会修改原配置。",
		"Manual selection in sing-box needs client controls; otherwise it uses the first candidate.": "sing-box 的手动选择（selector）需配合客户端切换界面或 Clash API 使用，否则将固定使用第一个候选策略。",
		"Fill Unset Suggestions": "填入推荐设置",
		"Review each change category, then confirm to create the draft.": "请按类别核对并勾选确认以下变更，确认无误后创建独立草稿。",
		"Remaining export warnings": "剩余导出警告",
		"%s · %s changes": "%s · %s 项变更",
		"Show Changes": "查看变更明细",
		"Confirm every change category before creating the independent draft.": "请先勾选确认所有类别的变更，再创建独立草稿。",
		"No choice yet": "暂未选择",
		"Latency testing is a simpler alternative to Smart selection; it does not preserve Smart decisions.": "建议将 Smart 简化为延迟测速优选（不保留 Smart 历史权重与决策逻辑）。",
		"Use manual selection to match the source group mode; automatic switching will stop.": "建议与 Mihomo 原模式保持一致，改为手动选择（不再自动测速切换）。",
		"Use the target client latency testing; client timing and selection behavior may differ.": "建议改用目标客户端的延迟测速模式（测速触发时机与选路细节可能略有差异）。",
		"Ordered fallback keeps priority-based availability selection; native client behavior may still differ.": "建议改用故障转移模式，按候选顺序选择首个可用节点（不同客户端的健康检查细节可能略有差异）。",
		"This target has no native fallback mode; latency testing loses ordered failover priority.": "该客户端无原生故障转移模式；建议改用延迟测速模式（不再按固定先后顺序故障回退）。",
		"Latency testing selects by delay and does not preserve load balancing.": "建议改用延迟测速模式（按延迟优选单节点，不再分摊流量）。",
		"No suggestion is available because the Mihomo group mode is unknown.": "未能识别原 Mihomo 策略组模式，无法自动生成推荐设置。",
		"The target already uses this alternative; its remaining behavior difference still requires review.": "目标客户端当前已采用该替代模式，但与原模式仍存在行为差异，请核对确认。",
		"Candidates come from enabled scoped rules and final policies in their original order. Manual selection does not preserve rule conditions, REMATCH-NAME matching, or regional re-evaluation; the first candidate becomes the initial selection.": "候选策略已按子规则内启用规则及兜底策略的原有顺序提取。改为手动选择组后，不再执行原规则条件、REMATCH-NAME 识别或地区二次匹配，初始默认选中第一项。",
		"A scoped policy includes DIRECT or REJECT; review these routing decisions manually instead of inferring candidates.": "目标子规则包含 DIRECT 或 REJECT 出口，无法自动推导候选策略组，请手动指定替代方式。",
		"A rematch, sub-rule, or candidate policy reference is missing or ambiguous; choose candidates manually.": "重匹配入口、子规则或候选策略的引用缺失或存在冲突，请手动指定候选策略。",
		"The policy graph contains a cycle or a candidate depends on this rematch; choose candidates manually.": "策略引用存在循环依赖，或候选策略反向引用了当前重匹配入口，请手动指定候选策略。",
		"The policy graph exceeds the suggestion depth limit; choose candidates manually.": "策略嵌套层级超出自动推导上限，请手动指定候选策略。",
		"Scoped rules contain unsupported or malformed conditions; choose candidates manually.": "子规则中包含不支持或格式有误的匹配条件，请手动指定候选策略。",
		'Changing a parent group does not change automation inside its candidate groups. Adjust those groups separately under Automation Level.': '修改上层策略组不会改变其下属候选子组的切换方式；如需调整，请在“策略组切换方式”中单独设置。',
		"List candidate policies in order; the first is the initial default in manual mode. The former sub-rule conditions will no longer select between them.": "按顺序列出候选策略，手动模式下默认选中第一项；原有的子规则条件将不再参与出口选择。",
		"Choose an existing rematch for every replacement": "请选择当前配置已有的重匹配项进行替换",
		"A rematch alternative requires manual or url-test mode and explicit unique candidate policies": "重匹配替代方案须选择手动或延迟测速模式，并明确提供不重复的候选策略",
		"Choose an existing group and a supported alternative mode for this target": "请选择当前配置已有的策略组，以及目标客户端支持的替代模式",
		"manual selection does not automatically switch candidates or preserve Smart behavior": "手动选择不再自动切换候选策略，也不保留 Smart 智能选择行为",
		"latency testing selects by measured delay": "延迟测速按测得的延迟选择候选策略",
		"it does not preserve Smart or regional matching behavior": "不保留 Smart 智能选择或地区匹配行为",
		"fallback selects the first available candidate in order": "故障切换按列表顺序选择第一个可用候选策略",
		"it does not preserve Smart behavior": "不保留 Smart 智能选择行为",
		"sing-box manual selection requires client selection controls or its API": "sing-box 手动选择需要客户端提供切换界面或 API",
		"otherwise the first candidate is used": "否则将使用第一个候选策略",
		"regional re-evaluation is no longer performed in the new profile": "新配置将不再执行原有的地区二次匹配",
		"Automation Level": "策略组切换方式",
		"Automation for %s": "%s 的切换方式",
		"Mihomo: %s; target: %s. Manual selection stops automatic switching; URL Test selects by latency; Fallback selects by availability and order. Rule conditions stay unchanged.": "Mihomo 当前模式：%s；目标端模式：%s。手动选择需人工切换节点；延迟测速按最低延迟自动优选；故障转移按列表顺序选择首个可用策略。分流规则的匹配条件保持不变。",
		"Keep current target behavior": "保持目标客户端当前模式",
		"Choose an existing policy or create a manual or latency-based selection group. Replacing rematch stops conditional re-evaluation.": "可改用已有策略，或新建手动选择组、延迟测速组。替换后将不再按原重匹配条件执行二次分流。",
		"Create a manual selection group": "创建手动选择组",
		"Create a latency-test group": "创建延迟测速选择组",
		"Candidates for %s": "%s 的候选策略",
		"Manual selection in sing-box requires a client with selector controls or a configured Clash API. Without those controls, the generated default uses the first candidate.": "sing-box 的手动选择（selector）需配合客户端切换界面或 Clash API 使用；若无切换入口，将默认固定使用第一个候选策略。",
		"sing-box inline rule sets require explicit IP-CIDR ranges instead of GEOIP LAN": "sing-box 内联规则集需要明确的 IP-CIDR 网段，不能使用 GEOIP LAN",
		"Condition nesting exceeds 8 levels": "逻辑条件嵌套超过 8 层上限",
		"Duplicate Surge WebSocket header": "Surge 节点包含重复的 WebSocket 请求头",
		"Unsupported sing-box HTTP proxy protocol": "当前代理协议不支持导入 sing-box HTTP 传输层配置",
		"Unsupported sing-box HTTP/2 fields": "sing-box HTTP/2 传输配置包含不支持导入的字段",
		"Unsupported sing-box HTTP fields": "sing-box HTTP 传输配置包含不支持导入的字段",
		"Only proxy nodes are imported. Routing rules, policy groups, and DNS settings in the file are not imported; manage these in Subscription Profiles and Routing Rules.": "仅提取并导入代理节点；原文件中的策略组、分流规则及 DNS 设置不会导入，请在“订阅配置”与“分流规则”中统一配置。",
		"Rematch routing needs an explicit replacement policy": "重匹配分流需要明确选择替代策略",
		"Mihomo sub-rules require explicit removal or a manual native replacement": "目标客户端不支持 Mihomo 子规则，请确认移除子规则或改用目标端原生规则",
		"Native Mihomo DNS policy cannot be preserved; explicitly choose the target client DNS defaults": "目标客户端无法沿用 Mihomo 专属 DNS 策略，请确认改用目标端默认 DNS",
		"Native Mihomo runtime and geodata settings are omitted by this target": "目标客户端不支持 Mihomo 专属运行参数与地理数据库设置，导出时将自动忽略",
		"sing-box requires a native rule set instead of GEOIP": "sing-box 需要使用原生规则集替代 GEOIP",
		"sing-box cannot preserve no-resolve semantics": "sing-box 不支持规则级的 no-resolve（跳过域名解析）标记",
		"Compatibility resolutions must be an object": "兼容性处理方案必须是合法的对象",
		"Choose an existing group, DIRECT or REJECT for every rematch replacement": "重匹配替代策略必须选择当前配置已有的策略组、DIRECT 或 REJECT",
		"Choose existing enabled rules to disable": "只能选择当前配置已启用的规则进行停用",
		"Mihomo copies preserve native policies; compatibility removals are only for other targets": "Mihomo 副本将保留原生策略；兼容性移除选项仅用于其他客户端",
		"Invalid compatibility resolutions JSON": "兼容性处理方案 JSON 格式无效",
		"An independent profile requires a new unused identifier": "独立配置必须使用尚未占用的新标识符",
		"Profile name must contain 1–256 characters without control characters": "配置名称须为 1–256 个字符，且不含控制字符",
		"Generated compatibility identifier already exists; choose another profile identifier": "自动生成的派生条目标识符与现有配置冲突，请更换新配置的标识符",
		"Generated rule set identifier already exists; choose another profile identifier": "生成的规则集标识符已存在，请更换新配置的标识符",
		"Omit all native Mihomo DNS policy; the target client will use its generated system/local DNS defaults": "移除 Mihomo 专属 DNS 策略，改用目标客户端默认的系统或本地 DNS 设置",
		"Omit native Mihomo runtime and geodata policy from the new profile": "从新配置中移除 Mihomo 专属运行参数与地理数据库设置",
		"Compatibility plan changed; preview the plan again before creating the profile": "兼容性方案或节点缓存已变化，请重新预览再创建配置",
		"Please confirm every compatibility change before creating the profile": "请逐项确认全部兼容性变更，再创建配置",
		"Resolve all compatibility errors before creating the profile": "请先解决所有兼容性错误，再创建配置",
		"Duplicate Surge proxy option": "Surge 节点包含重复选项",
		"Conflicting Surge obfuscation options": "Surge 节点的混淆选项冲突",
		"TUIC heartbeat must be whole milliseconds or seconds": "TUIC 心跳间隔必须为整数毫秒或秒",
		"Compatibility": "兼容性",
		"Save & Check Compatibility": "保存并检查兼容性",
		"Create a subscription profile before checking compatibility.": "请先创建订阅配置，再检查兼容性。",
		"Checks all three clients using the saved draft and local node caches. Import Mihomo, Surge, or sing-box subscriptions under Subscription Sources, then choose output formats in Subscription Profiles.": "基于已保存的配置草稿与本地节点缓存，检查 Mihomo、Surge、sing-box 三端导出兼容性。可在“订阅源”中导入三端节点订阅，并在“订阅配置”中指定目标导出格式。",
		"Check Compatibility": "检查兼容性",
		"Target Client": "目标客户端",
		"Blocked": "存在阻塞项",
		"Review Differences": "需确认差异",
		"Compatible": "兼容",
		"Compatibility Wizard": "兼容性向导",
		"Compatibility describes this exporter and its selected target versions. Unsupported policies block output; differences still require confirmation when publishing.": "检查结果以本工具当前的转换规则及所选客户端版本为准。不支持的协议或分流语义会直接拦截导出；非阻断性的行为差异仍需在发布前勾选确认。",
		"Affected Item": "受影响项目",
		"Suggested Action": "建议处理方式",
		"No additional compatibility issues.": "无其他兼容性问题。",
		"Independent Profile": "独立配置",
		"Routing Decisions": "分流处理",
		"Client Settings": "客户端设置",
		"Replacement for %s": "%s 的替代策略",
		"Choose a fixed policy to replace this rematch entry. This changes routing behavior.": "使用固定出口策略替代该重匹配入口（将改变原有二次分流行为）。",
		"Keep unresolved": "保留，暂不处理",
		"Remove sub-rule routing in the copy": "在副本中移除子规则分流",
		"Removes the named sub-rules and their scoped rules. Review every removal in the next step.": "在副本中移除全部命名子规则及其下属分流规则，下一步将逐项列出供你核对确认。",
		"Omit Mihomo DNS policy in the copy": "在副本中移除 Mihomo DNS 策略",
		"The target will use its own DNS behavior. This can change resolution and routing.": "目标客户端将改用自身的默认 DNS 设置，可能会影响域名解析与分流结果。",
		"Omit Mihomo advanced policy in the copy": "在副本中移除 Mihomo 高级策略",
		"Disable selected rules in the copy": "在副本中停用所选规则",
		"Only select rules whose removal you accept. Traffic will continue to later rules or the fallback policy.": "仅勾选确认停用的分流规则；停用后，原命中流量将顺延匹配后续规则或走默认兜底策略。",
		"Incompatible": "不兼容",
		"Creates an independent draft from the saved profile. Select changes explicitly, then review their effects before saving.": "基于当前已保存的配置派生一套独立的客户端草稿。请按需选择兼容调整项，并在下一步核对变更明细后保存。",
		"Preview Changes": "预览变更",
		"Review Compatibility Changes": "确认兼容性变更",
		"The independent draft passes export validation. Confirm each change to create it.": "新配置草稿已通过导出校验，请逐项勾选确认以下变更后完成创建。",
		"Unresolved issues still block this target. Go back to adjust decisions or edit the original draft.": "仍存在未解决的兼容错误，无法生成该客户端配置。请返回调整向导选项，或先修改原配置草稿。",
		"Creation saves a draft only. Build and publish it from Overview after reviewing the resulting profile.": "此操作仅创建并保存配置草稿；核对无误后，请前往“状态概览”页面执行构建与发布。",
		"Back": "返回",
		"Create Independent Draft": "创建独立草稿",
		"Confirm every proposed change before creating the independent draft.": "请逐项确认所有变更，再创建独立草稿。",

		"Confirm every change category before updating the compatible draft.": "请先勾选确认所有类别的变更，再更新兼容草稿。",
		"Existing draft changes": "现有草稿变更",
		"Review and Update Copy": "复核并更新",
		"Review each change category, then confirm to update the existing draft.": "请按类别核对并勾选确认以下变更，确认无误后更新现有兼容草稿。",
		"Review saved choices before updating this draft. Its identifier, name and download link stay the same; the original profile stays unchanged.": "复核已保存的转换设置并更新当前兼容草稿。更新后其名称、标识符与订阅下载链接均保持不变，来源配置不受影响。",
		"Review the saved conversion choices.": "请复核已保存的转换方案。",
		"Saved compatible copies": "已保存的兼容配置",
		"Saved conversion": "已保存的转换方案",
		"Saved conversion choices are up to date.": "当前转换方案已与来源配置保持同步。",
		"Some saved choices were cleared. Review these items again:": "以下已保存的选项因来源配置变更而失效，请重新指定：",
		"Source policy changed. Review the saved conversion choices.": "来源配置已发生变更，请复核已保存的转换方案。",
		"Source profile: %s": "来源配置：%s",
		"The source profile is missing. The saved copy can still be used.": "来源配置已删除，现有兼容配置仍可正常使用。",
		"This copy has local edits. Review what updating will replace.": "该兼容草稿存在本地手动修改，更新前请核对将被覆盖的内容。",
		"Update Compatible Draft": "更新兼容草稿",
		"Updating saves the draft only. The published subscription stays unchanged until you build and publish this copy again.": "此操作仅更新并保存配置草稿；如需更新线上订阅内容，请前往“状态概览”重新构建并发布。",
		"View Copy": "查看配置",
		"View Source Profile": "查看来源配置",
		"Compatible draft has local changes. Review before updating.": "该兼容草稿存在手动修改，更新前请先复核变更。",
		"Review Conversion": "复核转换方案",
		"Saved conversion needs review.": "已保存的转换方案需要复核。",
		"Source and compatible draft changed. Review before updating.": "来源配置与当前兼容草稿均有变更，更新前请先复核。",
		"Source profile changed. Review before updating this draft.": "来源配置已发生变更，请复核并更新当前兼容草稿。",
		"Source profile is missing. Review this compatible draft.": "来源配置已删除，请检查当前兼容草稿。",
		"The source content or a referenced policy changed; review this saved choice again.": "来源配置或所引用的策略已发生变更，请重新指定此项设置。",
		"The source profile no longer exists; the current compatible draft and published release are preserved.": "来源配置已删除，现有兼容草稿与已发布版本仍会保留。",
		"Compatibility source relationships contain a cycle": "兼容配置的来源关联存在循环引用",
		"Compatibility source relationships exceed the depth limit": "兼容配置的来源关联层级超出上限",
		"Only a tracked compatible profile can be updated from its source": "仅已记录来源关系的兼容配置支持从来源同步更新",
		"The update must use the saved source profile and target format": "复核更新须使用已保存的来源配置与目标客户端格式",
		"A managed compatibility rule set is used by another profile; resolve that reference before updating": "当前兼容配置的派生规则集正被其他配置引用，请先解除引用后再更新",
		"The compatible draft was edited independently; replace its current contents with this reviewed conversion plan": "该兼容草稿曾被单独修改；确认后将使用本次复核的转换方案覆盖现有草稿内容",
		"Invalid compatibility operation": "兼容性操作类型无效",
		"Use compatibility update to replace an existing draft": "请通过“复核并更新”修改已有兼容草稿",
		"Compatibility plan changed; preview the plan again before saving the draft": "兼容性方案或节点缓存已变化，请重新预览后再保存草稿",
		"Please confirm every compatibility change before saving the draft": "请逐项确认全部兼容性变更后再保存草稿",
		"Resolve all compatibility errors before saving the draft": "请先解决所有兼容性错误后再保存草稿",
		"regional re-evaluation is no longer performed in the compatible draft": "兼容草稿将不再执行原有的地区二次匹配",
		"Omit native Mihomo runtime and geodata policy from the compatible draft": "从兼容草稿中移除 Mihomo 专属运行参数与地理数据库设置",

		// Menu & ACL
		'Hybrid Subscription': '混合订阅',
		'Overview': '状态概览',
		'Subscription Sources': '订阅源',
		'Subscription Profiles': '订阅配置',
		'Routing Rules': '分流规则',
		'Global Settings': '全局设置',
		'Manage hybrid subscription sources, profiles, and releases': '管理混合订阅源、配置草稿与发布版本',

		// Common & Shared UI (hybrid-subscription.js)
		'The router did not return a valid response. Please check the backend service and permissions.': '路由器未返回有效响应，请检查后台服务状态与账户权限。',
		'Unknown': '未知',
		'No records': '暂无记录',
		'Validation found %s error(s).': '校验未通过，共发现 %s 项错误。',
		'Validation passed with no blocking errors.': '校验通过，未发现配置错误。',
		'Close': '关闭',
		'Job submitted. Waiting for completion…': '任务已提交，正在等待后台执行完成…',
		'Refreshing the page will not cancel the background job.': '刷新页面不会中断后台任务。',
		'Processing…': '正在处理…',
		'Job failed.': '任务执行失败。',
		'The job is still running in the background. Check the Overview page for its status.': '任务仍在后台运行，请稍后在“状态概览”页面查看进度。',
		'The backend did not return a job identifier.': '后台未返回有效的任务标识。',
		'Draft saved. Build and publish from the Overview page to update downloads or OpenClash.': '草稿已保存。如需更新下载内容或同步至 OpenClash，请在“状态概览”页面构建并发布。',
		'Global settings saved.': '全局设置已保存。',
		'Add': '添加',
		'Identifier': '标识符',
		'Start with a lowercase letter and use only lowercase letters, digits, underscores, or hyphens (up to 48 characters).': '须以小写字母开头，仅限小写字母、数字、下划线或连字符，长度不超过 48 个字符。',
		'Name': '名称',
		'Please enter a valid JSON array.': '请输入合法的 JSON 数组。',
		'Please enter a valid JSON object.': '请输入合法的 JSON 对象。',
		'Invalid JSON format: ': 'JSON 格式无效：',
		'Paste YAML, JSON, or node subscription content': '粘贴 YAML、JSON 或节点订阅内容',
		'File size must not exceed 2 MiB.': '文件大小不得超过 2 MiB。',
		'Import Cache: ': '导入本地缓存：',
		'Replaces only the local node cache for this source without fetching upstream or publishing automatically.': '仅替换该订阅源的本地缓存，不会请求上游地址，也不会自动重新发布。',
		'Cancel': '取消',
		'Validate & Import': '校验并导入',
		'Content size must not exceed 2 MiB.': '内容大小不得超过 2 MiB。',
		'Source node cache has been imported.': '订阅源本地缓存已导入。',
		'Download access is restricted to authenticated LuCI sessions. Third-party clients cannot pull via URL or QR code; please download the file and import it manually.': '当前仅允许已登录的 LuCI 会话下载，客户端无法通过链接或二维码直接更新，请下载文件后手动导入。',
		'Anyone with the download link can access the node credentials in this subscription. Share only with your own trusted devices.': '下载链接包含完整的节点密码与凭据，请仅在个人设备间使用，切勿外泄。',
		'Download File': '下载配置文件',
		'Import in Surge': '一键导入至 Surge',
		'No published artifacts are available. Build and publish the profile first.': '尚无已发布的配置文件，请先构建并发布。',
		'Subscription Download & QR Code': '订阅下载与二维码',
		'Dependency graph of subscription sources, policy groups, rematch entries, and sub-rules': '订阅源、策略组、重匹配项与子规则依赖关系图',
		'Final fallback policy of main rules': '主规则链默认兜底出口',
		'Main rules final fallback': '主规则链默认出口',
		'Source nodes expanded into policy group': '订阅源节点汇入策略组',
		'Group member': '策略组成员引用',
		'Empty group fallback': '空策略组回退出口',
		'Forwards to sub-rule': '转发至子规则',
		'Sub-rule final fallback': '子规则默认出口',
		'Profile / Sources': '配置 / 订阅源',
		'Policy Groups': '策略组',
		'Rematch Entries': '重匹配项',
		'Sub-Rules': '子规则',
		'Built-in Policies': '内置策略',
		'Zoom': '缩放比例',
		'Scroll horizontally or vertically to inspect. 100% preserves native label size; expand below for full names and outgoing references.': '可横向或纵向滚动查看。100% 保持原始字号；下方可展开查看完整名称与引用目标。',
		'Scrollable policy dependency graph': '可滚动的策略依赖关系图',
		'Full Names & Outgoing References (Click a Name to Focus)': '完整名称与引用明细（点击名称可定位节点）',
		'References': '引用目标',

		// Overview (overview.js)
		'Confirm Publication': '确认发布',
		'Validation and build succeeded. Publishing makes this release available via the download link without re-fetching upstream sources.': '配置已生成。发布后下载链接将直接提供此版本，不会重新拉取上游订阅源。',
		'The following compatibility differences may affect client behavior. Please review and confirm each item:': '以下兼容性差异会影响导出结果，请逐项确认：',
		'No compatibility differences require confirmation.': '无跨客户端兼容性差异。',
		'Not Now': '暂不发布',
		'Please confirm all compatibility differences, or return to modify the configuration.': '请勾选确认全部兼容性差异，或返回修改配置。',
		'Apply to OpenClash': '应用至 OpenClash',
		'Used ': '已用 ',
		'No quota data': '暂无流量数据',
		'Expires: ': '到期时间：',
		'Not provided by upstream': '上游未提供',
		'Never expires': '长期有效',
		'Click "Refresh Quota" to fetch the latest data.': '可点击“刷新额度”获取最新数据。',
		'Quota query is not configured. Configure it under Subscription Sources.': '未配置额度查询，请前往“订阅源”页面配置。',
		'Stale · ': '数据已过期 · ',
		'Preview Client Format': '预览客户端格式',
		'Select a format to generate a preview. Sensitive node credentials will be redacted.': '选择格式后生成预览，服务器地址与密码已做脱敏处理。',
		'Preview: ': '配置预览：',
		'Generate Preview': '生成预览',
		'No content available to display.': '暂无可显示的内容。',
		'Release Management: ': '版本管理：',
		'Validate Draft': '校验草稿',
		'Validation Result': '校验结果',
		'View Preview': '查看预览',
		'Edit Routing Rules': '编辑分流规则',
		'Release History': '版本记录',
		'Created At': '生成时间',
		'Release ID': '版本号',
		'Status': '状态',
		'Actions': '操作',
		'Published': '当前发布',
		'Previously Published': '历史发布',
		'Unpublished': '未发布',
		'Roll Back': '回滚',
		'Publish': '发布',
		'Roll Back Release': '回滚版本',
		'Rolling back restores the download link to this release. If auto-apply is enabled, OpenClash will also be updated.': '回滚后下载链接将切换至此历史版本；若已启用自动应用，OpenClash 配置也将同步更新。',
		'Confirm Rollback': '确认回滚',
		'Roll Back OpenClash': '回滚至 OpenClash',
		'OpenClash & Download Management': 'OpenClash 与下载管理',
		'Apply Published Release to OpenClash': '将已发布版本应用至 OpenClash',
		'This will back up and switch the active OpenClash configuration, which may briefly interrupt proxy connections.': '将自动备份现有配置并切换 OpenClash 运行配置，期间代理连接可能短暂中断。',
		'Apply': '应用',
		'Rotate Download Token': '重置下载令牌',
		'Existing download links and QR codes will be invalidated immediately. Clients must re-import the new subscription URL.': '重置后原下载链接与二维码立即失效，客户端需重新导入订阅地址。',
		'Confirm Rotation': '确认重置',
		'Unpublish': '停止发布',
		'Revokes download links while retaining release history and the active OpenClash configuration.': '停用下载链接并吊销访问令牌；历史版本与当前运行的 OpenClash 配置不受影响。',
		'Confirm Unpublish': '确认停止发布',
		'Published · ': '已发布 · ',
		'Draft · Unpublished': '草稿 · 未发布',
		'Edit Profile': '编辑配置',
		'Build & Publish': '构建并发布',
		'Validate and Build Release': '校验并构建版本',
		'No release ID was returned. Please check the job status.': '未返回版本标识，请查看任务执行结果。',
		'Download / QR Code': '下载 / 二维码',
		'Release Management': '版本管理',
		'Add subscription sources first, then create a subscription profile.': '请先添加订阅源，再创建订阅配置。',
		'Create Subscription Profile': '创建订阅配置',
		'Subscription Source Status': '订阅源状态',
		'Source': '订阅源',
		'Node Cache': '节点缓存',
		'Quota / Expiration': '流量 / 到期',
		' nodes': ' 个节点',
		'Not cached': '尚未缓存',
		' regions matched': ' 个匹配地区',
		'Refresh Quota': '刷新额度',
		'Refresh Quota Status': '刷新流量额度',
		'Manage Sources': '管理订阅源',
		'Components & Recent Jobs': '组件状态与近期任务',
		'The draft has unpublished changes. Build and publish to update downloads and OpenClash.': '当前配置或节点有未发布的改动，请重新构建并发布以更新订阅文件与 OpenClash。',
		'The current draft cannot generate all selected formats. Check the configuration and compatibility before publishing.': '当前草稿无法导出全部所选格式，请先检查配置项与兼容性后再构建发布。',
		'Component': '组件',
		'Installed': '已安装',
		'Not installed': '未安装',
		'Available': '可用',
		'Unavailable': '不可用',
		'Time': '时间',
		'Operation': '操作',
		'Details': '详情',
		'Update Nodes': '更新节点',
		'Build Release': '构建版本',
		'Compatibility Audit': '兼容性比对',
		'Queued': '排队中',
		'Running': '运行中',
		'Completed': '已完成',
		'Failed': '失败',

		// Sources (sources.js)
		'Enabled': '启用',
		'Cache Status': '缓存状态',
		'Disabled · ': '已停用 · ',
		' nodes · ': ' 个节点 · ',
		'Subscription URL': '订阅地址',
		'Saved URLs are loaded when you edit this source. Use the visibility button to view the address. Leave blank to keep the saved URL; new sources may use a local file instead.': '打开编辑时会自动载入已保存的地址，可点击显示按钮查看明文。留空则保留原地址；若仅通过本地文件导入节点，可留空保存。',
		'URL Saved': '已保存地址',
		'Yes': '是',
		'No': '否',
		'Dedicated Quota Query URL': '独立额度查询地址',
		'Specify a dedicated endpoint that returns the Subscription-Userinfo header. Quota refreshes never fall back to the subscription URL. Leave blank to keep the saved URL.': '填写返回 Subscription-Userinfo 响应头的独立接口。刷新额度时不会回退请求原订阅地址；留空则保留原地址。',
		'Quota URL Saved': '已保存额度地址',
		'Clear Saved Quota URL': '清除已保存的额度地址',
		'Check and save to remove the dedicated quota query endpoint.': '勾选并保存后，将移除已保存的独立额度查询地址。',
		'Query Quota via Subscription URL': '允许通过订阅地址查询额度',
		'When no dedicated quota URL is set, sends a GET request to the subscription URL to read response headers. Keep disabled for time-windowed or rate-limited subscriptions, as this may consume pull quota. Only triggered manually.': '未设置独立地址时，点击“刷新额度”将请求原订阅地址并读取响应头。限时或限次拉取的订阅源请保持关闭，以免消耗拉取次数。',
		'Quota Cache TTL (seconds)': '额度数据有效期（秒）',
		'Data older than this threshold is marked as stale without triggering automatic requests.': '超出此时间后将标记为过期数据，不会自动发起后台请求。',
		'No data': '暂无数据',
		'Quota Query Not Configured': '尚未配置额度查询',
		'Configure a dedicated quota URL under "Quota / Expiration". Standard subscriptions may also enable header queries via the subscription URL; keep that disabled for time-windowed subscriptions.': '请在“流量 / 到期”标签页配置独立额度查询地址。普通订阅源也可开启“允许通过订阅地址查询额度”；限时或限次订阅请仅使用独立查询地址。',
		'Input Format': '输入格式',
		'Auto Detect': '自动识别',
		'Update Mode': '更新方式',
		'Manual Only': '仅手动',
		'Scheduled': '定时更新',
		'Update Interval (seconds)': '更新间隔（秒）',
		'Applies only to scheduled sources. Do not enable scheduled updates for time-windowed subscriptions.': '仅对定时更新的订阅源生效。限时或限次拉取的订阅源请勿启用定时更新。',
		'Exclude Node Names (Regex)': '排除节点名称（正则）',
		'Filter out informational entries such as traffic or expiration notices.': '按正则表达式过滤剩余流量提示、官网说明等非代理节点条目。',
		'Download User-Agent': '请求 User-Agent',
		'Leave blank to use the default User-Agent.': '留空则使用默认 User-Agent。',
		'Linked OpenClash Source': '关联的 OpenClash 订阅源',
		'Take Over OpenClash Subscription Updates': '接管 OpenClash 订阅更新',
		'Applies only to sources imported from OpenClash. Disables OpenClash auto-updates for this source when applying a profile to prevent duplicate pulls.': '仅对从 OpenClash 导入的订阅源生效。应用配置时将停用 OpenClash 对该订阅的自动更新，避免重复拉取。',
		'Update Subscription': '更新订阅',
		'Initial cache': '首次缓存',
		'Nodes unchanged': '节点无变化',
		'Added %s · removed %s · modified %s': '新增 %s · 移除 %s · 修改 %s',
		'Node order changed': '节点顺序变化',
		'Node Update Result: ': '节点更新结果：',
		'Nodes: %s → %s.': '节点数：%s → %s。',
		'Node refresh updates only the cache. Published downloads and OpenClash are unchanged.': '本次操作仅更新本地节点缓存，已发布的订阅内容与 OpenClash 配置保持不变。',
		'Profiles using this source:': '使用此订阅源的配置：',
		'Open Overview to build and publish the profiles you want to update.': '请前往“状态概览”页面，重新构建并发布需要同步更新的配置。',
		'No node changes were found; this refresh does not require rebuilding.': '节点内容未发生变化，本次刷新无需重新构建发布。',
		'This source is not referenced by any profile yet.': '当前尚无订阅配置使用此订阅源。',
		'Go to Overview': '前往状态概览',
		'Done': '完成',
		'Import File': '导入文件',
		'Subconverter Compatibility Audit': '转换器兼容性比对',
		'Missing': '缺失',
		'Added': '新增',
		'Modified': '字段变更',
		'Compatibility Audit: ': '兼容性比对：',
		'Compares cached nodes against local subconverter output without fetching upstream sources or modifying the cache.': '仅比对本地缓存节点与 subconverter 的转换结果，不会拉取上游订阅或修改本地缓存。',
		'Original nodes: %s; Converted nodes: %s.': '原始节点数：%s；转换后节点数：%s。',
		'Native parser and subconverter outputs are identical.': '原生解析与 subconverter 转换结果完全一致。',
		'Differences detected. Subscription generation continues to use the native parser output.': '检测到字段差异，导出配置仍以原生解析结果为准。',
		'Node': '节点名称',
		'Difference Type': '差异类型',
		'Affected Fields': '涉及字段',
		'No differences': '无差异',
		'Subscription & Updates': '订阅与更新',
		'Advanced': '高级选项',
		'Import from OpenClash': '从 OpenClash 导入',
		'OpenClash subscription sources and node caches have been imported.': '已导入 OpenClash 订阅源与本地缓存。',

		// Profiles (profiles.js)
		'Quick Create Profile': '快速创建订阅配置',
		'Included Sources': '包含的订阅源',
		'Export Formats': '导出格式',
		'Default Fallback Policy': '默认兜底策略',
		'Select a policy group or rematch entry belonging to this profile, or DIRECT / REJECT.': '未命中任何分流规则时的默认出口，仅可选择当前配置下的策略组、重匹配项或内置策略。',
		'Mihomo Core Variant': 'Mihomo 内核版本',
		'The Smart core variant is required when using Smart policy groups.': '若策略组使用了 Smart 类型，须选择支持 Smart 的 Mihomo 内核。',
		'Standard Mihomo': '标准 Mihomo 内核',
		'Mihomo Smart': 'Mihomo Smart 内核',
		'Surge Target': 'Surge 目标版本',
		'Surge (Modern)': 'Surge 现代版',
		'sing-box Target': 'sing-box 目标版本',
		'Mihomo DNS Policy (JSON)': 'Mihomo DNS 策略（JSON）',
		'Configure Mihomo DNS routing options. Listener addresses and controller secrets are managed by the router and not permitted here. Leave empty to use defaults.': '配置 Mihomo DNS 分流与解析选项；监听端口与控制密钥等运行参数由路由器管理，不可在此填写。留空则使用默认设置。',
		'Mihomo Advanced Policy (JSON)': 'Mihomo 高级策略（JSON）',
		'Configure domain sniffing, connection behavior, and GeoIP/GeoSite database options. Controller, listener, TUN, and network interface bindings are not permitted.': '配置域名嗅探、连接保活及 GeoIP / GeoSite 数据库选项；不可填写控制器、监听端口、TUN 或网卡绑定参数。',
		'Dependency Graph': '依赖关系图',
		'Dependency Graph: ': '依赖关系图：',
		'Directed edges illustrate references across sources, policy groups, rematch entries, and sub-rules. Circular dependencies will block validation and publication.': '展示订阅源、策略组、重匹配项与子规则之间的引用流向。若存在循环引用，校验时将直接报错并阻止发布。',
		'General': '基本设置',
		'Target Clients': '目标客户端',
		'Advanced Policy': '高级策略',
		'Profile': '所属配置',
		'Node Sources': '节点来源',
		'Leave empty to include only explicit group members without expanding source nodes.': '留空则不展开订阅源节点，仅包含下方手动指定的成员。',
		'Region Template': '地区匹配模板',
		'Combined with the include and exclude regular expressions below. Per-source region overrides can be configured in Global Settings.': '与下方的包含、排除正则同时生效。如需为特定订阅源单独指定匹配规则，可在“全局设置”中配置。',
		'No Region Template': '不使用地区模板',
		'None': '无',
		'Include Nodes (Regex)': '包含节点（正则）',
		'Example: Japan|日本|JP to match only nodes in that region.': '例如填写 Japan|日本|JP，仅筛选名称匹配的节点入组。',
		'Exclude Nodes (Regex)': '排除节点（正则）',
		'Group Members / Built-in Policies': '策略组成员 / 内置策略',
		'Select policy groups or rematch entries within the same profile, or DIRECT / REJECT. Surge Smart groups accept nodes only.': '可选择同一订阅配置下的策略组、重匹配项或 DIRECT、REJECT。注意：Surge 的 Smart 策略组仅支持直接包含节点。',
		'Mihomo Group Type': 'Mihomo 策略组类型',
		'Manual Select': '手动选择',
		'URL Test (Auto)': '自动测速优选（URL-Test）',
		'Fallback': '故障转移（Fallback）',
		'Load Balance': '负载均衡（Load-Balance）',
		'Surge Group Type': 'Surge 策略组类型',
		"Exports a Clash YAML profile with nodes, policy groups and routing rules. Import it under Config in Shadowrocket; review unsupported Mihomo features before exporting.": '导出包含节点、策略组和分流规则的 Clash YAML 配置，请在 Shadowrocket 的“配置”中导入。导出前需处理不兼容的 Mihomo 特性。',
		"Invalid Shadowrocket proxy definition": "Shadowrocket 节点定义格式无效",
		"Quoted, escaped or commented native Shadowrocket proxy fields have no verified import mapping": "当前转换器尚未提供经核实的 Shadowrocket 引号、转义或注释字段导入映射",
		"This protocol has no verified native Shadowrocket import mapping yet; use supported URI or YAML nodes": "当前转换器尚未提供经核实的该协议 Shadowrocket 原生导入映射，请使用受支持的节点链接或 YAML 节点",
		"Invalid Shadowrocket proxy option": "Shadowrocket 节点选项格式无效",
		"Duplicate Shadowrocket proxy option": "Shadowrocket 节点包含重复选项",
		"Shadowrocket method is supported only for SS and VMess": "当前转换器仅支持为 SS 和 VMess 导入 Shadowrocket method 选项",
		"Shadowrocket alterId is supported only for VMess": "Shadowrocket alterId 选项仅适用于 VMess",
		"Legacy VMess has no verified Shadowrocket import mapping": "当前转换器尚未提供经核实的旧版 VMess Shadowrocket 导入映射",
		"Invalid Shadowrocket boolean": "Shadowrocket 布尔值格式无效",
		"Shadowrocket TLS options require enabled TLS": "Shadowrocket TLS 选项需要先启用 TLS",
		"Trojan requires TLS": "Trojan 需要启用 TLS",
		"TLS-wrapped Shadowsocks has no verified import mapping": "当前转换器尚未提供经核实的 TLS 封装 Shadowsocks 导入映射",
		"conflicting TLS server names": "TLS 服务器名称设置冲突",
		"TLS options require enabled TLS": "TLS 选项需要先启用 TLS",
		"Native Shadowrocket import requires an explicit udp=0 or udp=1; the client default has no verified mapping": "导入 Shadowrocket 原生节点需要明确设置 udp=0 或 udp=1；当前转换器尚未验证客户端默认行为的映射",
		"Native Shadowrocket VMess import currently supports only method=auto": "当前转换器导入 Shadowrocket 原生 VMess 节点时仅支持 method=auto",
		"Shadowrocket policy names must be unique ignoring case, including DIRECT and REJECT": "Shadowrocket 策略名称不得重复（不区分大小写），也不得与 DIRECT 或 REJECT 重名",
		"Shadowrocket LAN rules use explicit private, loopback and link-local ranges; Mihomo GEOIP LAN may include additional reserved ranges": "Shadowrocket LAN 规则使用明确的私有、回环和链路本地网段；Mihomo GEOIP LAN 可能还包含其他保留网段",
		"Reality requires VLESS or VMess": "Reality 需要使用 VLESS 或 VMess 协议",
		"Reality requires enabled TLS": "Reality 需要启用 TLS",
		"this protocol requires TLS": "该协议需要启用 TLS",
		"conflicting VMess AEAD settings": "VMess AEAD 设置冲突",
		"unsupported VMess cipher": "不支持的 VMess 加密方式",
		"conflicting fast-open settings": "TCP Fast Open 设置冲突",
		"conflicting AnyTLS reuse settings": "AnyTLS 连接复用设置冲突",
		"conflicting certificate fingerprints": "证书指纹设置冲突",
		"unsupported v2ray-plugin mode": "不支持的 v2ray-plugin 模式",
		"conflicting plugin certificate verification settings": "插件证书验证设置冲突",
		"transport options must be an object": "传输选项必须为对象",
		"HTTP headers must be an object": "HTTP 请求头必须为对象",
		"multiple HTTP/2 paths cannot be represented": "无法转换多个 HTTP/2 路径，请明确使用一个路径",
		"HTTP/2 headers must be an object": "HTTP/2 请求头必须为对象",
		"conflicting HTTP/2 hosts": "HTTP/2 主机名设置冲突",
		"WebSocket path must be text": "WebSocket 路径必须为文本",
		"HTTP Upgrade early data requires an explicit transport mapping": "HTTP Upgrade 提前数据需要明确的传输方式映射",
		"conflicting WebSocket early data limits": "WebSocket 提前数据大小限制冲突",
		"invalid transport URL encoding": "传输地址的 URL 编码无效",
		'Shadowrocket (Clash YAML)': 'Shadowrocket（Clash YAML）',
		'Shadowrocket Group Type': 'Shadowrocket 策略组类型',
		'sing-box Group Type': 'sing-box 策略组类型',
		'Health Check URL': '连通性测试地址',
		'Test Interval (seconds)': '测速间隔（秒）',
		'Latency Tolerance (ms)': '延迟容差（毫秒）',
		'Hide Group in Supported Clients': '在客户端界面隐藏此策略组',
		'Mihomo Default Selection': 'Mihomo 默认选中项',
		'Must be a member of this group. Leave empty to use the client default.': '须为当前策略组的有效成员；留空则使用客户端默认选中项。',
		'Mihomo Empty Group Fallback': 'Mihomo 空组回退策略',
		'Fallback policy when no nodes match the filter. Leave empty to report an empty group during validation.': '未筛选到任何节点时使用的回退出口；留空则在配置校验时报错提示。',
		'Lazy Health Check': '按需延迟测试（Lazy）',
		'Mihomo tests node latency only when this policy group is actively used.': '仅在该策略组产生实际流量时触发节点连通性测试（仅 Mihomo 生效）。',
		'Nodes & Members': '节点与成员',
		'Client Behavior': '客户端行为',
		'Health Check': '连通性测试',
		'Mihomo Rematch Entries': 'Mihomo 重匹配入口',
		'Forwards traffic into a designated sub-rule for secondary matching.': '将命中流量转交至指定子规则继续匹配。',
		'Target Sub-Rule': '目标子规则',
		'Rematch Tag': '重匹配标记',
		'Optional tag matched by REMATCH-NAME rules inside the target sub-rule.': '可选标记，供目标子规则中的 REMATCH-NAME 规则识别来源。',
		'Mihomo Sub-Rules': 'Mihomo 子规则',
		'Rules inside each sub-rule are managed on the Routing Rules page and evaluated in order.': '子规则内的分流条目在“分流规则”页面统一管理，并按排列顺序依次匹配。',
		'Fallback Policy': '未命中兜底策略',
		'Save & Edit Rules': '保存并编辑规则',
		'Advanced Routing': '高级路由',
		'All Profiles': '全部订阅配置',
		'Active Profile': '当前订阅配置',
		'Use 1–40 lowercase letters, digits, underscores, or hyphens, starting with a letter.': '请使用 1–40 个小写字母、数字、下划线或连字符，且须以字母开头。',
		'Creates a starter profile with a manual node selection group for Mihomo, Surge, and sing-box. You can add region groups and routing rules afterward.': '快速生成包含默认节点选择组的基础配置（同时支持 Mihomo、Surge 与 sing-box），创建后可继续补充地区策略组与分流规则。',
		'Add to Draft': '添加至草稿',
		'Profile identifier already exists.': '该配置标识符已存在。',
		'Proxy': '节点选择',

		// Rules (rules.js)
		'Ordered Routing Rules': '分流规则列表',
		'Rule Scope': '所属规则域',
		'Select Main Rules or a sub-rule belonging to the same profile.': '留空归入主规则链；若选择子规则，须归属于同一订阅配置。',
		'Main Rules': '主规则链',
		'Rule Type': '规则类型',
		'Match Value': '匹配内容',
		'Use TCP or UDP for NETWORK; REMATCH-NAME is valid only within sub-rules. Edit AND/OR/NOT conditions under the "Advanced Conditions" tab.': 'NETWORK 类型请填写 TCP 或 UDP；REMATCH-NAME 仅在子规则内有效。AND / OR / NOT 逻辑组合条件请在“高级条件”标签页中编辑。',
		'Logical expression · ': '逻辑组合 · ',
		' conditions': ' 个条件',
		'Outbound Policy': '出口策略',
		'Skip DNS Resolution (no-resolve)': '跳过域名解析（no-resolve）',
		'Applies to IP and rule-set rules that support no-resolve. Unsupported target formats will report a warning during validation.': '匹配 IP 或规则集时不触发本地 DNS 解析；若目标客户端不支持该标记，校验时将给出兼容性提示。',
		'Logical Conditions (JSON Array)': '逻辑条件（JSON 数组）',
		'Example: [ {"type":"NETWORK","value":"UDP"}, {"type":"RULE-SET","value":"ruleset_id"} ]. Nested conditions use type and conditions; AND/OR require at least 2 conditions, and NOT requires exactly 1.': '示例：[ {"type":"NETWORK","value":"UDP"}, {"type":"RULE-SET","value":"规则集标识"} ]。支持通过 type 与 conditions 嵌套组合；AND / OR 至少包含 2 个子条件，NOT 须恰好包含 1 个子条件。',
		'Matching & Policy': '匹配与出口',
		'Advanced Conditions': '高级条件',
		'Shared Rule Sets': '共享规则集',
		'Available across all subscription profiles regardless of the active filter above.': '可供所有订阅配置引用，不受上方配置筛选条件限制。',
		'Source Type': '规则集来源',
		'Remote URL': '远程地址',
		'Inline Rules': '内联规则',
		'Rule Behavior': '匹配行为类型',
		'Domain': '域名（domain）',
		'IP CIDR': 'IP 网段（ipcidr）',
		'Classical': '经典复合规则（classical）',
		'Inline Rule Entries': '内联规则内容',
		'One rule per line without an outbound policy, e.g., DOMAIN-SUFFIX,example.com.': '每行填写一条不含出口策略的规则，例如：DOMAIN-SUFFIX,example.com。',
		'Mihomo URL': 'Mihomo 规则集地址',
		'Mihomo Format': 'Mihomo 规则集格式',
		'Mihomo Download Detour Policy': 'Mihomo 规则集下载策略',
		'Leave empty to use the client default outbound for fetching rule sets.': '指定拉取该远程规则集时使用的代理策略；留空则使用客户端默认下载策略。',
		'Surge URL': 'Surge 规则集地址',
		'Shadowrocket URL (Classical YAML)': 'Shadowrocket 规则集地址（Classical YAML）',
		'URL of a Clash classical YAML rule set with a payload list. Configure this separately; Surge text lists cannot be used here.': '填写包含 payload 列表的 Clash classical YAML 规则集地址，需单独配置，不能使用 Surge 文本规则列表。',
		'URL of a Surge-compatible RULE-SET file.': '填写兼容 Surge RULE-SET / DOMAIN-SET 格式的远程规则地址。',
		'sing-box URL': 'sing-box 规则集地址',
		'sing-box Format': 'sing-box 规则集格式',
		'Content & URLs': '内容与地址',
		'Update Options': '更新策略',
		'Rule Sets': '规则集',
		'All Main & Sub-Rules': '全部主规则与子规则',

		// Settings (settings.js) & Default Region Names
		'Region Matching Templates': '国家与地区匹配模板',
		'Classify nodes into regions by matching node names against flag emojis, region names, or ISO country codes. Per-source rules override the general pattern.': '按节点名称识别国家或地区，支持国旗、中英文名称及国家代码。订阅源专属规则优先于通用规则。',
		'Add Common Regions': '添加常用地区模板',
		'Preview Region Matches': '预览地区匹配结果',
		'General Pattern (Regex)': '通用匹配规则（正则）',
		'Example: 🇯🇵|日本|Japan. Use word-boundary assertions for short country codes to avoid false positives. Patterns must not match empty strings.': '例如：🇯🇵|日本|Japan。短代码建议使用内置模板的边界匹配以避免误判；表达式不可匹配空字符串。',
		'Source Overrides': '订阅源专属覆盖',
		'Use general pattern for all sources': '全部使用通用规则',
		' Override Pattern': ' 专属匹配规则',
		'Leave empty to use the general pattern above. When specified, only this source uses this regular expression.': '留空则沿用上方通用匹配规则；填写后，该订阅源将优先采用此正则表达式。',
		'View Matched Nodes': '查看匹配节点',
		'Download & Integration': '下载与系统集成',
		'Manage published releases, download links, and rollbacks on the Overview page.': '如需管理已发布版本、获取下载链接或执行版本回滚，请前往“状态概览”页面。',
		'Download Access': '下载访问控制',
		'OpenClash & Subconverter': 'OpenClash 与本地转换器',
		'Download Access Mode': '下载访问鉴权方式',
		'LAN + Download Token': '局域网访问 + 下载令牌',
		'Download Token (All Reachable Networks)': '仅校验下载令牌（所有可达网络）',
		'Authenticated LuCI Session Only': '仅限已登录的 LuCI 会话',
		'Changing the access mode does not open firewall ports. Session-only mode does not provide QR codes for third-party clients. Rotate tokens under "Release Management" on the Overview page.': '修改鉴权方式不会开放防火墙端口。“仅限已登录的 LuCI 会话”模式不生成第三方客户端二维码。令牌可在“状态概览 → 版本管理”中重置。',
		'Subscription Base URL': '订阅链接基础地址',
		'Leave empty to use the current router origin.': '留空则默认使用当前访问路由器的协议、主机名与端口。',
		'Auto-Apply to OpenClash on Publish': '发布后自动应用至 OpenClash',
		'Applies only to the profile selected below (disabled by default). When enabled, publishing or rolling back will reload OpenClash.': '仅对下方指定的关联配置生效（默认关闭）。启用后，每次发布或回滚该配置时将自动同步并重载 OpenClash。',
		'Linked OpenClash Profile': 'OpenClash 关联订阅配置',
		'Local Subconverter URL': '本地 subconverter 服务地址',
		'Loopback addresses only. Run compatibility audits from the Advanced tab of a subscription source.': '仅允许填写本机回环地址（127.0.0.1 或 ::1）。可在“订阅源 → 高级选项”中执行兼容性比对。',
		'Region Matching': '地区匹配',
		'Match Preview: ': '匹配预览：',
		'Region Match Preview': '地区匹配预览',
		'Previewed against currently cached node names. If a node matches multiple regions, refine the regular expressions. Name matching does not guarantee the actual egress IP location.': '基于当前缓存的节点名称测试匹配效果。若同一节点命中多个地区，请调整正则表达式；名称匹配仅用于节点归类，不代表实际出口 IP 归属地。',
		' matched nodes': ' 个匹配节点',
		' nodes, ': ' 个节点，未匹配 ',
		' unmatched, ': ' 个，多重匹配 ',
		' ambiguous': ' 个',
		'Original Node Name': '原始节点名称',
		'Matched Regions': '命中地区',
		'Unmatched': '未匹配',
		'Japan': '日本',
		'Hong Kong': '中国香港',
		'Taiwan': '中国台湾',
		'Singapore': '新加坡',
		'United States': '美国',
		'South Korea': '韩国',
		'United Kingdom': '英国',
		'Germany': '德国',
		'Canada': '加拿大',
		'Australia': '澳大利亚',
		'France': '法国',
		'Netherlands': '荷兰',
		'India': '印度',
		'Argentina': '阿根廷',
		'Brazil': '巴西',
		'Russia': '俄罗斯',
		'Türkiye': '土耳其',

		// Backend & CLI Static Error Messages
		'Invalid identifier': '标识符格式无效',
		'Command output exceeds size limit': '命令返回结果超出大小限制',
		'Operation timed out; existing cache and published releases remain unchanged': '操作执行超时，原有缓存与已发布版本保持不变',
		'URL must use HTTP or HTTPS': 'URL 必须使用 HTTP 或 HTTPS 协议',
		'Converter URL must use a loopback address': '转换器地址必须为本机回环地址',
		'Invalid URL format': 'URL 格式无效',
		'Configuration was modified in another session; please reload before saving': '配置已在其他会话中更新，请刷新页面后重新保存',
		'Configuration exceeds the 2 MiB size limit': '配置文件大小超出 2 MiB 限制',
		'Unsupported configuration schema version': '不支持的配置数据结构版本',
		'Quota URL must not contain credentials; use an API token instead': '额度查询地址不得包含用户名或密码，请改用接口令牌参数',
		'Dedicated quota URL must not match the subscription URL': '独立额度查询地址不得与订阅下载地址相同',
		'Quota header query option must be a boolean': '订阅响应头查询开关必须为布尔值',
		'Quota cache TTL must be between 60 and 31536000 seconds': '额度数据有效期须在 60 至 31536000 秒之间',
		'Unsupported update mode': '不支持的更新方式',
		'Scheduled update interval must be at least 300 seconds': '定时更新间隔不得少于 300 秒',
		'Source name exceeds maximum length': '订阅源名称超出长度限制',
		'Missing global settings': '缺少全局设置项',
		'Invalid download access mode': '下载访问鉴权方式无效',
		'Invalid export format': '导出格式无效',
		'Unpublish the profile before deleting it': '删除已发布的订阅配置前，请先执行“停止发布”',
		'Invalid configuration field format': '配置字段格式无效',
		'Subscription source does not exist': '指定的订阅源不存在',
		'Subscription profile does not exist': '指定的订阅配置不存在',
		'Subscription content exceeds 2 MiB': '订阅内容大小超出 2 MiB 限制',
		'Subscription contains no valid nodes; previous cache retained': '订阅内容中未解析到有效节点，已保留上次成功的缓存',
		'Source or cache was updated concurrently; discarding stale fetch result': '订阅源配置或本地缓存已被并发更新，本次拉取结果已丢弃',
		'No subscription URL configured for this source; import a local file instead': '该订阅源尚未配置订阅地址，请填写地址或直接导入本地文件',
		'Subscription source is disabled': '该订阅源已停用',
		'Dedicated quota URL must not match any subscription URL': '独立额度查询地址不得与任何订阅下载地址相同',
		'Invalid User-Agent for quota request': '额度查询请求的 User-Agent 格式无效',
		'Source or quota query settings changed; please retry': '订阅源或额度查询配置已变更，请重新发起查询',
		'No valid Subscription-Userinfo header received; previous quota state retained': '未收到有效的 Subscription-Userinfo 响应头，已保留原有额度信息',
		'No quota query method configured and no local cache available; configure quota query under Subscription Sources': '尚未配置额度查询方式且无可用本地缓存，请在“订阅源 → 流量 / 到期”中配置',
		'Source or quota state was updated concurrently; discarding stale quota result': '订阅源或额度状态已被并发更新，本次查询结果已丢弃',
		'Region preview configuration exceeds size limit': '地区预览配置数据超出大小限制',
		'Region preview requires sources and regions lists': '地区预览请求须包含订阅源与地区模板列表',
		'Invalid source selection for region preview': '地区预览所选的订阅源无效',
		'Invalid JSON in region preview configuration': '地区预览配置中的 JSON 格式无效',
		'Invalid release identifier': '版本标识符无效',
		'Select at least one export format': '请至少选择一种导出格式',
		'Unsupported export format': '不支持的导出格式',
		'Release does not exist': '指定的构建版本不存在',
		'Rollback is only allowed for previously published releases': '仅可回滚至历史已发布过的版本',
		'Draft configuration or source cache has changed; please rebuild before publishing': '配置草稿或订阅源缓存已发生变更，请重新构建后再发布',
		'Please confirm all compatibility differences before publishing': '发布前请先勾选确认所有兼容性差异',
		'Release artifact integrity check failed': '构建产物完整性校验失败',
		'Build and publish this profile first': '请先构建并发布该订阅配置',
		'Invalid job identifier': '任务标识符无效',
		'Background job terminated or timed out; please resubmit': '后台任务已异常终止或执行超时，请重新提交',
		'Invalid operation': '无效的操作请求',
		'Profile has not been published': '该订阅配置尚未发布',
		'Release does not belong to this profile': '指定的构建版本不属于该订阅配置',
		'Failed to start background job; please try again later': '无法启动后台任务进程，请稍后重试',
		'Job does not exist': '指定的任务不存在',
		'Job has expired; please resubmit': '任务已过期，请重新提交',
		'No cached nodes available for this source': '该订阅源尚无可用的本地节点缓存',
		'Job is missing a target release': '任务缺少目标发布版本参数',
		'Release does not include Mihomo output': '该发布版本未包含 Mihomo 格式产物',
		'Unknown operation': '未知的操作指令',
		'Unknown command': '未知的命令参数',
		'Invalid request payload or backend state; please check the configuration': '请求参数格式或后台状态异常，请检查当前配置',

		// Engine / Regions / Converter / OpenClash Static Messages
		'Configuration must contain JSON-compatible values': '配置内容必须为合法的 JSON 数据类型',
		'Source exceeds 2 MiB': '订阅源内容超出 2 MiB 限制',
		'Source is not valid UTF-8': '订阅源内容不是有效的 UTF-8 编码',
		'Source is empty': '订阅源内容为空',
		'Unknown source format': '未知的订阅源格式',
		'Encoded source does not contain supported node links': 'Base64 解码后的内容未包含受支持的节点链接',
		'Expected a Mihomo proxy list, Surge/Shadowrocket [Proxy], sing-box outbounds, or supported node links': '订阅格式无法识别：须为 Mihomo proxies 列表、Surge / Shadowrocket [Proxy] 段落、sing-box outbounds 或受支持的节点分享链接',
		'Source has no proxy nodes': '订阅源中未包含任何代理节点',
		'Source has too many nodes (maximum 4096)': '订阅源节点数量超出上限（最多 4096 个）',
		'Invalid or unsafe YAML source (aliases and object tags are disabled)': 'YAML 格式无效或包含受限语法（已禁用别名引用与自定义对象标签）',
		'Malformed subscription; check its format and encoding': '订阅内容解析失败，请检查订阅格式与字符编码',
		'Profile must select at least one output format': '订阅配置必须至少选择一种导出格式',
		'Unknown output format': '未知的导出格式',
		'Unknown profile': '未找到指定的订阅配置',
		'Configuration and caches must be objects': '配置与缓存数据必须为对象结构',
		'Profile contains duplicate sources or formats': '订阅配置中包含重复的订阅源或导出格式',
		'Unknown profile format': '订阅配置包含未知的导出格式',
		'Profile has no nodes': '当前订阅配置下无可用节点',
		'Regular expression exceeded its time limit': '正则表达式匹配超时',
		'Mihomo DNS must be an object': 'Mihomo DNS 配置必须为 JSON 对象',
		'Mihomo DNS contains unsupported settings (listeners are managed separately)': 'Mihomo DNS 包含不支持的字段（监听地址等运行参数由路由器管理）',
		'Mihomo policy must be an object': 'Mihomo 高级策略必须为 JSON 对象',
		'Mihomo policy contains unsupported settings (API, listener and router bindings are excluded)': 'Mihomo 高级策略包含不支持的字段（不可填写控制器、监听端口或网卡绑定等运行参数）',
		'Mihomo policy geox-url contains unsupported databases': 'Mihomo geox-url 包含不受支持的数据库键名（仅支持 geoip、geosite、mmdb、asn）',
		'Mihomo profile policy supports only store-selected/store-fake-ip': 'Mihomo profile 策略仅支持 store-selected 与 store-fake-ip 选项',
		'Mihomo geodata-loader must be standard or memconservative': 'Mihomo geodata-loader 仅支持 standard 或 memconservative',
		'Mihomo-specific runtime and geodata policy has no equivalent export here and will be omitted': 'Mihomo 专属运行参数与地理数据库策略在当前目标格式中无对应实现，导出时将被忽略',
		'Surge field contains a line break or NUL': 'Surge 字段内容包含非法换行符或空字符',
		'Surge built-in LAN and Mihomo GEOIP LAN may cover different reserved ranges': 'Surge 内置 LAN 规则集与 Mihomo GEOIP,LAN 覆盖的保留网段范围可能存在细微差异',
		'Bandwidth must be Mbps or a number followed by Mbps': '带宽参数须为纯数字（Mbps）或带 Mbps 单位的数值',
		'Target bandwidth must be a whole number of Mbps': '目标客户端要求带宽参数必须为整数 Mbps',
		'sing-box ip_is_private and Mihomo GEOIP LAN do not cover exactly the same reserved ranges': 'sing-box 的 ip_is_private 与 Mihomo 的 GEOIP,LAN 覆盖的私有网段范围不完全一致',
		'Region matching needs valid, unique source IDs': '地区匹配器要求提供有效且唯一的订阅源标识符列表',
		'Regions must be a list of at most 128 objects': '地区模板列表最多包含 128 个条目',
		'Region has an invalid ID': '地区模板标识符格式无效',
		'Region preview needs at most 4096 node names': '地区预览单次最多处理 4096 个节点名称',
		'Region matching accepts only valid node names': '地区匹配仅接受合法的节点名称',
		'Region regular expression exceeded its time limit': '地区匹配正则表达式执行超时',
		'Converter must use an HTTP(S) loopback URL without credentials or query parameters': '本地转换器必须使用不含凭据与查询参数的 HTTP(S) 本机回环地址',
		'Invalid local converter URL': '本地转换器地址格式无效',
		'Converter audit requires a non-empty node list': '转换器兼容性比对需要非空的节点列表',
		'Converter audit input exceeds 2 MiB': '转换器比对输入数据超出 2 MiB 限制',
		'Converter did not return a proxy list': '本地转换器未返回有效的代理节点列表',
		'Converter returned invalid or unsafe YAML': '本地转换器返回了无效或受限的 YAML 内容',
		'Local converter audit transport failed': '本地转换器通信失败',
		'Local converter request timed out': '本地转换器请求超时',
		'Converter response exceeds its size limit': '本地转换器响应内容超出大小限制',
		'Local converter request failed': '本地转换器请求失败',
		'curl is required for the local converter audit': '执行本地转换器比对需要安装 curl',
		'Could not read the existing OpenClash subscriptions.': '无法读取现有的 OpenClash 订阅配置。',
		'Mihomo core is not installed.': '未检测到已安装的 Mihomo 内核。',
		'Exported configuration is missing or too large.': '导出的配置文件缺失或超出大小限制。',
		'The export is not a Mihomo configuration.': '导出内容不是有效的 Mihomo 配置结构。',
		'Invalid YAML configuration.': 'YAML 配置文件格式无效。',
		'Invalid profile ID.': '订阅配置标识符无效。',
		'OpenClash is not installed.': '系统未安装 OpenClash 或缺少 Mihomo 内核。',
		'Profile does not exist.': '指定的订阅配置不存在。',
		'The release is not a Mihomo configuration.': '该发布版本不是有效的 Mihomo 配置文件。',
		'This release requires the Smart core. Install it in OpenClash before applying.': '当前版本使用了 Smart 策略组，请先在 OpenClash 中安装 Smart 内核后再应用。',
		'An OpenClash apply operation is already running.': '已有另一个 OpenClash 应用任务正在执行，请稍后再试。',
		'Apply exceeded its rollback deadline.': '配置应用超时，已触发回滚保护阈值。',
		'Apply failed and automatic recovery failed. Use the saved OpenClash backup in the integration backup directory.': '应用配置失败且自动回滚异常，请使用备份目录中的 OpenClash 备份文件手动恢复。',
		'Apply failed. Previous OpenClash configuration restored.': '应用配置失败，已自动恢复原有的 OpenClash 配置。',
		'This export requires the installed Mihomo Smart core.': '该导出配置需要系统安装 Mihomo Smart 内核。',
		'Required geodata is missing; update it in OpenClash before validating this profile.': '缺少所需的 GeoIP / GeoSite 数据库文件，请先在 OpenClash 中更新地理数据库后再校验。',
		'A local provider cache is missing. Import its contents before publishing.': '缺少本地规则集或节点提供者缓存文件，请先导入对应内容后再发布。',
		'An OpenClash command timed out.': 'OpenClash 命令执行超时。',
		'An OpenClash command failed.': 'OpenClash 命令执行失败。',
		'An OpenClash helper is unavailable.': 'OpenClash 辅助命令不可用。',
		'Could not read OpenClash settings.': '无法读取 OpenClash UCI 配置。',
		'An OpenClash subscription changed. Re-import it before taking over updates.': 'OpenClash 订阅源地址已发生变更，请重新导入后再启用更新接管。',
		'OpenClash did not load the published policy.': 'OpenClash 未能成功加载已发布的策略配置。'
	},
	patterns: [
		[/^shadowrocket: (.+)$/, function(_, detail) { return 'Shadowrocket：' + translateMessage(detail); }],
		[/^Group (.+): this exporter has no verified Shadowrocket mapping for mode (.+); explicitly choose a manual or simpler automatic alternative$/, '策略组 $1：当前转换器尚未验证 Shadowrocket 的 $2 模式映射，请改为手动选择或受支持的基础自动模式'],
		[/^Group (.+): unsupported Shadowrocket type; choose select, url-test, fallback or load-balance$/, '策略组 $1：当前转换器支持的 Shadowrocket 模式为手动选择、延迟测速、故障转移和负载均衡'],
		[/^(.+): (Trojan requires TLS|conflicting TLS server names|TLS options require enabled TLS)$/, function(_, name, detail) { return '节点 ' + name + '：' + translateSingle(detail); }],
		[/^(.+): this exporter has no verified Shadowrocket mapping for the hidden group flag; it will be omitted$/, '策略组 $1：当前转换器尚未验证 Shadowrocket 隐藏策略组标记的映射，导出时将被忽略'],
		[/^(\d+) nodes contain advanced fields whose Shadowrocket behavior needs review: (.+)\. These fields are retained\.$/, '$1 个节点的高级字段需确认 Shadowrocket 支持情况：$2。字段已保留。'],
		[/^(.+): (Reality requires VLESS or VMess|Reality requires enabled TLS|this protocol requires TLS|conflicting VMess AEAD settings|unsupported VMess cipher|conflicting fast\-open settings|conflicting AnyTLS reuse settings|conflicting certificate fingerprints|unsupported v2ray\-plugin mode|conflicting plugin certificate verification settings|transport options must be an object|HTTP headers must be an object|multiple HTTP\/2 paths cannot be represented|HTTP\/2 headers must be an object|conflicting HTTP\/2 hosts|WebSocket path must be text|HTTP Upgrade early data requires an explicit transport mapping|conflicting WebSocket early data limits|invalid transport URL encoding)$/, function(_, name, detail) { return '节点 ' + name + '：' + translateSingle(detail); }],
		[/^(.+): (dialer-proxy|underlying-proxy) requires an explicit policy reference mapping$/, '节点 $1：$2 需要明确的策略引用映射'],
		[/^(.+): (reuse|disable-reuse|fast-open|aead) must be boolean$/, '节点 $1：$2 必须为布尔值'],
		[/^Shadowrocket source option (.+) has no verified import mapping$/, '当前转换器尚未提供经核实的 Shadowrocket 源选项 $1 导入映射'],
		[/^Update compatible draft (.+) \((.+)\) from its saved source; preserve published releases and download links$/, '根据来源配置更新兼容草稿“$1”（$2）；保留已发布版本和订阅链接'],
		[/^(Add|Remove|Replace) target (profile|groups|rematches|sub_rules|rules|rule_sets) (.+) \((.+)\)(?:; changed fields: (.+))?$/, function(_, action, kind, name, id, fields) {
			const actions = { Add: '添加', Remove: '移除', Replace: '更新' };
			const kinds = { profile: '配置', groups: '策略组', rematches: '重匹配项', sub_rules: '子规则', rules: '分流规则', rule_sets: '规则集' };
			const labels = { name: '名称', sources: '订阅源', formats: '导出格式', final_policy: '兜底策略', mihomo_core: 'Mihomo 内核', mihomo_dns: 'DNS 策略', mihomo_policy: '高级策略', members: '候选策略', default_member: '默认策略', empty_fallback: '空组回退策略', region: '地区', filter: '筛选条件', exclude_filter: '排除条件', mihomo_type: 'Mihomo 模式', surge_type: 'Surge 模式', singbox_type: 'sing-box 模式', shadowrocket_type: 'Shadowrocket 模式', shadowrocket_url: 'Shadowrocket 规则集地址', url: '测速地址', interval: '间隔', tolerance: '容差', type: '规则类型', value: '匹配内容', policy: '出口策略', conditions: '匹配条件', sub_rule: '所属子规则', enabled: '启用状态', no_resolve: '跳过解析', target_sub_rule: '目标子规则', rematch_name: '重匹配名称', mihomo_proxy: '下载策略', inline_rules: '内联规则', source_type: '来源类型', behavior: '规则集类型' };
			return actions[action] + '兼容草稿中的' + kinds[kind] + '“' + name + '”（' + id + '）' + (fields ? '；变更字段：' + fields.split(', ').map(function(field) { return labels[field] || field; }).join('、') : '');
		}],
		[/^Update the order of target (groups|rematches|sub_rules|rules|rule_sets)$/, function(_, kind) {
			return '调整兼容草稿中的' + ({ groups: '策略组', rematches: '重匹配项', sub_rules: '子规则', rules: '分流规则', rule_sets: '规则集' })[kind] + '顺序';
		}],
		[/^Change group (.+) \((.+)\) for (.+): (.+) -> (.+) \(Mihomo reference: (.+)\); (.+)$/, function(_, name, id, target, before, after, baseline, detail) {
			return '将策略组“' + name + '”（' + id + '）在 ' + target + ' 中的模式从 ' + before + ' 改为 ' + after + '（Mihomo 参考模式：' + baseline + '）；' + translateMessage(detail);
		}],
		[/^Replace rematch (.+) \((.+)\) with (manual|url-test) group; candidates: (.+?); (.+)$/, function(_, name, id, mode, candidates, detail) {
			return '将重匹配项“' + name + '”（' + id + '）替换为' + (mode === 'manual' ? '手动选择组' : '延迟测速组') + '；候选策略：' + candidates + '；' + translateMessage(detail);
		}],
		[/^Group (.+): (.+) does not support (.+); explicitly choose a manual or simpler automatic alternative$/, '策略组 $1：$2 不支持 $3 模式，请改为手动选择或受支持的基础自动模式'],
		[/^Group (.+): Smart requires the Mihomo Smart core; a manual or simpler automatic mode is an alternative, not equivalent behavior$/, '策略组 $1：Smart 模式需要 Mihomo Smart 内核；可改为手动选择或基础自动模式（行为并非完全等价）'],
		[/^Group (.+): (.+) mode (.+) differs from or cannot guarantee Mihomo (.+) behavior; review a manual or simpler automatic alternative$/, '策略组 $1：$2 的 $3 模式与 Mihomo 的 $4 模式行为存在差异，请确认是否调整为手动选择或基础自动模式'],
		[/^(.+): sing-box manual selection requires client selection controls or its API; otherwise the first candidate is used$/, '$1：sing-box 手动选择需要客户端切换界面或 API，否则将使用第一个候选策略'],
		[/^(.+): Surge uses native test URL settings and does not preserve this per-group health-check URL$/, '$1：Surge 使用原生测速地址设置，无法保留该策略组单独配置的健康检查地址'],
		[/^Create independent (.+) profile (.+) \((.+)\); preserve the original profile and its export formats$/, '创建独立的 $1 配置“$2”（$3），保留原配置及其导出格式'],
		[/^Replace rematch (.+) with policy (.+); regional re-evaluation is no longer performed in the compatible draft$/, '将重匹配项 $1 替换为策略 $2；兼容草稿将不再执行该地区二次匹配'],
		[/^Omit sub-rule (.+) \((.+)\) and its (\d+) scoped rules from the compatible draft$/, '从兼容草稿中移除子规则“$1”（$2）及其 $3 条内部规则'],
		[/^Omit scoped rule (.+) \((.+), (.+)\) from sub-rule (.+) in the compatible draft$/, '从兼容草稿的子规则 $4 中移除规则“$1”（$2，$3）'],
		[/^Disable rule (.+) \((.+)\) in the compatible draft; matching traffic will follow later rules or the final policy$/, '在兼容草稿中停用规则 $1（$2）；对应流量将继续匹配后续规则或使用兜底策略'],
		[/^Replace rematch (.+) with policy (.+); regional re-evaluation is no longer performed in the new profile$/, '将重匹配项 $1 替换为策略 $2；新配置将不再执行该地区二次匹配'],
		[/^Omit sub-rule (.+) \((.+)\) and its (\d+) scoped rules from the new profile$/, '从新配置中移除子规则“$1”（$2）及其 $3 条内部规则'],
		[/^Omit scoped rule (.+) \((.+), (.+)\) from sub-rule (.+) in the new profile$/, '从新配置的子规则 $4 中移除规则“$1”（$2，$3）'],
		[/^Disable rule (.+) \((.+)\) in the new profile; matching traffic will follow later rules or the final policy$/, '在新配置中停用规则 $1（$2）；对应流量将继续匹配后续规则或使用兜底策略'],
		[/^Copy rule set (.+) to preserve its reference to the independent profile's download policy$/, '为独立配置创建规则集 $1 的副本，以同步绑定新配置中的规则集下载策略'],
		[/^(.+) requires a native replacement rule$/, '$1 需要手动配置目标客户端的替代规则'],
		[/^Rule set (.+) needs a (.+) URL$/, '规则集 $1 需要填写 $2 格式的规则地址'],
		[/^(.+) exceeds the 5000 item limit$/, '$1 的条目数超过 5000 条上限'],
		[/^(.+): Mihomo no-resolve has no equivalent sing-box rule flag; use a separate compatible rule$/, '$1：Mihomo 的 no-resolve 在 sing-box 中没有等价规则标记，请配置独立的兼容规则'],
		[/^(.+): sing-box inline rule sets do not support GEOIP LAN; use explicit IP-CIDR ranges$/, '$1：sing-box 内联规则集不支持 GEOIP LAN，请使用明确的 IP-CIDR 网段'],
		[/^(.+): sing-box IP matching does not automatically resolve destination domains; review the native DNS and resolve routing before relying on IP rules$/, '$1：sing-box 匹配 IP 规则时不会自动解析目标域名，请先检查 DNS 与域名解析分流设置'],
		[/^Subscription request failed \(HTTP (\d{3})\); cached nodes were kept$/, '订阅请求失败（HTTP $1），已保留节点缓存'],
		[/^Command failed \((.+)\)$/, '命令执行失败（$1）'],
		[/^([a-z_]+) must be a list$/, '配置项 $1 必须为列表'],
		[/^([a-z_]+) contains duplicate identifiers$/, '配置项 $1 存在重复的标识符'],
		[/^([a-z_]+) must be an array$/, '配置项 $1 必须为数组'],
		[/^([a-z_]+): invalid ID$/, '$1：标识符格式无效'],
		[/^([a-z_]+): duplicate ID (.+)$/, '$1：存在重复的标识符 $2'],
		[/^Unknown source (.+) for region matching$/, '地区匹配引用了未知的订阅源 $1'],
		[/^Unknown source (.+)$/, '引用了未知的订阅源：$1'],
		[/^Source (.+) is disabled$/, '订阅源 $1 处于停用状态'],
		[/^Source (.+) has no valid cached nodes$/, '订阅源 $1 尚无有效的本地缓存节点'],
		[/^Source (.+) has no nodes after filtering$/, '订阅源 $1 在过滤后无剩余可用节点'],
		[/^Source contains duplicate node names at node (\d+)$/, '订阅源在第 $1 个节点处存在重复的节点名称'],
		[/^Node (\d+) must be an object$/, '第 $1 个节点必须为对象结构'],
		[/^(?:Source (.+), node (\d+)|Node (\d+)): (.+)$/, function(_, src, n1, n2, detail) {
			const prefix = src ? '订阅源 ' + src + ' 第 ' + n1 + ' 个节点：' : '第 ' + n2 + ' 个节点：';
			return prefix + translateSingle(detail);
		}],
		[/^node must be an object$/, '节点数据必须为对象结构'],
		[/^property names must be strings$/, '节点属性名必须为字符串'],
		[/^unsupported proxy protocol$/, '不支持的代理协议类型'],
		[/^missing or invalid name$/, '缺少节点名称或名称格式无效'],
		[/^missing or invalid server$/, '缺少服务器地址或地址格式无效'],
		[/^port must be 1–65535$/, '端口号必须为 1–65535 之间的整数'],
		[/^missing (.+)$/, '缺少必填字段 $1'],
		[/^invalid UUID$/, 'UUID 格式无效'],
		[/^ALPN must be an array of strings$/, 'ALPN 必须为字符串数组'],
		[/^(.+) must be a string without line breaks$/, '字段 $1 必须为不含换行符的字符串'],
		[/^(.+) must be a non-negative integer$/, '字段 $1 必须为非负整数'],
		[/^(.+) must be boolean$/, '字段 $1 必须为布尔值'],
		[/^Duplicate policy name (.+)$/, '策略或节点名称重复：$1'],
		[/^Duplicate group\/rematch ID (.+)$/, '策略组与重匹配项标识符冲突：$1'],
		[/^Duplicate sub-rule name (.+)$/, '子规则名称重复：$1'],
		[/^Duplicate region ID (.+)$/, '地区模板标识符重复：$1'],
		[/^Unknown region (.+)$/, '未知的地区模板：$1'],
		[/^Region (.+): invalid name$/, '地区模板 $1：名称无效'],
		[/^Region (.+): unsupported fields$/, '地区模板 $1：包含不受支持的字段'],
		[/^Region (.+): source overrides must refer to existing source IDs$/, '地区模板 $1：订阅源专属规则引用了不存在的订阅源标识符'],
		[/^(.+): pattern must contain 1–512 characters without line breaks$/, '$1：正则表达式长度须为 1–512 个字符且不可包含换行'],
		[/^(.+): pattern must not match an empty name$/, '$1：正则表达式不可匹配空字符串'],
		[/^(.+): invalid regular expression$/, '$1：正则表达式语法无效'],
		[/^(.+): filter must be a string of at most 512 characters$/, '$1：过滤表达式长度不得超过 512 个字符'],
		[/^Group (.+) uses a source outside this profile$/, '策略组 $1 引用了未包含在当前订阅配置中的订阅源'],
		[/^Group (.+) has duplicate members or sources$/, '策略组 $1 包含重复的成员或订阅源引用'],
		[/^Group (.+): names cannot contain commas$/, '策略组 $1：名称不得包含逗号'],
		[/^Group (.+): region must be an ID or empty$/, '策略组 $1：地区模板字段无效'],
		[/^Group (.+): unknown region (.+)$/, '策略组 $1：引用了不存在的地区模板 $2'],
		[/^Group (.+) has no members after filtering$/, '策略组 $1 在筛选后无可用节点或成员'],
		[/^Group (.+): default member is not a member$/, '策略组 $1：默认选中项不在该策略组的成员列表中'],
		[/^Group (.+): lazy must be boolean$/, '策略组 $1：按需测试（lazy）必须为布尔值'],
		[/^Group (.+): unsupported Mihomo type$/, '策略组 $1：不支持的 Mihomo 策略组类型'],
		[/^Group (.+): Smart requires the Mihomo Smart core$/, '策略组 $1：使用 Smart 策略组需将 Mihomo 内核版本设为 Mihomo Smart'],
		[/^Group (.+): unsupported Surge type$/, '策略组 $1：不支持的 Surge 策略组类型'],
		[/^Group (.+): Surge Smart accepts only nodes, not groups or DIRECT\/REJECT$/, '策略组 $1：Surge 的 Smart 策略组仅支持直接包含节点，不支持嵌套策略组或 DIRECT / REJECT'],
		[/^Group (.+): sing-box supports selector or urltest$/, '策略组 $1：sing-box 仅支持 selector 或 urltest 策略组类型'],
		[/^Group (.+): sing-box cannot put REJECT in an outbound group$/, '策略组 $1：sing-box 策略组成员中不支持包含 REJECT'],
		[/^Rematch (.+): names cannot contain commas$/, '重匹配项 $1：名称不得包含逗号'],
		[/^Rematch (.+): missing sub-rule reference$/, '重匹配项 $1：引用了不存在的目标子规则'],
		[/^Rematch (.+): matching name contains a rule delimiter$/, '重匹配项 $1：重匹配标记包含非法的分隔符'],
		[/^Sub-rule (.+): name contains a rule delimiter$/, '子规则 $1：名称包含非法的分隔符'],
		[/^Missing policy reference (.+)$/, '引用了不存在的策略组或重匹配项：$1'],
		[/^Policy group\/sub-rule cycle at (.+)$/, '策略组或子规则存在循环引用（位于 $1）'],
		[/^Rule (.+): missing sub-rule scope$/, '分流规则 $1：引用了不存在的所属子规则'],
		[/^Rule (.+): condition must be an object$/, '分流规则 $1：条件结构必须为对象'],
		[/^Rule (.+): condition nesting exceeds 8 levels$/, '分流规则 $1：逻辑条件嵌套层级超过 8 层上限'],
		[/^Rule (.+): unsupported rule type$/, '分流规则 $1：不支持的规则类型'],
		[/^Rule (.+): NOT needs one condition; AND\/OR need 2–64 conditions$/, '分流规则 $1：NOT 规则须恰好包含 1 个子条件，AND / OR 规则须包含 2–64 个子条件'],
		[/^Rule (.+): logical rule cannot have a value or no-resolve$/, '分流规则 $1：逻辑组合规则不可直接填写匹配值或启用 no-resolve'],
		[/^Rule (.+): nested condition cannot contain policy or scope$/, '分流规则 $1：嵌套子条件中不可包含出口策略或规则域字段'],
		[/^Rule (.+): leaf rule cannot have conditions$/, '分流规则 $1：普通匹配规则不可包含嵌套条件列表'],
		[/^Rule (.+): invalid value$/, '分流规则 $1：匹配值格式无效'],
		[/^Rule (.+): invalid IP prefix$/, '分流规则 $1：IP 网段（CIDR）格式无效'],
		[/^Rule (.+): invalid domain$/, '分流规则 $1：域名格式无效'],
		[/^Rule (.+): GEOIP must be a country code or LAN$/, '分流规则 $1：GEOIP 匹配值须为两位国家代码或 LAN'],
		[/^Rule (.+): invalid GEOSITE category$/, '分流规则 $1：GEOSITE 分类名格式无效'],
		[/^Rule (.+): REMATCH-NAME is only valid inside a sub-rule$/, '分流规则 $1：REMATCH-NAME 仅可在子规则内使用'],
		[/^Rule (.+): missing rule set$/, '分流规则 $1：引用了不存在的规则集'],
		[/^Rule (.+): port must be 1–65535$/, '分流规则 $1：端口号必须为 1–65535 之间的整数'],
		[/^Rule (.+): network must be TCP or UDP$/, '分流规则 $1：NETWORK 匹配值必须为 TCP 或 UDP'],
		[/^Rule (.+): no-resolve is not valid for this rule type$/, '分流规则 $1：当前规则类型不支持 no-resolve 标记'],
		[/^Rule (.+): sing-box 1\.12 removed GEOIP; select a native sing-box rule set instead$/, '分流规则 $1：sing-box 1.12+ 已移除内置 GEOIP 数据库，请改用原生规则集（RULE-SET）'],
		[/^Rule set (.+): inline rules must be text \(maximum 512 KiB\)$/, '规则集 $1：内联规则内容必须为文本且不超过 512 KiB'],
		[/^Rule set (.+): inline rule set is empty$/, '规则集 $1：内联规则内容不能为空'],
		[/^Rule set (.+): inline rules cannot contain policies or logical expressions$/, '规则集 $1：内联规则条目不可包含出口策略或逻辑组合表达式'],
		[/^Rule set (.+): invalid source type$/, '规则集 $1：规则集来源类型无效'],
		[/^Rule set (.+): inline rules require classical behavior$/, '规则集 $1：内联规则集必须将匹配行为类型设为经典复合规则（classical）'],
		[/^Rule set (.+): invalid Mihomo behavior or format$/, '规则集 $1：Mihomo 匹配行为类型或格式无效'],
		[/^Rule set (.+): MRS cannot contain classical rules$/, '规则集 $1：MRS 二进制格式不支持 classical 复合规则类型'],
		[/^Rule set (.+): sing-box format must be source or binary$/, '规则集 $1：sing-box 规则集格式必须为 source 或 binary'],
		[/^Rule set (.+): Mihomo download proxy selection is not preserved in (.+)$/, '规则集 $1：Mihomo 规则集下载代理策略在 $2 格式中不受支持，导出时将被忽略'],
		[/^Mihomo DNS references missing rule set (.+)$/, 'Mihomo DNS 配置引用了不存在的规则集 $1'],
		[/^(.+): this profile requires (.+); create a separate compatible profile instead of discarding these policies$/, '$1 格式不支持当前配置所使用的特性（$2）；为避免策略被静默丢弃，请为该客户端创建独立的兼容配置'],
		[/^(.+): Mihomo (.+) is not preserved in (.+)$/, '策略组 $1：Mihomo 专属选项 $2 在 $3 格式中不受支持，导出时将被忽略'],
		[/^(.+): sing-box does not preserve the hidden group flag$/, '策略组 $1：sing-box 不支持隐藏策略组（hidden）标记，导出时将被忽略'],
		[/^(.+): this Surge protocol always supports UDP; source udp=false is not preserved$/, '节点 $1：该协议在 Surge 中默认启用 UDP 转发，原节点的 udp=false 设置无法保留'],
		[/^(.+): (.+) cannot be represented in (.+) and will be omitted$/, '节点 $1：字段 $2 在 $3 格式中无对应实现，导出时将被忽略'],
		[/^(.+): Surge does not support (.+)$/, '节点 $1：Surge 不支持 $2 协议'],
		[/^(.+): HTTP\(S\) URL required$/, '$1：必须填写有效的 HTTP 或 HTTPS 地址'],
		[/^(.+): invalid URL$/, '$1：URL 格式无效'],
		[/^(.+) Previous OpenClash configuration restored\.$/, '$1 已自动恢复原有的 OpenClash 配置。']
	]
});

if (typeof window === 'object' && window && typeof window._ === 'function' && !window._.__hsWrapped) {
	const wrapped = function(value) { return t(value); };
	wrapped.__hsWrapped = true;
	window._ = wrapped;
}

if (typeof _ !== 'undefined') _ = t;

const fields = {
	status: [], get_config: [], source_urls: ['source'], save_config: ['config', 'version', 'collections'],
	refresh: ['source'], import_source: ['source', 'content'], import_openclash: [], compare_converter: ['source'],
	refresh_quota: ['source'], region_defaults: [], preview_regions: ['config', 'sources'],
	validate: ['profile'], preview: ['profile', 'format'], build: ['profile'],
	compatibility: ['profile', 'review'],
	compatibility_plan: ['profile', 'format', 'id', 'name', 'resolutions', 'operation'],
	compatibility_create: ['profile', 'format', 'id', 'name', 'resolutions', 'version', 'plan_token', 'accepted_changes'],
	compatibility_update: ['profile', 'format', 'id', 'name', 'resolutions', 'version', 'plan_token', 'accepted_changes'],
	publish: ['release', 'accepted_warnings'], rollback: ['release'],
	unpublish: ['profile'],
	download_info: ['profile'], rotate_token: ['profile'], apply_openclash: ['profile'],
	job_status: ['job']
};
const calls = {};
Object.keys(fields).forEach(function(method) {
	calls[method] = rpc.declare({ object: 'luci.hybrid_subscription', method: method, params: fields[method], expect: { '': {} } });
});
const booleanFields = ['enabled', 'takeover', 'hidden', 'no_resolve', 'lazy', 'openclash_auto_apply', 'clear_quota_url', 'quota_via_subscription'];
const numberFields = ['interval', 'tolerance', 'quota_max_age'];
const listFields = ['sources', 'formats', 'members'];

function clean(row) {
	const result = {};
	Object.keys(row).filter(function(k) { return k.charAt(0) !== '.' && k.charAt(0) !== '_' && k !== 'has_url' && k !== 'has_quota_url'; }).forEach(function(k) {
		let value = row[k];
		if (booleanFields.indexOf(k) >= 0)
			value = value === true || value === '1' || value === 1;
		if (numberFields.indexOf(k) >= 0 && value !== '')
			value = Number(value);
		if (listFields.indexOf(k) >= 0)
			value = Array.isArray(value) ? value : (value ? [value] : []);
		result[k] = value;
	});
	if (row['.type'] === 'rules' || ('profile' in result && 'policy' in result && 'type' in result)) {
		if (['AND', 'OR', 'NOT'].indexOf(result.type) >= 0) {
			delete result.value;
			delete result.no_resolve;
		} else {
			delete result.conditions;
		}
	}
	return result;
}

function api(method, args) {
	return calls[method].apply(null, fields[method].map(function(k) { return (args || {})[k]; })).then(function(result) {
		if (!result || result.ok !== true)
			throw new Error(translateMessage((result && result.error) || _('The router did not return a valid response. Please check the backend service and permissions.')));
		return result;
	});
}

function notify(error) {
	const raw = error && error.message ? error.message : String(error);
	ui.addNotification(null, E('p', {}, translateMessage(raw)), 'error');
}

function button(label, action, style, writes) {
	return E('button', {
		'class': 'cbi-button ' + (style || 'cbi-button-action'),
		'disabled': writes && !L.hasViewPermission() ? true : null,
		'click': function(event) {
			event.preventDefault();
			const node = event.currentTarget;
			node.disabled = true;
			return Promise.resolve().then(action).catch(notify).finally(function() { node.disabled = false; });
		}
	}, label);
}

function time(value) {
	if (!value) return _('Unknown');
	const date = new Date(typeof value === 'number' ? value * 1000 : value);
	return isNaN(date.getTime()) ? String(value) : date.toLocaleString();
}

function table(headers, rows, empty) {
	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, headers.map(function(h) { return E('th', { 'class': 'th' }, h); })),
	].concat(rows.length ? rows.map(function(row) {
		return E('tr', { 'class': 'tr' }, row.map(function(cell) { return E('td', { 'class': 'td' }, cell == null ? '—' : cell); }));
	}) : [E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', 'colspan': headers.length }, empty || _('No records')))]));
}

function report(title, result) {
	const errors = result.errors || [], warnings = result.warnings || [];
	ui.showModal(title, [
		E('p', {}, errors.length ? _('Validation found %s error(s).').format(errors.length) : _('Validation passed with no blocking errors.')),
		E('ul', {}, errors.map(function(e) { return E('li', {}, translateMessage(typeof e === 'string' ? e : e.message || JSON.stringify(e))); })),
		E('ul', {}, warnings.map(function(w) { return E('li', {}, '[' + (w.target || w.code || '') + '] ' + translateMessage(w.message || String(w))); })),
		result.summary ? E('pre', {}, JSON.stringify(result.summary, null, 2)) : E('span'),
		E('div', { 'class': 'right' }, button(_('Close'), ui.hideModal))
	]);
}

function waitJob(id, label) {
	const statusNode = E('p', {}, _('Job submitted. Waiting for completion…'));
	ui.showModal(label, [statusNode, E('p', {}, _('Refreshing the page will not cancel the background job.'))]);
	return new Promise(function(resolve, reject) {
		let started = Date.now(), checking = false;
		const check = function() {
			if (checking) return Promise.resolve();
			checking = true;
			return api('job_status', { job: id }).then(function(result) {
				const job = result.job || {};
				const stateLabels = { queued: _('Queued'), running: _('Running'), completed: _('Completed'), failed: _('Failed') };
				statusNode.textContent = translateMessage(job.message) || stateLabels[job.state] || job.state || _('Processing…');
				if (['completed', 'complete', 'done', 'success', 'succeeded'].indexOf(job.state) >= 0) {
					poll.remove(check); ui.hideModal(); resolve(job);
				} else if (['failed', 'error', 'cancelled'].indexOf(job.state) >= 0) {
					poll.remove(check); ui.hideModal(); reject(new Error(translateMessage(job.error) || _('Job failed.')));
				} else if (Date.now() - started > 600000) {
					poll.remove(check); ui.hideModal(); reject(new Error(_('The job is still running in the background. Check the Overview page for its status.')));
				}
			}).catch(function(error) {
				poll.remove(check); ui.hideModal(); reject(error);
			}).finally(function() { checking = false; });
		};
		poll.add(check, 2);
		check();
	});
}

function runJob(method, args, label) {
	return api(method, args).then(function(result) {
		if (!result.job) throw new Error(_('The backend did not return a job identifier.'));
		return waitJob(result.job, label);
	});
}

function sourceUpdateSummary(changes) {
	if (!changes) return '';
	const summary = changes.initial ? _('Initial cache') : !changes.changed ? _('Nodes unchanged') :
		_('Added %s · removed %s · modified %s').format(changes.added, changes.removed, changes.updated);
	return summary + (changes.order_changed ? ' · ' + _('Node order changed') : '');
}

function sourceUpdateResult(source, result) {
	const changes = result.changes || {}, profiles = result.affected_profiles || [];
	const content = [
		E('p', {}, E('strong', {}, sourceUpdateSummary(result.changes))),
		E('p', {}, _('Nodes: %s → %s.').format(changes.before_nodes == null ? '—' : changes.before_nodes, changes.after_nodes == null ? result.nodes : changes.after_nodes)),
		E('p', {}, _('Node refresh updates only the cache. Published downloads and OpenClash are unchanged.'))
	];
	if (!profiles.length) {
		content.push(E('p', {}, _('This source is not referenced by any profile yet.')));
	} else if (changes.changed) {
		content.push(E('p', {}, _('Profiles using this source:')),
			E('ul', {}, profiles.map(function(profile) { return E('li', {}, profile.name || profile.id); })),
			E('p', {}, _('Open Overview to build and publish the profiles you want to update.')));
	} else {
		content.push(E('p', {}, _('No node changes were found; this refresh does not require rebuilding.')));
	}
	content.push(E('div', { 'class': 'right' }, [
		button(_('Done'), function() { ui.hideModal(); window.location.reload(); }), ' ',
		E('a', { 'class': 'cbi-button cbi-button-action', href: L.url('admin', 'services', 'hybrid-subscription', 'overview') }, _('Go to Overview'))
	]));
	ui.showModal(_('Node Update Result: ') + (source.name || source.id), content);
}

function regionMatchSignature(regions) {
	// Names and display order do not change which nodes enter generated groups.
	return JSON.stringify((regions || []).map(function(region) {
		return [region.id, region.pattern, Object.entries(region.source_patterns || {}).sort()];
	}).sort(function(a, b) { return a[0].localeCompare(b[0]); }));
}

function createMap(owner, payload, collections, title, description) {
	owner.config = JSON.parse(JSON.stringify(payload.config));
	owner.version = payload.version;
	const data = {};
	collections.forEach(function(key) {
		if (key === 'settings') {
			data.settings = Object.assign({}, owner.config.settings);
			booleanFields.forEach(function(k) { if (k in data.settings) data.settings[k] = data.settings[k] ? '1' : '0'; });
		} else {
			data[key] = (owner.config[key] || []).map(function(row, index) {
				const item = Object.assign({}, row, { '.name': key + '_' + index });
				booleanFields.forEach(function(k) { if (k in item) item[k] = item[k] ? '1' : '0'; });
				return item;
			});
		}
	});
	const m = new form.JSONMap(data, title, description);
	m.readonly = !L.hasViewPermission();
	// Older LuCI JSONMap versions reuse an existing row ID after a deletion.
	m.data.add = function(config, type, name) {
		const rows = this.sections(config);
		let id = name, index = 0;
		if (id == null) {
			while (this.data[type + index]) index++;
			id = type + index;
		}
		if (!this.data[id]) this.data[id] = {
			'.name': id, '.type': type, '.anonymous': name == null,
			'.index': rows.reduce(function(max, row) { return Math.max(max, row['.index'] || 0); }, -1) + 1
		};
		return id;
	};
	// Keep JSON-backed rule ordering independent of UCI's internal change state.
	m.data.move = function(config, from, to, after) {
		const rows = this.sections(config), a = rows.findIndex(function(r) { return r['.name'] === from; });
		if (a < 0) return false;
		const item = rows.splice(a, 1)[0];
		let b = rows.findIndex(function(r) { return r['.name'] === to; });
		if (b < 0) b = rows.length;
		else if (after) b++;
		rows.splice(b, 0, item);
		rows.forEach(function(row, index) { row['.index'] = index; });
		return true;
	};
	owner.map = m;
	owner.handleSave = function() {
		return m.save(function() {
			const next = JSON.parse(JSON.stringify(owner.config));
			collections.forEach(function(key) {
				next[key] = key === 'settings' ? clean(m.data.get('json', 'settings')) : m.data.sections('json', key).map(clean);
			});
			const settingsOnly = collections.indexOf('settings') >= 0 && regionMatchSignature(next.regions) === regionMatchSignature(owner.config.regions);
			const sourceFlags = {};
			(next.sources || []).forEach(function(source) {
				const previous = (owner.config.sources || []).find(function(row) { return row.id === source.id; }) || {};
				sourceFlags[source.id] = { has_url: !!source.url || !!source.has_url || !!previous.has_url, has_quota_url: !source.clear_quota_url && (!!source.quota_url || !!source.has_quota_url || !!previous.has_quota_url) };
				delete source.has_url; delete source.has_quota_url;
			});
			const changes = {};
			collections.forEach(function(key) { changes[key] = next[key]; });
			return api('save_config', { config: JSON.stringify(changes), version: owner.version, collections: collections }).then(function(result) {
				(next.sources || []).forEach(function(source) {
					Object.assign(source, sourceFlags[source.id], { url: '', quota_url: '', clear_quota_url: false });
				});
				m.data.sections('json', 'sources').forEach(function(row) {
					const source = next.sources.find(function(s) { return s.id === row.id; });
					if (source) { row.url = ''; row.quota_url = ''; row.clear_quota_url = '0'; row.has_url = source.has_url; row.has_quota_url = source.has_quota_url; }
				});
				owner.version = result.version; owner.config = next;
				ui.addNotification(null, E('p', {}, settingsOnly ? _('Global settings saved.') : _('Draft saved. Build and publish from the Overview page to update downloads or OpenClash.')), 'info');
			});
		});
	};
	owner.handleSaveApply = null;
	owner.handleReset = function() { window.location.reload(); };
	return m;
}

function grid(m, type, title, description, withName) {
	const s = m.section(form.GridSection, type, title, description);
	s.anonymous = true; s.addremove = true; s.nodescriptions = true;
	s.modaltitle = title; s.addbtntitle = _('Add');
	let o = s.option(form.Value, 'id', _('Identifier'));
	o.rmempty = false; o.modalonly = true;
	o.validate = function(sid, value) { return /^[a-z][a-z0-9_-]{0,47}$/.test(value) || _('Start with a lowercase letter and use only lowercase letters, digits, underscores, or hyphens (up to 48 characters).'); };
	if (withName !== false) {
		o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;
	}
	return s;
}

function value(s, type, key, title, description, defaultValue, modal) {
	const o = s.option(type, key, title, description);
	if (defaultValue !== undefined) o.default = defaultValue;
	o.retain = true;
	if (defaultValue === '' || type === form.MultiValue || type === form.DynamicList) {
		o.optional = true;
		const isList = type === form.MultiValue || type === form.DynamicList;
		// JSON schema uses explicit empty lists/strings; UCI normally removes them.
		o.remove = function(sid) { return this.write(sid, isList ? [] : ''); };
	}
	if (modal !== false) o.modalonly = true;
	return o;
}

function choices(o, values) {
	const labels = {};
	values.forEach(function(v) {
		const key = Array.isArray(v) ? v[0] : v, label = Array.isArray(v) ? v[1] : v;
		labels[key] = label; o.value(key, label);
	});
	o.textvalue = function(sid) {
		const current = this.cfgvalue(sid), selected = Array.isArray(current) ? current : [current];
		return selected.filter(function(v) { return v != null && v !== ''; }).map(function(v) { return Object.prototype.hasOwnProperty.call(labels, v) ? labels[v] : v; }).join(', ') || null;
	};
	return o;
}

function references(o, config, type, extra) {
	const types = Array.isArray(type) ? type : [type];
	(extra || []).forEach(function(v) { o.value(v, v); });
	types.forEach(function(collection) { (config[collection] || []).forEach(function(row) { o.value(row.id, row.name || row.id); }); });
	const load = o.load;
	o.load = function() {
		const option = this;
		types.forEach(function(collection) {
			option.map.data.sections('json', collection).forEach(function(row) {
				if (row.id) {
					const index = (option.keylist || []).indexOf(row.id);
					if (index >= 0) option.vallist[index] = row.name || row.id;
					else option.value(row.id, row.name || row.id);
				}
			});
		});
		return load.apply(this, arguments);
	};
	o.textvalue = function(sid) {
		const value = this.cfgvalue(sid), labels = {};
		types.forEach(function(collection) {
			(config[collection] || []).forEach(function(row) { labels[row.id] = row.name || row.id; });
		});
		const option = this;
		types.forEach(function(collection) { option.map.data.sections('json', collection).forEach(function(row) { labels[row.id] = row.name || row.id; }); });
		const values = Array.isArray(value) ? value : [value];
		return values.filter(function(v) { return v != null && v !== ''; }).map(function(v) { return labels[v] || v; }).join(', ') || null;
	};
	return o;
}

function sectionTabs(m, tabs, initialTab, toolbar) {
	const render = m.renderChildren;
	let active = tabs.some(function(tab) { return tab.id === initialTab; }) ? initialTab : tabs[0].id;
	m.tabbed = false;
	m.renderChildren = function(tabName) {
		const sections = this.children.filter(function(s) { return !s.disable && (tabName === null || s.tab === tabName); });
		return render.apply(this, arguments).then(function(nodes) {
			const used = {}, panes = tabs.map(function(tab) {
				const children = nodes.filter(function(node, index) {
					if (tab.sections.indexOf(sections[index].sectiontype) < 0) return false;
					used[index] = true; return true;
				});
				const pane = E('div', { 'data-tab': tab.id, 'data-tab-title': tab.title, 'data-tab-active': active === tab.id ? 'true' : null }, children);
				pane.addEventListener('cbi-tab-active', function() { active = tab.id; });
				return pane;
			});
			return (toolbar ? [toolbar()] : []).concat(nodes.filter(function(node, index) { return !used[index]; }), [E('div', { 'class': 'cbi-map-tabbed' }, panes)]);
		});
	};
	return m;
}

function modalTabs(s, tabs) {
	tabs.forEach(function(tab) { s.tab(tab.id, tab.title); });
	s.children.forEach(function(option) {
		if (option.modalonly === false) return;
		const tab = tabs.find(function(candidate) { return (candidate.options || []).indexOf(option.option) >= 0; }) || tabs[0];
		option.tab = tab.id;
		s.tabs[tab.id].children.push(option);
	});
	return s;
}

function filterSection(s, predicate, defaults) {
	s.filter = function(sid) {
		const row = this.map.data.get('json', sid);
		return !row.id || predicate(row);
	};
	if (defaults) {
		const add = s.addModalOptions;
		s.addModalOptions = function(modal, sid) {
			const row = this.map.data.get('json', sid);
			if (!row.id) Object.assign(row, defaults());
			return add.apply(this, arguments);
		};
	}
	return s;
}

function selectFilter(m, label, state, key, choices, changed) {
	const id = 'hs-filter-' + key, widget = new ui.Select(state[key], choices, { id: id, optional: false }), node = widget.render();
	let updating = false;
	node.addEventListener('change', function() {
		if (updating) return;
		const selected = widget.getValue();
		updating = true;
		return Promise.resolve().then(function() { return m.parse(); }).then(function() {
			state[key] = selected;
			if (changed) changed();
			return m.load().then(function() { return m.renderContents(); });
		}).catch(function(error) { widget.setValue(state[key]); notify(error); }).finally(function() { updating = false; });
	});
	return E('div', { 'class': 'cbi-value' }, [E('label', { 'class': 'cbi-value-title', 'for': 'widget.' + id }, label), E('div', { 'class': 'cbi-value-field' }, node)]);
}

function sectionActions(s, actions) {
	const render = s.renderSectionAdd;
	s.renderSectionAdd = function() {
		const node = render.apply(this, arguments);
		actions().forEach(function(action) { node.appendChild(E('span', {}, [' ', action])); });
		return node;
	};
}

function jsonValue(s, key, title, description, array) {
	const o = value(s, form.TextValue, key, title, description, array ? '[]' : '{}');
	o.rows = 12; o.monospace = true; o.optional = true; o.rmempty = false;
	o.load = function(sid) {
		const current = this.map.data.get('json', sid, key);
		return JSON.stringify(current || (array ? [] : {}), null, 2);
	};
	o.validate = function(sid, input) {
		try {
			const parsed = JSON.parse(input || (array ? '[]' : '{}'));
			return (array ? Array.isArray(parsed) : parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) || (array ? _('Please enter a valid JSON array.') : _('Please enter a valid JSON object.'));
		} catch (error) { return _('Invalid JSON format: ') + error.message; }
	};
	o.write = function(sid, input) { return this.map.data.set('json', sid, key, JSON.parse(input || (array ? '[]' : '{}'))); };
	o.remove = function(sid) { return this.map.data.set('json', sid, key, array ? [] : {}); };
	return o;
}

function rowAction(s, key, title, action, available) {
	const o = s.option(form.Button, key, title);
	o.inputtitle = title; o.inputstyle = 'action'; o.editable = true; o.modalonly = false;
	if (available) {
		const renderWidget = o.renderWidget;
		o.renderWidget = function(sid) {
			return available(s.map.data.get('json', sid)) ? renderWidget.apply(this, arguments) : E('span');
		};
	}
	o.onclick = function(ev, sid) {
		const row = s.map.data.get('json', sid);
		if (available && !available(row)) return Promise.resolve();
		return Promise.resolve().then(function() { return action(row); }).catch(notify);
	};
	return o;
}

function importSource(source) {
	const text = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 12, 'cols': 80, 'placeholder': _('Paste YAML, JSON, or node subscription content') });
	const file = E('input', { 'type': 'file', 'accept': '.yaml,.yml,.json,.txt,.conf', 'change': function(event) {
		const selected = event.target.files[0];
		if (!selected) return;
		if (selected.size > 2 * 1024 * 1024) { notify(new Error(_('File size must not exceed 2 MiB.'))); return; }
		selected.text().then(function(content) { text.value = content; }).catch(notify);
	} });
	ui.showModal(_('Import Cache: ') + source.name, [
		E('p', {}, _('Replaces only the local node cache for this source without fetching upstream or publishing automatically.')),
		E('p', {}, _('Only proxy nodes are imported. Routing rules, policy groups, and DNS settings in the file are not imported; manage these in Subscription Profiles and Routing Rules.')),
		file, E('p'), text,
		E('div', { 'class': 'right' }, [button(_('Cancel'), ui.hideModal), ' ', button(_('Validate & Import'), function() {
			if (new Blob([text.value]).size > 2 * 1024 * 1024) throw new Error(_('Content size must not exceed 2 MiB.'));
			return api('import_source', { source: source.id, content: text.value }).then(function(result) { sourceUpdateResult(source, result); });
		}, 'cbi-button-positive', true)])
	]);
}

function download(profile) {
	return api('download_info', { profile: profile }).then(function(info) {
		const base = (info.base_url || window.location.origin).replace(/\/$/, '');
		const formats = info.formats || [];
		const session = info.access_mode === 'session';
		const items = [E('p', {}, session ? _('Download access is restricted to authenticated LuCI sessions. Third-party clients cannot pull via URL or QR code; please download the file and import it manually.') : _('Anyone with the download link can access the node credentials in this subscription. Share only with your own trusted devices.'))];
		formats.forEach(function(format) {
			const url = base + '/cgi-bin/hybrid-subscription?profile=' + encodeURIComponent(profile) + '&format=' + encodeURIComponent(format) + (session ? '' : '&token=' + encodeURIComponent(info.token));
			items.push(E('h4', {}, ({ mihomo: 'Mihomo', surge: 'Surge', singbox: 'sing-box', shadowrocket: _('Shadowrocket (Clash YAML)') })[format] || format), E('p', {}, E('a', { href: url, target: '_blank', rel: 'noopener noreferrer', download: '' }, _('Download File'))));
			if (!session) {
				items.push(E('input', { 'class': 'cbi-input-text', 'readonly': true, 'value': url, 'click': function(e) { e.target.select(); } }));
				items.push(E('p', {}, E(uqr.renderSVG(url, { pixelSize: 4, border: 4, ecc: 'M', whiteColor: 'white', blackColor: 'black' }))));
				if (format === 'surge') items.push(E('p', {}, E('a', { href: 'surge:///install-config?url=' + encodeURIComponent(url) }, _('Import in Surge'))));
			}
		});
		if (!formats.length) items.push(E('p', {}, _('No published artifacts are available. Build and publish the profile first.')));
		items.push(E('div', { 'class': 'right' }, button(_('Close'), ui.hideModal)));
		ui.showModal(_('Subscription Download & QR Code'), items);
	});
}

function graph(config, profile) {
	const groups = (config.groups || []).filter(function(g) { return g.profile === profile; });
	const rematches = (config.rematches || []).filter(function(r) { return r.profile === profile; });
	const subRules = (config.sub_rules || []).filter(function(r) { return r.profile === profile; });
	const selected = (config.profiles || []).find(function(p) { return p.id === profile; });
	const sources = (config.sources || []).filter(function(s) { return selected && (selected.sources || []).indexOf(s.id) >= 0; });
	const ns = 'http://www.w3.org/2000/svg', boxWidth = 240, width = 1400;
	function svgNode(tag, attrs, text) {
		const el = document.createElementNS(ns, tag);
		Object.keys(attrs).forEach(function(k) { el.setAttribute(k, attrs[k]); });
		if (text != null) el.textContent = text;
		return el;
	}
	const height = Math.max(200, 65 * Math.max(sources.length + 1, groups.length, rematches.length, subRules.length) + 80);
	const svg = svgNode('svg', { viewBox: '0 0 ' + width + ' ' + height, width: width, height: height, style: 'width:' + width + 'px;height:' + height + 'px;max-width:none', role: 'img', 'aria-label': _('Dependency graph of subscription sources, policy groups, rematch entries, and sub-rules') });
	const points = {}, markerID = 'hs-arrow-' + Math.random().toString(36).slice(2);
	const defs = svgNode('defs', {}), marker = svgNode('marker', { id: markerID, viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 5, markerHeight: 5, orient: 'auto-start-reverse' });
	marker.appendChild(svgNode('path', { d: 'M 0 0 L 10 5 L 0 10 z', fill: 'currentColor' })); defs.appendChild(marker); svg.appendChild(defs);
	function node(key, x, index, name, detail) { points[key] = { x: x, y: 50 + index * 65, name: String(name), detail: detail || key }; }
	if (selected) node('profile', 10, 0, selected.name || selected.id, _('Final fallback policy of main rules'));
	sources.forEach(function(s, i) { node('s:' + s.id, 10, i + 1, s.name || s.id); });
	groups.forEach(function(g, i) { node('g:' + g.id, 290, i, g.name || g.id); });
	rematches.forEach(function(r, i) { node('r:' + r.id, 570, i, r.name || r.id, 'rematch: ' + r.id + (r.rematch_name ? ' [' + r.rematch_name + ']' : '')); });
	subRules.forEach(function(r, i) { node('u:' + r.id, 850, i, r.name || r.id); });
	node('DIRECT', 1130, 0, 'DIRECT'); node('REJECT', 1130, 1, 'REJECT');
	function policy(id) { return points['g:' + id] ? 'g:' + id : points['r:' + id] ? 'r:' + id : id; }
	const renderedEdges = {};
	function edge(fromKey, toKey, detail) {
		const from = points[fromKey], to = points[toKey];
		if (!from || !to) return;
		const key = fromKey + '\n' + toKey;
		if (renderedEdges[key]) return;
		renderedEdges[key] = { from: fromKey, to: toKey };
		let start = from.x + boxWidth, end = to.x;
		if (from.x > to.x) { start = from.x; end = to.x + boxWidth; }
		else if (from.x === to.x) { end = to.x + boxWidth; }
		const bend = from.x === to.x ? start + 50 : (start + end) / 2;
		const line = svgNode('path', { d: 'M ' + start + ' ' + (from.y + 18) + ' C ' + bend + ' ' + (from.y + 18) + ', ' + bend + ' ' + (to.y + 18) + ', ' + end + ' ' + (to.y + 18), fill: 'none', stroke: 'currentColor', 'stroke-opacity': '.5', 'marker-end': 'url(#' + markerID + ')' });
		line.appendChild(svgNode('title', {}, detail || from.name + ' → ' + to.name)); svg.appendChild(line);
	}
	if (selected) edge('profile', policy(selected.final_policy), _('Main rules final fallback'));
	groups.forEach(function(g) {
		(g.sources || []).forEach(function(id) { edge('s:' + id, 'g:' + g.id, _('Source nodes expanded into policy group')); });
		(g.members || []).forEach(function(id) { edge('g:' + g.id, policy(id), _('Group member')); });
		if (g.empty_fallback) edge('g:' + g.id, policy(g.empty_fallback), _('Empty group fallback'));
	});
	rematches.forEach(function(r) { edge('r:' + r.id, 'u:' + r.target_sub_rule, _('Forwards to sub-rule') + (r.rematch_name ? ' [' + r.rematch_name + ']' : '')); });
	subRules.forEach(function(r) {
		edge('u:' + r.id, policy(r.final_policy), _('Sub-rule final fallback'));
		(config.rules || []).filter(function(rule) { return rule.profile === profile && rule.sub_rule === r.id && rule.enabled !== false; }).forEach(function(rule) {
			edge('u:' + r.id, policy(rule.policy), rule.type + (rule.value ? ': ' + rule.value : ''));
		});
	});
	function shortLabel(name) {
		let length = 0, label = '';
		for (const character of name) {
			length += character.codePointAt(0) > 255 ? 2 : 1;
			if (length > 30) return label + '…';
			label += character;
		}
		return label;
	}
	Object.keys(points).forEach(function(key, index) {
		const p = points[key], g = svgNode('g', { id: markerID + '-node-' + index, tabindex: -1, 'aria-label': p.name }, null);
		p.element = g;
		p.elementID = markerID + '-node-' + index;
		g.appendChild(svgNode('rect', { x: p.x, y: p.y, width: boxWidth, height: 36, rx: 4, fill: 'Canvas', stroke: 'currentColor' }));
		g.appendChild(svgNode('text', { x: p.x + 8, y: p.y + 23, fill: 'currentColor', 'font-size': 14 }, shortLabel(p.name)));
		g.appendChild(svgNode('title', {}, p.detail + ': ' + p.name)); svg.appendChild(g);
	});
	[[_('Profile / Sources'), 10], [_('Policy Groups'), 290], [_('Rematch Entries'), 570], [_('Sub-Rules'), 850], [_('Built-in Policies'), 1130]].forEach(function(v) { svg.appendChild(svgNode('text', { x: v[1], y: 25, fill: 'currentColor', 'font-size': 14 }, v[0])); });
	const zoom = new ui.Select('1', { '1': '100%', '1.5': '150%', '2': '200%' }, { id: markerID + '-zoom', optional: false });
	const zoomNode = zoom.render();
	zoomNode.addEventListener('change', function() {
		const scale = Number(zoom.getValue()) || 1;
		svg.setAttribute('width', width * scale);
		svg.setAttribute('height', height * scale);
		svg.setAttribute('style', 'width:' + width * scale + 'px;height:' + height * scale + 'px;max-width:none');
	});
	const links = Object.keys(points).map(function(key) {
		const p = points[key];
		return [E('a', { href: '#' + p.elementID, click: function(event) {
			event.preventDefault();
			p.element.focus({ preventScroll: true });
			p.element.scrollIntoView({ block: 'nearest', inline: 'nearest' });
		} }, p.name), Object.keys(renderedEdges).filter(function(edgeKey) { return renderedEdges[edgeKey].from === key; }).map(function(edgeKey) { return points[renderedEdges[edgeKey].to].name; }).join(' / ') || '—'];
	});
	return E('div', {}, [
		E('div', { 'class': 'cbi-value' }, [E('label', { 'class': 'cbi-value-title', 'for': 'widget.' + markerID + '-zoom' }, _('Zoom')), E('div', { 'class': 'cbi-value-field' }, zoomNode)]),
		E('p', {}, _('Scroll horizontally or vertically to inspect. 100% preserves native label size; expand below for full names and outgoing references.')),
		E('div', { style: 'overflow:auto;max-height:60vh', tabindex: 0, role: 'region', 'aria-label': _('Scrollable policy dependency graph') }, svg),
		E('details', {}, [E('summary', {}, _('Full Names & Outgoing References (Click a Name to Focus)')), table([_('Name'), _('References')], links)])
	]);
}

return baseclass.extend({
	api: api, notify: notify, button: button, time: time, table: table, report: report,
	waitJob: waitJob, runJob: runJob, sourceUpdateSummary: sourceUpdateSummary, sourceUpdateResult: sourceUpdateResult,
	createMap: createMap, grid: grid, value: value,
	choices: choices, references: references, jsonValue: jsonValue, rowAction: rowAction, importSource: importSource,
	sectionTabs: sectionTabs, modalTabs: modalTabs, filterSection: filterSection, selectFilter: selectFilter, sectionActions: sectionActions,
	download: download, graph: graph, clean: clean,
	t: t, translateMessage: translateMessage, registerLocale: registerLocale, getLocale: getLocale, setLocale: setLocale, locales: locales
});
