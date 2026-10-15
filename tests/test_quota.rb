require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../root/usr/share/hybrid-subscription/quota'

class QuotaTest < Minitest::Test
  def test_header_values_are_partial_and_absent_is_unknown
    assert_equal({'upload'=>0,'download'=>12,'expire'=>0}, HybridSubscription::Quota.parse("HTTP/2 200\r\nSubscription-Userinfo: upload=0; download=12; expire=0\r\n"))
    assert_nil HybridSubscription::Quota.parse("Subscription-Userinfo: total=bad; expire=-1\n")
    assert_nil HybridSubscription::Quota.parse('')
    assert_nil HybridSubscription::Quota.parse('x'*65_537)
    assert_equal({'upload'=>8,'download'=>10},HybridSubscription::Quota.parse("Subscription-Userinfo: upload = 0008; download=0010\n"))
  end

  def test_final_response_must_have_its_own_valid_quota_header
    assert_nil HybridSubscription::Quota.parse("HTTP/1.1 302 Found\r\nSubscription-Userinfo: total=10\r\n\r\nHTTP/2 200\r\n\r\n")
    assert_nil HybridSubscription::Quota.parse("HTTP/1.1 403 Forbidden\nSubscription-Userinfo: total=10\n")
    assert_equal({'total'=>20},HybridSubscription::Quota.parse("HTTP/1.1 200 Connection established\nSubscription-Userinfo: total=10\n\nHTTP/2 200\nSubscription-Userinfo: total=20\n"))
  end

  def test_rfc3339_local_time_offsets_are_supported
    utc=HybridSubscription::Quota.timestamp('2026-10-15T03:00:00Z')
    assert_equal utc,HybridSubscription::Quota.timestamp('2026-10-15T11:00:00.123456+08:00')
    assert_equal 0,HybridSubscription::Quota.timestamp('unknown')
  end

  def test_local_provider_snapshot_matches_exact_url_and_uses_read_only_api
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root,'etc/config'))
      FileUtils.mkdir_p(File.join(root,'etc/openclash/config'))
      File.write(File.join(root,'etc/config/openclash'),'present')
      source={'proxy-providers'=>{'Provider'=>{'type'=>'http','url'=>'https://private.invalid/sub'}}}
      File.write(File.join(root,'etc/openclash/config/Hybrid.yaml'),YAML.dump(source))
      File.write(File.join(root,'etc/openclash/Hybrid.yaml'),YAML.dump('secret'=>'private-secret'))
      calls=[]
      runner=lambda do |argv, **options|
        calls << [argv,options]
        if argv.first=='/bin/ubus'
          JSON.generate('values'=>{'config'=>{'config_path'=>'/etc/openclash/config/Hybrid.yaml','cn_port'=>'9090'}})
        else
          JSON.generate('providers'=>{'Provider'=>{'subscriptionInfo'=>{'Upload'=>1,'Download'=>2,'Total'=>100,'Expire'=>0},'updatedAt'=>'2026-10-15T11:00:00+08:00'}})
        end
      end
      adapter=HybridSubscription::Quota.new(root,command:runner)
      result=adapter.local_states([{'id'=>'one','url'=>'https://private.invalid/sub'},{'id'=>'wrong','url'=>'https://different.invalid/sub'}])
      assert_equal ['one'],result.keys
      assert_equal 100,result['one']['quota']['total']
      refute result['one']['quota'].key?('expire')
      assert_equal 'openclash_cache',result['one']['origin']
      api=calls.last
      assert_equal '--disable',api[0][1]
      assert_equal 'http://127.0.0.1:9090/providers/proxies',api[0].last
      refute_includes api[0].join(' '),'private-secret'
      assert_includes api[1][:input],'private-secret'
      refute calls.any? { |argv,_| argv.include?('--request') || argv.include?('--location') || argv.join.include?('https://private.invalid') }
      assert_empty adapter.local_states([{'id'=>'one','url'=>'https://mismatch.invalid/sub'}])
      assert_equal '/bin/ubus',calls.last[0].first
    end
  end

  def test_import_only_unambiguous_explicit_independent_status_urls
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root,'etc/config'))
      File.write(File.join(root,'etc/config/openclash'),'present')
      sections={
        'sub'=>{'.type'=>'config_subscribe','name'=>'Provider'},
        'info'=>{'.type'=>'subscribe_info','name'=>'Provider.yaml','url'=>['https://status.invalid/metadata#name=Provider']}
      }
      calls=[]
      adapter=HybridSubscription::Quota.new(root,command:lambda { |argv, **_options| calls << argv; JSON.generate('values'=>sections) })
      source={'id'=>'one','name'=>'Provider','openclash_section'=>'sub','url'=>'https://sub.invalid/timed'}
      assert_equal({'one'=>'https://status.invalid/metadata'},adapter.configured_urls([source]))
      assert_empty adapter.configured_urls([source,source.merge('id'=>'duplicate')])
      sections['info']['url']=['https://sub.invalid/timed#name=Provider']
      assert_empty adapter.configured_urls([source])
      sections['info']['url']=['https://status.invalid/one','https://status.invalid/two']
      assert_empty adapter.configured_urls([source])
      assert calls.all? { |argv| argv.first=='/bin/ubus' }
    end
  end
end
