'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
String.prototype.format = function(...values) { let i = 0; return this.replace(/%s/g, () => String(values[i++])); };
const E = (tag, attrs = {}, children = []) => ({ tag, attrs, children: Array.isArray(children) ? children : [children] });
const nodes = value => value && typeof value === 'object' ? [value, ...(value.children || []).flatMap(nodes)] : [];
let modal, build, downloads = [], requests = [], checks = [], failPublish = false;
const ui = {
 showModal(title, children) { modal = E('modal', { title }, children); },
 hideModal() { modal = undefined; },
 Checkbox: class {
  constructor(value) { this.checked = value === '1'; this.id = 'check-' + checks.length; checks.push(this); }
  render() { this.rendered = true; return { tag: 'checkbox', querySelector: () => ({ id: this.id }) }; }
  isChecked() { assert.ok(this.rendered, 'LuCI checkbox state requires rendering'); return this.checked; }
 }
};
const hs = {
 time: x => x, table: () => E('table'), translateMessage: x => x,
 button: (label, action) => E('button', { action }, label),
 runJob: async () => ({ result: build }),
 api: async (method, args) => { requests.push({ method, args }); if (failPublish) throw new Error('stale build'); return {}; },
 download: async id => downloads.push(id)
};
const overview = new Function('view', 'dom', 'poll', 'ui', 'hs', 'E', '_', 'L', 'window', fs.readFileSync(path.join(__dirname, '../htdocs/luci-static/resources/view/hybrid-subscription/overview.js'), 'utf8'))(
 { extend: x => x }, {}, {}, ui, hs, E, x => x, { url: x => x }, { location: { reload() {} } }
);
overview.config = { profiles: [{ id: 'surge', name: 'Surge' }] };
const button = (root, label) => { const found = nodes(root).find(n => n.tag === 'button' && n.children[0] === label); assert.ok(found, label); return found.attrs.action; };
const start = () => button(overview.statusContent({}), 'Build & Export')();
const warnings = Array.from({ length: 25 }, (_, i) => ({ code: 'surge:' + i, message: 'Difference ' + i, target: 'surge' }));
(async () => {
 build = { release: 'r1', warnings };
 await start();
 assert.equal(requests.length, 0);
 const list = modal.children.find(n => n.tag === 'div' && !n.attrs.class);
 assert.equal(list.children.length, 10);
 const extra = nodes(modal).find(n => n.tag === 'details');
 assert.equal(extra.children.length, 16);
 assert.equal(extra.attrs.open, undefined);
 assert.throws(button(modal, 'Confirm & Export'), /confirm all/);
 await button(modal, 'Accept All & Export')();
 assert.deepEqual(requests.at(-1), { method: 'publish', args: { release: 'r1', accepted_warnings: warnings.map(w => w.code) } });
 assert.deepEqual(downloads, ['surge']);

 checks = []; requests = []; downloads = [];
 build = { release: 'r2', warnings, reused_warnings: warnings.map(w => w.code) };
 await start();
 assert.equal(modal, undefined, 'reused warnings do not reopen the confirmation dialog');
 assert.deepEqual(requests[0].args.accepted_warnings, [], 'server revalidates automatic reuse');
 assert.deepEqual(downloads, ['surge']);

 checks = []; requests = [];
 build = { release: 'r3', warnings, reused_warnings: warnings.slice(0, 24).map(w => w.code) };
 await start();
 assert.equal(requests.length, 0, 'a new difference requires confirmation');
 assert.equal(checks.filter(c => c.checked).length, 24);
 assert.match(JSON.stringify(modal.children.find(n => n.tag === 'div' && !n.attrs.class).children[0]), /Difference 24/);
 checks[24].checked = true;
 await button(modal, 'Confirm & Export')();
 assert.equal(requests.length, 1);

 downloads = []; failPublish = true;
 build = { release: 'stale', warnings: [], reused_warnings: [] };
 await assert.rejects(start(), /stale build/);
 assert.deepEqual(downloads, [], 'failed publication never exposes an export as successful');
 console.log('Overview export checks passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
