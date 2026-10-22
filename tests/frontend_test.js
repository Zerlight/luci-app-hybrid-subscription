'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
let modules = 0;
function syntax(dir) {
	for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
		const file = path.join(dir, item.name);
		if (item.isDirectory()) syntax(file);
		else if (file.endsWith('.js')) { new Function(fs.readFileSync(file, 'utf8')); modules++; }
	}
}
syntax(path.join(root, 'htdocs'));

class Map {
	constructor(input) {
		const rows = {}; let index = 0;
		for (const [type, value] of Object.entries(input)) {
			for (const item of Array.isArray(value) ? value : [value]) {
				const name = item['.name'] || type;
				rows[name] = { ...item, '.type': type, '.name': name, '.index': index++ };
			}
		}
		this.data = {
			data: rows,
			sections: (_, type) => Object.values(rows).filter(r => !type || r['.type'] === type).sort((a, b) => a['.index'] - b['.index']),
			get: (_, id) => rows[id], remove: (_, id) => { delete rows[id]; }
		};
	}
	save(callback) { return callback(); }
}

const sent = [], form = { JSONMap: Map, MultiValue: {}, DynamicList: {}, Button: {}, TextValue: {} };
const rpc = { declare: spec => (...args) => {
	sent.push({ method: spec.method, args });
	return Promise.resolve({ ok: true, version: 'v2' });
} };
function node(tag, attrs = {}, children = []) {
	return { tag, attrs, children: Array.isArray(children) ? children : [children], listeners: {},
		setAttribute(k, v) { this.attrs[k] = v; }, appendChild(child) { this.children.push(child); },
		addEventListener(name, listener) { this.listeners[name] = listener; },
		focus() { this.focused = true; }, scrollIntoView() { this.scrolled = true; }
	};
}
const document = { createElementNS: (_, tag) => node(tag) }, selects = [], notifications = [];
const ui = { addNotification(title, content, level) { notifications.push({ title, content, level }); }, Select: class {
	constructor(value, choices, options) { this.value = value; this.choices = choices; this.options = options; selects.push(this); }
	render() { return this.node = node('select'); }
	getValue() { return this.value; }
	setValue(value) { this.value = value; }
} };
const hs = new Function('baseclass', 'form', 'rpc', 'ui', 'poll', 'uqr', 'L', 'E', '_', 'document',
	fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/hybrid-subscription.js'), 'utf8'))(
	{ extend: value => value }, form, rpc, ui, {}, {},
	{ hasViewPermission: () => true, env: { lang: 'en' } }, node, value => value, document
);

// Verify i18n default English, Simplified Chinese translation, dynamic backend patterns, and extensibility.
assert.equal(hs.getLocale(), 'en');
assert.equal(hs.t('Subscription Profiles'), 'Subscription Profiles');
assert.equal(hs.translateMessage('Group proxy has no members after filtering'), 'Group proxy has no members after filtering');

hs.setLocale('zh_Hans');
assert.equal(hs.getLocale(), 'zh-cn');
assert.equal(hs.t('Subscription Profiles'), '订阅配置');
assert.equal(hs.t('Overview'), '状态概览');
assert.equal(hs.t('Shadowrocket Group Type'), 'Shadowrocket 策略组类型');
assert.equal(hs.t('Shadowrocket URL (Classical YAML)'), 'Shadowrocket 规则集地址（Classical YAML）');
assert.equal(hs.t('Mihomo Default Selection'), 'Mihomo 默认选中项');
assert.equal(hs.t('Shadowrocket (Clash YAML)'), 'Shadowrocket（Clash YAML）');
assert.equal(hs.translateMessage('Group proxy: this exporter has no verified Shadowrocket mapping for mode smart; explicitly choose a manual or simpler automatic alternative'), '策略组 proxy：当前转换器尚未验证 Shadowrocket 的 smart 模式映射，请改为手动选择或受支持的基础自动模式');
assert.equal(hs.translateMessage('32 nodes contain advanced fields whose Shadowrocket behavior needs review: client-fingerprint, idle-session-timeout. These fields are retained.'), '32 个节点的高级字段需确认 Shadowrocket 支持情况：client-fingerprint, idle-session-timeout。字段已保留。');
assert.equal(hs.translateMessage('Group proxy: unsupported Shadowrocket type; choose select, url-test, fallback or load-balance'), '策略组 proxy：当前转换器支持的 Shadowrocket 模式为手动选择、延迟测速、故障转移和负载均衡');
assert.equal(hs.translateMessage('shadowrocket: Example: conflicting AnyTLS reuse settings'), 'Shadowrocket：节点 Example：AnyTLS 连接复用设置冲突');
assert.equal(hs.translateMessage('shadowrocket: Example: unsupported VMess cipher'), 'Shadowrocket：节点 Example：不支持的 VMess 加密方式');
assert.equal(hs.translateMessage('shadowrocket: Example: reuse must be boolean'), 'Shadowrocket：节点 Example：reuse 必须为布尔值');
assert.equal(hs.translateMessage('shadowrocket: Example: Reality requires enabled TLS'), 'Shadowrocket：节点 Example：Reality 需要启用 TLS');
assert.equal(hs.translateMessage('Invalid identifier'), '标识符格式无效');
assert.equal(hs.translateMessage('Subscription request failed (HTTP 404); cached nodes were kept'), '订阅请求失败（HTTP 404），已保留节点缓存');
assert.equal(hs.translateMessage('Subscription request failed (HTTP 400); cached nodes were kept'), '订阅请求失败（HTTP 400），已保留节点缓存');
assert.equal(hs.translateMessage('Group proxy has no members after filtering; Rule r1: invalid IP prefix'), '策略组 proxy 在筛选后无可用节点或成员；分流规则 r1：IP 网段（CIDR）格式无效');
assert.equal(hs.translateMessage('Source alpha, node 2: missing password'), '订阅源 alpha 第 2 个节点：缺少必填字段 password');
assert.equal(hs.translateMessage('Update compatible draft Surge (copy) from its saved source; preserve published releases and download links'), '根据来源配置更新兼容草稿“Surge”（copy）；保留已发布版本和订阅链接');
assert.equal(hs.translateMessage('Replace target rules Test rule (rule_1); changed fields: policy, value'), '更新兼容草稿中的分流规则“Test rule”（rule_1）；变更字段：出口策略、匹配内容');
assert.equal(hs.translateMessage('Omit sub-rule Scope (scope) and its 2 scoped rules from the compatible draft'), '从兼容草稿中移除子规则“Scope”（scope）及其 2 条内部规则');

hs.registerLocale('ja', {
	separator: '・',
	aliases: ['ja_jp'],
	exact: { 'Overview': '概要' },
	patterns: [[/^Unknown source (.+)$/, '不明なソース: $1']]
});
hs.setLocale('ja_JP');
assert.equal(hs.getLocale(), 'ja');
assert.equal(hs.t('Overview'), '概要');
assert.equal(hs.translateMessage('Unknown source foo'), '不明なソース: foo');
hs.setLocale('en');

const logical = hs.clean({ '.type': 'rules', type: 'AND', value: 'old-leaf-value', no_resolve: '1', conditions: [{ type: 'NETWORK', value: 'UDP' }] });
assert.equal(logical.value, undefined);
assert.equal(logical.no_resolve, undefined);
assert.equal(logical.conditions[0].type, 'NETWORK');
const leaf = hs.clean({ '.type': 'rules', type: 'DOMAIN', value: 'example.com', conditions: [{ type: 'NETWORK', value: 'UDP' }] });
assert.equal(leaf.conditions, undefined);
assert.equal(leaf.value, 'example.com');

const owner = {}, config = {
	schema: 1, settings: {}, profiles: [], groups: [], rule_sets: [],
	sources: [{ id: 'a', url: 'private-input', quota_url: 'quota-input', quota_max_age: '3600', has_url: true, has_quota_url: true, enabled: true }, { id: 'b', url: '', quota_url: '', has_url: true, has_quota_url: true, clear_quota_url: true }],
	rules: [{ id: 'a', enabled: true }, { id: 'b', enabled: false }]
};
const m = hs.createMap(owner, { config, version: 'v1' }, ['sources', 'rules'], 'Test');
const rowA = m.data.add('json', 'groups'), rowB = m.data.add('json', 'groups');
m.data.remove('json', rowA);
const rowC = m.data.add('json', 'groups');
assert.notEqual(rowC, rowB, 'adding after deletion must not reuse a surviving row');
assert.ok(m.data.get('json', rowB));

const rules = m.data.sections('json', 'rules');
m.data.move('json', rules[1]['.name'], rules[0]['.name'], false);
assert.deepEqual(m.data.sections('json', 'rules').map(row => row.id), ['b', 'a']);

const section = { option() { return { write(sid, value) { this.written = value; } }; } };
const url = hs.value(section, {}, 'url', 'URL', null, '');
url.remove('row'); assert.equal(url.written, ''); assert.equal(url.optional, true);
const members = hs.value(section, form.DynamicList, 'members', 'Members', null, []);
members.remove('row'); assert.deepEqual(members.written, []);
const sources = hs.value(section, form.MultiValue, 'sources', 'Sources', null, []);
sources.remove('row'); assert.deepEqual(sources.written, []);
const action = hs.rowAction(section, '_test', 'Test', () => {});
assert.equal(action.editable, true, 'GridSection must render a real action button');
assert.equal(action.modalonly, false, 'row actions must not dispatch while modal edits are unsaved');
let storedChoice = 'manual';
const choice = hs.choices({ value() {}, cfgvalue: () => storedChoice }, [['manual', 'Manual Only'], ['scheduled', 'Scheduled']]);
assert.equal(choice.textvalue('row'), 'Manual Only'); assert.equal(storedChoice, 'manual');
storedChoice = ['manual', 'scheduled'];
assert.equal(choice.textvalue('row'), 'Manual Only, Scheduled'); assert.deepEqual(storedChoice, ['manual', 'scheduled']);
storedChoice = 'unknown'; assert.equal(choice.textvalue('row'), 'unknown');
storedChoice = ''; assert.equal(choice.textvalue('row'), null);

const jsonStore = {}, jsonSection = { option() { return { map: { data: { get: (_, id, key) => jsonStore[key], set: (_, id, key, value) => { jsonStore[key] = value; } } } }; } };
const conditions = hs.jsonValue(jsonSection, 'conditions', 'Conditions', '', true);
assert.equal(conditions.validate('row', '[{"type":"NETWORK","value":"UDP"}]'), true);
assert.notEqual(conditions.validate('row', '{}'), true);
conditions.write('row', '[{"type":"AND","conditions":[{"type":"NETWORK","value":"UDP"},{"type":"GEOSITE","value":"cn"}]}]');
assert.equal(jsonStore.conditions[0].conditions[1].type, 'GEOSITE');
conditions.remove('row'); assert.deepEqual(jsonStore.conditions, []);
const dns = hs.jsonValue(jsonSection, 'mihomo_dns', 'DNS', '');
dns.write('row', '{"enable":true,"nameserver":["https://dns.example/dns-query"]}');
assert.equal(jsonStore.mihomo_dns.enable, true);
assert.equal(JSON.parse(dns.load('row')).nameserver[0], 'https://dns.example/dns-query');
assert.notEqual(dns.validate('row', '[]'), true);

const diagram = hs.graph({ profiles: [{ id: 'p', name: 'Hybrid', sources: ['s'], final_policy: 'shared' }], sources: [{ id: 's', name: 'Source' }], groups: [{ id: 'shared', profile: 'p', sources: ['s'], members: ['region'] }, { id: 'jp', profile: 'p', sources: ['s'], members: [] }], rematches: [{ id: 'region', profile: 'p', name: 'Japan', target_sub_rule: 'choose' }], sub_rules: [{ id: 'choose', profile: 'p', name: 'Choose', final_policy: 'REJECT' }], rules: [{ profile: 'p', sub_rule: 'choose', type: 'REMATCH-NAME', value: 'Source A', policy: 'jp' }] }, 'p');
function descendants(n) { return n && typeof n === 'object' ? [n, ...n.children.flatMap(descendants)] : []; }
const all = descendants(diagram), svg = all.find(n => n.tag === 'svg');
assert.ok(svg.children.filter(child => child.tag === 'path' && child.attrs['marker-end']).length >= 6, 'graph must include rematch/sub-rule and rule-policy edges');
assert.ok(svg.children.some(child => child.tag === 'g' && child.children.some(item => item.textContent === 'Japan')));
assert.equal(svg.attrs.width, 1400, '100% must preserve native pixels instead of shrinking to modal width');
assert.match(svg.attrs.style, /max-width:none/);
assert.ok(all.some(n => n.attrs.style === 'overflow:auto;max-height:60vh'));
const originalHeight = svg.attrs.height;
selects[0].value = '1.5'; selects[0].node.listeners.change();
assert.equal(svg.attrs.width, 2100);
assert.equal(svg.attrs.height, originalHeight * 1.5);
const japan = all.find(n => n.tag === 'a' && n.children[0] === 'Japan');
japan.attrs.click({ preventDefault() {} });
const japanNode = svg.children.find(n => n.attrs.id === japan.attrs.href.slice(1));
assert.equal(japanNode.focused, true);
assert.equal(japanNode.scrolled, true);

async function sourceActionChecks() {
	const sourceRows = {
		saved: { id: 'saved', url: '', has_url: true, quota_via_subscription: false },
		header: { id: 'header', url: '', has_url: '1', quota_via_subscription: '1' },
		file: { id: 'file', url: '', has_url: false, quota_via_subscription: true },
		dedicated: { id: 'dedicated', url: '', has_url: false, quota_url: '', has_quota_url: true },
		cleared: { id: 'cleared', url: '', quota_url: '', has_quota_url: true, clear_quota_url: '1' },
		disabled: { id: 'disabled', url: '', has_url: true, quota_via_subscription: '0' },
		local: { id: 'local', url: '', has_url: false },
		metadata: { id: 'metadata', url: '', has_url: false },
		newurl: { id: 'newurl', url: 'https://example.invalid/subscription', has_url: false, quota_via_subscription: true },
		newquota: { id: 'newquota', url: '', quota_url: 'https://example.invalid/quota', clear_quota_url: '0' },
		unset: { id: 'unset', url: '  ', has_url: 'false', quota_via_subscription: '0' }
	};
	const sourceMap = { data: { get: (_, sid, key) => key ? sourceRows[sid][key] : sourceRows[sid] }, render: () => sourceSection };
	const sourceSection = {
		map: sourceMap, children: [], tabs: {}, renderSectionAdd() { return node('div'); },
		option(type, key, title) {
			const option = { option: key, title, depends() {}, value() {}, renderWidget() { return node('button', { 'data-option': key }); } };
			this.children.push(option); return option;
		},
		tab(key) { this.tabs[key] = { children: [] }; }
	};
	const sourceJobs = [], sourceResults = [];
	const updateResult = { changes: { changed: true, added: 1, removed: 0, updated: 0 } };
	let sourceSaves = 0, sourceReloads = 0;
	const sourcePage = new Function('view', 'form', 'ui', 'hs', 'E', '_', 'window', fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/view/hybrid-subscription/sources.js'), 'utf8'))(
		{ extend: value => value }, { ...form, Flag: {}, DummyValue: {}, Value: {}, ListValue: {} }, ui,
		{ ...hs, createMap: () => sourceMap, grid: () => sourceSection,
			runJob: async (method, args) => { sourceJobs.push({ method, args }); return { result: updateResult }; },
			sourceUpdateResult: (source, result) => { sourceResults.push({ source, result }); } }, node, value => value,
		{ location: { reload() { sourceReloads++; } } }
	);
	sourcePage.handleSave = async () => { sourceSaves++; };
	sourcePage.render([{}, { sources: [
		{ id: 'saved', nodes: 3, cached_at: '2026-10-21T12:00:00Z', last_refresh: updateResult.changes, error: 'Subscription request failed (HTTP 400); cached nodes were kept', quota_status: { can_refresh: false, query_mode: 'cache_only' } },
		{ id: 'file', quota_status: { can_refresh: true, query_mode: 'subscription' } },
		{ id: 'cleared', quota_status: { can_refresh: true, query_mode: 'independent' } },
		{ id: 'disabled', quota_status: { can_refresh: true, query_mode: 'subscription' } },
		{ id: 'local', quota_status: { can_refresh: true, query_mode: 'cache_only' } },
		{ id: 'metadata', quota_status: { available: true, can_refresh: false, query_mode: 'cache_only' } }
	] }]);
	const sourceOption = key => sourceSection.children.find(option => option.option === key);
	const updateSource = sourceOption('_refresh'), refreshQuota = sourceOption('_refresh_quota');
	assert.equal(sourceOption('has_url'), undefined, 'saved URL presence is internal state, not a source table or editor field');
	assert.ok(sourceOption('has_quota_url'), 'the quota URL status remains available in the editor');
	assert.match(sourceOption('_state').cfgvalue('saved'), /^3 nodes · .*Added 1 · removed 0 · modified 0 · Subscription request failed \(HTTP 400\)/, 'cache status retains node count, timestamp, last change summary and latest error');
	for (const [sid, update, quota] of [
		['saved', true, false], ['header', true, true], ['file', false, false], ['dedicated', false, true],
		['cleared', false, false], ['disabled', true, false], ['local', false, true], ['metadata', false, false],
		['newurl', true, true], ['newquota', false, true], ['unset', false, false]
	]) {
		assert.equal(updateSource.renderWidget(sid).tag === 'button', update, `${sid}: render Update Subscription only when a URL exists`);
		assert.equal(refreshQuota.renderWidget(sid).tag === 'button', quota, `${sid}: render Refresh Quota only with a current query method or local adapter`);
	}
	assert.equal(sourceSaves, 0, 'drawing the source list does not save or refresh subscriptions');
	assert.deepEqual(sourceJobs, []);
	await updateSource.onclick({}, 'file'); await refreshQuota.onclick({}, 'cleared'); await refreshQuota.onclick({}, 'disabled');
	assert.equal(sourceSaves, 0, 'unavailable actions remain inert if a stale handler is invoked');
	sourceRows.dedicated.clear_quota_url = '1';
	assert.equal(refreshQuota.renderWidget('dedicated').tag, 'span', 're-render uses the current edited row after removing a saved quota URL');
	sourceRows.file.url = 'https://example.invalid/new-subscription';
	assert.equal(updateSource.renderWidget('file').tag, 'button', 're-render reflects a newly entered subscription URL');
	await updateSource.onclick({}, 'saved'); await refreshQuota.onclick({}, 'local');
	assert.equal(sourceSaves, 2); assert.equal(sourceReloads, 1, 'subscription results stay visible; only the independent quota action reloads immediately');
	assert.deepEqual(sourceResults, [{ source: sourceRows.saved, result: updateResult }], 'completed subscription jobs open the shared result dialog');
	assert.deepEqual(sourceJobs, [{ method: 'refresh', args: { source: 'saved' } }, { method: 'refresh_quota', args: { source: 'local' } }]);
}

async function sourceUpdateResultChecks() {
	let modal, reloads = 0, hidden = 0;
	const requests = [], changes = { changed: true, initial: false, before_nodes: 3, after_nodes: 4, added: 2, removed: 1, updated: 1, order_changed: true };
	const result = { nodes: 4, changes, affected_profiles: [{ id: 'profile', name: 'Hybrid' }] };
	const resultUi = {
		showModal(title, children) { modal = node('modal', { title }, children); },
		hideModal() { hidden++; }
	};
	const feedback = new Function('baseclass', 'form', 'rpc', 'ui', 'poll', 'uqr', 'L', 'E', '_', 'document', 'window',
		fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/hybrid-subscription.js'), 'utf8'))(
		{ extend: value => value }, {}, { declare: spec => (...args) => { requests.push({ method: spec.method, args }); return Promise.resolve({ ok: true, ...result }); } }, resultUi, {}, {},
		{ env: { lang: 'en' }, hasViewPermission: () => true, url: (...segments) => '/cgi-bin/luci/' + segments.join('/') }, node, value => value, {},
		{ location: { reload() { reloads++; } } }
	);
	const text = value => value == null ? '' : typeof value === 'object' ? value.children.map(text).join(' ') : String(value);
	const buttons = () => descendants(modal).filter(value => value.tag === 'button');
	const click = button => button.attrs.click({ preventDefault() {}, currentTarget: button });
	assert.equal(feedback.sourceUpdateSummary(), '');
	assert.equal(feedback.sourceUpdateSummary(changes), 'Added 2 · removed 1 · modified 1 · Node order changed');
	feedback.sourceUpdateResult({ id: 'source', name: 'Test Source' }, { ...result, password: 'secret-must-not-render', url: 'https://secret.invalid' });
	assert.equal(modal.attrs.title, 'Node Update Result: Test Source');
	assert.match(text(modal), /Nodes: 3 → 4\./);
	assert.match(text(modal), /Added 2 · removed 1 · modified 1 · Node order changed/);
	assert.match(text(modal), /Profiles using this source: Hybrid/);
	assert.match(text(modal), /Published downloads and OpenClash are unchanged/);
	assert.doesNotMatch(text(modal), /secret-must-not-render|secret\.invalid/);
	const overview = descendants(modal).find(value => value.tag === 'a');
	assert.equal(overview.attrs.href, '/cgi-bin/luci/admin/services/hybrid-subscription/overview');
	assert.equal(reloads, 0, 'successful updates do not reload before users read the result');
	assert.deepEqual(requests, [], 'the result dialog never builds or publishes automatically');
	await click(buttons().find(value => text(value) === 'Done'));
	assert.equal(reloads, 1); assert.equal(hidden, 1);

	feedback.sourceUpdateResult({ id: 'source' }, { nodes: 4, changes: { ...changes, changed: false, added: 0, removed: 0, updated: 0, order_changed: false }, affected_profiles: result.affected_profiles });
	assert.match(text(modal), /Nodes unchanged/);
	assert.match(text(modal), /this refresh does not require rebuilding/);
	assert.doesNotMatch(text(modal), /Profiles using this source|Node order changed/);
	feedback.sourceUpdateResult({ id: 'source' }, { nodes: 4, changes: { ...changes, initial: true, before_nodes: 0, order_changed: false }, affected_profiles: [] });
	assert.match(text(modal), /Initial cache/);
	assert.match(text(modal), /not referenced by any profile yet/);
	assert.equal(reloads, 1);
	feedback.setLocale('zh-cn');
	assert.equal(feedback.sourceUpdateSummary(changes), '新增 2 · 移除 1 · 修改 1 · 节点顺序变化');
	feedback.setLocale('en');

	feedback.importSource({ id: 'source', name: 'Test Source' });
	descendants(modal).find(value => value.tag === 'textarea').value = 'fixture node content';
	await click(buttons().find(value => text(value) === 'Validate & Import'));
	assert.deepEqual(requests, [{ method: 'import_source', args: ['source', 'fixture node content'] }]);
	assert.equal(modal.attrs.title, 'Node Update Result: Test Source', 'local imports use the same node-diff result dialog');
	assert.match(text(modal), /Added 2 · removed 1 · modified 1/);
	assert.equal(reloads, 1, 'local imports also preserve the result until dismissed');
}

async function editorChecks() {
	await sourceActionChecks();
	await sourceUpdateResultChecks();
	let downloadModal;
	const downloads = new Function('baseclass', 'form', 'rpc', 'ui', 'poll', 'uqr', 'L', 'E', '_', 'document', 'window',
		fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/hybrid-subscription.js'), 'utf8'))(
		{ extend: value => value }, {}, { declare: spec => (...args) => {
			assert.equal(spec.method, 'download_info'); assert.deepEqual(args, ['rocket']);
			return Promise.resolve({ ok: true, formats: ['shadowrocket'], access_mode: 'lan_token', token: 'local-test-token', base_url: 'http://router.test' });
		} }, { showModal: (title, children) => { downloadModal = node('modal', { title }, children); } }, {}, { renderSVG: url => url },
		{ env: { lang: 'en' } }, node, value => value, {}, { location: { origin: 'http://router.test' } }
	);
	await downloads.download('rocket');
	const downloadNodes = descendants(downloadModal);
	assert.equal(downloadNodes.find(item => item.tag === 'h4').children[0], 'Shadowrocket (Clash YAML)');
	const downloadLink = downloadNodes.find(item => item.tag === 'a');
	assert.equal(downloadLink.attrs.href, 'http://router.test/cgi-bin/hybrid-subscription?profile=rocket&format=shadowrocket&token=local-test-token');
	assert.equal(downloadLink.attrs.download, '', 'use the native download link and server-provided filename');
	assert.equal(downloadNodes.filter(item => item.tag === 'a').length, 1, 'do not invent an unverified import URL scheme');
	const publishNotice = 'Draft saved. Build and publish from the Overview page to update downloads or OpenClash.';
	const settingsNotice = 'Global settings saved.';
	function assertNotice(expected, reason) {
		assert.equal(notifications.at(-1).content.children[0], expected, reason);
		assert.equal(notifications.at(-1).level, 'info');
	}
	const addButton = node('button'), actionSection = { renderSectionAdd(extraClass) { return node('div', { class: extraClass }, [addButton]); } };
	hs.sectionActions(actionSection, () => [node('button', {}, 'Import')]);
	const actions = actionSection.renderSectionAdd('cbi-tblsection-create');
	assert.equal(actions.children[0], addButton, 'keep the native Add control');
	assert.equal(actions.attrs.class, 'cbi-tblsection-create');
	assert.equal(actions.children[1].children[1].children[0], 'Import');
	assert.equal(actionSection.renderSectionAdd().children.length, 2, 'rerender does not duplicate actions');
	assert.equal(typeof owner.handleSave, 'function'); assert.equal(typeof owner.handleReset, 'function');
	assert.equal(owner.handleSaveApply, null, 'draft pages expose native Save/Reset without Apply');

	const settings = new Function('view', 'hs', '_', fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/view/hybrid-subscription/settings.js'), 'utf8'))(
		{ extend: value => value }, { api: async method => {
			assert.equal(method, 'region_defaults', 'adding templates must not save or fetch subscriptions');
			return { regions: [{ id: 'jp', name: 'Japan', pattern: 'default' }, { id: 'us', name: 'United States', pattern: 'US' }] };
		} }, hs.t
	);
	hs.setLocale('zh-cn');
	const regionOwner = {}, regionMap = hs.createMap(regionOwner, { config: { regions: [{ id: 'jp', name: '日本', pattern: 'custom', source_patterns: { a: 'override' } }] } }, ['regions']);
	regionMap.data.set = (_, sid, key, value) => { regionMap.data.get('json', sid)[key] = value; };
	let regionParsed = false, regionRendered = 0;
	regionMap.parse = async () => { regionParsed = true; };
	regionMap.load = async () => { assert.equal(regionParsed, true); };
	regionMap.renderContents = async () => { regionRendered++; };
	await settings.addRegions(regionMap); await settings.addRegions(regionMap);
	assert.deepEqual(regionMap.data.sections('json', 'regions').map(hs.clean), [
		{ id: 'jp', name: '日本', pattern: 'custom', source_patterns: { a: 'override' } }, { id: 'us', name: '美国', pattern: 'US' }
	], 'default templates localize region names, preserve custom matches, and do not add duplicates');
	hs.setLocale('en');
	assert.equal(regionOwner.config.regions.length, 1, 'templates remain unsaved until native Save');
	assert.equal(regionRendered, 2);

	const childNodes = [node('section', { id: 'profiles' }), node('section', { id: 'groups' }), node('section', { id: 'rematches' }), node('section', { id: 'sub_rules' })];
	const tabMap = { children: ['profiles', 'groups', 'rematches', 'sub_rules'].map(sectiontype => ({ sectiontype })), renderChildren: async () => childNodes };
	hs.sectionTabs(tabMap, [{ id: 'profiles', title: 'Profiles', sections: ['profiles'] }, { id: 'groups', title: 'Groups', sections: ['groups'] }, { id: 'advanced', title: 'Advanced', sections: ['rematches', 'sub_rules'] }], 'groups');
	const initial = (await tabMap.renderChildren(null))[0];
	assert.equal(initial.attrs.class, 'cbi-map-tabbed', 'Map must use native LuCI tab initialization');
	assert.equal(initial.children[1].attrs['data-tab-active'], 'true');
	assert.deepEqual(initial.children[2].children, childNodes.slice(2), 'grouped tabs must reuse all original sections');
	initial.children[2].listeners['cbi-tab-active']();
	assert.equal((await tabMap.renderChildren(null))[0].children[2].attrs['data-tab-active'], 'true', 'modal rerender must preserve the selected page tab');
	const named = { children: [{ sectiontype: 'settings' }], renderChildren: async () => [node('section')] };
	hs.sectionTabs(named, [{ id: 'general', title: 'General', sections: ['settings'] }]);
	assert.equal((await named.renderChildren(null))[0].children[0].children.length, 1, 'NamedSection must be grouped using its section type');
	const modal = { children: [{ option: 'name' }, { option: 'conditions' }, { option: '_action', modalonly: false }], tabs: {}, tab(id, title) { this.tabs[id] = { title, children: [] }; } };
	hs.modalTabs(modal, [{ id: 'general', title: 'General' }, { id: 'advanced', title: 'Advanced', options: ['conditions'] }]);
	assert.equal(modal.children[0].tab, 'general'); assert.equal(modal.children[1].tab, 'advanced'); assert.equal(modal.children[2].tab, undefined);

	const filteredOwner = {}, filtered = hs.createMap(filteredOwner, { version: 'v1', config: { sources: [], rules: [
		{ id: 'a1', profile: 'a', value: 'draft-before-filter', enabled: true }, { id: 'b1', profile: 'b', value: 'keep-hidden', enabled: true }, { id: 'a2', profile: 'a', enabled: false }
	] } }, ['rules'], 'Filtered');
	const state = { profile: 'a' }, rowSection = { map: filtered, addModalOptions() {} };
	hs.filterSection(rowSection, row => row.profile === state.profile, () => ({ profile: state.profile }));
	const visible = () => filtered.data.sections('json', 'rules').filter(row => rowSection.filter(row['.name']));
	assert.deepEqual(visible().map(row => row.id), ['a1', 'a2']);
	const rows = filtered.data.sections('json', 'rules');
	filtered.data.move('json', rows[2]['.name'], rows[0]['.name'], false);
	assert.deepEqual(visible().map(row => row.id), ['a2', 'a1']);
	let parsed = false;
	filtered.parse = async () => { parsed = true; rows[0].value = 'retained-draft'; };
	filtered.load = async () => { assert.equal(parsed, true, 'parse current edits before changing visibility'); };
	filtered.renderContents = async () => {};
	hs.selectFilter(filtered, 'Profile', state, 'profile', { a: 'A', b: 'B' });
	const select = selects.at(-1); select.value = 'b'; await select.node.listeners.change();
	assert.equal(state.profile, 'b'); assert.deepEqual(visible().map(row => row.id), ['b1']);
	assert.equal(filtered.data.sections('json', 'rules').length, 3, 'changing filters must keep all underlying rows');
	await filteredOwner.handleSave();
	assertNotice(publishNotice, 'routing edits retain the publication reminder');
	const saved = JSON.parse(sent.filter(call => call.method === 'save_config').at(-1).args[0]);
	assert.deepEqual(saved.rules.map(row => row.id), ['a2', 'a1', 'b1']);
	assert.equal(saved.rules[1].value, 'retained-draft'); assert.equal(saved.rules[2].value, 'keep-hidden');
	const added = filtered.data.add('json', 'rules');
	assert.equal(rowSection.filter(added), true, 'a new draft row remains editable before its id is set');
	rowSection.addModalOptions({}, added);
	assert.equal(filtered.data.get('json', added).profile, 'b', 'new rows inherit the active subscription');

	const referenceRows = [{ id: 'jp', name: 'Japan' }], reference = { keylist: [], vallist: [], map: { data: { sections: () => referenceRows } }, cfgvalue: () => ['jp', 'DIRECT'], load() {}, value(id, label) { this.keylist.push(id); this.vallist.push(label); } };
	hs.references(reference, { groups: referenceRows }, 'groups', ['DIRECT']);
	assert.equal(reference.textvalue('row'), 'Japan, DIRECT', 'references display names without changing stored ids');
	referenceRows[0].name = 'Japan updated'; reference.load('row');
	assert.equal(reference.vallist[reference.keylist.indexOf('jp')], 'Japan updated');

	await hs.api('refresh_quota', { source: 's' }); await hs.api('preview_regions', { config: '{}', sources: ['s'] }); await hs.api('region_defaults');
	assert.deepEqual(sent.find(call => call.method === 'refresh_quota').args, ['s']);
	assert.deepEqual(sent.find(call => call.method === 'preview_regions').args, ['{}', ['s']]);
	await owner.handleSave();
	const request = sent.filter(call => call.method === 'save_config').at(-1);
	const body = JSON.parse(request.args[0]);
	assert.equal(request.args[1], 'v1');
	assert.deepEqual(request.args[2], ['sources', 'rules']);
	assert.deepEqual(Object.keys(body).sort(), ['rules', 'sources']);
	assert.deepEqual(body.rules.map(row => row.id), ['b', 'a']);
	assert.equal(body.rules[0].enabled, false);
	assert.equal(body.sources[0].url, 'private-input');
	assert.equal(body.sources[0].quota_url, 'quota-input');
	assert.equal(body.sources[0].quota_max_age, 3600);
	assert.equal(body.sources[0].has_url, undefined); assert.equal(body.sources[0].has_quota_url, undefined);
	assert.equal(body.sources[1].clear_quota_url, true);
	assert.equal(owner.config.sources[0].url, '');
	assert.equal(owner.config.sources[0].quota_url, '');
	assert.equal(owner.config.sources[0].has_url, true);
	assert.equal(owner.config.sources[0].has_quota_url, true);
	assert.equal(owner.config.sources[1].has_quota_url, false);
	assert.equal(owner.config.sources[1].clear_quota_url, false);
	assert.equal(m.data.sections('json', 'sources')[1].clear_quota_url, '0');
	assert.equal(owner.version, 'v2');
	assertNotice(publishNotice, 'source and routing edits retain the publication reminder');

	function settingsEditor(regions) {
		const owner = {};
		const config = { schema: 1, settings: { access_mode: 'lan_token', base_url: '', openclash_auto_apply: false, openclash_profile: '', converter_url: 'http://127.0.0.1:25500' },
			sources: [{ id: 'a', url: '', quota_url: '', has_url: true, has_quota_url: false }, { id: 'b', url: '', quota_url: '', has_url: true, has_quota_url: false }],
			profiles: [], groups: [], rematches: [], sub_rules: [], rules: [], rule_sets: [], regions };
		return { owner, map: hs.createMap(owner, { config, version: 'settings-v1' }, ['settings', 'regions']) };
	}
	const flags = settingsEditor([{ id: 'jp', name: 'Japan', pattern: 'JP' }]);
	flags.map.data.get('json', 'settings').openclash_auto_apply = '1';
	// Native override controls materialize an empty object when parsing an unset override.
	flags.map.data.get('json', 'regions_0').source_patterns = {};
	await flags.owner.handleSave();
	assertNotice(settingsNotice, 'a settings flag and materialized empty overrides do not require publication');
	assert.equal(flags.owner.config.settings.openclash_auto_apply, true);
	assert.equal(sent.at(-1).args[1], 'settings-v1');
	assert.deepEqual(sent.at(-1).args[2], ['settings', 'regions']);
	assert.deepEqual(Object.keys(JSON.parse(sent.at(-1).args[0])).sort(), ['regions', 'settings']);
	await flags.owner.handleSave();
	assertNotice(settingsNotice, 'repeated settings-only saves remain neutral');
	assert.equal(sent.at(-1).args[1], 'v2', 'repeat save uses the returned configuration version');

	const regions = [{ id: 'jp', name: 'Japan', pattern: 'JP', source_patterns: { a: 'Japan A', b: 'Japan B' } }, { id: 'us', name: 'United States', pattern: 'US' }];
	const display = settingsEditor(regions);
	display.map.data.get('json', 'regions_0').name = '日本';
	display.map.data.get('json', 'regions_0').source_patterns = { b: 'Japan B', a: 'Japan A' };
	display.map.data.move('json', 'regions_1', 'regions_0', false);
	await display.owner.handleSave();
	assertNotice(settingsNotice, 'region labels, display order and override key order do not change matching');
	assert.deepEqual(display.owner.config.regions.map(region => region.id), ['us', 'jp'], 'display edits are still saved');

	for (const [reason, edit] of [
		['general regex', map => { map.data.get('json', 'regions_0').pattern = 'JP|Japan'; }],
		['source override', map => { map.data.get('json', 'regions_0').source_patterns = { a: 'Changed A', b: 'Japan B' }; }],
		['removed override', map => { map.data.get('json', 'regions_0').source_patterns = {}; }],
		['new region', map => { Object.assign(map.data.get('json', map.data.add('json', 'regions')), { id: 'sg', name: 'Singapore', pattern: 'SG' }); }],
		['removed region', map => { map.data.remove('json', 'regions_0'); }],
		['region identifier', map => { map.data.get('json', 'regions_0').id = 'japan'; }],
		['mixed settings and region matching', map => { map.data.get('json', 'settings').access_mode = 'session'; map.data.get('json', 'regions_0').pattern = 'Japan'; }]
	]) {
		const changed = settingsEditor(regions);
		edit(changed.map);
		await changed.owner.handleSave();
		assertNotice(publishNotice, `${reason} changes retain the publication reminder`);
	}
	const sourceOwner = {}, sourceMap = hs.createMap(sourceOwner, { config: { sources: [{ id: 'a', url: '', has_url: true }] }, version: 'source-v1' }, ['sources']);
	const largeOwner = {}, largeConfig = {
		schema: 1, sources: [{ id: 'source', url: '', has_url: true }],
		rules: [{ id: 'large-rule', value: 'example'.repeat(12000) }], profiles: [], groups: []
	};
	hs.createMap(largeOwner, { config: largeConfig, version: 'large-v1' }, ['sources']);
	assert(Buffer.byteLength(JSON.stringify(largeConfig)) > 65536);
	await largeOwner.handleSave();
	const partial = sent.filter(call => call.method === 'save_config').at(-1);
	assert.deepEqual(partial.args[2], ['sources']);
	assert.deepEqual(Object.keys(JSON.parse(partial.args[0])), ['sources']);
	assert(Buffer.byteLength(JSON.stringify(partial.args)) < 4096, 'source actions do not send the large routing configuration through /ubus');
	assert.equal(largeOwner.config.rules[0].value, largeConfig.rules[0].value, 'partial saves retain unrelated editor state');
	sourceMap.data.get('json', 'sources_0').url = 'https://example.invalid/subscription';
	await sourceOwner.handleSave();
	assertNotice(publishNotice, 'source-only edits retain the publication reminder');
	assert.equal(sourceOwner.config.sources[0].url, '', 'notification classification does not alter secret cleanup');
	console.log(`${modules} modules parse; i18n (en/zh-cn/extensible), JSONMap, native tabs, filter/sort draft preservation, save notifications, display names, quota RPC/secret cleanup, native JSON, rule normalization and graph zoom/navigation pass.`);
}
editorChecks().catch(error => { console.error(error); process.exitCode = 1; });
