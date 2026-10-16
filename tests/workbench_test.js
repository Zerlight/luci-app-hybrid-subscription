'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const E = (tag, attrs, children) => ({ tag, attrs, children });
const realHs = new Function('baseclass', 'form', 'rpc', 'ui', 'poll', 'uqr', 'L', 'E', '_', 'document',
 fs.readFileSync(path.join(__dirname, '../htdocs/luci-static/resources/hybrid-subscription.js'), 'utf8'))(
 { extend: value => value }, {}, { declare: () => () => Promise.resolve({ ok: true }) }, {}, {}, {},
 { hasViewPermission: () => true, env: { lang: 'en' } }, E, value => value, {}
);
const hs = {
 table: (headers, rows) => ({ headers, rows }), button: label => ({ button: label }),
 time: value => value == null ? realHs.t('Unknown') : String(value),
 translateMessage: realHs.translateMessage
};
const page = new Function('view','dom','poll','ui','hs','E','_','L',
 fs.readFileSync(path.join(__dirname,'../htdocs/luci-static/resources/view/hybrid-subscription/overview.js'),'utf8'))(
 {extend: value=>value},{},{},{},hs,E,realHs.t,{url:value=>'/'+value}
);
const owner = {config:{profiles:[]}};
function renderQuota(quota) {
 return JSON.stringify(page.statusContent.call(owner,{sources:[{id:'source',quota,quota_status:{},nodes:1}],profiles:[]}));
}

// Verify default English output
realHs.setLocale('en');
assert.match(renderQuota({upload:1073741824,total:10737418240}), /Used Unknown \/ 10\.00 GiB/);
assert.match(renderQuota({download:1073741824,total:10737418240}), /Used Unknown \/ 10\.00 GiB/);
assert.match(renderQuota({upload:0,download:0,total:10737418240,expire:0}), /Used 0\.00 GiB \/ 10\.00 GiB/);
assert.match(renderQuota({upload:0,download:0,expire:0}), /Never expires/);
assert.match(renderQuota({upload:0,download:0}), /Not provided by upstream/);
assert.match(renderQuota(null), /No quota data/);
let workbench = JSON.stringify(page.statusContent.call({config:{profiles:[{id:'p',name:'Profile',formats:['mihomo']}]}},{profiles:[{id:'p',published_release:'r1',formats:['mihomo']}]}));
for (const action of ['Edit Profile','Build & Publish','Download / QR Code','Release Management']) assert.ok(workbench.includes(action));

// Saved conversion drift is advisory and opens review for the existing target.
function renderCompatibility(state) {
 return page.statusContent.call({config:{profiles:[{id:'compatible_copy',name:'Surge copy'}]}}, {
  profiles:[{id:'compatible_copy',published_release:'r1',formats:['surge'],compatibility:state}]
 });
}
function elements(value) {
 if (Array.isArray(value)) return value.flatMap(elements);
 if (!value || typeof value !== 'object') return [];
 return [value].concat(elements(value.children));
}
const tracked = {source_profile:'main',format:'surge',source_changed:false,target_changed:false,source_missing:false,needs_review:false};
for (const state of [undefined, tracked]) {
 const content = JSON.stringify(renderCompatibility(state));
 assert.doesNotMatch(content, /Review Conversion|alert-message warning/, 'unchanged or independent drafts need no drift notice');
}
for (const [flags, message] of [
 [{source_changed:true}, 'Source profile changed. Review before updating this draft.'],
 [{target_changed:true}, 'Compatible draft has local changes. Review before updating.'],
 [{source_changed:true,target_changed:true}, 'Source and compatible draft changed. Review before updating.'],
 [{source_missing:true,source_changed:true,target_changed:true}, 'Source profile is missing. Review this compatible draft.'],
 [{}, 'Saved conversion needs review.']
]) {
 const rendered = renderCompatibility({...tracked,...flags,needs_review:true}), content = JSON.stringify(rendered);
 const alerts = elements(rendered).filter(node => node.attrs && node.attrs.class === 'alert-message warning');
 assert.equal(alerts.length, 1, 'show one compact notice for a compatible copy');
 assert.equal(alerts[0].children[0], message);
 const review = elements(alerts[0]).find(node => node.tag === 'a');
 assert.equal(review.children, 'Review Conversion');
 assert.equal(review.attrs.href, '/admin/services/hybrid-subscription/compatibility?profile=compatible_copy&review=1', 'review selects the existing target, even if its source is missing');
 assert.match(content, /Download \/ QR Code/, 'the notice does not hide the published download');
 assert.match(content, /Build & Publish/, 'the notice does not silently replace existing publish actions');
}

// Verify Simplified Chinese (zh-cn / zh_Hans) output
realHs.setLocale('zh_Hans');
assert.match(renderQuota({upload:1073741824,total:10737418240}), /已用 未知 \/ 10\.00 GiB/);
assert.match(renderQuota({download:1073741824,total:10737418240}), /已用 未知 \/ 10\.00 GiB/);
assert.match(renderQuota({upload:0,download:0,total:10737418240,expire:0}), /已用 0\.00 GiB \/ 10\.00 GiB/);
assert.match(renderQuota({upload:0,download:0,expire:0}), /长期有效/);
assert.match(renderQuota({upload:0,download:0}), /上游未提供/);
assert.match(renderQuota(null), /暂无流量数据/);
workbench = JSON.stringify(page.statusContent.call({config:{profiles:[{id:'p',name:'Profile',formats:['mihomo']}]}},{profiles:[{id:'p',published_release:'r1',formats:['mihomo']}]}));
for (const action of ['编辑配置','构建并发布','下载 / 二维码','版本管理']) assert.ok(workbench.includes(action));

console.log('Workbench actions, conversion drift notices, review links and partial quota/expiry display pass.');
