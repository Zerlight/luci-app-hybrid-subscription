'use strict';
'require view';
'require form';
'require ui';
'require dom';
'require hybrid-subscription as hs';

const clients = { mihomo: 'Mihomo', surge: 'Surge', singbox: 'sing-box' };
function modeLabel(mode) {
	const labels = { manual: _('Manual Select'), select: _('Manual Select'), selector: _('Manual Select'),
		'url-test': _('URL Test (Auto)'), urltest: _('URL Test (Auto)'), fallback: _('Fallback'), 'load-balance': _('Load Balance'), smart: 'Smart' };
	return labels[mode] || mode;
}
function messages(items) {
	return E('ul', {}, (items || []).map(function(item) { return E('li', {}, hs.translateMessage(typeof item === 'string' ? item : item.message)); }));
}
function editorLink(page, label, profile) {
	return E('a', { 'class': 'cbi-button cbi-button-action', href: L.url('admin/services/hybrid-subscription/' + page) + '?profile=' + encodeURIComponent(profile) }, label);
}

return view.extend({
	load: function() { return hs.api('get_config'); },
	render: function(data) {
		const self = this, profiles = data.config.profiles || [];
		this.config = data.config;
		if (!profiles.length) return E('div', { 'class': 'cbi-map' }, [E('h2', {}, _('Compatibility')), E('p', {}, _('Create a subscription profile before checking compatibility.'))]);
		const requested = new URLSearchParams(window.location.search).get('profile');
		const m = new form.JSONMap({ selection: { profile: profiles.some(function(p) { return p.id === requested; }) ? requested : profiles[0].id } });
		const s = m.section(form.NamedSection, 'selection', 'selection');
		const o = s.option(form.ListValue, 'profile', _('Profile'));
		profiles.forEach(function(p) { o.value(p.id, p.name || p.id); });
		o.rmempty = false;
		const output = E('div', { 'aria-live': 'polite' });
		function check() {
			return m.parse().then(function() {
				const id = m.data.get('json', 'selection', 'profile');
				return hs.api('compatibility', { profile: id }).then(function(report) {
					dom.content(output, self.reportContent(report));
				});
			});
		}
		return m.render().then(function(node) {
			const page = E('div', { 'class': 'cbi-map' }, [
				E('h2', {}, _('Compatibility')),
				E('p', { 'class': 'cbi-map-descr' }, _('Checks all three clients using the saved draft and local node caches. Import Mihomo, Surge, or sing-box subscriptions under Subscription Sources, then choose output formats in Subscription Profiles.')),
				node, E('p', {}, hs.button(_('Check Compatibility'), check)), output
			]);
			// JSONMap controls must be mounted before parsing their current values.
			const id = m.data.get('json', 'selection', 'profile');
			return hs.api('compatibility', { profile: id }).then(function(report) { dom.content(output, self.reportContent(report)); return page; });
		});
	},
	reportContent: function(report) {
		const self = this, profile = report.profile;
		return E('div', {}, [
			E('h3', {}, profile.name || profile.id),
			E('p', {}, [editorLink('profiles', _('Edit Profile'), profile.id), ' ', editorLink('rules', _('Edit Routing Rules'), profile.id)]),
			hs.table([_('Target Client'), _('Status'), _('Actions')], report.targets.map(function(target) {
				const issues = target.issues || [], blocked = target.errors.length || issues.some(function(issue) { return issue.severity === 'error'; });
				const differences = target.warnings.length || issues.some(function(issue) { return issue.severity === 'warning'; });
				return [clients[target.format], blocked ? _('Blocked') : differences ? _('Review Differences') : _('Compatible'),
					hs.button(_('Compatibility Wizard'), function() { return self.wizard(report, target.format); }, null, true)];
			})),
			E('p', { 'class': 'cbi-section-descr' }, _('Compatibility describes this exporter and its selected target versions. Unsupported policies block output; differences still require confirmation when publishing.')),
			E('div', {}, report.targets.map(function(target) {
				return E('div', { 'class': 'cbi-section' }, [
					E('h4', {}, clients[target.format]),
					target.errors.length ? messages(target.errors) : E('p', {}, _('Validation passed with no blocking errors.')),
					messages(target.warnings),
					hs.table([_('Affected Item'), _('Suggested Action')], (target.issues || []).map(function(issue) {
						return [issue.name || issue.id || issue.kind, hs.translateMessage(issue.message)];
					}), _('No additional compatibility issues.'))
				]);
			}))
		]);
	},
	wizard: function(report, format) {
		const self = this, choices = report.choices, source = report.profile;
		const base = source.id.slice(0, 34) + '_' + format;
		let id = base, n = 2;
		while (this.config.profiles.some(function(p) { return p.id === id; })) id = base + '_' + n++;
		const m = new form.JSONMap({ copy: { id: id, name: (source.name || source.id) + ' · ' + clients[format], disable_rules: [] } });
		const s = m.section(form.NamedSection, 'copy', 'copy');
		s.tab('general', _('Independent Profile'));
		s.tab('automation', _('Automation Level'));
		s.tab('routing', _('Routing Decisions'));
		s.tab('settings', _('Client Settings'));
		let o = s.taboption('general', form.Value, 'id', _('Identifier'));
		o.rmempty = false;
		o.validate = function(sid, value) { return /^[a-z][a-z0-9_-]{0,47}$/.test(value) || _('Start with a lowercase letter and use only lowercase letters, digits, underscores, or hyphens (up to 48 characters).'); };
		o = s.taboption('general', form.Value, 'name', _('Name')); o.rmempty = false;
		(choices.groups || []).forEach(function(group, index) {
			const option = s.taboption('automation', form.ListValue, 'group_mode_' + index, _('Automation for %s').format(group.name || group.id),
				_('Mihomo: %s; target: %s. Manual selection stops automatic switching; URL Test selects by latency; Fallback selects by availability and order. Rule conditions stay unchanged.').format(modeLabel(group.modes.mihomo), modeLabel(group.modes[format])));
			option.value('', _('Keep current target behavior'));
			(group.alternatives[format] || []).forEach(function(mode) { option.value(mode, modeLabel(mode)); });
			option.optional = true; option.rmempty = false;
		});
		if (format !== 'mihomo') {
			choices.rematches.forEach(function(rematch, index) {
				const option = s.taboption('routing', form.ListValue, 'rematch_' + index, _('Replacement for %s').format(rematch.name || rematch.id), _('Choose an existing policy or create a manual or latency-based selection group. Replacing rematch stops conditional re-evaluation.'));
				option.value('', _('Keep unresolved'));
				option.value('__manual', _('Create a manual selection group'));
				option.value('__url-test', _('Create a latency-test group'));
				choices.policies.forEach(function(policy) { option.value(policy.id, policy.name || policy.id); });
				option.optional = true; option.rmempty = false;
				const members = s.taboption('routing', form.DynamicList, 'rematch_members_' + index, _('Candidates for %s').format(rematch.name || rematch.id), _('List candidate policies in order; the first is the initial default in manual mode. The former sub-rule conditions will no longer select between them.'));
				choices.policies.filter(function(policy) { return format !== 'singbox' || policy.id !== 'REJECT'; }).forEach(function(policy) { members.value(policy.id, policy.name || policy.id); });
				members.depends('rematch_' + index, '__manual'); members.depends('rematch_' + index, '__url-test');
				members.optional = true; members.rmempty = false;
				members.remove = function(sid) { return this.write(sid, []); };
			});
			if (choices.sub_rules.length) {
				o = s.taboption('routing', form.Flag, 'abandon_sub_rules', _('Remove sub-rule routing in the copy'), _('Removes the named sub-rules and their scoped rules. Review every removal in the next step.'));
				o.default = '0'; o.rmempty = false;
			}
			if (choices.has_dns) {
				o = s.taboption('settings', form.Flag, 'omit_dns', _('Omit Mihomo DNS policy in the copy'), _('The target will use its own DNS behavior. This can change resolution and routing.'));
				o.default = '0'; o.rmempty = false;
			}
			if (choices.has_mihomo_policy) {
				o = s.taboption('settings', form.Flag, 'omit_mihomo_policy', _('Omit Mihomo advanced policy in the copy'));
				o.default = '0'; o.rmempty = false;
			}
		}
		if (choices.rules.length && format !== 'mihomo') {
			o = s.taboption('routing', form.MultiValue, 'disable_rules', _('Disable selected rules in the copy'), _('Only select rules whose removal you accept. Traffic will continue to later rules or the fallback policy.'));
			choices.rules.forEach(function(rule) { o.value(rule.id, rule.id + ' · ' + (rule.name || rule.type) + (rule.targets.indexOf(format) >= 0 ? ' · ' + _('Incompatible') : '')); });
			o.optional = true; o.rmempty = false;
			o.remove = function(sid) { return this.write(sid, []); };
		}
		function show() {
			return m.render().then(function(node) {
				ui.showModal(_('Compatibility Wizard') + ' · ' + clients[format], [
					E('p', {}, _('Creates an independent draft from the saved profile. Select changes explicitly, then review their effects before saving.')),
					E('p', { 'class': 'cbi-section-descr' }, _('Changing a parent group does not change automation inside its candidate groups. Adjust those groups separately under Automation Level.')),
					format === 'singbox' ? E('p', { 'class': 'cbi-section-descr' }, _('Manual selection in sing-box requires a client with selector controls or a configured Clash API. Without those controls, the generated default uses the first candidate.')) : '',
					node, E('div', { 'class': 'right' }, [hs.button(_('Cancel'), ui.hideModal), ' ', hs.button(_('Preview Changes'), function() {
						return m.parse().then(function() {
							const values = m.data.get('json', 'copy');
							const resolutions = { rematches: {}, group_modes: {}, disable_rules: values.disable_rules || [] };
							choices.rematches.forEach(function(rematch, index) {
								const selected = values['rematch_' + index];
								if (selected === '__manual' || selected === '__url-test') resolutions.rematches[rematch.id] = { mode: selected.slice(2), members: values['rematch_members_' + index] || [] };
								else if (selected) resolutions.rematches[rematch.id] = selected;
							});
							(choices.groups || []).forEach(function(group, index) { if (values['group_mode_' + index]) resolutions.group_modes[group.id] = values['group_mode_' + index]; });
							['abandon_sub_rules', 'omit_dns', 'omit_mihomo_policy'].forEach(function(key) { resolutions[key] = values[key] === '1' || values[key] === true; });
							const args = { profile: source.id, format: format, id: values.id, name: values.name, resolutions: JSON.stringify(resolutions) };
							return hs.api('compatibility_plan', args).then(function(plan) { self.confirmPlan(plan, args, show); });
						});
					}, 'cbi-button-positive')])
				]);
			});
		}
		return show();
	},
	confirmPlan: function(plan, args, back) {
		const checks = plan.changes.map(function(change) { return { change: change, field: new ui.Checkbox('0') }; });
		ui.showModal(_('Review Compatibility Changes'), [
			E('p', {}, plan.ready ? _('The independent draft passes export validation. Confirm each change to create it.') : _('Unresolved issues still block this target. Go back to adjust decisions or edit the original draft.')),
			messages(plan.errors), messages(plan.warnings),
			E('div', {}, checks.map(function(item) {
				const node = item.field.render(), input = node.querySelector('input[type="checkbox"]');
				return E('p', {}, [node, ' ', E('label', { 'for': input.id }, hs.translateMessage(item.change.message))]);
			})),
			E('p', { 'class': 'cbi-section-descr' }, _('Creation saves a draft only. Build and publish it from Overview after reviewing the resulting profile.')),
			E('div', { 'class': 'right' }, [hs.button(_('Back'), back), ' ', hs.button(_('Cancel'), ui.hideModal), ' ', plan.ready ? hs.button(_('Create Independent Draft'), function() {
				if (checks.some(function(item) { return !item.field.isChecked(); })) throw new Error(_('Confirm every proposed change before creating the independent draft.'));
				return hs.api('compatibility_create', Object.assign({}, args, { version: plan.version, plan_token: plan.plan_token, accepted_changes: checks.map(function(item) { return item.change.code; }) })).then(function() {
					ui.hideModal();
					window.location.href = L.url('admin/services/hybrid-subscription/profiles') + '?profile=' + encodeURIComponent(args.id);
				});
			}, 'cbi-button-positive', true) : ''])
		]);
	},
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
