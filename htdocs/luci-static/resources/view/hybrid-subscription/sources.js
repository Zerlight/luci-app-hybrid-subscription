'use strict';
'require view';
'require form';
'require ui';
'require hybrid-subscription as hs';

return view.extend({
	load: function() { return Promise.all([hs.api('get_config'), hs.api('status')]); },
	render: function(data) {
		const self = this, status = {};
		(data[1].sources || []).forEach(function(s) { status[s.id] = s; });
		const flag = function(value) { return value === true || value === '1' || value === 1 || value === 'true'; };
		const hasUrl = function(value) { return typeof value === 'string' && value.trim() !== ''; };
		const canUpdate = function(row) { return hasUrl(row.url) || flag(row.has_url); };
		const canRefreshQuota = function(row) {
			const state = (status[row.id] || {}).quota_status || {};
			return (!flag(row.clear_quota_url) && (hasUrl(row.quota_url) || flag(row.has_quota_url))) ||
				(flag(row.quota_via_subscription) && canUpdate(row)) ||
				(state.can_refresh === true && state.query_mode === 'cache_only');
		};
		const m = hs.createMap(this, data[0], ['sources']);
		const s = hs.grid(m, 'sources', _('Subscription Sources'));
		s.addModalOptions = function(section, sid) {
			const row = m.data.get('json', sid);
			const saved = self.config.sources.find(function(source) { return source.id === row.id; });
			if (m.readonly || !saved || (!flag(saved.has_url) && !flag(saved.has_quota_url))) return;
			return hs.api('source_urls', { source: saved.id }).then(function(result) {
				['url', 'quota_url'].forEach(function(key) {
					if (!hasUrl(row[key]) && !(key === 'quota_url' && flag(row.clear_quota_url)))
						m.data.set('json', sid, key, result[key] || '');
				});
			});
		};
		let o = hs.value(s, form.Flag, 'enabled', _('Enabled'), null, '1');
		o.rmempty = false;
		o = hs.value(s, form.DummyValue, '_state', _('Cache Status'), null, null, false);
		o.cfgvalue = function(sid) {
			const item = status[m.data.get('json', sid, 'id')];
			if (!item) return _('Not cached');
			const summary = hs.sourceUpdateSummary(item.last_refresh);
			return (item.enabled === false ? _('Disabled · ') : '') + (item.nodes == null ? '0' : item.nodes) + _(' nodes · ') + hs.time(item.cached_at) +
				(summary ? ' · ' + summary : '') + (item.error ? ' · ' + hs.translateMessage(item.error) : '');
		};
		o = hs.value(s, form.Value, 'url', _('Subscription URL'), _('Saved URLs are loaded when you edit this source. Use the visibility button to view the address. Leave blank to keep the saved URL; new sources may use a local file instead.'), '');
		o.password = true; o.rmempty = false;
		o = hs.value(s, form.Value, 'quota_url', _('Dedicated Quota Query URL'), _('Specify a dedicated endpoint that returns the Subscription-Userinfo header. Quota refreshes never fall back to the subscription URL. Leave blank to keep the saved URL.'), ''); o.password = true; o.rmempty = false;
		o = hs.value(s, form.DummyValue, 'has_quota_url', _('Quota URL Saved'));
		o.cfgvalue = function(sid) { return ['true', '1'].indexOf(String(m.data.get('json', sid, 'has_quota_url'))) >= 0 ? _('Yes') : _('No'); };
		o = hs.value(s, form.Flag, 'clear_quota_url', _('Clear Saved Quota URL'), _('Check and save to remove the dedicated quota query endpoint.'), '0'); o.rmempty = false;
		o = hs.value(s, form.Flag, 'quota_via_subscription', _('Query Quota via Subscription URL'), _('When no dedicated quota URL is set, sends a GET request to the subscription URL to read response headers. Keep disabled for time-windowed or rate-limited subscriptions, as this may consume pull quota. Only triggered manually.'), '0'); o.rmempty = false;
		o = hs.value(s, form.Value, 'quota_max_age', _('Quota Cache TTL (seconds)'), _('Data older than this threshold is marked as stale without triggering automatic requests.'), 86400); o.datatype = 'range(60,31536000)'; o.rmempty = false;
		o = hs.value(s, form.DummyValue, '_quota', _('Quota / Expiration'), null, null, false);
		o.cfgvalue = function(sid) {
			const item = status[m.data.get('json', sid, 'id')] || {}, q = item.quota || {}, state = item.quota_status || {};
			if (!Object.keys(q).length) return _('No data');
			return (state.stale ? _('Stale · ') : '') + (q.upload == null || q.download == null ? '?' : ((Number(q.upload || 0) + Number(q.download || 0)) / 1073741824).toFixed(2)) + ' / ' + (q.total == null ? '?' : (Number(q.total) / 1073741824).toFixed(2)) + ' GiB · ' + _('Expires: ') + (q.expire == null ? _('Unknown') : q.expire === 0 ? _('Never expires') : hs.time(q.expire));
		};
		hs.rowAction(s, '_refresh_quota', _('Refresh Quota'), function(row) {
			return self.handleSave().then(function() { return hs.runJob('refresh_quota', { source: row.id }, _('Refresh Quota Status')); }).then(function() { window.location.reload(); });
		}, canRefreshQuota);
		hs.choices(hs.value(s, form.ListValue, 'format', _('Input Format'), null, 'auto'), [['auto', _('Auto Detect')], ['mihomo', 'Mihomo / Clash YAML'], ['surge', 'Surge'], ['singbox', 'sing-box'], ['shadowrocket', 'Shadowrocket']]);
		hs.choices(hs.value(s, form.ListValue, 'update_mode', _('Update Mode'), null, 'manual', false), [['manual', _('Manual Only')], ['scheduled', _('Scheduled')]]);
		o = hs.value(s, form.Value, 'interval', _('Update Interval (seconds)'), _('Applies only to scheduled sources. Do not enable scheduled updates for time-windowed subscriptions.'), 86400);
		o.datatype = 'range(300,31536000)'; o.depends('update_mode', 'scheduled'); o.rmempty = false;
		o = hs.value(s, form.Value, 'exclude_filter', _('Exclude Node Names (Regex)'), _('Filter out informational entries such as traffic or expiration notices.'), ''); o.rmempty = false;
		o = hs.value(s, form.Value, 'user_agent', _('Download User-Agent'), _('Leave blank to use the default User-Agent.'), ''); o.rmempty = false;
		o = hs.value(s, form.DummyValue, 'openclash_section', _('Linked OpenClash Source'));
		o = hs.value(s, form.Flag, 'takeover', _('Take Over OpenClash Subscription Updates'), _('Applies only to sources imported from OpenClash. Disables OpenClash auto-updates for this source when applying a profile to prevent duplicate pulls.'), '0'); o.rmempty = false;
		hs.rowAction(s, '_refresh', _('Update Subscription'), function(row) {
			return self.handleSave().then(function() { return hs.runJob('refresh', { source: row.id }, _('Update Subscription')); }).then(function(job) { hs.sourceUpdateResult(row, job.result || {}); });
		}, canUpdate);
		o = hs.rowAction(s, '_import', _('Import File'), function(row) {
			return self.handleSave().then(function() { hs.importSource(row); });
		});
		o.modalonly = true;
		o = hs.rowAction(s, '_compare', _('Subconverter Compatibility Audit'), function(row) {
			return self.handleSave().then(function() {
				return hs.runJob('compare_converter', { source: row.id }, _('Subconverter Compatibility Audit'));
			}).then(function(job) {
				const result = job.result || {};
				const diffKinds = { missing: _('Missing'), added: _('Added'), changed: _('Modified') };
				ui.showModal(_('Compatibility Audit: ') + (row.name || row.id), [
					E('p', {}, _('Compares cached nodes against local subconverter output without fetching upstream sources or modifying the cache.')),
					E('p', {}, _('Original nodes: %s; Converted nodes: %s.').format(result.node_count_before == null ? '—' : result.node_count_before, result.node_count_after == null ? '—' : result.node_count_after)),
					E('p', {}, result.equal === true ? _('Native parser and subconverter outputs are identical.') : _('Differences detected. Subscription generation continues to use the native parser output.')),
					hs.table([_('Node'), _('Difference Type'), _('Affected Fields')], (result.differences || []).map(function(diff) { return [diff.node, diffKinds[diff.kind] || diff.kind, (diff.fields || []).join(', ')]; }), _('No differences')),
					E('div', { 'class': 'right' }, hs.button(_('Close'), ui.hideModal))
				]);
			});
		});
		o.modalonly = true;
		// Native GridSection tabs keep the less common import and converter controls out of the main flow.
		s.tab('subscription', _('Subscription & Updates')); s.tab('quota', _('Quota / Expiration')); s.tab('advanced', _('Advanced'));
		s.children.forEach(function(option) {
			const key = option.option;
			const tab = ['quota_url', 'has_quota_url', 'clear_quota_url', 'quota_via_subscription', 'quota_max_age', '_quota', '_refresh_quota'].indexOf(key) >= 0 ? 'quota' : ['exclude_filter', 'user_agent', 'openclash_section', 'takeover', '_compare', '_import'].indexOf(key) >= 0 ? 'advanced' : 'subscription';
			option.tab = tab; s.tabs[tab].children.push(option);
		});
		hs.sectionActions(s, function() {
			return [hs.button(_('Import from OpenClash'), function() {
				return self.handleSave().then(function() {
					return hs.api('import_openclash');
				}).then(function() {
					ui.addNotification(null, E('p', {}, _('OpenClash subscription sources and node caches have been imported.')), 'info');
					window.location.reload();
				});
			}, null, true)];
		});
		return m.render();
	}
});
