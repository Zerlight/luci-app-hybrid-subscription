'use strict';
'require view';
'require form';
'require ui';
'require hybrid-subscription as hs';

return view.extend({
	load: function() { return hs.api('get_config'); },
	render: function(data) {
		const self = this;
		const m = hs.createMap(this, data, ['profiles', 'groups', 'rematches', 'sub_rules']);
		const query = new URLSearchParams(window.location.search), profileIDs = this.config.profiles.map(function(p) { return p.id; });
		const selected = this.editorState = { profile: profileIDs.indexOf(query.get('profile')) >= 0 ? query.get('profile') : (profileIDs[0] || '__all') };
		function inProfile(row) { return selected.profile === '__all' || row.profile === selected.profile; }
		function defaults() { return selected.profile === '__all' ? {} : { profile: selected.profile }; }
		let s = hs.grid(m, 'profiles', _('Subscription Profiles'));
		hs.sectionActions(s, function() { return [hs.button(_('Quick Create Profile'), function() { return self.createProfile(m); }, null, true)]; });
		hs.filterSection(s, function(row) { return selected.profile === '__all' || row.id === selected.profile; });
		let o = hs.references(hs.value(s, form.MultiValue, 'sources', _('Included Sources'), null, [], false), this.config, 'sources');
		o.rmempty = false;
		o = hs.choices(hs.value(s, form.MultiValue, 'formats', _('Export Formats'), null, ['mihomo', 'surge', 'singbox'], false), [['mihomo', 'Mihomo'], ['surge', 'Surge'], ['singbox', 'sing-box']]);
		o.rmempty = false;
		o = hs.references(hs.value(s, form.ListValue, 'final_policy', _('Default Fallback Policy'), _('Select a policy group or rematch entry belonging to this profile, or DIRECT / REJECT.'), 'DIRECT'), this.config, ['groups', 'rematches'], ['DIRECT', 'REJECT']);
		o.rmempty = false;
		hs.choices(hs.value(s, form.ListValue, 'mihomo_core', _('Mihomo Core Variant'), _('The Smart core variant is required when using Smart policy groups.'), 'standard'), [['standard', _('Standard Mihomo')], ['smart', _('Mihomo Smart')]]);
		hs.choices(hs.value(s, form.ListValue, 'surge_version', _('Surge Target'), null, 'modern'), [['modern', _('Surge (Modern)')]]);
		hs.choices(hs.value(s, form.ListValue, 'singbox_version', _('sing-box Target'), null, '1.12'), [['1.12', 'sing-box 1.12+']]);
		hs.jsonValue(s, 'mihomo_dns', _('Mihomo DNS Policy (JSON)'), _('Configure Mihomo DNS routing options. Listener addresses and controller secrets are managed by the router and not permitted here. Leave empty to use defaults.'));
		hs.jsonValue(s, 'mihomo_policy', _('Mihomo Advanced Policy (JSON)'), _('Configure domain sniffing, connection behavior, and GeoIP/GeoSite database options. Controller, listener, TUN, and network interface bindings are not permitted.'));
		hs.rowAction(s, '_graph', _('Dependency Graph'), function(row) {
			return m.parse().then(function() {
				const draft = Object.assign({}, self.config, { profiles: m.data.sections('json', 'profiles').map(hs.clean), groups: m.data.sections('json', 'groups').map(hs.clean), rematches: m.data.sections('json', 'rematches').map(hs.clean), sub_rules: m.data.sections('json', 'sub_rules').map(hs.clean) });
				ui.showModal(_('Dependency Graph: ') + (row.name || row.id), [
					E('p', {}, _('Directed edges illustrate references across sources, policy groups, rematch entries, and sub-rules. Circular dependencies will block validation and publication.')),
					hs.graph(draft, row.id), E('div', { 'class': 'right' }, hs.button(_('Close'), ui.hideModal))
				]);
			});
		});
		hs.rowAction(s, '_compatibility', _('Save & Check Compatibility'), function(row) {
			return self.handleSave().then(function() { window.location.href = L.url('admin/services/hybrid-subscription/compatibility') + '?profile=' + encodeURIComponent(row.id); });
		});
		hs.modalTabs(s, [{ id: 'general', title: _('General') }, { id: 'clients', title: _('Target Clients'), options: ['mihomo_core', 'surge_version', 'singbox_version'] }, { id: 'advanced', title: _('Advanced Policy'), options: ['mihomo_dns', 'mihomo_policy'] }]);

		s = hs.grid(m, 'groups', _('Policy Groups'));
		hs.filterSection(s, inProfile, defaults);
		o = hs.references(hs.value(s, form.ListValue, 'profile', _('Profile'), null, undefined), this.config, 'profiles'); o.rmempty = false;
		o = hs.references(hs.value(s, form.MultiValue, 'sources', _('Node Sources'), _('Leave empty to include only explicit group members without expanding source nodes.'), []), this.config, 'sources'); o.rmempty = false;
		o = hs.references(hs.value(s, form.ListValue, 'region', _('Region Template'), _('Combined with the include and exclude regular expressions below. Per-source region overrides can be configured in Global Settings.'), '', false), this.config, 'regions'); o.value('', _('No Region Template')); o.rmempty = false;
		const regionText = o.textvalue; o.textvalue = function(sid) { return regionText.call(this, sid) || _('None'); };
		o = hs.value(s, form.Value, 'filter', _('Include Nodes (Regex)'), _('Example: Japan|日本|JP to match only nodes in that region.'), ''); o.rmempty = false;
		o = hs.value(s, form.Value, 'exclude_filter', _('Exclude Nodes (Regex)'), null, ''); o.rmempty = false;
		o = hs.references(hs.value(s, form.DynamicList, 'members', _('Group Members / Built-in Policies'), _('Select policy groups or rematch entries within the same profile, or DIRECT / REJECT. Surge Smart groups accept nodes only.'), []), this.config, ['groups', 'rematches'], ['DIRECT', 'REJECT']); o.rmempty = false;
		hs.choices(hs.value(s, form.ListValue, 'mihomo_type', _('Mihomo Group Type'), null, 'select', false), [['select', _('Manual Select')], ['url-test', _('URL Test (Auto)')], ['fallback', _('Fallback')], ['load-balance', _('Load Balance')], ['smart', 'Smart']]);
		hs.choices(hs.value(s, form.ListValue, 'surge_type', _('Surge Group Type'), null, 'select'), [['select', _('Manual Select')], ['url-test', _('URL Test (Auto)')], ['fallback', _('Fallback')], ['smart', 'Smart']]);
		hs.choices(hs.value(s, form.ListValue, 'singbox_type', _('sing-box Group Type'), null, 'selector'), [['selector', _('Manual Select')], ['urltest', _('URL Test (Auto)')]]);
		o = hs.value(s, form.Value, 'url', _('Health Check URL'), null, 'https://www.gstatic.com/generate_204'); o.rmempty = false;
		o = hs.value(s, form.Value, 'interval', _('Test Interval (seconds)'), null, 300); o.datatype = 'range(30,86400)'; o.rmempty = false;
		o = hs.value(s, form.Value, 'tolerance', _('Latency Tolerance (ms)'), null, 50); o.datatype = 'range(0,10000)'; o.rmempty = false;
		o = hs.value(s, form.Flag, 'hidden', _('Hide Group in Supported Clients'), null, '0'); o.rmempty = false;
		o = hs.references(hs.value(s, form.ListValue, 'default_member', _('Mihomo Default Selection'), _('Must be a member of this group. Leave empty to use the client default.'), ''), this.config, ['groups', 'rematches'], ['DIRECT', 'REJECT']); o.rmempty = false;
		o = hs.references(hs.value(s, form.ListValue, 'empty_fallback', _('Mihomo Empty Group Fallback'), _('Fallback policy when no nodes match the filter. Leave empty to report an empty group during validation.'), ''), this.config, ['groups', 'rematches'], ['DIRECT', 'REJECT']); o.rmempty = false;
		o = hs.value(s, form.Flag, 'lazy', _('Lazy Health Check'), _('Mihomo tests node latency only when this policy group is actively used.'), '1'); o.rmempty = false;
		hs.modalTabs(s, [{ id: 'general', title: _('Nodes & Members') }, { id: 'clients', title: _('Client Behavior'), options: ['mihomo_type', 'surge_type', 'singbox_type', 'hidden', 'default_member', 'empty_fallback'] }, { id: 'checks', title: _('Health Check'), options: ['url', 'interval', 'tolerance', 'lazy'] }]);

		s = hs.grid(m, 'rematches', _('Mihomo Rematch Entries'), _('Forwards traffic into a designated sub-rule for secondary matching.'));
		hs.filterSection(s, inProfile, defaults);
		o = hs.references(hs.value(s, form.ListValue, 'profile', _('Profile'), null, undefined), this.config, 'profiles'); o.rmempty = false;
		o = hs.references(hs.value(s, form.ListValue, 'target_sub_rule', _('Target Sub-Rule'), null, '', false), this.config, 'sub_rules'); o.rmempty = false;
		o = hs.value(s, form.Value, 'rematch_name', _('Rematch Tag'), _('Optional tag matched by REMATCH-NAME rules inside the target sub-rule.'), '', false); o.rmempty = false;

		s = hs.grid(m, 'sub_rules', _('Mihomo Sub-Rules'), _('Rules inside each sub-rule are managed on the Routing Rules page and evaluated in order.'));
		hs.filterSection(s, inProfile, defaults);
		o = hs.references(hs.value(s, form.ListValue, 'profile', _('Profile'), null, undefined), this.config, 'profiles'); o.rmempty = false;
		o = hs.references(hs.value(s, form.ListValue, 'final_policy', _('Fallback Policy'), null, 'REJECT', false), this.config, ['groups', 'rematches'], ['DIRECT', 'REJECT']); o.rmempty = false;
		hs.rowAction(s, '_rules', _('Save & Edit Rules'), function(row) {
			return self.handleSave().then(function() { window.location.href = L.url('admin', 'services', 'hybrid-subscription', 'rules') + '?profile=' + encodeURIComponent(row.profile) + '&sub_rule=' + encodeURIComponent(row.id); });
		});
		hs.sectionTabs(m, [
			{ id: 'profiles', title: _('Subscription Profiles'), sections: ['profiles'] },
			{ id: 'groups', title: _('Policy Groups'), sections: ['groups'] },
			{ id: 'advanced', title: _('Advanced Routing'), sections: ['rematches', 'sub_rules'] }
		], query.get('tab'), function() {
			const choices = { '__all': _('All Profiles') };
			m.data.sections('json', 'profiles').forEach(function(row) { if (row.id) choices[row.id] = row.name || row.id; });
			if (!choices[selected.profile]) selected.profile = '__all';
			return hs.selectFilter(m, _('Active Profile'), selected, 'profile', choices);
		});
		return m.render();
	},
	createProfile: function(m) {
		const self = this, sources = (this.config.sources || []).filter(function(s) { return s.enabled !== false; }).map(function(s) { return s.id; });
		let count = 1;
		const ids = m.data.sections('json', 'profiles').map(function(p) { return p.id; });
		while (ids.indexOf('hybrid' + count) >= 0) count++;
		const dialog = new form.JSONMap({ profile: { id: 'hybrid' + count, name: 'Hybrid ' + count, sources: sources } });
		const section = dialog.section(form.NamedSection, 'profile', 'profile');
		let o = section.option(form.Value, 'id', _('Identifier'));
		o.rmempty = false; o.validate = function(sid, value) { return /^[a-z][a-z0-9_-]{0,39}$/.test(value) || _('Use 1–40 lowercase letters, digits, underscores, or hyphens, starting with a letter.'); };
		o = section.option(form.Value, 'name', _('Name')); o.rmempty = false;
		o = section.option(form.MultiValue, 'sources', _('Included Sources')); hs.references(o, this.config, 'sources'); o.rmempty = false; o.optional = true;
		o.remove = function(sid) { return this.write(sid, []); };
		return dialog.render().then(function(node) {
			ui.showModal(_('Quick Create Profile'), [node, E('p', {}, _('Creates a starter profile with a manual node selection group for Mihomo, Surge, and sing-box. You can add region groups and routing rules afterward.')), E('div', { 'class': 'right' }, [
				hs.button(_('Cancel'), ui.hideModal), ' ', hs.button(_('Add to Draft'), function() {
					return dialog.parse().then(function() {
						const p = hs.clean(dialog.data.get('json', 'profile'));
						if (m.data.sections('json', 'profiles').some(function(row) { return row.id === p.id; })) throw new Error(_('Profile identifier already exists.'));
						return m.parse().then(function() {
							const profile = Object.assign(p, { formats: ['mihomo', 'surge', 'singbox'], final_policy: p.id + '_proxy', mihomo_core: 'standard', surge_version: 'modern', singbox_version: '1.12' });
							const group = { id: p.id + '_proxy', profile: p.id, name: _('Proxy'), sources: p.sources, members: [], region: '', filter: '', exclude_filter: '', mihomo_type: 'select', surge_type: 'select', singbox_type: 'selector', url: 'https://www.gstatic.com/generate_204', interval: 300, tolerance: 50, hidden: false };
							[['profiles', profile], ['groups', group]].forEach(function(entry) {
								const sid = m.data.add('json', entry[0]);
								Object.keys(entry[1]).forEach(function(key) { m.data.set('json', sid, key, entry[1][key]); });
							});
							self.editorState.profile = p.id;
							ui.hideModal();
							return m.load().then(function() { return m.renderContents(); });
						});
					});
				}, 'cbi-button-positive', true)
			])]);
		});
	}
});
