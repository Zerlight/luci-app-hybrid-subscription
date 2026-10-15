require 'minitest/autorun'
require 'tmpdir'
require_relative '../root/usr/share/hybrid-subscription/backend'
require_relative '../root/usr/share/hybrid-subscription/download'
class BackendTest < Minitest::Test
  class Adapter
    def status; {'installed'=>true,'integration'=>false}; end
    def import_sources; {'sources'=>[],'caches'=>{}}; end
  end
  class App < HybridSubscription::Backend
    attr_reader :enqueued
    def enqueue(kind,id); (@enqueued||=[]) << [kind,id]; 'j'+'a'*24; end
    def enqueue_locked(kind,id,release=nil); enqueue(kind,id); end
    def converter_status; {'available'=>false}; end
  end
  class QueueApp < HybridSubscription::Backend
    attr_accessor :spawn_error, :fetch_hook, :fetch_content
    def spawn_worker(id)
      raise Errno::EAGAIN if spawn_error
      Process.pid
    end
    def command(argv, **options)
      return super unless argv.first=='curl' && argv.include?('--output') && fetch_content
      fetch_hook.call if fetch_hook
      File.write(argv[argv.index('--output')+1],fetch_content)
      File.write(argv[argv.index('--dump-header')+1],'')
      ''
    end
  end
  class ApplyAdapter < Adapter
    attr_reader :applied
    attr_accessor :before_apply
    def initialize; @applied=[]; end
    def apply(profile,artifact,config)
      @applied << [File.basename(File.dirname(artifact)),config]
      before_apply.call if before_apply
      {'ok'=>true}
    end
  end
  class QuotaAdapter
    attr_accessor :states, :before_read
    def initialize; @states={}; end
    def local_states(_sources); before_read.call if before_read; @states; end
  end
  class QuotaApp < App
    attr_accessor :response_headers, :status_hook, :status_error
    attr_reader :status_requests
    def command(argv, **options)
      raise 'Unexpected network or helper command' unless argv.first=='curl' && argv.include?('--head')
      (@status_requests||=[]) << [argv,options]
      status_hook.call if status_hook
      raise status_error if status_error
      response_headers || ''
    end
  end
  def setup
    @tmp=Dir.mktmpdir
    @b=App.new(File.join(@tmp,'data'),File.join(@tmp,'run'),adapter:Adapter.new)
    @c=@b.blank_config
    @c['sources']=[{'id'=>'test','name'=>'Test','enabled'=>true,'url'=>'https://invalid.example/secret','format'=>'mihomo','update_mode'=>'manual','interval'=>86400}]
    @c['profiles']=[{'id'=>'main','name'=>'Main','sources'=>['test'],'formats'=>%w[mihomo surge singbox],'final_policy'=>'proxy','mihomo_core'=>'standard'}]
    @c['groups']=[{'id'=>'proxy','profile'=>'main','name'=>'Proxy','sources'=>['test'],'filter'=>'','exclude_filter'=>'','members'=>[],'mihomo_type'=>'select','surge_type'=>'select','singbox_type'=>'selector','url'=>'https://www.gstatic.com/generate_204','interval'=>300,'tolerance'=>50}]
    @b.save_config('config'=>JSON.generate(@c),'version'=>@b.version)
    @node={'name'=>'Node','type'=>'anytls','server'=>'proxy.example','port'=>443,'password'=>'private-password','client-fingerprint'=>'chrome'}
    @b.put_source('test',YAML.dump('proxies'=>[@node]),'mihomo')
  end
  def teardown; FileUtils.rm_rf(@tmp); end
  def test_installed_core_validation_precedes_release_creation
    adapter=Adapter.new
    def adapter.validate_export(content)
      raise HybridSubscription::Error, 'Core rejected the generated policy'
    end
    b=App.new(@b.dir,File.join(@tmp,'run'),adapter:adapter)
    assert_raises(HybridSubscription::Error) { b.build_profile('main') }
    assert_empty b.releases
  end
  def test_legacy_draft_upgrades_special_rule_collections
    legacy=JSON.parse(JSON.generate(@c))
    legacy.delete('rematches'); legacy.delete('sub_rules')
    @b.atomic(@b.path('config.json'),legacy)
    assert_equal [],@b.config['rematches']
    assert_equal [],@b.config['sub_rules']
    legacy['rematches']=[{'id'=>'follow','profile'=>'main','name'=>'Follow','target_sub_rule'=>'region','rematch_name'=>'Provider'}]
    legacy['sub_rules']=[{'id'=>'region','profile'=>'main','name'=>'Region','final_policy'=>'proxy'}]
    @b.save_config('config'=>JSON.generate(legacy),'version'=>@b.version)
    assert_equal 'follow',@b.config['rematches'][0]['id']
    assert_equal 'region',@b.config['sub_rules'][0]['id']
  end
  def test_source_url_is_write_only_and_preserved
    r=@b.call('get_config'); refute_includes JSON.generate(r),'https://invalid.example/secret'
    assert r['config']['sources'][0]['has_url']
    r2=@b.call('save_config','config'=>JSON.generate(r['config']),'version'=>r['version']);assert r2['ok']
    assert_equal @c['sources'][0]['url'],@b.config['sources'][0]['url']
  end
  def quota_app
    @quota_adapter=QuotaAdapter.new
    QuotaApp.new(@b.dir,File.join(@tmp,'run'),adapter:Adapter.new,quota_adapter:@quota_adapter)
  end
  def configure_quota(b)
    c=b.config;c['sources'][0]['quota_url']='https://status.invalid/metadata?token=private-status-token'
    b.save_config('config'=>JSON.generate(c),'version'=>b.version)
  end
  def enable_subscription_quota(b)
    c=b.config;c['sources'][0]['quota_via_subscription']=true
    b.save_config('config'=>JSON.generate(c),'version'=>b.version)
  end
  def test_subscription_quota_requires_strict_boolean_opt_in
    b=quota_app
    assert_equal false,b.config['sources'][0]['quota_via_subscription']
    [nil,'true','false',1,0].each do |invalid|
      c=b.config;c['sources'][0]['quota_via_subscription']=invalid
      assert_raises(HybridSubscription::Error) { b.save_config('config'=>JSON.generate(c),'version'=>b.version) }
    end
    assert_nil b.status_requests
    enable_subscription_quota(b)
    assert_equal true,b.call('get_config')['config']['sources'][0]['quota_via_subscription']
    c=b.config;c['sources'][0].delete('quota_via_subscription')
    b.save_config('config'=>JSON.generate(c),'version'=>b.version)
    assert_equal false,b.config['sources'][0]['quota_via_subscription']
  end
  def test_subscription_quota_requests_only_explicitly_selected_source
    b=quota_app;enable_subscription_quota(b)
    c=b.config
    c['sources'] << {'id'=>'timed','name'=>'Manual Window Source','enabled'=>true,'url'=>'https://window.invalid/sub?token=limited-fixture','format'=>'mihomo','update_mode'=>'manual'}
    b.save_config('config'=>JSON.generate(c),'version'=>b.version)
    b.put_source('timed',YAML.dump('proxies'=>[@node.merge('name'=>'Other Node')]),'mihomo')
    before=b.caches
    b.response_headers="HTTP/2 200\r\nSubscription-Userinfo: upload=0; download=25; total=100; expire=0\r\n"
    result=b.refresh_quota('test')
    assert_equal 'subscription_header',result['origin']
    assert_equal 1,b.status_requests.length
    assert_includes b.status_requests[0][1][:input],c['sources'][0]['url']
    refute_includes b.status_requests[0][0].join(' '),c['sources'][0]['url']
    refute_includes JSON.generate(b.status_requests),'window.invalid'
    assert_equal before['test']['nodes'],b.caches['test']['nodes']
    assert_equal before['timed'],b.caches['timed']
    statuses=b.status['sources'].to_h { |item| [item['id'],item['quota_status']] }
    assert statuses['test']['can_refresh']
    assert_equal 'subscription',statuses['test']['query_mode']
    refute statuses['timed']['can_refresh']
    assert_equal 'cache_only',statuses['timed']['query_mode']
    assert_raises(HybridSubscription::Error) { b.refresh_quota('timed') }
    assert_equal 1,b.status_requests.length
    assert_equal before['timed']['nodes'],b.caches['timed']['nodes']
  end
  def test_subscription_opt_in_does_not_make_status_tick_or_download_fetch
    b=quota_app;enable_subscription_quota(b)
    built=b.build_profile('main')
    b.publish('release'=>built['release'],'accepted_warnings'=>built['warnings'].map { |warning| warning['code'] })
    b.status;b.tick
    info=b.download_info('main')
    endpoint=HybridSubscription::Download.new(b)
    env={'REMOTE_ADDR'=>'127.0.0.1','QUERY_STRING'=>'profile=main&format=mihomo&token='+info['token']}
    %w[GET HEAD].each { |method| assert_equal 200,endpoint.response(env.merge('REQUEST_METHOD'=>method))[0] }
    assert_nil b.status_requests
    assert_nil b.enqueued
  end
  def test_independent_status_endpoint_has_priority_and_failure_never_falls_back
    b=quota_app;configure_quota(b);enable_subscription_quota(b)
    b.response_headers="Subscription-Userinfo: total=123\n";b.refresh_quota('test')
    before=b.caches['test']
    assert_equal 'independent',b.status['sources'][0]['quota_status']['query_mode']
    ["HTTP/2 200\r\n\r\n", "HTTP/1.1 302 Found\r\nLocation: https://window.invalid/sub\r\n\r\n"].each do |headers|
      b.response_headers=headers
      assert_raises(HybridSubscription::Error) { b.refresh_quota('test') }
      assert_equal before['nodes'],b.caches['test']['nodes']
      assert_equal before['meta']['quota'],b.caches['test']['meta']['quota']
    end
    assert_equal 3,b.status_requests.length
    b.status_requests.each do |argv,options|
      assert_includes options[:input],'https://status.invalid/metadata'
      refute_includes options[:input],b.config['sources'][0]['url']
      assert_equal '--disable',argv[1]
      assert_includes argv,'--no-location'
      refute_includes argv,'--location'
    end
  end
  def test_disabling_subscription_quota_discards_inflight_result
    b=quota_app;enable_subscription_quota(b);before=b.caches['test']
    b.response_headers="Subscription-Userinfo: total=123\n"
    b.status_hook=proc { c=b.config;c['sources'][0]['quota_via_subscription']=false;b.atomic(b.path('config.json'),c) }
    assert_raises(HybridSubscription::Error) { b.refresh_quota('test') }
    assert_equal before,b.caches['test']
    refute b.status['sources'][0]['quota_status']['can_refresh']
    assert_equal 1,b.status_requests.length
  end
  def test_disabling_subscription_quota_before_send_prevents_request
    b=quota_app;enable_subscription_quota(b);before=b.caches['test']
    @quota_adapter.before_read=proc { c=b.config;c['sources'][0]['quota_via_subscription']=false;b.atomic(b.path('config.json'),c) }
    assert_raises(HybridSubscription::Error) { b.refresh_quota('test') }
    assert_nil b.status_requests
    assert_equal before,b.caches['test']
  end
  def test_independent_url_cannot_bypass_another_sources_opt_in
    b=quota_app;enable_subscription_quota(b)
    c=b.config
    c['sources'] << {'id'=>'timed','name'=>'Another Manual Source','enabled'=>true,'url'=>'https://window.invalid/sub?token=limited-fixture','format'=>'mihomo','update_mode'=>'manual','quota_via_subscription'=>false}
    c['sources'][0]['quota_url']=c['sources'][1]['url']+'#ignored'
    b.atomic(b.path('config.json'),c)
    assert_raises(HybridSubscription::Error) { b.refresh_quota('test') }
    assert_nil b.status_requests
  end
  def test_subscription_opt_in_without_url_cannot_refresh
    b=quota_app;c=b.config
    c['sources'] << {'id'=>'file-only','name'=>'Imported File','enabled'=>true,'url'=>'','format'=>'mihomo','update_mode'=>'manual','quota_via_subscription'=>true}
    b.save_config('config'=>JSON.generate(c),'version'=>b.version)
    details=b.status['sources'].find { |s| s['id']=='file-only' }['quota_status']
    assert_equal 'cache_only',details['query_mode']
    refute details['can_refresh']
    assert_raises(HybridSubscription::Error) { b.refresh_quota('file-only') }
    assert_nil b.status_requests
  end
  def test_quota_url_is_write_only_preserved_and_explicitly_clearable
    b=quota_app;configure_quota(b)
    result=b.call('get_config')
    assert result['config']['sources'][0]['has_quota_url']
    assert_equal '',result['config']['sources'][0]['quota_url']
    refute_includes JSON.generate(result),'private-status-token'
    b.save_config('config'=>JSON.generate(result['config']),'version'=>result['version'])
    assert_includes b.config['sources'][0]['quota_url'],'private-status-token'
    result=b.call('get_config');result['config']['sources'][0]['clear_quota_url']=true
    b.save_config('config'=>JSON.generate(result['config']),'version'=>result['version'])
    assert_equal '',b.config['sources'][0]['quota_url']
    bad=b.config;bad['sources'][0]['quota_url']=bad['sources'][0]['url']+'#fragment'
    assert_raises(HybridSubscription::Error) { b.save_config('config'=>JSON.generate(bad),'version'=>b.version) }
  end
  def test_status_refresh_updates_only_quota_and_preserves_published_candidate
    b=quota_app;configure_quota(b)
    before=b.caches['test'];build=b.build_profile('main')
    b.response_headers="HTTP/2 200\r\nSubscription-Userinfo: upload=10; download=20; total=100; expire=0\r\n"
    b.refresh_quota('test')
    after=b.caches['test']
    assert_equal before['nodes'],after['nodes']
    %w[generation cached_at attempt_at sha256].each { |key| assert_equal before['meta'][key],after['meta'][key] }
    assert_equal 100,after['meta']['quota']['total']
    request=b.status_requests.first
    assert_includes request[0],'--head'
    assert_includes request[0],'GET'
    assert_equal '--disable',request[0][1]
    assert_includes request[0],'--no-location'
    refute_includes request[0],'--location'
    refute_includes request[0],'--max-filesize'
    refute_includes request[0].join(' '),'private-status-token'
    assert_includes request[1][:input],'private-status-token'
    b.publish('release'=>build['release'],'accepted_warnings'=>build['warnings'].map { |warning| warning['code'] })
    assert_equal build['release'],b.published['main']
    info=b.status['sources'][0]['quota_status']
    assert_equal 'fresh',info['state']
    assert info['can_refresh']
  end
  def test_quota_failure_keeps_values_and_hides_private_url
    b=quota_app;configure_quota(b)
    b.response_headers="Subscription-Userinfo: total=123\n";b.refresh_quota('test')
    before=b.caches['test']
    b.status_error=HybridSubscription::Error.new('failed https://status.invalid/metadata?token=private-status-token')
    assert_raises(HybridSubscription::Error) { b.refresh_quota('test') }
    after=b.caches['test']
    assert_equal before['nodes'],after['nodes']
    assert_equal before['meta']['quota'],after['meta']['quota']
    refute_includes JSON.generate(b.status),'private-status-token'
    assert_match(/\[URL\]/,after['meta']['quota_error'])
  end
  def test_missing_status_endpoint_never_falls_back_to_subscription
    b=quota_app
    assert_raises(HybridSubscription::Error) { b.refresh_quota('test') }
    assert_nil b.status_requests
    details=b.status['sources'][0]['quota_status']
    assert_equal 'unavailable',details['state']
    refute details['can_refresh']
    b.tick;assert_nil b.enqueued
    result=b.call('refresh_quota','source'=>'test')
    assert result['ok']
    assert_equal [['refresh_quota','test']],b.enqueued
  end
  def test_quota_failure_does_not_change_legacy_node_cache_generation
    b=quota_app
    cached=b.caches['test'];cached['meta'].delete('generation');b.atomic(b.source_path('test'),cached)
    generation=b.source_generation('test')
    assert_raises(HybridSubscription::Error) { b.refresh_quota('test') }
    assert_equal generation,b.source_generation('test')
    assert_equal cached['nodes'],b.caches['test']['nodes']
  end
  def test_local_cached_quota_is_reused_and_marked_stale_without_upstream
    b=quota_app
    @quota_adapter.states={'test'=>{'quota'=>{'total'=>999},'updated_at'=>'2020-01-01T00:00:00Z','origin'=>'openclash_cache'}}
    info=b.status['sources'][0]
    assert_equal 999,info['quota']['total']
    assert info['quota_status']['can_refresh']
    assert_equal 'stale',info['quota_status']['state']
    b.refresh_quota('test')
    assert_nil b.status_requests
    @quota_adapter.states={}
    info=b.status['sources'][0]
    assert_equal 999,info['quota']['total']
    refute info['quota_status']['can_refresh']
  end
  def test_import_without_headers_keeps_quota_and_new_headers_replace_it
    b=quota_app;configure_quota(b)
    b.response_headers="Subscription-Userinfo: total=123\n";b.refresh_quota('test')
    b.put_source('test',YAML.dump('proxies'=>[@node]),'mihomo')
    assert_equal 123,b.caches['test']['meta']['quota']['total']
    b.put_source('test',YAML.dump('proxies'=>[@node]),'mihomo',"Subscription-Userinfo: total=456\n")
    assert_equal 456,b.caches['test']['meta']['quota']['total']
    assert_equal 'subscription_header',b.caches['test']['meta']['quota_origin']
  end
  def test_stale_status_url_result_does_not_clobber_newer_state
    b=quota_app;configure_quota(b);before=b.caches['test']
    b.response_headers="Subscription-Userinfo: total=123\n"
    b.status_hook=proc { c=b.config;c['sources'][0]['quota_url']='https://status.invalid/new';b.atomic(b.path('config.json'),c) }
    assert_raises(HybridSubscription::Error) { b.refresh_quota('test') }
    assert_equal before,b.caches['test']
  end
  def test_new_subscription_header_wins_over_inflight_status_refresh
    b=quota_app;configure_quota(b)
    b.response_headers="Subscription-Userinfo: total=123\n"
    b.status_hook=proc { b.put_source('test',YAML.dump('proxies'=>[@node]),'mihomo',"Subscription-Userinfo: total=456\n") }
    assert_raises(HybridSubscription::Error) { b.refresh_quota('test') }
    assert_equal 456,b.caches['test']['meta']['quota']['total']
    assert_nil b.caches['test']['meta']['quota_error']
  end
  def test_status_fetch_uses_real_curl_headers_despite_large_declared_body
    require 'socket'
    server=TCPServer.new('127.0.0.1',0)
    request=nil
    worker=Thread.new do
      client=server.accept
      request=client.gets
      while (line=client.gets) && line!="\r\n"; end
      # A header-only GET must not demand or reject the advertised subscription body.
      client.write("HTTP/1.1 200 OK\r\nSubscription-Userinfo: upload=5; download=6; total=999\r\nContent-Length: 10485760\r\nConnection: close\r\n\r\n")
      client.close
    end
    b=HybridSubscription::Backend.new(@b.dir,File.join(@tmp,'run'),adapter:Adapter.new,quota_adapter:QuotaAdapter.new)
    c=b.config;c['sources'][0]['quota_url']="http://127.0.0.1:#{server.addr[1]}/status?token=fixture"
    b.save_config('config'=>JSON.generate(c),'version'=>b.version)
    before=b.caches['test']['nodes']
    assert_equal 999,b.refresh_quota('test')['quota']['total']
    worker.join(3)
    assert_equal "GET /status?token=fixture HTTP/1.1\r\n",request
    assert_equal before,b.caches['test']['nodes']
    assert_empty Dir.glob(File.join(@tmp,'run','command-*'))
  ensure
    server.close if server
    worker.kill if worker && worker.alive?
  end
  def test_regions_preview_is_draft_only_and_contains_no_node_secrets
    b=quota_app
    defaults=b.call('region_defaults')
    assert defaults['ok'];assert defaults['regions'].any? { |r| r['id']=='jp' }
    draft=b.sanitized_config;draft['regions']=[{'id'=>'jp','name'=>'Japan','pattern'=>'Node','source_patterns'=>{}}]
    result=b.call('preview_regions','config'=>JSON.generate(draft),'sources'=>['test'])
    assert result['ok'];assert_equal [{'name'=>'Node','regions'=>['jp']}],result['sources'][0]['nodes']
    assert_equal({'jp'=>1},result['sources'][0]['counts'])
    refute_includes JSON.generate(result),'private-password'
    assert_empty b.config['regions']
    b.save_config('config'=>JSON.generate(draft),'version'=>b.version)
    assert_equal 'jp',b.config['regions'][0]['id']
    assert_equal({'jp'=>1},b.status['sources'][0]['regions'])
    draft['regions'][0]['source_patterns']={'missing'=>'JP'}
    assert_raises(HybridSubscription::Error) { b.save_config('config'=>JSON.generate(draft),'version'=>b.version) }
  end
  def test_optimistic_save_and_unsafe_ids
    r=@b.call('save_config','config'=>JSON.generate(@c),'version'=>'stale');refute r['ok']
    r=@b.call('refresh','source'=>'../../etc/passwd');refute r['ok'];assert_nil @b.enqueued
  end
  def test_invalid_import_preserves_cache
    before=@b.caches['test']
    r=@b.call('import_source','source'=>'test','content'=>'<html>expired</html>');refute r['ok']
    assert_equal before,@b.caches['test']
  end
  def test_build_requires_ack_and_history_for_rollback
    build=@b.build_profile('main'); assert_equal 3,build['formats'].length
    refute_empty build['warnings']
    assert_raises(HybridSubscription::Error) { @b.publish('release'=>build['release'],'accepted_warnings'=>[]) }
    assert_raises(HybridSubscription::Error) { @b.publish({'release'=>build['release']},rollback:true) }
    pub=@b.publish('release'=>build['release'],'accepted_warnings'=>build['warnings'].map { |w| w['code'] })
    assert_equal build['release'],pub['release'];assert_nil @b.enqueued
    assert @b.status['releases'][0]['ever_published']
    @b.publish({'release'=>build['release']},rollback:true)
  end
  def test_changed_source_invalidates_candidate
    r=@b.build_profile('main');@node['password']='new-value';@b.put_source('test',YAML.dump('proxies'=>[@node]),'mihomo')
    assert_raises(HybridSubscription::Error) { @b.publish('release'=>r['release'],'accepted_warnings'=>r['warnings'].map { |w| w['code'] }) }
  end
  def test_download_does_not_fetch_and_old_tokens_revoke
    r=@b.build_profile('main');@b.publish('release'=>r['release'],'accepted_warnings'=>r['warnings'].map { |w| w['code'] })
    info=@b.download_info('main');d=HybridSubscription::Download.new(@b)
    env={'REQUEST_METHOD'=>'GET','REMOTE_ADDR'=>'127.0.0.1','QUERY_STRING'=>'profile=main&format=mihomo&token='+info['token']}
    status,headers,body=d.response(env);assert_equal 200,status;assert_includes body,'private-password';assert_equal body.bytesize.to_s,headers['Content-Length']
    status,headers,body=d.response(env.merge('REQUEST_METHOD'=>'HEAD'));assert_equal 200,status;assert_empty body
    assert_equal 403,d.response(env.merge('REMOTE_ADDR'=>'203.0.113.1'))[0]
    assert_equal 400,d.response(env.merge('QUERY_STRING'=>'profile=../../root&format=mihomo'))[0]
    assert_equal 400,d.response(env.merge('QUERY_STRING'=>env['QUERY_STRING']+'&profile=main'))[0]
    @b.rotate_token('main');assert_equal 403,d.response(env)[0]
    assert_nil @b.enqueued
  end
  def test_download_detects_tampering
    r=@b.build_profile('main');@b.publish('release'=>r['release'],'accepted_warnings'=>r['warnings'].map { |w| w['code'] })
    File.write(File.join(@b.release_path(r['release']),'mihomo.yaml'),'tampered')
    env={'REMOTE_ADDR'=>'127.0.0.1','QUERY_STRING'=>'profile=main&format=mihomo&token='+@b.download_info('main')['token']}
    assert_equal 503,HybridSubscription::Download.new(@b).response(env)[0]
  end
  def test_manual_update_never_scheduled
    @b.tick;assert_nil @b.enqueued
    c=@b.config;c['sources'][0]['update_mode']='scheduled';c['sources'][0]['interval']=300
    @b.atomic(@b.path('config.json'),c)
    @b.atomic(@b.source_path('test'),{'nodes'=>[@node],'meta'=>{'attempt_at'=>'2020-01-01T00:00:00Z'}})
    @b.tick;assert_equal [['refresh','test']],@b.enqueued
  end
  def test_auto_apply_only_selected_profile
    r=@b.build_profile('main')
    c=@b.config;c['settings']['openclash_auto_apply']=true;c['settings']['openclash_profile']='main';@b.atomic(@b.path('config.json'),c)
    r=@b.build_profile('main');@b.publish('release'=>r['release'],'accepted_warnings'=>r['warnings'].map { |w| w['code'] })
    assert_equal [['apply','main']],@b.enqueued
  end
  def test_command_timeout_kills_child
    started=Time.now
    assert_raises(HybridSubscription::Error) { @b.command([RbConfig.ruby,'-e','sleep 30'],seconds:0.1) }
    assert_operator Time.now-started,:<,3
    assert_empty Dir.glob(File.join(@tmp,'run','command-*'))
  end
  def test_preview_redacts_password
    r=@b.call('preview','profile'=>'main','format'=>'mihomo');assert r['ok'];refute_includes r['content'],'private-password'
  end
  def queue_app(adapter=ApplyAdapter.new)
    QueueApp.new(File.join(@tmp,'data'),File.join(@tmp,'run'),adapter:adapter)
  end
  def auto_apply(b)
    c=b.config;c['settings']['openclash_auto_apply']=true;c['settings']['openclash_profile']='main'
    b.atomic(b.path('config.json'),c)
  end
  def publish_build(b)
    built=b.build_profile('main')
    b.publish('release'=>built['release'],'accepted_warnings'=>built['warnings'].map { |w| w['code'] })
  end
  def test_overlapping_publications_have_pinned_serial_apply_jobs
    adapter=ApplyAdapter.new;b=queue_app(adapter);auto_apply(b)
    entered=Queue.new;proceed=Queue.new
    adapter.before_apply=proc { if adapter.applied.length==1;entered << true;proceed.pop;end }
    first=publish_build(b)
    first_thread=Thread.new { b.run_job(first['job']) }
    Timeout.timeout(3) { entered.pop }
    @node['password']='second-release';b.put_source('test',YAML.dump('proxies'=>[@node]),'mihomo')
    second=publish_build(b)
    refute_equal first['job'],second['job']
    assert_equal first['release'],b.job_status(first['job'])['release']
    assert_equal second['release'],b.job_status(second['job'])['release']
    second_thread=Thread.new { b.run_job(second['job']) }
    sleep 0.03
    assert_equal 'queued',b.job_status(second['job'])['state']
    draft=b.config;draft['sources'][0]['takeover']=true;b.atomic(b.path('config.json'),draft)
    proceed << true
    Timeout.timeout(4) { first_thread.join;second_thread.join }
    assert_equal [first['release'],second['release']],adapter.applied.map(&:first)
    refute adapter.applied.last[1]['sources'][0]['takeover']
    assert_equal 'completed',b.job_status(second['job'])['state']
  ensure
    proceed << true if proceed
    [first_thread,second_thread].compact.each { |t| t.kill if t.alive? }
  end
  def test_simultaneous_enqueues_deduplicate_under_state_lock
    b=queue_app
    ids=8.times.map { Thread.new { b.enqueue('refresh','test') } }.map(&:value)
    assert_equal 1,ids.uniq.length
    assert_equal 1,b.all_jobs.length
  end
  def test_stale_url_fetch_does_not_replace_cache_or_record_error
    b=queue_app;before=b.caches['test'];b.fetch_content=YAML.dump('proxies'=>[@node.merge('password'=>'old-url-result')])
    b.fetch_hook=proc { c=b.config;c['sources'][0]['url']='https://new.invalid/sub';b.atomic(b.path('config.json'),c) }
    assert_raises(HybridSubscription::Error) { b.refresh_source('test') }
    assert_equal before,b.caches['test']
  end
  def test_manual_import_wins_over_inflight_refresh_even_with_same_nodes
    b=queue_app;b.fetch_content=YAML.dump('proxies'=>[@node.merge('password'=>'stale-download')])
    imported=nil
    b.fetch_hook=proc { b.put_source('test',YAML.dump('proxies'=>[@node]),'mihomo');imported=b.caches['test'] }
    assert_raises(HybridSubscription::Error) { b.refresh_source('test') }
    assert_equal imported,b.caches['test']
    assert_nil b.caches['test']['meta']['error']
  end
  def test_spawn_failure_is_failed_job_after_successful_publication
    b=queue_app;auto_apply(b);b.spawn_error=true
    result=publish_build(b)
    assert_equal result['release'],b.published['main']
    assert_equal 'failed',b.job_status(result['job'])['state']
    assert_match(/Failed to start/,b.job_status(result['job'])['error'])
  end
  def test_stale_dead_and_expired_jobs_stop_blocking_updates
    b=queue_app
    old=b.enqueue('refresh','test');j=b.read(b.job_file(old));j['pid']=nil;j['queued_at']=Time.now.to_f-10;b.atomic(b.job_file(old),j)
    fresh=b.enqueue('refresh','test')
    refute_equal old,fresh
    assert_equal 'failed',b.job_status(old)['state']
    j=b.read(b.job_file(fresh));j['state']='running';j['deadline']=Time.now.to_f-1;b.atomic(b.job_file(fresh),j)
    assert_equal 'failed',b.job_status(fresh)['state']
    assert b.process_alive?(Process.pid)
    new_id='j'+'f'*24
    b.atomic(b.job_file(new_id),{'id'=>new_id,'kind'=>'build','value'=>'main','state'=>'queued','created_at'=>b.now,'queued_at'=>Time.now.to_f,'deadline'=>Time.now.to_f+1800,'order'=>99})
    assert_equal 'queued',b.job_status(new_id)['state']
  end
  def test_unpublish_revokes_downloads_before_deleting_profile
    r=publish_build(@b);info=@b.download_info('main')
    c=@b.config;c['profiles']=[]
    assert_raises(HybridSubscription::Error) { @b.save_config('config'=>JSON.generate(c),'version'=>@b.version) }
    @b.unpublish('main')
    env={'REMOTE_ADDR'=>'127.0.0.1','QUERY_STRING'=>'profile=main&format=mihomo&token='+info['token']}
    assert_equal 403,HybridSubscription::Download.new(@b).response(env)[0]
    @b.save_config('config'=>JSON.generate(c),'version'=>@b.version)
    assert_empty @b.config['profiles']
    assert File.file?(File.join(@b.release_path(r['release']),'manifest.json'))
  end
end
