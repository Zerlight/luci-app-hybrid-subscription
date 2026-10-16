# frozen_string_literal: true
require 'minitest/autorun'
require 'json'
require_relative '../root/usr/share/hybrid-subscription/engine'

class PortabilityTest < Minitest::Test
  Engine = HybridSubscription::Engine

  def setup
    @config = {
      'sources' => [{ 'id' => 'source', 'name' => 'Source' }],
      'profiles' => [{ 'id' => 'main', 'name' => 'Main', 'sources' => ['source'], 'formats' => Engine::FORMATS, 'final_policy' => 'DIRECT' }],
      'groups' => [{ 'id' => 'proxy', 'name' => 'Proxy', 'profile' => 'main', 'sources' => ['source'], 'members' => [] }],
      'rule_sets' => [], 'rules' => []
    }
    @caches = { 'source' => { 'nodes' => [{ 'name' => 'Node', 'type' => 'trojan', 'server' => 'proxy.example.test', 'port' => 443, 'password' => 'synthetic-secret', 'udp' => true }] } }
  end

  def rule(condition, policy = 'proxy')
    @config['rules'] << condition.merge('id' => "rule#{@config['rules'].length}", 'profile' => 'main', 'policy' => policy)
  end

  def inline(text)
    @config['rule_sets'] << { 'id' => 'local', 'source_type' => 'inline', 'behavior' => 'classical', 'inline_rules' => text }
  end

  def render(format)
    Engine.new(@config, @caches).render('main', format)
  end

  def success(format)
    result = render(format)
    assert_empty result['errors'], result['errors'].join('; ')
    result
  end

  def blocked(format, message)
    result = render(format)
    assert_empty result['content']
    assert_includes result['errors'].join('; '), message
  end

  def test_nested_logical_rules_keep_boolean_structure_and_parent_action
    rule({ 'type' => 'AND', 'conditions' => [
      { 'type' => 'OR', 'conditions' => [{ 'type' => 'DOMAIN', 'value' => 'example.test' }, { 'type' => 'DOMAIN-SUFFIX', 'value' => 'video.test' }] },
      { 'type' => 'NOT', 'conditions' => [{ 'type' => 'NETWORK', 'value' => 'UDP' }] },
      { 'type' => 'DST-PORT', 'value' => '443' }
    ] }, 'REJECT')
    assert_includes success('surge')['content'], 'AND,((OR,((DOMAIN,example.test),(DOMAIN-SUFFIX,video.test))),(NOT,((PROTOCOL,UDP))),(DEST-PORT,443)),REJECT'
    native = JSON.parse(success('singbox')['content']).dig('route', 'rules').first
    assert_equal 'reject', native.delete('action')
    expected = { 'type' => 'logical', 'mode' => 'and', 'rules' => [
      { 'type' => 'logical', 'mode' => 'or', 'rules' => [{ 'domain' => ['example.test'] }, { 'domain_suffix' => ['video.test'] }] },
      { 'type' => 'logical', 'mode' => 'and', 'rules' => [{ 'network' => 'udp' }], 'invert' => true },
      { 'port' => [443] }
    ] }
    assert_equal expected, native
    %w[example.test a.video.test unrelated.test].product(%w[tcp udp], [80, 443]).each do |domain, network, port|
      expected_match = (domain == 'example.test' || domain.end_with?('.video.test')) && network != 'udp' && port == 443
      assert_equal expected_match, native_match(native, domain, network, port), [domain, network, port].inspect
    end
  end

  def native_match(rule, domain, network, port)
    match = if rule['type'] == 'logical'
              children = rule['rules'].map { |child| native_match(child, domain, network, port) }
              rule['mode'] == 'and' ? children.all? : children.any?
            elsif rule['domain']
              rule['domain'].include?(domain)
            elsif rule['domain_suffix']
              rule['domain_suffix'].any? { |suffix| domain == suffix || domain.end_with?(".#{suffix}") }
            elsif rule['network']
              rule['network'] == network
            else
              rule['port'].include?(port)
            end
    rule['invert'] ? !match : match
  end

  def test_surge_keeps_no_resolve_in_the_right_place_at_each_depth
    rule({ 'type' => 'IP-CIDR', 'value' => '192.0.2.0/24', 'no_resolve' => true })
    rule({ 'type' => 'NOT', 'conditions' => [{ 'type' => 'IP-CIDR6', 'value' => '2001:db8::/32', 'no_resolve' => true }] }, 'REJECT')
    content = success('surge')['content']
    assert_includes content, 'IP-CIDR,192.0.2.0/24,Proxy,no-resolve'
    assert_includes content, 'NOT,((IP-CIDR6,2001:db8::/32,no-resolve)),REJECT'
  end

  def test_surge_expands_inline_sets_as_or_inside_logical_rules
    inline("DOMAIN-SUFFIX,example.test\nIP-CIDR,192.0.2.0/24,no-resolve\n")
    rule({ 'type' => 'AND', 'conditions' => [{ 'type' => 'NETWORK', 'value' => 'UDP' }, { 'type' => 'RULE-SET', 'value' => 'local' }] })
    assert_includes success('surge')['content'], 'AND,((PROTOCOL,UDP),(OR,((DOMAIN-SUFFIX,example.test),(IP-CIDR,192.0.2.0/24,no-resolve)))),Proxy'
    blocked('singbox', 'no-resolve')
  end

  def test_surge_inherits_ruleset_no_resolve_only_on_ip_conditions
    inline("DOMAIN,example.test\nIP-CIDR,192.0.2.0/24\nIP-CIDR6,2001:db8::/32\n")
    rule({ 'type' => 'RULE-SET', 'value' => 'local', 'no_resolve' => true })
    assert_includes success('surge')['content'], 'OR,((DOMAIN,example.test),(IP-CIDR,192.0.2.0/24,no-resolve),(IP-CIDR6,2001:db8::/32,no-resolve)),Proxy'
    blocked('singbox', 'no-resolve')
  end

  def test_single_inline_leaf_preserves_policy_and_resolve_option
    inline('IP-CIDR,192.0.2.0/24,no-resolve')
    rule({ 'type' => 'RULE-SET', 'value' => 'local' })
    assert_includes success('surge')['content'], 'IP-CIDR,192.0.2.0/24,Proxy,no-resolve'
  end

  def test_singbox_inline_sets_keep_disjunction_and_headless_rules
    inline("DOMAIN,example.test\nNETWORK,UDP\nDST-PORT,443\n")
    rule({ 'type' => 'NOT', 'conditions' => [{ 'type' => 'RULE-SET', 'value' => 'local' }] })
    output = JSON.parse(success('singbox')['content'])
    assert_equal [{ 'type' => 'inline', 'tag' => 'local', 'rules' => [{ 'domain' => ['example.test'] }, { 'network' => 'udp' }, { 'port' => [443] }] }], output.dig('route', 'rule_set')
    assert_equal({ 'type' => 'logical', 'mode' => 'and', 'rules' => [{ 'rule_set' => ['local'] }], 'invert' => true, 'action' => 'route', 'outbound' => 'Proxy' }, output.dig('route', 'rules').first)
  end

  def test_singbox_blocks_no_resolve_at_the_top_and_inside_logic
    rule({ 'type' => 'IP-CIDR', 'value' => '192.0.2.0/24', 'no_resolve' => true })
    blocked('singbox', 'no-resolve')
    @config['rules'].clear
    rule({ 'type' => 'NOT', 'conditions' => [{ 'type' => 'IP-CIDR', 'value' => '192.0.2.0/24', 'no_resolve' => true }] })
    blocked('singbox', 'no-resolve')
  end

  def test_inline_geodata_cannot_bypass_compatibility_checks
    inline('GEOSITE,category-games')
    rule({ 'type' => 'RULE-SET', 'value' => 'local' })
    %w[surge singbox].each { |format| blocked(format, 'GEOSITE') }
    @config['rule_sets'].first['inline_rules'] = 'GEOIP,LAN'
    success('surge')
    blocked('singbox', 'inline rule sets do not support GEOIP LAN')
    @config['rule_sets'].first['inline_rules'] = 'GEOIP,CN'
    blocked('singbox', 'removed GEOIP')
  end

  def test_inline_sources_validate_consistently_and_only_when_used
    inline('DOMAIN,example.test,Proxy')
    rule({ 'type' => 'RULE-SET', 'value' => 'local' })
    Engine::FORMATS.each { |format| blocked(format, 'cannot contain policies') }
    @config['rule_sets'].first['inline_rules'] = 'DOMAIN,example.test'
    @config['rule_sets'].first['behavior'] = 'domain'
    Engine::FORMATS.each { |format| blocked(format, 'require classical') }
    @config['rules'].first['enabled'] = false
    Engine::FORMATS.each { |format| success(format) }
  end

  def test_nested_remote_set_preserves_target_url_kind_options_and_quoting
    @config['rule_sets'] << { 'id' => 'remote', 'behavior' => 'domain', 'surge_url' => 'https://rules.example.test/(domains).txt', 'interval' => 600 }
    rule({ 'type' => 'AND', 'conditions' => [{ 'type' => 'NETWORK', 'value' => 'TCP' }, { 'type' => 'RULE-SET', 'value' => 'remote', 'no_resolve' => true }] })
    assert_includes success('surge')['content'], 'AND,((PROTOCOL,TCP),(DOMAIN-SET,"https://rules.example.test/(domains).txt",no-resolve,update-interval=600)),Proxy'
  end

  def test_ip_mapping_reports_singbox_dns_semantic_difference
    inline('IP-CIDR,192.0.2.0/24')
    rule({ 'type' => 'RULE-SET', 'value' => 'local' })
    result = success('singbox')
    assert result['warnings'].any? { |item| item['code'].include?('dns-match:') && item['message'].include?('does not automatically resolve') }
    assert_equal [{ 'ip_cidr' => ['192.0.2.0/24'] }], JSON.parse(result['content']).dig('route', 'rule_set').first['rules']
  end

  def test_rendering_does_not_mutate_shared_inline_set_or_logical_tree
    inline("DOMAIN,example.test\nIP-CIDR,192.0.2.0/24\n")
    rule({ 'type' => 'RULE-SET', 'value' => 'local', 'no_resolve' => true })
    before = Engine.copy(@config)
    first = success('surge')['content']
    assert_equal first, success('surge')['content']
    assert_equal before, @config
    success('mihomo')
  end

  def test_surge_reports_native_test_url_difference_for_automatic_groups
    @config['groups'].first['url'] = 'https://check.example.test/generate_204'
    %w[url-test fallback load-balance].each do |type|
      @config['groups'].first['surge_type'] = type
      result = success('surge')
      assert result['warnings'].any? { |item| item['code'] == 'surge:group-test-url:proxy' && item['message'].include?('does not preserve this per-group health-check URL') }
      refute_includes result['content'], 'proxy-test-url ='
      refute_includes result['content'], 'internet-test-url ='
    end
    @config['groups'].first['surge_type'] = 'select'
    refute success('surge')['warnings'].any? { |item| item['code'] == 'surge:group-test-url:proxy' }
  end
end
