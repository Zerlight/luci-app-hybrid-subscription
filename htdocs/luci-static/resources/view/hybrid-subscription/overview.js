'use strict';
'require view';
'require dom';
'require poll';
'require ui';
'require hybrid-subscription as hs';

function trMsg(text) { return hs && hs.translateMessage ? hs.translateMessage(text) : text; }
function link(page, label, profile) {
	return E('a', { 'class': 'cbi-button cbi-button-action', href: L.url('admin/services/hybrid-subscription/' + page) + (profile ? '?profile=' + encodeURIComponent(profile) : '') }, label);
}
function bytes(value) { return value == null ? _('Unknown') : (Number(value) / 1073741824).toFixed(2) + ' GiB'; }
function confirmPublish(release, done) {
	const checks = (release.warnings || []).map(function(w) { return { warning: w, field: new ui.Checkbox('0') }; });
	ui.showModal(_('Confirm Publication'), [
		E('p', {}, _('Validation and build succeeded. Publishing makes this release available via the download link without re-fetching upstream sources.')),
		E('p', {}, checks.length ? _('The following compatibility differences may affect client behavior. Please review and confirm each item:') : _('No compatibility differences require confirmation.')),
		E('div', {}, checks.map(function(item) {
			const field = item.field.render(), input = field.querySelector('input[type="checkbox"]');
			return E('p', {}, [field, ' ', E('label', { 'for': input.id }, '[' + (item.warning.target || item.warning.code) + '] ' + trMsg(item.warning.message))]);
		})),
		E('div', { 'class': 'right' }, [hs.button(_('Not Now'), ui.hideModal), ' ', hs.button(_('Confirm Publication'), function() {
			if (checks.some(function(c) { return !c.field.isChecked(); })) throw new Error(_('Please confirm all compatibility differences, or return to modify the configuration.'));
			return hs.api('publish', { release: release.id, accepted_warnings: checks.map(function(c) { return c.warning.code; }) }).then(function(result) {
				ui.hideModal();
				return result.job ? hs.waitJob(result.job, _('Apply to OpenClash')) : result;
			}).then(done);
		}, 'cbi-button-positive', true)])
	]);
}
function quotaCell(s) {
	const q = s.quota || {}, state = s.quota_status || {};
	const has = Object.keys(q).length > 0;
	return E('div', {}, [
		E('div', {}, has ? _('Used ') + bytes(q.upload == null || q.download == null ? null : Number(q.upload || 0) + Number(q.download || 0)) + ' / ' + bytes(q.total) : _('No quota data')),
		E('div', { 'class': 'cbi-section-descr' }, has ? _('Expires: ') + (q.expire == null ? _('Not provided by upstream') : q.expire === 0 ? _('Never expires') : hs.time(q.expire)) : state.can_refresh ? _('Click "Refresh Quota" to fetch the latest data.') : _('Quota query is not configured. Configure it under Subscription Sources.')),
		has ? E('div', { 'class': 'cbi-section-descr' }, (state.stale ? _('Stale · ') : '') + hs.time(state.updated_at || s.cached_at)) : '',
		state.error ? E('div', { 'class': 'cbi-section-descr' }, trMsg(state.error)) : ''
	]);
}

return view.extend({
	load: function() { return Promise.all([hs.api('get_config'), hs.api('status')]); },
	preview: function(profile) {
		const format = E('select', { 'class': 'cbi-input-select', 'aria-label': _('Preview Client Format') }, (profile.formats || []).map(function(f) { return E('option', { value: f }, f); }));
		const output = E('pre', {}, _('Select a format to generate a preview. Sensitive node credentials will be redacted.')), messages = E('p');
		ui.showModal(_('Preview: ') + profile.name, [E('p', {}, [format, ' ', hs.button(_('Generate Preview'), function() {
			return hs.api('preview', { profile: profile.id, format: format.value }).then(function(result) {
				output.textContent = result.content || _('No content available to display.');
				messages.textContent = [].concat(result.errors || [], (result.warnings || []).map(function(w) { return w.message; })).map(function(e) { return trMsg(typeof e === 'string' ? e : e.message); }).join('\n');
			});
		})]), messages, output, E('div', { 'class': 'right' }, hs.button(_('Close'), ui.hideModal))]);
	},
	manage: function(profile, current, data) {
		const self = this;
		ui.showModal(_('Release Management: ') + profile.name, [
			E('p', {}, [hs.button(_('Validate Draft'), function() { return hs.api('validate', { profile: profile.id }).then(function(result) { hs.report(_('Validation Result'), result); }); }), ' ', hs.button(_('View Preview'), function() { self.preview(profile); }), ' ', link('rules', _('Edit Routing Rules'), profile.id)]),
			E('h4', {}, _('Release History')),
			hs.table([_('Created At'), _('Release ID'), _('Status'), _('Actions')], (data.releases || []).filter(function(r) { return r.profile === profile.id; }).map(function(r) {
				return [hs.time(r.created_at), r.id, r.published ? _('Published') : r.ever_published ? _('Previously Published') : _('Unpublished'), r.published ? '—' : hs.button(r.ever_published ? _('Roll Back') : _('Publish'), function() {
					if (!r.ever_published) return confirmPublish(r, function() { window.location.reload(); });
					ui.showModal(_('Roll Back Release'), [E('p', {}, _('Rolling back restores the download link to this release. If auto-apply is enabled, OpenClash will also be updated.')), E('div', { 'class': 'right' }, [hs.button(_('Cancel'), ui.hideModal), ' ', hs.button(_('Confirm Rollback'), function() {
						return hs.api('rollback', { release: r.id }).then(function(result) { return result.job ? hs.waitJob(result.job, _('Roll Back OpenClash')) : result; }).then(function() { window.location.reload(); });
					}, 'cbi-button-positive', true)])]);
				}, null, true)];
			})),
			current.published_release ? E('details', {}, [E('summary', {}, _('OpenClash & Download Management')), E('p', {}, [
				data.openclash && data.openclash.installed && (current.formats || []).indexOf('mihomo') >= 0 ? hs.button(_('Apply Published Release to OpenClash'), function() {
					ui.showModal(_('Apply to OpenClash'), [E('p', {}, _('This will back up and switch the active OpenClash configuration, which may briefly interrupt proxy connections.')), E('div', { 'class': 'right' }, [hs.button(_('Cancel'), ui.hideModal), ' ', hs.button(_('Apply'), function() { return hs.runJob('apply_openclash', { profile: profile.id }, _('Apply to OpenClash')).then(function() { window.location.reload(); }); }, 'cbi-button-positive', true)])]);
				}, null, true) : '', ' ',
				hs.button(_('Rotate Download Token'), function() {
					ui.showModal(_('Rotate Download Token'), [E('p', {}, _('Existing download links and QR codes will be invalidated immediately. Clients must re-import the new subscription URL.')), E('div', { 'class': 'right' }, [hs.button(_('Cancel'), ui.hideModal), ' ', hs.button(_('Confirm Rotation'), function() { return hs.api('rotate_token', { profile: profile.id }).then(function() { return hs.download(profile.id); }); }, 'cbi-button-negative', true)])]);
				}, null, true), ' ',
				hs.button(_('Unpublish'), function() {
					ui.showModal(_('Unpublish'), [E('p', {}, _('Revokes download links while retaining release history and the active OpenClash configuration.')), E('div', { 'class': 'right' }, [hs.button(_('Cancel'), ui.hideModal), ' ', hs.button(_('Confirm Unpublish'), function() { return hs.api('unpublish', { profile: profile.id }).then(function() { window.location.reload(); }); }, 'cbi-button-negative', true)])]);
				}, 'cbi-button-negative', true)
			])]) : '',
			E('div', { 'class': 'right' }, hs.button(_('Close'), ui.hideModal))
		]);
	},
	statusContent: function(data) {
		const self = this, state = {};
		(data.profiles || []).forEach(function(p) { state[p.id] = p; });
		return E('div', {}, [
			E('h3', {}, _('Subscription Profiles')),
			(this.config.profiles || []).length ? E('div', {}, this.config.profiles.map(function(p) {
				const current = state[p.id] || {};
				return E('div', { 'class': 'cbi-section' }, [
					E('h4', {}, p.name || p.id),
					E('p', {}, current.published_release ? _('Published · ') + (current.formats || []).join(' / ') + ' · ' + hs.time(current.generated_at) : _('Draft · Unpublished')),
					E('p', {}, [link('profiles', _('Edit Profile'), p.id), ' ', hs.button(_('Build & Publish'), function() {
						return hs.runJob('build', { profile: p.id }, _('Validate and Build Release')).then(function(job) {
							const result = job.result || {};
							if (!result.release) throw new Error(_('No release ID was returned. Please check the job status.'));
							confirmPublish({ id: result.release, warnings: result.warnings || [] }, function() { window.location.reload(); });
						});
					}, 'cbi-button-positive', true), ' ', current.published_release ? hs.button(_('Download / QR Code'), function() { return hs.download(p.id); }) : '', ' ', hs.button(_('Release Management'), function() { self.manage(p, current, data); })])
				]);
			})) : E('p', {}, [_('Add subscription sources first, then create a subscription profile.'), ' ', link('profiles', _('Create Subscription Profile'))]),
			E('h3', {}, _('Subscription Source Status')),
			hs.table([_('Source'), _('Node Cache'), _('Quota / Expiration'), _('Actions')], (data.sources || []).map(function(s) {
				const names = Object.keys(s.regions || {});
				return [E('strong', {}, s.name || s.id), E('div', {}, [E('div', {}, s.cached_at ? String(s.nodes || 0) + _(' nodes') : _('Not cached')), E('div', { 'class': 'cbi-section-descr' }, s.error ? trMsg(s.error) : hs.time(s.cached_at)), names.length ? E('div', { 'class': 'cbi-section-descr' }, String(names.length) + _(' regions matched')) : '']), quotaCell(s), E('div', {}, [
					s.quota_status && s.quota_status.can_refresh ? hs.button(_('Refresh Quota'), function() { return hs.runJob('refresh_quota', { source: s.id }, _('Refresh Quota Status')).then(function() { window.location.reload(); }); }, null, true) : '', ' ', link('sources', _('Manage Sources'))
				])];
			})),
			E('details', {}, [E('summary', {}, _('Components & Recent Jobs')), hs.table([_('Component'), _('Status')], [
				['OpenClash', data.openclash && data.openclash.installed ? (data.openclash.active_config || _('Installed')) : _('Not installed')],
				['subconverter', data.converter && data.converter.available ? (data.converter.version || _('Available')) : _('Unavailable')]
			]), hs.table([_('Time'), _('Operation'), _('Status'), _('Details')], (data.jobs || []).slice(0, 8).map(function(j) {
				return [hs.time(j.created_at), { refresh: _('Update Nodes'), refresh_quota: _('Refresh Quota'), build: _('Build Release'), apply: _('Apply to OpenClash'), compare: _('Compatibility Audit') }[j.kind] || j.kind, { queued: _('Queued'), running: _('Running'), completed: _('Completed'), failed: _('Failed') }[j.state] || j.state, trMsg(j.error || j.message) || '—'];
			}))])
		]);
	},
	render: function(payload) {
		this.config = payload[0].config;
		const self = this, content = E('div', {}, this.statusContent(payload[1]));
		let failures = 0;
		poll.add(function() { return hs.api('status').then(function(data) {
			failures = 0;
			// Keep the user's focus and expanded diagnostics stable while they read or act.
			if (!content.contains(document.activeElement) && !content.querySelector('details[open]')) dom.content(content, self.statusContent(data));
		}).catch(function(error) { if (++failures === 1) hs.notify(error); }); }, 15);
		return content;
	},
	handleSave: null, handleSaveApply: null, handleReset: null
});
