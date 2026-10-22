'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(path.join(__dirname, '../htdocs/luci-static/resources/view/hybrid-subscription/sources.js'), 'utf8');
const calls = [], rows = {
	saved: { id: 'saved', url: '', quota_url: '', has_url: true, has_quota_url: true },
	other: { id: 'other', url: '', quota_url: '', has_url: true },
	file: { id: 'file', url: '', quota_url: '', has_url: false },
	new: { id: 'new', url: '', quota_url: '' }
};
const map = {
	data: {
		get: (_, sid, key) => key ? rows[sid][key] : rows[sid],
		set: (_, sid, key, value) => { rows[sid][key] = value; }
	},
	render: () => section
};
const section = {
	children: [], tabs: {},
	tab(key) { this.tabs[key] = { children: [] }; }
};
function option(key) {
	const value = { option: key, depends() {} };
	section.children.push(value);
	return value;
}
const page = new Function('view', 'form', 'ui', 'hs', 'E', '_', source)(
	{ extend: value => value }, {}, {}, {
		createMap(owner) {
			owner.config = { sources: Object.values(rows).filter(row => row.id !== 'new').map(row => ({ ...row })) };
			return map;
		},
		grid: () => section,
		value: (_, type, key) => option(key),
		choices: value => value,
		rowAction: (_, key) => option(key),
		sectionActions() {},
		api: async (method, args) => {
			calls.push({ method, args });
			if (args.source === 'other') throw new Error('Read denied');
			return { url: 'https://fixture.invalid/subscription', quota_url: 'https://fixture.invalid/quota' };
		}
	}, () => {}, value => value
);

async function checks() {
	page.render([{}, { sources: [] }]);
	assert.deepEqual(calls, [], 'rendering the source list does not retrieve any saved URLs');
	assert.equal(section.children.find(value => value.option === 'has_url'), undefined, 'the saved address flag is not rendered as a field');
	assert.ok(section.children.find(value => value.option === 'has_quota_url'), 'the quota address status is retained');
	assert.equal(section.children.find(value => value.option === 'url').password, true);
	assert.equal(section.children.find(value => value.option === 'quota_url').password, true);
	await section.addModalOptions({}, 'saved');
	assert.deepEqual(calls, [{ method: 'source_urls', args: { source: 'saved' } }]);
	assert.equal(rows.saved.url, 'https://fixture.invalid/subscription');
	assert.equal(rows.saved.quota_url, 'https://fixture.invalid/quota');
	assert.equal(rows.other.url, '', 'only the edited source receives its saved addresses');
	rows.saved.url = 'https://fixture.invalid/edited';
	rows.saved.quota_url = '';
	rows.saved.clear_quota_url = '1';
	await section.addModalOptions({}, 'saved');
	assert.equal(rows.saved.url, 'https://fixture.invalid/edited', 'reopening an editor preserves staged changes');
	assert.equal(rows.saved.quota_url, '', 'an explicitly cleared quota URL is not restored');
	await section.addModalOptions({}, 'file');
	await section.addModalOptions({}, 'new');
	assert.equal(calls.length, 2, 'file-only and new sources do not request stored URLs');
	map.readonly = true;
	await section.addModalOptions({}, 'saved');
	assert.equal(calls.length, 2, 'read-only forms do not request secrets');
	map.readonly = false;
	await assert.rejects(section.addModalOptions({}, 'other'), /Read denied/);
	assert.equal(rows.other.url, '', 'failed reads do not pretend that saved addresses were loaded');
	console.log('Source URL editor checks passed');
}
checks().catch(error => { console.error(error); process.exitCode = 1; });
