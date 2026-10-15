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

console.log('Workbench actions and partial quota/expiry display pass in both English and Simplified Chinese.');
