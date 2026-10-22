'use strict';
'require view';
'require form';
'require ui';
'require hybrid-subscription as hs';

return view.extend({
	load: function() { return hs.api('get_config'); },
	render: function(data) {
		const self = this;
		const m = hs.createMap(this, data, ['settings', 'regions']);
		let s = hs.grid(m, 'regions', _('Region Matching Templates'), _('Classify nodes into regions by matching node names against flag emojis, region names, or ISO country codes. Per-source rules override the general pattern.'));
		hs.sectionActions(s, function() { return [
			hs.button(_('Add Common Regions'), function() { return self.addRegions(m); }, null, true),
			hs.button(_('Preview Region Matches'), function() { return self.previewRegions(m); })
		]; });
		let o = hs.value(s, form.Value, 'pattern', _('General Pattern (Regex)'), _('Example: 🇯🇵|日本|Japan. Use word-boundary assertions for short country codes to avoid false positives. Patterns must not match empty strings.'), ''); o.rmempty = false; o.optional = false;
		o = hs.value(s, form.DummyValue, '_overrides', _('Source Overrides'), null, null, false);
		o.cfgvalue = function(sid) {
			const overrides = m.data.get('json', sid, 'source_patterns') || {};
			return (self.config.sources || []).filter(function(source) { return !!overrides[source.id]; }).map(function(source) { return source.name || source.id; }).join(', ') || _('Use general pattern for all sources');
		};
		(this.config.sources || []).forEach(function(source) {
			const key = '_source_' + source.id;
			const field = hs.value(s, form.Value, key, (source.name || source.id) + _(' Override Pattern'), _('Leave empty to use the general pattern above. When specified, only this source uses this regular expression.'), '');
			field.rmempty = false; field.optional = true;
			field.load = function(sid) { return (this.map.data.get('json', sid, 'source_patterns') || {})[source.id] || ''; };
			field.write = function(sid, value) {
				const overrides = Object.assign({}, this.map.data.get('json', sid, 'source_patterns') || {});
				if (value.trim()) overrides[source.id] = value; else delete overrides[source.id];
				return this.map.data.set('json', sid, 'source_patterns', overrides);
			};
			field.remove = function(sid) { return this.write(sid, ''); };
		});
		hs.rowAction(s, '_test', _('View Matched Nodes'), function(row) { return self.previewRegions(m, row.id); });

		s = m.section(form.NamedSection, 'settings', 'settings', _('Download & Integration'), _('Manage published releases, download links, and rollbacks on the Overview page.'));
		s.tab('access', _('Download Access')); s.tab('integration', _('OpenClash & Subconverter'));
		o = s.taboption('access', form.ListValue, 'access_mode', _('Download Access Mode'));
		hs.choices(o, [['lan_token', _('LAN + Download Token')], ['token', _('Download Token (All Reachable Networks)')], ['session', _('Authenticated LuCI Session Only')]]);
		o.default = 'lan_token'; o.rmempty = false;
		o.description = _('Changing the access mode does not open firewall ports. Session-only mode does not provide QR codes for third-party clients. Rotate tokens under "Release Management" on the Overview page.');
		o = s.taboption('access', form.Value, 'base_url', _('Subscription Base URL'), _('Use a stable HTTP(S) address reachable by your clients. Surge client updates require this field. Leave empty to use the current router origin for ordinary download links.')); o.rmempty = false; o.optional = true;
		o.remove = function(sid) { return this.write(sid, ''); };
		o = s.taboption('integration', form.Flag, 'openclash_auto_apply', _('Auto-Apply to OpenClash on Publish'), _('Applies only to the profile selected below (disabled by default). When enabled, publishing or rolling back will reload OpenClash.')); o.default = '0'; o.rmempty = false;
		o = s.taboption('integration', form.ListValue, 'openclash_profile', _('Linked OpenClash Profile')); o.value('', _('None')); hs.references(o, this.config, 'profiles'); o.rmempty = false; o.optional = true;
		o.remove = function(sid) { return this.write(sid, ''); };
		o = s.taboption('integration', form.Value, 'converter_url', _('Local Subconverter URL'), _('Loopback addresses only. Run compatibility audits from the Advanced tab of a subscription source.')); o.default = 'http://127.0.0.1:25500'; o.rmempty = false;
		hs.sectionTabs(m, [
			{ id: 'regions', title: _('Region Matching'), sections: ['regions'] },
			{ id: 'general', title: _('Download & Integration'), sections: ['settings'] }
		], 'regions');
		return m.render();
	},
	addRegions: function(m) {
		const translate = typeof _ === 'function' ? _ : (hs && hs.t ? hs.t : function(v) { return v; });
		return m.parse().then(function() { return hs.api('region_defaults'); }).then(function(result) {
			const existing = m.data.sections('json', 'regions').map(function(r) { return r.id; });
			(result.regions || []).filter(function(r) { return existing.indexOf(r.id) < 0; }).forEach(function(region) {
				const sid = m.data.add('json', 'regions');
				Object.keys(region).forEach(function(key) {
					m.data.set('json', sid, key, key === 'name' ? translate(region[key]) : region[key]);
				});
			});
			return m.load().then(function() { return m.renderContents(); });
		});
	},
	currentDraft: function(m) {
		return Object.assign({}, this.config, { settings: hs.clean(m.data.get('json', 'settings')), regions: m.data.sections('json', 'regions').map(hs.clean) });
	},
	previewRegions: function(m, selectedRegion) {
		const self = this;
		return m.parse().then(function() { return hs.api('preview_regions', { config: JSON.stringify(self.currentDraft(m)), sources: [] }); }).then(function(result) {
			const regionNames = {}; (result.regions || []).forEach(function(r) { regionNames[r.id] = r.name; });
			ui.showModal(selectedRegion ? _('Match Preview: ') + (regionNames[selectedRegion] || selectedRegion) : _('Region Match Preview'), [E('p', {}, _('Previewed against currently cached node names. If a node matches multiple regions, refine the regular expressions. Name matching does not guarantee the actual egress IP location.')),
				E('div', {}, (result.sources || []).map(function(source) {
					const nodes = (source.nodes || []).filter(function(n) { return !selectedRegion || (n.regions || []).indexOf(selectedRegion) >= 0; });
					return E('details', { open: (result.sources || []).length === 1 ? true : null }, [E('summary', {}, (source.name || source.id) + (selectedRegion ? ' · ' + nodes.length + _(' matched nodes') : ' · ' + source.total + _(' nodes, ') + source.unmatched + _(' unmatched, ') + source.ambiguous + _(' ambiguous'))),
						hs.table([_('Original Node Name'), _('Matched Regions')], nodes.map(function(n) { return [n.name, (n.regions || []).map(function(id) { return regionNames[id] || id; }).join(', ') || _('Unmatched')]; }))]);
				})), E('div', { 'class': 'right' }, hs.button(_('Close'), ui.hideModal))]);
		});
	}
});
