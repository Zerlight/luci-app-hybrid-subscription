'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const E = (tag, attrs = {}, children = []) => ({ tag, attrs, children: Array.isArray(children) ? children : [children] });
const nodes = value => value && typeof value === 'object' ? [value, ...(value.children || []).flatMap(nodes)] : [];
const maps = [], checks = [], calls = [];
let modal;
class Section {
	constructor(map, type) { this.map = map; this.type = type; map.sections.push(this); }
	tab() {}
	option(type, key, title, ...args) {
		const option = { key, type, title, section: this, choices: [], value(id, name) { this.choices.push([id, name]); }, depends() {} };
		if (type === 'SectionValue') option.subsection = new Section(this.map, args[0]);
		this.map.options.push(option); return option;
	}
	taboption(tab, ...args) { const option = this.option(...args); option.tab = tab; return option; }
}
class JSONMap {
	constructor(data) {
		this.rows = {}; this.options = []; this.sections = []; this.parses = 0;
		this.root = Object.assign(E('form'), { attached: false, bindingPurged: false,
			addEventListener() {}, remove() { this.attached = false; } });
		Object.entries(data).forEach(([type, value]) => (Array.isArray(value) ? value : [value]).forEach(row => {
			const name = row['.name'] || type; this.rows[name] = { ...row, '.type': type, '.name': name };
		}));
		this.data = { get: (_, id, key) => key ? this.rows[id][key] : this.rows[id],
			set: (_, id, key, value) => { this.rows[id][key] = value; } };
		maps.push(this);
	}
	section(type, id) { return new Section(this, id); }
	parse() {
		if (this.root.bindingPurged) throw new Error('LuCI form bindings were purged before parse');
		this.parses++; return Promise.resolve();
	}
	render() {
		if (this.root.bindingPurged) throw new Error('LuCI form bindings were purged before render');
		return Promise.resolve(this.root);
	}
}
function purgeModalBindings() {
	// LuCI clears widget bindings on roots still attached to the replaced modal.
	nodes(modal).filter(node => node.tag === 'form' && node.attached).forEach(node => {
		node.bindingPurged = true; node.attached = false;
	});
}
const ui = {
	showModal: (title, children) => {
		purgeModalBindings(); modal = E('modal', { title }, children);
		nodes(modal).filter(node => node.tag === 'form').forEach(node => { node.attached = true; });
	},
	hideModal() { purgeModalBindings(); modal = undefined; },
	cancelModal(event) {
		if (event.key !== 'Escape') return;
		// Native LuCI activates the first footer button; it does not look up Cancel by label.
		const footer = nodes(modal).find(node => node.attrs && node.attrs.class === 'right');
		const first = footer && footer.children.find(node => node && node.tag === 'button');
		if (first) return first.attrs.action();
	},
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
const proposed = { available: true, mode: 'url-test', reason: 'Use latency testing; Smart decisions are not preserved.' };
const group = (id, modes = ['smart', 'smart', 'selector']) => ({ id, name: id, modes: { mihomo: modes[0], surge: modes[1], singbox: modes[2] },
	alternatives: { mihomo: ['manual', 'url-test', 'fallback'], surge: ['manual', 'url-test', 'fallback'], singbox: ['manual', 'url-test'] },
	suggestions: id === 'stable' ? {} : { surge: proposed, singbox: proposed } });
const issues = ['proxy', 'backup'].map(id => ({ id, code: 'group:' + id, kind: 'group', severity: 'warning', message: 'Repeated warning for ' + id }));
issues.push({ id: 'entry', code: 'rematch:entry', kind: 'rematch', severity: 'error', message: 'Choose a replacement' });
const report = {
	profile: { id: 'main', name: 'Main' },
	targets: [
		{ format: 'mihomo', errors: [], warnings: [], issues: [] },
		{ format: 'surge', errors: ['Unsupported node transport'], warnings: issues.slice(0, 2).map(issue => ({ code: 'surge:' + issue.code, message: issue.message })), issues },
		{ format: 'singbox', errors: [], warnings: [{ message: 'Review DNS behavior' }], issues: issues.slice(0, 2) }
	],
	choices: { policies: [{ id: 'DIRECT', name: 'DIRECT' }, { id: 'REJECT', name: 'REJECT' }, { id: 'proxy', name: 'Proxy' }, { id: 'backup', name: 'Backup' }],
		rematches: [{ id: 'entry', name: 'Entry', suggestions: { surge: { available: true, mode: 'manual', members: ['proxy', 'backup'], reason: 'Review the candidate order.' },
			singbox: { available: false, reason: 'Choose candidates manually.' } } }],
		groups: [group('proxy'), group('backup'), group('stable', ['select', 'select', 'selector'])],
		rules: [{ id: 'geo', name: 'Geo rule', type: 'GEOSITE', targets: ['surge', 'singbox'] }, { id: 'domain', name: 'Domain', type: 'DOMAIN', targets: [] }],
		sub_rules: [{ id: 'branch' }], has_dns: true, has_mihomo_policy: true }
};
const plan = { version: 'version-1', plan_token: 'cache-bound-token', ready: true, changes: [
	{ code: 'group-mode:proxy', message: 'Change proxy mode' }, { code: 'group-mode:backup', message: 'Change backup mode' },
	{ code: 'omit-mihomo_dns', message: 'Change DNS behavior' }, { code: 'future:change', message: 'A future change' }
], errors: [], warnings: [] };
let currentReport = report, reviewReport, currentPlan = plan, writable = true;
const requests = [], notifications = [];
const hs = {
	translateMessage: native.translateMessage,
	notify: error => notifications.push(error.message),
	table: (heads, rows) => E('table', {}, rows.flat()),
	button: (label, action, style, writes) => E('button', { action, writes }, label),
	api: async (method, args) => { requests.push({ method, args }); return method === 'compatibility' ? args.review ? reviewReport : currentReport : method === 'compatibility_plan' ? currentPlan : {}; }
};
const window = { location: { search: '?profile=main' } };
const types = Object.fromEntries(['NamedSection', 'TableSection', 'SectionValue', 'DummyValue', 'Button', 'ListValue', 'Value', 'Flag', 'MultiValue', 'DynamicList'].map(t => [t, t]));
const page = new Function('view', 'form', 'ui', 'dom', 'hs', 'E', '_', 'L', 'window',
	fs.readFileSync(path.join(root, 'htdocs/luci-static/resources/view/hybrid-subscription/compatibility.js'), 'utf8'))(
	{ extend: x => x }, { JSONMap, ...types }, ui, { content: (node, child) => { node.children = [child]; } }, hs, E, native.t, { url: x => '/' + x, hasViewPermission: () => writable }, window
);
const button = label => nodes(modal).find(node => node.tag === 'button' && node.children[0] === label);
const option = (map, key) => map.options.find(o => o.key === key);
(async () => {
	const rendered = await page.render({ config: { profiles: [{ id: 'main', name: 'Main' }, { id: 'main_surge' }] } });
	const renderedText = JSON.stringify(rendered);
	assert.match(renderedText, /Blocked/); assert.match(renderedText, /Review Differences/);
	assert.equal(requests.length, 1, 'initial report reads only');
	assert.equal((renderedText.match(/Use latency testing; Smart decisions are not preserved\./g) || []).length, 1, 'same-mode group explanation appears once');
	assert.doesNotMatch(renderedText, /Repeated warning/, 'renderer warnings mirrored by issues are not printed again');
	assert.match(renderedText, /Unsupported node transport/, 'unassociated export blockers remain visible in diagnostics');
	assert.doesNotMatch(renderedText, /Review DNS behavior/, 'only the selected client has details');
	await nodes(rendered).filter(n => n.tag === 'button' && n.children[0] === 'View Suggestions')[2].attrs.action();
	assert.match(JSON.stringify(rendered), /Review DNS behavior/);
	assert.doesNotMatch(JSON.stringify(rendered), /Unsupported node transport/, 'switching client replaces the details');
	native.setLocale('zh_Hans');
	assert.match(JSON.stringify(page.reportContent(report)), /存在阻塞项/);
	assert.match(native.translateMessage('Change group Proxy (proxy) for singbox: fallback -> urltest (Mihomo reference: fallback); latency testing selects by measured delay; it does not preserve Smart or regional matching behavior'), /延迟测速/);
	native.setLocale('en');
	await page.wizard(report, 'surge');
	const canceled = maps.at(-1), beforeCancel = requests.length;
	await ui.cancelModal({ key: 'Escape' });
	assert.equal(modal, undefined, 'native Escape must close the wizard');
	assert.equal(canceled.parses, 0, 'cancel must not parse or fill suggestions');
	assert.equal(canceled.rows.group_0.mode, ''); assert.equal(canceled.rows.rematch_0.replacement, '');
	assert.equal(requests.length, beforeCancel, 'cancel must not preview or save');
	await page.wizard(report, 'surge');
	const wizard = maps.at(-1);
	const wizardRoot = wizard.root;
	assert.equal(wizardRoot.attached, true);
	assert.equal(wizard.rows.copy.id, 'main_surge_2');
	assert.equal(wizard.rows.copy.omit_dns, undefined);
	assert.equal(wizard.rows.rematch_0.replacement, '', 'manual path does not preselect an adaptation');
	const groupTable = wizard.sections.find(s => s.type === 'group');
	assert.equal(groupTable.filter('group_0'), true); assert.equal(groupTable.filter('group_2'), false, 'compatible groups are hidden by default');
	assert.deepEqual(option(wizard, 'disable_rules').choices.map(c => c[0]), ['geo'], 'rule picker only offers target-incompatible rules');
	wizard.rows.copy.name = 'Edited name';
	wizard.rows.group_0.mode = 'keep';
	await button('Fill Unset Suggestions').attrs.action();
	assert.equal(wizard.root, wizardRoot, 'LuCI reuses the form root when the wizard is rerendered');
	assert.equal(wizardRoot.bindingPurged, false, 'rerender must detach the root before replacing the modal');
	assert.equal(wizardRoot.attached, true);
	assert.ok(wizard.parses > 0, 'capture live form edits before filling suggestions');
	assert.equal(wizard.rows.copy.name, 'Edited name');
	assert.equal(wizard.rows.group_0.mode, 'keep', 'explicit keep choice survives applying suggestions');
	assert.equal(wizard.rows.group_1.mode, 'url-test');
	assert.equal(wizard.rows.group_2.mode, '', 'compatible groups stay unchanged');
	assert.equal(wizard.rows.rematch_0.replacement, '__manual');
	assert.deepEqual(wizard.rows.rematch_0.members, ['proxy', 'backup']);
	assert.equal(wizard.rows.copy.omit_dns, undefined); assert.equal(wizard.rows.copy.abandon_sub_rules, undefined);
	assert.deepEqual(wizard.rows.copy.disable_rules, [], 'suggestions never opt into deletions');
	wizard.rows.copy.batch_mode = 'manual';
	await option(wizard, '_batch').onclick();
	assert.equal(wizard.rows.group_0.mode, 'manual', 'explicit batch action replaces an affected group keep choice');
	assert.equal(wizard.rows.group_1.mode, 'manual', 'explicit batch action replaces an affected group suggestion');
	assert.equal(wizard.rows.group_2.mode, '', 'batch action leaves unaffected groups unchanged');
	await option(wizard, '_show_groups').onclick(); assert.equal(groupTable.filter('group_2'), true);
	wizard.rows.group_2.mode = 'url-test';
	await option(wizard, '_show_groups').onclick(); assert.equal(groupTable.filter('group_2'), true, 'a changed group remains visible when filtering');
	wizard.rows.copy.abandon_sub_rules = '1'; wizard.rows.copy.omit_dns = '1'; wizard.rows.copy.disable_rules = ['geo'];
	await button('Preview Changes').attrs.action();
	assert.equal(wizardRoot.attached, false, 'preview preserves the detached form for Back');
	assert.equal(wizardRoot.bindingPurged, false, 'confirmation must not purge the reusable wizard bindings');
	const preview = requests.at(-1);
	assert.equal(preview.method, 'compatibility_plan');
	assert.deepEqual(JSON.parse(preview.args.resolutions), { rematches: { entry: { mode: 'manual', members: ['proxy', 'backup'] } }, group_modes: { proxy: 'manual', backup: 'manual', stable: 'url-test' }, disable_rules: ['geo'], abandon_sub_rules: true, omit_dns: true, omit_mihomo_policy: false });
	assert.equal(checks.length, 3, 'four exact changes require three category acknowledgments, with unknown changes kept');
	assert.match(JSON.stringify(modal), /Change proxy mode/); assert.match(JSON.stringify(modal), /Change backup mode/); assert.match(JSON.stringify(modal), /A future change/);
	assert.throws(() => button('Create Independent Draft').attrs.action(), /Confirm every change category/);
	checks.at(-1).checked = true; checks.at(-2).checked = true;
	assert.throws(() => button('Create Independent Draft').attrs.action(), /Confirm every change category/);
	await button('Back').attrs.action();
	assert.equal(wizard.root, wizardRoot); assert.equal(wizardRoot.attached, true, 'Back reattaches the original form root');
	assert.equal(wizard.rows.group_1.mode, 'manual'); assert.equal(wizard.rows.copy.name, 'Edited name');
	await button('Preview Changes').attrs.action();
	assert.equal(checks.at(-1).checked, false, 'a new preview resets category consent');
	checks.slice(-3).forEach(check => { check.checked = true; });
	await button('Create Independent Draft').attrs.action();
	assert.deepEqual(requests.at(-1).args.accepted_changes, plan.changes.map(change => change.code), 'submit all exact change codes, never category IDs');
	assert.equal(requests.at(-1).args.plan_token, 'cache-bound-token'); assert.equal(requests.at(-1).args.version, 'version-1');
	assert.match(window.location.href, /profile=main_surge_2$/);
	await page.wizard(report, 'surge', true);
	const suggested = maps.at(-1);
	assert.equal(suggested.rows.group_0.mode, 'url-test'); assert.equal(suggested.rows.rematch_0.replacement, '__manual');
	assert.equal(suggested.rows.copy.omit_dns, undefined);
	suggested.rows.group_2.mode = 'fallback'; suggested.rows.copy.batch_mode = 'manual';
	await option(suggested, '_batch').onclick();
	assert.equal(suggested.rows.group_0.mode, 'manual'); assert.equal(suggested.rows.group_1.mode, 'manual', 'prefilled groups can switch mode in one batch action');
	assert.equal(suggested.rows.group_2.mode, 'fallback', 'batch action preserves an unaffected group override');
	assert.equal(suggested.rows.rematch_0.replacement, '__manual'); assert.deepEqual(suggested.rows.rematch_0.members, ['proxy', 'backup']);
	assert.equal(suggested.rows.copy.omit_dns, undefined); assert.equal(suggested.rows.copy.abandon_sub_rules, undefined); assert.deepEqual(suggested.rows.copy.disable_rules, []);
	await button('Fill Unset Suggestions').attrs.action();
	assert.equal(suggested.rows.group_0.mode, 'manual'); assert.equal(suggested.rows.group_1.mode, 'manual', 'ordinary suggestions still preserve explicit batch choices');
	await page.wizard(report, 'singbox', true);
	const downgrade = maps.at(-1);
	assert.equal(downgrade.rows.rematch_0.replacement, '', 'unavailable suggestions never guess a replacement');
	assert.equal(option(downgrade, 'mode').choices.some(c => c[0] === 'fallback'), false);
	assert.equal(option(downgrade, 'members').choices.some(c => c[0] === 'REJECT'), false);
	page.confirmPlan({ ...plan, ready: false, errors: ['Still blocked'] }, preview.args, () => {});
	assert.equal(button('Create Independent Draft'), undefined, 'unresolved blockers cannot be saved as compatible');
	const strategy = { id: 'saved_surge', name: 'My Surge Copy', format: 'surge', source_profile: 'main', source_changed: true, target_changed: true, source_missing: false, needs_review: true,
		resolutions: { group_modes: { proxy: 'keep' }, rematches: { entry: { mode: 'manual', members: ['backup', 'proxy'] } }, disable_rules: ['domain'], omit_dns: true },
		invalidated: [{ code: 'subrules-changed', resolution: 'abandon_sub_rules', message: 'Sub-rule routing changed; choose whether to remove it again.' },
			{ code: 'group_modes:removed_one', resolution: 'group_modes', id: 'removed_one', message: 'The source content or a referenced policy changed; review this saved choice again.' },
			{ code: 'group_modes:removed_two', resolution: 'group_modes', id: 'removed_two', message: 'The source content or a referenced policy changed; review this saved choice again.' }] };
	const linkedReport = { ...report, derived_profiles: [strategy] };
	const linked = page.reportContent(linkedReport);
	assert.match(JSON.stringify(linked), /Saved compatible copies/); assert.match(JSON.stringify(linked), /My Surge Copy/);
	assert.match(JSON.stringify(linked), /Source policy changed/); assert.match(JSON.stringify(linked), /local edits/);
	assert.ok(nodes(linked).some(node => node.tag === 'a' && node.attrs.href.endsWith('?profile=saved_surge')), 'saved copy links identify the existing profile');
	const reviewButton = nodes(linked).find(node => node.tag === 'button' && node.children[0] === 'Review and Update Copy');
	assert.equal(reviewButton.attrs.writes, true, 'review entry uses the native write-permission gate');
	reviewReport = { ...report, strategy };
	await reviewButton.attrs.action();
	assert.deepEqual(requests.at(-1), { method: 'compatibility', args: { profile: 'saved_surge', review: true } }, 'review fetches fresh source choices and filtered saved decisions');
	const update = maps.at(-1), updateRoot = update.root;
	assert.equal(update.rows.copy.id, 'saved_surge'); assert.equal(update.rows.copy.name, 'My Surge Copy');
	assert.equal(option(update, 'id').readonly, true); assert.equal(option(update, 'name').readonly, true);
	assert.equal(update.rows.group_0.mode, 'keep', 'a saved explicit keep decision is restored'); assert.equal(update.rows.group_1.mode, '', 'new affected groups are not silently filled');
	assert.equal(update.rows.rematch_0.replacement, '__manual'); assert.deepEqual(update.rows.rematch_0.members, ['backup', 'proxy'], 'saved first-choice order survives reopening');
	assert.equal(update.rows.copy.omit_dns, '1'); assert.equal(update.rows.copy.abandon_sub_rules, undefined, 'cleared destructive choices stay unselected');
	assert.match(JSON.stringify(modal), /Some saved choices were cleared/); assert.match(JSON.stringify(modal), /Sub-rule routing changed/);
	assert.match(JSON.stringify(modal), /removed_one/); assert.match(JSON.stringify(modal), /removed_two/, 'repeated invalidation reasons still identify every cleared choice');
	assert.deepEqual(option(update, 'disable_rules').choices.map(choice => choice[0]), ['geo', 'domain'], 'a saved disabled rule remains visible and reversible even if it no longer blocks the target');
	await button('Fill Unset Suggestions').attrs.action();
	assert.equal(update.rows.group_0.mode, 'keep', 'filling recommendations after reopening must preserve an explicit keep decision');
	assert.equal(update.rows.group_1.mode, 'url-test', 'only the previously unset affected group receives a suggestion');
	update.rows.rematch_0.members.push('DIRECT');
	assert.deepEqual(strategy.resolutions.rematches.entry.members, ['backup', 'proxy'], 'editing a form does not mutate the saved strategy response');
	update.rows.copy.id = 'tampered'; update.rows.copy.name = 'Tampered';
	currentPlan = { ...plan, changes: [{ code: 'replace-target', message: 'Replace the locally edited draft after review' }, { code: 'remove-target-rule:old', message: 'Remove the previous copy rule' }, ...plan.changes] };
	let previousChecks = checks.length;
	await button('Preview Changes').attrs.action();
	const updatePreview = requests.at(-1);
	assert.equal(updatePreview.method, 'compatibility_plan');
	assert.equal(updatePreview.args.operation, 'reapply'); assert.equal(updatePreview.args.profile, 'main');
	assert.deepEqual(JSON.parse(updatePreview.args.resolutions).group_modes, { proxy: 'keep', backup: 'url-test' }, 'preview persists explicit keep separately from groups with no decision');
	assert.equal(updatePreview.args.id, 'saved_surge'); assert.equal(updatePreview.args.name, 'My Surge Copy', 'update identity comes from the saved copy, not editable form data');
	assert.equal(updateRoot.bindingPurged, false); assert.equal(updateRoot.attached, false);
	assert.equal(checks.slice(previousChecks).every(check => !check.checked), true, 'reused choices never reuse prior category consent');
	assert.match(JSON.stringify(modal), /published subscription stays unchanged/); assert.match(JSON.stringify(modal), /Remove the previous copy rule/);
	assert.throws(() => button('Update Compatible Draft').attrs.action(), /Confirm every change category/);
	checks.slice(previousChecks).forEach(check => { check.checked = true; });
	await button('Back').attrs.action();
	assert.equal(updateRoot.bindingPurged, false); assert.equal(updateRoot.attached, true, 'update review Back preserves native form bindings');
	previousChecks = checks.length;
	await button('Preview Changes').attrs.action();
	assert.equal(checks.slice(previousChecks).every(check => !check.checked), true, 'another update preview resets all consent');
	checks.slice(previousChecks).forEach(check => { check.checked = true; });
	await button('Update Compatible Draft').attrs.action();
	assert.equal(requests.at(-1).method, 'compatibility_update');
	assert.deepEqual(requests.at(-1).args.accepted_changes.slice().sort(), currentPlan.changes.map(change => change.code).sort(), 'update includes every exact replacement/removal code');
	assert.equal(requests.at(-1).args.plan_token, currentPlan.plan_token); assert.equal(requests.at(-1).args.version, currentPlan.version);
	assert.match(window.location.href, /profile=saved_surge$/, 'update keeps the existing profile and subscription identity');
	const copyReport = { ...report, profile: { id: 'saved_surge', name: 'My Surge Copy' }, strategy };
	const copyContent = page.reportContent(copyReport);
	assert.match(JSON.stringify(copyContent), /Source profile: main/); assert.match(JSON.stringify(copyContent), /View Source Profile/);
	const missing = { ...strategy, source_missing: true };
	const orphaned = page.reportContent({ ...copyReport, strategy: missing });
	assert.match(JSON.stringify(orphaned), /saved copy can still be used/);
	assert.equal(nodes(orphaned).some(node => node.tag === 'button' && node.children[0] === 'Review and Update Copy'), false, 'orphaned copies have no update action');
	reviewReport = { ...copyReport, strategy: missing };
	await assert.rejects(page.review('saved_surge'), /source profile is missing/, 'a source removed between report and review never opens an update wizard');
	reviewReport = { ...report, strategy };
	currentReport = copyReport;
	window.location.search = '?profile=saved_surge&review=1';
	const config = { profiles: [{ id: 'main', name: 'Main' }, { id: 'saved_surge', name: 'My Surge Copy' }] };
	let previousRequests = requests.length;
	await page.render({ config });
	assert.deepEqual(requests.slice(previousRequests).map(request => request.args), [{ profile: 'saved_surge' }, { profile: 'saved_surge', review: true }], 'overview review deep link reads the copy and opens its source-based wizard');
	assert.equal(maps.at(-1).rows.copy.id, 'saved_surge');
	await ui.cancelModal({ key: 'Escape' }); assert.equal(modal, undefined, 'Escape still cancels a reopened update form');
	writable = false; previousRequests = requests.length;
	await page.render({ config });
	assert.equal(requests.length - previousRequests, 1, 'read-only access does not auto-open an update wizard from a URL');
	writable = true; currentReport = { ...copyReport, strategy: missing }; previousRequests = requests.length;
	await page.render({ config });
	assert.equal(requests.length - previousRequests, 1, 'missing-source deep links remain a read-only report');
	currentReport = copyReport; reviewReport = { ...copyReport, strategy: missing };
	const interruptedReview = await page.render({ config });
	assert.match(JSON.stringify(interruptedReview), /Saved conversion/, 'a source removed during automatic review leaves the normal report usable');
	assert.match(notifications.at(-1), /source profile is missing/); assert.equal(modal, undefined);
	page.confirmPlan({ ...currentPlan, ready: false, errors: ['Still blocked'] }, updatePreview.args, () => {});
	assert.equal(button('Update Compatible Draft'), undefined, 'unresolved update blockers cannot replace a saved copy');
	await native.api('compatibility_create', { profile: 'main', format: 'surge', id: 'copy', name: 'Copy', resolutions: '{}', version: 'v', plan_token: 't', accepted_changes: ['c'] });
	assert.deepEqual(calls.at(-1), { method: 'compatibility_create', args: ['main', 'surge', 'copy', 'Copy', '{}', 'v', 't', ['c']] });
	await native.api('compatibility_update', { profile: 'main', format: 'surge', id: 'copy', name: 'Copy', resolutions: '{}', operation: 'reapply', version: 'v', plan_token: 't', accepted_changes: ['c'] });
	assert.deepEqual(calls.at(-1), { method: 'compatibility_update', args: ['main', 'surge', 'copy', 'Copy', '{}', 'v', 't', ['c']] });
	await native.api('compatibility', { profile: 'copy', review: true });
	assert.deepEqual(calls.at(-1), { method: 'compatibility', args: ['copy', true] });
	await native.api('compatibility_plan', { profile: 'main', format: 'surge', id: 'copy', name: 'Copy', resolutions: '{}', operation: 'reapply' });
	assert.deepEqual(calls.at(-1), { method: 'compatibility_plan', args: ['main', 'surge', 'copy', 'Copy', '{}', 'reapply'] });
	console.log('Compatibility UI: grouped reports, reusable choices, explicit update review, native form lifecycle and exact consent pass.');
})().catch(error => { console.error(error); process.exitCode = 1; });
