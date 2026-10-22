# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../root/usr/share/hybrid-subscription/openclash'

class OpenClashTest < Minitest::Test
  class Adapter < HybridSubscription::OpenClash
    attr_accessor :force_verify_failure

    private

    def verify_running(profile_id, candidate)
      raise Error, 'OpenClash did not load the published policy.' if force_verify_failure
      runtime = read_yaml(path("/etc/openclash/HybridSubscriptions-#{profile_id}.yaml"))
      raise Error, 'Policy changed.' unless policy_matches?(candidate,runtime)
      true
    end
  end

  def setup
    @root = Dir.mktmpdir('hybrid-openclash-test')
    @calls = []
    @uci = { 'config_path' => '/etc/openclash/config/Hybrid.yaml', 'cn_port' => '9090' }
    @sections = { 'config' => { '.type' => 'openclash', 'config_path' => @uci['config_path'] } }
    @version = 'Mihomo Meta alpha-smart-test'
    write('/etc/init.d/openclash', '# service')
    write('/etc/openclash/core/clash_meta', 'test core')
    write('/etc/config/openclash', 'original uci')
    write('/etc/openclash/custom/openclash_custom_overwrite.sh', "#!/bin/sh\nlegacy-hook \"$1\"\nexit 0\n")
    write('/etc/openclash/config/Hybrid.yaml', YAML.dump('proxies' => []))
    @candidate = {
      'proxies' => [{ 'name' => 'Node', 'type' => 'ss', 'server' => 'test.invalid', 'port' => 443, 'cipher' => 'aes-128-gcm', 'password' => 'private' }],
      'proxy-groups' => [{ 'name' => 'Proxy', 'type' => 'select', 'proxies' => ['Node'] }],
      'rules' => ['MATCH,Proxy']
    }
    @artifact = write('/etc/hybrid-subscription/releases/release-1/mihomo.yaml', YAML.dump(@candidate))
    @config = { 'profiles' => [{ 'id' => 'main', 'sources' => [] }], 'sources' => [] }
    @adapter = Adapter.new(@root, command_runner: method(:run_command))
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def write(name, content)
    filename = File.join(@root, name.sub(%r{\A/}, ''))
    FileUtils.mkdir_p(File.dirname(filename))
    File.write(filename, content)
    filename
  end

  def read(name)
    File.read(File.join(@root, name.sub(%r{\A/}, '')))
  end

  def run_command(argv, _timeout)
    @calls << argv
    return [@version, true] if argv.last == '-v'
    return [JSON.generate('values' => @sections), true] if argv[0] == '/bin/ubus'
    if argv[0] == '/sbin/uci'
      if argv[1..2] == ['-q', 'get']
        value = @uci[argv.last.sub('openclash.config.', '')]
        return [value.to_s, !value.nil?]
      end
      if argv[1] == 'set'
        key, value = argv.last.split('=', 2)
        @uci[key.sub('openclash.config.', '')] = value
        write('/etc/config/openclash', JSON.generate(@uci))
      end
    end
    if argv == ['/etc/init.d/openclash', 'restart']
      raw = @uci['config_path']
      if raw.start_with?('/etc/openclash/config/HybridSubscriptions-') && File.file?(File.join(@root, raw))
        write('/etc/openclash/' + File.basename(raw), read(raw))
      end
    end
    ['', true]
  end

  def test_status_never_returns_private_urls_or_api_password
    status = @adapter.status
    assert_equal true, status['installed']
    assert_equal 'Hybrid.yaml', status['active_config']
    assert_equal false, status['integration']
    assert_equal @version, status['version']
    refute status.keys.any? { |key| key.match?(/url|secret|password/) }
  end

  def test_import_is_read_only_manual_and_preserves_file_cache
    write('/etc/openclash/config/Provider.yaml', YAML.dump('proxies' => @candidate['proxies']))
    write('/etc/openclash/config/Hybrid.yaml', YAML.dump('proxy-providers' => {
      'Provider' => { 'type' => 'file', 'path' => './proxy_provider/../config/Provider.yaml' }
    }))
    @sections['cfg123'] = { '.type' => 'config_subscribe', 'name' => 'Provider', 'address' => 'https://example.invalid/sub?token=private', 'sub_ua' => 'client', 'enabled' => '1' }
    result = @adapter.import_sources
    assert_equal 1, result['sources'].length
    source = result['sources'].first
    assert_equal 'manual', source['update_mode']
    assert_equal false, source['takeover']
    assert_equal 'cfg123', source['openclash_section']
    assert_equal 'https://example.invalid/sub?token=private', source['url']
    assert_equal 'client', source['user_agent']
    assert_equal @candidate['proxies'], result['caches'][source['id']]['nodes']
    assert_equal 'original uci', read('/etc/config/openclash')
    refute @calls.any? { |argv| argv.include?('set') || argv.include?('restart') || argv.first.include?('curl') }
  end

  def test_import_rejects_provider_directory_escape
    write('/etc/openclash/config/Hybrid.yaml', YAML.dump('proxy-providers' => {
      'outside' => { 'type' => 'file', 'path' => '../../private.yaml' }
    }))
    assert_raises(HybridSubscription::OpenClash::Error) { @adapter.import_sources }
  end

  def test_apply_rejects_ids_and_files_outside_release_directory
    assert_raises(HybridSubscription::OpenClash::Error) { @adapter.apply('../../bad', @artifact, @config) }
    other = write('/tmp/mihomo.yaml', YAML.dump(@candidate))
    assert_raises(HybridSubscription::OpenClash::Error) { @adapter.apply('main', other, @config) }
    File.symlink(other, File.join(File.dirname(@artifact), 'escape.yaml'))
    assert_raises(HybridSubscription::OpenClash::Error) { @adapter.apply('main', File.join(File.dirname(@artifact), 'escape.yaml'), @config) }
    refute @calls.any? { |argv| argv.include?('restart') }
  end

  def test_smart_release_requires_existing_smart_core
    @candidate['proxy-groups'][0]['type'] = 'smart'
    write('/etc/hybrid-subscription/releases/release-1/mihomo.yaml', YAML.dump(@candidate))
    @version = 'Mihomo Meta alpha-standard'
    error = assert_raises(HybridSubscription::OpenClash::Error) { @adapter.apply('main', @artifact, @config) }
    assert_match(/Install it in OpenClash/, error.message)
    refute @calls.any? { |argv| argv.include?('set') || argv.include?('restart') }
  end

  def test_apply_validates_arms_backup_and_restarts_once
    result = @adapter.apply('main', @artifact, @config)
    assert_equal true, result['ok']
    assert_equal 1, @calls.count { |argv| argv == ['/etc/init.d/openclash', 'restart'] }
    validate = @calls.index { |argv| argv.include?('-t') }
    guard = @calls.index { |argv| argv.include?('guard') }
    mutate = @calls.index { |argv| argv.include?('set') }
    assert validate < guard && guard < mutate
    assert_equal 'original uci', read("/etc/hybrid-subscription/openclash-backups/#{result['backup']}/file-0")
    manifest = JSON.parse(read("/etc/hybrid-subscription/openclash-backups/#{result['backup']}/manifest.json"))
    assert_equal 'committed', manifest['state']
    hook = read('/etc/openclash/custom/openclash_custom_overwrite.sh')
    assert hook.index('BEGIN hybrid-subscription') < hook.index('legacy-hook')
    assert_includes hook, "legacy-hook \"$1\"\nexit 0\n"
    assert_equal 0o600, File.stat(File.join(@root, '/etc/openclash/config/HybridSubscriptions-main.yaml')).mode & 0o777
    refute @calls.any? { |argv| argv.join.include?('auto_smart_switch') || argv.join.include?('smart_collect') || argv.join.include?('lgbm') }
  end

  def test_validation_disables_every_listener_before_using_real_core
    @candidate.merge!('mixed-port' => 9999, 'external-controller' => '0.0.0.0:9090', 'listeners' => [{ 'name' => 'bad' }], 'dns' => { 'enable' => true }, 'tun' => { 'enable' => true })
    directory = File.join(@root, 'tmp/check')
    @adapter.send(:validate_candidate, @candidate, directory)
    check = YAML.safe_load(File.read(File.join(directory, 'check.yaml')))
    assert_equal 0, check['mixed-port']
    assert_equal false, check['allow-lan']
    assert_equal true, check['dns']['enable']
    assert_equal '127.0.0.1:0', check['dns']['listen']
    assert_equal false, check['tun']['enable']
    refute check.key?('external-controller')
    refute check.key?('listeners')
    assert @calls.last.include?('-t')
    assert @calls.last.any? { |arg| arg.start_with?('SAFE_PATHS=') }
  end

  def test_failed_apply_restores_uci_hook_and_previous_managed_file
    original_hook = read('/etc/openclash/custom/openclash_custom_overwrite.sh')
    write('/etc/openclash/config/HybridSubscriptions-main.yaml', 'previous managed file')
    @adapter.force_verify_failure = true
    error = assert_raises(HybridSubscription::OpenClash::Error) { @adapter.apply('main', @artifact, @config) }
    assert_match(/Previous OpenClash configuration restored/, error.message)
    assert_equal 'original uci', read('/etc/config/openclash')
    assert_equal original_hook, read('/etc/openclash/custom/openclash_custom_overwrite.sh')
    assert_equal 'previous managed file', read('/etc/openclash/config/HybridSubscriptions-main.yaml')
    assert_equal 2, @calls.count { |argv| argv == ['/etc/init.d/openclash', 'restart'] }
  end

  def test_guard_recovers_abandoned_apply_without_touching_unrelated_configs
    journal = @adapter.send(:prepare_transaction, 'main')
    write('/etc/config/openclash', 'failed settings')
    write('/etc/openclash/config/HybridSubscriptions-main.yaml', 'failed config')
    @adapter.guard(journal, 0)
    assert_equal 'original uci', read('/etc/config/openclash')
    refute File.exist?(File.join(@root, 'etc/openclash/config/HybridSubscriptions-main.yaml'))
    assert File.exist?(File.join(@root, 'etc/openclash/config/Hybrid.yaml'))
    assert_equal 'restored', JSON.parse(File.read(File.join(journal, 'manifest.json')))['state']
  end

  def test_preserve_changes_policy_only_and_refuses_other_paths
    write('/etc/openclash/config/HybridSubscriptions-main.yaml', YAML.dump(@candidate))
    runtime = @candidate.merge('rules' => ['MATCH,DIRECT'], 'secret' => 'runtime-only', 'mixed-port' => 7893, 'dns' => { 'enable' => true })
    generated = write('/tmp/HybridSubscriptions-main.yaml', YAML.dump(runtime))
    @adapter.preserve(generated)
    result = YAML.safe_load(File.read(generated))
    assert_equal @candidate['rules'], result['rules']
    assert_equal 'runtime-only', result['secret']
    assert_equal 7893, result['mixed-port']
    assert_equal({ 'enable' => true }, result['dns'])
    assert_raises(HybridSubscription::OpenClash::Error) { @adapter.preserve(write('/tmp/Hybrid.yaml', YAML.dump(runtime))) }
    assert_raises(HybridSubscription::OpenClash::Error) { @adapter.preserve(write('/tmp/elsewhere/HybridSubscriptions-main.yaml', YAML.dump(runtime))) }
  end

  def test_hook_installation_is_idempotent
    @adapter.send(:install_hook)
    once = read('/etc/openclash/custom/openclash_custom_overwrite.sh')
    @adapter.send(:install_hook)
    assert_equal once, read('/etc/openclash/custom/openclash_custom_overwrite.sh')
    assert_equal 1, once.scan(HybridSubscription::OpenClash::HOOK_BEGIN).length
  end

  def test_preserves_native_dns_and_policy_with_openclash_listen
    candidate=@candidate.merge('dns'=>{'enable'=>true,'nameserver'=>['https://doh.invalid/dns-query'],'fake-ip-filter'=>['+.qq.com','rule-set:cn']},'sniffer'=>{'enable'=>true},'ipv6'=>false,'profile'=>{'store-selected'=>true})
    write('/etc/openclash/config/HybridSubscriptions-main.yaml',YAML.dump(candidate))
    runtime=@candidate.merge('dns'=>{'enable'=>true,'listen'=>'0.0.0.0:7874','nameserver'=>['1.1.1.1'],'fake-ip-filter'=>[]},'sniffer'=>{'enable'=>false},'ipv6'=>true,'mixed-port'=>7893,'secret'=>'router-only')
    generated=write('/tmp/HybridSubscriptions-main.yaml',YAML.dump(runtime))
    @adapter.preserve(generated)
    actual=YAML.safe_load(File.read(generated))
    assert_equal candidate['dns'].merge('listen'=>'0.0.0.0:7874'),actual['dns']
    assert_equal candidate['sniffer'],actual['sniffer']
    assert_equal candidate['profile'],actual['profile']
    assert_equal false,actual['ipv6']
    assert_equal 7893,actual['mixed-port']
    assert_equal 'router-only',actual['secret']
    assert @adapter.send(:policy_matches?,candidate,actual)
    actual['dns']['fake-ip-filter']=[]
    refute @adapter.send(:policy_matches?,candidate,actual)
    assert @adapter.send(:policy_matches?,@candidate,runtime)
  end

  def test_export_validation_keeps_rematch_subrules_and_never_fetches_providers
    captured=nil
    candidate=Marshal.load(Marshal.dump(@candidate))
    candidate['proxies'] << {'name'=>'Region route','type'=>'rematch','target-sub-rule'=>'region'}
    candidate['proxy-groups'][0]['proxies'] << 'Region route'
    candidate['sub-rules']={'region'=>['MATCH,DIRECT']}
    candidate['dns']={'enable'=>true,'nameserver'=>['https://dns.invalid/query'],'listen'=>'0.0.0.0:5353'}
    candidate['rule-providers']={'remote'=>{'type'=>'http','url'=>'https://rules.invalid/private','path'=>'./rule_provider/not-cached.txt','behavior'=>'classical','format'=>'text','interval'=>600}}
    candidate['rules'].unshift('RULE-SET,remote,DIRECT')
    runner=lambda do |argv,timeout|
      captured=YAML.safe_load(File.read(argv[argv.index('-f')+1])) if argv.include?('-t')
      run_command(argv,timeout)
    end
    adapter=Adapter.new(@root,command_runner:runner)
    assert_equal({'checked'=>true},adapter.validate_export(YAML.dump(candidate)))
    assert_equal candidate['proxies'],captured['proxies']
    assert_equal candidate['sub-rules'],captured['sub-rules']
    assert_equal true,captured['dns']['enable']
    assert_equal '127.0.0.1:0',captured['dns']['listen']
    assert_equal 'file',captured['rule-providers']['remote']['type']
    refute captured['rule-providers']['remote'].key?('url')
    refute @calls.any? { |argv| argv.first.include?('curl') || argv.include?('restart') || argv.include?('set') }
    assert_empty Dir.glob(File.join(@root,'tmp/hybrid-subscription/export-check-*'))
  end

  def test_provider_validation_copies_local_cache_instead_of_mutating_original
    original=write('/etc/openclash/rule_provider/local.list',"DOMAIN-SUFFIX,example.com\n")
    @candidate['rule-providers']={'local'=>{'type'=>'file','path'=>'./rule_provider/local.list','behavior'=>'classical','format'=>'text'}}
    directory=File.join(@root,'tmp/check')
    @adapter.send(:validate_candidate,@candidate,directory)
    check=YAML.safe_load(File.read(File.join(directory,'check.yaml')))
    isolated=check['rule-providers']['local']['path']
    refute_equal original,isolated
    refute File.symlink?(isolated)
    assert_equal File.binread(original),File.binread(isolated)
    @candidate['rule-providers']['local']['path']='./rule_provider/missing.list'
    assert_raises(HybridSubscription::OpenClash::Error) { @adapter.validate_export(YAML.dump(@candidate)) }
  end

  def test_native_geodata_validation_fails_locally_without_downloading
    @candidate['rules'].unshift('GEOSITE,anthropic,Proxy')
    error=assert_raises(HybridSubscription::OpenClash::Error) { @adapter.validate_export(YAML.dump(@candidate)) }
    assert_match(/geodata is missing/,error.message)
    refute @calls.any? { |argv| argv.include?('-t') }
    File.unlink(File.join(@root,'etc/openclash/core/clash_meta'))
    assert_equal false,@adapter.validate_export(YAML.dump(@candidate))['checked']
  end

  def test_validation_reuses_exact_active_remote_rule_cache_without_seeding
    provider = { 'type' => 'http', 'url' => 'https://rules.invalid/current', 'behavior' => 'domain', 'format' => 'mrs', 'path' => './rule_provider/old.mrs' }
    original = write('/etc/openclash/rule_provider/old.mrs', 'cached-binary')
    write('/etc/openclash/config/Hybrid.yaml', YAML.dump('rule-providers' => { 'old' => provider }))
    @candidate['rule-providers'] = { 'new' => provider.merge('path' => './rule_provider/hybrid-new-abc123.mrs') }
    directory = File.join(@root, 'tmp/cache-check')
    @adapter.send(:validate_candidate, @candidate, directory)
    isolated = YAML.safe_load(File.read(File.join(directory, 'check.yaml')))['rule-providers']['new']
    assert_equal 'file', isolated['type']
    assert_equal File.binread(original), File.binread(isolated['path'])
    refute File.exist?(File.join(@root, 'etc/openclash/rule_provider/hybrid-new-abc123.mrs'))
    refute @calls.any? { |argv| argv.first.include?('curl') || argv.include?('restart') }
  end

  def test_missing_mrs_uses_inline_placeholder_for_offline_reference_validation
    @candidate['rule-providers'] = { 'new' => { 'type' => 'http', 'url' => 'https://rules.invalid/new', 'behavior' => 'domain', 'format' => 'mrs', 'path' => './rule_provider/hybrid-new.mrs' } }
    directory = File.join(@root, 'tmp/mrs-check')
    @adapter.send(:validate_candidate, @candidate, directory)
    provider = YAML.safe_load(File.read(File.join(directory, 'check.yaml')))['rule-providers']['new']
    assert_equal({ 'type' => 'inline', 'behavior' => 'domain', 'payload' => [] }, provider)
  end

  def test_cache_seed_only_creates_absent_owned_paths_with_matching_definition
    provider = { 'type' => 'http', 'url' => 'https://rules.invalid/current', 'behavior' => 'classical', 'format' => 'text', 'path' => './rule_provider/old.txt' }
    write('/etc/openclash/rule_provider/old.txt', "DOMAIN-SUFFIX,example.com\n")
    write('/etc/openclash/config/Hybrid.yaml', YAML.dump('rule-providers' => { 'old' => provider }))
    @candidate['rule-providers'] = {
      'new' => provider.merge('path' => './rule_provider/hybrid-new-a1.txt'),
      'unowned' => provider.merge('path' => './rule_provider/unowned.txt'),
      'different' => provider.merge('path' => './rule_provider/hybrid-different.txt', 'url' => 'https://rules.invalid/different'),
      'format' => provider.merge('path' => './rule_provider/hybrid-format.yaml', 'format' => 'yaml'),
      'behavior' => provider.merge('path' => './rule_provider/hybrid-behavior.txt', 'behavior' => 'domain')
    }
    @adapter.send(:seed_rule_caches, @candidate)
    assert_equal read('/etc/openclash/rule_provider/old.txt'), read('/etc/openclash/rule_provider/hybrid-new-a1.txt')
    %w[unowned.txt hybrid-different.txt hybrid-format.yaml hybrid-behavior.txt].each do |name|
      refute File.exist?(File.join(@root, 'etc/openclash/rule_provider', name))
    end
    write('/etc/openclash/rule_provider/hybrid-new-a1.txt', 'newer cache')
    @adapter.send(:seed_rule_caches, @candidate)
    assert_equal 'newer cache', read('/etc/openclash/rule_provider/hybrid-new-a1.txt')
    assert_empty Dir.glob(File.join(@root, 'etc/openclash/rule_provider/.hybrid-cache-*'))
  end

  def test_cache_seed_refuses_symlink_directory_and_oversized_cache
    provider = { 'type' => 'http', 'url' => 'https://rules.invalid/current', 'behavior' => 'domain', 'format' => 'mrs', 'path' => './old.mrs' }
    original = write('/etc/openclash/old.mrs', 'cached-binary')
    write('/etc/openclash/config/Hybrid.yaml', YAML.dump('rule-providers' => { 'old' => provider }))
    @candidate['rule-providers'] = { 'new' => provider.merge('path' => './rule_provider/hybrid-new.mrs') }
    directory = File.join(@root, 'etc/openclash/rule_provider')
    File.symlink(File.join(@root, 'etc/openclash/core'), directory)
    assert_raises(HybridSubscription::OpenClash::Error) { @adapter.send(:seed_rule_caches, @candidate) }
    File.unlink(directory)
    File.truncate(original, HybridSubscription::OpenClash::MAX_CACHE_BYTES + 1)
    assert_raises(HybridSubscription::OpenClash::Error) { @adapter.send(:seed_rule_caches, @candidate) }
    refute File.exist?(File.join(directory, 'hybrid-new.mrs'))
  end

  def test_local_api_check_rejects_wrong_members_and_keeps_secret_out_of_arguments
    seen_config = nil
    calls = []
    response = { 'proxies' => { 'Node' => {}, 'Proxy' => { 'all' => ['Wrong Node'] } } }
    runner = lambda do |argv, _timeout|
      calls << argv
      if argv.first == '/sbin/uci'
        ['9090', true]
      else
        seen_config = File.read(argv[argv.index('--config') + 1])
        [JSON.generate(response), true]
      end
    end
    adapter = Adapter.new(@root, command_runner: runner)
    secret = "private\\secret\""
    refute adapter.send(:api_ready?, { 'secret' => secret }, @candidate)
    refute calls.flatten.join.include?(secret)
    assert_equal "header = \"Authorization: Bearer private\\\\secret\\\"\"\n", seen_config
    response['proxies']['Proxy']['all'] = ['Node']
    assert adapter.send(:api_ready?, { 'secret' => secret }, @candidate)
    refute File.exist?(File.join(@root, "tmp/hybrid-subscription/api-check-#{Process.pid}.conf"))
  end

  def test_takeover_requires_opt_in_exact_source_url_and_selected_profile
    @sections['cfg123'] = { '.type' => 'config_subscribe', 'address' => 'https://example.invalid/a' }
    @config['sources'] = [{ 'id' => 'one', 'url' => 'https://example.invalid/a', 'openclash_section' => 'cfg123', 'takeover' => true }]
    @config['profiles'][0]['sources'] = ['one']
    @adapter.send(:takeover_sources, @config, @config['profiles'][0])
    assert_includes @calls, ['/sbin/uci', 'set', 'openclash.cfg123.enabled=0']
    @config['sources'][0]['url'] = 'https://example.invalid/changed'
    assert_raises(HybridSubscription::OpenClash::Error) { @adapter.send(:takeover_sources, @config, @config['profiles'][0]) }
    @calls.clear
    @config['sources'][0]['takeover'] = false
    @adapter.send(:takeover_sources, @config, @config['profiles'][0])
    refute @calls.any? { |argv| argv.include?('set') }
  end

  def test_default_runner_bounds_timeout_and_redacts_command_errors
    adapter = HybridSubscription::OpenClash.new(@root)
    assert_equal ["hello\n", true], adapter.send(:command, ['/bin/echo', 'hello'])
    error = assert_raises(HybridSubscription::OpenClash::Error) { adapter.send(:command, ['/bin/sh', '-c', 'sleep 2'], timeout: 0.05) }
    assert_equal 'An OpenClash command timed out.', error.message
    error = assert_raises(HybridSubscription::OpenClash::Error) { adapter.send(:command, ['/bin/sh', '-c', 'echo private-token; exit 1']) }
    refute_includes error.message, 'private-token'
  end
end
