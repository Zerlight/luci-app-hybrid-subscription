# frozen_string_literal: true

require 'yaml'
require 'json'
require 'fileutils'
require 'open3'
require 'timeout'
require 'uri'

module HybridSubscription
  # Import is read-only. Only apply changes OpenClash and restarts its service.
  class OpenClash
    class Error < StandardError; end
    ID = /\A[a-z][a-z0-9_-]{0,47}\z/
    MANAGED = /\AHybridSubscriptions-([a-z][a-z0-9_-]{0,47})\.yaml\z/
    ROUTING_KEYS = %w[proxies proxy-groups proxy-providers rule-providers rules sub-rules].freeze
    OPTIONAL_POLICY_KEYS = %w[geodata-mode geodata-loader geox-url geo-auto-update geo-update-interval keep-alive-interval keep-alive-idle disable-keep-alive ipv6 tcp-concurrent unified-delay experimental sniffer profile hosts].freeze
    POLICY_KEYS = (ROUTING_KEYS + OPTIONAL_POLICY_KEYS + ['dns']).freeze
    MAX_BYTES = 4 * 1024 * 1024
    MAX_CACHE_BYTES = 32 * 1024 * 1024
    HOOK_BEGIN = '# BEGIN hybrid-subscription managed profiles'
    HOOK_END = '# END hybrid-subscription managed profiles'

    def initialize(root_dir = '/', command_runner: nil)
      @root = File.expand_path(root_dir)
      @runner = command_runner
    end

    def status
      installed = File.file?(path('/etc/init.d/openclash'))
      active = uci_get('config_path')
      version = installed && File.file?(core_path) ? command([core_path, '-v'], timeout: 8, required: false).first.lines.first.to_s.strip : ''
      {
        'installed' => installed,
        'version' => version.gsub(/[^[:print:]]/, '')[0, 180],
        'active_config' => active && File.basename(active),
        'integration' => !!(active && MANAGED.match(File.basename(active)))
      }
    end

    # URLs and raw nodes in this result are private; RPC callers must redact them.
    def import_sources
      sections = uci_sections
      active = sections.fetch('config', {})['config_path'] || '/etc/openclash/config/config.yaml'
      source_config = read_yaml(inside_openclash(active), optional: true)
      sources = []
      caches = {}
      Array(source_config.fetch('proxy-providers', {}).to_a).each do |name, provider|
        next unless provider.is_a?(Hash)
        cache_path = provider['path'] && inside_openclash(provider['path'], relative: true)
        cached = read_yaml(cache_path, optional: true)
        add_import(sources, caches, name, provider['url'], cached['proxies'], cache_path, '')
      end
      sections.each do |section, item|
        next unless item['.type'] == 'config_subscribe'
        urls = Array(item['address']).flat_map { |value| value.to_s.lines.map(&:strip) }.reject(&:empty?)
        next unless urls.length == 1 && http_url?(urls.first)
        name = item['name'].to_s
        existing = sources.find { |source| source['url'] == urls.first || (source['name'] == name && source['url'].to_s.empty?) }
        if existing
          existing['url'] = urls.first
          existing['openclash_section'] = section
          existing['user_agent'] = item['sub_ua'].to_s
          next
        end
        next if name.empty? || name.include?('/') || name.include?("\0")
        cache_path = inside_openclash("config/#{name}.yaml", relative: true)
        add_import(sources, caches, name, urls.first, read_yaml(cache_path, optional: true)['proxies'], cache_path, section, item['sub_ua'])
      end
      { 'sources' => sources, 'caches' => caches }
    rescue Error
      raise
    rescue StandardError
      raise Error, 'Could not read the existing OpenClash subscriptions.'
    end

    # Validate rendered content before publishing; no source refresh or service action.
    def validate_export(content)
      return { 'checked' => false, 'reason' => 'Mihomo core is not installed.' } unless File.file?(core_path)
      raise Error, 'Exported configuration is missing or too large.' unless content.is_a?(String) && content.bytesize <= MAX_BYTES
      candidate = YAML.safe_load(content, permitted_classes: [], permitted_symbols: [], aliases: true)
      raise Error, 'The export is not a Mihomo configuration.' unless candidate.is_a?(Hash) && candidate['proxy-groups'].is_a?(Array) && candidate['rules'].is_a?(Array)
      directory = path("/tmp/hybrid-subscription/export-check-#{Process.pid}-#{rand(1_000_000)}")
      validate_candidate(candidate, directory)
      { 'checked' => true }
    rescue Psych::Exception
      raise Error, 'Invalid YAML configuration.'
    ensure
      FileUtils.rm_rf(directory) if directory
    end

    def apply(profile_id, artifact_path, config)
      raise Error, 'Invalid profile ID.' unless profile_id.to_s.match?(ID)
      raise Error, 'OpenClash is not installed.' unless File.file?(path('/etc/init.d/openclash')) && File.file?(core_path)
      profile = Array(config['profiles']).find { |item| item['id'] == profile_id }
      raise Error, 'Profile does not exist.' unless profile
      artifact = checked_artifact(artifact_path)
      candidate = read_yaml(artifact)
      raise Error, 'The release is not a Mihomo configuration.' unless candidate['proxy-groups'].is_a?(Array) && candidate['rules'].is_a?(Array)
      uses_smart = candidate['proxy-groups'].any? { |group| group['type'] == 'smart' }
      if uses_smart && !command([core_path, '-v'], timeout: 8).first.downcase.include?('smart')
        raise Error, 'This release requires the Smart core. Install it in OpenClash before applying.'
      end
      FileUtils.mkdir_p(path('/etc/hybrid-subscription'), mode: 0o700)
      File.open(path('/etc/hybrid-subscription/openclash-apply.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
        raise Error, 'An OpenClash apply operation is already running.' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        validation_dir = path("/tmp/hybrid-subscription/openclash-check-#{Process.pid}")
        begin
          validate_candidate(candidate, validation_dir)
          journal = prepare_transaction(profile_id)
          start_guard(journal)
          begin
            seed_rule_caches(candidate)
            managed = path("/etc/openclash/config/HybridSubscriptions-#{profile_id}.yaml")
            atomic_write(managed, File.binread(artifact))
            install_hook
            uci_set('config_path', "/etc/openclash/config/#{File.basename(managed)}")
            # The core is already installed. Never download a core or enable global conversion.
            if uses_smart
              uci_set('smart_enable', '1')
              uci_set('core_type', 'Smart')
            end
            takeover_sources(config, profile)
            command(['/sbin/uci', 'commit', 'openclash'])
            command(['/etc/init.d/openclash', 'restart'], timeout: 100)
            verify_running(profile_id, candidate)
            transaction_lock(journal) do |record|
              raise Error, 'Apply exceeded its rollback deadline.' unless record['state'] == 'armed'
              record['state'] = 'committed'
              atomic_write(File.join(journal, 'manifest.json'), JSON.generate(record))
            end
            { 'ok' => true, 'active_config' => File.basename(managed), 'backup' => File.basename(journal), 'restarted' => true }
          rescue StandardError => error
            begin
              rollback(journal)
            rescue StandardError
              raise Error, 'Apply failed and automatic recovery failed. Use the saved OpenClash backup in the integration backup directory.'
            end
            raise Error, error.is_a?(Error) ? "#{error.message} Previous OpenClash configuration restored." : 'Apply failed. Previous OpenClash configuration restored.'
          end
        ensure
          FileUtils.rm_rf(validation_dir) if validation_dir
        end
      end
    end

    # Runs first in OpenClash's existing hook, exclusively for our owned filenames.
    def preserve(runtime_path)
      basename = File.basename(runtime_path.to_s)
      raise Error, 'Not a managed configuration.' unless MANAGED.match?(basename)
      expanded = File.expand_path(runtime_path)
      allowed = [path("/tmp/#{basename}"), path("/etc/openclash/#{basename}")]
      raise Error, 'Invalid generated configuration path.' unless allowed.include?(expanded)
      raise Error, 'Generated configuration must not be a symbolic link.' if File.symlink?(expanded)
      source = read_yaml(path("/etc/openclash/config/#{basename}"))
      runtime = read_yaml(expanded)
      ROUTING_KEYS.each do |key|
        source.key?(key) ? runtime[key] = source[key] : runtime.delete(key)
      end
      OPTIONAL_POLICY_KEYS.each { |key| runtime[key] = source[key] if source.key?(key) }
      if source['dns'].is_a?(Hash)
        # DNS policy is portable; the listening socket belongs to OpenClash.
        listen = runtime.fetch('dns', {})['listen']
        runtime['dns'] = source['dns'].reject { |key, _| key == 'listen' }
        runtime['dns']['listen'] = listen if listen
      end
      atomic_write(expanded, YAML.dump(runtime))
      true
    end

    def guard(journal, wait_seconds = 240)
      checked_journal(journal)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait_seconds
      loop do
        state = JSON.parse(File.read(File.join(journal, 'manifest.json')))['state']
        return unless state == 'armed'
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 2
      end
      rollback(journal)
    end

    def rollback(journal)
      checked_journal(journal)
      transaction_lock(journal) do |record|
        return if %w[committed restored].include?(record['state'])
        record['state'] = 'restoring'
        atomic_write(File.join(journal, 'manifest.json'), JSON.generate(record))
        record.fetch('files').each do |entry|
          destination = checked_restore_path(entry.fetch('path'))
          if entry['present']
            atomic_write(destination, File.binread(File.join(journal, entry.fetch('backup'))), entry.fetch('mode'))
          else
            File.unlink(destination) if File.file?(destination) || File.symlink?(destination)
          end
        end
        # Clear staged UCI changes too; a failed commit must not override restored files.
        command(['/sbin/uci', '-q', 'revert', 'openclash'], required: false)
        command(['/etc/init.d/openclash', 'restart'], timeout: 100)
        record['state'] = 'restored'
        atomic_write(File.join(journal, 'manifest.json'), JSON.generate(record))
      end
    end

    private

    def path(absolute)
      File.join(@root, absolute.sub(%r{\A/+}, ''))
    end

    def core_path
      regular = path('/etc/openclash/core/clash_meta')
      File.file?(regular) ? regular : path('/tmp/etc/openclash/core/clash_meta')
    end

    def command(argv, timeout: 20, required: true)
      if @runner
        output, success = @runner.call(argv, timeout)
      else
        output = +''
        success = false
        Open3.popen2e(*argv, pgroup: true) do |stdin, stdout, process|
          stdin.close
          begin
            Timeout.timeout(timeout) do
              loop do
                chunk = stdout.readpartial(4096)
                output << chunk if output.bytesize < MAX_BYTES
              end
            rescue EOFError
              success = process.value.success?
            end
          rescue Timeout::Error
            Process.kill('TERM', -process.pid) rescue nil
            sleep 0.2
            Process.kill('KILL', -process.pid) rescue nil
            raise Error, 'An OpenClash command timed out.'
          end
        end
      end
      raise Error, 'An OpenClash command failed.' if required && !success
      [output.to_s, !!success]
    rescue Errno::ENOENT
      raise Error, 'An OpenClash helper is unavailable.' if required
      ['', false]
    end

    def uci_get(option)
      output, success = command(['/sbin/uci', '-q', 'get', "openclash.config.#{option}"], required: false)
      success ? output.strip : nil
    end

    def uci_set(option, value)
      command(['/sbin/uci', 'set', "openclash.config.#{option}=#{value}"])
    end

    def uci_sections
      output, success = command(['/bin/ubus', 'call', 'uci', 'get', '{"config":"openclash"}'], required: false)
      success ? JSON.parse(output).fetch('values', {}) : {}
    rescue JSON::ParserError
      raise Error, 'Could not read OpenClash settings.'
    end

    def read_yaml(filename, optional: false)
      return {} if optional && (!filename || !File.file?(filename))
      raise Error, 'Configuration is missing or too large.' unless filename && File.file?(filename) && File.size(filename) <= MAX_BYTES
      parsed = YAML.safe_load(File.read(filename), permitted_classes: [], permitted_symbols: [], aliases: true)
      raise Error, 'Invalid YAML configuration.' unless parsed.is_a?(Hash)
      parsed
    rescue Psych::Exception
      raise Error, 'Invalid YAML configuration.'
    end

    def inside_openclash(filename, relative: false)
      base = path('/etc/openclash')
      candidate = if relative
                    File.expand_path(filename.to_s, base)
                  elsif @root != '/' && filename.to_s.start_with?(@root + '/')
                    File.expand_path(filename)
                  else
                    path(filename.to_s)
                  end
      raise Error, 'OpenClash provider path is outside its configuration directory.' unless candidate.start_with?(base + '/')
      if File.exist?(candidate)
        raise Error, 'OpenClash provider resolves outside its configuration directory.' unless File.realpath(candidate).start_with?(File.realpath(base) + '/')
      end
      candidate
    end

    def http_url?(value)
      uri = URI.parse(value.to_s)
      %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo
    rescue URI::InvalidURIError
      false
    end

    def add_import(sources, caches, name, url, nodes, cache_path, section, user_agent = '')
      return unless http_url?(url) || nodes.is_a?(Array)
      existing = sources.find { |source| http_url?(url) && source['url'] == url }
      return if existing
      slug = name.to_s.downcase.gsub(/[^a-z0-9_-]+/, '-').gsub(/\A-+|-+\z/, '')[0, 34]
      slug = "source-#{slug}" unless slug.match?(/\A[a-z]/)
      slug = 'source' if slug.empty?
      id = "oc-#{slug}"
      suffix = 2
      while sources.any? { |source| source['id'] == id }
        id = "oc-#{slug}-#{suffix}"
        suffix += 1
      end
      sources << {
        'id' => id, 'name' => name.to_s, 'enabled' => true, 'url' => http_url?(url) ? url : '',
        'format' => 'mihomo', 'update_mode' => 'manual', 'interval' => 86400,
        'exclude_filter' => '', 'user_agent' => user_agent.to_s,
        'openclash_section' => section, 'takeover' => false
      }
      caches[id] = {
        'nodes' => nodes.is_a?(Array) ? nodes : [],
        'meta' => { 'imported_from' => 'openclash', 'cached_at' => cache_path && File.file?(cache_path) ? File.mtime(cache_path).utc.strftime('%Y-%m-%dT%H:%M:%SZ') : nil }
      }
    end

    def checked_artifact(filename)
      base = File.realpath(path('/etc/hybrid-subscription/releases'))
      real = File.realpath(filename.to_s)
      raise Error, 'Only published release artifacts may be applied.' unless real.start_with?(base + '/') && File.basename(real) == 'mihomo.yaml'
      real
    rescue Errno::ENOENT
      raise Error, 'The published Mihomo artifact is missing.'
    end

    def validate_candidate(candidate, directory)
      FileUtils.mkdir_p(directory, mode: 0o700)
      check = JSON.parse(JSON.generate(candidate))
      %w[port socks-port mixed-port redir-port tproxy-port].each { |key| check[key] = 0 }
      %w[listeners external-controller external-controller-tls external-controller-unix external-controller-pipe external-ui external-ui-url external-ui-name].each { |key| check.delete(key) }
      check['allow-lan'] = false
      check['bind-address'] = '127.0.0.1'
      check['tun'] = { 'enable' => false }
      if check['dns'].is_a?(Hash)
        check['dns']['listen'] = '127.0.0.1:0'
      else
        check['dns'] = { 'enable' => false }
      end
      check['profile'] = { 'store-selected' => false, 'store-fake-ip' => false }
      check['geo-auto-update'] = false
      check['geox-url'] = %w[geoip geosite mmdb asn].to_h { |key| [key, "http://127.0.0.1:1/#{key}"] }
      if Array(check['proxy-groups']).any? { |group| group['type'] == 'smart' } && !command([core_path, '-v'], timeout: 8).first.downcase.include?('smart')
        raise Error, 'This export requires the installed Mihomo Smart core.'
      end
      required_data = []
      native_text = JSON.generate([check['rules'], check['sub-rules'], check['dns']])
      required_data << 'GeoSite.dat' if native_text.match?(/geosite[,:]/i)
      required_data << (check['geodata-mode'] ? 'GeoIP.dat' : 'Country.mmdb') if native_text.match?(/geoip[,:](?!LAN(?:[,"\)]|$))/i)
      required_data.each do |name|
        raise Error, 'Required geodata is missing; update it in OpenClash before validating this profile.' unless File.file?(path("/etc/openclash/#{name}"))
      end
      isolate_provider_caches(check, directory)
      # -t never starts listeners; geodata is reused without moving or changing it.
      %w[Country.mmdb GeoIP.dat GeoSite.dat ASN.mmdb].each do |name|
        existing = path("/etc/openclash/#{name}")
        File.symlink(existing, File.join(directory, name)) if File.file?(existing)
      end
      atomic_write(File.join(directory, 'check.yaml'), YAML.dump(check))
      command(['/usr/bin/env', "SAFE_PATHS=#{path('/etc/openclash')}", core_path, '-t', '-d', directory, '-f', File.join(directory, 'check.yaml')], timeout: 60)
    end

    def isolate_provider_caches(check, directory)
      copied = 0
      reusable = reusable_rule_caches
      %w[rule-providers proxy-providers].each do |kind|
        providers = check.fetch(kind, {})
        raise Error, 'Invalid provider definitions.' unless providers.is_a?(Hash)
        providers.each_with_index do |(_name, provider), index|
          raise Error, 'Invalid provider definition.' unless provider.is_a?(Hash)
          next if provider['type'] == 'inline'
          raise Error, 'Unsupported provider type.' unless %w[file http].include?(provider['type'])
          original = provider['path'] && inside_openclash(provider['path'], relative: true)
          original = reusable[rule_cache_key(provider)] if !File.file?(original.to_s) && kind == 'rule-providers' && provider['type'] == 'http'
          present = original && File.file?(original)
          if !present && (provider['type'] == 'file' || kind == 'proxy-providers')
            raise Error, 'A local provider cache is missing. Import its contents before publishing.'
          end
          isolated = File.join(directory, kind, index.to_s)
          if present
            copied += File.size(original)
            raise Error, 'Provider caches exceed the 32 MiB validation limit.' if copied > MAX_CACHE_BYTES
            atomic_write(isolated, File.binread(original))
          elsif provider['format'] == 'mrs'
            # Without a cached binary, validate references only; an empty file is not valid MRS.
            provider['type'] = 'inline'
            provider['payload'] = []
            %w[path format url interval header proxy health-check].each { |key| provider.delete(key) }
            next
          else
            # Remote rule contents are not fetched by validation; only their references and format are checked.
            atomic_write(isolated, '')
          end
          provider['type'] = 'file'
          provider['path'] = isolated
          %w[url interval header proxy health-check].each { |key| provider.delete(key) }
        end
      end
    end

    def rule_cache_key(provider)
      provider.values_at('url', 'behavior', 'format')
    end

    # Reuse only an exact provider definition from the currently selected source.
    # This lookup is read-only, including during build/preview validation.
    def reusable_rule_caches
      active = uci_get('config_path')
      return {} unless active
      providers = read_yaml(inside_openclash(active), optional: true).fetch('rule-providers', {})
      return {} unless providers.is_a?(Hash)
      providers.each_value.each_with_object({}) do |provider, result|
        next unless provider.is_a?(Hash) && provider['type'] == 'http' && http_url?(provider['url']) && provider['path']
        begin
          filename = inside_openclash(provider['path'], relative: true)
          result[rule_cache_key(provider)] ||= filename if File.file?(filename)
        rescue Error
          next
        end
      end
    end

    # Warm only missing app-owned paths. A hard link publishes the completed copy
    # atomically and refuses to replace a cache concurrently created by Mihomo.
    def seed_rule_caches(candidate)
      reusable = reusable_rule_caches
      copied = 0
      candidate.fetch('rule-providers', {}).each_value do |provider|
        next unless provider['type'] == 'http'
        match = /\A(?:\.\/)?rule_provider\/(hybrid-[a-zA-Z0-9_-]+\.(?:yaml|yml|txt|list|mrs))\z/.match(provider['path'].to_s)
        next unless match
        original = reusable[rule_cache_key(provider)]
        next unless original
        directory = path('/etc/openclash/rule_provider')
        raise Error, 'The rule cache directory must not be a symbolic link.' if File.symlink?(directory)
        FileUtils.mkdir_p(directory, mode: 0o700)
        destination = inside_openclash("rule_provider/#{match[1]}", relative: true)
        next if File.exist?(destination) || File.symlink?(destination)
        copied += File.size(original)
        raise Error, 'Provider caches exceed the 32 MiB copy limit.' if copied > MAX_CACHE_BYTES
        temporary = File.join(directory, ".hybrid-cache-#{Process.pid}-#{rand(1_000_000)}")
        begin
          content = File.binread(original, MAX_CACHE_BYTES + 1)
          raise Error, 'Provider cache exceeds the 32 MiB copy limit.' if content.bytesize > MAX_CACHE_BYTES
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(content) }
          begin
            File.link(temporary, destination)
          rescue Errno::EEXIST
            # A concurrent updater won. Its cache must remain untouched.
          end
        ensure
          File.unlink(temporary) if temporary && File.file?(temporary)
        end
      end
    end

    def prepare_transaction(profile_id)
      name = "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}-#{rand(1_000_000)}"
      directory = path("/etc/hybrid-subscription/openclash-backups/#{name}")
      FileUtils.mkdir_p(directory, mode: 0o700)
      filenames = [
        '/etc/config/openclash', '/etc/openclash/custom/openclash_custom_overwrite.sh',
        "/etc/openclash/config/HybridSubscriptions-#{profile_id}.yaml",
        "/etc/openclash/HybridSubscriptions-#{profile_id}.yaml"
      ]
      files = filenames.each_with_index.map do |filename, index|
        original = path(filename)
        raise Error, 'An OpenClash configuration unexpectedly uses a symbolic link.' if File.symlink?(original)
        present = File.file?(original)
        entry = { 'path' => filename, 'present' => present, 'backup' => "file-#{index}", 'mode' => present ? File.stat(original).mode & 0o777 : 0o600 }
        atomic_write(File.join(directory, entry['backup']), File.binread(original)) if present
        entry
      end
      atomic_write(File.join(directory, 'manifest.json'), JSON.generate('state' => 'armed', 'files' => files, 'profile' => profile_id))
      directory
    end

    def start_guard(journal)
      if @runner
        command(['/usr/bin/ruby', __FILE__, 'guard', journal])
      else
        pid = Process.spawn('/usr/bin/ruby', __FILE__, 'guard', journal, in: File::NULL, out: File.join(journal, 'guard.log'), err: [:child, :out], pgroup: true)
        Process.detach(pid)
      end
    end

    def install_hook
      filename = path('/etc/openclash/custom/openclash_custom_overwrite.sh')
      original = File.file?(filename) ? File.read(filename) : "#!/bin/sh\n"
      return if original.include?(HOOK_BEGIN) && original.include?(HOOK_END)
      raise Error, 'The OpenClash integration hook is incomplete.' if original.include?(HOOK_BEGIN) || original.include?(HOOK_END)
      block = <<~SH
        #{HOOK_BEGIN}
        case "${1##*/}" in
          HybridSubscriptions-*.yaml)
            /usr/bin/ruby /usr/share/hybrid-subscription/openclash.rb preserve "$1"
            exit $?
            ;;
        esac
        #{HOOK_END}
      SH
      lines = original.lines
      shebang = lines.first.to_s.start_with?('#!') ? lines.shift : "#!/bin/sh\n"
      atomic_write(filename, shebang.chomp + "\n" + block + lines.join, 0o755)
    end

    def takeover_sources(config, profile)
      sections = uci_sections
      Array(config['sources']).each do |source|
        next unless source['takeover'] == true && Array(profile['sources']).include?(source['id'])
        section = source['openclash_section'].to_s
        raise Error, 'The subscription takeover reference is invalid.' unless section.match?(/\A[a-zA-Z0-9_]+\z/)
        existing = sections[section]
        addresses = existing && Array(existing['address'])
        unless existing && existing['.type'] == 'config_subscribe' && addresses == [source['url']] && http_url?(source['url'])
          raise Error, 'An OpenClash subscription changed. Re-import it before taking over updates.'
        end
        command(['/sbin/uci', 'set', "openclash.#{section}.enabled=0"])
      end
    end

    def verify_running(profile_id, candidate)
      expected_path = "/etc/openclash/config/HybridSubscriptions-#{profile_id}.yaml"
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 55
      loop do
        if uci_get('config_path') == expected_path
          runtime_path = path("/etc/openclash/HybridSubscriptions-#{profile_id}.yaml")
          runtime = read_yaml(runtime_path, optional: true)
          if policy_matches?(candidate, runtime) && api_ready?(runtime, candidate)
            return true
          end
        end
        raise Error, 'OpenClash did not load the published policy.' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 1
      end
    end

    def policy_matches?(candidate, runtime)
      return false unless ROUTING_KEYS.all? { |key| candidate[key] == runtime[key] }
      return false unless OPTIONAL_POLICY_KEYS.all? { |key| !candidate.key?(key) || candidate[key] == runtime[key] }
      return true unless candidate.key?('dns')
      return false unless candidate['dns'].is_a?(Hash) && runtime['dns'].is_a?(Hash)
      candidate['dns'].reject { |key, _| key == 'listen' } == runtime['dns'].reject { |key, _| key == 'listen' }
    end

    def api_ready?(runtime, candidate)
      port = uci_get('cn_port').to_s
      return false unless port.match?(/\A\d{1,5}\z/) && port.to_i.between?(1, 65_535)
      # Keep the API secret out of process arguments and logs.
      config_path = path("/tmp/hybrid-subscription/api-check-#{Process.pid}.conf")
      secret = runtime['secret'].to_s
      return false if secret.match?(/[[:cntrl:]]/)
      escaped = secret.gsub(/[\\"]/) { |character| "\\#{character}" }
      atomic_write(config_path, "header = \"Authorization: Bearer #{escaped}\"\n")
      output, success = command(['/usr/bin/curl', '--silent', '--fail', '--noproxy', '*', '--max-time', '3', '--config', config_path, "http://127.0.0.1:#{port}/proxies"], timeout: 5, required: false)
      return false unless success
      proxies = JSON.parse(output).fetch('proxies', {})
      nodes_loaded = Array(candidate['proxies']).all? { |node| proxies.key?(node['name']) }
      groups_loaded = Array(candidate['proxy-groups']).all? do |group|
        running = proxies[group['name']]
        running && (!group['proxies'].is_a?(Array) || Array(running['all']).sort == group['proxies'].sort)
      end
      nodes_loaded && groups_loaded
    rescue JSON::ParserError
      false
    ensure
      File.unlink(config_path) if config_path && File.file?(config_path)
    end

    def checked_journal(directory)
      base = path('/etc/hybrid-subscription/openclash-backups')
      expanded = File.expand_path(directory)
      unless File.dirname(expanded) == base && File.basename(expanded).match?(/\A\d{8}T\d{6}-\d+-\d+\z/) && !File.symlink?(expanded)
        raise Error, 'Invalid OpenClash recovery transaction.'
      end
      expanded
    end

    def checked_restore_path(filename)
      allowed = ['/etc/config/openclash', '/etc/openclash/custom/openclash_custom_overwrite.sh']
      managed = %r{\A/etc/openclash/(?:config/)?HybridSubscriptions-[a-z][a-z0-9_-]{0,47}\.yaml\z}
      raise Error, 'Invalid OpenClash recovery file.' unless allowed.include?(filename) || filename.match?(managed)
      path(filename)
    end

    def transaction_lock(directory)
      File.open(File.join(directory, 'transaction.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        record = JSON.parse(File.read(File.join(directory, 'manifest.json')))
        yield record
      end
    end

    def atomic_write(filename, content, mode = 0o600)
      FileUtils.mkdir_p(File.dirname(filename), mode: 0o700)
      temporary = "#{filename}.hybrid-tmp-#{Process.pid}"
      raise Error, 'Unsafe temporary configuration path.' if File.symlink?(temporary)
      File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, mode) do |file|
        file.chmod(mode)
        file.write(content)
        file.flush
        file.fsync
      end
      File.rename(temporary, filename)
    ensure
      File.unlink(temporary) if temporary && File.file?(temporary)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    adapter = HybridSubscription::OpenClash.new
    case ARGV.shift
    when 'preserve' then adapter.preserve(ARGV.fetch(0))
    when 'guard' then adapter.guard(ARGV.fetch(0))
    else raise HybridSubscription::OpenClash::Error, 'Unsupported integration operation.'
    end
  rescue StandardError
    warn 'OpenClash subscription integration failed. Check the saved apply transaction.'
    exit 1
  end
end
