# frozen_string_literal: true
require 'minitest/autorun'
require 'base64'
require_relative '../root/usr/share/hybrid-subscription/engine'

class ShadowrocketTest < Minitest::Test
  Engine = HybridSubscription::Engine
  UUID = '11111111-1111-4111-8111-111111111111'

  def setup
    @config = {
      'sources' => [{ 'id' => 'source', 'name' => 'Source' }],
      'profiles' => [{ 'id' => 'main', 'name' => 'Main', 'sources' => ['source'], 'formats' => ['shadowrocket'], 'final_policy' => 'proxy' }],
      'groups' => [{ 'id' => 'proxy', 'name' => 'Proxy', 'profile' => 'main', 'sources' => ['source'], 'members' => [], 'shadowrocket_type' => 'select' }],
      'rule_sets' => [], 'rules' => []
    }
    @node = { 'name' => 'Trojan', 'type' => 'trojan', 'server' => 'proxy.example.test', 'port' => 443,
              'password' => 'synthetic-secret', 'sni' => 'tls.example.test', 'skip-cert-verify' => false, 'udp' => true, 'tfo' => false }
    @caches = { 'source' => { 'nodes' => [@node] } }
  end

  def render(redact: false)
    Engine.new(@config, @caches).render('main', 'shadowrocket', redact: redact)
  end

  def success
    result = render
    assert_empty result['errors'], result['errors'].join('; ')
    result
  end

  def output
    YAML.safe_load(success['content'])
  end

  def blocked(text)
    result = render
    assert_empty result['content']
    assert_includes result['errors'].join('; '), text
    result
  end

  def rule(condition, policy = 'proxy')
    @config['rules'] << condition.merge('id' => "rule#{@config['rules'].length}", 'profile' => 'main', 'policy' => policy)
  end

  def test_full_yaml_keeps_nodes_groups_ordered_rules_and_final_policy
    rule('type' => 'DOMAIN-SUFFIX', 'value' => 'example.test')
    rule({ 'type' => 'DOMAIN', 'value' => 'direct.test' }, 'DIRECT')
    result = success
    assert_empty result['warnings']
    parsed = YAML.safe_load(result['content'])
    assert_equal %w[mode proxies proxy-groups rule-providers rules], parsed.keys
    assert_equal [@node.merge('name' => 'Source | Trojan')], parsed['proxies']
    assert_equal [{ 'name' => 'Proxy', 'type' => 'select', 'proxies' => ['Source | Trojan'] }], parsed['proxy-groups']
    assert_equal ['DOMAIN-SUFFIX,example.test,Proxy', 'DOMAIN,direct.test,DIRECT', 'MATCH,Proxy'], parsed['rules']
    assert_equal parsed['proxies'], Engine.import_nodes(result['content'], 'shadowrocket')
    assert_equal parsed['proxies'], Engine.import_nodes(result['content'])
    refute_includes result['content'], '[Proxy]'
  end

  def test_anytls_preserves_tls_credentials_and_session_settings
    @node.merge!('type' => 'anytls', 'tls' => true, 'alpn' => ['h2', 'http/1.1'], 'client-fingerprint' => 'chrome',
                 'reuse' => false, 'idle-session-check-interval' => 30, 'idle-session-timeout' => 30, 'min-idle-session' => 1)
    result = success
    node = YAML.safe_load(result['content'])['proxies'].first
    assert_equal @node.reject { |key, _| %w[name tls reuse].include?(key) }.merge('name' => 'Source | Trojan', 'disable-reuse' => true), node
    assert result['warnings'].any? { |warning| warning['code'] == 'shadowrocket:advanced-fields' }
    assert_equal @node['password'], node['password']
    assert_equal false, node['skip-cert-verify']
  end

  def test_all_seven_protocols_are_kept_instead_of_filtered
    @caches['source']['nodes'] = Engine::PROTOCOLS.map do |type|
      base = { 'name' => type, 'type' => type, 'server' => 'proxy.example.test', 'port' => 443, 'udp' => true }
      case type
      when 'ss' then base.merge('cipher' => 'aes-128-gcm', 'password' => 'synthetic')
      when 'vmess', 'vless' then base.merge('uuid' => UUID, 'tls' => true, 'sni' => 'tls.example.test')
      when 'tuic' then base.merge('uuid' => UUID, 'password' => 'synthetic', 'tfo' => false)
      else base.merge('password' => 'synthetic', 'tls' => true)
      end
    end
    nodes = output['proxies']
    assert_equal Engine::PROTOCOLS, nodes.map { |node| node['type'] }
    assert_equal 5, nodes.last['version']
    assert_equal false, nodes.last['fast-open']
    refute nodes.find { |node| node['type'] == 'anytls' }.key?('tls')
    assert_equal 'tls.example.test', nodes.find { |node| node['type'] == 'vless' }['servername']
  end

  def test_bad_node_blocks_entire_output_without_secrets
    @caches['source']['nodes'] << @node.merge('name' => 'Bad', 'type' => 'unknown', 'password' => 'do-not-print')
    result = blocked('unsupported proxy protocol')
    refute_includes result['errors'].join, 'do-not-print'
    @caches['source']['nodes'].last.merge!('type' => 'anytls', 'dialer-proxy' => 'private-reference')
    result = blocked('explicit policy reference mapping')
    refute_includes result['errors'].join, 'private-reference'
  end

  def test_conflicting_aliases_and_required_tls_are_rejected
    [
      ['conflicting TLS server names', { 'servername' => 'different.test' }],
      ['requires TLS', { 'tls' => false }],
      ['conflicting AnyTLS reuse', { 'type' => 'anytls', 'reuse' => false, 'disable-reuse' => false }],
      ['conflicting fast-open', { 'type' => 'hysteria2', 'tfo' => false, 'fast-open' => true }],
      ['reuse must be boolean', { 'type' => 'anytls', 'reuse' => 'false' }],
      ['conflicting certificate fingerprints', { 'tls-fingerprint' => 'private-one', 'fingerprint' => 'private-two' }]
    ].each do |message, options|
      @caches['source']['nodes'] = [@node.merge(options)]
      result = blocked(message)
      refute_includes result['errors'].join, 'private-one'
    end
  end

  def test_vmess_cipher_and_sni_normalization
    @node = { 'name' => 'VMess', 'type' => 'vmess', 'server' => 'vmess.example.test', 'port' => 443, 'uuid' => UUID,
              'cipher' => 'chacha20-ietf-poly1305', 'tls' => true, 'sni' => 'tls.example.test', 'aead' => true }
    @caches['source']['nodes'] = [@node]
    node = output['proxies'].first
    assert_equal 'chacha20-poly1305', node['cipher']
    assert_equal 0, node['alterId']
    assert_equal 'tls.example.test', node['servername']
    refute node.key?('sni')
    refute node.key?('aead')
    ['', '  '].each do |empty_cipher|
      @node['cipher'] = empty_cipher
      assert_equal 'auto', output['proxies'].first['cipher']
    end
    @node['cipher'] = 'private-invalid-cipher'
    result = blocked('unsupported VMess cipher')
    refute_includes result['errors'].join, @node['cipher']
  end

  def test_hysteria2_and_tuic_keep_quic_and_obfuscation_options
    @node.merge!('type' => 'hysteria2', 'obfs' => 'salamander', 'obfs-password' => 'synthetic-obfs', 'alpn' => ['h3'], 'up' => '50 Mbps', 'down' => '100 Mbps')
    node = output['proxies'].first
    assert_equal 'synthetic-obfs', node['obfs-password']
    assert_equal ['h3'], node['alpn']
    assert_equal false, node['fast-open']
    assert_equal '100 Mbps', node['down']
  end

  def test_shadowsocks_tls_and_plugin_mode_normalization
    @node.merge!('type' => 'ss', 'cipher' => 'aes-128-gcm', 'tls' => true)
    assert_equal 'tls.example.test', output['proxies'].first['servername']
    @node.merge!('plugin' => 'v2ray-plugin', 'plugin-opts' => { 'mode' => 'WebSocket', 'tls' => true })
    parsed = output['proxies'].first
    assert_equal 'websocket', parsed['plugin-opts']['mode']
    assert_equal false, parsed['plugin-opts']['skip-cert-verify']
    refute parsed.key?('servername')
    @node['plugin-opts'].delete('mode')
    blocked('unsupported v2ray-plugin mode')
  end

  def test_websocket_path_and_early_data_normalization
    @node.merge!('network' => 'ws', 'ws-opts' => { 'path' => '/proxy?a=1&ed=2048', 'headers' => { 'Host' => 'ws.example.test' } })
    opts = output['proxies'].first['ws-opts']
    assert_equal '/proxy?a=1', opts['path']
    assert_equal 2048, opts['max-early-data']
    assert_equal 'Sec-WebSocket-Protocol', opts['early-data-header-name']
    @node['ws-opts']['max-early-data'] = 100
    blocked('conflicting WebSocket early data')
  end

  def test_http_and_h2_shape_normalization_does_not_discard_alternate_paths
    @node.merge!('type' => 'vless', 'uuid' => UUID, 'tls' => true, 'network' => 'http', 'http-opts' => { 'path' => '/proxy', 'headers' => { 'Host' => 'http.example.test' } })
    assert_equal({ 'path' => ['/proxy'], 'headers' => { 'Host' => ['http.example.test'] } }, output['proxies'].first['http-opts'])
    @node.delete('http-opts')
    @node.merge!('network' => 'h2', 'h2-opts' => { 'path' => ['/proxy'], 'headers' => { 'Host' => 'http.example.test' } })
    assert_equal({ 'path' => '/proxy', 'host' => ['http.example.test'] }, output['proxies'].first['h2-opts'])
    @node['h2-opts']['path'] << '/other'
    blocked('multiple HTTP/2 paths')
  end

  def test_advanced_field_warnings_are_grouped_across_nodes
    @caches['source']['nodes'] = 16.times.map { |i| @node.merge('name' => "Node #{i}", 'client-fingerprint' => 'chrome') }
    result = success
    assert_equal 1, result['warnings'].length
    assert_equal 'shadowrocket:advanced-fields', result['warnings'].first['code']
    assert_equal '16 nodes contain advanced fields whose Shadowrocket behavior needs review: client-fingerprint. These fields are retained.', result['warnings'].first['message']
    assert_equal 16, YAML.safe_load(result['content'])['proxies'].length
  end

  def test_invalid_transport_option_objects_cannot_be_silently_erased
    [false, nil, 'private-options'].each do |opts|
      @node.merge!('network' => 'ws', 'ws-opts' => opts)
      result = blocked('transport options must be an object')
      refute_includes result['errors'].join, 'private-options'
    end
  end

  def test_invalid_nested_transport_fields_are_not_defaulted_away
    @node.merge!('type' => 'vless', 'uuid' => UUID, 'tls' => true, 'network' => 'h2', 'h2-opts' => { 'headers' => false })
    blocked('HTTP/2 headers must be an object')
    @node.delete('h2-opts')
    @node.merge!('network' => 'http', 'http-opts' => { 'headers' => false })
    blocked('HTTP headers must be an object')
    @node.delete('http-opts')
    @node.merge!('network' => 'ws', 'ws-opts' => { 'path' => false })
    blocked('WebSocket path must be text')
  end

  def test_reality_requires_enabled_tls_for_the_correct_protocol
    @node.merge!('reality-opts' => { 'public-key' => 'synthetic-key' })
    blocked('Reality requires VLESS or VMess')
    @node.merge!('type' => 'vless', 'uuid' => UUID, 'tls' => false)
    blocked('Reality requires enabled TLS')
  end

  def test_reality_and_unknown_advanced_fields_are_preserved_with_review_warning
    @node.merge!('type' => 'vless', 'uuid' => UUID, 'tls' => true, 'client-fingerprint' => 'chrome', 'flow' => 'xtls-rprx-vision',
                 'reality-opts' => { 'public-key' => 'synthetic-key', 'short-id' => 'abcd' }, 'future-option' => { 'secret' => 'synthetic-value' })
    result = success
    node = YAML.safe_load(result['content'])['proxies'].first
    assert_equal @node['reality-opts'], node['reality-opts']
    assert_equal @node['future-option'], node['future-option']
    assert_equal 1, result['warnings'].length
    assert_includes result['warnings'].first['message'], 'These fields are retained.'
    refute_includes result['warnings'].first['message'], 'synthetic-value'
  end

  def test_yaml_groups_report_unmapped_defaults_and_keep_health_checks
    group = @config['groups'].first
    group.merge!('members' => ['DIRECT'], 'default_member' => 'DIRECT', 'shadowrocket_type' => 'url-test',
                 'url' => 'https://test.example.test/204', 'interval' => 600, 'tolerance' => 100, 'hidden' => true, 'lazy' => true)
    result = success
    parsed = YAML.safe_load(result['content'])['proxy-groups'].first
    assert_equal({ 'name' => 'Proxy', 'type' => 'url-test', 'proxies' => ['DIRECT', 'Source | Trojan'], 'url' => 'https://test.example.test/204', 'interval' => 600, 'tolerance' => 100 }, parsed)
    assert result['warnings'].any? { |item| item['code'] == 'shadowrocket:hidden:proxy' }
    assert result['warnings'].any? { |item| item['code'].end_with?(':lazy') }
    assert result['warnings'].any? { |item| item['code'].end_with?(':default_member') }
    group['shadowrocket_type'] = 'smart'
    blocked('unsupported Shadowrocket type')
  end

  def test_direct_export_requires_acknowledgment_when_smart_becomes_manual
    @config['groups'].first['mihomo_type'] = 'smart'
    expected = 'Group Proxy: shadowrocket mode select differs from or cannot guarantee Mihomo smart behavior; review a manual or simpler automatic alternative'
    warning = success['warnings'].find { |item| item['code'] == 'shadowrocket:group:proxy' }
    assert_equal expected, warning['message']
    validation = Engine.new(@config, @caches).validate('main')
    assert_empty validation['errors']
    assert_includes validation['warnings'], warning
  end

  def test_remote_sets_use_explicit_classical_yaml_url_without_changing_other_clients
    @config['rule_sets'] << { 'id' => 'domains', 'behavior' => 'domain', 'surge_url' => 'https://surge.example.test/domains.list', 'interval' => 600 }
    rule('type' => 'RULE-SET', 'value' => 'domains')
    blocked('Shadowrocket: HTTP(S) URL required')
    @config['rule_sets'].first['shadowrocket_url'] = 'https://rocket.example.test/classical.yaml'
    parsed = output
    provider = parsed['rule-providers']['domains']
    assert_equal 'classical', provider['behavior']
    assert_equal 'http', provider['type']
    assert_equal 'https://rocket.example.test/classical.yaml', provider['url']
    assert_match(/\.yaml\z/, provider['path'])
    assert_equal 600, provider['interval']
    assert_equal ['RULE-SET,domains,Proxy', 'MATCH,Proxy'], parsed['rules']
    assert_equal 'domain', @config['rule_sets'].first['behavior']
  end

  def test_nested_rules_reference_provider_id_not_url_or_native_syntax
    @config['rule_sets'] << { 'id' => 'remote', 'shadowrocket_url' => 'https://rules.example.test/a)b.yaml' }
    rule('type' => 'AND', 'conditions' => [{ 'type' => 'NETWORK', 'value' => 'UDP' }, { 'type' => 'RULE-SET', 'value' => 'remote' }])
    assert_equal 'AND,((NETWORK,udp),(RULE-SET,remote)),Proxy', output['rules'].first
  end

  def test_inline_conditions_keep_order_and_no_resolve_without_inline_providers
    @config['rule_sets'] << { 'id' => 'local', 'source_type' => 'inline', 'behavior' => 'classical', 'inline_rules' => "DOMAIN,example.test\nIP-CIDR,192.0.2.0/24\n" }
    rule({ 'type' => 'AND', 'conditions' => [{ 'type' => 'NETWORK', 'value' => 'UDP' }, { 'type' => 'DST-PORT', 'value' => '443' }, { 'type' => 'RULE-SET', 'value' => 'local', 'no_resolve' => true }] }, 'REJECT')
    parsed = output
    assert_equal({}, parsed['rule-providers'])
    assert_equal 'AND,((NETWORK,udp),(DST-PORT,443),(OR,((DOMAIN,example.test),(IP-CIDR,192.0.2.0/24,no-resolve)))),REJECT', parsed['rules'].first
  end

  def test_lan_expands_to_explicit_ranges_with_behavior_warning
    rule({ 'type' => 'GEOIP', 'value' => 'LAN', 'no_resolve' => true }, 'DIRECT')
    result = success
    rules = YAML.safe_load(result['content'])['rules']
    assert_includes rules.first, '(IP-CIDR,192.168.0.0/16,no-resolve)'
    assert_includes rules.first, '(IP-CIDR6,fc00::/7,no-resolve)'
    assert rules.first.end_with?(',DIRECT')
    refute_includes rules.first, 'GEOIP,LAN'
    assert result['warnings'].any? { |item| item['code'] == 'shadowrocket:lan:rule0' }
  end

  def test_policy_collisions_and_invalid_routing_still_block_full_profile
    @config['groups'] << @config['groups'].first.merge('id' => 'other', 'name' => 'PROXY')
    blocked('unique ignoring case')
    @config['groups'].pop
    @config['profiles'].first['final_policy'] = 'missing'
    blocked('Missing policy reference')
  end

  def test_native_mihomo_features_cannot_be_silently_dropped
    @config['profiles'].first['mihomo_dns'] = { 'nameserver' => ['system'] }
    blocked('native Mihomo DNS policy')
    @config['profiles'].first.delete('mihomo_dns')
    rule('type' => 'GEOSITE', 'value' => 'cn')
    blocked('GEOSITE')
  end

  def test_yaml_quotes_credentials_and_preserves_nested_multiline_values
    @node['password'] = 'private,colon: "quoted" \\ secret'
    @node['future-option'] = { 'private' => "multiline\nsecret\tvalue" }
    parsed = output
    assert_equal @node['password'], parsed['proxies'].first['password']
    result = render(redact: true)
    assert_empty result['errors']
    preview = YAML.safe_load(result['content'])['proxies'].first
    assert_equal '[REDACTED]', preview['password']
    assert_equal '[REDACTED]', preview['future-option']['private']
    refute_includes result['content'], 'multiline'
    refute_includes result['content'], 'quoted'
  end

  def test_uri_base64_yaml_and_existing_native_import_remain_supported
    uri = 'anytls://synthetic@proxy.example.test:443?sni=tls.example.test#AnyTLS'
    [uri, Base64.strict_encode64(uri), YAML.dump('proxies' => [@node])].each do |input|
      assert_equal Engine.import_nodes(input), Engine.import_nodes(input, 'shadowrocket')
    end
    native = "# Hybrid Subscription: Shadowrocket\n[Proxy]\nNative = trojan, proxy.example.test, 443, password=synthetic, peer=tls.example.test, udp=1\n"
    assert_equal Engine.import_nodes(native, 'shadowrocket'), Engine.import_nodes(native)
    assert_equal 'trojan', Engine.import_nodes(native).first['type']
  end

  def test_native_import_keeps_strict_boolean_and_duplicate_option_guards
    [
      'trojan, proxy.example.test, 443, password=synthetic',
      'trojan, proxy.example.test, 443, password=synthetic, udp=perhaps',
      'trojan, proxy.example.test, 443, password=first, password=second, udp=1'
    ].each do |definition|
      assert_raises(HybridSubscription::Error) { Engine.import_nodes("[Proxy]\nExample = #{definition}\n", 'shadowrocket') }
    end
  end

  def test_native_detection_does_not_parse_markers_inside_surge_password
    native = "[Proxy]\nNative = trojan, proxy.example.test, 443, password=\"synthetic,peer=example\", udp-relay=true\n"
    assert_equal 'synthetic,peer=example', Engine.import_nodes(native).first['password']
  end

  def test_unsafe_yaml_aliases_and_unknown_protocols_remain_rejected
    ['proxies: &a [*a]', YAML.dump('proxies' => [@node.merge('type' => 'unknown')])].each do |input|
      assert_raises(HybridSubscription::Error) { Engine.import_nodes(input, 'shadowrocket') }
    end
  end
end
