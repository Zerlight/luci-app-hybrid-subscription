# frozen_string_literal: true
require 'json'
require 'yaml'
require 'uri'

module HybridSubscription
  # Quota snapshots never update proxy providers or import a subscription body.
  class Quota
    KEYS = %w[upload download total expire].freeze
    MAX_HEADERS = 65_536
    def initialize(root = '/', command:)
      @root, @command = root, command
    end

    def self.parse(headers)
      return nil unless headers.is_a?(String) && headers.bytesize <= MAX_HEADERS
      # A proxy CONNECT or informational response must not supply the final quota.
      blocks = headers.split(/(?=^HTTP\/\S+\s+\d{3})/)
      final = blocks.reverse.find { |block| block.match?(/\AHTTP\/\S+\s+\d{3}/) } || headers
      return nil if final.match?(/\AHTTP\/\S+\s+(?!2\d\d)\d{3}/)
      line = final.lines.reverse.find { |value| value.match?(/\Asubscription-userinfo\s*:/i) }
      return nil unless line
      values = line.split(':', 2).last.split(';').each_with_object({}) do |item, result|
        key, value = item.strip.split('=', 2)
        key, value = key.to_s.strip.downcase, value.to_s.strip
        result[key] = Integer(value,10) if KEYS.include?(key) && value.match?(/\A\d{1,19}\z/)
      end
      values.empty? ? nil : values
    end

    def self.normalized(value)
      return nil unless value.is_a?(Hash)
      result = value.each_with_object({}) do |(key, number), out|
        key = key.to_s.downcase
        out[key] = number if KEYS.include?(key) && number.is_a?(Integer) && number >= 0
      end
      result.empty? ? nil : result
    end

    def self.timestamp(value)
      parts = value.to_s.match(/\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)\z/)
      parts ? Time.new(*parts.captures.first(6).map(&:to_i), parts[7]=='Z' ? '+00:00' : parts[7]).to_i : 0
    rescue ArgumentError
      0
    end

    def local_states(sources)
      return {} unless File.file?(file('/etc/config/openclash'))
      data = JSON.parse(@command.call(['/bin/ubus', 'call', 'uci', 'get', '{"config":"openclash"}'], seconds: 3))
      settings = data.fetch('values', {}).fetch('config', {})
      active = settings['config_path'].to_s
      return {} unless active.match?(%r{\A/etc/openclash/config/[^/\x00]+\.ya?ml\z})
      source = read_yaml(file(active))
      providers = source.fetch('proxy-providers', {})
      return {} unless providers.is_a?(Hash)
      matches = sources.each_with_object({}) do |s, out|
        next if s['url'].to_s.empty?
        out[s['id']] = providers.select { |_name, p| p.is_a?(Hash) && p['type'] == 'http' && p['url'] == s['url'] }.keys
      end
      return {} unless matches.values.any? { |names| !names.empty? }
      runtime = read_yaml(file('/etc/openclash/' + File.basename(active)))
      secret = runtime['secret'].to_s
      port = settings['cn_port'].to_s
      return {} unless port.match?(/\A\d{1,5}\z/) && port.to_i.between?(1, 65_535) && !secret.match?(/[[:cntrl:]]/)
      escaped = secret.gsub(/[\\"]/) { |char| "\\#{char}" }
      headers = "header = \"Authorization: Bearer #{escaped}\"\n"
      response = @command.call(['curl', '--disable', '--noproxy', '*', '--silent', '--fail', '--no-location', '--max-time', '2', '--config', '-', "http://127.0.0.1:#{port}/providers/proxies"], seconds: 3, input: headers)
      cached = JSON.parse(response).fetch('providers', {})
      matches.each_with_object({}) do |(id, names), result|
        snapshots = names.map do |name|
          provider = cached[name]
          next unless provider.is_a?(Hash)
          values = self.class.normalized(provider['subscriptionInfo'])
          # Mihomo's fixed int64 struct serializes absent fields as zero too.
          # Only a raw response header can prove an explicit zero/unlimited value.
          values = values.reject { |_key, value| value.zero? } if values
          next if !values || values.empty?
          stamp = provider['updatedAt']
          { 'quota' => values, 'updated_at' => self.class.timestamp(stamp) > 0 ? stamp : nil, 'origin' => 'openclash_cache' }
        end.compact
        result[id] = snapshots.max_by { |entry| self.class.timestamp(entry['updated_at']) } unless snapshots.empty?
      end
    rescue StandardError
      # No local provider state is different from an unknown or fabricated quota.
      {}
    end

    # OpenClash subscribe_info is explicit configuration, not a universal API.
    # Ambiguous multi-provider entries are intentionally left for the user to map.
    def configured_urls(sources)
      return {} unless File.file?(file('/etc/config/openclash'))
      data = JSON.parse(@command.call(['/bin/ubus','call','uci','get','{"config":"openclash"}'],seconds:3)).fetch('values',{})
      names = sources.map do |source|
        old = data[source['openclash_section']]
        (old.is_a?(Hash) && old['.type']=='config_subscribe' ? old['name'] : source['name']).to_s.sub(/\.ya?ml\z/,'')
      end
      sources.each_with_index.each_with_object({}) do |(source,index), result|
        name = names[index]
        next if name.empty? || names.count(name) != 1
        rows = data.values.select { |item| item.is_a?(Hash) && item['.type']=='subscribe_info' && item['name'].to_s.sub(/\.ya?ml\z/,'')==name }
        next unless rows.length == 1
        urls = Array(rows.first['url']).flat_map { |value| value.to_s.lines.map(&:strip) }.reject(&:empty?)
        next unless urls.length == 1 && !urls.first.match?(/[\x00-\x20\x7f]/)
        begin
          url = URI.parse(urls.first)
          next unless %w[http https].include?(url.scheme) && url.host && !url.userinfo
          url.fragment = nil
          subscription = URI.parse(source['url'].to_s); subscription.fragment=nil
          next if url.normalize.to_s == subscription.normalize.to_s
          result[source['id']] = url.to_s
        rescue URI::InvalidURIError
          next
        end
      end
    rescue StandardError
      {}
    end

    private

    def file(name)
      File.join(@root, name.sub(%r{\A/+}, ''))
    end

    def read_yaml(filename)
      base = File.realpath(file('/etc/openclash'))
      return {} unless File.file?(filename) && File.size(filename) <= 4 * 1024 * 1024 && File.realpath(filename).start_with?(base + '/')
      value = YAML.safe_load(File.read(filename), permitted_classes: [], permitted_symbols: [], aliases: true)
      value.is_a?(Hash) ? value : {}
    end
  end
end
