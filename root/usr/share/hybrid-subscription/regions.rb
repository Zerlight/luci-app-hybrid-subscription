# frozen_string_literal: true

module HybridSubscription
  class Error < StandardError; end unless const_defined?(:Error)

  # Only node names enter this matcher; provider credentials never enter previews.
  class Regions
    ID = /\A[a-z][a-z0-9_-]{0,47}\z/
    MAX_REGIONS = 128
    MAX_PATTERN = 512
    DEFAULTS = [
      ['jp', 'Japan', '🇯🇵|日本', 'JP|JPN|Japan'],
      ['hk', 'Hong Kong', '🇭🇰|香港', 'HK|HKG|Hong[ -]?Kong'],
      ['tw', 'Taiwan', '🇹🇼|台湾|臺灣|台灣', 'TW|TWN|Taiwan'],
      ['sg', 'Singapore', '🇸🇬|新加坡|狮城|獅城', 'SG|SGP|Singapore'],
      ['us', 'United States', '🇺🇸|美国|美國', 'US|USA|United[ -]States'],
      ['kr', 'South Korea', '🇰🇷|韩国|韓國', 'KR|KOR|Korea|South[ -]Korea'],
      ['gb', 'United Kingdom', '🇬🇧|英国|英國', 'GB|GBR|UK|United[ -]Kingdom|Great[ -]Britain'],
      ['de', 'Germany', '🇩🇪|德国|德國', 'DE|DEU|Germany|Deutschland'],
      ['ca', 'Canada', '🇨🇦|加拿大', 'CA|CAN|Canada'],
      ['au', 'Australia', '🇦🇺|澳大利亚|澳大利亞|澳洲', 'AU|AUS|Australia'],
      ['fr', 'France', '🇫🇷|法国|法國', 'FR|FRA|France'],
      ['nl', 'Netherlands', '🇳🇱|荷兰|荷蘭', 'NL|NLD|Netherlands'],
      ['in', 'India', '🇮🇳|印度', 'IN|IND|India'],
      ['ar', 'Argentina', '🇦🇷|阿根廷', 'AR|ARG|Argentina'],
      ['br', 'Brazil', '🇧🇷|巴西', 'BR|BRA|Brazil'],
      ['ru', 'Russia', '🇷🇺|俄罗斯|俄羅斯', 'RU|RUS|Russia'],
      ['tr', 'Türkiye', '🇹🇷|土耳其', 'TR|TUR|Turkey|Turkiye']
    ].map { |row| row.map(&:freeze).freeze }.freeze

    def self.defaults
      DEFAULTS.map do |id, name, symbols, words|
        { 'id' => id.dup, 'name' => name.dup,
          'pattern' => "(?:#{symbols}|(?<![A-Za-z])(?i:#{words})(?![A-Za-z]))".dup,
          'source_patterns' => {} }
      end
    end

    def self.validate!(regions, source_ids:)
      new(regions, source_ids: source_ids)
      true
    end

    def initialize(regions, source_ids:)
      unless source_ids.is_a?(Array) && source_ids.all? { |id| id.is_a?(String) && ID.match?(id) } && source_ids.uniq == source_ids
        raise Error, 'Region matching needs valid, unique source IDs'
      end
      unless regions.is_a?(Array) && regions.length <= MAX_REGIONS && regions.all? { |r| r.is_a?(Hash) }
        raise Error, 'Regions must be a list of at most 128 objects'
      end
      @source_ids = source_ids.dup.freeze
      @regions = {}
      regions.each do |region|
        id = region['id']
        raise Error, 'Region has an invalid ID' unless id.is_a?(String) && ID.match?(id)
        raise Error, "Duplicate region ID #{id}" if @regions.key?(id)
        name = region['name']
        unless name.is_a?(String) && !name.strip.empty? && name.length <= 256 && !name.match?(/[\x00-\x1f\x7f]/)
          raise Error, "Region #{id}: invalid name"
        end
        raise Error, "Region #{id}: unsupported fields" unless (region.keys - %w[id name pattern source_patterns]).empty?
        pattern = compile(region['pattern'], "Region #{id}")
        overrides = region.fetch('source_patterns', {})
        unless overrides.is_a?(Hash) && overrides.keys.all? { |source| @source_ids.include?(source) }
          raise Error, "Region #{id}: source overrides must refer to existing source IDs"
        end
        compiled = overrides.each_with_object({}) { |(source, value), out| out[source] = compile(value, "Region #{id}, source #{source}") }
        @regions[id] = { pattern: pattern, source_patterns: compiled }
      end
    end

    def include?(region_id)
      @regions.key?(region_id)
    end

    def match?(region_id, source_id, name)
      region = @regions[region_id] || (raise Error, "Unknown region #{region_id}")
      validate_source!(source_id)
      validate_name!(name)
      match_name(region, source_id, name)
    end

    def preview(source_id, names)
      validate_source!(source_id)
      unless names.is_a?(Array) && names.length <= 4096
        raise Error, 'Region preview needs at most 4096 node names'
      end
      names.map do |name|
        validate_name!(name)
        matches = @regions.select { |_id, region| match_name(region, source_id, name) }.keys
        { 'name' => name, 'regions' => matches }
      end
    end

    private

    def compile(value, label)
      unless value.is_a?(String) && !value.strip.empty? && value.length <= MAX_PATTERN && !value.match?(/[\r\n\x00]/)
        raise Error, "#{label}: pattern must contain 1–512 characters without line breaks"
      end
      pattern = Regexp.respond_to?(:timeout=) ? Regexp.new(value.dup, timeout: 0.05) : Regexp.new(value.dup)
      raise Error, "#{label}: pattern must not match an empty name" if pattern.match?('')
      pattern
    rescue RegexpError
      raise Error, "#{label}: invalid regular expression"
    end

    def validate_source!(source_id)
      raise Error, "Unknown source #{source_id} for region matching" unless @source_ids.include?(source_id)
    end

    def validate_name!(name)
      unless name.is_a?(String) && !name.empty? && name.length <= 256 && !name.match?(/[\x00-\x1f\x7f]/)
        raise Error, 'Region matching accepts only valid node names'
      end
    end

    def match_name(region, source_id, name)
      (region[:source_patterns][source_id] || region[:pattern]).match?(name)
    rescue StandardError => error
      raise unless error.class.name == 'Regexp::TimeoutError'
      raise Error, 'Region regular expression exceeded its time limit'
    end
  end
end
