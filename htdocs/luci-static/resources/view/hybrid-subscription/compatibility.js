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
	return E('ul', {}, Array.from(new Set((items || []).map(function(item) { return typeof item === 'string' ? item : item.message; }))).map(function(message) { return E('li', {}, hs.translateMessage(message)); }));
}
function editorLink(page, label, profile) {
	return E('a', { 'class': 'cbi-button cbi-button-action', href: L.url('admin/services/hybrid-subscription/' + page) + '?profile=' + encodeURIComponent(profile) }, label);
}
function targetStatus(target) {
	const issues = target.issues || [];
	return target.errors.length || issues.some(function(issue) { return issue.severity === 'error'; }) ? _('Blocked') :
		target.warnings.length || issues.some(function(issue) { return issue.severity === 'warning'; }) ? _('Review Differences') : _('Compatible');
}
function suggestion(item, format) { return (item.suggestions || {})[format]; }
function issueGroups(target, choices) {
	const buckets = new Map();
	const titles = { group: _('Policy group modes'), rematch: _('Conditional routing'), sub_rules: _('Sub-rules'),
		dns: _('DNS policy'), runtime_policy: _('Runtime settings'), rule: _('Routing rules') };
	(target.issues || []).forEach(function(issue) {
		const group = issue.kind === 'group' && (choices.groups || []).find(function(row) { return row.id === issue.id; });
		const reason = group ? _('Mihomo: %s → %s: %s').format(modeLabel(group.modes.mihomo), clients[target.format], modeLabel(group.modes[target.format])) : hs.translateMessage(issue.message);
		const key = [issue.kind, issue.severity, reason].join(':');
		if (!buckets.has(key)) buckets.set(key, { title: titles[issue.kind] || issue.kind, reason: reason, items: [], suggestions: [] });
		const bucket = buckets.get(key);
		bucket.items.push(issue);
		const row = group || (issue.kind === 'rematch' && choices.rematches.find(function(row) { return row.id === issue.id; }));
		const proposed = row && suggestion(row, target.format);
		if (proposed && bucket.suggestions.indexOf(proposed.reason) < 0) bucket.suggestions.push(proposed.reason);
	});
	return Array.from(buckets.values());
}
function changeGroups(changes) {
	const titles = { 'create-profile': _('New profile'), 'group-mode': _('Policy group modes'), 'replace-rematch': _('Conditional routing'),
		'omit-subrule': _('Sub-rule removal'), 'omit-rule': _('Sub-rule removal'), 'disable-rule': _('Disabled rules'),
		'omit-mihomo_dns': _('DNS policy'), 'omit-mihomo_policy': _('Runtime settings'), 'copy-ruleset': _('Rule set copies') };
	const groups = new Map();
	changes.forEach(function(change) {
		const title = titles[change.code.split(':')[0]] || _('Other changes');
		if (!groups.has(title)) groups.set(title, { title: title, changes: [] });
		groups.get(title).changes.push(change);
	});
	return Array.from(groups.values());
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
			return m.parse().then(function() { return hs.api('compatibility', { profile: m.data.get('json', 'selection', 'profile') }); }).then(function(report) {
				dom.content(output, self.reportContent(report));
			});
		}
		return m.render().then(function(node) {
			const page = E('div', { 'class': 'cbi-map' }, [E('h2', {}, _('Compatibility')),
				E('p', { 'class': 'cbi-map-descr' }, _('Compare clients, review the differences, then prepare a separate draft. Checks use saved settings and cached nodes.')),
				node, E('p', {}, hs.button(_('Check Compatibility'), check)), output]);
			// JSONMap controls must be mounted before parsing their current values.
			return hs.api('compatibility', { profile: m.data.get('json', 'selection', 'profile') }).then(function(report) { dom.content(output, self.reportContent(report)); return page; });
		});
	},
	reportContent: function(report) {
		const self = this, panel = E('div', { 'aria-live': 'polite' });
		function select(target) { dom.content(panel, self.targetContent(report, target)); }
		select(report.targets.find(function(target) { return target.errors.length || (target.issues || []).length; }) || report.targets[0]);
		return E('div', {}, [hs.table([_('Target Client'), _('Status'), _('Items to review'), _('Actions')], report.targets.map(function(target) {
			return [clients[target.format], targetStatus(target), (target.issues || []).length,
				hs.button(_('View Suggestions'), function() { select(target); })];
		})), panel]);
	},
	targetContent: function(report, target) {
		const self = this, buckets = issueGroups(target, report.choices), issues = target.issues || [];
		const warnings = target.warnings.filter(function(warning) {
			return !issues.some(function(issue) { return warning.code === target.format + ':' + issue.code || warning.message === issue.message; });
		});
		const available = (report.choices.groups || []).concat(report.choices.rematches || []).filter(function(row) { return (suggestion(row, target.format) || {}).available; }).length;
		return E('div', { 'class': 'cbi-section' }, [E('h3', {}, clients[target.format]),
			E('p', {}, buckets.length ? _('%s issue types. Expand a row to see the affected items.').format(buckets.length) : _('No additional compatibility issues.')),
			buckets.length ? hs.table([_('Issue'), _('Details and suggestions')], buckets.map(function(bucket) {
				return [E('details', {}, [E('summary', {}, _('%s · %s items').format(bucket.title, bucket.items.length)),
					E('ul', {}, bucket.items.map(function(item) { return E('li', {}, [item.name || item.id,
						item.kind === 'group' && item.severity === 'error' ? E('p', {}, hs.translateMessage(item.message)) : '']); }))]),
					E('div', {}, [E('p', {}, bucket.reason)].concat(bucket.suggestions.map(function(reason) { return E('p', {}, hs.translateMessage(reason)); })))];
			})) : '',
			available ? E('p', {}, _('%s suggestions can fill unset choices. Rules and DNS settings still need your decision.').format(available)) : '',
			E('p', {}, [available ? hs.button(_('Use Suggestions'), function() { return self.wizard(report, target.format, true); }, 'cbi-button-positive', true) : '', ' ',
				hs.button(_('Adjust Manually'), function() { return self.wizard(report, target.format); }, null, true), ' ', editorLink('rules', _('Edit Routing Rules'), report.profile.id)]),
			target.errors.length || warnings.length ? E('details', {}, [E('summary', {}, _('Export validation details')), messages(target.errors), messages(warnings)]) : ''
		]);
	},
	wizard: function(report, format, useSuggestions) {
		const self = this, choices = report.choices, source = report.profile;
		const target = report.targets.find(function(item) { return item.format === format; });
		const affected = new Set((target.issues || []).filter(function(issue) { return issue.kind === 'group'; }).map(function(issue) { return issue.id; }));
		const base = source.id.slice(0, 34) + '_' + format;
		let id = base, n = 2, showAllGroups = false, feedback = '';
		while (this.config.profiles.some(function(p) { return p.id === id; })) id = base + '_' + n++;
		const groups = (choices.groups || []).map(function(row, index) { return { '.name': 'group_' + index, id: row.id, name: row.name || row.id, mode: '' }; });
		const rematches = (choices.rematches || []).map(function(row, index) { return { '.name': 'rematch_' + index, id: row.id, name: row.name || row.id, replacement: '', members: [] }; });
		const m = new form.JSONMap({ copy: { id: id, name: (source.name || source.id) + ' · ' + clients[format], disable_rules: [], batch_mode: 'recommended' }, group: groups, rematch: rematches });
		function fillSuggestions() {
			let count = 0;
			groups.forEach(function(row, index) {
				const proposed = suggestion(choices.groups[index], format);
				if (proposed && proposed.available && !m.data.get('json', row['.name'], 'mode')) { m.data.set('json', row['.name'], 'mode', proposed.mode); count++; }
			});
			if (format !== 'mihomo') rematches.forEach(function(row, index) {
				const proposed = suggestion(choices.rematches[index], format);
				if (proposed && proposed.available && !m.data.get('json', row['.name'], 'replacement')) {
					m.data.set('json', row['.name'], 'replacement', '__' + proposed.mode);
					m.data.set('json', row['.name'], 'members', proposed.members.slice()); count++;
				}
			});
			feedback = _('%s unset choices filled. Existing choices were kept.').format(count);
		}
		if (useSuggestions) fillSuggestions();
		const s = m.section(form.NamedSection, 'copy', 'copy');
		s.selected_tab = useSuggestions && affected.size ? 'automation' : useSuggestions && rematches.length && format !== 'mihomo' ? 'routing' : 'general';
		function rememberTab(event) { s.selected_tab = event.detail.tab; }
		s.tab('general', _('Independent Profile'));
		s.tab('automation', _('Policy Groups'), _('Manual selects a candidate; URL Test selects by latency; Fallback follows availability and order. Changes apply only to the listed groups.'));
		if (format !== 'mihomo') {
			s.tab('routing', _('Routing Decisions'), _('Replacing conditional routing changes how traffic selects a policy. Review the proposed candidates; rules are never removed automatically.'));
			s.tab('settings', _('Client Settings'));
		}
		let o = s.taboption('general', form.Value, 'id', _('Identifier'));
		o.rmempty = false;
		o.validate = function(sid, value) { return /^[a-z][a-z0-9_-]{0,47}$/.test(value) || _('Start with a lowercase letter and use only lowercase letters, digits, underscores, or hyphens (up to 48 characters).'); };
		o = s.taboption('general', form.Value, 'name', _('Name')); o.rmempty = false;
		o = s.taboption('automation', form.ListValue, 'batch_mode', _('Batch choice'));
		o.value('recommended', _('Suggested modes'));
		['manual', 'url-test'].concat(format === 'singbox' ? [] : ['fallback']).forEach(function(mode) { o.value(mode, modeLabel(mode)); });
		o.rmempty = false;
		o = s.taboption('automation', form.Button, '_batch', _('Affected groups only'), _('Replaces choices for affected groups. Other groups are kept.'));
		o.inputtitle = _('Apply to Affected Groups');
		o.onclick = function() {
			return m.parse().then(function() {
				const mode = m.data.get('json', 'copy', 'batch_mode'); let count = 0;
				groups.forEach(function(row, index) {
					const proposed = suggestion(choices.groups[index], format);
					const selected = mode === 'recommended' ? proposed && proposed.available && proposed.mode : mode;
					if (affected.has(row.id) && selected && m.data.get('json', row['.name'], 'mode') !== selected) { m.data.set('json', row['.name'], 'mode', selected); count++; }
				});
				feedback = _('%s group choices updated.').format(count);
				s.selected_tab = 'automation'; return show();
			});
		};
		o = s.taboption('automation', form.Button, '_show_groups', _('Group visibility'));
		o.inputtitle = _('Show All Groups');
		o.onclick = function() { return m.parse().then(function() { showAllGroups = !showAllGroups; s.selected_tab = 'automation'; return show(); }); };
		const visibility = o;
		const groupTable = s.taboption('automation', form.SectionValue, '_groups', form.TableSection, 'group').subsection;
		groupTable.anonymous = true; groupTable.addremove = false;
		groupTable.filter = function(sid) { return showAllGroups || affected.has(m.data.get('json', sid, 'id')) || !!m.data.get('json', sid, 'mode'); };
		groupTable.option(form.DummyValue, 'name', _('Policy Group'));
		o = groupTable.option(form.DummyValue, '_modes', _('Mihomo → target'));
		o.cfgvalue = function(sid) { const row = choices.groups.find(function(row) { return row.id === m.data.get('json', sid, 'id'); }); return modeLabel(row.modes.mihomo) + ' → ' + modeLabel(row.modes[format]); };
		o = groupTable.option(form.ListValue, 'mode', _('Use in the copy'));
		o.value('', _('No choice yet')); o.value('keep', _('Keep current mode'));
		['manual', 'url-test'].concat(format === 'singbox' ? [] : ['fallback']).forEach(function(mode) { o.value(mode, modeLabel(mode)); });
		o.rmempty = false; o.optional = true;
		if (format !== 'mihomo') {
			if (rematches.length) {
				const table = s.taboption('routing', form.SectionValue, '_rematches', form.TableSection, 'rematch').subsection;
				table.anonymous = true; table.addremove = false;
				table.option(form.DummyValue, 'name', _('Conditional entry'));
				o = table.option(form.ListValue, 'replacement', _('Replacement'));
				o.value('', _('Needs a decision')); o.value('__manual', _('Manual candidate group')); o.value('__url-test', _('Latency-test candidate group'));
				choices.policies.forEach(function(policy) { o.value(policy.id, policy.name || policy.id); });
				o.optional = true; o.rmempty = false;
				o = table.option(form.DynamicList, 'members', _('Candidates in order'));
				choices.policies.filter(function(policy) { return format !== 'singbox' || policy.id !== 'REJECT'; }).forEach(function(policy) { o.value(policy.id, policy.name || policy.id); });
				o.depends('replacement', '__manual'); o.depends('replacement', '__url-test'); o.optional = true; o.rmempty = false; o.retain = true;
				o.remove = function(sid) { return this.write(sid, []); };
			}
			if (choices.sub_rules.length) {
				o = s.taboption('routing', form.Flag, 'abandon_sub_rules', _('Remove sub-rule routing in the copy'), _('Removes the named sub-rules and their scoped rules. Review every removal in the next step.'));
				o.default = '0'; o.rmempty = false;
			}
			const incompatibleRules = choices.rules.filter(function(rule) { return rule.targets.indexOf(format) >= 0; });
			if (incompatibleRules.length) {
				o = s.taboption('routing', form.MultiValue, 'disable_rules', _('Disable incompatible rules'), _('Optional. Unselected rules stay enabled and may still block export. Rules inside removed sub-rules are already covered by that removal.'));
				incompatibleRules.forEach(function(rule) { o.value(rule.id, (rule.name && rule.name !== rule.id ? rule.name + ' · ' : '') + rule.id + ' · ' + rule.type); });
				o.optional = true; o.rmempty = false; o.remove = function(sid) { return this.write(sid, []); };
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
		function show() {
			visibility.inputtitle = showAllGroups ? _('Show Affected Groups') : _('Show All Groups');
			return m.render().then(function(node) {
				node.addEventListener('cbi-tab-active', rememberTab, true);
				// Preserve LuCI widget bindings when showModal clears its previous content.
				node.remove();
				ui.showModal(_('Compatibility Wizard') + ' · ' + clients[format], [
					E('p', {}, _('Suggestions fill choices for review. Saving creates a separate draft; the original profile stays unchanged.')),
					feedback ? E('p', { 'class': 'alert-message info', 'role': 'status' }, feedback) : '',
					format === 'singbox' ? E('p', { 'class': 'cbi-section-descr' }, _('Manual selection in sing-box needs client controls; otherwise it uses the first candidate.')) : '', node,
					E('div', { 'class': 'right' }, [hs.button(_('Cancel'), ui.hideModal), ' ',
						hs.button(_('Fill Unset Suggestions'), function() { return m.parse().then(function() { fillSuggestions(); return show(); }); }), ' ', hs.button(_('Preview Changes'), function() {
							return m.parse().then(function() {
								const values = m.data.get('json', 'copy'), resolutions = { rematches: {}, group_modes: {}, disable_rules: values.disable_rules || [] };
								rematches.forEach(function(row) {
									const selected = m.data.get('json', row['.name'], 'replacement');
									if (selected === '__manual' || selected === '__url-test') resolutions.rematches[row.id] = { mode: selected.slice(2), members: m.data.get('json', row['.name'], 'members') || [] };
									else if (selected) resolutions.rematches[row.id] = selected;
								});
								groups.forEach(function(row) { const mode = m.data.get('json', row['.name'], 'mode'); if (mode && mode !== 'keep') resolutions.group_modes[row.id] = mode; });
								['abandon_sub_rules', 'omit_dns', 'omit_mihomo_policy'].forEach(function(key) { resolutions[key] = values[key] === '1' || values[key] === true; });
								const args = { profile: source.id, format: format, id: values.id, name: values.name, resolutions: JSON.stringify(resolutions) };
								return hs.api('compatibility_plan', args).then(function(plan) { node.remove(); self.confirmPlan(plan, args, show); });
							});
						}, 'cbi-button-positive')])
				]);
			});
		}
		return show();
	},
	confirmPlan: function(plan, args, back) {
		const checks = changeGroups(plan.changes).map(function(group) { return Object.assign(group, { field: new ui.Checkbox('0') }); });
		ui.showModal(_('Review Compatibility Changes'), [
			E('p', {}, plan.ready ? _('Review each change category, then confirm to create the draft.') : _('Unresolved issues still block this target. Go back to adjust decisions or edit the original draft.')),
			messages(plan.errors),
			plan.warnings.length ? E('details', {}, [E('summary', {}, _('Remaining export warnings')), messages(plan.warnings)]) : '',
			E('div', {}, checks.map(function(item) {
				const node = item.field.render(), input = node.querySelector('input[type="checkbox"]');
				return E('div', { 'class': 'cbi-section' }, [E('div', { 'class': 'control-group' }, [node, ' ', E('label', { 'for': input.id }, _('%s · %s changes').format(item.title, item.changes.length))]),
					E('details', {}, [E('summary', {}, _('Show Changes')), E('ul', {}, item.changes.map(function(change) { return E('li', {}, hs.translateMessage(change.message)); }))])]);
			})),
			E('p', { 'class': 'cbi-section-descr' }, _('Creation saves a draft only. Build and publish it from Overview after reviewing the resulting profile.')),
			E('div', { 'class': 'right' }, [hs.button(_('Back'), back), ' ', hs.button(_('Cancel'), ui.hideModal), ' ', plan.ready ? hs.button(_('Create Independent Draft'), function() {
				if (checks.some(function(item) { return !item.field.isChecked(); })) throw new Error(_('Confirm every change category before creating the independent draft.'));
				return hs.api('compatibility_create', Object.assign({}, args, { version: plan.version, plan_token: plan.plan_token, accepted_changes: checks.flatMap(function(item) { return item.changes.map(function(change) { return change.code; }); }) })).then(function() {
					ui.hideModal(); window.location.href = L.url('admin/services/hybrid-subscription/profiles') + '?profile=' + encodeURIComponent(args.id);
				});
			}, 'cbi-button-positive', true) : ''])
		]);
	},
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
