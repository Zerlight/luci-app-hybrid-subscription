# frozen_string_literal: true
require 'json'
require 'yaml'
require 'uri'
require 'ipaddr'
require 'digest'
require_relative 'regions'

module HybridSubscription
  class Error < StandardError; end unless const_defined?(:Error)

  # Canonical caches contain Mihomo node hashes, never whole router configurations.
  # Rendering is pure: a download cannot refresh a source or change the router.
  class Engine
    FORMATS = %w[mihomo surge singbox].freeze
    PROTOCOLS = %w[anytls trojan ss vmess vless hysteria2 tuic].freeze
    RULE_TYPES = %w[DOMAIN DOMAIN-SUFFIX DOMAIN-KEYWORD IP-CIDR IP-CIDR6 GEOIP GEOSITE RULE-SET DST-PORT NETWORK REMATCH-NAME AND OR NOT].freeze
    BUILTINS = %w[DIRECT REJECT].freeze
    ID = /\A[a-z][a-z0-9_-]{0,47}\z/
    MAX_INPUT = 2 * 1024 * 1024
    MAX_NODES = 4096
    SAFE_PREVIEW_KEYS = %w[name type port cipher network client-fingerprint udp tfo tls skip-cert-verify alterId flow version congestion-controller udp-relay-mode].freeze

    def initialize(config, caches)
      @config = self.class.copy(config)
      @caches = self.class.copy(caches)
    end

    def self.copy(value)
      JSON.parse(JSON.generate(value))
    rescue JSON::GeneratorError, JSON::ParserError, TypeError
      raise Error, 'Configuration must contain JSON-compatible values'
    end

    def self.import_nodes(content, format = 'auto')
      raise Error, 'Source exceeds 2 MiB' unless content.is_a?(String) && content.bytesize <= MAX_INPUT
      raise Error, 'Source is not valid UTF-8' unless content.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      text = content.dup.force_encoding(Encoding::UTF_8).sub(/\A\uFEFF/, '').strip
      raise Error, 'Source is empty' if text.empty?
      raise Error, 'Unknown source format' unless %w[auto mihomo clash surge singbox uri].include?(format)
      if format == 'uri' || text.match?(/\A(?:ss|trojan|anytls|vmess|vless|hysteria2|hy2|tuic):\/\//)
        nodes = text.lines.reject { |line| line.strip.empty? || line.lstrip.start_with?('#') }.map { |line| import_uri(line.strip) }
      elsif format == 'surge' || text.match?(/^\[Proxy\]\s*$/i)
        nodes = import_surge(text)
      elsif text.match?(/\A[A-Za-z0-9+\/_=\-\s]+\z/) && !text.include?(':')
        decoded = decode64(text.gsub(/\s/, ''))
        raise Error, 'Encoded source does not contain supported node links' unless decoded.match?(/\A(?:ss|trojan|anytls|vmess|vless|hysteria2|hy2|tuic):\/\//)
        return import_nodes(decoded, 'uri')
      else
        # No aliases, object tags or Ruby classes from provider-controlled YAML.
        value = YAML.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false)
        if value.is_a?(Hash) && value['proxies'].is_a?(Array)
          nodes = value['proxies']
        elsif value.is_a?(Hash) && value['outbounds'].is_a?(Array)
          nodes = value['outbounds'].reject { |n| n.is_a?(Hash) && %w[selector urltest direct block dns].include?(n['type']) }.map { |n| import_singbox(n) }
        elsif value.is_a?(Array)
          nodes = value
        else
          raise Error, 'Expected a Mihomo proxy list, Surge [Proxy], sing-box outbounds, or supported node links'
        end
      end
      raise Error, 'Source has no proxy nodes' if nodes.empty?
      raise Error, 'Source has too many nodes (maximum 4096)' if nodes.length > MAX_NODES
      names = {}
      nodes.each_with_index do |node, i|
        raise Error, "Node #{i + 1} must be an object" unless node.is_a?(Hash)
        node['type'] = 'hysteria2' if node['type'] == 'hy2'
        validate_node!(node, "Node #{i + 1}")
        raise Error, "Source contains duplicate node names at node #{i + 1}" if names[node['name']]
        names[node['name']] = true
      end
      copy(nodes)
    rescue Psych::Exception
      raise Error, 'Invalid or unsafe YAML source (aliases and object tags are disabled)'
    rescue JSON::ParserError, ArgumentError, URI::InvalidURIError, EncodingError
      raise Error, 'Malformed subscription; check its format and encoding'
    end

    def self.validate_node!(node, label)
      raise Error, "#{label}: node must be an object" unless node.is_a?(Hash)
      raise Error, "#{label}: property names must be strings" unless node.keys.all? { |k| k.is_a?(String) && !k.match?(/[\r\n\x00]/) }
      raise Error, "#{label}: unsupported proxy protocol" unless PROTOCOLS.include?(node['type'])
      raise Error, "#{label}: missing or invalid name" unless node['name'].is_a?(String) && !node['name'].strip.empty? && node['name'].length <= 256 && !node['name'].match?(/[\x00-\x1f\x7f]/)
      raise Error, "#{label}: missing or invalid server" unless node['server'].is_a?(String) && !node['server'].empty? && !node['server'].match?(/[\s,\x00-\x1f]/)
      raise Error, "#{label}: port must be 1–65535" unless node['port'].is_a?(Integer) && (1..65_535).cover?(node['port'])
      required = case node['type']
                 when 'vmess', 'vless' then %w[uuid]
                 when 'tuic' then node.key?('token') ? %w[token] : %w[uuid password]
                 when 'ss' then %w[cipher password]
                 else %w[password]
                 end
      required.each do |key|
        raise Error, "#{label}: missing #{key}" unless node[key].is_a?(String) && !node[key].empty? && !node[key].match?(/[\r\n\x00]/)
      end
      if node['uuid'] && (!node['uuid'].is_a?(String) || !node['uuid'].match?(/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/))
        raise Error, "#{label}: invalid UUID"
      end
      if node.key?('alpn') && (!node['alpn'].is_a?(Array) || !node['alpn'].all? { |v| v.is_a?(String) && !v.empty? && !v.match?(/[\r\n\x00]/) })
        raise Error, "#{label}: ALPN must be an array of strings"
      end
      %w[sni servername client-fingerprint network cipher flow packet-encoding obfs obfs-password].each do |key|
        if node.key?(key) && (!node[key].is_a?(String) || node[key].match?(/[\r\n\x00]/))
          raise Error, "#{label}: #{key} must be a string without line breaks"
        end
      end
      %w[alterId idle-session-check-interval idle-session-timeout min-idle-session heartbeat-interval].each do |key|
        if node.key?(key) && (!node[key].is_a?(Integer) || node[key] < 0)
          raise Error, "#{label}: #{key} must be a non-negative integer"
        end
      end
      %w[udp tfo tls skip-cert-verify].each do |key|
        raise Error, "#{label}: #{key} must be boolean" if node.key?(key) && ![true, false].include?(node[key])
      end
    end

    def validate(profile_id)
      p = profile(profile_id)
      results = Array(p['formats']).map { |format| render(profile_id, format) }
      errors = results.flat_map { |r| r['errors'] }.uniq
      errors << 'Profile must select at least one output format' if results.empty?
      context = context_for(profile_id)
      { 'errors' => (errors + context[:errors]).uniq, 'warnings' => results.flat_map { |r| r['warnings'] }.uniq,
        'summary' => { 'profile' => profile_id, 'formats' => Array(p['formats']), 'nodes' => context[:nodes].length,
                       'groups' => context[:groups].length, 'rules' => context[:rules].length,
                       'sources' => context[:source_counts] } }
    rescue Error => e
      { 'errors' => [e.message], 'warnings' => [], 'summary' => {} }
    end

    def render(profile_id, format, redact: false)
      raise Error, 'Unknown output format' unless FORMATS.include?(format)
      c = context_for(profile_id)
      errors, warnings = c[:errors].dup, []
      if errors.empty?
        content = case format
                  when 'mihomo' then render_mihomo(c, warnings, errors)
                  when 'surge' then render_surge(c, warnings, errors)
                  when 'singbox' then render_singbox(c, warnings, errors)
                  end
      end
      content = redact_content(content, c) if redact && content && errors.empty?
      { 'content' => errors.empty? ? content : '', 'warnings' => warnings.uniq, 'errors' => errors.uniq }
    rescue Error => e
      { 'content' => '', 'warnings' => [], 'errors' => [e.message] }
    end

    private

    def collection(key)
      value = @config[key] || []
      raise Error, "#{key} must be an array" unless value.is_a?(Array) && value.all? { |v| v.is_a?(Hash) }
      value
    end

    def profile(id)
      collection('profiles').find { |p| p['id'] == id } || (raise Error, 'Unknown profile')
    end

    def string_list(value, label)
      raise Error, "#{label} must be a list of strings" unless value.is_a?(Array) && value.all? { |v| v.is_a?(String) }
      value
    end

    def clean_name(value, label)
      raise Error, "#{label} has an invalid name" unless value.is_a?(String) && !value.strip.empty? && value.length <= 256 && !value.match?(/[\x00-\x1f\x7f]/)
      value
    end

    def regexp(value, label)
      return nil if value.nil? || value == ''
      raise Error, "#{label}: filter must be a string of at most 512 characters" unless value.is_a?(String) && value.length <= 512
      # Ruby 3.4 bounds matching time; older local Ruby is used only for development.
      Regexp.respond_to?(:timeout=) ? Regexp.new(value, timeout: 0.05) : Regexp.new(value)
    rescue RegexpError
      raise Error, "#{label}: invalid regular expression"
    end

    def context_for(profile_id)
      c = { errors: [], nodes: [], groups: [], rules: [], source_counts: {}, sets: {} }
      raise Error, 'Configuration and caches must be objects' unless @config.is_a?(Hash) && @caches.is_a?(Hash)
      %w[sources profiles groups rematches sub_rules rule_sets rules].each do |key|
        seen = {}
        collection(key).each do |item|
          id = item['id']
          raise Error, "#{key}: invalid ID" unless id.is_a?(String) && ID.match?(id)
          raise Error, "#{key}: duplicate ID #{id}" if seen[id]
          seen[id] = true
        end
      end
      p = profile(profile_id)
      c[:profile] = p
      clean_name(p['name'], 'Profile')
      source_ids = string_list(p['sources'], 'Profile sources')
      formats = string_list(p['formats'], 'Profile formats')
      raise Error, 'Profile contains duplicate sources or formats' if source_ids.uniq != source_ids || formats.uniq != formats
      raise Error, 'Unknown profile format' unless (formats - FORMATS).empty?
      sources = collection('sources').each_with_object({}) { |s, h| h[s['id']] = s }
      regions = Regions.new(@config.fetch('regions', []), source_ids: sources.keys)
      used_names = BUILTINS.each_with_object({}) { |n, h| h[n] = true }
      source_ids.each do |id|
        source = sources[id] || (raise Error, "Unknown source #{id}")
        raise Error, "Source #{id} is disabled" if source['enabled'] == false
        source_name = clean_name(source['name'], "Source #{id}")
        cache = @caches[id]
        raise Error, "Source #{id} has no valid cached nodes" unless cache.is_a?(Hash) && cache['nodes'].is_a?(Array) && !cache['nodes'].empty?
        exclusion = regexp(source['exclude_filter'], "Source #{id}")
        count = 0
        cache['nodes'].each_with_index do |raw, i|
          self.class.validate_node!(raw, "Source #{id}, node #{i + 1}")
          next if exclusion && exclusion.match?(raw['name'])
          n = self.class.copy(raw)
          n['name'] = "#{source_name} | #{raw['name']}"
          raise Error, "Duplicate policy name #{n['name']}" if used_names[n['name']]
          used_names[n['name']] = true
          c[:nodes] << { raw: n, source: id, original_name: raw['name'] }
          count += 1
        end
        c[:source_counts][id] = count
        raise Error, "Source #{id} has no nodes after filtering" if count.zero?
      end
      raise Error, 'Profile has no nodes' if c[:nodes].empty?
      c[:groups] = collection('groups').select { |g| g['profile'] == profile_id }
      c[:group_map] = c[:groups].each_with_object({}) { |g, h| h[g['id']] = g }
      c[:rematches] = collection('rematches').select { |r| r['profile'] == profile_id }
      c[:sub_rules] = collection('sub_rules').select { |r| r['profile'] == profile_id }
      c[:rematch_map] = c[:rematches].each_with_object({}) { |r, h| h[r['id']] = r }
      c[:sub_rule_map] = c[:sub_rules].each_with_object({}) { |r, h| h[r['id']] = r }
      c[:rematches].each do |r|
        raise Error, "Duplicate group/rematch ID #{r['id']}" if c[:group_map].key?(r['id'])
        name = clean_name(r['name'], "Rematch #{r['id']}")
        raise Error, "Rematch #{r['id']}: names cannot contain commas" if name.include?(',')
        raise Error, "Duplicate policy name #{name}" if used_names[name]
        used_names[name] = true
        raise Error, "Rematch #{r['id']}: missing sub-rule reference" unless c[:sub_rule_map].key?(r['target_sub_rule'])
        if r['rematch_name'] && r['rematch_name'] != ''
          clean_name(r['rematch_name'], "Rematch #{r['id']} matching name")
          raise Error, "Rematch #{r['id']}: matching name contains a rule delimiter" if r['rematch_name'].match?(/[,()]/)
        end
      end
      sub_names = {}
      c[:sub_rules].each do |r|
        name = clean_name(r['name'], "Sub-rule #{r['id']}")
        raise Error, "Sub-rule #{r['id']}: name contains a rule delimiter" if name.match?(/[,()]/)
        raise Error, "Duplicate sub-rule name #{name}" if sub_names[name]
        sub_names[name] = true
        policy_name(c, r['final_policy'])
      end
      c[:groups].each do |g|
        name = clean_name(g['name'], "Group #{g['id']}")
        raise Error, "Group #{g['id']}: names cannot contain commas" if name.include?(',')
        raise Error, "Duplicate policy name #{name}" if used_names[name]
        used_names[name] = true
        members = string_list(g.fetch('members', []), "Group #{g['id']} members")
        group_sources = string_list(g.fetch('sources', []), "Group #{g['id']} sources")
        raise Error, "Group #{g['id']} uses a source outside this profile" unless (group_sources - source_ids).empty?
        raise Error, "Group #{g['id']} has duplicate members or sources" if members.uniq != members || group_sources.uniq != group_sources
        members.each { |m| policy_name(c, m) }
        region_id = g.fetch('region', '')
        raise Error, "Group #{g['id']}: region must be an ID or empty" unless region_id.is_a?(String)
        raise Error, "Group #{g['id']}: unknown region #{region_id}" unless region_id.empty? || regions.include?(region_id)
        include_re = regexp(g['filter'], "Group #{g['id']}")
        exclude_re = regexp(g['exclude_filter'], "Group #{g['id']}")
        matched = c[:nodes].select { |n| group_sources.include?(n[:source]) && (region_id.empty? || regions.match?(region_id, n[:source], n[:original_name])) && (!include_re || include_re.match?(n[:original_name])) && (!exclude_re || !exclude_re.match?(n[:original_name])) }
        g['_nodes'] = matched.map { |n| n[:raw]['name'] }
        raise Error, "Group #{g['id']} has no members after filtering" if matched.empty? && members.empty?
      end
      policy_name(c, p['final_policy'])
      c[:sets] = collection('rule_sets').each_with_object({}) { |r, h| h[r['id']] = r }
      c[:all_rules] = collection('rules').select { |r| r['profile'] == profile_id && r['enabled'] != false }
      c[:rules] = c[:all_rules].select { |r| r['sub_rule'].to_s.empty? }
      c[:all_rules].each do |r|
        raise Error, "Rule #{r['id']}: missing sub-rule scope" if !r['sub_rule'].to_s.empty? && !c[:sub_rule_map].key?(r['sub_rule'])
        validate_rule!(c, r)
      end
      c[:groups].each do |g|
        if !g['default_member'].to_s.empty?
          raise Error, "Group #{g['id']}: default member is not a member" unless Array(g['members']).include?(g['default_member'])
          policy_name(c, g['default_member'])
        end
        policy_name(c, g['empty_fallback']) unless g['empty_fallback'].to_s.empty?
        raise Error, "Group #{g['id']}: lazy must be boolean" if g.key?('lazy') && ![true, false].include?(g['lazy'])
      end
      validate_dns!(c)
      used_sets(c).each { |set| policy_name(c, set['mihomo_proxy']) unless set['mihomo_proxy'].to_s.empty? }
      validate_policy_graph!(c)
      validate_mihomo_policy!(c)
      c
    rescue Error => e
      c[:errors] << e.message
      c
    rescue StandardError => e
      raise unless e.class.name == 'Regexp::TimeoutError'
      c[:errors] << 'Regular expression exceeded its time limit'
      c
    end

    def policy_name(c, id)
      return id if BUILTINS.include?(id)
      g = c[:group_map][id] || c.fetch(:rematch_map, {})[id]
      raise Error, "Missing policy reference #{id}" unless g
      g['name']
    end

    def validate_policy_graph!(c)
      edges = {}
      c[:groups].each { |g| edges["p:#{g['id']}"] = (Array(g['members']) + [g['empty_fallback']].compact.reject { |m| m == '' }).reject { |m| BUILTINS.include?(m) }.map { |m| "p:#{m}" } }
      c[:rematches].each { |r| edges["p:#{r['id']}"] = ["s:#{r['target_sub_rule']}"] }
      c[:sub_rules].each do |r|
        policies = c[:all_rules].select { |v| v['sub_rule'] == r['id'] }.map { |v| v['policy'] } + [r['final_policy']]
        edges["s:#{r['id']}"] = policies.reject { |m| BUILTINS.include?(m) }.map { |m| "p:#{m}" }
      end
      visited, active = {}, {}
      visit = lambda do |id|
        return if visited[id]
        raise Error, "Policy group/sub-rule cycle at #{id}" if active[id]
        active[id] = true
        Array(edges[id]).each { |other| visit.call(other) }
        active.delete(id)
        visited[id] = true
      end
      edges.each_key { |id| visit.call(id) }
    end

    def validate_rule!(c, r)
      policy_name(c, r['policy'])
      validate_condition!(c, r, "Rule #{r['id']}", 0, !r['sub_rule'].to_s.empty?)
    end

    def validate_condition!(c, r, label, depth = 0, sub_rule = false)
      raise Error, "#{label}: condition must be an object" unless r.is_a?(Hash)
      raise Error, "#{label}: condition nesting exceeds 8 levels" if depth > 8
      type, value = r['type'], r['value']
      raise Error, "#{label}: unsupported rule type" unless RULE_TYPES.include?(type)
      if %w[AND OR NOT].include?(type)
        children = r['conditions']
        valid = children.is_a?(Array) && (type == 'NOT' ? children.length == 1 : (2..64).cover?(children.length))
        raise Error, "#{label}: NOT needs one condition; AND/OR need 2–64 conditions" unless valid
        raise Error, "#{label}: logical rule cannot have a value or no-resolve" if (value && value != '') || r['no_resolve']
        children.each do |child|
          raise Error, "#{label}: nested condition cannot contain policy or scope" if child.is_a?(Hash) && (child.keys - %w[type value conditions no_resolve]).any?
          validate_condition!(c, child, label, depth + 1, sub_rule)
        end
        return
      end
      raise Error, "#{label}: leaf rule cannot have conditions" if r['conditions'] && r['conditions'] != []
      raise Error, "#{label}: invalid value" unless value.is_a?(String) && !value.empty? && value.length <= 1024 && !value.match?(/[,()\r\n\x00]/)
      case type
      when 'IP-CIDR', 'IP-CIDR6'
        begin
          ip = IPAddr.new(value)
          raise ArgumentError unless value.include?('/') && (type == 'IP-CIDR6' ? ip.ipv6? : ip.ipv4?)
        rescue IPAddr::Error, ArgumentError
          raise Error, "#{label}: invalid IP prefix"
        end
      when 'DOMAIN', 'DOMAIN-SUFFIX'
        raise Error, "#{label}: invalid domain" if value.match?(/[\s\/:]/) || value.start_with?('.') || value.end_with?('.')
      when 'GEOIP'
        raise Error, "#{label}: GEOIP must be a country code or LAN" unless value.match?(/\A(?:[A-Za-z]{2}|LAN)\z/)
      when 'GEOSITE'
        raise Error, "#{label}: invalid GEOSITE category" unless value.match?(/\A[a-zA-Z0-9_@!.:-]+\z/)
      when 'REMATCH-NAME'
        raise Error, "#{label}: REMATCH-NAME is only valid inside a sub-rule" unless sub_rule
      when 'RULE-SET'
        raise Error, "#{label}: missing rule set" unless c[:sets][value]
      when 'DST-PORT'
        raise Error, "#{label}: port must be 1–65535" unless value.match?(/\A\d+\z/) && (1..65_535).cover?(value.to_i)
      when 'NETWORK'
        raise Error, "#{label}: network must be TCP or UDP" unless %w[TCP UDP].include?(value.upcase)
      end
      if r['no_resolve'] && !%w[IP-CIDR IP-CIDR6 GEOIP RULE-SET].include?(type)
        raise Error, "#{label}: no-resolve is not valid for this rule type"
      end
    end

    DNS_KEYS = %w[enable ipv6 enhanced-mode fake-ip-range fake-ip-range6 fake-ip-filter-mode fake-ip-filter respect-rules use-hosts use-system-hosts prefer-h3 nameserver default-nameserver proxy-server-nameserver direct-nameserver direct-nameserver-follow-policy fallback nameserver-policy proxy-server-nameserver-policy fallback-filter cache-algorithm].freeze

    def validate_dns!(c)
      dns = c[:profile]['mihomo_dns']
      return if dns.nil? || dns == {}
      raise Error, 'Mihomo DNS must be an object' unless dns.is_a?(Hash)
      raise Error, 'Mihomo DNS contains unsupported settings (listeners are managed separately)' unless (dns.keys - DNS_KEYS).empty?
      %w[enable ipv6 respect-rules use-hosts use-system-hosts prefer-h3 direct-nameserver-follow-policy].each do |k|
        raise Error, "Mihomo DNS #{k} must be boolean" if dns.key?(k) && ![true, false].include?(dns[k])
      end
      %w[nameserver default-nameserver proxy-server-nameserver direct-nameserver fallback fake-ip-filter].each do |k|
        next unless dns.key?(k)
        string_list(dns[k], "Mihomo DNS #{k}")
        raise Error, "Mihomo DNS #{k}: invalid entry" if dns[k].length > 4096 || dns[k].any? { |v| v.empty? || v.match?(/[\r\n\x00]/) }
      end
      %w[nameserver-policy proxy-server-nameserver-policy fallback-filter].each do |k|
        raise Error, "Mihomo DNS #{k} must be an object" if dns.key?(k) && !dns[k].is_a?(Hash)
      end
      dns_rule_set_ids(c).each { |id| raise Error, "Mihomo DNS references missing rule set #{id}" unless c[:sets].key?(id) }
    end

    def dns_rule_set_ids(c)
      dns = c[:profile]['mihomo_dns'] || {}
      values = Array(dns['fake-ip-filter']) + %w[nameserver-policy proxy-server-nameserver-policy].flat_map { |k| (dns[k] || {}).keys }
      values.select { |v| v.is_a?(String) && v.start_with?('rule-set:') }.flat_map { |v| v.delete_prefix('rule-set:').split(',') }.uniq
    end

    MIHOMO_POLICY_KEYS = %w[geodata-mode geodata-loader geox-url geo-auto-update geo-update-interval keep-alive-interval keep-alive-idle disable-keep-alive ipv6 tcp-concurrent unified-delay experimental sniffer profile hosts].freeze

    def validate_mihomo_policy!(c)
      policy = c[:profile]['mihomo_policy']
      return if policy.nil? || policy == {}
      raise Error, 'Mihomo policy must be an object' unless policy.is_a?(Hash)
      raise Error, 'Mihomo policy contains unsupported settings (API, listener and router bindings are excluded)' unless (policy.keys - MIHOMO_POLICY_KEYS).empty?
      %w[geodata-mode geo-auto-update disable-keep-alive ipv6 tcp-concurrent unified-delay].each do |key|
        raise Error, "Mihomo policy #{key} must be boolean" if policy.key?(key) && ![true, false].include?(policy[key])
      end
      %w[geo-update-interval keep-alive-interval keep-alive-idle].each do |key|
        integer(policy[key], nil, 0, 2_147_483_647, "Mihomo policy #{key}") if policy.key?(key)
      end
      %w[geox-url experimental sniffer profile hosts].each do |key|
        raise Error, "Mihomo policy #{key} must be an object" if policy.key?(key) && !policy[key].is_a?(Hash)
      end
      if policy['geox-url']
        raise Error, 'Mihomo policy geox-url contains unsupported databases' unless (policy['geox-url'].keys - %w[geoip geosite mmdb asn]).empty?
        policy['geox-url'].each_value { |url| http_url(url, 'Mihomo geodata URL') }
      end
      if policy['profile'] && (policy['profile'].keys - %w[store-selected store-fake-ip]).any?
        raise Error, 'Mihomo profile policy supports only store-selected/store-fake-ip'
      end
      if policy['geodata-loader'] && !%w[standard memconservative].include?(policy['geodata-loader'])
        raise Error, 'Mihomo geodata-loader must be standard or memconservative'
      end
    end

    def portable_policy_warnings(c, format, warnings)
      if c[:profile]['mihomo_policy'] && !c[:profile]['mihomo_policy'].empty?
        warning(warnings, format, 'mihomo-policy', 'Mihomo-specific runtime and geodata policy has no equivalent export here and will be omitted')
      end
      c[:groups].each do |g|
        %w[default_member empty_fallback lazy].each do |key|
          next if !g.key?(key) || g[key].nil? || g[key] == ''
          warning(warnings, format, "group-option:#{g['id']}:#{key}", "#{g['name']}: Mihomo #{key} is not preserved in #{format}")
        end
      end
      used_sets(c).each do |set|
        next if set['mihomo_proxy'].to_s.empty?
        warning(warnings, format, "ruleset-proxy:#{set['id']}", "Rule set #{set['id']}: Mihomo download proxy selection is not preserved in #{format}")
      end
    end

    def inline_conditions(c, set)
      text = set['inline_rules']
      raise Error, "Rule set #{set['id']}: inline rules must be text (maximum 512 KiB)" unless text.is_a?(String) && text.bytesize <= 524_288
      rules = text.lines.map(&:strip).reject { |line| line.empty? || line.start_with?('#', '//') }
      raise Error, "Rule set #{set['id']}: inline rule set is empty" if rules.empty?
      rules.map do |line|
        type, value, option, *extra = line.split(',', -1)
        raise Error, "Rule set #{set['id']}: inline rules cannot contain policies or logical expressions" unless extra.empty? && [nil, 'no-resolve'].include?(option) && !%w[RULE-SET REMATCH-NAME AND OR NOT].include?(type)
        r = { 'type' => type, 'value' => value, 'no_resolve' => option == 'no-resolve' }
        validate_condition!(c, r, "Rule set #{set['id']}")
        r
      end
    end

    def require_portable_policy!(c, format)
      incompatible = []
      incompatible << 'rematch/shared-region routing' unless c[:rematches].empty?
      incompatible << 'Mihomo sub-rules' unless c[:sub_rules].empty?
      incompatible << 'native Mihomo DNS policy' if c[:profile]['mihomo_dns'].is_a?(Hash) && !c[:profile]['mihomo_dns'].empty?
      types = []
      collect = lambda do |r|
        types << r['type'] if %w[GEOSITE REMATCH-NAME AND OR NOT].include?(r['type'])
        Array(r['conditions']).each { |child| collect.call(child) }
      end
      c[:all_rules].each { |r| collect.call(r) }
      incompatible.concat(types.uniq)
      incompatible << 'inline rule sets (currently Mihomo only)' if used_sets(c).any? { |r| r['source_type'] == 'inline' }
      raise Error, "#{format}: this profile requires #{incompatible.join(', ')}; create a separate compatible profile instead of discarding these policies" unless incompatible.empty?
    end

    def http_url(value, label)
      u = URI.parse(value.to_s)
      raise Error, "#{label}: HTTP(S) URL required" unless %w[http https].include?(u.scheme) && u.host && !u.userinfo && !value.match?(/[\r\n\x00]/)
      value
    rescue URI::InvalidURIError
      raise Error, "#{label}: invalid URL"
    end

    def integer(value, default, min, max, label)
      value = default if value.nil?
      raise Error, "#{label}: invalid number" unless value.is_a?(Integer) && (min..max).cover?(value)
      value
    end

    def warning(warnings, target, code, message)
      warnings << { 'code' => "#{target}:#{code}", 'message' => message, 'target' => target }
    end

    def node_warnings(node, supported, target, warnings)
      (node.keys - supported).sort.each do |key|
        warning(warnings, target, "field:#{Digest::SHA256.hexdigest(node['name'])[0, 12]}:#{key}", "#{node['name']}: #{key} cannot be represented in #{target} and will be omitted")
      end
    end

    def group_members(c, g)
      Array(g['members']).map { |m| policy_name(c, m) } + g['_nodes']
    end

    def used_sets(c)
      ids = []
      visit = lambda do |r|
        ids << r['value'] if r['type'] == 'RULE-SET'
        Array(r['conditions']).each { |v| visit.call(v) }
      end
      c[:all_rules].each { |r| visit.call(r) }
      ids.concat(dns_rule_set_ids(c))
      ids.uniq.map { |id| c[:sets][id] }
    end

    def mihomo_condition(r)
      if %w[AND OR NOT].include?(r['type'])
        "#{r['type']},(" + r['conditions'].map { |v| "(#{mihomo_condition(v)})" }.join(',') + ')'
      else
        value = r['type'] == 'NETWORK' ? r['value'].downcase : r['value']
        [r['type'], value, (r['no_resolve'] ? 'no-resolve' : nil)].compact.join(',')
      end
    end

    def mihomo_rule(c, r)
      # no-resolve belongs after the policy for top-level rules.
      expr = mihomo_condition(r.reject { |k, _| k == 'no_resolve' })
      [expr, policy_name(c, r['policy']), (r['no_resolve'] ? 'no-resolve' : nil)].compact.join(',')
    end

    def render_mihomo(c, warnings, errors)
      groups = c[:groups].map do |g|
        type = g.fetch('mihomo_type', 'select')
        raise Error, "Group #{g['id']}: unsupported Mihomo type" unless %w[select url-test fallback load-balance smart].include?(type)
        raise Error, "Group #{g['id']}: Smart requires the Mihomo Smart core" if type == 'smart' && c[:profile]['mihomo_core'] != 'smart'
        x = { 'name' => g['name'], 'type' => type, 'proxies' => group_members(c, g) }
        if type != 'select'
          x['url'] = http_url(g.fetch('url', 'https://www.gstatic.com/generate_204'), "Group #{g['id']}")
          x['interval'] = integer(g['interval'], 300, 10, 86_400, 'Group interval')
          x['tolerance'] = integer(g['tolerance'], 50, 0, 60_000, 'Group tolerance') if type == 'url-test'
        end
        x.merge!('uselightgbm' => false, 'collectdata' => false, 'prefer-asn' => false) if type == 'smart'
        x['hidden'] = true if g['hidden']
        x['default-selected'] = policy_name(c, g['default_member']) unless g['default_member'].to_s.empty?
        x['empty-fallback'] = policy_name(c, g['empty_fallback']) unless g['empty_fallback'].to_s.empty?
        x['lazy'] = g['lazy'] if g.key?('lazy')
        x
      end
      providers = used_sets(c).each_with_object({}) do |set, h|
        source_type = set.fetch('source_type', 'remote')
        raise Error, "Rule set #{set['id']}: invalid source type" unless %w[remote inline].include?(source_type)
        if source_type == 'inline'
          raise Error, "Rule set #{set['id']}: inline rules require classical behavior" unless set.fetch('behavior', 'classical') == 'classical'
          h[set['id']] = { 'type' => 'inline', 'behavior' => 'classical', 'payload' => inline_conditions(c, set).map { |r| mihomo_condition(r) } }
          next
        end
        behavior, format = set.fetch('behavior', 'classical'), set.fetch('mihomo_format', 'text')
        raise Error, "Rule set #{set['id']}: invalid Mihomo behavior or format" unless %w[domain ipcidr classical].include?(behavior) && %w[text yaml mrs].include?(format)
        raise Error, "Rule set #{set['id']}: MRS cannot contain classical rules" if format == 'mrs' && behavior == 'classical'
        cache_key = Digest::SHA256.hexdigest([set['mihomo_url'], behavior, format].join("\x00"))[0, 12]
        h[set['id']] = { 'type' => 'http', 'behavior' => behavior, 'format' => format,
                         'url' => http_url(set['mihomo_url'], "Rule set #{set['id']} Mihomo"),
                         'path' => "./rule_provider/hybrid-#{set['id']}-#{cache_key}.#{format == 'text' ? 'txt' : format}",
                         'interval' => integer(set['interval'], 86_400, 60, 2_592_000, 'Rule set interval') }
        h[set['id']]['proxy'] = policy_name(c, set['mihomo_proxy']) unless set['mihomo_proxy'].to_s.empty?
      end
      rules = c[:rules].map { |r| mihomo_rule(c, r) }
      rules << "MATCH,#{policy_name(c, c[:profile]['final_policy'])}"
      nodes = c[:nodes].map { |n| self.class.copy(n[:raw]) }
      nodes.each do |n|
        # Source-local dependency names are intentionally not guessed across providers.
        raise Error, "#{n['name']}: dialer-proxy requires an explicit supported dependency mapping" if n.key?('dialer-proxy')
      end
      c[:rematches].each do |r|
        node = { 'name' => r['name'], 'type' => 'rematch', 'target-sub-rule' => c[:sub_rule_map][r['target_sub_rule']]['name'] }
        node['target-rematch-name'] = r['rematch_name'] unless r['rematch_name'].to_s.empty?
        nodes << node
      end
      output = { 'mixed-port' => 7890, 'allow-lan' => false, 'mode' => 'rule', 'log-level' => 'info',
                 'proxies' => nodes, 'proxy-groups' => groups, 'rule-providers' => providers, 'rules' => rules }
      unless c[:sub_rules].empty?
        output['sub-rules'] = c[:sub_rules].each_with_object({}) do |sub, h|
          h[sub['name']] = c[:all_rules].select { |r| r['sub_rule'] == sub['id'] }.map { |r| mihomo_rule(c, r) } + ["MATCH,#{policy_name(c, sub['final_policy'])}"]
        end
      end
      output['dns'] = self.class.copy(c[:profile]['mihomo_dns']) if c[:profile]['mihomo_dns'] && !c[:profile]['mihomo_dns'].empty?
      output.merge!(self.class.copy(c[:profile]['mihomo_policy'])) if c[:profile]['mihomo_policy']
      YAML.dump(output)
    end

    def surge_value(value)
      s = value.is_a?(Array) ? value.join(',') : value.to_s
      raise Error, 'Surge field contains a line break or NUL' if s.match?(/[\r\n\x00]/)
      s.match?(/[,;"\\]|\A\s|\s\z/) ? JSON.generate(s) : s
    end

    def render_surge(c, warnings, errors)
      require_portable_policy!(c, 'surge')
      portable_policy_warnings(c, 'surge', warnings)
      # Names commonly contain [A]/[B]; brackets inside policy names are valid.
      c[:nodes].each { |n| validate_surge_name(n[:raw]['name']) }
      c[:groups].each { |g| validate_surge_name(g['name']) }
      lines = ['#!FORBIDDEN-AUTO-UPGRADE smart-group', '[General]', 'loglevel = notify', 'dns-server = system', '', '[Proxy]']
      c[:nodes].each do |n|
        begin
          lines << surge_node(n[:raw], warnings)
        rescue Error => e
          errors << "surge: #{e.message}"
        end
      end
      lines += ['', '[Proxy Group]']
      c[:groups].each do |g|
        type = g.fetch('surge_type', 'select')
        raise Error, "Group #{g['id']}: unsupported Surge type" unless %w[select url-test fallback load-balance smart].include?(type)
        raise Error, "Group #{g['id']}: Surge Smart accepts only nodes, not groups or DIRECT/REJECT" if type == 'smart' && !Array(g['members']).empty?
        fields = [type] + group_members(c, g).map { |n| surge_value(n) }
        if %w[url-test fallback load-balance].include?(type)
          fields << "url=#{surge_value(http_url(g.fetch('url', 'https://www.gstatic.com/generate_204'), 'Group test URL'))}"
          fields << "interval=#{integer(g['interval'], 300, 10, 86_400, 'Group interval')}"
          fields << "tolerance=#{integer(g['tolerance'], 50, 0, 60_000, 'Group tolerance')}" if type == 'url-test'
        end
        fields << 'hidden=true' if g['hidden']
        lines << "#{g['name']} = #{fields.join(', ')}"
      end
      lines += ['', '[Rule]']
      c[:rules].each do |r|
        type, value = r['type'], r['value']
        if type == 'RULE-SET'
          set = c[:sets][value]
          value = http_url(set['surge_url'], "Rule set #{set['id']} Surge")
          type = 'DOMAIN-SET' if set['behavior'] == 'domain'
        elsif type == 'GEOIP' && value.upcase == 'LAN'
          type, value = 'RULE-SET', 'LAN'
          warning(warnings, 'surge', "lan:#{r['id']}", 'Surge built-in LAN and Mihomo GEOIP LAN may cover different reserved ranges')
        elsif type == 'NETWORK'
          type, value = 'PROTOCOL', value.upcase
        elsif type == 'DST-PORT'
          type = 'DEST-PORT'
        end
        parts = [type, surge_value(value), policy_name(c, r['policy'])]
        parts << 'no-resolve' if r['no_resolve']
        parts << "update-interval=#{integer(c[:sets][r['value']]['interval'], 86_400, 60, 2_592_000, 'Rule set interval')}" if r['type'] == 'RULE-SET'
        lines << parts.join(',')
      end
      lines << "FINAL,#{policy_name(c, c[:profile]['final_policy'])}"
      lines.join("\n") + "\n"
    end

    def validate_surge_name(value)
      raise Error, "Surge policy name contains unsupported delimiter: #{value}" if value.match?(/[,="\r\n]/) || value.start_with?('#', ';', '//')
    end

    def surge_node(n, warnings)
      type = n['type']
      raise Error, "#{n['name']}: Surge does not support #{type}" if type == 'vless'
      supported = %w[name type server port udp tfo sni servername skip-cert-verify alpn]
      if n['type'] == 'ss' && n.keys.any? { |k| %w[sni servername tls skip-cert-verify alpn].include?(k) }
        raise Error, "#{n['name']}: TLS-wrapped Shadowsocks needs an explicit Surge mapping"
      end
      params = {}
      case type
      when 'anytls', 'trojan', 'hysteria2'
        supported << 'password'
        params['password'] = n['password']
      when 'ss'
        supported += %w[password cipher]
        params['encrypt-method'], params['password'] = n['cipher'], n['password']
        params['udp-relay'] = n.fetch('udp', false)
        raise Error, "#{n['name']}: Shadowsocks plugin requires a separate verified Surge mapping" if n['plugin']
      when 'vmess'
        supported += %w[uuid alterId cipher tls]
        raise Error, "#{n['name']}: legacy VMess alterId is not supported" unless n.fetch('alterId', 0).to_i.zero?
        cipher = n.fetch('cipher', 'auto')
        cipher = 'aes-128-gcm' if cipher == 'auto'
        raise Error, "#{n['name']}: unsupported Surge VMess encryption" unless %w[aes-128-gcm chacha20-ietf-poly1305].include?(cipher)
        params.merge!('username' => n['uuid'], 'encrypt-method' => cipher, 'vmess-aead' => true, 'tls' => n.fetch('tls', false))
      when 'tuic'
        if n['token']
          supported << 'token'
          params['token'] = n['token']
        else
          type = 'tuic-v5'
          supported += %w[uuid password]
          params['uuid'], params['password'] = n['uuid'], n['password']
        end
      end
      if %w[trojan vmess].include?(n['type'])
        supported << 'network'
        network = n.fetch('network', 'tcp')
        raise Error, "#{n['name']}: Surge transport #{network} is not supported" unless %w[tcp ws].include?(network)
        if network == 'ws'
          supported << 'ws-opts'
          opts = n.fetch('ws-opts', {})
          raise Error, "#{n['name']}: unsupported WebSocket transport options" unless opts.is_a?(Hash) && (opts.keys - %w[path headers]).empty?
          params['ws'], params['ws-path'] = true, opts.fetch('path', '/')
          headers = opts.fetch('headers', {})
          raise Error, "#{n['name']}: invalid WebSocket headers" unless headers.is_a?(Hash) && headers.all? { |k, v| k.is_a?(String) && v.is_a?(String) && ![k, v].join.match?(/[|\r\n]/) }
          params['ws-headers'] = headers.map { |k, v| "#{k}:#{v}" }.join('|') unless headers.empty?
        end
      end
      if n['type'] == 'hysteria2'
        supported += %w[down obfs obfs-password]
        params['download-bandwidth'] = bandwidth(n['down']) if n['down']
        if n['obfs']
          raise Error, "#{n['name']}: unknown Hysteria2 obfuscation" unless %w[salamander gecko].include?(n['obfs']) && n['obfs-password'].is_a?(String)
          params["#{n['obfs']}-password"] = n['obfs-password']
        end
      end
      %w[reality-opts shadow-tls-opts restls-opts jls-opts dialer-proxy].each do |key|
        raise Error, "#{n['name']}: #{key} needs a supported explicit Surge mapping" if n[key]
      end
      params['sni'] = n['sni'] || n['servername'] if n['sni'] || n['servername']
      params['skip-cert-verify'] = n['skip-cert-verify'] if n.key?('skip-cert-verify')
      params['alpn'] = n['alpn'] if n['alpn']
      params['tfo'] = n['tfo'] if n.key?('tfo')
      if n['udp'] == false && n['type'] != 'ss'
        warning(warnings, 'surge', "udp:#{Digest::SHA256.hexdigest(n['name'])[0, 12]}", "#{n['name']}: this Surge protocol always supports UDP; source udp=false is not preserved")
      end
      node_warnings(n, supported, 'surge', warnings)
      "#{n['name']} = #{([type, surge_value(n['server']), n['port'].to_s] + params.map { |k, v| "#{k}=#{surge_value(v)}" }).join(', ')}"
    end

    def bandwidth(value)
      s = value.to_s
      raise Error, 'Bandwidth must be Mbps or a number followed by Mbps' unless s.match?(/\A\d+(?:\.\d+)?(?:\s*[Mm][Bb][Pp][Ss])?\z/)
      raise Error, 'Target bandwidth must be a whole number of Mbps' unless s.to_f == s.to_i
      s.to_i
    end

    def render_singbox(c, warnings, errors)
      require_portable_policy!(c, 'singbox')
      portable_policy_warnings(c, 'singbox', warnings)
      outbounds = [{ 'type' => 'direct', 'tag' => 'DIRECT' }]
      c[:nodes].each do |n|
        begin
          outbounds << singbox_node(n[:raw], warnings)
        rescue Error => e
          errors << "singbox: #{e.message}"
        end
      end
      c[:groups].each do |g|
        type = g.fetch('singbox_type', 'selector')
        raise Error, "Group #{g['id']}: sing-box supports selector or urltest" unless %w[selector urltest].include?(type)
        raise Error, "Group #{g['id']}: sing-box cannot put REJECT in an outbound group" if Array(g['members']).include?('REJECT')
        x = { 'type' => type, 'tag' => g['name'], 'outbounds' => group_members(c, g) }
        if type == 'urltest'
          x['url'] = http_url(g.fetch('url', 'https://www.gstatic.com/generate_204'), 'Group test URL')
          x['interval'] = "#{integer(g['interval'], 300, 10, 86_400, 'Group interval')}s"
          x['tolerance'] = integer(g['tolerance'], 50, 0, 60_000, 'Group tolerance')
        else
          x['default'] = x['outbounds'].first
        end
        warning(warnings, 'singbox', "hidden:#{g['id']}", "#{g['name']}: sing-box does not preserve the hidden group flag") if g['hidden']
        outbounds << x
      end
      rules = c[:rules].map do |r|
        x = {}
        case r['type']
        when 'DOMAIN' then x['domain'] = [r['value']]
        when 'DOMAIN-SUFFIX' then x['domain_suffix'] = [r['value']]
        when 'DOMAIN-KEYWORD' then x['domain_keyword'] = [r['value']]
        when 'IP-CIDR', 'IP-CIDR6' then x['ip_cidr'] = [r['value']]
        when 'DST-PORT' then x['port'] = [r['value'].to_i]
        when 'NETWORK' then x['network'] = r['value'].downcase
        when 'RULE-SET' then x['rule_set'] = [r['value']]
        when 'GEOIP'
          raise Error, "Rule #{r['id']}: sing-box 1.12 removed GEOIP; select a native sing-box rule set instead" unless r['value'].upcase == 'LAN'
          x['ip_is_private'] = true
          warning(warnings, 'singbox', "lan:#{r['id']}", 'sing-box ip_is_private and Mihomo GEOIP LAN do not cover exactly the same reserved ranges')
        end
        warning(warnings, 'singbox', "resolve:#{r['id']}", "Rule #{r['id']}: Mihomo no-resolve is not an equivalent sing-box rule flag") if r['no_resolve']
        if r['policy'] == 'REJECT'
          x['action'] = 'reject'
        else
          x['action'], x['outbound'] = 'route', policy_name(c, r['policy'])
        end
        x
      end
      sets = used_sets(c).map do |set|
        format = set.fetch('singbox_format', 'source')
        raise Error, "Rule set #{set['id']}: sing-box format must be source or binary" unless %w[source binary].include?(format)
        { 'type' => 'remote', 'tag' => set['id'], 'format' => format,
          'url' => http_url(set['singbox_url'], "Rule set #{set['id']} sing-box"),
          'download_detour' => 'DIRECT', 'update_interval' => "#{integer(set['interval'], 86_400, 60, 2_592_000, 'Rule set interval')}s" }
      end
      final = policy_name(c, c[:profile]['final_policy'])
      if final == 'REJECT'
        rules << { 'action' => 'reject' }
        final = 'DIRECT'
      end
      JSON.pretty_generate({ 'log' => { 'level' => 'warn' },
                             'dns' => { 'servers' => [{ 'type' => 'local', 'tag' => 'local-dns' }] },
                             'inbounds' => [{ 'type' => 'mixed', 'tag' => 'mixed-in', 'listen' => '127.0.0.1', 'listen_port' => 7890 }],
                             'outbounds' => outbounds,
                             'route' => { 'default_domain_resolver' => 'local-dns', 'rules' => rules, 'rule_set' => sets, 'final' => final, 'auto_detect_interface' => true } }) + "\n"
    end

    def singbox_node(n, warnings)
      type = n['type'] == 'ss' ? 'shadowsocks' : n['type']
      x = { 'type' => type, 'tag' => n['name'], 'server' => n['server'], 'server_port' => n['port'] }
      supported = %w[name type server port udp tfo]
      tls_enabled = %w[anytls trojan hysteria2 tuic].include?(n['type']) || n['tls'] == true
      supported += %w[sni servername tls skip-cert-verify alpn client-fingerprint] if tls_enabled
      supported << 'tls' if %w[vmess vless].include?(n['type'])
      if n['tls'] == false && %w[anytls trojan hysteria2 tuic].include?(n['type'])
        raise Error, "#{n['name']}: this protocol requires TLS"
      end
      case n['type']
      when 'anytls', 'trojan', 'hysteria2'
        x['password'] = n['password']
        supported << 'password'
      when 'ss'
        x['method'], x['password'] = n['cipher'], n['password']
        supported += %w[cipher password plugin plugin-opts]
        if n['plugin']
          raise Error, "#{n['name']}: Shadowsocks plugin options require an explicit sing-box mapping"
        end
      when 'vmess', 'vless'
        x['uuid'] = n['uuid']
        supported += %w[uuid packet-encoding]
        if type == 'vmess'
          supported += %w[alterId cipher]
          x['security'] = n.fetch('cipher', 'auto')
          x['alter_id'] = n.fetch('alterId', 0)
        else
          supported << 'flow'
          x['flow'] = n['flow'] if n['flow']
        end
        x['packet_encoding'] = n['packet-encoding'] if n['packet-encoding']
      when 'tuic'
        raise Error, "#{n['name']}: sing-box supports TUIC v5 only, not token/v4" if n['token']
        x['uuid'], x['password'] = n['uuid'], n['password']
        supported += %w[uuid password congestion-controller udp-relay-mode reduce-rtt heartbeat-interval]
        { 'congestion-controller' => 'congestion_control', 'udp-relay-mode' => 'udp_relay_mode', 'reduce-rtt' => 'zero_rtt_handshake' }.each { |a, b| x[b] = n[a] if n.key?(a) }
        x['heartbeat'] = "#{n['heartbeat-interval']}ms" if n['heartbeat-interval']
      end
      if n['type'] == 'anytls'
        supported += %w[idle-session-check-interval idle-session-timeout min-idle-session]
        %w[idle-session-check-interval idle-session-timeout].each { |k| x[k.tr('-', '_')] = "#{n[k]}s" if n[k] }
        x['min_idle_session'] = n['min-idle-session'] if n['min-idle-session']
      end
      if n['type'] == 'hysteria2'
        supported += %w[up down obfs obfs-password]
        x['up_mbps'] = bandwidth(n['up']) if n['up']
        x['down_mbps'] = bandwidth(n['down']) if n['down']
        if n['obfs']
          raise Error, "#{n['name']}: unsupported Hysteria2 obfuscation" unless n['obfs'] == 'salamander' && n['obfs-password'].is_a?(String)
          x['obfs'] = { 'type' => n['obfs'], 'password' => n['obfs-password'] }
        end
      end
      if tls_enabled
        tls = { 'enabled' => true }
        tls['server_name'] = n['sni'] || n['servername'] if n['sni'] || n['servername']
        tls['insecure'] = n['skip-cert-verify'] if n.key?('skip-cert-verify')
        tls['alpn'] = n['alpn'] if n['alpn']
        tls['utls'] = { 'enabled' => true, 'fingerprint' => n['client-fingerprint'] } if n['client-fingerprint']
        if n['reality-opts']
          raise Error, "#{n['name']}: Reality requires VLESS or VMess" unless %w[vless vmess].include?(n['type'])
          reality = n['reality-opts']
          raise Error, "#{n['name']}: invalid Reality options" unless reality.is_a?(Hash) && (reality.keys - %w[public-key short-id]).empty? && reality['public-key']
          tls['reality'] = { 'enabled' => true, 'public_key' => reality['public-key'], 'short_id' => reality.fetch('short-id', '') }
          supported << 'reality-opts'
        end
        x['tls'] = tls
      end
      supported << 'network'
      if n['network'] && n['network'] != 'tcp'
        network = n['network']
        raise Error, "#{n['name']}: unsupported sing-box transport #{network}" unless %w[ws grpc http h2].include?(network) && %w[vmess vless trojan].include?(n['type'])
        transport = { 'type' => (network == 'h2' ? 'http' : network) }
        if network == 'ws'
          supported << 'ws-opts'
          opts = n.fetch('ws-opts', {})
          raise Error, "#{n['name']}: unsupported WebSocket options" unless opts.is_a?(Hash) && (opts.keys - %w[path headers max-early-data early-data-header-name]).empty?
          { 'path' => 'path', 'headers' => 'headers', 'max-early-data' => 'max_early_data', 'early-data-header-name' => 'early_data_header_name' }.each { |a, b| transport[b] = opts[a] if opts.key?(a) }
        elsif network == 'grpc'
          supported << 'grpc-opts'
          opts = n.fetch('grpc-opts', {})
          raise Error, "#{n['name']}: unsupported gRPC options" unless opts.is_a?(Hash) && (opts.keys - %w[grpc-service-name]).empty?
          transport['service_name'] = opts['grpc-service-name'] if opts['grpc-service-name']
        else
          key = network == 'h2' ? 'h2-opts' : 'http-opts'
          supported << key
          opts = n.fetch(key, {})
          raise Error, "#{n['name']}: unsupported HTTP transport options" unless opts.is_a?(Hash) && (opts.keys - %w[path host headers method]).empty?
          transport['path'] = opts['path'].is_a?(Array) ? opts['path'].first : opts['path'] if opts['path']
          raise Error, "#{n['name']}: multiple HTTP paths cannot be represented" if opts['path'].is_a?(Array) && opts['path'].length > 1
          %w[host headers method].each { |k| transport[k] = opts[k] if opts[k] }
        end
        x['transport'] = transport
      end
      raise Error, "#{n['name']}: Reality requires enabled TLS" if n['reality-opts'] && !tls_enabled
      %w[shadow-tls-opts restls-opts jls-opts dialer-proxy].each { |k| raise Error, "#{n['name']}: #{k} requires an explicit outbound mapping" if n[k] }
      x['network'] = 'tcp' if n['udp'] == false
      x['tcp_fast_open'] = n['tfo'] if n.key?('tfo')
      node_warnings(n, supported, 'singbox', warnings)
      x
    end

    def redact_content(content, c)
      secrets = []
      gather = lambda do |value|
        case value
        when Hash then value.each_value { |v| gather.call(v) }
        when Array then value.each { |v| gather.call(v) }
        when String then secrets << value unless value.empty?
        end
      end
      c[:nodes].each { |n| n[:raw].each { |key, value| gather.call(value) unless SAFE_PREVIEW_KEYS.include?(key) } }
      used_sets(c).each do |set|
        %w[mihomo_url surge_url singbox_url].each do |key|
          next unless set[key].is_a?(String)
          uri = URI.parse(set[key]) rescue nil
          secrets << set[key] if uri && (uri.query || uri.userinfo)
        end
      end
      dns = c[:profile]['mihomo_dns'] || {}
      dns.each do |key, value|
        next if %w[enable ipv6 enhanced-mode fake-ip-range fake-ip-range6 fake-ip-filter-mode fake-ip-filter respect-rules use-hosts use-system-hosts prefer-h3 direct-nameserver-follow-policy cache-algorithm].include?(key)
        gather.call(value)
      end
      native_policy = c[:profile]['mihomo_policy'] || {}
      gather.call(native_policy['hosts']) if native_policy['hosts']
      (native_policy['geox-url'] || {}).each_value do |url|
        parsed = URI.parse(url) rescue nil
        secrets << url if parsed && parsed.query
      end
      # Replace encoded forms as well; preview is deliberately not an importable config.
      secrets.uniq.sort_by { |s| -s.length }.each do |secret|
        encoded = JSON.generate(secret)[1...-1]
        content = content.gsub(encoded, '[REDACTED]') unless encoded.empty?
        content = content.gsub(secret, '[REDACTED]')
      end
      content
    end

    class << self
      private

      def decode64(value)
        (value.tr('-_', '+/') + '=' * ((4 - value.length % 4) % 4)).unpack1('m0').force_encoding(Encoding::UTF_8)
      end

      def import_uri(link)
        if link.start_with?('vmess://')
          v = JSON.parse(decode64(link.delete_prefix('vmess://')))
          allowed = %w[v ps add port id aid scy net type host path tls sni alpn fp]
          raise Error, 'VMess URI contains unsupported fields' unless (v.keys - allowed).empty?
          raise Error, 'Legacy VMess transport obfuscation is unsupported' unless [nil, '', 'none'].include?(v['type'])
          raise Error, 'VMess URI TLS mode is unsupported' unless [nil, '', 'none', 'tls'].include?(v['tls'])
          if v.fetch('net', 'tcp') == 'tcp' && (!v['path'].to_s.empty? || !v['host'].to_s.empty?)
            raise Error, 'VMess TCP URI contains options without a verified mapping'
          end
          n = { 'name' => v['ps'] || 'VMess', 'type' => 'vmess', 'server' => v['add'], 'port' => Integer(v['port']), 'uuid' => v['id'], 'alterId' => Integer(v.fetch('aid', 0)), 'cipher' => v.fetch('scy', 'auto'), 'network' => v.fetch('net', 'tcp'), 'tls' => v['tls'] == 'tls' }
          n['sni'] = v['sni'] if v['sni'] && !v['sni'].empty?
          n['client-fingerprint'] = v['fp'] if v['fp'] && !v['fp'].empty?
          n['alpn'] = v['alpn'].split(',') if v['alpn'].is_a?(String) && !v['alpn'].empty?
          if n['network'] == 'ws'
            n['ws-opts'] = { 'path' => v['path'] || '/', 'headers' => (v['host'].to_s.empty? ? {} : { 'Host' => v['host'] }) }
          elsif n['network'] != 'tcp'
            raise Error, 'VMess URI transport currently supports TCP or WebSocket'
          end
          return n
        end
        scheme, rest = link.split('://', 2)
        raise Error, 'Unsupported node link protocol' unless %w[ss trojan anytls vless hysteria2 hy2 tuic].include?(scheme)
        if scheme == 'ss'
          body, fragment = rest.split('#', 2)
          raise Error, 'Shadowsocks plugin URI requires converter import' if body.include?('?')
          body = decode64(body) unless body.include?('@')
          at = body.rindex('@')
          raise Error, 'Invalid Shadowsocks link' unless at
          auth, address = body[0...at], body[(at + 1)..-1]
          auth = decode64(auth) unless auth.include?(':')
          cipher, password = auth.split(':', 2)
          u = URI.parse('ss://' + address)
          return { 'name' => fragment ? URI.decode_www_form_component(fragment) : 'Shadowsocks', 'type' => 'ss', 'server' => u.hostname, 'port' => u.port, 'cipher' => cipher, 'password' => password, 'udp' => true }
        end
        # URI is ASCII; percent-encoded credentials and remarks are decoded separately.
        u = URI.parse(link)
        pairs = URI.decode_www_form(u.query.to_s)
        raise Error, 'Node URI contains duplicate query parameters' unless pairs.map(&:first).uniq.length == pairs.length
        q = pairs.to_h
        allowed = %w[sni peer allowInsecure insecure alpn fp tfo]
        allowed += %w[security type path host serviceName] if %w[trojan vless].include?(scheme)
        allowed += %w[flow pbk sid] if scheme == 'vless'
        allowed += %w[obfs obfs-password] if %w[hysteria2 hy2].include?(scheme)
        allowed += %w[congestion_control udp_relay_mode] if scheme == 'tuic'
        raise Error, 'Node URI contains unsupported query parameters' unless (q.keys - allowed).empty?
        %w[allowInsecure insecure tfo].each { |k| raise Error, 'Node URI boolean is invalid' if q.key?(k) && !%w[true false 1 0].include?(q[k]) }
        if scheme == 'trojan' && q['security'] && q['security'] != 'tls'
          raise Error, 'Trojan URI security mode must be TLS'
        end
        if scheme == 'vless' && !%w[none tls reality].include?(q.fetch('security', 'none'))
          raise Error, 'VLESS URI security mode is unsupported'
        end
        if q['type'].nil? || q['type'] == 'tcp'
          raise Error, 'TCP URI contains transport options without a verified mapping' if q.keys.any? { |k| %w[path host serviceName].include?(k) }
        end
        if scheme == 'vless' && q['security'] != 'reality' && (q.key?('pbk') || q.key?('sid'))
          raise Error, 'Reality URI options require security=reality'
        end
        n = { 'name' => u.fragment ? URI.decode_www_form_component(u.fragment) : scheme, 'type' => scheme == 'hy2' ? 'hysteria2' : scheme, 'server' => u.hostname, 'port' => u.port || 443, 'udp' => true }
        if scheme == 'vless'
          n['uuid'] = URI.decode_www_form_component(u.userinfo.to_s)
          n['tls'] = %w[tls reality].include?(q.fetch('security', 'none'))
          n['flow'] = q['flow'] if q['flow']
          n['reality-opts'] = { 'public-key' => q['pbk'], 'short-id' => q.fetch('sid', '') } if q['security'] == 'reality'
        elsif scheme == 'tuic'
          n['uuid'], n['password'] = u.userinfo.to_s.split(':', 2).map { |v| URI.decode_www_form_component(v) }
          n['congestion-controller'] = q['congestion_control'] if q['congestion_control']
          n['udp-relay-mode'] = q['udp_relay_mode'] if q['udp_relay_mode']
        else
          n['password'] = URI.decode_www_form_component(u.userinfo.to_s)
        end
        n['sni'] = q['sni'] || q['peer'] if q['sni'] || q['peer']
        n['skip-cert-verify'] = %w[1 true].include?(q['allowInsecure'] || q['insecure']) if q['allowInsecure'] || q['insecure']
        n['tfo'] = %w[1 true].include?(q['tfo']) if q['tfo']
        n['alpn'] = q['alpn'].split(',') if q['alpn']
        n['client-fingerprint'] = q['fp'] if q['fp']
        raise Error, 'URI obfuscation password needs an obfuscation type' if q['obfs-password'] && !q['obfs']
        n['obfs'], n['obfs-password'] = q['obfs'], q['obfs-password'] if q['obfs']
        if q['type'] && q['type'] != 'tcp'
          n['network'] = q['type']
          case q['type']
          when 'ws' then n['ws-opts'] = { 'path' => q.fetch('path', '/'), 'headers' => q['host'] ? { 'Host' => q['host'] } : {} }
          when 'grpc' then n['grpc-opts'] = { 'grpc-service-name' => q.fetch('serviceName', '') }
          else raise Error, 'Node URI transport is unsupported'
          end
        end
        n
      end

      def split_surge_fields(value)
        fields, current, quoted, escaped = [], String.new, false, false
        value.each_char do |char|
          if char == ',' && !quoted
            fields << current.strip
            current = String.new
            next
          end
          current << char
          if escaped
            escaped = false
          elsif char == '\\' && quoted
            escaped = true
          elsif char == '"'
            quoted = !quoted
          end
        end
        raise Error, 'Unterminated quoted Surge field' if quoted || escaped
        fields << current.strip
        fields
      end

      def import_surge(text)
        section, nodes = '', []
        text.lines.each do |line|
          line = line.strip
          next if line.empty? || line.start_with?('#', ';', '//')
          if line.match?(/\A\[[^\]]+\]\z/)
            section = line.downcase
            next
          end
          next unless section == '[proxy]'
          name, value = line.split('=', 2).map { |v| v && v.strip }
          raise Error, 'Invalid Surge proxy definition' unless value
          fields = split_surge_fields(value)
          next if %w[direct reject reject-drop].include?(fields[0])
          type = fields.shift
          raise Error, 'Surge source contains an unsupported protocol' unless %w[anytls trojan ss vmess hysteria2 tuic tuic-v5].include?(type)
          n = { 'name' => name, 'type' => type == 'tuic-v5' ? 'tuic' : type, 'server' => fields.shift, 'port' => Integer(fields.shift) }
          fields.each do |field|
            key, val = field.split('=', 2).map { |v| v && v.strip }
            raise Error, 'Invalid Surge proxy option' unless val
            val = JSON.parse(val) if val.start_with?('"')
            case key
            when 'password', 'sni', 'token', 'uuid' then n[key] = val
            when 'username' then raise Error, 'Surge username is only supported for VMess' unless type == 'vmess'; n['uuid'] = val
            when 'encrypt-method' then n['cipher'] = val
            when 'tls', 'tfo', 'skip-cert-verify', 'udp-relay' then raise Error, 'Invalid Surge boolean' unless %w[true false].include?(val); n[key == 'udp-relay' ? 'udp' : key] = val == 'true'
            when 'vmess-aead' then raise Error, 'Legacy VMess is not supported' unless val == 'true'; n['alterId'] = 0
            when 'alpn' then n['alpn'] = val.split(',')
            when 'download-bandwidth' then n['down'] = val
            when 'salamander-password' then n['obfs'], n['obfs-password'] = 'salamander', val
            when 'ws' then raise Error, 'Invalid Surge ws option' unless %w[true false].include?(val); n['network'] = val == 'true' ? 'ws' : 'tcp'
            when 'ws-path' then (n['ws-opts'] ||= {})['path'] = val
            when 'ws-headers'
              headers = val.split('|').map { |h| h.split(':', 2) }
              raise Error, 'Invalid Surge WebSocket headers' unless headers.all? { |h| h.length == 2 }
              (n['ws-opts'] ||= {})['headers'] = headers.to_h
            else raise Error, "Surge source option #{key} has no verified import mapping"
            end
          end
          nodes << n
        end
        nodes
      end

      def import_singbox(n)
        raise Error, 'Invalid sing-box outbound' unless n.is_a?(Hash)
        raw_type = n['type']
        type = raw_type == 'shadowsocks' ? 'ss' : raw_type
        raise Error, 'Unsupported sing-box source protocol' unless PROTOCOLS.include?(type)
        supported = %w[type tag server server_port password uuid method security alter_id flow packet_encoding network tcp_fast_open tls transport up_mbps down_mbps obfs congestion_control udp_relay_mode zero_rtt_handshake idle_session_check_interval idle_session_timeout min_idle_session]
        raise Error, 'sing-box outbound contains options without a lossless import mapping' unless (n.keys - supported).empty?
        x = { 'name' => n['tag'], 'type' => type, 'server' => n['server'], 'port' => n['server_port'] }
        { 'password' => 'password', 'uuid' => 'uuid', 'method' => 'cipher', 'security' => 'cipher', 'alter_id' => 'alterId', 'flow' => 'flow', 'packet_encoding' => 'packet-encoding', 'tcp_fast_open' => 'tfo', 'up_mbps' => 'up', 'down_mbps' => 'down', 'congestion_control' => 'congestion-controller', 'udp_relay_mode' => 'udp-relay-mode', 'zero_rtt_handshake' => 'reduce-rtt', 'min_idle_session' => 'min-idle-session' }.each { |a, b| x[b] = n[a] if n.key?(a) }
        if n['network']
          raise Error, 'sing-box node network must be tcp or udp' unless %w[tcp udp].include?(n['network'])
          raise Error, 'UDP-only sing-box nodes cannot be losslessly imported' if n['network'] == 'udp'
          x['udp'] = false
        end
        %w[idle_session_check_interval idle_session_timeout].each do |k|
          next unless n[k]
          raise Error, 'AnyTLS duration must be whole seconds' unless n[k].to_s.match?(/\A\d+s\z/)
          x[k.tr('_', '-')] = n[k].to_i
        end
        if n['obfs']
          raise Error, 'Unsupported sing-box obfuscation' unless n['obfs'].is_a?(Hash) && (n['obfs'].keys - %w[type password]).empty?
          x['obfs'], x['obfs-password'] = n['obfs']['type'], n['obfs']['password']
        end
        if n['tls']
          tls = n['tls']
          raise Error, 'Unsupported sing-box TLS options' unless tls.is_a?(Hash) && (tls.keys - %w[enabled server_name insecure alpn utls reality]).empty?
          raise Error, 'This proxy protocol requires TLS; disabled TLS cannot be imported' if tls['enabled'] == false && %w[anytls trojan tuic hysteria2].include?(type)
          x['tls'] = tls.fetch('enabled', true) if %w[vmess vless].include?(type)
          x['sni'] = tls['server_name'] if tls['server_name']
          x['skip-cert-verify'] = tls['insecure'] if tls.key?('insecure')
          x['alpn'] = tls['alpn'] if tls['alpn']
          if tls['utls']
            u = tls['utls']
            raise Error, 'Unsupported sing-box uTLS options' unless u.is_a?(Hash) && (u.keys - %w[enabled fingerprint]).empty?
            x['client-fingerprint'] = u['fingerprint'] if u['enabled']
          end
          if tls['reality']
            r = tls['reality']
            raise Error, 'Unsupported sing-box Reality options' unless r.is_a?(Hash) && (r.keys - %w[enabled public_key short_id]).empty?
            x['reality-opts'] = { 'public-key' => r['public_key'], 'short-id' => r.fetch('short_id', '') } if r['enabled']
          end
        end
        if n['transport']
          t = n['transport']
          raise Error, 'Unsupported sing-box transport import' unless t.is_a?(Hash) && %w[ws grpc].include?(t['type'])
          x['network'] = t['type']
          if t['type'] == 'ws'
            raise Error, 'Unsupported sing-box WebSocket fields' unless (t.keys - %w[type path headers max_early_data early_data_header_name]).empty?
            x['ws-opts'] = {}
            { 'path' => 'path', 'headers' => 'headers', 'max_early_data' => 'max-early-data', 'early_data_header_name' => 'early-data-header-name' }.each { |a, b| x['ws-opts'][b] = t[a] if t.key?(a) }
          else
            raise Error, 'Unsupported sing-box gRPC fields' unless (t.keys - %w[type service_name]).empty?
            x['grpc-opts'] = { 'grpc-service-name' => t.fetch('service_name', '') }
          end
        end
        x
      end
    end
  end
end
