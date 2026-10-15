# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../root/usr/share/hybrid-subscription/converter'

class ConverterTest < Minitest::Test
  Converter = HybridSubscription::Converter
  def node
    { 'name' => 'Synthetic', 'type' => 'anytls', 'server' => 'proxy.example.test', 'port' => 443, 'password' => 'very-secret', 'client-fingerprint' => 'chrome' }
  end

  def test_diff_reports_field_names_not_values
    changed = node.merge('password' => 'another-secret').reject { |k, _| k == 'client-fingerprint' }
    result = Converter.diff([node], [changed])
    assert_equal false, result['equal']
    assert_equal ['client-fingerprint', 'password'], result['differences'].first['fields']
    refute_includes result.to_s, 'very-secret'
    refute_includes result.to_s, 'another-secret'
  end

  def test_diff_sees_missing_added_and_nested_options
    original = node.merge('ws-opts' => { 'headers' => { 'Authorization' => 'secret-a' } })
    result = Converter.diff([original, node.merge('name' => 'Missing')], [original.merge('ws-opts' => { 'headers' => { 'Authorization' => 'secret-b' } }), node.merge('name' => 'Added')])
    assert_equal %w[added missing changed], result['differences'].map { |d| d['kind'] }
    assert_includes result['differences'].last['fields'], 'ws-opts.headers.Authorization'
    refute_includes result.to_s, 'secret-a'
    refute_includes result.to_s, 'secret-b'
  end

  def test_diff_is_order_independent_but_rejects_duplicate_names
    a, b = node, node.merge('name' => 'B')
    assert_equal true, Converter.diff([a, b], [b, a])['equal']
    assert_raises(HybridSubscription::Error) { Converter.diff([a, a], [a]) }
  end

  def test_converter_requires_numeric_loopback_without_url_credentials
    %w[http://example.test:25500 http://localhost:25500 http://192.0.2.1:25500 file:///tmp/input http://u:p@127.0.0.1:25500 http://127.0.0.1:25500/?token=secret].each do |url|
      assert_raises(HybridSubscription::Error) { Converter.new(url) }
    end
    assert Converter.new('http://127.0.0.1:25500')
    assert Converter.new('http://[::1]:25500')
  end

  class FakeConverter < Converter
    attr_reader :served_url, :bad_path_status, :method_status
    private
    def request(url, _timeout, _limit)
      return 'subconverter v0.9.9 backend' if url.end_with?('/version')
      query = URI.decode_www_form(URI.parse(url).query).to_h
      @served_url = query['url']
      uri = URI.parse(@served_url)
      @bad_path_status = local_get(uri, '/wrong').lines.first
      @method_status = local_get(uri, uri.path, 'POST').lines.first
      response = local_get(uri, uri.path)
      raise 'source response failed' unless response.start_with?('HTTP/1.1 200 OK')
      body = response.split("\r\n\r\n", 2).last
      nodes = YAML.safe_load(body)['proxies']
      nodes.each { |n| n.delete('client-fingerprint') }
      YAML.dump('proxies' => nodes)
    end

    def local_get(uri, path, method = 'GET')
      s = TCPSocket.new(uri.hostname, uri.port)
      s.write("#{method} #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      s.read
    ensure
      s.close if s
    end
  end

  def test_audit_ephemeral_server_only_serves_nonce_get_and_is_closed
    converter = FakeConverter.new('http://127.0.0.1:25500')
    original = node
    result = converter.compare([original])
    assert_equal 'subconverter v0.9.9 backend', result['version']
    assert_includes converter.bad_path_status, '404'
    assert_includes converter.method_status, '405'
    assert_equal ['client-fingerprint'], result['differences'].first['fields']
    assert_equal 'chrome', original['client-fingerprint']
    uri = URI.parse(converter.served_url)
    assert_raises(Errno::ECONNREFUSED) { TCPSocket.new(uri.hostname, uri.port) }
  end

  class FailingConverter < FakeConverter
    private
    def request(url, _timeout, _limit)
      @served_url = URI.decode_www_form(URI.parse(url).query).to_h['url']
      raise HybridSubscription::Error, 'Synthetic failure'
    end
  end

  def test_failure_also_closes_source_server
    converter = FailingConverter.new('http://127.0.0.1:25500')
    assert_raises(HybridSubscription::Error) { converter.compare([node]) }
    uri = URI.parse(converter.served_url)
    assert_raises(Errno::ECONNREFUSED) { TCPSocket.new(uri.hostname, uri.port) }
  end
end
