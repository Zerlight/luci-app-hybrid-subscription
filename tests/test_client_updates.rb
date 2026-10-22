require 'minitest/autorun'
require 'tmpdir'
require_relative '../root/usr/share/hybrid-subscription/download'

class ClientUpdatesTest < Minitest::Test
  class Adapter
    def status; {'installed'=>false}; end
  end
  class App < HybridSubscription::Backend
    attr_reader :commands
    def command(argv, **_options)
      (@commands ||= []) << argv
      return '{"access":true}' if argv[0,4] == %w[ubus call session access]
      raise 'Unexpected network or helper command'
    end
  end

  def setup
    @tmp = Dir.mktmpdir
    @b = App.new(File.join(@tmp, 'data'), File.join(@tmp, 'run'), adapter: Adapter.new)
    config = @b.blank_config
    config['settings'].merge!('access_mode'=>'token', 'base_url'=>'https://router.invalid/family%20network/')
    config['sources'] = [{'id'=>'source', 'name'=>'Source', 'enabled'=>true, 'url'=>'', 'format'=>'mihomo', 'update_mode'=>'manual'}]
    config['profiles'] = [{'id'=>'main', 'name'=>'Main', 'sources'=>['source'], 'formats'=>%w[mihomo surge singbox shadowrocket], 'final_policy'=>'proxy', 'mihomo_core'=>'standard'}]
    config['groups'] = [{'id'=>'proxy', 'profile'=>'main', 'name'=>'Proxy', 'sources'=>['source'], 'members'=>[], 'mihomo_type'=>'select', 'surge_type'=>'select', 'singbox_type'=>'selector'}]
    save(config)
    @b.put_source('source', YAML.dump('proxies'=>[{'name'=>'日本', 'type'=>'trojan', 'server'=>'proxy.invalid', 'port'=>443, 'password'=>'synthetic-password'}]), 'mihomo')
    @endpoint = HybridSubscription::Download.new(@b)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def save(config)
    @b.save_config('config'=>JSON.generate(config), 'version'=>@b.version)
  end

  def publish(enabled: false, interval: 24)
    config = @b.config
    config['profiles'][0].merge!('client_update_enabled'=>enabled, 'client_update_interval'=>interval)
    save(config)
    build = @b.build_profile('main')
    @b.publish({'release'=>build['release'], 'accepted_warnings'=>build['warnings'].map { |warning| warning['code'] }})
    @manifest = @b.release_meta(build['release'])
  end

  def artifact(format)
    File.binread(File.join(@b.release_path(@manifest['id']), @b.filename(format)))
  end

  def env(format, extra = {})
    {'REQUEST_METHOD'=>'GET', 'REMOTE_ADDR'=>'127.0.0.1', 'QUERY_STRING'=>URI.encode_www_form('profile'=>'main', 'format'=>format, 'token'=>@b.read(@b.path('tokens.json'))['main'])}.merge(extra)
  end

  def test_surge_managed_first_line_preserves_payload_and_hashes_delivered_bytes
    publish(enabled: true, interval: 48)
    request = env('surge')
    status, headers, body = @endpoint.response(request)
    assert_equal 200, status
    expected_url = 'https://router.invalid/family%20network/cgi-bin/hybrid-subscription?' + request['QUERY_STRING']
    assert_equal "#!MANAGED-CONFIG #{expected_url} interval=172800 strict=false\n", body.lines.first
    assert_equal artifact('surge'), body.split("\n", 2)[1]
    assert_equal "#!FORBIDDEN-AUTO-UPGRADE smart-group\n", body.lines[1]
    refute_includes body, 'strict=true'
    assert_equal body.bytesize.to_s, headers['Content-Length']
    assert_equal '"' + Digest::SHA256.hexdigest(body) + '"', headers['ETag']
    refute_equal '"' + @manifest['sha256']['surge'] + '"', headers['ETag']
    head_status, head_headers, head_body = @endpoint.response(request.merge('REQUEST_METHOD'=>'HEAD'))
    assert_equal 200, head_status
    assert_equal headers, head_headers
    assert_empty head_body
    assert_nil @b.commands
  end

  def test_only_mihomo_gets_the_hour_based_interval_header
    publish(enabled: true, interval: 12)
    %w[mihomo surge singbox shadowrocket].each do |format|
      status, headers, body = @endpoint.response(env(format))
      assert_equal 200, status, format
      if format == 'mihomo'
        assert_equal '12', headers['Profile-Update-Interval']
      else
        refute headers.key?('Profile-Update-Interval'), format
      end
      assert_equal artifact(format), body unless format == 'surge'
    end
  end

  def test_disabled_and_legacy_releases_are_byte_identical
    publish
    2.times do
      %w[mihomo surge singbox shadowrocket].each do |format|
        status, headers, body = @endpoint.response(env(format))
        assert_equal 200, status
        assert_equal artifact(format), body
        assert_equal '"' + @manifest['sha256'][format] + '"', headers['ETag']
        refute headers.key?('Profile-Update-Interval')
      end
      @manifest.delete('client_update')
      @b.atomic(File.join(@b.release_path(@manifest['id']), 'manifest.json'), @manifest)
    end
    config = @b.config
    config['profiles'][0]['client_update_enabled'] = true
    save(config)
    assert_equal artifact('surge'), @endpoint.response(env('surge'))[2]
  end

  def test_tampering_is_rejected_before_managed_url_is_generated
    publish(enabled: true)
    File.binwrite(File.join(@b.release_path(@manifest['id']), 'surge.conf'), 'tampered')
    config = @b.config
    config['settings']['base_url'] = ''
    save(config)
    assert_equal [503, {}, 'Published file verification failed'], @endpoint.response(env('surge'))
  end

  def test_missing_or_unsafe_base_url_never_falls_back_to_request_host
    publish(enabled: true)
    ['', 'https://user:password@router.invalid', 'https://router.invalid/?secret=value', 'https://router.invalid/#fragment', "https://router.invalid/\r\nInjected: value", 'file:///tmp/config'].each do |base|
      config = @b.config
      config['settings']['base_url'] = base
      @b.atomic(@b.path('config.json'), config)
      response = @endpoint.response(env('surge', 'HTTP_HOST'=>'attacker.invalid', 'HTTP_X_FORWARDED_HOST'=>'attacker.invalid'))
      assert_equal [503, {}, 'Client update URL is not configured or invalid'], response, base.inspect
    end
  end

  def test_request_host_is_ignored_and_query_values_are_encoded
    publish(enabled: true)
    token = 'synthetic+/=&%?credential'
    @b.atomic(@b.path('tokens.json'), {'main'=>token})
    status, _headers, body = @endpoint.response(env('surge', 'HTTP_HOST'=>'attacker.invalid', 'HTTP_X_FORWARDED_HOST'=>'attacker.invalid', 'HTTP_FORWARDED'=>'host=attacker.invalid;proto=http'))
    assert_equal 200, status
    uri = URI.parse(body.lines.first.split(' ')[1])
    assert_equal 'https', uri.scheme
    assert_equal 'router.invalid', uri.host
    assert_equal '/family%20network/cgi-bin/hybrid-subscription', uri.path
    assert_equal({'profile'=>'main', 'format'=>'surge', 'token'=>token}, URI.decode_www_form(uri.query).to_h)
    refute_includes body, 'attacker.invalid'
    refute_includes uri.query, token
  end

  def test_token_rotation_changes_managed_representation_without_rebuilding
    publish(enabled: true)
    old_request = env('surge')
    old_response = @endpoint.response(old_request)
    @b.rotate_token('main')
    assert_equal 403, @endpoint.response(old_request)[0]
    status, headers, body = @endpoint.response(env('surge'))
    assert_equal 200, status
    refute_equal old_response[1]['ETag'], headers['ETag']
    refute_equal old_response[2].lines.first, body.lines.first
    assert_equal old_response[2].split("\n", 2)[1], body.split("\n", 2)[1]
    assert_equal @manifest['id'], @b.published['main']
    assert_equal @manifest['sha256']['surge'], Digest::SHA256.hexdigest(artifact('surge'))
  end

  def test_session_access_has_no_token_or_update_hints
    publish(enabled: true)
    config = @b.config
    config['settings'].merge!('access_mode'=>'session', 'base_url'=>'')
    save(config)
    token = @b.read(@b.path('tokens.json'))['main']
    %w[mihomo surge].each do |format|
      request = env(format, 'HTTP_COOKIE'=>'sysauth=' + 'a' * 32, 'QUERY_STRING'=>URI.encode_www_form('profile'=>'main', 'format'=>format))
      status, headers, body = @endpoint.response(request)
      assert_equal 200, status
      assert_equal artifact(format), body
      refute_includes body, token
      refute headers.key?('Profile-Update-Interval')
      refute_includes body, '#!MANAGED-CONFIG'
    end
    assert_equal 403, @endpoint.response(env('surge'))[0]
    assert_equal 'Client updates require token-based download access', @b.download_info('main')['client_update_error']
  end

  def test_draft_update_options_require_a_new_publication
    publish(enabled: true)
    before = @endpoint.response(env('surge'))
    assert_equal({'enabled'=>true, 'interval'=>24}, @manifest['client_update'])
    config = @b.config
    config['profiles'][0].merge!('client_update_enabled'=>false, 'client_update_interval'=>72)
    save(config)
    build = @b.build_profile('main')
    assert_equal before, @endpoint.response(env('surge'))
    assert_equal({'enabled'=>true, 'interval'=>24}, @b.download_info('main')['client_update'])
    state = @b.profile_draft_status(config['profiles'][0], @manifest, @b.engine(config, @b.caches(config)))
    assert_equal 'changed', state['draft_status']
    @b.publish({'release'=>build['release'], 'accepted_warnings'=>build['warnings'].map { |warning| warning['code'] }})
    assert_equal artifact('surge'), @endpoint.response(env('surge'))[2]
    assert_equal({'enabled'=>false, 'interval'=>72}, @b.download_info('main')['client_update'])
  end

  def test_build_rejects_an_unusable_update_transport
    config = @b.config
    config['profiles'][0]['client_update_enabled'] = true
    config['settings']['base_url'] = ''
    save(config)
    error = assert_raises(HybridSubscription::Error) { @b.build_profile('main') }
    assert_equal 'Client update URL is not configured or invalid', error.message
    assert_empty @b.releases
    config['settings'].merge!('base_url'=>'https://router.invalid', 'access_mode'=>'session')
    save(config)
    error = assert_raises(HybridSubscription::Error) { @b.build_profile('main') }
    assert_equal 'Client updates require token-based download access', error.message
    assert_empty @b.releases
    assert_empty @b.published
  end

  def test_update_settings_validate_booleans_and_whole_hours
    [0, 721, -1, 1.5, '1.5', '', nil, true].each do |interval|
      config = @b.config
      config['profiles'][0]['client_update_interval'] = interval
      before = @b.version
      assert_raises(HybridSubscription::Error) { save(config) }
      assert_equal before, @b.version
    end
    [0, 'true', nil].each do |enabled|
      config = @b.config
      config['profiles'][0]['client_update_enabled'] = enabled
      assert_raises(HybridSubscription::Error) { save(config) }
    end
    [1, '24', 720].each do |interval|
      config = @b.config
      config['profiles'][0]['client_update_interval'] = interval
      save(config)
      assert_equal interval.to_i, @b.config['profiles'][0]['client_update_interval']
    end
  end
end
