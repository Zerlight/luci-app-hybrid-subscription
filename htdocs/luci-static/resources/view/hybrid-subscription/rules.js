'use strict';
'require view';
'require form';
'require hybrid-subscription as hs';

return view.extend({
	load: function() { return hs.api('get_config'); },
	render: function(data) {
		const self = this, m = hs.createMap(this, data, ['rules', 'rule_sets']);
		const query = new URLSearchParams(window.location.search), profileIDs = this.config.profiles.map(function(p) { return p.id; });
		const selected = { profile: profileIDs.indexOf(query.get('profile')) >= 0 ? query.get('profile') : (profileIDs[0] || '__all'), sub_rule: query.get('sub_rule') || '' };
		if (!(this.config.sub_rules || []).some(function(row) { return row.id === selected.sub_rule && (selected.profile === '__all' || row.profile === selected.profile); })) selected.sub_rule = '';
		let s = hs.grid(m, 'rules', _('Ordered Routing Rules'), null, false);
		s.sortable = true;
		hs.filterSection(s, function(row) {
			return (selected.profile === '__all' || row.profile === selected.profile) && (selected.sub_rule === '__all' || (row.sub_rule || '') === selected.sub_rule);
		}, function() { return Object.assign({ sub_rule: selected.sub_rule === '__all' ? '' : selected.sub_rule }, selected.profile === '__all' ? {} : { profile: selected.profile }); });
		let o = hs.references(hs.value(s, form.ListValue, 'profile', _('Profile'), null, undefined), this.config, 'profiles'); o.rmempty = false;
		o = hs.value(s, form.ListValue, 'sub_rule', _('Rule Scope'), _('Select Main Rules or a sub-rule belonging to the same profile.'), '', false); o.value('', _('Main Rules')); hs.references(o, this.config, 'sub_rules'); o.rmempty = false;
		const subRuleText = o.textvalue; o.textvalue = function(sid) { return subRuleText.call(this, sid) || _('Main Rules'); };
		o = hs.value(s, form.Flag, 'enabled', _('Enabled'), null, '1', false); o.rmempty = false;
		hs.choices(hs.value(s, form.ListValue, 'type', _('Rule Type'), null, 'DOMAIN-SUFFIX', false), ['DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'IP-CIDR', 'IP-CIDR6', 'GEOIP', 'GEOSITE', 'RULE-SET', 'DST-PORT', 'NETWORK', 'REMATCH-NAME', 'AND', 'OR', 'NOT']);
		o = hs.value(s, form.Value, 'value', _('Match Value'), _('Use TCP or UDP for NETWORK; REMATCH-NAME is valid only within sub-rules. Edit AND/OR/NOT conditions under the "Advanced Conditions" tab.'), '', false); o.rmempty = false;
		o.textvalue = function(sid) {
			const row = this.map.data.get('json', sid);
			if (['AND', 'OR', 'NOT'].indexOf(row.type) >= 0) return _('Logical expression · ') + (row.conditions || []).length + _(' conditions');
			if (row.type === 'RULE-SET') { const set = this.map.data.sections('json', 'rule_sets').find(function(item) { return item.id === row.value; }); return set ? set.name || set.id : row.value; }
			return row.value;
		};
		o = hs.references(hs.value(s, form.ListValue, 'policy', _('Outbound Policy'), null, 'DIRECT', false), this.config, ['groups', 'rematches'], ['DIRECT', 'REJECT']); o.rmempty = false;
		o = hs.value(s, form.Flag, 'no_resolve', _('Skip DNS Resolution (no-resolve)'), _('Applies to IP and rule-set rules that support no-resolve. Unsupported target formats will report a warning during validation.'), '0'); o.rmempty = false;
		o = hs.jsonValue(s, 'conditions', _('Logical Conditions (JSON Array)'), _('Example: [ {"type":"NETWORK","value":"UDP"}, {"type":"RULE-SET","value":"ruleset_id"} ]. Nested conditions use type and conditions; AND/OR require at least 2 conditions, and NOT requires exactly 1.'), true);
		o.depends('type', 'AND'); o.depends('type', 'OR'); o.depends('type', 'NOT');
		hs.modalTabs(s, [{ id: 'general', title: _('Matching & Policy') }, { id: 'advanced', title: _('Advanced Conditions'), options: ['no_resolve', 'conditions'] }]);

		s = hs.grid(m, 'rule_sets', _('Shared Rule Sets'), _('Available across all subscription profiles regardless of the active filter above.'));
		hs.choices(hs.value(s, form.ListValue, 'source_type', _('Source Type'), null, 'remote', false), [['remote', _('Remote URL')], ['inline', _('Inline Rules')]]);
		hs.choices(hs.value(s, form.ListValue, 'behavior', _('Rule Behavior'), null, 'domain', false), [['domain', _('Domain')], ['ipcidr', _('IP CIDR')], ['classical', _('Classical')]]);
		o = hs.value(s, form.TextValue, 'inline_rules', _('Inline Rule Entries'), _('One rule per line without an outbound policy, e.g., DOMAIN-SUFFIX,example.com.'), ''); o.rows = 14; o.monospace = true; o.rmempty = false; o.depends('source_type', 'inline');
		o = hs.value(s, form.Value, 'mihomo_url', _('Mihomo URL'), null, ''); o.rmempty = false; o.depends('source_type', 'remote');
		hs.choices(hs.value(s, form.ListValue, 'mihomo_format', _('Mihomo Format'), null, 'text'), ['text', 'yaml', 'mrs']).depends('source_type', 'remote');
		o = hs.references(hs.value(s, form.ListValue, 'mihomo_proxy', _('Mihomo Download Detour Policy'), _('Leave empty to use the client default outbound for fetching rule sets.'), ''), this.config, ['groups', 'rematches'], ['DIRECT', 'REJECT']); o.rmempty = false; o.depends('source_type', 'remote');
		o = hs.value(s, form.Value, 'surge_url', _('Surge URL'), _('URL of a Surge-compatible RULE-SET file.'), ''); o.rmempty = false; o.depends('source_type', 'remote');
		o = hs.value(s, form.Value, 'shadowrocket_url', _('Shadowrocket URL (Classical YAML)'), _('URL of a Clash classical YAML rule set with a payload list. Configure this separately; Surge text lists cannot be used here.'), ''); o.rmempty = false; o.depends('source_type', 'remote');
		o = hs.value(s, form.Value, 'singbox_url', _('sing-box URL'), null, ''); o.rmempty = false; o.depends('source_type', 'remote');
		hs.choices(hs.value(s, form.ListValue, 'singbox_format', _('sing-box Format'), null, 'source'), [['source', 'JSON source'], ['binary', 'SRS binary']]).depends('source_type', 'remote');
		o = hs.value(s, form.Value, 'interval', _('Update Interval (seconds)'), null, 86400); o.datatype = 'range(300,31536000)'; o.rmempty = false;
		hs.modalTabs(s, [{ id: 'general', title: _('General') }, { id: 'content', title: _('Content & URLs'), options: ['inline_rules', 'mihomo_url', 'mihomo_format', 'surge_url', 'shadowrocket_url', 'singbox_url', 'singbox_format'] }, { id: 'advanced', title: _('Update Options'), options: ['mihomo_proxy', 'interval'] }]);
		hs.sectionTabs(m, [{ id: 'rules', title: _('Routing Rules'), sections: ['rules'] }, { id: 'rule_sets', title: _('Rule Sets'), sections: ['rule_sets'] }], query.get('tab'), function() {
			const profiles = { '__all': _('All Profiles') }, scopes = { '': _('Main Rules'), '__all': _('All Main & Sub-Rules') };
			(self.config.profiles || []).forEach(function(row) { profiles[row.id] = row.name || row.id; });
			(self.config.sub_rules || []).filter(function(row) { return selected.profile === '__all' || row.profile === selected.profile; }).forEach(function(row) { scopes[row.id] = row.name || row.id; });
			return E('div', {}, [
				hs.selectFilter(m, _('Active Profile'), selected, 'profile', profiles, function() { selected.sub_rule = ''; }),
				hs.selectFilter(m, _('Rule Scope'), selected, 'sub_rule', scopes)
			]);
		});
		return m.render();
	}
});
