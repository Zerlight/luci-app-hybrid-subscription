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
    attr_accessor :spawn_error, :fetch_hook, :fetch_content, :fetch_headers, :fetch_error
    def spawn_worker(id)
      raise Errno::EAGAIN if spawn_error
      Process.pid
    end
    def command(argv, **options)
      return super unless argv.first=='curl' && argv.include?('--output') && fetch_content
      fetch_hook.call if fetch_hook
      File.write(argv[argv.index('--output')+1],fetch_content)
      File.write(argv[argv.index('--dump-header')+1],fetch_headers || '')
      raise fetch_error if fetch_error
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
  def test_default_config_hides_source_url_and_blank_save_preserves_it
    r=@b.call('get_config'); refute_includes JSON.generate(r),'https://invalid.example/secret'
    assert r['config']['sources'][0]['has_url']
    r2=@b.call('save_config','config'=>JSON.generate(r['config']),'version'=>r['version']);assert r2['ok']
    assert_equal @c['sources'][0]['url'],@b.config['sources'][0]['url']
  end
  def test_partial_source_save_preserves_other_collections_and_private_urls
    c=@b.config
    c['sources'][0]['quota_url']='https://status.invalid/query?token=quota-fixture'
    c['profiles'][0]['mihomo_dns']={'nameserver'=>['https://resolver.invalid/dns-query']}
    @b.atomic(@b.path('config.json'),c)
    update=@b.sanitized_config['sources']
    update[0]['name']='Edited Source'
    result=@b.call('save_config','config'=>JSON.generate('sources'=>update),'collections'=>['sources'],'version'=>@b.version)
    assert result['ok'],result.inspect
    after=@b.config
    assert_equal 'Edited Source',after['sources'][0]['name']
    assert_equal c['sources'][0]['url'],after['sources'][0]['url']
    assert_equal c['sources'][0]['quota_url'],after['sources'][0]['quota_url']
    refute after['sources'][0].key?('has_url')
    refute after['sources'][0].key?('has_quota_url')
    (HybridSubscription::Backend::COLLECTIONS-['sources']+['settings']).each { |key| assert_equal c[key],after[key],key }
    assert_equal @b.version,result['version']
  end
  def test_partial_group_save_preserves_source_secrets_and_conversion_strategy
    create_tracked_profile
    before=@b.config
    groups=JSON.parse(JSON.generate(before['groups']))
    groups[0]['name']='Edited Group'
    result=@b.call('save_config','config'=>JSON.generate('groups'=>groups),'collections'=>['groups'],'version'=>@b.version)
    assert result['ok'],result.inspect
    after=@b.config
    assert_equal 'Edited Group',after['groups'][0]['name']
    (HybridSubscription::Backend::COLLECTIONS-['groups']+['settings']).each { |key| assert_equal before[key],after[key],key }
  end
  def test_partial_save_checks_version_and_full_configuration_validation
    before=@b.config
    stale=@b.version
    changed=@b.sanitized_config['sources']
    changed[0]['name']='New Name'
    @b.save_config('config'=>JSON.generate('sources'=>changed),'collections'=>['sources'],'version'=>stale)
    current=@b.config
    result=@b.call('save_config','config'=>JSON.generate('sources'=>before['sources']),'collections'=>['sources'],'version'=>stale)
    refute result['ok']
    assert_match(/modified in another session/,result['error'])
    assert_equal current,@b.config
    changed[0]['url']='not-a-url'
    result=@b.call('save_config','config'=>JSON.generate('sources'=>changed),'collections'=>['sources'],'version'=>@b.version)
    refute result['ok']
    assert_equal current,@b.config
  end
  def test_partial_save_rejects_invalid_or_missing_collections_without_mutation
    before=@b.config
    [false,'sources',{},['schema'],['unknown'],['sources','sources'],[nil],[1],['settings']].each do |collections|
      result=@b.call('save_config','config'=>JSON.generate('sources'=>before['sources']),'collections'=>collections,'version'=>@b.version)
      refute result['ok'],collections.inspect
      assert_equal before,@b.config
    end
    result=@b.call('save_config','config'=>'[]','collections'=>['sources'],'version'=>@b.version)
    refute result['ok']
    assert_equal before,@b.config
    [nil,[]].each do |collections|
      result=@b.call('save_config','config'=>JSON.generate(@b.sanitized_config),'collections'=>collections,'version'=>@b.version)
      assert result['ok'],result.inspect
      assert_equal before,@b.config
    end
  end
  def test_source_urls_are_requested_for_one_existing_source_only
    c=@b.config
    c['sources'][0]['quota_url']='https://status.invalid/query?token=quota-fixture'
    c['sources'] << {'id'=>'other','url'=>'https://other.invalid/private-fixture','quota_url'=>''}
    @b.atomic(@b.path('config.json'),c)
    before=@b.version
    result=@b.call('source_urls','source'=>'test')
    assert_equal({'ok'=>true,'url'=>c['sources'][0]['url'],'quota_url'=>c['sources'][0]['quota_url']},result)
    refute_includes JSON.generate(result),'private-fixture'
    assert_equal before,@b.version
    assert_nil @b.enqueued
    assert_equal({'ok'=>true,'url'=>c['sources'][1]['url'],'quota_url'=>''},@b.call('source_urls','source'=>'other'))
    %w[missing ../test].each do |id|
      result=@b.call('source_urls','source'=>id)
      refute result['ok']
      refute_includes JSON.generate(result),c['sources'][0]['url']
      refute_includes JSON.generate(result),'quota-fixture'
    end
    acl=JSON.parse(File.read(File.expand_path('../root/usr/share/rpcd/acl.d/luci-app-hybrid-subscription.json',__dir__)))['luci-app-hybrid-subscription']
    refute_includes acl['read']['ubus']['luci.hybrid_subscription'],'source_urls'
    assert_includes acl['write']['ubus']['luci.hybrid_subscription'],'source_urls'
    output,status=Open3.capture2(RbConfig.ruby,File.expand_path('../root/usr/share/hybrid-subscription/cli.rb',__dir__),'list')
    assert status.success?
    declared=JSON.parse(output)
    assert_equal({'source'=>''},declared['source_urls'])
    assert_equal({'config'=>'','version'=>'','collections'=>[]},declared['save_config'])
  end
  def create_tracked_profile
    @b.put_source('test', YAML.dump('proxies'=>[@node.merge('type'=>'trojan')]), 'mihomo')
    request = {'profile'=>'main', 'format'=>'surge', 'id'=>'compatible', 'name'=>'Compatible', 'resolutions'=>'{}'}
    plan = @b.call('compatibility_plan', request)
    assert plan['ok'] && plan['ready'], plan.inspect
    result = @b.call('compatibility_create', request.merge('version'=>plan['version'], 'plan_token'=>plan['plan_token'], 'accepted_changes'=>plan['changes'].map { |change| change['code'] }))
    assert result['ok'] && result['created'], result.inspect
    request
  end
  def test_editor_cannot_forge_or_reset_conversion_strategy_baselines
    create_tracked_profile
    saved = @b.config['profiles'].last['compatibility']
    refute_nil saved
    c = @b.sanitized_config
    c['profiles'].last['compatibility']['source_digest'] = 'forged'
    c['profiles'].first['compatibility'] = {'source_profile'=>'compatible'}
    @b.save_config('config'=>JSON.generate(c), 'version'=>@b.version)
    assert_equal saved, @b.config['profiles'].last['compatibility']
    refute @b.config['profiles'].first.key?('compatibility')
    c = @b.sanitized_config
    c['profiles'].last.delete('compatibility')
    c['profiles'].last['name'] = 'My edited copy'
    @b.save_config('config'=>JSON.generate(c), 'version'=>@b.version)
    assert_equal saved, @b.config['profiles'].last['compatibility']
    status = @b.status['profiles'].find { |item| item['id'] == 'compatible' }['compatibility']
    assert status['target_changed']
    refute status['source_changed']
    review = @b.call('compatibility', 'profile'=>'compatible', 'review'=>true)
    assert review['ok'], review.inspect
    assert_equal 'main', review['profile']['id']
    assert_equal 'compatible', review['strategy']['id']
    c = @b.config
    c['profiles'].last.delete('compatibility')
    c['profiles'].first['notes'] = 'x' * (HybridSubscription::Backend::MAX_BYTES - JSON.generate(c).bytesize - 20)
    raw = JSON.generate(c)
    assert_operator raw.bytesize, :<=, HybridSubscription::Backend::MAX_BYTES
    assert_match(/size limit/, assert_raises(HybridSubscription::Error) { @b.save_config('config'=>raw, 'version'=>@b.version) }.message)
    assert_equal saved, @b.config['profiles'].last['compatibility']
  end
  def test_compatibility_update_only_changes_draft_after_fresh_exact_confirmation
    request = create_tracked_profile
    built = @b.build_profile('compatible')
    @b.publish({'release'=>built['release'], 'accepted_warnings'=>built['warnings'].map { |warning| warning['code'] }})
    info = @b.download_info('compatible')
    files = Dir.glob(File.join(@b.dir, '**', '*')).select { |file| File.file?(file) && !%w[config.json state.lock].include?(File.basename(file)) }.to_h { |file| [file, File.binread(file)] }
    c = @b.config
    c['groups'].find { |group| group['profile'] == 'main' }['name'] = 'Updated source group'
    c['profiles'].last['name'] = 'My Surge subscription'
    @b.save_config('config'=>JSON.generate(c), 'version'=>@b.version)
    plan = @b.call('compatibility_plan', request.merge('operation'=>'reapply'))
    assert plan['ok'] && plan['ready'], plan.inspect
    apply = request.merge('version'=>plan['version'], 'plan_token'=>plan['plan_token'], 'accepted_changes'=>plan['changes'].map { |change| change['code'] })
    before = @b.config
    refute @b.call('compatibility_update', apply.merge('accepted_changes'=>[]))['ok']
    refute @b.call('compatibility_update', apply.merge('accepted_changes'=>apply['accepted_changes'] + [apply['accepted_changes'].first]))['ok']
    refute @b.call('compatibility_update', apply.merge('plan_token'=>'stale'))['ok']
    refute @b.call('compatibility_update', apply.merge('version'=>'stale'))['ok']
    refute @b.call('compatibility_create', apply.merge('operation'=>'reapply'))['ok']
    assert_equal before, @b.config
    result = @b.call('compatibility_update', apply)
    assert result['ok'] && result['updated'], result.inspect
    assert_equal 'My Surge subscription', @b.config['profiles'].last['name']
    assert_equal 'Updated source group', @b.config['groups'].find { |group| group['profile'] == 'compatible' }['name']
    assert_equal info, @b.download_info('compatible')
    files.each { |file, content| assert_equal content, File.binread(file), file }
    state = @b.status['profiles'].find { |item| item['id'] == 'compatible' }['compatibility']
    refute state['needs_review'], state.inspect
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
    b.publish({'release'=>built['release'],'accepted_warnings'=>built['warnings'].map { |warning| warning['code'] }})
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
  def test_default_config_hides_quota_url_preserves_it_and_allows_explicit_clear
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
    b.publish({'release'=>build['release'],'accepted_warnings'=>build['warnings'].map { |warning| warning['code'] }})
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
    assert_raises(HybridSubscription::Error) { @b.publish({'release'=>build['release'],'accepted_warnings'=>[]}) }
    assert_raises(HybridSubscription::Error) { @b.publish({'release'=>build['release']},rollback:true) }
    pub=@b.publish({'release'=>build['release'],'accepted_warnings'=>build['warnings'].map { |w| w['code'] }})
    assert_equal build['release'],pub['release'];assert_nil @b.enqueued
    assert @b.status['releases'][0]['ever_published']
    @b.publish({'release'=>build['release']},rollback:true)
  end
  def test_changed_source_invalidates_candidate
    r=@b.build_profile('main');@node['password']='new-value';@b.put_source('test',YAML.dump('proxies'=>[@node]),'mihomo')
    assert_raises(HybridSubscription::Error) { @b.publish({'release'=>r['release'],'accepted_warnings'=>r['warnings'].map { |w| w['code'] }}) }
  end
  def test_source_refresh_summary_covers_initial_import_and_direct_profile_references
    expected={'changed'=>true,'initial'=>true,'before_nodes'=>0,'after_nodes'=>1,'added'=>1,'removed'=>0,'updated'=>0,'order_changed'=>false}
    assert_equal expected,@b.caches['test']['meta']['last_refresh']
    c=@b.config
    c['profiles'] << c['profiles'][0].merge('id'=>'copy','name'=>'Copy')
    c['profiles'] << c['profiles'][0].merge('id'=>'unrelated','sources'=>[])
    @b.atomic(@b.path('config.json'),c)
    result=@b.put_source('test',YAML.dump('proxies'=>[@node]),'mihomo')
    assert_equal [{'id'=>'main','name'=>'Main'},{'id'=>'copy','name'=>'Copy'}],result['affected_profiles']
    assert_equal result['changes'],@b.status['sources'][0]['last_refresh']
    refute @b.caches['test']['meta']['last_refresh'].key?('affected_profiles')
    refute_includes JSON.generate(result),@node['password']
  end
  def test_identical_refresh_ignores_formatting_and_hash_order_and_keeps_candidate_publishable
    built=@b.build_profile('main')
    before=@b.caches['test']
    reordered=@node.to_a.reverse.to_h
    content="# Provider notice changed\n"+YAML.dump('proxies'=>[reordered])
    result=@b.put_source('test',content,'mihomo',"Subscription-Userinfo: total=456\n")
    expected={'changed'=>false,'initial'=>false,'before_nodes'=>1,'after_nodes'=>1,'added'=>0,'removed'=>0,'updated'=>0,'order_changed'=>false}
    assert_equal expected,result['changes']
    after=@b.caches['test']
    assert_equal expected,after['meta']['last_refresh']
    assert_equal JSON.generate(before['nodes']),JSON.generate(after['nodes'])
    refute_equal before['meta']['generation'],after['meta']['generation']
    refute_equal before['meta']['sha256'],after['meta']['sha256']
    assert_equal 456,after['meta']['quota']['total']
    @b.publish({'release'=>built['release'],'accepted_warnings'=>built['warnings'].map { |w| w['code'] }})
    assert_equal 'current',@b.status['profiles'][0]['draft_status']
  end
  def test_source_refresh_counts_added_removed_updated_and_common_node_order
    first=@node.merge('name'=>'First');second=@node.merge('name'=>'Second');removed=@node.merge('name'=>'Removed')
    @b.put_source('test',YAML.dump('proxies'=>[first,second,removed]),'mihomo')
    result=@b.put_source('test',YAML.dump('proxies'=>[second.merge('password'=>'changed-secret'),first,@node.merge('name'=>'Added')]),'mihomo')
    assert_equal({'changed'=>true,'initial'=>false,'before_nodes'=>3,'after_nodes'=>3,'added'=>1,'removed'=>1,'updated'=>1,'order_changed'=>true},result['changes'])
    assert_equal result['changes'],@b.caches['test']['meta']['last_refresh']
    refute_includes JSON.generate(result),'changed-secret'
    result=@b.put_source('test',YAML.dump('proxies'=>[first,second.merge('password'=>'changed-secret'),@node.merge('name'=>'Added')]),'mihomo')
    assert_equal({'changed'=>true,'initial'=>false,'before_nodes'=>3,'after_nodes'=>3,'added'=>0,'removed'=>0,'updated'=>0,'order_changed'=>true},result['changes'])
  end
  def test_node_additions_and_removals_do_not_count_as_common_node_reordering
    first=@node.merge('name'=>'First');second=@node.merge('name'=>'Second');added=@node.merge('name'=>'Added')
    @b.put_source('test',YAML.dump('proxies'=>[first,second]),'mihomo')
    result=@b.put_source('test',YAML.dump('proxies'=>[added,first,second]),'mihomo')
    assert_equal 1,result['changes']['added'];refute result['changes']['order_changed']
    result=@b.put_source('test',YAML.dump('proxies'=>[first,second]),'mihomo')
    assert_equal 1,result['changes']['removed'];refute result['changes']['order_changed']
  end
  def test_refresh_job_keeps_change_summary_and_does_not_publish_or_create_release
    b=queue_app
    b.fetch_content=YAML.dump('proxies'=>[@node,@node.merge('name'=>'New Node')])
    id=b.enqueue('refresh','test');b.run_job(id)
    job=b.job_status(id)
    assert_equal 'completed',job['state']
    assert_equal 1,job['result']['changes']['added']
    assert_equal [{'id'=>'main','name'=>'Main'}],job['result']['affected_profiles']
    assert_equal job['result']['changes'],b.caches['test']['meta']['last_refresh']
    assert_empty b.releases;assert_empty b.published
    assert_equal({'draft_status'=>'unpublished'},b.profile_draft_status(b.config['profiles'][0],nil,b.engine))
  end
  def test_profile_draft_status_compares_exports_without_unrelated_or_runtime_changes
    published=publish_build(@b)
    assert_equal 'current',@b.status['profiles'][0]['draft_status']
    c=@b.config
    c['settings']['base_url']='https://downloads.invalid'
    c['settings']['openclash_auto_apply']=true
    c['sources'][0]['update_mode']='scheduled'
    c['sources'] << {'id'=>'unused','name'=>'Unused','enabled'=>true,'url'=>'','format'=>'mihomo'}
    @b.atomic(@b.path('config.json'),c)
    unused=@b.put_source('unused',YAML.dump('proxies'=>[@node.merge('name'=>'Unrelated','password'=>'other-password')]),'mihomo')
    assert_empty unused['affected_profiles']
    state=@b.caches['test'];state['meta'].merge!('quota'=>{'total'=>123},'quota_updated_at'=>@b.now,'attempt_at'=>@b.now,'error'=>'Previous fetch failed')
    @b.atomic(@b.source_path('test'),state)
    files=Dir.glob(@b.path('**','*')).select { |file| File.file?(file) }.to_h { |file| [file,Digest::SHA256.file(file).hexdigest] }
    assert_equal 'current',@b.status['profiles'][0]['draft_status']
    assert_equal files,files.keys.to_h { |file| [file,Digest::SHA256.file(file).hexdigest] }
    assert_equal published['release'],@b.published['main']
    @b.put_source('test',YAML.dump('proxies'=>[@node.merge('password'=>'new-password')]),'mihomo')
    assert_equal 'changed',@b.status['profiles'][0]['draft_status']
    assert_equal published['release'],@b.published['main']
  end
  def test_profile_draft_status_detects_profile_and_format_changes_and_invalid_drafts
    publish_build(@b)
    c=@b.config;c['profiles'][0]['formats'].reverse!
    @b.atomic(@b.path('config.json'),c)
    assert_equal 'current',@b.status['profiles'][0]['draft_status']
    c['groups'][0]['name']='Renamed Group';@b.atomic(@b.path('config.json'),c)
    assert_equal 'changed',@b.status['profiles'][0]['draft_status']
    c['groups'][0]['name']='Proxy'
    c['profiles'][0]['formats']=['mihomo'];@b.atomic(@b.path('config.json'),c)
    assert_equal 'changed',@b.status['profiles'][0]['draft_status']
    c['profiles'][0]['formats']=[];@b.atomic(@b.path('config.json'),c)
    assert_equal 'invalid',@b.status['profiles'][0]['draft_status']
    c['profiles'][0]['formats']=['mihomo'];c['profiles'][0]['final_policy']='missing'
    @b.atomic(@b.path('config.json'),c)
    assert_equal 'invalid',@b.status['profiles'][0]['draft_status']
    renderer=Object.new
    def renderer.render(*); {'errors'=>['private-render-error'],'content'=>''}; end
    assert_equal({'draft_status'=>'invalid'},@b.profile_draft_status(c['profiles'][0],{},renderer))
    def renderer.render(*); raise 'https://private.invalid/credential-secret'; end
    assert_equal({'draft_status'=>'invalid'},@b.profile_draft_status(c['profiles'][0],{},renderer))
    assert_equal({'draft_status'=>'unpublished'},@b.profile_draft_status(c['profiles'][0],nil,renderer))
  end
  def test_filtered_information_node_changes_do_not_mark_published_output_stale
    c=@b.config;c['sources'][0]['exclude_filter']='^Info'
    @b.atomic(@b.path('config.json'),c)
    @b.put_source('test',YAML.dump('proxies'=>[@node,@node.merge('name'=>'Info Old')]),'mihomo')
    publish_build(@b)
    result=@b.put_source('test',YAML.dump('proxies'=>[@node.merge('name'=>'Info New','password'=>'new-information-value'),@node]),'mihomo')
    assert result['changes']['changed']
    assert_equal 1,result['changes']['added']
    assert_equal 1,result['changes']['removed']
    assert_equal 'current',@b.status['profiles'][0]['draft_status']
  end
  def test_profile_draft_status_supports_existing_manifests_without_new_metadata
    published=publish_build(@b)
    manifest=@b.release_meta(published['release'])
    refute manifest.key?('draft_status');refute manifest.key?('last_refresh')
    assert_equal 'current',@b.status['profiles'][0]['draft_status']
    manifest.delete('sha256')
    @b.atomic(File.join(@b.release_path(published['release']),'manifest.json'),manifest)
    assert_equal 'current',@b.status['profiles'][0]['draft_status']
    @b.put_source('test',YAML.dump('proxies'=>[@node.merge('port'=>8443)]),'mihomo')
    assert_equal 'changed',@b.status['profiles'][0]['draft_status']
  end
  def test_download_does_not_fetch_and_old_tokens_revoke
    r=@b.build_profile('main');@b.publish({'release'=>r['release'],'accepted_warnings'=>r['warnings'].map { |w| w['code'] }})
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
    r=@b.build_profile('main');@b.publish({'release'=>r['release'],'accepted_warnings'=>r['warnings'].map { |w| w['code'] }})
    File.write(File.join(@b.release_path(r['release']),'mihomo.yaml'),'tampered')
    env={'REMOTE_ADDR'=>'127.0.0.1','QUERY_STRING'=>'profile=main&format=mihomo&token='+@b.download_info('main')['token']}
    assert_equal 503,HybridSubscription::Download.new(@b).response(env)[0]
  end
  def test_shadowrocket_build_publish_and_authenticated_download
    @b.put_source('test', YAML.dump('proxies'=>[@node.merge('type'=>'anytls', 'alpn'=>['h2'], 'idle-session-timeout'=>60)]), 'mihomo')
    @c['profiles'][0]['formats'] = ['shadowrocket']
    @b.save_config('config'=>JSON.generate(@c), 'version'=>@b.version)
    build = @b.build_profile('main')
    assert_equal ['shadowrocket'], build['formats']
    assert_raises(HybridSubscription::Error) { @b.publish({'release'=>build['release'], 'accepted_warnings'=>[]}) }
    @b.publish({'release'=>build['release'], 'accepted_warnings'=>build['warnings'].map { |warning| warning['code'] }})
    endpoint = HybridSubscription::Download.new(@b)
    info = @b.download_info('main')
    env = {'REMOTE_ADDR'=>'127.0.0.1', 'QUERY_STRING'=>'profile=main&format=shadowrocket&token='+info['token']}
    status, headers, body = endpoint.response(env)
    assert_equal 200, status
    assert_equal 'application/yaml; charset=utf-8', headers['Content-Type']
    assert_includes headers['Content-Disposition'], 'main-shadowrocket.yaml'
    document = YAML.safe_load(body, permitted_classes: [], permitted_symbols: [], aliases: false)
    assert_equal 'anytls', document['proxies'][0]['type']
    assert_equal 60, document['proxies'][0]['idle-session-timeout']
    assert_equal ['h2'], document['proxies'][0]['alpn']
    refute_empty document['proxy-groups']
    refute_empty document['rules']
    assert_includes body, 'private-password'
    assert_equal @b.release_meta(build['release'])['sha256']['shadowrocket'], Digest::SHA256.hexdigest(body)
    assert_equal 403, endpoint.response(env.merge('QUERY_STRING'=>'profile=main&format=shadowrocket&token=wrong'))[0]
    assert_equal 200, endpoint.response(env.merge('REQUEST_METHOD'=>'HEAD'))[0]
    assert_empty endpoint.response(env.merge('REQUEST_METHOD'=>'HEAD'))[2]
    File.write(File.join(@b.release_path(build['release']), 'shadowrocket.yaml'), 'tampered')
    assert_equal 503, endpoint.response(env)[0]
    assert_nil @b.enqueued
  end

  def test_shadowrocket_rule_set_url_is_validated_on_save
    @c['rule_sets'] = [{'id'=>'remote', 'shadowrocket_url'=>'file:///etc/passwd'}]
    before = @b.version
    assert_raises(HybridSubscription::Error) { @b.save_config('config'=>JSON.generate(@c), 'version'=>before) }
    assert_equal before, @b.version
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
    r=@b.build_profile('main');@b.publish({'release'=>r['release'],'accepted_warnings'=>r['warnings'].map { |w| w['code'] }})
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
    b.publish({'release'=>built['release'],'accepted_warnings'=>built['warnings'].map { |w| w['code'] }})
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
  def test_subscription_http_failure_reports_final_status_without_exposing_response_or_changing_nodes
    b=queue_app
    b.fetch_content='private-response-body-with-token'
    b.fetch_error=HybridSubscription::Error.new('Command failed (curl)')
    [
      ["HTTP/2 404\r\nX-Private: private-header-token\r\n\r\n",404],
      ["HTTP/1.1 200 Connection established\r\n\r\nHTTP/1.1 302 Found\r\nLocation: https://invalid.example/private-redirect-token\r\n\r\nHTTP/2 400 Bad Request\r\n\r\n",400],
      ["HTTP/1.1 503 Unavailable\r\nX-Padding: #{'x'*70000}\r\n\r\nHTTP/2 404\r\n\r\n",404]
    ].each do |headers,status|
      before=b.caches['test']
      b.fetch_headers=headers
      error=assert_raises(HybridSubscription::Error) { b.refresh_source('test') }
      assert_equal "Subscription request failed (HTTP #{status}); cached nodes were kept",error.message
      after=b.caches['test']
      assert_equal before['nodes'],after['nodes']
      %w[generation cached_at sha256].each { |key| assert_equal before['meta'][key],after['meta'][key] }
      assert_equal error.message,after['meta']['error']
      refute_match(/private|https?:\/\//,after['meta']['error'])
      assert_empty Dir.glob(File.join(@tmp,'run','fetch-*'))
    end
    b.fetch_headers="HTTP/1.1 404 Not Found\r\n\r\nHTTP/2 200\r\n\r\n"
    error=assert_raises(HybridSubscription::Error) { b.refresh_source('test') }
    assert_equal 'Command failed (curl)',error.message
    b.fetch_headers="HTTP/2 400\r\n\r\n"
    b.fetch_error=HybridSubscription::Error.new('Operation timed out; existing cache and published releases remain unchanged')
    error=assert_raises(HybridSubscription::Error) { b.refresh_source('test') }
    assert_equal b.fetch_error.message,error.message
  end
  def test_subscription_http_failure_does_not_overwrite_a_concurrent_import
    b=queue_app
    b.fetch_content='private-response-body'
    b.fetch_headers="HTTP/2 404\r\n\r\n"
    b.fetch_error=HybridSubscription::Error.new('Command failed (curl)')
    imported=nil
    b.fetch_hook=proc { b.put_source('test',YAML.dump('proxies'=>[@node.merge('name'=>'Imported')]),'mihomo');imported=b.caches['test'] }
    error=assert_raises(HybridSubscription::Error) { b.refresh_source('test') }
    assert_match(/HTTP 404/,error.message)
    assert_equal imported,b.caches['test']
    assert_nil b.caches['test']['meta']['error']
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
