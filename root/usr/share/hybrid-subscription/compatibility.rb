# frozen_string_literal: true
require_relative 'engine'
require_relative 'compatibility_strategy'

module HybridSubscription
  # Plans are regenerated from the saved draft and caches before any write.
  class Compatibility
    include CompatibilityStrategy
    SCOPED = %w[groups rematches sub_rules rules].freeze
    RESOLUTIONS = %w[rematches group_modes abandon_sub_rules omit_dns omit_mihomo_policy disable_rules].freeze
    GROUP_MODES = {
      'mihomo'=>{'manual'=>'select', 'url-test'=>'url-test', 'fallback'=>'fallback'},
      'surge'=>{'manual'=>'select', 'url-test'=>'url-test', 'fallback'=>'fallback'},
      'shadowrocket'=>{'manual'=>'select', 'url-test'=>'url-test', 'fallback'=>'fallback'},
      'singbox'=>{'manual'=>'selector', 'url-test'=>'urltest'}
    }.freeze
    GROUP_EXPLANATIONS = {
      'manual'=>'manual selection does not automatically switch candidates or preserve Smart behavior',
      'url-test'=>'latency testing selects by measured delay; it does not preserve Smart or regional matching behavior',
      'fallback'=>'fallback selects the first available candidate in order; it does not preserve Smart behavior'
    }.freeze
    SUGGESTION_REASONS = {
      'smart'=>'Latency testing is a simpler alternative to Smart selection; it does not preserve Smart decisions.',
      'manual'=>'Use manual selection to match the source group mode; automatic switching will stop.',
      'url-test'=>'Use the target client latency testing; client timing and selection behavior may differ.',
      'fallback'=>'Ordered fallback keeps priority-based availability selection; native client behavior may still differ.',
      'fallback-loss'=>'This target has no native fallback mode; latency testing loses ordered failover priority.',
      'load-balance'=>'Latency testing selects by delay and does not preserve load balancing.',
      'unknown'=>'No suggestion is available because the Mihomo group mode is unknown.',
      'unchanged'=>'The target already uses this alternative; its remaining behavior difference still requires review.',
      'candidates'=>'Candidates come from enabled scoped rules and final policies in their original order. Manual selection does not preserve rule conditions, REMATCH-NAME matching, or regional re-evaluation; the first candidate becomes the initial selection.',
      'builtins'=>'A scoped policy includes DIRECT or REJECT; review these routing decisions manually instead of inferring candidates.',
      'missing'=>'A rematch, sub-rule, or candidate policy reference is missing or ambiguous; choose candidates manually.',
      'cycle'=>'The policy graph contains a cycle or a candidate depends on this rematch; choose candidates manually.',
      'depth'=>'The policy graph exceeds the suggestion depth limit; choose candidates manually.',
      'conditions'=>'Scoped rules contain unsupported or malformed conditions; choose candidates manually.'
    }.freeze

    def initialize(config, caches)
      @config, @caches = Engine.copy(config), Engine.copy(caches)
    end

    def profile(id)
      @config.fetch('profiles').find { |p| p['id'] == id } || (raise Error, 'Subscription profile does not exist')
    end

    def rows(key, id)
      Array(@config[key]).select { |row| row['profile'] == id }
    end

    def group_type(group, format)
      group.fetch(format + '_type', format == 'singbox' ? 'selector' : 'select')
    end

    def group_behavior(type)
      {'select'=>'manual', 'selector'=>'manual', 'urltest'=>'url-test'}.fetch(type, type)
    end

    def group_explanation(mode, format)
      text = GROUP_EXPLANATIONS.fetch(mode)
      text += '; sing-box manual selection requires client selection controls or its API; otherwise the first candidate is used' if mode == 'manual' && format == 'singbox'
      text
    end

    def policy_label(id, profile_id)
      group = rows('groups', profile_id).find { |row| row['id'] == id }
      group ? "#{group['name']} (#{id})" : id
    end

    def group_suggestion(group, format)
      native = group_type(group, 'mihomo')
      return {'available'=>false, 'reason'=>SUGGESTION_REASONS['unknown']} unless %w[select url-test fallback load-balance smart].include?(native)
      baseline = group_behavior(native)
      mode, reason = case baseline
                     when 'smart', 'load-balance' then ['url-test', baseline]
                     when 'manual', 'url-test' then [baseline, baseline]
                     when 'fallback' then GROUP_MODES[format].key?('fallback') ? ['fallback', 'fallback'] : ['url-test', 'fallback-loss']
                     else return {'available'=>false, 'reason'=>SUGGESTION_REASONS['unknown']}
                     end
      return {'available'=>false, 'reason'=>SUGGESTION_REASONS['unchanged']} if group_type(group, format) == GROUP_MODES[format][mode]
      {'available'=>true, 'mode'=>mode, 'reason'=>SUGGESTION_REASONS[reason]}
    end

    def rematch_suggestion(profile_id, original)
      maps = %w[groups rematches sub_rules].to_h do |key|
        items = rows(key, profile_id)
        map = items.to_h { |row| [row['id'], row] }
        raise Error, SUGGESTION_REASONS['missing'] unless items.length == map.length
        [key, map]
      end
      raise Error, SUGGESTION_REASONS['missing'] unless (maps['groups'].keys & maps['rematches'].keys).empty?
      scoped = rows('rules', profile_id).reject { |rule| rule['enabled'] == false }.group_by { |rule| rule['sub_rule'] }
      scopes = {}
      scope_policies = lambda do |id|
        scopes[id] ||= begin
          rematch = maps['rematches'][id]
          sub = rematch && maps['sub_rules'][rematch['target_sub_rule']]
          raise Error, SUGGESTION_REASONS['missing'] unless sub
          rules = scoped.fetch(sub['id'], [])
          rules.each do |rule|
            begin
              valid = conditions(rule).all? { |condition| Engine::RULE_TYPES.include?(condition['type']) && Array(condition['conditions']).all? { |child| child.is_a?(Hash) } }
            rescue Error
              valid = false
            end
            raise Error, SUGGESTION_REASONS['conditions'] unless valid
          end
          rules.map { |rule| rule['policy'] } + [sub['final_policy']]
        end
      end
      resolved = {}
      resolve = lambda do |policy, trail|
        raise Error, SUGGESTION_REASONS['depth'] if trail.length >= 16
        raise Error, SUGGESTION_REASONS['builtins'] if Engine::BUILTINS.include?(policy)
        next [policy] if maps['groups'].key?(policy)
        raise Error, SUGGESTION_REASONS['missing'] unless maps['rematches'].key?(policy)
        raise Error, SUGGESTION_REASONS['cycle'] if trail.include?(policy)
        resolved[policy] ||= scope_policies.call(policy).flat_map { |child| resolve.call(child, trail + [policy]) }.uniq
      end
      candidates = resolve.call(original['id'], [])
      checked = {}
      check = lambda do |policy, trail|
        raise Error, SUGGESTION_REASONS['depth'] if trail.length >= 16
        next if Engine::BUILTINS.include?(policy)
        raise Error, SUGGESTION_REASONS['cycle'] if policy == original['id'] || trail.include?(policy)
        next if checked[policy]
        group = maps['groups'][policy]
        edges = if group
                  raise Error, SUGGESTION_REASONS['missing'] unless group.fetch('members', []).is_a?(Array)
                  Array(group['members']) + %w[default_member empty_fallback].map { |key| group[key] }.compact.reject { |id| id == '' }
                elsif maps['rematches'].key?(policy)
                  scope_policies.call(policy)
                else
                  raise Error, SUGGESTION_REASONS['missing']
                end
        edges.each { |child| check.call(child, trail + [policy]) }
        checked[policy] = true
      end
      candidates.each { |candidate| check.call(candidate, []) }
      {'available'=>true, 'mode'=>'manual', 'members'=>candidates, 'reason'=>SUGGESTION_REASONS['candidates']}
    rescue Error => e
      {'available'=>false, 'reason'=>e.message}
    end

    def conditions(rule, depth = 0)
      raise Error, 'Condition nesting exceeds 8 levels' if depth > 8
      return [] unless rule.is_a?(Hash)
      [rule] + Array(rule['conditions']).flat_map { |child| conditions(child, depth + 1) }
    end

    def rule_issues(rule, format)
      return [] if format == 'mihomo'
      conditions(rule).flat_map do |condition|
        type = condition['type']
        problems = []
        problems << "#{type} requires a native replacement rule" if %w[GEOSITE REMATCH-NAME].include?(type)
        problems << 'sing-box requires a native rule set instead of GEOIP' if format == 'singbox' && type == 'GEOIP' && condition['value'].to_s.upcase != 'LAN'
        problems << 'sing-box cannot preserve no-resolve semantics' if format == 'singbox' && condition['no_resolve']
        if type == 'RULE-SET'
          set = Array(@config['rule_sets']).find { |item| item['id'] == condition['value'] }
          if set && set.fetch('source_type', 'remote') != 'inline' && set[format + '_url'].to_s.empty?
            problems << "Rule set #{set['id']} needs a #{format} URL"
          elsif set && set['source_type'] == 'inline'
            set['inline_rules'].to_s.lines.map(&:strip).reject { |line| line.empty? || line.start_with?('#', '//') }.each do |line|
              leaf_type, value, option = line.split(',', -1)
              problems << 'sing-box inline rule sets require explicit IP-CIDR ranges instead of GEOIP LAN' if format == 'singbox' && leaf_type == 'GEOIP' && value.to_s.upcase == 'LAN'
              problems.concat(rule_issues({'type'=>leaf_type, 'value'=>value, 'no_resolve'=>option == 'no-resolve'}, format)) unless leaf_type == 'RULE-SET'
            end
          end
        end
        problems
      end.uniq
    end

    def target(id, format)
      draft = Engine.copy(@config)
      draft['profiles'].find { |p| p['id'] == id }['formats'] = [format]
      validation = Engine.new(draft, @caches).validate(id)
      p = profile(id)
      issues = []
      rows('groups', id).each do |group|
        current, baseline = group_type(group, format), group_type(group, 'mihomo')
        supported = case format
                    when 'singbox' then %w[selector urltest]
                    when 'shadowrocket' then %w[select url-test fallback load-balance]
                    else %w[select url-test fallback load-balance smart]
                    end
        if !supported.include?(current)
          message = format == 'shadowrocket' ? "Group #{group['name']}: this exporter has no verified Shadowrocket mapping for mode #{current}; explicitly choose a manual or simpler automatic alternative" : "Group #{group['name']}: #{format} does not support #{current}; explicitly choose a manual or simpler automatic alternative"
          issues << issue('group', group, message, 'group_modes')
        elsif format == 'mihomo' && current == 'smart' && p['mihomo_core'] != 'smart'
          issues << issue('group', group, "Group #{group['name']}: Smart requires the Mihomo Smart core; a manual or simpler automatic mode is an alternative, not equivalent behavior", 'group_modes')
        elsif format != 'mihomo' && (group_behavior(current) != group_behavior(baseline) || baseline == 'smart')
          issues << issue('group', group, "Group #{group['name']}: #{format} mode #{current} differs from or cannot guarantee Mihomo #{baseline} behavior; review a manual or simpler automatic alternative", 'group_modes', 'warning')
        end
      end
      if format != 'mihomo'
        rows('rematches', id).each do |item|
          issues << issue('rematch', item, 'Rematch routing needs an explicit replacement policy', 'rematches')
        end
        rows('sub_rules', id).each do |item|
          issues << issue('sub_rules', item, 'Mihomo sub-rules require explicit removal or a manual native replacement', 'abandon_sub_rules')
        end
        issues << issue('dns', p, 'Native Mihomo DNS policy cannot be preserved; explicitly choose the target client DNS defaults', 'omit_dns') if p['mihomo_dns'].is_a?(Hash) && !p['mihomo_dns'].empty?
        issues << issue('runtime_policy', p, 'Native Mihomo runtime and geodata settings are omitted by this target', 'omit_mihomo_policy', 'warning') if p['mihomo_policy'].is_a?(Hash) && !p['mihomo_policy'].empty?
        rows('rules', id).reject { |r| r['enabled'] == false }.each do |rule|
          problems = rule_issues(rule, format)
          issues << issue('rule', rule, problems.join('; '), 'disable_rules') unless problems.empty?
        end
      end
      issues.select { |item| item['kind'] == 'group' && item['severity'] == 'warning' }.each do |item|
        next if validation['warnings'].any? { |warning| warning['code'] == "#{format}:#{item['code']}" }
        validation['warnings'] << {'code'=>"#{format}:#{item['code']}", 'message'=>item['message'], 'target'=>format}
      end
      validation.merge('format'=>format, 'issues'=>issues, 'compatible'=>validation['errors'].empty?)
    end

    def issue(kind, item, message, resolution, severity = 'error')
      {'code'=>"#{kind}:#{item['id']}", 'kind'=>kind, 'id'=>item['id'], 'name'=>item['name'] || item['id'], 'severity'=>severity, 'message'=>message, 'resolution'=>resolution}
    end

    def report(id, review: false)
      strategy = strategy_status(id, details: true)
      if review && strategy && !strategy['source_missing']
        return report(strategy['source_profile']).merge('strategy'=>strategy)
      end
      p = profile(id)
      targets = Engine::FORMATS.map { |format| target(id, format) }
      affected_groups = Hash.new { |groups, key| groups[key] = [] }
      targets.each do |target|
        target['issues'].select { |item| item['kind'] == 'group' }.each { |item| affected_groups[item['id']] << target['format'] }
      end
      {'profile'=>{'id'=>id, 'name'=>p['name']}, 'targets'=>targets, 'strategy'=>strategy,
       'derived_profiles'=>@config['profiles'].select { |row| row['compatibility'].is_a?(Hash) && row['compatibility']['source_profile'] == id }.map { |row| strategy_status(row['id']) }.compact,
       'choices'=>{
         'policies'=>Engine::BUILTINS.map { |value| {'id'=>value, 'name'=>value} } + rows('groups', id).map { |g| g.slice('id', 'name') },
         'groups'=>rows('groups', id).map do |group|
           group.slice('id', 'name').merge('modes'=>Engine::FORMATS.to_h { |format| [format, group_type(group, format)] }, 'alternatives'=>GROUP_MODES.transform_values(&:keys), 'suggestions'=>affected_groups[group['id']].to_h { |format| [format, group_suggestion(group, format)] })
         end,
         'rematches'=>rows('rematches', id).map do |rematch|
           suggestion = rematch_suggestion(id, rematch)
           rematch.slice('id', 'name').merge('suggestions'=>(Engine::FORMATS - ['mihomo']).to_h { |format| [format, Engine.copy(suggestion)] })
         end,
         'sub_rules'=>rows('sub_rules', id).map { |r| r.slice('id', 'name').merge('rules'=>rows('rules', id).count { |rule| rule['sub_rule'] == r['id'] && rule['enabled'] != false }) },
         'has_dns'=>p['mihomo_dns'].is_a?(Hash) && !p['mihomo_dns'].empty?,
         'has_mihomo_policy'=>p['mihomo_policy'].is_a?(Hash) && !p['mihomo_policy'].empty?,
         'rules'=>rows('rules', id).reject { |r| r['enabled'] == false }.map { |r| {'id'=>r['id'], 'name'=>r['name'] || r['id'], 'type'=>r['type'], 'sub_rule'=>r['sub_rule'].to_s, 'targets'=>(Engine::FORMATS - ['mihomo']).select { |format| !rule_issues(r, format).empty? }} }
       }}
    end

    def resolutions(value, id, format)
      value = JSON.parse(value) if value.is_a?(String)
      value ||= {}
      raise Error, 'Compatibility resolutions must be an object' unless value.is_a?(Hash) && (value.keys - RESOLUTIONS).empty?
      %w[abandon_sub_rules omit_dns omit_mihomo_policy].each do |key|
        raise Error, "Compatibility #{key} must be boolean" if value.key?(key) && ![true, false].include?(value[key])
      end
      mappings = value.fetch('rematches', {})
      allowed = rows('groups', id).map { |r| r['id'] } + Engine::BUILTINS
      rematches = rows('rematches', id).map { |r| r['id'] }
      raise Error, 'Choose an existing rematch for every replacement' unless mappings.is_a?(Hash) && (mappings.keys - rematches).empty?
      mappings.each_value do |policy|
        if policy.is_a?(Hash)
          members = policy['members']
          raise Error, 'A rematch alternative requires manual or url-test mode and explicit unique candidate policies' unless (policy.keys - %w[mode members]).empty? && %w[manual url-test].include?(policy['mode']) && members.is_a?(Array) && !members.empty? && members.uniq == members && (members - allowed).empty?
        else
          raise Error, 'Choose an existing group, DIRECT or REJECT for every rematch replacement' unless allowed.include?(policy)
        end
      end
      modes = value.fetch('group_modes', {})
      group_ids = rows('groups', id).map { |row| row['id'] }
      raise Error, 'Choose an existing group and a supported alternative mode for this target' unless modes.is_a?(Hash) && modes.all? { |group, mode| group_ids.include?(group) && (mode == 'keep' || GROUP_MODES[format].key?(mode)) }
      disabled = value.fetch('disable_rules', [])
      rule_ids = rows('rules', id).select { |r| r['enabled'] != false }.map { |r| r['id'] }
      raise Error, 'Choose existing enabled rules to disable' unless disabled.is_a?(Array) && disabled.uniq == disabled && (disabled - rule_ids).empty?
      if format == 'mihomo' && (mappings.any? || disabled.any? || value.values.include?(true))
        raise Error, 'Mihomo copies preserve native policies; compatibility removals are only for other targets'
      end
      value
    rescue JSON::ParserError
      raise Error, 'Invalid compatibility resolutions JSON'
    end

    def copy_id(id, key, original)
      "#{id[0, 23]}-#{key[0]}-#{Digest::SHA256.hexdigest([id, key, original].join(':'))[0, 20]}"
    end

    def remap_condition(rule, set_map)
      rule['value'] = set_map.fetch(rule['value'], rule['value']) if rule['type'] == 'RULE-SET'
      Array(rule['conditions']).each { |child| remap_condition(child, set_map) }
    end

    def remap_dns(value, set_map)
      case value
      when Hash then value.each_with_object({}) { |(key, child), out| out[remap_dns(key, set_map)] = remap_dns(child, set_map) }
      when Array then value.map { |child| remap_dns(child, set_map) }
      when String
        value.start_with?('rule-set:') ? 'rule-set:' + value.delete_prefix('rule-set:').split(',').map { |id| set_map.fetch(id, id) }.join(',') : value
      else value
      end
    end

    def plan(args)
      old_id, new_id, format = args.values_at('profile', 'id', 'format')
      original = profile(old_id)
      operation = args.fetch('operation', 'create')
      raise Error, 'Invalid compatibility operation' unless %w[create reapply].include?(operation)
      raise Error, 'Invalid export format' unless Engine::FORMATS.include?(format)
      raise Error, 'Invalid identifier' unless new_id.is_a?(String) && Engine::ID.match?(new_id)
      check_ancestry(old_id, new_id)
      raise Error, 'An independent profile requires a new unused identifier' if operation == 'create' && @config['profiles'].any? { |p| p['id'] == new_id }
      draft = Engine.copy(@config)
      name = args['name']
      old_sets = []
      name, old_sets = prepare_reapply(draft, new_id, old_id, format) if operation == 'reapply'
      raise Error, 'Profile name must contain 1–256 characters without control characters' unless name.is_a?(String) && !name.strip.empty? && name.length <= 256 && !name.match?(/[\x00-\x1f\x7f]/)
      choices = resolutions(args['resolutions'], old_id, format)
      changes = if operation == 'reapply'
                  [{'code'=>'update-profile', 'message'=>"Update compatible draft #{name} (#{new_id}) from its saved source; preserve published releases and download links"}]
                else
                  [{'code'=>'create-profile', 'message'=>"Create independent #{format} profile #{name} (#{new_id}); preserve the original profile and its export formats"}]
                end
      if operation == 'reapply' && strategy_status(new_id)['target_changed']
        changes << {'code'=>'replace-target', 'message'=>'The compatible draft was edited independently; replace its current contents with this reviewed conversion plan'}
      end
      cloned = {}
      maps = {}
      SCOPED.each do |key|
        maps[key] = {}
        cloned[key] = rows(key, old_id).map do |row|
          copy = Engine.copy(row)
          copy['profile'], copy['id'] = new_id, copy_id(new_id, key, row['id'])
          raise Error, 'Generated compatibility identifier already exists; choose another profile identifier' if Array(draft[key]).any? { |existing| existing['id'] == copy['id'] }
          maps[key][row['id']] = copy['id']
          copy
        end
      end
      policy_map = maps['groups'].merge(maps['rematches'])
      choices.fetch('rematches', {}).each do |rematch, fallback|
        if fallback.is_a?(Hash)
          original_rematch = rows('rematches', old_id).find { |row| row['id'] == rematch }
          group_id = copy_id(new_id, 'rematch_groups', rematch)
          if (Array(draft['groups']) + Array(draft['rematches']) + cloned['groups'] + cloned['rematches']).any? { |row| row['id'] == group_id }
            raise Error, 'Generated compatibility identifier already exists; choose another profile identifier'
          end
          group = {'id'=>group_id, 'profile'=>new_id, 'name'=>original_rematch['name'], 'sources'=>[], 'members'=>fallback['members'], 'url'=>'https://www.gstatic.com/generate_204', 'interval'=>300, 'tolerance'=>50}
          GROUP_MODES.each { |target, modes| group[target + '_type'] = modes[fallback['mode']] }
          cloned['groups'] << group
          policy_map[rematch] = group_id
          candidates = fallback['members'].map { |member| policy_label(member, old_id) }.join(', ')
          changes << {'code'=>"replace-rematch:#{rematch}", 'message'=>"Replace rematch #{original_rematch['name']} (#{rematch}) with #{fallback['mode']} group; candidates: #{candidates}; #{group_explanation(fallback['mode'], format)}; regional re-evaluation is no longer performed in the new profile"}
        else
          policy_map[rematch] = policy_map.fetch(fallback, fallback)
          changes << {'code'=>"replace-rematch:#{rematch}", 'message'=>"Replace rematch #{rematch} with policy #{fallback}; regional re-evaluation is no longer performed in the new profile"}
        end
        cloned['rematches'].reject! { |row| row['id'] == maps['rematches'][rematch] }
      end
      choices.fetch('group_modes', {}).each do |id, mode|
        next if mode == 'keep'
        group = cloned['groups'].find { |row| row['id'] == maps['groups'][id] }
        before, baseline = group_type(group, format), group_type(group, 'mihomo')
        group[format + '_type'] = GROUP_MODES[format][mode]
        changes << {'code'=>"group-mode:#{id}", 'message'=>"Change group #{group['name']} (#{id}) for #{format}: #{before} -> #{group[format + '_type']} (Mihomo reference: #{baseline}); #{group_explanation(mode, format)}"}
      end
      if choices['abandon_sub_rules']
        rows('sub_rules', old_id).each do |sub|
          count = rows('rules', old_id).count { |rule| rule['sub_rule'] == sub['id'] }
          changes << {'code'=>"omit-subrule:#{sub['id']}", 'message'=>"Omit sub-rule #{sub['name']} (#{sub['id']}) and its #{count} scoped rules from the new profile"}
        end
        rows('rules', old_id).reject { |rule| rule['sub_rule'].to_s.empty? }.each do |rule|
          changes << {'code'=>"omit-rule:#{rule['id']}", 'message'=>"Omit scoped rule #{rule['name'] || rule['id']} (#{rule['id']}, #{rule['type']}) from sub-rule #{rule['sub_rule']} in the new profile"}
        end
        cloned['sub_rules'] = []
        cloned['rules'].reject! { |rule| !rule['sub_rule'].to_s.empty? }
      end
      choices.fetch('disable_rules', []).each do |id|
        rule = cloned['rules'].find { |row| row['id'] == maps['rules'][id] }
        next unless rule
        rule['enabled'] = false
        changes << {'code'=>"disable-rule:#{id}", 'message'=>"Disable rule #{id} (#{rule['type']}) in the new profile; matching traffic will follow later rules or the final policy"}
      end
      copy = Engine.copy(without_strategy(original)).merge('id'=>new_id, 'name'=>name, 'formats'=>[format])
      copy['final_policy'] = policy_map.fetch(copy['final_policy'], copy['final_policy'])
      %w[dns mihomo_policy].each do |key|
        field = key == 'dns' ? 'mihomo_dns' : key
        next unless choices['omit_' + key] && copy[field] && !copy[field].empty?
        copy.delete(field)
        changes << {'code'=>'omit-' + field, 'message'=>key == 'dns' ? 'Omit all native Mihomo DNS policy; the target client will use its generated system/local DNS defaults' : 'Omit native Mihomo runtime and geodata policy from the new profile'}
      end
      cloned['groups'].each do |group|
        group['members'] = Array(group['members']).map { |member| policy_map.fetch(member, member) }.uniq
        %w[default_member empty_fallback].each { |key| group[key] = policy_map.fetch(group[key], group[key]) if group.key?(key) }
      end
      cloned['rematches'].each { |row| row['target_sub_rule'] = maps['sub_rules'].fetch(row['target_sub_rule'], row['target_sub_rule']) }
      cloned['sub_rules'].each { |row| row['final_policy'] = policy_map.fetch(row['final_policy'], row['final_policy']) }
      cloned['rules'].each do |row|
        row['policy'] = policy_map.fetch(row['policy'], row['policy'])
        row['sub_rule'] = maps['sub_rules'].fetch(row['sub_rule'], row['sub_rule']) unless row['sub_rule'].to_s.empty?
      end
      # Shared sets remain shared unless their download policy refers to a copied group.
      set_map = {}
      used = cloned['rules'].flat_map { |r| conditions(r).select { |v| v['type'] == 'RULE-SET' }.map { |v| v['value'] } }
      dns = copy['mihomo_dns'] || {}
      used.concat((Array(dns['fake-ip-filter']) + %w[nameserver-policy proxy-server-nameserver-policy].flat_map { |key| (dns[key] || {}).keys }).grep(/^rule-set:/).flat_map { |v| v.delete_prefix('rule-set:').split(',') })
      Array(@config['rule_sets']).each do |set|
        next unless used.include?(set['id']) && policy_map.key?(set['mihomo_proxy'])
        replacement = Engine.copy(set)
        replacement['id'] = copy_id(new_id, 'rule_sets', set['id'])
        raise Error, 'Generated rule set identifier already exists; choose another profile identifier' if draft['rule_sets'].any? { |existing| existing['id'] == replacement['id'] }
        replacement['mihomo_proxy'] = policy_map[set['mihomo_proxy']]
        draft['rule_sets'] << replacement
        set_map[set['id']] = replacement['id']
        changes << {'code'=>"copy-ruleset:#{set['id']}", 'message'=>"Copy rule set #{set['id']} to preserve its reference to the independent profile's download policy"}
      end
      cloned['rules'].each { |rule| remap_condition(rule, set_map) }
      copy['mihomo_dns'] = remap_dns(copy['mihomo_dns'], set_map) if copy['mihomo_dns']
      draft['profiles'] << copy
      SCOPED.each { |key| draft[key] ||= []; draft[key].concat(cloned[key]) }
      planned = self.class.new(draft, @caches)
      new_sets = set_map.values
      changes.concat(target_changes(owned_state(new_id, old_sets), planned.owned_state(new_id, new_sets))) if operation == 'reapply'
      copy['compatibility'] = {'schema'=>1, 'source_profile'=>old_id, 'format'=>format, 'resolutions'=>Engine.copy(choices), 'source_digest'=>source_fingerprint(old_id), 'target_digest'=>fingerprint(planned.owned_state(new_id, new_sets)), 'decision_digests'=>decision_fingerprints(old_id, choices), 'managed_rule_sets'=>new_sets}
      raise Error, 'Configuration exceeds the 2 MiB size limit' if JSON.generate(draft).bytesize > Engine::MAX_INPUT
      %w[profiles groups rematches sub_rules rules rule_sets].each { |key| raise Error, "#{key} exceeds the 5000 item limit" if draft[key].length > 5000 }
      validation = Engine.new(draft, @caches).validate(new_id)
      if format == 'singbox'
        manual = choices.fetch('group_modes', {}).select { |_, mode| mode == 'manual' }.map { |id, _| ["group:#{id}", policy_label(id, old_id)] }
        choices.fetch('rematches', {}).each do |id, alternative|
          next unless alternative.is_a?(Hash) && alternative['mode'] == 'manual'
          manual << ["rematch:#{id}", rows('rematches', old_id).find { |row| row['id'] == id }['name']]
        end
        manual.each do |id, name|
          validation['warnings'] << {'code'=>"singbox:manual-controls:#{id}", 'message'=>"#{name}: sing-box manual selection requires client selection controls or its API; otherwise the first candidate is used", 'target'=>'singbox'}
        end
      end
      changes.each { |change| change['message'] = change['message'].gsub('new profile', 'compatible draft') } if operation == 'reapply'
      output = validation.merge('profile'=>new_id, 'format'=>format, 'operation'=>operation, 'updated_target'=>operation == 'reapply', 'changes'=>changes, 'ready'=>validation['errors'].empty?)
      output['plan_token'] = Digest::SHA256.hexdigest(JSON.generate([@config, @caches.transform_values { |value| value['nodes'] }, draft, changes]))
      [draft, output]
    end
  end
end
