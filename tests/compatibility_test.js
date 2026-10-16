'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const E = (tag, attrs = {}, children = []) => ({ tag, attrs, children: Array.isArray(children) ? children : [children] });
const nodes = value => value && typeof value === 'object' ? [value, ...(value.children || []).flatMap(nodes)] : [];
const maps = [], checks = [], calls = [];
let modal;
class JSONMap {
	constructor(data) {
		this.rows = data; this.options = [];
		this.data = { get: (_, id, key) => key ? data[id][key] : data[id] };
		maps.push(this);
	}
	section() {
		const map = this;
		return { tab() {}, taboption(tab, type, key, title) {
			const option = { key, type, title, choices: [], value(id, name) { this.choices.push([id, name]); }, depends() {} };
			map.options.push(option); return option;
		}, option(type, key, title) { return this.taboption('', type, key, title); } };
	}
	parse() { return Promise.resolve(); }
	render() { return Promise.resolve(E('form')); }
}
const ui = {
	showModal: (title, children) => { modal = E('modal', { title }, children); }, hideModal() {},
	Checkbox: class {
		constructor() { this.checked = false; this.id = 'check-' + checks.length; checks.push(this); }
		render() { return { querySelector: () => ({ id: this.id }) }; }
		isChecked() { return this.checked; }
	}
};
const native = new Function('baseclass', 'form', 'rpc', 'ui', 'poll', 'uqr', 'L', 'E', '_', 'document',
	fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/hybrid-subscription.js'), 'utf8'))(
	{ extend: x => x }, {}, { declare: spec => (...args) => { calls.push({ method: spec.method, args }); return Promise.resolve({ ok: true }); } }, ui, {}, {},
	{ env: { lang: 'en' } }, E, x => x, {}
);
const report = {
	profile: { id: 'main', name: 'Main' },
	targets: [
		{ format: 'mihomo', errors: [], warnings: [], issues: [] },
		{ format: 'surge', errors: ['rematch policy'], warnings: [], issues: [{ id: 'entry', message: 'Choose a replacement' }] },
		{ format: 'singbox', errors: [], warnings: [{ message: 'Review DNS behavior' }], issues: [] }
	],
	choices: { policies: [{ id: 'DIRECT', name: 'DIRECT' }, { id: 'REJECT', name: 'REJECT' }, { id: 'proxy', name: 'Proxy' }], rematches: [{ id: 'entry', name: 'Entry' }],
		groups: [{ id: 'proxy', name: 'Proxy', modes: { mihomo: 'smart', surge: 'smart', singbox: 'selector' }, alternatives: { mihomo: ['manual', 'url-test', 'fallback'], surge: ['manual', 'url-test', 'fallback'], singbox: ['manual', 'url-test'] } }],
		rules: [{ id: 'geo', name: 'Geo rule', type: 'GEOSITE', targets: ['surge', 'singbox'] }], sub_rules: [{ id: 'branch' }], has_dns: true, has_mihomo_policy: true }
};
const plan = { version: 'version-1', plan_token: 'cache-bound-token', ready: true, changes: [{ code: 'drop:geo', message: 'Disable geo' }], errors: [], warnings: [] };
const requests = [];
const hs = {
	translateMessage: native.translateMessage,
	table: (heads, rows) => E('table', {}, rows.flat()),
	button: (label, action, style, writes) => E('button', { action, writes }, label),
	api: async (method, args) => { requests.push({ method, args }); return method === 'compatibility' ? report : method === 'compatibility_plan' ? plan : {}; }
};
const window = { location: { search: '?profile=main' } };
const page = new Function('view', 'form', 'ui', 'dom', 'hs', 'E', '_', 'L', 'window',
	fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/view/hybrid-subscription/compatibility.js'), 'utf8'))(
	{ extend: x => x }, { JSONMap, NamedSection: {}, ListValue: {}, Value: {}, Flag: {}, MultiValue: {}, DynamicList: {} }, ui,
	{ content: (node, child) => { node.children = [child]; } }, hs, E, native.t, { url: x => '/' + x }, window
);
const button = label => nodes(modal).find(node => node.tag === 'button' && node.children[0] === label);
(async () => {
	const rendered = await page.render({ config: { profiles: [{ id: 'main', name: 'Main' }, { id: 'main_surge' }] } });
	assert.match(JSON.stringify(rendered), /Blocked/);
	assert.match(JSON.stringify(rendered), /Review Differences/);
	const modeDifference = { ...report, targets: [{ format: 'surge', errors: [], warnings: [], issues: [{ severity: 'warning', message: 'Automation differs' }] }] };
	assert.match(JSON.stringify(page.reportContent(modeDifference)), /Review Differences/, 'automation differences require review even when syntax is compatible');
	assert.equal(requests.length, 1, 'initial report reads only, without creating or refreshing');
	native.setLocale('zh_Hans');
	assert.match(JSON.stringify(page.reportContent(report)), /兼容性向导/);
	assert.match(JSON.stringify(page.reportContent(report)), /存在阻塞项/);
	assert.match(native.translateMessage('Change group Proxy (proxy) for singbox: fallback -> urltest (Mihomo reference: fallback); latency testing selects by measured delay; it does not preserve Smart or regional matching behavior'), /延迟测速按测得的延迟选择候选策略；不保留 Smart 智能选择或地区匹配行为/);
	assert.match(native.translateMessage('Replace rematch Region (entry) with manual group; candidates: Proxy (proxy), DIRECT; manual selection does not automatically switch candidates or preserve Smart behavior; sing-box manual selection requires client selection controls or its API; otherwise the first candidate is used; regional re-evaluation is no longer performed in the new profile'), /否则将使用第一个候选策略；新配置将不再执行原有的地区二次匹配/);
	native.setLocale('en');
	await page.wizard(report, 'surge');
	const wizard = maps.at(-1);
	assert.equal(wizard.rows.copy.id, 'main_surge_2');
	assert.equal(wizard.rows.copy.omit_dns, undefined, 'DNS removal must not be preselected');
	assert.equal(wizard.rows.copy.rematch_0, undefined, 'never pick a replacement policy automatically');
	wizard.rows.copy.rematch_0 = 'proxy';
	wizard.rows.copy.abandon_sub_rules = '1';
	wizard.rows.copy.omit_dns = '1';
	wizard.rows.copy.disable_rules = ['geo'];
	await button('Preview Changes').attrs.action();
	const preview = requests.at(-1);
	assert.equal(preview.method, 'compatibility_plan');
	assert.deepEqual(JSON.parse(preview.args.resolutions), { rematches: { entry: 'proxy' }, group_modes: {}, disable_rules: ['geo'], abandon_sub_rules: true, omit_dns: true, omit_mihomo_policy: false });
	assert.throws(() => button('Create Independent Draft').attrs.action(), /Confirm every/);
	assert.equal(requests.at(-1).method, 'compatibility_plan', 'unconfirmed plan must not write');
	await button('Back').attrs.action();
	assert.equal(wizard.rows.copy.rematch_0, 'proxy', 'back preserves explicit decisions');
	await button('Preview Changes').attrs.action();
	checks.at(-1).checked = true;
	await button('Create Independent Draft').attrs.action();
	assert.deepEqual(requests.at(-1).args.accepted_changes, ['drop:geo']);
	assert.equal(requests.at(-1).args.plan_token, 'cache-bound-token');
	assert.equal(requests.at(-1).args.version, 'version-1');
	assert.match(window.location.href, /profile=main_surge_2$/);
	await page.wizard(report, 'singbox');
	const downgrade = maps.at(-1);
	assert.match(JSON.stringify(modal), /requires a client with selector controls/);
	assert.equal(downgrade.rows.copy.group_mode_0, undefined, 'never preselect an automation downgrade');
	assert.equal(downgrade.options.find(o => o.key === 'group_mode_0').choices.some(choice => choice[0] === 'fallback'), false, 'do not offer unsupported fallback mode in sing-box');
	assert.equal(downgrade.options.find(o => o.key === 'rematch_members_0').choices.some(choice => choice[0] === 'REJECT'), false, 'sing-box cannot select a reject outbound');
	downgrade.rows.copy.rematch_0 = '__manual';
	downgrade.rows.copy.rematch_members_0 = ['proxy', 'DIRECT'];
	downgrade.rows.copy.group_mode_0 = 'url-test';
	await button('Preview Changes').attrs.action();
	const reduced = JSON.parse(requests.at(-1).args.resolutions);
	assert.deepEqual(reduced.rematches.entry, { mode: 'manual', members: ['proxy', 'DIRECT'] });
	assert.deepEqual(reduced.group_modes, { proxy: 'url-test' });
	await button('Back').attrs.action();
	assert.deepEqual(downgrade.rows.copy.rematch_members_0, ['proxy', 'DIRECT'], 'back retains the chosen candidates');
	page.confirmPlan({ ...plan, ready: false, errors: ['Still blocked'] }, preview.args, () => {});
	assert.equal(button('Create Independent Draft'), undefined, 'unresolved blockers cannot be saved as compatible');
	await native.api('compatibility_create', { profile: 'main', format: 'surge', id: 'copy', name: 'Copy', resolutions: '{}', version: 'v', plan_token: 't', accepted_changes: ['c'] });
	assert.deepEqual(calls.at(-1), { method: 'compatibility_create', args: ['main', 'surge', 'copy', 'Copy', '{}', 'v', 't', ['c']] });
	console.log('Compatibility UI: client reports, native form decisions, localization, confirmation gates, stale-plan fields and blocked creation pass.');
})().catch(error => { console.error(error); process.exitCode = 1; });
