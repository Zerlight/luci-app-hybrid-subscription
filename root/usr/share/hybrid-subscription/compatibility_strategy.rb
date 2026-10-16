# frozen_string_literal: true

module HybridSubscription
  # Strategy fingerprints describe saved configuration, never cached credentials.
  module CompatibilityStrategy
    def canonical(value)
      case value
      when Hash then value.keys.sort.each_with_object({}) { |key, out| out[key] = canonical(value[key]) }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def fingerprint(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def without_strategy(value)
      value.reject { |key, _| key == 'compatibility' }
    end

    def set_ids(rule_rows, profile_row)
      ids = []
      visit = lambda do |rule, depth|
        next unless rule.is_a?(Hash) && depth < 32
        ids << rule['value'] if rule['type'] == 'RULE-SET' && rule['value'].is_a?(String)
        Array(rule['conditions']).each { |child| visit.call(child, depth + 1) }
      end
      rule_rows.each { |rule| visit.call(rule, 0) }
      dns = profile_row['mihomo_dns'] || {}
      if dns.is_a?(Hash)
        ids.concat((Array(dns['fake-ip-filter']) + %w[nameserver-policy proxy-server-nameserver-policy].flat_map { |key| dns[key].is_a?(Hash) ? dns[key].keys : [] }).grep(/^rule-set:/).flat_map { |value| value.delete_prefix('rule-set:').split(',') })
      end
      ids.uniq
    end

    def dependency_rows(collection, ids)
      ids.uniq.sort_by { |id| JSON.generate(id) }.map do |id|
        Array(@config[collection]).find { |row| row['id'] == id } || {'id'=>id, 'missing'=>true}
      end
    end

    def source_dependencies(ids)
      dependency_rows('sources', ids).map do |source|
        source.slice('id', 'name', 'enabled', 'exclude_filter', 'url', 'format', 'user_agent', 'missing')
      end
    end

    def region_dependencies(groups)
      region_sources = {}
      groups.each do |group|
        region = group['region']
        next if region.to_s.empty?
        region_sources[region] ||= []
        region_sources[region].concat(Array(group['sources']))
      end
      dependency_rows('regions', region_sources.keys).map do |region|
        region.slice('id', 'pattern', 'missing').merge('source_patterns'=>(region['source_patterns'] || {}).select { |source, _| region_sources[region['id']].include?(source) })
      end
    end

    def source_fingerprint(id)
      p = profile(id)
      scoped = self.class::SCOPED.to_h { |key| [key, rows(key, id)] }
      sources = source_dependencies(Array(p['sources']))
      regions = region_dependencies(scoped['groups'])
      sets = dependency_rows('rule_sets', set_ids(scoped['rules'], p))
      fingerprint(scoped.merge('profile'=>without_strategy(p), 'sources'=>sources, 'rule_sets'=>sets, 'regions'=>regions))
    end

    def owned_state(id, managed_sets = [])
      self.class::SCOPED.to_h { |key| [key, rows(key, id)] }.merge('profile'=>without_strategy(profile(id)), 'rule_sets'=>dependency_rows('rule_sets', managed_sets))
    end

    def policy_dependencies(id, policy)
      maps = %w[groups rematches sub_rules].to_h { |key| [key, rows(key, id).to_h { |row| [row['id'], row] }] }
      scoped_rules = rows('rules', id).group_by { |row| row['sub_rule'] }
      pending, graph, used_groups, used_rules = [policy], {}, [], []
      until pending.empty?
        current = pending.shift
        key = JSON.generate(current)
        next if graph.key?(key)
        group, rematch = maps['groups'][current], maps['rematches'][current]
        if group
          graph[key] = group
          used_groups << group
          pending.concat(Array(group['members']) + %w[default_member empty_fallback].map { |field| group[field] }.compact.reject { |value| value == '' })
        elsif rematch
          sub = maps['sub_rules'][rematch['target_sub_rule']]
          rules = sub ? scoped_rules.fetch(sub['id'], []) : []
          graph[key] = {'rematch'=>rematch, 'sub_rule'=>sub, 'rules'=>rules}
          used_rules.concat(rules)
          pending.concat(rules.map { |rule| rule['policy'] } + [sub && sub['final_policy']])
        else
          graph[key] = {'id'=>current, Engine::BUILTINS.include?(current) ? 'terminal' : 'missing'=>true}
        end
      end
      {'policies'=>graph, 'sources'=>source_dependencies(used_groups.flat_map { |group| Array(group['sources']) }), 'regions'=>region_dependencies(used_groups), 'rule_sets'=>dependency_rows('rule_sets', set_ids(used_rules, {}))}
    end

    def decision_fingerprints(id, choices)
      result = {}
      choices.fetch('group_modes', {}).each_key do |group|
        result['group_modes:' + group] = fingerprint(rows('groups', id).find { |row| row['id'] == group })
      end
      choices.fetch('rematches', {}).each do |rematch, choice|
        candidates = choice.is_a?(Hash) ? choice['members'] : [choice]
        result['rematches:' + rematch] = fingerprint([policy_dependencies(id, rematch), Array(candidates).map { |candidate| policy_dependencies(id, candidate) }])
      end
      choices.fetch('disable_rules', []).each do |rule|
        row = rows('rules', id).find { |item| item['id'] == rule }
        result['disable_rules:' + rule] = fingerprint([row, dependency_rows('rule_sets', set_ids(row ? [row] : [], {}))])
      end
      if choices['abandon_sub_rules']
        scoped_rules = rows('rules', id).reject { |row| row['sub_rule'].to_s.empty? }
        result['abandon_sub_rules'] = fingerprint([rows('sub_rules', id), scoped_rules, dependency_rows('rule_sets', set_ids(scoped_rules, {}))])
      end
      {'omit_dns'=>'mihomo_dns', 'omit_mihomo_policy'=>'mihomo_policy'}.each do |key, field|
        result[key] = fingerprint([profile(id)[field], field == 'mihomo_dns' ? dependency_rows('rule_sets', set_ids([], profile(id))) : []]) if choices[key]
      end
      result
    end

    def reusable_resolutions(metadata)
      choices = Engine.copy(metadata['resolutions'] || {})
      current = decision_fingerprints(metadata['source_profile'], choices)
      previous = metadata['decision_digests'] || {}
      invalidated = []
      current.each do |code, digest|
        key, id = code.split(':', 2)
        begin
          value = if %w[group_modes rematches].include?(key)
                    {key=>{id=>choices[key][id]}}
                  elsif key == 'disable_rules'
                    {key=>[id]}
                  else
                    {key=>choices[key]}
                  end
          resolutions(value, metadata['source_profile'], metadata['format'])
          valid = previous[code] == digest
        rescue Error
          valid = false
        end
        next if valid
        if %w[group_modes rematches].include?(key)
          choices[key].delete(id)
        elsif key == 'disable_rules'
          choices[key].delete(id)
        else
          choices.delete(key)
        end
        item = {'code'=>code, 'resolution'=>key, 'message'=>'The source content or a referenced policy changed; review this saved choice again.'}
        item['id'] = id if id
        invalidated << item
      end
      [choices, invalidated]
    end

    def strategy_status(id, details: false)
      p = profile(id)
      metadata = p['compatibility']
      return nil unless metadata.is_a?(Hash) && metadata['schema'] == 1
      source_missing = !@config['profiles'].any? { |source| source['id'] == metadata['source_profile'] }
      source_changed = source_missing || source_fingerprint(metadata['source_profile']) != metadata['source_digest']
      target_changed = fingerprint(owned_state(id, Array(metadata['managed_rule_sets']))) != metadata['target_digest']
      result = p.slice('id', 'name').merge('format'=>metadata['format'], 'source_profile'=>metadata['source_profile'], 'source_missing'=>source_missing, 'source_changed'=>source_changed, 'target_changed'=>target_changed, 'needs_review'=>source_changed || target_changed)
      if details
        choices, invalidated = source_missing ? [{}, [{'code'=>'source-missing', 'resolution'=>'source_profile', 'message'=>'The source profile no longer exists; the current compatible draft and published release are preserved.'}]] : reusable_resolutions(metadata)
        result.merge!('resolutions'=>choices, 'invalidated'=>invalidated)
      end
      result
    end

    def check_ancestry(source_id, target_id)
      seen = [target_id]
      current = source_id
      32.times do
        raise Error, 'Compatibility source relationships contain a cycle' if seen.include?(current)
        seen << current
        row = @config['profiles'].find { |item| item['id'] == current }
        metadata = row && row['compatibility']
        return unless metadata.is_a?(Hash) && metadata['schema'] == 1
        current = metadata['source_profile']
      end
      raise Error, 'Compatibility source relationships exceed the depth limit'
    end

    def prepare_reapply(draft, id, source_id, format)
      target = profile(id)
      metadata = target['compatibility']
      raise Error, 'Only a tracked compatible profile can be updated from its source' unless metadata.is_a?(Hash) && metadata['schema'] == 1
      raise Error, 'The update must use the saved source profile and target format' unless metadata['source_profile'] == source_id && metadata['format'] == format
      managed = Array(metadata['managed_rule_sets'])
      external = @config['profiles'].reject { |p| p['id'] == id }.flat_map { |p| set_ids(rows('rules', p['id']), p) }
      raise Error, 'A managed compatibility rule set is used by another profile; resolve that reference before updating' unless (managed & external).empty?
      draft['profiles'].reject! { |p| p['id'] == id }
      self.class::SCOPED.each { |key| draft[key].reject! { |row| row['profile'] == id } }
      draft['rule_sets'].reject! { |set| managed.include?(set['id']) }
      [target['name'], managed]
    end

    def target_changes(before, after)
      changes = []
      %w[profile groups rematches sub_rules rules rule_sets].each do |key|
        old_rows = key == 'profile' ? [before[key]] : before[key]
        new_rows = key == 'profile' ? [after[key]] : after[key]
        old_map = old_rows.to_h { |row| [row['id'], row] }
        new_map = new_rows.to_h { |row| [row['id'], row] }
        (old_map.keys | new_map.keys).each do |id|
          old, fresh = old_map[id], new_map[id]
          next if canonical(old) == canonical(fresh)
          action = !old ? 'Add' : !fresh ? 'Remove' : 'Replace'
          fields = old && fresh ? (old.keys | fresh.keys).select { |field| canonical(old[field]) != canonical(fresh[field]) }.sort : []
          changes << {'code'=>"target-#{action.downcase}:#{key}:#{id}", 'message'=>"#{action} target #{key} #{(fresh || old)['name'] || id} (#{id})" + (fields.empty? ? '' : "; changed fields: #{fields.join(', ')}")}
        end
        if old_map.keys.sort == new_map.keys.sort && old_map.keys != new_map.keys
          changes << {'code'=>"target-reorder:#{key}", 'message'=>"Update the order of target #{key}"}
        end
      end
      changes
    end
  end
end
