# frozen_string_literal: true
require 'json'
require 'yaml'
require 'digest'
require 'fileutils'
require 'open3'
require 'timeout'
require 'uri'
require 'ipaddr'
require_relative 'engine'
require_relative 'openclash'
require_relative 'quota'
require_relative 'regions'

module HybridSubscription
  class Error < StandardError; end unless const_defined?(:Error)
  class Backend
    FORMATS = %w[mihomo surge singbox].freeze
    COLLECTIONS = %w[sources profiles groups rule_sets rules rematches sub_rules regions].freeze
    ID = /\A[a-z][a-z0-9_-]{0,47}\z/
    MAX_BYTES = 2 * 1024 * 1024
    attr_reader :dir
    def initialize(dir = '/etc/hybrid-subscription', runtime = '/tmp/hybrid-subscription', adapter: nil, quota_adapter: nil)
      @dir, @runtime = dir, runtime
      @adapter = adapter || OpenClash.new
      @quota_adapter = quota_adapter || Quota.new(command: method(:command))
      [dir, runtime, File.join(dir, 'sources'), File.join(dir, 'releases'), File.join(runtime, 'jobs')].each { |p| FileUtils.mkdir_p(p, mode: 0700); File.chmod(0700, p) }
    end
    def now; Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'); end
    def random; File.binread('/dev/urandom', 24).unpack1('H*'); end
    def check_id(value)
      raise Error, 'Invalid identifier' unless value.is_a?(String) && ID.match?(value)
      value
    end
    def path(*parts); File.join(@dir, *parts); end
    def atomic(file, object, json: true)
      data = json ? JSON.generate(object) : object
      tmp = file + '.tmp-' + random[0, 10]
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0600) { |f| f.write(data); f.flush; f.fsync }
      File.rename(tmp, file)
    ensure
      File.unlink(tmp) if tmp && File.exist?(tmp)
    end
    def read(file, default = {})
      File.file?(file) ? JSON.parse(File.read(file)) : default
    end
    def locked
      File.open(path('state.lock'), File::RDWR | File::CREAT, 0600) { |f| f.flock(File::LOCK_EX); yield }
    end
    def blank_config
      {'schema'=>1, 'settings'=>{'access_mode'=>'lan_token', 'base_url'=>'', 'openclash_auto_apply'=>false, 'openclash_profile'=>'', 'converter_url'=>'http://127.0.0.1:25500'}, 'sources'=>[], 'profiles'=>[], 'groups'=>[], 'rule_sets'=>[], 'rules'=>[], 'rematches'=>[], 'sub_rules'=>[], 'regions'=>[]}
    end
    def config
      c = read(path('config.json'), blank_config)
      %w[rematches sub_rules regions].each { |key| c[key] ||= [] }
      c
    end
    def version(c = config); Digest::SHA256.hexdigest(JSON.generate(c)); end
    def safe_error(error)
      error.to_s.gsub(%r{https?://[^\s\]"']+}, '[URL]').gsub(/[\r\n]+/, ' ')[0, 600]
    end
    def command(argv, seconds: 15, input: nil)
      stem = File.join(@runtime, 'command-' + random)
      inp, outp, errp = stem+'.in', stem+'.out', stem+'.err'
      atomic(inp, input.to_s, json: false)
      [outp,errp].each { |p| File.open(p,File::WRONLY|File::CREAT|File::EXCL,0600) {} }
      pid = Process.spawn(*argv, in: inp, out: outp, err: errp, pgroup: true)
      _, status = Timeout.timeout(seconds) { Process.wait2(pid) }
      pid = nil
      raise Error, "Command failed (#{File.basename(argv.first)})" unless status.success?
      raise Error, 'Command output exceeds size limit' if File.size(outp) > MAX_BYTES * 4
      File.binread(outp)
    rescue Timeout::Error
      raise Error, 'Operation timed out; existing cache and published releases remain unchanged'
    ensure
      if pid
        begin; Process.kill('KILL', -pid); rescue Errno::ESRCH; end
        begin; Process.wait(pid); rescue Errno::ECHILD; end
      end
      [inp,outp,errp].compact.each { |p| File.unlink(p) if File.exist?(p) }
    end
    def url!(url, loopback: false)
      u = URI.parse(url)
      raise Error, 'URL must use HTTP or HTTPS' unless %w[http https].include?(u.scheme) && u.host && !url.match?(/[\x00-\x20\x7f]/)
      raise Error, 'Converter URL must use a loopback address' if loopback && !%w[127.0.0.1 ::1 localhost].include?(u.host)
      u
    rescue URI::InvalidURIError
      raise Error, 'Invalid URL format'
    end
    def sanitized_config
      c = JSON.parse(JSON.generate(config))
      c['sources'].each do |s|
        %w[url quota_url].each { |key| s['has_'+key] = !s.fetch(key, '').empty?; s[key] = '' }
      end
      c
    end
    def save_config(args)
      locked do
        current = config
        raise Error, 'Configuration was modified in another session; please reload before saving' unless args['version'] == version(current)
        raw = args['config']
        raise Error, 'Configuration exceeds the 2 MiB size limit' unless raw.is_a?(String) && raw.bytesize <= MAX_BYTES
        c = JSON.parse(raw)
        raise Error, 'Unsupported configuration schema version' unless c['schema'] == 1
        %w[rematches sub_rules regions].each { |key| c[key] ||= [] }
        COLLECTIONS.each do |key|
          raise Error, "#{key} must be a list" unless c[key].is_a?(Array) && c[key].length <= 5000
          ids = c[key].map { |row| check_id(row['id']) }
          raise Error, "#{key} contains duplicate identifiers" unless ids.uniq.length == ids.length
        end
        c['sources'].each do |s|
          old = current['sources'].find { |x| x['id'] == s['id'] }
          s['url'] = old.fetch('url', '') if s.fetch('url', '').empty? && old
          s['url'] ||= ''
          url!(s['url']) unless s['url'].empty?
          s.delete('has_url')
          s['quota_url'] = old.fetch('quota_url', '') if s.fetch('quota_url', '').empty? && old
          s['quota_url'] = '' if s.delete('clear_quota_url') == true
          s['quota_url'] ||= ''
          unless s['quota_url'].empty?
            status_uri = url!(s['quota_url'])
            raise Error, 'Quota URL must not contain credentials; use an API token instead' if status_uri.userinfo
            raise Error, 'Dedicated quota URL must not match the subscription URL' if same_url?(s['quota_url'], s['url'])
          end
          s.delete('has_quota_url')
          s['quota_via_subscription'] = false unless s.key?('quota_via_subscription')
          raise Error, 'Quota header query option must be a boolean' unless [true,false].include?(s['quota_via_subscription'])
          s['quota_max_age'] = Integer(s.fetch('quota_max_age', 86400))
          raise Error, 'Quota cache TTL must be between 60 and 31536000 seconds' unless s['quota_max_age'].between?(60,31536000)
          raise Error, 'Unsupported update mode' unless %w[manual scheduled].include?(s.fetch('update_mode', 'manual'))
          s['interval'] = Integer(s.fetch('interval', 86400))
          raise Error, 'Scheduled update interval must be at least 300 seconds' if s['interval'] < 300
          raise Error, 'Source name exceeds maximum length' if s.fetch('name', '').bytesize > 200
        end
        Regions.validate!(c['regions'], source_ids: c['sources'].map { |s| s['id'] })
        settings = c['settings']
        raise Error, 'Missing global settings' unless settings.is_a?(Hash)
        raise Error, 'Invalid download access mode' unless %w[lan_token token session].include?(settings['access_mode'])
        url!(settings['base_url']) unless settings.fetch('base_url', '').empty?
        url!(settings.fetch('converter_url', 'http://127.0.0.1:25500'), loopback: true)
        c['profiles'].each do |p|
          raise Error, 'Invalid export format' unless p['formats'].is_a?(Array) && (p['formats'] - FORMATS).empty?
        end
        c['rule_sets'].each { |r| %w[mihomo_url surge_url singbox_url].each { |k| url!(r[k]) unless r.fetch(k, '').empty? } }
        removed = published.keys - c['profiles'].map { |p| p['id'] }
        raise Error, 'Unpublish the profile before deleting it' unless removed.empty?
        c = c.select { |k,_| (COLLECTIONS + %w[schema settings]).include?(k) }
        atomic(path('config.json'), c)
        {'version'=>version(c)}
      end
    rescue JSON::ParserError, ArgumentError, TypeError
      raise Error, 'Invalid configuration field format'
    end
    def source(c, id)
      check_id(id)
      c['sources'].find { |x| x['id'] == id } || (raise Error, 'Subscription source does not exist')
    end
    def profile(c, id)
      check_id(id)
      c['profiles'].find { |x| x['id'] == id } || (raise Error, 'Subscription profile does not exist')
    end
    def source_path(id); path('sources', check_id(id) + '.json'); end
    def caches(c = config)
      c['sources'].each_with_object({}) { |s,h| h[s['id']] = read(source_path(s['id']), {'nodes'=>[], 'meta'=>{}}) }
    end
    def digest_inputs(c, cache)
      # Fetch-attempt timestamps do not change the identity of valid node data.
      Digest::SHA256.hexdigest(JSON.generate([c, cache.transform_values { |x| x['nodes'] }]))
    end
    def engine(c = config, cache = caches(c)); Engine.new(c, cache); end
    def quota(headers); Quota.parse(headers); end
    def same_url?(left, right)
      return false if left.to_s.empty? || right.to_s.empty?
      [left, right].map { |value| u=URI.parse(value); u.fragment=nil; u.normalize.to_s }.uniq.length == 1
    end
    def source_generation(id)
      state = read(source_path(id), {})
      state.fetch('meta', {})['generation'] || Digest::SHA256.hexdigest(JSON.generate(state['nodes']))
    end
    def refresh_current?(id, expected)
      current = config['sources'].find { |s| s['id'] == id }
      current && current['url'] == expected['url'] && current['enabled'] != false &&
        current.fetch('format', 'auto') == expected['format'] && source_generation(id) == expected['generation']
    end
    def put_source(id, content, format, headers = '', expected: nil)
      raise Error, 'Subscription content exceeds 2 MiB' if content.bytesize > MAX_BYTES
      nodes = Engine.import_nodes(content, format)
      raise Error, 'Subscription contains no valid nodes; previous cache retained' unless nodes.is_a?(Array) && !nodes.empty?
      state = {'nodes'=>nodes, 'meta'=>{'generation'=>random, 'cached_at'=>now, 'attempt_at'=>now, 'sha256'=>Digest::SHA256.hexdigest(content), 'error'=>nil}}
      locked do
        source(config, id)
        raise Error, 'Source or cache was updated concurrently; discarding stale fetch result' if expected && !refresh_current?(id, expected)
        old = read(source_path(id), {}).fetch('meta', {})
        %w[quota quota_generation quota_updated_at quota_attempt_at quota_origin quota_error].each { |key| state['meta'][key] = old[key] if old.key?(key) }
        values = quota(headers)
        state['meta'].merge!('quota'=>values,'quota_generation'=>random,'quota_updated_at'=>now,'quota_attempt_at'=>now,'quota_origin'=>'subscription_header','quota_error'=>nil) if values
        atomic(source_path(id), state)
      end
      {'source'=>id, 'nodes'=>nodes.length, 'cached_at'=>state['meta']['cached_at']}
    end
    def refresh_source(id)
      s, expected = locked do
        current = source(config, id)
        [current, {'url'=>current['url'], 'format'=>current.fetch('format','auto'), 'generation'=>source_generation(id)}]
      end
      raise Error, 'No subscription URL configured for this source; import a local file instead' if s.fetch('url', '').empty?
      raise Error, 'Subscription source is disabled' if s['enabled'] == false
      base = File.join(@runtime, 'fetch-' + random)
      body, headers = base + '.body', base + '.headers'
      argv = ['curl', '--silent', '--show-error', '--fail', '--location', '--max-redirs', '3', '--connect-timeout', '10', '--max-time', '40', '--max-filesize', MAX_BYTES.to_s, '--proto', '=http,https', '--proto-redir', '=http,https', '--dump-header', headers, '--output', body]
      argv += ['--user-agent', s['user_agent']] unless s.fetch('user_agent','').empty?
      argv += ['--url', s['url']]
      command(argv, seconds: 45)
      put_source(id, File.binread(body), s.fetch('format', 'auto'), File.read(headers), expected: expected)
    rescue StandardError => e
      locked do
        if expected && refresh_current?(id, expected)
          state = read(source_path(id), {'nodes'=>[], 'meta'=>{}})
          state['meta']['attempt_at'] = now
          state['meta']['error'] = safe_error(e)
          atomic(source_path(id), state)
        end
      end
      raise e
    ensure
      [body, headers].compact.each { |p| File.unlink(p) if File.exist?(p) }
    end
    def quota_current?(id, expected)
      s = config['sources'].find { |item| item['id'] == id }
      meta = read(source_path(id), {}).fetch('meta', {})
      s && s['url'].to_s == expected['url'] && s['quota_url'].to_s == expected['quota_url'] &&
        (s['quota_via_subscription'] == true) == expected['via_subscription'] &&
        s['user_agent'].to_s == expected['user_agent'] && meta['quota_generation'] == expected['generation']
    end
    def refresh_quota(id)
      s, expected = locked do
        current = source(config,id)
        meta = read(source_path(id), {}).fetch('meta', {})
        [current, {'url'=>current['url'].to_s,'quota_url'=>current['quota_url'].to_s,'via_subscription'=>current['quota_via_subscription']==true,'user_agent'=>current['user_agent'].to_s,'generation'=>meta['quota_generation']}]
      end
      snapshot = @quota_adapter.local_states([s])[id]
      independent = !s['quota_url'].to_s.empty?
      request_url = independent ? s['quota_url'] : (s['quota_via_subscription'] == true ? s['url'] : '')
      unless request_url.to_s.empty?
        uri = url!(request_url)
        raise Error, 'Quota URL must not contain credentials; use an API token instead' if uri.userinfo
        raise Error, 'Dedicated quota URL must not match any subscription URL' if independent && config['sources'].any? { |other| same_url?(request_url,other['url']) }
        raise Error, 'Invalid User-Agent for quota request' if s['user_agent'].to_s.match?(/[[:cntrl:]]/)
        # GET may consume a timed subscription window even when only headers are
        # read. Subscription URLs require opt-in; never follow redirects or retry.
        escaped = request_url.gsub(/[\\"]/) { |char| "\\#{char}" }
        request = "url = \"#{escaped}\"\n"
        argv = ['curl','--disable','--silent','--show-error','--fail','--head','--request','GET','--no-location','--connect-timeout','5','--max-time','15','--proto','=http,https','--config','-','--user-agent',s['user_agent'].to_s.empty? ? 'Clash' : s['user_agent']]
        locked { raise Error, 'Source or quota query settings changed; please retry' unless quota_current?(id,expected) }
        headers = command(argv,seconds:20,input:request)
        values = Quota.parse(headers)
        raise Error, 'No valid Subscription-Userinfo header received; previous quota state retained' unless values
        snapshot = {'quota'=>values,'updated_at'=>now,'origin'=>independent ? 'status_url' : 'subscription_header'}
      end
      raise Error, 'No quota query method configured and no local cache available; configure quota query under Subscription Sources' unless snapshot
      locked do
        raise Error, 'Source or quota state was updated concurrently; discarding stale quota result' unless quota_current?(id,expected)
        state = read(source_path(id),{'nodes'=>[],'meta'=>{}})
        state['meta'] ||= {}
        state['meta'].merge!('quota'=>snapshot['quota'],'quota_origin'=>snapshot['origin'],'quota_updated_at'=>snapshot['updated_at'],'quota_attempt_at'=>now,'quota_generation'=>random,'quota_error'=>nil)
        atomic(source_path(id),state)
      end
      {'source'=>id,'quota'=>snapshot['quota'],'updated_at'=>snapshot['updated_at'],'origin'=>snapshot['origin']}
    rescue StandardError => error
      locked do
        if expected && quota_current?(id,expected)
          state = read(source_path(id),{'nodes'=>[],'meta'=>{}})
          state['meta'] ||= {}
          state['meta'].merge!('quota_attempt_at'=>now,'quota_error'=>safe_error(error))
          atomic(source_path(id),state)
        end
      end
      raise error
    end
    def quota_status(s, meta, local)
      values = Quota.normalized(meta['quota'])
      updated = meta['quota_updated_at'] || (values && meta['cached_at'])
      origin = meta['quota_origin'] || (values && 'subscription_header')
      if local && (!values || Quota.timestamp(local['updated_at']) > Quota.timestamp(updated))
        values, updated, origin = local.values_at('quota','updated_at','origin')
      end
      available = !values.nil?
      stale = !available || Quota.timestamp(updated) == 0 || Time.now.to_i - Quota.timestamp(updated) > s.fetch('quota_max_age',86400).to_i
      query_mode = !s['quota_url'].to_s.empty? ? 'independent' : (s['quota_via_subscription']==true && !s['url'].to_s.empty? ? 'subscription' : 'cache_only')
      details = {'state'=>available ? (stale ? 'stale' : 'fresh') : 'unavailable','available'=>available,'stale'=>stale,'origin'=>origin,'updated_at'=>updated,'attempt_at'=>meta['quota_attempt_at'],'can_refresh'=>query_mode!='cache_only' || !local.nil?,'query_mode'=>query_mode,'error'=>meta['quota_error']}
      [values,details]
    end
    def preview_regions(args)
      raw = args['config']
      raise Error, 'Region preview configuration exceeds size limit' if raw && (!raw.is_a?(String) || raw.bytesize > MAX_BYTES)
      c = raw.to_s.empty? ? config : JSON.parse(raw)
      raise Error, 'Region preview requires sources and regions lists' unless c.is_a?(Hash) && c['sources'].is_a?(Array) && c['regions'].is_a?(Array)
      ids = c['sources'].map { |s| check_id(s['id']) }
      matcher = Regions.new(c['regions'],source_ids:ids)
      selected = args.fetch('sources',[])
      raise Error, 'Invalid source selection for region preview' unless selected.is_a?(Array) && selected.all? { |id| ids.include?(id) }
      rows = c['sources'].select { |s| selected.empty? || selected.include?(s['id']) }.map do |s|
        names = Array(read(source_path(s['id']),{})['nodes']).map { |node| node['name'].to_s }
        matches = matcher.preview(s['id'],names)
        counts = c['regions'].to_h { |region| [region['id'],0] }
        matches.each { |row| row['regions'].each { |region| counts[region] += 1 } }
        {'id'=>s['id'],'name'=>s['name'],'total'=>matches.length,'nodes'=>matches,'counts'=>counts,'unmatched'=>matches.count { |row| row['regions'].empty? },'ambiguous'=>matches.count { |row| row['regions'].length>1 }}
      end
      {'regions'=>c['regions'].map { |region| region.slice('id','name') },'sources'=>rows}
    rescue JSON::ParserError
      raise Error, 'Invalid JSON in region preview configuration'
    end
    def release_path(id)
      raise Error, 'Invalid release identifier' unless id.is_a?(String) && id.match?(/\Ar[0-9]{14}-[a-f0-9]{12}\z/)
      path('releases', id)
    end
    def release_meta(id); read(File.join(release_path(id), 'manifest.json')); end
    def published; read(path('published.json')); end
    def releases
      Dir.glob(path('releases', '*', 'manifest.json')).sort.reverse.map { |p| read(p) }.reject(&:empty?)
    end
    def build_profile(id)
      c = config; p = profile(c, id); cache = caches(c); e = engine(c, cache)
      check = e.validate(id)
      raise Error, Array(check['errors']).join('; ') unless Array(check['errors']).empty?
      output = {}; warnings = Array(check['warnings'])
      p['formats'].each do |fmt|
        r = e.render(id, fmt)
        raise Error, Array(r['errors']).join('; ') unless Array(r['errors']).empty?
        output[fmt] = r['content']; warnings.concat(Array(r['warnings']))
      end
      raise Error, 'Select at least one export format' if output.empty?
      checks = {}
      if output['mihomo'] && @adapter.respond_to?(:validate_export)
        checks['mihomo'] = @adapter.validate_export(output['mihomo'])
      end
      rid = 'r' + Time.now.utc.strftime('%Y%m%d%H%M%S') + '-' + random[0,12]
      dest = release_path(rid); FileUtils.mkdir_p(dest, mode: 0700)
      output.each { |fmt, text| atomic(File.join(dest, filename(fmt)), text, json: false) }
      manifest = {'id'=>rid, 'profile'=>id, 'created_at'=>now, 'formats'=>output.keys, 'warnings'=>warnings.uniq { |w| w['code'] }, 'checks'=>checks, 'input_digest'=>digest_inputs(c, cache), 'sha256'=>output.transform_values { |x| Digest::SHA256.hexdigest(x) }}
      atomic(File.join(dest, 'config.json'), c)
      atomic(File.join(dest, 'manifest.json'), manifest)
      {'release'=>rid, 'warnings'=>manifest['warnings'], 'formats'=>manifest['formats']}
    rescue StandardError
      FileUtils.rm_rf(dest) if dest && File.directory?(dest) && !File.file?(File.join(dest, 'manifest.json'))
      raise
    end
    def filename(fmt)
      {'mihomo'=>'mihomo.yaml', 'surge'=>'surge.conf', 'singbox'=>'singbox.json'}.fetch(fmt) { raise Error, 'Unsupported export format' }
    end
    def publish(args, rollback: false)
      manifest = release_meta(args['release'])
      raise Error, 'Release does not exist' if manifest.empty?
      id = manifest['profile']
      out = {'release'=>manifest['id'], 'profile'=>id}
      locked do
        c = config; profile(c, id)
        history = read(path('publication-history.json'))
        raise Error, 'Rollback is only allowed for previously published releases' if rollback && !history.key?(manifest['id'])
        unless rollback
          raise Error, 'Draft configuration or source cache has changed; please rebuild before publishing' unless manifest['input_digest'] == digest_inputs(c, caches(c))
          expected = manifest['warnings'].map { |w| w['code'] }
          raise Error, 'Please confirm all compatibility differences before publishing' unless (expected - Array(args['accepted_warnings'])).empty?
        end
        manifest['formats'].each do |fmt|
          actual = Digest::SHA256.file(File.join(release_path(manifest['id']), filename(fmt))).hexdigest
          raise Error, 'Release artifact integrity check failed' unless actual == manifest['sha256'][fmt]
        end
        history[manifest['id']] ||= {'published_at'=>now}
        atomic(path('publication-history.json'), history)
        tokens = read(path('tokens.json')); tokens[id] ||= random; atomic(path('tokens.json'), tokens)
        state = published; state[id] = manifest['id']; atomic(path('published.json'), state)
        settings = c['settings']
        if settings['openclash_auto_apply'] && settings['openclash_profile'] == id
          out['job'] = enqueue_locked('apply', id, manifest['id'])
        end
      end
      out
    end
    def unpublish(id)
      locked do
        profile(config,id)
        state=published; state.delete(id); atomic(path('published.json'),state)
        tokens=read(path('tokens.json')); tokens.delete(id); atomic(path('tokens.json'),tokens)
      end
      {'profile'=>id}
    end
    def rotate_token(id)
      locked do
        profile(config, id); tokens = read(path('tokens.json')); tokens[id] = random; atomic(path('tokens.json'), tokens)
      end
      {'profile'=>id}
    end
    def download_info(id)
      c = config; profile(c,id); pub = published[id]
      raise Error, 'Build and publish this profile first' unless pub
      meta = release_meta(pub)
      {'profile'=>id, 'token'=>read(path('tokens.json'))[id], 'formats'=>meta['formats'], 'published_release'=>pub, 'access_mode'=>c['settings']['access_mode'], 'base_url'=>c['settings']['base_url']}
    end
    def job_file(id)
      raise Error, 'Invalid job identifier' unless id.to_s.match?(/\Aj[a-f0-9]{24}\z/)
      File.join(@runtime,'jobs',id+'.json')
    end
    def all_jobs
      Dir.glob(File.join(@runtime,'jobs','*.json')).map { |p| read(p) }.reject(&:empty?).sort_by { |j| [j.fetch('order',0),j['created_at'].to_s,j['id'].to_s] }
    end
    def process_alive?(pid)
      return false unless pid.is_a?(Integer) && pid > 0
      Process.kill(0,pid); true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
    def reconcile_jobs
      all_jobs.each do |j|
        next unless %w[queued running].include?(j['state'])
        created = j['queued_at'] || (Time.utc(*j['created_at'].to_s.scan(/\d+/).map(&:to_i)).to_f rescue 0)
        next if !j['pid'] && Time.now.to_f-created < 5
        stale = Time.now.to_f > j.fetch('deadline',created+1800) || !process_alive?(j['pid'])
        next unless stale
        j['state']='failed'; j['error']='Background job terminated or timed out; please resubmit'; j['finished_at']=now
        atomic(job_file(j['id']),j)
      end
    end
    def jobs
      locked { reconcile_jobs; all_jobs.reverse.first(30) }
    end
    def job_status(id)
      locked { reconcile_jobs; read(job_file(id)) }
    end
    def enqueue(kind, value)
      locked { enqueue_locked(kind,value) }
    end
    def spawn_worker(id)
      pid = Process.spawn(RbConfig.ruby, File.join(__dir__, 'cli.rb'), 'job', id, @dir, @runtime, in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
      Process.detach(pid)
      pid
    end
    # Caller holds the state lock, including publication plus its apply dispatch.
    def enqueue_locked(kind, value, release = nil)
      raise Error, 'Invalid operation' unless %w[refresh refresh_quota build apply compare].include?(kind)
      check_id(value)
      if kind == 'apply'
        release ||= published[value]
        raise Error,'Profile has not been published' unless release
        m=release_meta(release)
        raise Error,'Release does not belong to this profile' unless m['profile']==value
      end
      reconcile_jobs
      records = all_jobs
      pending = records.find { |j| j['kind']==kind && j['value']==value && j['release']==release && %w[queued running].include?(j['state']) }
      return pending['id'] if pending
      id = 'j'+random[0,24]
      j = {'id'=>id, 'kind'=>kind, 'value'=>value, 'release'=>release, 'state'=>'queued', 'created_at'=>now, 'queued_at'=>Time.now.to_f, 'deadline'=>Time.now.to_f+1800, 'order'=>records.map { |r| r.fetch('order',0) }.max.to_i+1}
      atomic(job_file(id),j)
      begin
        j['pid']=spawn_worker(id)
      rescue StandardError
        j['state']='failed'; j['error']='Failed to start background job; please try again later'; j['finished_at']=now
      end
      atomic(job_file(id),j)
      id
    end
    def run_job(id)
      j = locked do
        record=read(job_file(id))
        raise Error,'Job does not exist' if record.empty?
        return unless record['state']=='queued'
        return if record['pid'] && record['pid']!=Process.pid && process_alive?(record['pid'])
        record['pid']=Process.pid; atomic(job_file(id),record); record
      end
      lock_name=j['kind']=='apply' ? 'apply-global' : j['kind']+'-'+check_id(j['value'])
      lock=File.open(File.join(@runtime,lock_name+'.lock'),File::RDWR|File::CREAT,0600)
      loop do
        lock.flock(File::LOCK_EX)
        ready=locked do
          reconcile_jobs
          current=read(job_file(id))
          raise Error,'Job has expired; please resubmit' unless current['state']=='queued'
          earlier=j['kind']=='apply' && all_jobs.any? { |other| other['kind']=='apply' && %w[queued running].include?(other['state']) && other.fetch('order',0)<j.fetch('order',0) }
          unless earlier
            j=current; j['state']='running'; j['started_at']=now; j['deadline']=Time.now.to_f+600; atomic(job_file(id),j)
          end
          !earlier
        end
        break if ready
        lock.flock(File::LOCK_UN); sleep 0.1
      end
      result = case j['kind']
      when 'refresh'; refresh_source(j['value'])
      when 'refresh_quota'; refresh_quota(j['value'])
      when 'build'; build_profile(j['value'])
      when 'compare'
        require_relative 'converter'
        nodes=caches.fetch(j['value'],{})['nodes']; raise Error,'No cached nodes available for this source' if !nodes || nodes.empty?
        Converter.new(config['settings']['converter_url']).compare(nodes)
      when 'apply'
        rid=j['release']; raise Error,'Job is missing a target release' unless rid
        m=release_meta(rid); raise Error,'Release does not include Mihomo output' unless m['formats'].include?('mihomo')
        @adapter.apply(j['value'],File.join(release_path(rid),'mihomo.yaml'),read(File.join(release_path(rid),'config.json')))
      end
      j['state']='completed'; j['result']=result
    rescue StandardError => e
      j ||= {'id'=>id}; j['state']='failed'; j['error']=safe_error(e)
    ensure
      if j
        locked do
          current=read(job_file(id))
          if %w[queued running].include?(current['state']) && current['pid']==Process.pid
            j['finished_at']=now; atomic(job_file(id),j)
          end
          old = Dir.glob(File.join(@runtime,'jobs','*.json')).sort_by { |p| File.mtime(p) }.reverse.drop(60)
          old.each { |p| File.unlink(p) if %w[completed failed].include?(read(p)['state']) }
        end
      end
      lock.close if lock
    end
    def import_openclash
      result = @adapter.import_sources
      quota_urls = @quota_adapter.respond_to?(:configured_urls) ? @quota_adapter.configured_urls(Array(result['sources'])) : {}
      locked do
        c=config
        Array(result['sources']).each do |s|
          old=c['sources'].find { |entry| entry['id']==s['id'] }
          if old
            old['quota_url']=quota_urls[s['id']] if quota_urls[s['id']] && old['quota_url'].to_s.empty? && old['url']==s['url']
            next
          end
          s['update_mode']='manual'; s['takeover']=false; s['enabled']=true; s['quota_via_subscription']=false
          s['quota_url']=quota_urls[s['id']] if quota_urls[s['id']]
          c['sources'] << s
          cache = result.fetch('caches',{})[s['id']]
          atomic(source_path(s['id']),cache) if cache
        end
        atomic(path('config.json'),c)
      end
      {'imported'=>Array(result['sources']).map { |s| s['id'] }, 'version'=>version}
    end
    def converter_status
      u=url!(config['settings'].fetch('converter_url','http://127.0.0.1:25500'),loopback:true)
      v=command(['curl','--noproxy','*','-fsS','--max-time','2',u.to_s.sub(%r{/$},'')+'/version'],seconds:3)
      {'available'=>true,'version'=>safe_error(v.strip)}
    rescue StandardError
      {'available'=>false,'version'=>nil}
    end
    def status
      c=config; pub=published
      local_quotas=@quota_adapter.local_states(c['sources'])
      matcher=Regions.new(c['regions'],source_ids:c['sources'].map { |s| s['id'] })
      {'config_version'=>version(c), 'sources'=>c['sources'].map do |s|
        x=read(source_path(s['id']),{'nodes'=>[],'meta'=>{}})
        values, details=quota_status(s,x.fetch('meta',{}),local_quotas[s['id']])
        counts=Hash.new(0)
        matcher.preview(s['id'],Array(x['nodes']).map { |node| node['name'].to_s }).each { |node| node['regions'].each { |region| counts[region] += 1 } } unless c['regions'].empty?
        x.fetch('meta',{}).merge('id'=>s['id'],'name'=>s['name'],'nodes'=>Array(x['nodes']).length,'update_mode'=>s['update_mode'],'enabled'=>s['enabled'],'regions'=>counts,'quota'=>values,'quota_status'=>details)
      end, 'profiles'=>c['profiles'].map do |p|
        rid=pub[p['id']]; m=rid ? release_meta(rid) : {}
        {'id'=>p['id'],'name'=>p['name'],'published_release'=>rid,'formats'=>m['formats'] || [],'generated_at'=>m['created_at']}
      end, 'releases'=>releases.map { |r| r.merge(read(path('publication-history.json'))[r['id']] || {}).merge('ever_published'=>read(path('publication-history.json')).key?(r['id']), 'published'=>pub[r['profile']]==r['id']) }, 'jobs'=>jobs, 'openclash'=>@adapter.status,'converter'=>converter_status}
    end
    def tick
      c=config
      c['sources'].each do |s|
        next unless s['enabled']!=false && s['update_mode']=='scheduled'
        meta=read(source_path(s['id']),{'meta'=>{}})['meta'] || {}
        begin
          # ISO timestamps are fixed-width; use the last attempt to avoid retry storms.
          stamp=meta['attempt_at']; last=stamp ? Time.utc(*stamp.scan(/\d+/).map(&:to_i)).to_i : 0
        rescue ArgumentError; last=0; end
        enqueue('refresh',s['id']) if Time.now.to_i-last >= s.fetch('interval',86400).to_i
      end
    end
    def call(method,args={})
      result=case method
      when 'status'; status
      when 'get_config'; {'config'=>sanitized_config,'version'=>version}
      when 'save_config'; save_config(args)
      when 'refresh'; source(config,args['source']); {'job'=>enqueue('refresh',args['source'])}
      when 'refresh_quota'; source(config,args['source']); {'job'=>enqueue('refresh_quota',args['source'])}
      when 'region_defaults'; {'regions'=>Regions.defaults}
      when 'preview_regions'; preview_regions(args)
      when 'compare_converter'; source(config,args['source']); {'job'=>enqueue('compare',args['source'])}
      when 'import_source'; s=source(config,args['source']); put_source(s['id'],args.fetch('content'),s.fetch('format','auto'))
      when 'import_openclash'; import_openclash
      when 'validate'; engine.validate(args['profile'])
      when 'preview'; engine.render(args['profile'],args['format'],redact:true)
      when 'build'; profile(config,args['profile']); {'job'=>enqueue('build',args['profile'])}
      when 'publish'; publish(args)
      when 'rollback'; publish(args,rollback:true)
      when 'download_info'; download_info(args['profile'])
      when 'rotate_token'; rotate_token(args['profile'])
      when 'unpublish'; unpublish(args['profile'])
      when 'apply_openclash'; profile(config,args['profile']); {'job'=>enqueue('apply',args['profile'])}
      when 'job_status'; {'job'=>job_status(args['job'])}
      else; raise Error,'Unknown operation'
      end
      {'ok'=>true}.merge(result || {})
    rescue StandardError => e
      {'ok'=>false,'error'=>safe_error(e)}
    end
  end
end
