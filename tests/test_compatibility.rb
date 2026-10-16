require 'minitest/autorun'
require 'tmpdir'
require_relative '../root/usr/share/hybrid-subscription/backend'

class CompatibilityTest < Minitest::Test
  class Adapter
    def status; {'installed'=>false}; end
  end

  def setup
    @tmp = Dir.mktmpdir
    @backend = HybridSubscription::Backend.new(File.join(@tmp, 'data'), File.join(@tmp, 'run'), adapter:Adapter.new)
    @config = @backend.blank_config
    @config['sources'] = [{'id'=>'source', 'name'=>'Provider', 'enabled'=>true, 'url'=>'https://provider.invalid/subscription?token=private-url-token'}]
    @config['profiles'] = [{'id'=>'main', 'name'=>'Main', 'sources'=>['source'], 'formats'=>['mihomo'], 'final_policy'=>'proxy', 'mihomo_core'=>'smart'}]
    @config['groups'] = [{'id'=>'proxy', 'profile'=>'main', 'name'=>'Proxy', 'sources'=>['source'], 'members'=>[], 'mihomo_type'=>'select', 'surge_type'=>'select', 'singbox_type'=>'selector'}]
    @config['rules'] = [{'id'=>'domain', 'profile'=>'main', 'enabled'=>true, 'type'=>'DOMAIN-SUFFIX', 'value'=>'example.test', 'policy'=>'proxy'}]
    save
    @node = {'name'=>'Node', 'type'=>'trojan', 'server'=>'secret-server.invalid', 'port'=>443, 'password'=>'private-node-password', 'sni'=>'edge.invalid'}
    @backend.put_source('source', YAML.dump('proxies'=>[@node]), 'mihomo')
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def save
    @backend.save_config('config'=>JSON.generate(@config), 'version'=>@backend.version)
    @config = @backend.config
  end

  def args(format = 'surge', resolutions = {})
    {'profile'=>'main', 'format'=>format, 'id'=>'compatible', 'name'=>'Compatible', 'resolutions'=>JSON.generate(resolutions)}
  end

  def preview(request = args)
    @backend.compatibility_plan(request)
  end

  def create(request = args, plan = preview(request))
    @backend.compatibility_plan(request.merge('version'=>plan['version'], 'plan_token'=>plan['plan_token'], 'accepted_changes'=>plan['changes'].map { |change| change['code'] }), create:true)
  end

  def native_graph
    @config['profiles'][0]['final_policy'] = 'follow'
    @config['profiles'][0]['mihomo_dns'] = {'enable'=>true, 'nameserver'=>['https://resolver.invalid/dns-query?token=private-dns-token']}
    @config['rematches'] = [{'id'=>'follow', 'profile'=>'main', 'name'=>'Follow region', 'target_sub_rule'=>'region', 'rematch_name'=>'Provider'}]
    @config['sub_rules'] = [{'id'=>'region', 'profile'=>'main', 'name'=>'Region selection', 'final_policy'=>'proxy'}]
    @config['rules'] << {'id'=>'regional', 'profile'=>'main', 'sub_rule'=>'region', 'type'=>'REMATCH-NAME', 'value'=>'Provider', 'policy'=>'proxy'}
    @config['rules'] << {'id'=>'geosite', 'profile'=>'main', 'type'=>'GEOSITE', 'value'=>'cn', 'policy'=>'DIRECT'}
    save
  end

  def test_report_checks_all_targets_independently_of_selected_formats
    native_graph
    report = @backend.compatibility('profile'=>'main')
    assert_equal @backend.version, report['version']
    assert_equal %w[mihomo surge singbox], report['targets'].map { |item| item['format'] }
    assert_empty report['targets'][0]['errors']
    assert_equal 1, report['targets'][0]['summary']['nodes']
    report['targets'][1..].each do |item|
      refute_empty item['errors']
      assert_includes item['issues'].map { |issue| issue['kind'] }, 'rematch'
      assert_includes item['issues'].map { |issue| issue['kind'] }, 'dns'
    end
    choices = report['choices']
    assert_equal %w[surge singbox], choices['rules'].find { |rule| rule['id'] == 'geosite' }['targets']
    assert_equal 1, choices['sub_rules'][0]['rules']
    assert_equal %w[DIRECT REJECT proxy], choices['policies'].map { |policy| policy['id'] }
    %w[private-url-token private-node-password secret-server.invalid private-dns-token].each { |secret| refute_includes JSON.generate(report), secret }
  end

  def test_preview_never_writes_and_default_choices_never_discard_policy
    native_graph
    before = @backend.config
    cache = @backend.caches
    plan = preview
    refute plan['ready']
    assert_equal ['create-profile'], plan['changes'].map { |change| change['code'] }
    assert_equal before, @backend.config
    assert_equal cache, @backend.caches
    assert_raises(HybridSubscription::Error) { create(args, plan) }
    assert_empty @backend.releases
    assert_empty @backend.published
  end

  def test_explicit_adaptations_create_valid_independent_profile_without_mutating_source
    native_graph
    before = @backend.config
    cache = @backend.caches
    request = args('surge', 'rematches'=>{'follow'=>'proxy'}, 'abandon_sub_rules'=>true, 'omit_dns'=>true, 'disable_rules'=>['geosite'])
    plan = preview(request)
    assert plan['ready'], plan['errors'].inspect
    assert_includes plan['changes'].map { |change| change['code'] }, 'replace-rematch:follow'
    assert_includes plan['changes'].map { |change| change['code'] }, 'omit-rule:regional'
    assert_match(/1 scoped rules/, plan['changes'].find { |change| change['code'] == 'omit-subrule:region' }['message'])
    result = create(request, plan)
    assert result['created']
    current = @backend.config
    assert_equal before['profiles'][0], current['profiles'][0]
    %w[groups rules rematches sub_rules].each do |key|
      assert_equal before[key], current[key].select { |row| row['profile'] == 'main' }
    end
    copy = current['profiles'].find { |p| p['id'] == 'compatible' }
    assert_equal ['surge'], copy['formats']
    assert_equal ['source'], copy['sources']
    refute copy.key?('mihomo_dns')
    groups = current['groups'].select { |row| row['profile'] == 'compatible' }
    assert_equal groups[0]['id'], copy['final_policy']
    rules = current['rules'].select { |row| row['profile'] == 'compatible' }
    assert_equal groups[0]['id'], rules.find { |rule| rule['type'] == 'DOMAIN-SUFFIX' }['policy']
    assert_equal false, rules.find { |rule| rule['type'] == 'GEOSITE' }['enabled']
    assert_empty @backend.engine.validate('compatible')['errors']
    assert_equal cache, @backend.caches
    assert_empty @backend.releases
    assert_empty @backend.published
  end

  def test_native_copy_remaps_every_profile_owned_reference
    native_graph
    @config['groups'][0].merge!('members'=>['follow'], 'default_member'=>'follow', 'empty_fallback'=>'DIRECT')
    @config['sub_rules'][0]['final_policy'] = 'DIRECT'
    @config['rules'].find { |rule| rule['id'] == 'regional' }['policy'] = 'DIRECT'
    save
    request = args('mihomo')
    plan = preview(request)
    assert plan['ready'], plan['errors'].inspect
    create(request, plan)
    current = @backend.config
    group = current['groups'].find { |row| row['profile'] == 'compatible' }
    rematch = current['rematches'].find { |row| row['profile'] == 'compatible' }
    scope = current['sub_rules'].find { |row| row['profile'] == 'compatible' }
    rule = current['rules'].find { |row| row['profile'] == 'compatible' && row['type'] == 'REMATCH-NAME' }
    assert_equal [rematch['id']], group['members']
    assert_equal rematch['id'], group['default_member']
    assert_equal scope['id'], rematch['target_sub_rule']
    assert_equal scope['id'], rule['sub_rule']
    assert_equal rematch['id'], current['profiles'].last['final_policy']
    assert_empty @backend.engine.validate('compatible')['errors']
  end

  def test_profile_dependent_rule_sets_are_copied_and_shared_sets_reused
    @config['rule_sets'] = [
      {'id'=>'shared', 'source_type'=>'inline', 'behavior'=>'classical', 'inline_rules'=>'DOMAIN,shared.test'},
      {'id'=>'bound', 'source_type'=>'remote', 'behavior'=>'domain', 'mihomo_url'=>'https://rules.invalid/bound', 'surge_url'=>'https://rules.invalid/surge', 'mihomo_proxy'=>'proxy'}
    ]
    @config['profiles'][0]['mihomo_dns'] = {'nameserver-policy'=>{'rule-set:bound,shared'=>'system'}, 'fake-ip-filter'=>['rule-set:bound']}
    @config['rules'] << {'id'=>'sets', 'profile'=>'main', 'type'=>'AND', 'conditions'=>[{'type'=>'RULE-SET', 'value'=>'bound'}, {'type'=>'RULE-SET', 'value'=>'shared'}], 'policy'=>'proxy'}
    save
    request = args('mihomo')
    plan = preview(request)
    assert plan['ready'], plan['errors'].inspect
    create(request, plan)
    current = @backend.config
    assert_equal 3, current['rule_sets'].length
    cloned = current['rule_sets'].last
    assert_equal current['groups'].last['id'], cloned['mihomo_proxy']
    rule = current['rules'].find { |row| row['profile'] == 'compatible' && row['type'] == 'AND' }
    assert_equal [cloned['id'], 'shared'], rule['conditions'].map { |condition| condition['value'] }
    dns = current['profiles'].last['mihomo_dns']
    assert_equal ["rule-set:#{cloned['id']},shared"], dns['nameserver-policy'].keys
    assert_equal ["rule-set:#{cloned['id']}"], dns['fake-ip-filter']
    assert_empty @backend.engine.validate('main')['errors']
    assert_empty @backend.engine.validate('compatible')['errors']
  end

  def test_stale_configuration_and_node_cache_changes_cannot_apply_old_plan
    request = args
    plan = preview(request)
    @config['profiles'][0]['name'] = 'Changed'
    save
    assert_match(/another session/, assert_raises(HybridSubscription::Error) { create(request, plan) }.message)
    plan = preview(request)
    @backend.put_source('source', YAML.dump('proxies'=>[@node.merge('name'=>'New node')]), 'mihomo')
    assert_match(/plan changed/, assert_raises(HybridSubscription::Error) { create(request, plan) }.message)
    assert_equal 1, @backend.config['profiles'].length
  end

  def test_changed_choices_need_new_plan_and_each_change_needs_exact_confirmation
    native_graph
    request = args('surge', 'rematches'=>{'follow'=>'DIRECT'}, 'abandon_sub_rules'=>true, 'omit_dns'=>true, 'disable_rules'=>['geosite'])
    plan = preview(request)
    valid = request.merge('version'=>plan['version'], 'plan_token'=>plan['plan_token'], 'accepted_changes'=>plan['changes'].map { |change| change['code'] })
    [[], valid['accepted_changes'] + ['unexpected'], valid['accepted_changes'] + [valid['accepted_changes'][0]]].each do |accepted|
      assert_raises(HybridSubscription::Error) { @backend.compatibility_plan(valid.merge('accepted_changes'=>accepted), create:true) }
    end
    changed = JSON.parse(request['resolutions'])
    changed['rematches']['follow'] = 'REJECT'
    assert_match(/plan changed/, assert_raises(HybridSubscription::Error) { @backend.compatibility_plan(valid.merge('resolutions'=>JSON.generate(changed)), create:true) }.message)
    assert_equal 1, @backend.config['profiles'].length
  end

  def test_duplicate_profile_or_generated_id_never_overwrites_existing_rows
    assert_raises(HybridSubscription::Error) { preview(args.merge('id'=>'main')) }
    compatibility = HybridSubscription::Compatibility.new(@config, @backend.caches)
    @config['groups'] << {'id'=>compatibility.copy_id('compatible', 'groups', 'proxy'), 'profile'=>'main', 'name'=>'Collision', 'sources'=>['source'], 'members'=>[]}
    save
    assert_match(/identifier already exists/, assert_raises(HybridSubscription::Error) { preview }.message)
    assert_equal 1, @backend.config['profiles'].length
  end

  def test_invalid_resolutions_are_rejected_before_cloning
    native_graph
    [ {'rematches'=>{'follow'=>'missing'}}, {'rematches'=>{'missing'=>'DIRECT'}}, {'disable_rules'=>['missing']}, {'disable_rules'=>['domain','domain']}, {'omit_dns'=>'true'}, {'typo'=>true} ].each do |resolution|
      assert_raises(HybridSubscription::Error) { preview(args('surge', resolution)) }
    end
    assert_raises(HybridSubscription::Error) { preview(args('mihomo', 'omit_dns'=>true)) }
    assert_raises(HybridSubscription::Error) { preview(args.merge('resolutions'=>'bad json')) }
    assert_equal 1, @backend.config['profiles'].length
  end

  def test_replacing_rematch_cannot_introduce_self_referential_group
    native_graph
    @config['groups'][0]['members'] = ['follow']
    @config['sub_rules'][0]['final_policy'] = 'DIRECT'
    @config['rules'].find { |rule| rule['id'] == 'regional' }['policy'] = 'DIRECT'
    save
    request = args('surge', 'rematches'=>{'follow'=>'proxy'}, 'abandon_sub_rules'=>true, 'omit_dns'=>true, 'disable_rules'=>['geosite'])
    plan = preview(request)
    refute plan['ready']
    assert_match(/cycle/, plan['errors'].join)
    assert_raises(HybridSubscription::Error) { create(request, plan) }
  end

  def test_disabled_rules_survive_clone_without_becoming_active
    @config['rules'] << {'id'=>'disabled', 'profile'=>'main', 'enabled'=>false, 'type'=>'GEOSITE', 'value'=>'cn', 'policy'=>'DIRECT'}
    save
    create
    rule = @backend.config['rules'].find { |row| row['profile'] == 'compatible' && row['type'] == 'GEOSITE' }
    assert_equal false, rule['enabled']
    assert_empty @backend.engine.validate('compatible')['errors']
  end

  def test_copy_does_not_bypass_publish_warning_confirmation
    @config['profiles'][0]['mihomo_policy'] = {'ipv6'=>true}
    save
    create
    built = @backend.build_profile('compatible')
    refute_empty built['warnings']
    assert_raises(HybridSubscription::Error) { @backend.publish({'release'=>built['release'], 'accepted_warnings'=>[]}) }
    assert_empty @backend.published
  end

  def test_logical_rules_and_portable_inline_sets_need_no_lossy_resolutions
    @config['rule_sets'] = [{'id'=>'local', 'source_type'=>'inline', 'behavior'=>'classical', 'inline_rules'=>"DOMAIN,one.test\nDOMAIN-SUFFIX,two.test"}]
    @config['rules'] << {'id'=>'logical', 'profile'=>'main', 'type'=>'AND', 'conditions'=>[{'type'=>'NETWORK', 'value'=>'TCP'}, {'type'=>'RULE-SET', 'value'=>'local'}], 'policy'=>'proxy'}
    save
    %w[surge singbox].each do |format|
      plan = preview(args(format))
      assert plan['ready'], plan['errors'].inspect
      assert_equal ['create-profile'], plan['changes'].map { |change| change['code'] }
    end
    rule = @backend.compatibility('profile'=>'main')['choices']['rules'].find { |item| item['id'] == 'logical' }
    assert_empty rule['targets']
  end

  def test_report_identifies_nested_and_inline_target_blockers
    @config['rule_sets'] = [
      {'id'=>'remote', 'source_type'=>'remote', 'behavior'=>'classical', 'mihomo_url'=>'https://rules.invalid/source', 'surge_url'=>'https://rules.invalid/surge'},
      {'id'=>'local', 'source_type'=>'inline', 'behavior'=>'classical', 'inline_rules'=>'GEOIP,LAN'}
    ]
    @config['rules'] << {'id'=>'logical', 'profile'=>'main', 'type'=>'OR', 'conditions'=>[{'type'=>'IP-CIDR', 'value'=>'192.0.2.0/24', 'no_resolve'=>true}, {'type'=>'RULE-SET', 'value'=>'remote'}], 'policy'=>'DIRECT'}
    @config['rules'] << {'id'=>'inline', 'profile'=>'main', 'type'=>'RULE-SET', 'value'=>'local', 'policy'=>'DIRECT'}
    save
    report = @backend.compatibility('profile'=>'main')
    rules = report['choices']['rules']
    assert_equal ['singbox'], rules.find { |rule| rule['id'] == 'logical' }['targets']
    assert_equal ['singbox'], rules.find { |rule| rule['id'] == 'inline' }['targets']
    messages = report['targets'].find { |target| target['format'] == 'singbox' }['issues'].map { |issue| issue['message'] }.join('; ')
    assert_match(/no-resolve/, messages)
    assert_match(/needs a singbox URL/, messages)
    assert_match(/GEOIP LAN/, messages)
  end

  def test_read_and_write_rpc_methods_are_exposed_separately
    assert @backend.call('compatibility', 'profile'=>'main')['ok']
    plan = @backend.call('compatibility_plan', args)
    assert plan['ok']
    refute @backend.call('compatibility_create', args)['ok']
    acl = JSON.parse(File.read(File.expand_path('../root/usr/share/rpcd/acl.d/luci-app-hybrid-subscription.json', __dir__)))['luci-app-hybrid-subscription']
    assert_includes acl['read']['ubus']['luci.hybrid_subscription'], 'compatibility_plan'
    refute_includes acl['read']['ubus']['luci.hybrid_subscription'], 'compatibility_create'
    assert_includes acl['write']['ubus']['luci.hybrid_subscription'], 'compatibility_create'
  end

  def test_group_choices_report_native_modes_and_behavior_differences
    @config['groups'][0].merge!('mihomo_type'=>'smart', 'surge_type'=>'select', 'singbox_type'=>'fallback')
    save
    report = @backend.compatibility('profile'=>'main')
    group = report['choices']['groups'][0]
    assert_equal({'mihomo'=>'smart', 'surge'=>'select', 'singbox'=>'fallback'}, group['modes'])
    assert_equal %w[manual url-test fallback], group['alternatives']['surge']
    assert_equal %w[manual url-test], group['alternatives']['singbox']
    surge = report['targets'].find { |target| target['format'] == 'surge' }['issues'].find { |issue| issue['kind'] == 'group' }
    assert_equal 'warning', surge['severity']
    assert_equal 'group_modes', surge['resolution']
    assert_match(/Mihomo smart/, surge['message'])
    assert report['targets'].find { |target| target['format'] == 'surge' }['warnings'].any? { |warning| warning['code'] == 'surge:group:proxy' }
    singbox = report['targets'].find { |target| target['format'] == 'singbox' }['issues'].find { |issue| issue['kind'] == 'group' }
    assert_equal 'error', singbox['severity']
    assert_match(/does not support fallback/, singbox['message'])
  end

  def test_mihomo_smart_can_be_explicitly_changed_to_manual_for_standard_core
    @config['profiles'][0]['mihomo_core'] = 'standard'
    @config['groups'][0]['mihomo_type'] = 'smart'
    save
    before = @backend.config
    refute preview(args('mihomo'))['ready']
    request = args('mihomo', 'group_modes'=>{'proxy'=>'manual'})
    plan = preview(request)
    assert plan['ready'], plan['errors'].inspect
    change = plan['changes'].find { |item| item['code'] == 'group-mode:proxy' }
    assert_match(/smart -> select/, change['message'])
    assert_match(/does not automatically switch/, change['message'])
    create(request, plan)
    assert_equal before['groups'][0], @backend.config['groups'][0]
    assert_equal 'select', @backend.config['groups'].last['mihomo_type']
    assert_equal before['rules'][0].reject { |key, _| %w[id profile policy].include?(key) }, @backend.config['rules'].last.reject { |key, _| %w[id profile policy].include?(key) }
    assert_empty @backend.engine.validate('compatible')['errors']
  end

  def test_singbox_fallback_can_be_explicitly_replaced_with_latency_testing
    @config['groups'][0].merge!('mihomo_type'=>'fallback', 'singbox_type'=>'fallback')
    save
    request = args('singbox', 'group_modes'=>{'proxy'=>'url-test'})
    plan = preview(request)
    assert plan['ready'], plan['errors'].inspect
    assert_match(/fallback -> urltest/, plan['changes'].last['message'])
    assert_match(/does not preserve Smart/, plan['changes'].last['message'])
    create(request, plan)
    assert_equal 'fallback', @backend.config['groups'][0]['singbox_type']
    assert_equal 'urltest', @backend.config['groups'].last['singbox_type']
    assert_equal 'fallback', @backend.config['groups'].last['mihomo_type']
  end

  def test_group_modes_cannot_change_unsupported_rule_conditions
    native_graph
    plan = preview(args('surge', 'group_modes'=>{'proxy'=>'manual'}))
    refute plan['ready']
    assert_equal %w[create-profile group-mode:proxy], plan['changes'].map { |change| change['code'] }
    assert_match(/GEOSITE/, plan['errors'].join)
    refute @backend.config['rules'].any? { |rule| rule['enabled'] == false }
  end

  def rematch_alternative(format, mode, members)
    args(format, 'rematches'=>{'follow'=>{'mode'=>mode, 'members'=>members}}, 'abandon_sub_rules'=>true, 'omit_dns'=>true, 'disable_rules'=>['geosite'])
  end

  def test_rematch_manual_group_preserves_candidates_and_client_control_requirement
    native_graph
    @config['groups'][0]['singbox_type'] = 'urltest'
    save
    before = @backend.config
    request = rematch_alternative('singbox', 'manual', ['DIRECT', 'proxy'])
    plan = preview(request)
    assert plan['ready'], plan['errors'].inspect
    message = plan['changes'].find { |item| item['code'] == 'replace-rematch:follow' }['message']
    assert_match(/candidates: DIRECT, Proxy \(proxy\)/, message)
    assert_match(/requires client selection controls or its API/, message)
    assert_match(/otherwise the first candidate is used/, message)
    assert plan['warnings'].any? { |warning| warning['code'] == 'singbox:manual-controls:rematch:follow' }
    create(request, plan)
    current = @backend.config
    copied = current['groups'].select { |group| group['profile'] == 'compatible' }
    replacement = copied.find { |group| group['name'] == 'Follow region' }
    proxy = copied.find { |group| group['name'] == 'Proxy' }
    assert_equal ['DIRECT', proxy['id']], replacement['members']
    assert_equal 'selector', replacement['singbox_type']
    assert_equal 'urltest', proxy['singbox_type'], 'A manual parent does not remove automation inside a candidate group'
    assert_equal replacement['id'], current['profiles'].last['final_policy']
    output = JSON.parse(@backend.engine.render('compatible', 'singbox')['content'])
    assert_equal 'DIRECT', output['outbounds'].find { |node| node['tag'] == 'Follow region' }['default']
    refute output.key?('experimental')
    assert_equal before['rematches'], current['rematches']
    assert_equal before['profiles'][0], current['profiles'][0]
  end

  def test_rematch_latency_group_uses_native_target_mode_and_explicit_candidates
    native_graph
    request = rematch_alternative('surge', 'url-test', ['proxy', 'DIRECT'])
    plan = preview(request)
    assert plan['ready'], plan['errors'].inspect
    assert_match(/does not preserve Smart or regional matching/, plan['changes'].find { |change| change['code'] == 'replace-rematch:follow' }['message'])
    create(request, plan)
    group = @backend.config['groups'].find { |row| row['profile'] == 'compatible' && row['name'] == 'Follow region' }
    assert_equal 'url-test', group['surge_type']
    assert_equal 300, group['interval']
    assert_equal 50, group['tolerance']
    assert_match(/Follow region = url-test, Proxy, DIRECT/, @backend.engine.render('compatible', 'surge')['content'])
  end

  def test_unsupported_modes_and_implicit_or_invalid_candidates_are_rejected
    native_graph
    [{'proxy'=>'smart'}, {'proxy'=>'fallback'}, {'missing'=>'manual'}].each do |modes|
      assert_raises(HybridSubscription::Error) { preview(args('singbox', 'group_modes'=>modes)) }
    end
    [{'mode'=>'fallback', 'members'=>['proxy']}, {'mode'=>'manual', 'members'=>[]}, {'mode'=>'manual', 'members'=>['proxy','proxy']}, {'mode'=>'url-test', 'members'=>['missing']}, {'mode'=>'manual', 'members'=>['proxy'], 'extra'=>true}].each do |resolution|
      assert_raises(HybridSubscription::Error) { preview(args('surge', 'rematches'=>{'follow'=>resolution})) }
    end
    plan = preview(rematch_alternative('singbox', 'manual', ['proxy', 'REJECT']))
    refute plan['ready']
    assert_match(/cannot put REJECT/, plan['errors'].join)
    assert_raises(HybridSubscription::Error) { preview(rematch_alternative('mihomo', 'manual', ['proxy'])) }
    assert_equal 1, @backend.config['profiles'].length
  end

  def test_new_rematch_alternative_group_still_blocks_cycles_and_id_collisions
    native_graph
    @config['groups'][0]['members'] = ['follow']
    @config['sub_rules'][0]['final_policy'] = 'DIRECT'
    @config['rules'].find { |rule| rule['id'] == 'regional' }['policy'] = 'DIRECT'
    save
    request = rematch_alternative('surge', 'manual', ['proxy'])
    plan = preview(request)
    refute plan['ready']
    assert_match(/cycle/, plan['errors'].join)
    assert_raises(HybridSubscription::Error) { create(request, plan) }
    @config['groups'][0]['members'] = []
    compatibility = HybridSubscription::Compatibility.new(@config, @backend.caches)
    @config['groups'] << {'id'=>compatibility.copy_id('compatible', 'rematch_groups', 'follow'), 'profile'=>'main', 'name'=>'Collision', 'sources'=>['source'], 'members'=>[]}
    save
    assert_match(/identifier already exists/, assert_raises(HybridSubscription::Error) { preview(request) }.message)
  end

  def test_changing_modes_or_rematch_member_order_invalidates_reviewed_plan
    request = args('surge', 'group_modes'=>{'proxy'=>'manual'})
    plan = preview(request)
    assert_match(/plan changed/, assert_raises(HybridSubscription::Error) { create(args('surge', 'group_modes'=>{'proxy'=>'url-test'}), plan) }.message)
    native_graph
    request = rematch_alternative('singbox', 'manual', ['proxy', 'DIRECT'])
    plan = preview(request)
    assert_match(/plan changed/, assert_raises(HybridSubscription::Error) { create(rematch_alternative('singbox', 'manual', ['DIRECT', 'proxy']), plan) }.message)
    assert_equal 1, @backend.config['profiles'].length
  end

  def test_group_suggestions_only_cover_affected_modes_and_explain_losses
    assert_empty @backend.compatibility('profile'=>'main')['choices']['groups'][0]['suggestions']
    [
      ['smart', 'select', 'selector', 'url-test', 'url-test', /does not preserve Smart/],
      ['select', 'url-test', 'urltest', 'manual', 'manual', /automatic switching will stop/],
      ['fallback', 'select', 'selector', 'fallback', 'url-test', /priority/],
      ['load-balance', 'select', 'selector', 'url-test', 'url-test', /does not preserve load balancing/]
    ].each do |baseline, surge, singbox, surge_mode, singbox_mode, reason|
      @config['groups'][0].merge!('mihomo_type'=>baseline, 'surge_type'=>surge, 'singbox_type'=>singbox)
      save
      suggestions = @backend.compatibility('profile'=>'main')['choices']['groups'][0]['suggestions']
      assert_equal surge_mode, suggestions['surge']['mode']
      assert_equal singbox_mode, suggestions['singbox']['mode']
      assert_match reason, suggestions['surge']['reason']
      refute suggestions.key?('mihomo')
    end
    @config['groups'][0].merge!('mihomo_type'=>'smart', 'singbox_type'=>'urltest')
    save
    unchanged = @backend.compatibility('profile'=>'main')['choices']['groups'][0]['suggestions']['singbox']
    refute unchanged['available']
    refute unchanged.key?('mode')
    assert_match(/already uses this alternative/, unchanged['reason'])
  end

  def test_group_suggestions_reject_unknown_source_modes_and_correct_invalid_target_spellings
    %w[unknown manual selector urltest].each do |baseline|
      @config['groups'][0].merge!('mihomo_type'=>baseline, 'surge_type'=>'invalid', 'singbox_type'=>'invalid')
      save
      suggestions = @backend.compatibility('profile'=>'main')['choices']['groups'][0]['suggestions']
      suggestions.each_value do |suggestion|
        refute suggestion['available']
        refute suggestion.key?('mode')
        assert_match(/mode is unknown/, suggestion['reason'])
      end
    end
    @config['groups'][0].merge!('mihomo_type'=>'url-test', 'singbox_type'=>'url-test')
    save
    suggestion = @backend.compatibility('profile'=>'main')['choices']['groups'][0]['suggestions']['singbox']
    assert suggestion['available']
    assert_equal 'url-test', suggestion['mode']
    assert preview(args('singbox', 'group_modes'=>{'proxy'=>suggestion['mode']}))['ready']
  end

  def rematch_suggestion(id = 'follow')
    @backend.compatibility('profile'=>'main')['choices']['rematches'].find { |item| item['id'] == id }['suggestions']['surge']
  end

  def test_rematch_suggestions_preserve_policy_order_resolve_rematches_and_ignore_disabled_rules
    native_graph
    %w[backup fast].each do |id|
      @config['groups'] << {'id'=>id, 'profile'=>'main', 'name'=>id.capitalize, 'sources'=>['source'], 'members'=>[]}
    end
    @config['rematches'] << {'id'=>'next', 'profile'=>'main', 'name'=>'Nested', 'target_sub_rule'=>'next_scope'}
    @config['sub_rules'] << {'id'=>'next_scope', 'profile'=>'main', 'name'=>'Nested scope', 'final_policy'=>'fast'}
    @config['rules'] << {'id'=>'nested_choice', 'profile'=>'main', 'sub_rule'=>'region', 'type'=>'DOMAIN', 'value'=>'nested.test', 'policy'=>'next'}
    @config['rules'] << {'id'=>'nested_backup', 'profile'=>'main', 'sub_rule'=>'next_scope', 'type'=>'DOMAIN', 'value'=>'backup.test', 'policy'=>'backup'}
    @config['rules'] << {'id'=>'disabled_choice', 'profile'=>'main', 'sub_rule'=>'region', 'type'=>'UNKNOWN', 'policy'=>'missing', 'enabled'=>false}
    @config['rules'] << {'id'=>'unrelated', 'profile'=>'other', 'sub_rule'=>'region', 'type'=>'DOMAIN', 'value'=>'unrelated.test', 'policy'=>'DIRECT'}
    save
    suggestion = rematch_suggestion
    assert suggestion['available']
    assert_equal 'manual', suggestion['mode']
    assert_equal %w[proxy backup fast], suggestion['members']
    assert_match(/does not preserve rule conditions, REMATCH-NAME/, suggestion['reason'])
    assert_match(/first candidate becomes the initial selection/, suggestion['reason'])
    refute_includes suggestion['members'], 'next'
  end

  def test_rematch_suggestions_skip_entire_builtin_or_missing_paths_without_filtering
    native_graph
    %w[DIRECT REJECT missing].each do |policy|
      @config['sub_rules'][0]['final_policy'] = policy
      save
      suggestion = rematch_suggestion
      refute suggestion['available']
      refute suggestion.key?('members')
      refute suggestion.key?('mode')
      assert_match(policy == 'missing' ? /missing or ambiguous/ : /includes DIRECT or REJECT/, suggestion['reason'])
    end
    @config['rematches'][0]['target_sub_rule'] = 'missing'
    save
    assert_match(/missing or ambiguous/, rematch_suggestion['reason'])
  end

  def test_rematch_suggestions_reject_cycles_and_transitive_candidate_dependencies
    native_graph
    @config['sub_rules'][0]['final_policy'] = 'follow'
    save
    refute rematch_suggestion['available']
    assert_match(/cycle/, rematch_suggestion['reason'])
    @config['sub_rules'][0]['final_policy'] = 'proxy'
    @config['groups'][0]['members'] = ['bridge']
    @config['groups'] << {'id'=>'bridge', 'profile'=>'main', 'name'=>'Bridge', 'sources'=>[], 'members'=>['follow']}
    save
    refute rematch_suggestion['available']
    assert_match(/candidate depends on this rematch/, rematch_suggestion['reason'])
    @config['groups'].last['members'] = ['proxy']
    save
    refute rematch_suggestion['available']
    assert_match(/cycle/, rematch_suggestion['reason'])
  end

  def test_rematch_suggestions_bound_depth_and_reject_unsupported_conditions
    native_graph
    initial = HybridSubscription::Engine.copy(@config)
    @config['rules'].find { |rule| rule['id'] == 'regional' }['type'] = 'UNKNOWN'
    save
    refute rematch_suggestion['available']
    assert_match(/unsupported or malformed conditions/, rematch_suggestion['reason'])
    @config = HybridSubscription::Engine.copy(initial)
    @config['rules'].find { |rule| rule['id'] == 'regional' }.merge!('type'=>'AND', 'conditions'=>['invalid'])
    save
    refute rematch_suggestion['available']
    assert_match(/unsupported or malformed conditions/, rematch_suggestion['reason'])
    @config = initial
    @config['sub_rules'][0]['final_policy'] = 'nested0'
    18.times do |i|
      @config['rematches'] << {'id'=>"nested#{i}", 'profile'=>'main', 'name'=>"Nested #{i}", 'target_sub_rule'=>"scope#{i}"}
      @config['sub_rules'] << {'id'=>"scope#{i}", 'profile'=>'main', 'name'=>"Scope #{i}", 'final_policy'=>i == 17 ? 'proxy' : "nested#{i + 1}"}
    end
    save
    refute rematch_suggestion['available']
    assert_match(/depth limit/, rematch_suggestion['reason'])
  end

  def test_suggestions_are_read_only_private_and_never_authorize_policy_removal
    native_graph
    @config['groups'][0]['mihomo_type'] = 'smart'
    save
    before, cache = @backend.config, @backend.caches
    report = @backend.compatibility('profile'=>'main')
    proposal = report['choices']['rematches'][0]['suggestions']['surge']
    assert proposal['available']
    refute report['choices']['rematches'][0]['suggestions'].key?('mihomo')
    refute report['choices'].key?('resolutions')
    rules = {'rematches'=>{'follow'=>proposal.slice('mode', 'members')}, 'group_modes'=>{'proxy'=>report['choices']['groups'][0]['suggestions']['surge']['mode']}}
    plan = preview(args('surge', rules))
    refute plan['ready']
    assert_equal %w[create-profile replace-rematch:follow group-mode:proxy], plan['changes'].map { |change| change['code'] }
    assert_equal before, @backend.config
    assert_equal cache, @backend.caches
    assert_empty @backend.releases
    assert_empty @backend.published
    %w[private-url-token private-node-password secret-server.invalid private-dns-token].each { |secret| refute_includes JSON.generate(report), secret }
  end
end
