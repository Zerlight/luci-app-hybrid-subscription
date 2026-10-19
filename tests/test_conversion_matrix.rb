# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../root/usr/share/hybrid-subscription/engine'

class ConversionMatrixTest < Minitest::Test
  Engine = HybridSubscription::Engine
  UUID = '11111111-1111-4111-8111-111111111111'

  def nodes
    base = { 'server' => 'proxy.example.test', 'port' => 443, 'tfo' => true, 'udp' => true }
    tls = { 'sni' => 'tls.example.test', 'skip-cert-verify' => false, 'alpn' => ['h2', 'http/1.1'] }
    [
      base.merge(tls).merge('name' => 'AnyTLS', 'type' => 'anytls', 'password' => 'synthetic,quoted="password"'),
      base.merge(tls).merge('name' => 'Trojan WS', 'type' => 'trojan', 'password' => 'synthetic', 'network' => 'ws', 'ws-opts' => { 'path' => '/proxy', 'headers' => { 'Host' => 'ws.example.test' } }),
      base.merge('name' => 'SS', 'type' => 'ss', 'cipher' => 'aes-128-gcm', 'password' => 'synthetic', 'udp' => true),
      base.merge(tls).merge('name' => 'VMess WS', 'type' => 'vmess', 'uuid' => UUID, 'cipher' => 'aes-128-gcm', 'alterId' => 0, 'tls' => true, 'network' => 'ws', 'ws-opts' => { 'path' => '/vmess' }),
      base.merge(tls).merge('name' => 'HY2', 'type' => 'hysteria2', 'password' => 'synthetic', 'down' => 100, 'obfs' => 'salamander', 'obfs-password' => 'synthetic-obfs'),
      base.merge(tls).merge('name' => 'TUIC v5', 'type' => 'tuic', 'uuid' => UUID, 'password' => 'synthetic')
    ]
  end

  def render(imported, format)
    config = {
      'sources' => [{ 'id' => 'imported', 'name' => 'Imported', 'enabled' => true }],
      'profiles' => [{ 'id' => 'main', 'name' => 'Conversion', 'sources' => ['imported'], 'formats' => Engine::FORMATS, 'final_policy' => 'proxy' }],
      'groups' => [{ 'id' => 'proxy', 'name' => 'Proxy', 'profile' => 'main', 'sources' => ['imported'], 'members' => [] }]
    }
    Engine.new(config, 'imported' => { 'nodes' => imported }).render('main', format)
  end

  def comparable(imported)
    imported.map do |node|
      copy = Engine.copy(node)
      copy['name'] = copy['name'].sub(/\A(?:Imported \| )+/, '')
      copy['down'] = copy['down'].to_i if copy.key?('down')
      copy['sni'] = copy.delete('servername') if copy.key?('servername')
      copy
    end
  end

  def test_every_source_format_converts_to_every_target_with_common_node_fields_preserved
    %w[mihomo surge singbox].each do |source|
      source_result = render(nodes, source)
      assert_empty source_result['errors'], source
      assert_empty source_result['warnings'], source
      explicit = Engine.import_nodes(source_result['content'], source)
      assert_equal explicit, Engine.import_nodes(source_result['content']), "#{source} auto detection"
      assert_equal nodes, comparable(explicit), "#{source} import"

      %w[mihomo surge singbox].each do |target|
        result = render(explicit, target)
        assert_empty result['errors'], "#{source} -> #{target}: #{result['errors'].join('; ')}"
        assert_empty result['warnings'], "#{source} -> #{target}"
        assert_equal nodes, comparable(Engine.import_nodes(result['content'], target)), "#{source} -> #{target}"
      end
    end
  end

  def test_surge_gecko_output_can_be_reimported_and_unsupported_target_stays_blocked
    original = nodes.find { |n| n['type'] == 'hysteria2' }.merge('obfs' => 'gecko')
    result = render([original], 'surge')
    assert_empty result['errors']
    assert_equal [original], comparable(Engine.import_nodes(result['content'], 'surge'))
    rejected = render([original], 'singbox')
    refute_empty rejected['errors']
    assert_empty rejected['content']
  end

  def test_four_client_matrix_preserves_common_tcp_nodes
    base = {'server'=>'proxy.example.test', 'port'=>443, 'udp'=>true, 'tfo'=>true}
    tls = {'sni'=>'tls.example.test', 'skip-cert-verify'=>false}
    originals = [
      base.merge('name'=>'SS', 'type'=>'ss', 'cipher'=>'aes-128-gcm', 'password'=>'synthetic'),
      base.merge(tls).merge('name'=>'Trojan', 'type'=>'trojan', 'password'=>'synthetic')
    ]
    Engine::FORMATS.each do |source|
      source_result = render(originals, source)
      assert_empty source_result['errors'], source
      assert_empty source_result['warnings'], source
      imported = Engine.import_nodes(source_result['content'], source)
      assert_equal imported, Engine.import_nodes(source_result['content']), "#{source} auto detection"
      assert_equal originals, comparable(imported), "#{source} import"
      Engine::FORMATS.each do |target|
        result = render(imported, target)
        assert_empty result['errors'], "#{source} -> #{target}"
        assert_empty result['warnings'], "#{source} -> #{target}"
        assert_equal originals, comparable(Engine.import_nodes(result['content'], target)), "#{source} -> #{target} import"
      end
    end
  end

  def test_shadowrocket_vless_preserves_tcp_tls_across_supported_formats
    original = {'name'=>'VLESS', 'type'=>'vless', 'server'=>'proxy.example.test', 'port'=>443, 'uuid'=>UUID, 'udp'=>true, 'tls'=>true, 'sni'=>'tls.example.test', 'skip-cert-verify'=>false}
    %w[mihomo singbox shadowrocket].each do |source|
      imported = Engine.import_nodes(render([original], source)['content'], source)
      %w[mihomo singbox shadowrocket].each do |target|
        result = render(imported, target)
        assert_empty result['errors']
        assert_empty result['warnings']
        assert_equal [original], comparable(Engine.import_nodes(result['content'], target))
      end
    end
  end

  def test_shadowrocket_vmess_auto_preserves_cipher_without_rewriting
    original = {'name'=>'VMess', 'type'=>'vmess', 'server'=>'proxy.example.test', 'port'=>443, 'uuid'=>UUID, 'udp'=>true, 'tls'=>true, 'cipher'=>'auto', 'alterId'=>0}
    %w[mihomo singbox shadowrocket].each do |source|
      imported = Engine.import_nodes(render([original], source)['content'], source)
      %w[mihomo singbox shadowrocket].each do |target|
        result = render(imported, target)
        assert_empty result['errors']
        assert_empty result['warnings']
        assert_equal [original], comparable(Engine.import_nodes(result['content'], target))
      end
    end
  end

  def test_surge_duplicate_options_are_rejected_instead_of_overwritten
    [
      'trojan, proxy.example.test, 443, password=first, password=second',
      "vmess, proxy.example.test, 443, username=#{UUID}, uuid=#{UUID}, vmess-aead=true",
      'trojan, proxy.example.test, 443, password=synthetic, ws=true, ws-headers=Host:first|host:second'
    ].each do |definition|
      assert_raises(HybridSubscription::Error) { Engine.import_nodes("[Proxy]\nExample = #{definition}\n", 'surge') }
    end
  end

  def test_surge_conflicting_obfuscation_and_implicit_legacy_vmess_are_rejected
    assert_raises(HybridSubscription::Error) do
      Engine.import_nodes("[Proxy]\nExample = hysteria2, proxy.example.test, 443, password=synthetic, salamander-password=first, gecko-password=second\n", 'surge')
    end
    assert_raises(HybridSubscription::Error) do
      Engine.import_nodes("[Proxy]\nExample = vmess, proxy.example.test, 443, username=#{UUID}\n", 'surge')
    end
    imported = Engine.import_nodes("[Proxy]\nExample = vmess, proxy.example.test, 443, username=#{UUID}, vmess-aead=true\n", 'surge')
    assert_equal 'aes-128-gcm', imported.first['cipher']
    assert_equal true, imported.first['udp']
  end

  def test_singbox_tuic_heartbeat_is_preserved_through_mihomo
    original = nodes.find { |n| n['type'] == 'tuic' }.merge('heartbeat-interval' => 5000)
    result = render([original], 'singbox')
    assert_empty result['errors']
    assert_empty result['warnings']
    assert_equal [original], comparable(Engine.import_nodes(result['content'], 'singbox'))
    input = JSON.parse(result['content'])
    input['outbounds'].find { |n| n['type'] == 'tuic' }['heartbeat'] = '5s'
    assert_equal [original], comparable(Engine.import_nodes(JSON.generate(input), 'singbox'))
  end

  def test_singbox_http2_transport_output_can_be_reimported
    original = nodes.find { |n| n['type'] == 'vmess' }.reject { |k, _| k == 'ws-opts' }.merge(
      'network' => 'h2', 'h2-opts' => { 'path' => '/proxy', 'host' => ['http.example.test'] }
    )
    result = render([original], 'singbox')
    assert_empty result['errors']
    assert_empty result['warnings']
    assert_equal [original], comparable(Engine.import_nodes(result['content'], 'singbox'))
  end

  def test_singbox_plain_http_transport_preserves_mihomo_array_paths_and_headers
    original = { 'name' => 'HTTP VMess', 'type' => 'vmess', 'server' => 'proxy.example.test', 'port' => 80, 'uuid' => UUID,
                 'cipher' => 'aes-128-gcm', 'alterId' => 0, 'udp' => false, 'network' => 'http',
                 'http-opts' => { 'path' => ['/proxy'], 'headers' => { 'X-Test' => ['synthetic'] }, 'method' => 'GET' } }
    result = render([original], 'singbox')
    assert_empty result['errors']
    assert_empty result['warnings']
    assert_equal [original], comparable(Engine.import_nodes(result['content'], 'singbox'))
  end

  def test_import_and_export_preserve_different_udp_defaults
    input = { 'type' => 'shadowsocks', 'tag' => 'SS', 'server' => 'proxy.example.test', 'server_port' => 443,
              'method' => 'aes-128-gcm', 'password' => 'synthetic' }
    imported = Engine.import_nodes(JSON.generate('outbounds' => [input]), 'singbox')
    assert_equal true, imported.first['udp']
    assert_includes render(imported, 'surge')['content'], 'udp-relay=true'

    input['network'] = 'tcp'
    imported = Engine.import_nodes(JSON.generate('outbounds' => [input]), 'singbox')
    assert_equal false, imported.first['udp']
    assert_includes render(imported, 'surge')['content'], 'udp-relay=false'

    implicit_mihomo = imported.first.reject { |key, _| key == 'udp' }
    output = JSON.parse(render([implicit_mihomo], 'singbox')['content'])
    assert_equal 'tcp', output['outbounds'].find { |node| node['type'] == 'shadowsocks' }['network']
    input['network'] = 'udp'
    assert_raises(HybridSubscription::Error) { Engine.import_nodes(JSON.generate('outbounds' => [input]), 'singbox') }
  end

  def test_vless_reality_and_grpc_preserve_their_supported_fields
    original = { 'name' => 'VLESS', 'type' => 'vless', 'server' => 'proxy.example.test', 'port' => 443, 'uuid' => UUID, 'udp' => true,
                 'tls' => true, 'sni' => 'tls.example.test', 'client-fingerprint' => 'chrome',
                 'reality-opts' => { 'public-key' => 'synthetic-public-key', 'short-id' => 'abcd' },
                 'network' => 'grpc', 'grpc-opts' => { 'grpc-service-name' => 'proxy' } }
    %w[mihomo singbox].each do |source|
      imported = Engine.import_nodes(render([original], source)['content'], source)
      %w[mihomo singbox].each do |target|
        result = render(imported, target)
        assert_empty result['errors']
        assert_empty result['warnings']
        assert_equal [original], comparable(Engine.import_nodes(result['content'], target))
      end
      rejected = render(imported, 'surge')
      refute_empty rejected['errors']
      assert_empty rejected['content']
    end
  end

  def test_unknown_singbox_options_at_each_supported_nesting_level_are_rejected
    base = { 'type' => 'trojan', 'tag' => 'Example', 'server' => 'proxy.example.test', 'server_port' => 443, 'password' => 'synthetic' }
    variants = [
      { 'future_option' => 'private-value' },
      { 'tls' => { 'enabled' => true, 'future_option' => 'private-value' } },
      { 'tls' => { 'utls' => { 'enabled' => true, 'fingerprint' => 'chrome', 'future_option' => 'private-value' } } },
      { 'tls' => { 'reality' => { 'enabled' => true, 'public_key' => 'key', 'future_option' => 'private-value' } } },
      { 'transport' => { 'type' => 'ws', 'future_option' => 'private-value' } },
      { 'transport' => { 'type' => 'grpc', 'future_option' => 'private-value' } },
      { 'transport' => { 'type' => 'http', 'future_option' => 'private-value' } },
      { 'obfs' => { 'type' => 'salamander', 'password' => 'synthetic', 'future_option' => 'private-value' } }
    ]
    variants.each do |variant|
      error = assert_raises(HybridSubscription::Error) { Engine.import_nodes(JSON.generate('outbounds' => [base.merge(variant)]), 'singbox') }
      refute_includes error.message, 'private-value'
    end
  end

  def test_invalid_proxy_does_not_return_a_partial_subscription
    %w[mihomo surge singbox].each do |format|
      result = render(nodes, format)
      content = case format
                when 'mihomo'
                  parsed = YAML.safe_load(result['content'])
                  parsed['proxies'] << { 'name' => 'Invalid', 'type' => 'unknown' }
                  YAML.dump(parsed)
                when 'surge'
                  result['content'].sub('[Proxy]', "[Proxy]\nInvalid = unknown, proxy.example.test, 443")
                else
                  parsed = JSON.parse(result['content'])
                  parsed['outbounds'] << { 'tag' => 'Invalid', 'type' => 'unknown' }
                  JSON.generate(parsed)
                end
      assert_raises(HybridSubscription::Error, format) { Engine.import_nodes(content, format) }
    end
  end
end
