# frozen_string_literal: true
require 'minitest/autorun'
require 'json'
require 'base64'
require 'yaml'
require_relative '../root/usr/share/hybrid-subscription/engine'

class EngineTest < Minitest::Test
  Engine = HybridSubscription::Engine

  def setup
    @node = { 'name' => '[A] Japan', 'type' => 'anytls', 'server' => 'proxy.example.test', 'port' => 443,
              'password' => 'synthetic-secret', 'sni' => 'tls.example.test', 'udp' => true,
              'tfo' => true, 'client-fingerprint' => 'chrome' }
    @config = {
      'sources' => [{ 'id' => 'a', 'name' => 'Alpha', 'enabled' => true }, { 'id' => 'b', 'name' => 'Beta', 'enabled' => true }],
      'profiles' => [{ 'id' => 'main', 'name' => 'Hybrid', 'sources' => %w[a b], 'formats' => %w[mihomo surge singbox], 'final_policy' => 'proxy', 'mihomo_core' => 'smart' }],
      'groups' => [{ 'id' => 'proxy', 'name' => 'Proxy', 'profile' => 'main', 'sources' => ['a'], 'members' => ['region'], 'mihomo_type' => 'select', 'surge_type' => 'select', 'singbox_type' => 'selector' },
                   { 'id' => 'region', 'name' => 'Source B JP', 'profile' => 'main', 'sources' => ['b'], 'filter' => 'Japan', 'members' => [], 'mihomo_type' => 'smart', 'surge_type' => 'smart', 'singbox_type' => 'urltest' }],
      'rule_sets' => [{ 'id' => 'domestic', 'name' => 'Domestic', 'behavior' => 'domain', 'mihomo_format' => 'text', 'mihomo_url' => 'https://rules.example.test/domestic.txt', 'surge_url' => 'https://rules.example.test/domestic.conf', 'singbox_url' => 'https://rules.example.test/domestic.json', 'singbox_format' => 'source' }],
      'rules' => [{ 'id' => 'home', 'profile' => 'main', 'type' => 'RULE-SET', 'value' => 'domestic', 'policy' => 'DIRECT' },
                  { 'id' => 'ai', 'profile' => 'main', 'type' => 'DOMAIN-SUFFIX', 'value' => 'ai.example.test', 'policy' => 'proxy' },
                  { 'id' => 'udp', 'profile' => 'main', 'type' => 'NETWORK', 'value' => 'UDP', 'policy' => 'REJECT' }]
    }
    @caches = { 'a' => { 'nodes' => [@node], 'meta' => {} }, 'b' => { 'nodes' => [{ 'name' => 'Japan 01', 'type' => 'trojan', 'server' => 'second.example.test', 'port' => 443, 'password' => 'other-synthetic-secret', 'skip-cert-verify' => false }], 'meta' => {} } }
  end

  def engine
    Engine.new(@config, @caches)
  end

  def assert_ok(format)
    result = engine.render('main', format)
    assert_equal [], result['errors'], result['errors'].join('; ')
    result
  end

  def test_mihomo_preserves_all_raw_node_fields_and_disables_smart_training
    result = assert_ok('mihomo')
    config = YAML.safe_load(result['content'])
    assert_equal @node.merge('name' => 'Alpha | [A] Japan'), config['proxies'].first
    smart = config['proxy-groups'].find { |g| g['type'] == 'smart' }
    assert_equal ['Beta | Japan 01'], smart['proxies']
    assert_equal false, smart['collectdata']
    assert_equal false, smart['uselightgbm']
    refute config.key?('secret')
    refute config.key?('external-controller')
    refute config.key?('proxy-providers')
    assert_equal 'MATCH,Proxy', config['rules'].last
    assert_equal [], result['warnings']
    refute @config['groups'].first.key?('_nodes')
  end

  def test_surge_warns_about_fingerprint_without_inventing_certificate_pin
    result = assert_ok('surge')
    assert_includes result['content'], 'anytls, proxy.example.test, 443, password=synthetic-secret'
    assert_includes result['content'], 'tfo=true'
    refute_includes result['content'], 'server-cert-fingerprint'
    assert result['warnings'].any? { |w| w['message'].include?('client-fingerprint') }
    assert_includes result['content'], 'PROTOCOL,UDP,REJECT'
    assert_includes result['content'], 'DOMAIN-SET,https://rules.example.test/domestic.conf,DIRECT'
  end

  def test_singbox_is_modern_native_config
    config = JSON.parse(assert_ok('singbox')['content'])
    node = config['outbounds'].find { |n| n['type'] == 'anytls' }
    assert_equal 'chrome', node.dig('tls', 'utls', 'fingerprint')
    assert_equal true, node['tcp_fast_open']
    assert_equal 'local', config['dns']['servers'].first['type']
    assert_equal 'reject', config['route']['rules'].last['action']
    refute config['outbounds'].any? { |n| n['type'] == 'block' }
    refute config.key?('experimental')
  end

  def test_invalid_graph_blocks_every_export
    @config['groups'].last['members'] = ['proxy']
    %w[mihomo surge singbox].each { |f| assert engine.render('main', f)['errors'].any? { |e| e.include?('cycle') } }
  end

  def test_missing_reference_is_never_direct_fallback
    @config['groups'].first['members'] = ['missing']
    r = engine.render('main', 'mihomo')
    assert_empty r['content']
    assert r['errors'].any? { |e| e.include?('Missing policy') }
  end

  def test_no_empty_region_fallback
    @config['groups'].last['filter'] = 'Hong Kong'
    assert engine.validate('main')['errors'].any? { |e| e.include?('no members') }
  end

  def test_source_filter_applies_before_group_filter
    @config['sources'].last['exclude_filter'] = 'Japan'
    assert engine.validate('main')['errors'].any? { |e| e.include?('no nodes after filtering') }
  end

  def test_invalid_regex_is_sanitized
    @config['groups'].last['filter'] = '[secret-regex'
    result = engine.validate('main')
    assert result['errors'].any? { |e| e.include?('invalid regular expression') }
    refute result.to_s.include?('secret-regex')
  end

  def test_surge_smart_group_rejects_nested_groups
    @config['groups'].first['surge_type'] = 'smart'
    assert engine.render('main', 'surge')['errors'].any? { |e| e.include?('only nodes') }
    assert_equal [], engine.render('main', 'mihomo')['errors']
  end

  def test_standard_mihomo_cannot_use_smart
    @config['profiles'].first['mihomo_core'] = 'standard'
    assert engine.render('main', 'mihomo')['errors'].any? { |e| e.include?('Smart core') }
  end

  def test_unsupported_surge_vless_is_blocking_not_dropped
    @caches['a']['nodes'] = [@node.reject { |k, _| k == 'password' }.merge('type' => 'vless', 'uuid' => '11111111-1111-4111-8111-111111111111', 'tls' => true)]
    r = engine.render('main', 'surge')
    assert_empty r['content']
    assert r['errors'].any? { |e| e.include?('does not support vless') }
    assert_equal [], engine.render('main', 'singbox')['errors']
  end

  def test_singbox_geoip_requires_native_ruleset
    @config['rules'].first.merge!('type' => 'GEOIP', 'value' => 'CN')
    assert engine.render('main', 'singbox')['errors'].any? { |e| e.include?('removed GEOIP') }
    assert_equal [], engine.render('main', 'mihomo')['errors']
  end

  def test_unknown_fields_require_explicit_loss_warning
    @node['future-option'] = 'new-option'
    assert assert_ok('surge')['warnings'].any? { |w| w['code'].end_with?('future-option') }
    assert assert_ok('singbox')['warnings'].any? { |w| w['code'].end_with?('future-option') }
    assert_includes assert_ok('mihomo')['content'], 'future-option'
  end

  def test_preview_redacts_credentials_servers_and_secret_rule_urls
    @config['rule_sets'].first['surge_url'] += '?token=rules-secret'
    %w[mihomo surge singbox].each do |format|
      r = engine.render('main', format, redact: true)
      assert_equal [], r['errors']
      %w[synthetic-secret other-synthetic-secret proxy.example.test tls.example.test second.example.test rules-secret].each { |s| refute_includes r['content'], s }
      assert_includes r['content'], 'Alpha | [A] Japan'
    end
  end

  def test_source_update_is_external_and_repeatable_render_is_deterministic
    first = assert_ok('mihomo')['content']
    assert_equal first, engine.render('main', 'mihomo')['content']
    @caches['b']['nodes'].first['password'] = 'changed-secret'
    second = assert_ok('mihomo')['content']
    refute_equal first, second
    assert_includes second, 'changed-secret'
  end

  def test_multiprofile_scope_is_respected
    @config['profiles'] << { 'id' => 'other', 'name' => 'Other', 'sources' => ['a'], 'formats' => ['mihomo'], 'final_policy' => 'solo' }
    @config['groups'] << { 'id' => 'solo', 'name' => 'Single', 'profile' => 'other', 'sources' => ['a'], 'members' => [] }
    result = engine.render('other', 'mihomo')
    assert_equal [], result['errors']
    parsed = YAML.safe_load(result['content'])
    assert_equal 1, parsed['proxies'].length
    assert_equal ['MATCH,Single'], parsed['rules']
  end

  def test_duplicate_names_and_mismatched_rule_prefix_are_rejected
    @config['groups'].last['name'] = 'Proxy'
    assert engine.validate('main')['errors'].any? { |e| e.include?('Duplicate policy') }
    @config['groups'].last['name'] = 'Region'
    @config['rules'].first.merge!('type' => 'IP-CIDR6', 'value' => '10.0.0.0/8')
    assert engine.validate('main')['errors'].any? { |e| e.include?('invalid IP prefix') }
  end

  def test_rule_urls_require_http_and_no_userinfo
    @config['rule_sets'].first['mihomo_url'] = 'file:///etc/shadow'
    assert engine.render('main', 'mihomo')['errors'].any? { |e| e.include?('HTTP(S)') }
    @config['rule_sets'].first['mihomo_url'] = 'https://user:secret@example.test/rules'
    assert engine.render('main', 'mihomo')['errors'].any? { |e| e.include?('HTTP(S)') }
  end

  def test_mihomo_import_does_not_import_router_secrets_or_other_config
    nodes = Engine.import_nodes(YAML.dump('secret' => 'router-secret', 'external-controller' => '0.0.0.0:9090', 'proxies' => [@node]))
    assert_equal [@node], nodes
    refute nodes.to_s.include?('router-secret')
  end

  def test_unsafe_yaml_aliases_and_objects_are_rejected
    ["--- !ruby/object:File {}", "proxies: &nodes []\nother: *nodes"].each do |text|
      assert_raises(HybridSubscription::Error) { Engine.import_nodes(text) }
    end
  end

  def test_uri_import_supports_percent_encoded_credentials_and_sni
    n = Engine.import_nodes('trojan://synthetic%40password@proxy.example.test:443?sni=tls.example.test#Japan%2001').first
    assert_equal 'synthetic@password', n['password']
    assert_equal 'Japan 01', n['name']
    assert_equal 'tls.example.test', n['sni']
    b64 = Base64.strict_encode64('anytls://synthetic@proxy.example.test:443#AI')
    assert_equal 'anytls', Engine.import_nodes(b64).first['type']
  end

  def test_uri_unknown_parameters_do_not_silently_disappear
    assert_raises(HybridSubscription::Error) { Engine.import_nodes('trojan://secret@proxy.example.test:443?future=unsupported#Japan') }
  end

  def test_ss_uri_and_vmess_uri_import
    ss = "ss://#{Base64.strict_encode64('aes-128-gcm:synthetic')}@proxy.example.test:8388#SS"
    assert_equal 'aes-128-gcm', Engine.import_nodes(ss).first['cipher']
    vmess = { 'v' => '2', 'ps' => 'VMess', 'add' => 'proxy.example.test', 'port' => '443', 'id' => '11111111-1111-4111-8111-111111111111', 'aid' => '0', 'net' => 'ws', 'type' => 'none', 'path' => '/ws', 'host' => 'tls.example.test', 'tls' => 'tls' }
    n = Engine.import_nodes('vmess://' + Base64.strict_encode64(JSON.generate(vmess))).first
    assert_equal 'ws', n['network']
    assert_equal '/ws', n.dig('ws-opts', 'path')
  end

  def test_singbox_import_preserves_verified_anytls_mapping
    sb = { 'outbounds' => [{ 'type' => 'anytls', 'tag' => 'AI', 'server' => 'proxy.example.test', 'server_port' => 443, 'password' => 'synthetic', 'tls' => { 'enabled' => true, 'server_name' => 'tls.example.test', 'utls' => { 'enabled' => true, 'fingerprint' => 'chrome' } } }, { 'type' => 'selector', 'tag' => 'Select', 'outbounds' => ['AI'] }] }
    nodes = Engine.import_nodes(JSON.generate(sb))
    assert_equal 1, nodes.length
    assert_equal 'chrome', nodes.first['client-fingerprint']
    assert_equal 'tls.example.test', nodes.first['sni']
  end

  def test_surge_import_supported_simple_anytls
    text = "[Proxy]\nAI = anytls, proxy.example.test, 443, password=synthetic, sni=tls.example.test, tfo=true\n[Rule]\nFINAL,AI\n"
    n = Engine.import_nodes(text).first
    assert_equal 'anytls', n['type']
    assert_equal true, n['tfo']
  end

  def test_surge_import_unknown_option_blocks_instead_of_losing_data
    assert_raises(HybridSubscription::Error) { Engine.import_nodes("[Proxy]\nAI = anytls, proxy.example.test, 443, password=synthetic, new-secret=unsupported\n") }
  end

  def test_synthetic_protocol_matrix
    variants = [
      { 'type' => 'ss', 'cipher' => 'aes-128-gcm', 'password' => 'synthetic' },
      { 'type' => 'vmess', 'uuid' => '11111111-1111-4111-8111-111111111111', 'cipher' => 'auto', 'alterId' => 0, 'tls' => true, 'network' => 'ws', 'ws-opts' => { 'path' => '/ws', 'headers' => { 'Host' => 'tls.example.test' } } },
      { 'type' => 'hysteria2', 'password' => 'synthetic', 'up' => 20, 'down' => 100, 'obfs' => 'salamander', 'obfs-password' => 'synthetic-obfs' },
      { 'type' => 'tuic', 'uuid' => '11111111-1111-4111-8111-111111111111', 'password' => 'synthetic' }
    ]
    variants.each do |variant|
      @caches['a']['nodes'] = [{ 'name' => 'Synthetic', 'server' => 'proxy.example.test', 'port' => 443 }.merge(variant)]
      %w[mihomo surge singbox].each { |format| assert_ok(format) }
    end
  end
  def test_surge_quoted_values_round_trip_without_splitting_credentials
    @node['password'] = 'synthetic,with="quote"\\slash'
    @node['alpn'] = ['h2', 'http/1.1']
    output = assert_ok('surge')['content']
    imported = Engine.import_nodes(output, 'surge')
    assert_equal @node['password'], imported.first['password']
    assert_equal @node['alpn'], imported.first['alpn']
  end

  def test_malformed_node_shape_and_uuid_have_clear_errors
    @caches['a']['nodes'] = [nil]
    assert engine.validate('main')['errors'].any? { |e| e.include?('node must be an object') }
    node = @node.merge('type' => 'vless', 'uuid' => 'not-a-uuid')
    assert_raises(HybridSubscription::Error) { Engine.import_nodes(YAML.dump('proxies' => [node])) }
  end

  def test_import_rejects_contextually_unused_uri_fields
    %w[flow=xtls-rprx-vision obfs-password=secret type=tcp\&path=%2Fws security=none insecure=perhaps].each do |query|
      assert_raises(HybridSubscription::Error) { Engine.import_nodes("trojan://synthetic@proxy.example.test:443?#{query}#Node") }
    end
    assert_raises(HybridSubscription::Error) { Engine.import_nodes('trojan://synthetic@proxy.example.test:443?sni=a&sni=b#Node') }
  end

  def test_singbox_does_not_consume_inapplicable_fields_silently
    @caches['a']['nodes'] = [{ 'name' => 'SS', 'type' => 'ss', 'server' => 'proxy.example.test', 'port' => 8388, 'cipher' => 'aes-128-gcm', 'password' => 'synthetic', 'client-fingerprint' => 'chrome' }]
    assert assert_ok('singbox')['warnings'].any? { |w| w['message'].include?('client-fingerprint') }
  end

  def test_bandwidth_is_integer_and_fractional_mbps_is_rejected
    @caches['a']['nodes'] = [{ 'name' => 'HY2', 'type' => 'hysteria2', 'server' => 'proxy.example.test', 'port' => 443, 'password' => 'synthetic', 'down' => '100 Mbps' }]
    assert_includes assert_ok('surge')['content'], 'download-bandwidth=100'
    refute_includes assert_ok('surge')['content'], 'download-bandwidth=100.0'
    @caches['a']['nodes'][0]['down'] = '10.5 Mbps'
    assert engine.render('main', 'surge')['errors'].any? { |e| e.include?('whole number') }
  end

  def add_native_region_graph
    @config['profiles'].first['formats'] = ['mihomo']
    @config['groups'].first['members'] = ['follow']
    @config['groups'].first['default_member'] = 'follow'
    @config['groups'].first['empty_fallback'] = 'REJECT'
    @config['groups'].first['lazy'] = false
    @config['rematches'] = [{ 'id' => 'follow', 'profile' => 'main', 'name' => 'Follow region', 'target_sub_rule' => 'pick', 'rematch_name' => 'Source A' }]
    @config['sub_rules'] = [{ 'id' => 'pick', 'profile' => 'main', 'name' => 'Pick region', 'final_policy' => 'REJECT' }]
    @config['rules'] << { 'id' => 'choose', 'profile' => 'main', 'sub_rule' => 'pick', 'type' => 'REMATCH-NAME', 'value' => 'Source A', 'policy' => 'region' }
    @config['rules'].insert(0, { 'id' => 'logical', 'profile' => 'main', 'type' => 'AND', 'conditions' => [{ 'type' => 'NETWORK', 'value' => 'UDP' }, { 'type' => 'RULE-SET', 'value' => 'domestic' }], 'policy' => 'REJECT' })
  end

  def test_rematch_subrule_and_logical_rule_graph_is_preserved
    add_native_region_graph
    output = YAML.safe_load(assert_ok('mihomo')['content'])
    assert_equal 'AND,((NETWORK,udp),(RULE-SET,domestic)),REJECT', output['rules'].first
    assert_equal ['REMATCH-NAME,Source A,Source B JP', 'MATCH,REJECT'], output['sub-rules']['Pick region']
    assert_equal({ 'name' => 'Follow region', 'type' => 'rematch', 'target-sub-rule' => 'Pick region', 'target-rematch-name' => 'Source A' }, output['proxies'].last)
    group = output['proxy-groups'].first
    assert_equal 'Follow region', group['default-selected']
    assert_equal 'REJECT', group['empty-fallback']
    assert_equal false, group['lazy']
    assert_equal ['Follow region', 'Alpha | [A] Japan'], group['proxies']
    refute output['rules'].any? { |r| r.start_with?('REMATCH-NAME') }
    %w[surge singbox].each do |format|
      result = engine.render('main', format)
      assert_empty result['content']
      assert_includes result['errors'].join, 'rematch/shared-region'
    end
  end

  def test_cycle_through_rematch_and_subrule_is_blocked
    add_native_region_graph
    @config['rules'].last['policy'] = 'proxy'
    assert_includes engine.render('main', 'mihomo')['errors'].join, 'cycle'
    @config['rules'].last['policy'] = 'region'
    @config['sub_rules'].first['final_policy'] = 'follow'
    assert_includes engine.render('main', 'mihomo')['errors'].join, 'cycle'
  end

  def test_native_scope_and_missing_rematch_references_are_rejected
    add_native_region_graph
    @config['rematches'].first['target_sub_rule'] = 'missing'
    assert_includes engine.validate('main')['errors'].join, 'missing sub-rule'
    @config['rematches'].first['target_sub_rule'] = 'pick'
    @config['rules'].last.delete('sub_rule')
    assert_includes engine.validate('main')['errors'].join, 'only valid inside'
    @config['rules'].last['sub_rule'] = 'missing'
    assert_includes engine.validate('main')['errors'].join, 'missing sub-rule scope'
  end

  def test_recursive_rule_validation_and_geosite_compatibility
    @config['rules'][0] = { 'id' => 'nested', 'profile' => 'main', 'type' => 'OR', 'conditions' => [
      { 'type' => 'NOT', 'conditions' => [{ 'type' => 'GEOSITE', 'value' => 'category-games@cn' }] },
      { 'type' => 'DOMAIN', 'value' => 'example.test' }], 'policy' => 'DIRECT' }
    assert_includes assert_ok('mihomo')['content'], 'OR,((NOT,((GEOSITE,category-games@cn))),(DOMAIN,example.test)),DIRECT'
    assert_includes engine.render('surge', 'surge')['errors'].join, 'Unknown profile'
    assert_includes engine.render('main', 'surge')['errors'].join, 'GEOSITE'
    @config['rules'].first['conditions'].first['conditions'].first['policy'] = 'REJECT'
    assert_includes engine.render('main', 'mihomo')['errors'].join, 'nested condition cannot contain'
  end

  def test_logic_arity_and_depth_are_bounded
    @config['rules'][0] = { 'id' => 'nested', 'profile' => 'main', 'type' => 'NOT', 'conditions' => [], 'policy' => 'DIRECT' }
    assert_includes engine.render('main', 'mihomo')['errors'].join, 'NOT needs one'
    child = { 'type' => 'DOMAIN', 'value' => 'example.test' }
    10.times { child = { 'type' => 'NOT', 'conditions' => [child] } }
    @config['rules'].first.merge!(child)
    assert_includes engine.render('main', 'mihomo')['errors'].join, 'exceeds 8'
  end

  def test_inline_rules_are_preserved_inside_logic_and_block_lossy_exports
    @config['rule_sets'].first.merge!('source_type' => 'inline', 'behavior' => 'classical', 'inline_rules' => "# private local rules\nDOMAIN-SUFFIX,example.test\nIP-CIDR,192.0.2.0/24,no-resolve\n")
    @config['rules'][0] = { 'id' => 'inline-logic', 'profile' => 'main', 'type' => 'AND', 'conditions' => [{ 'type' => 'NETWORK', 'value' => 'UDP' }, { 'type' => 'RULE-SET', 'value' => 'domestic' }], 'policy' => 'REJECT' }
    output = YAML.safe_load(assert_ok('mihomo')['content'])
    assert_equal({ 'type' => 'inline', 'behavior' => 'classical', 'payload' => ['DOMAIN-SUFFIX,example.test', 'IP-CIDR,192.0.2.0/24,no-resolve'] }, output['rule-providers']['domestic'])
    assert_includes assert_ok('surge')['content'], 'AND,((PROTOCOL,UDP),(OR,((DOMAIN-SUFFIX,example.test),(IP-CIDR,192.0.2.0/24,no-resolve)))),REJECT'
    @config['rule_sets'].first['inline_rules'] = 'DOMAIN-SUFFIX,example.test,Proxy'
    assert_includes engine.render('main', 'mihomo')['errors'].join, 'cannot contain policies'
  end

  def test_dns_only_ruleset_and_safe_policy_are_preserved_without_listener
    @config['rules'].reject! { |r| r['type'] == 'RULE-SET' }
    @config['profiles'].first['mihomo_dns'] = { 'enable' => true, 'enhanced-mode' => 'fake-ip', 'nameserver' => ['https://dns.example.test/query'], 'fake-ip-filter' => ['rule-set:domestic', '+.qq.com'] }
    @config['profiles'].first['mihomo_policy'] = { 'geodata-mode' => true, 'geox-url' => { 'geosite' => 'https://example.test/geosite.dat' }, 'profile' => { 'store-selected' => true }, 'hosts' => { 'router.test' => '192.0.2.1' } }
    @config['rule_sets'].first['mihomo_proxy'] = 'DIRECT'
    output = YAML.safe_load(assert_ok('mihomo')['content'])
    assert_equal @config['profiles'].first['mihomo_dns'], output['dns']
    assert_equal 'DIRECT', output['rule-providers']['domestic']['proxy']
    assert_equal true, output['geodata-mode']
    refute output['dns'].key?('listen')
    preview = engine.render('main', 'mihomo', redact: true)['content']
    refute_includes preview, 'https://dns.example.test/query'
    refute_includes preview, '192.0.2.1'
    @config['profiles'].first['mihomo_dns']['listen'] = '0.0.0.0:53'
    assert_includes engine.render('main', 'mihomo')['errors'].join, 'listeners are managed separately'
    @config['profiles'].first.delete('mihomo_dns')
    @config['profiles'].first['mihomo_policy']['secret'] = 'forbidden'
    assert_includes engine.render('main', 'mihomo')['errors'].join, 'API, listener'
  end

  def test_unused_other_profile_ruleset_proxy_does_not_leak_scope
    @config['rule_sets'] << { 'id' => 'other-set', 'mihomo_proxy' => 'other-profile-group' }
    assert_equal [], engine.render('main', 'mihomo')['errors']
  end

  def test_editing_remote_ruleset_url_changes_cache_identity
    first = YAML.safe_load(assert_ok('mihomo')['content'])['rule-providers']['domestic']['path']
    @config['rule_sets'].first['mihomo_url'] = 'https://rules.example.test/revised.txt'
    second = YAML.safe_load(assert_ok('mihomo')['content'])['rule-providers']['domestic']['path']
    refute_equal first, second
    assert_match(%r{\A\./rule_provider/hybrid-domestic-[0-9a-f]{12}\.txt\z}, second)
  end

  def test_malformed_dns_is_a_validation_error_not_an_exception
    [[], 'invalid', { 'fake-ip-filter' => ['rule-set:missing'] }, { 'nameserver-policy' => [] }].each do |dns|
      @config['profiles'].first['mihomo_dns'] = dns
      result = engine.render('main', 'mihomo')
      refute_empty result['errors']
      assert_empty result['content']
    end
  end

  def test_region_definitions_do_not_change_output_until_group_opts_in
    before = %w[mihomo surge singbox].map { |format| assert_ok(format)['content'] }
    @config['regions'] = HybridSubscription::Regions.defaults
    @config['groups'].each { |group| group['region'] = '' }
    after = %w[mihomo surge singbox].map { |format| assert_ok(format)['content'] }
    assert_equal before, after
  end

  def test_region_matching_is_consistent_across_targets_and_ands_existing_filters
    @config['regions'] = HybridSubscription::Regions.defaults
    @caches['a']['nodes'] = %w[JP01 JP02 HK01].map { |name| @node.merge('name' => "#{name} premium") }
    @config['groups'].first.merge!('members' => [], 'region' => 'jp', 'filter' => 'premium', 'exclude_filter' => '02')
    mihomo = YAML.safe_load(assert_ok('mihomo')['content'])
    assert_equal ['Alpha | JP01 premium'], mihomo['proxy-groups'].first['proxies']
    surge = assert_ok('surge')['content']
    assert_includes surge, 'Proxy = select, Alpha | JP01 premium'
    refute_includes surge, 'Proxy = select, Alpha | JP02'
    singbox = JSON.parse(assert_ok('singbox')['content'])
    assert_equal ['Alpha | JP01 premium'], singbox['outbounds'].find { |outbound| outbound['tag'] == 'Proxy' }['outbounds']
    assert_equal 4, mihomo['proxies'].length
  end

  def test_region_uses_original_name_and_rejects_unknown_even_without_sources
    @config['regions'] = HybridSubscription::Regions.defaults
    @config['sources'].first['name'] = 'JP provider'
    @caches['a']['nodes'].first['name'] = 'Hong Kong'
    @config['groups'].first.merge!('members' => [], 'region' => 'jp')
    assert_includes engine.render('main', 'mihomo')['errors'].join, 'no members after filtering'
    @config['groups'].first.merge!('sources' => [], 'members' => ['DIRECT'], 'region' => 'unknown')
    assert_includes engine.render('main', 'mihomo')['errors'].join, 'unknown region'
  end

  def test_region_source_override_applies_in_engine
    @config['regions'] = [{ 'id' => 'jp', 'name' => 'Japan', 'pattern' => 'Japan', 'source_patterns' => { 'a' => '^Custom$' } }]
    @caches['a']['nodes'] = [@node.merge('name' => 'Custom'), @node.merge('name' => 'Japan')]
    @config['groups'].first.merge!('members' => [], 'region' => 'jp')
    output = YAML.safe_load(assert_ok('mihomo')['content'])
    assert_equal ['Alpha | Custom'], output['proxy-groups'].first['proxies']
  end

end
