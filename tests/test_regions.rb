# frozen_string_literal: true
require 'minitest/autorun'
require_relative '../root/usr/share/hybrid-subscription/regions'

class RegionsTest < Minitest::Test
  Regions = HybridSubscription::Regions
  Error = HybridSubscription::Error

  def setup
    @definitions = Regions.defaults
    @regions = Regions.new(@definitions, source_ids: %w[source-a source-b])
  end

  def test_default_aliases_match_flags_chinese_and_bounded_codes
    ['🇯🇵 Premium', '日本节点', '日本01', '[A]JP 01', 'JP-01', 'JP01', 'JPN 01', 'jpn.01', 'Japan 01'].each do |name|
      assert @regions.match?('jp', 'source-a', name), name
    end
    ['VIPJPN', 'MyJPServer', 'Japanology', 'AirJapan', 'JPG image', 'PJPN', 'Hong Kong'].each do |name|
      refute @regions.match?('jp', 'source-a', name), name
    end
    assert @regions.match?('tw', 'source-a', '🇹🇼 01')
    assert @regions.match?('tw', 'source-a', '臺灣01')
    assert @regions.match?('us', 'source-b', 'USA 01')
    refute @regions.match?('us', 'source-b', 'AUS 01')
    assert @regions.match?('au', 'source-b', 'AUS 01')
    refute @regions.match?('in', 'source-b', 'Main 01')
    refute @regions.match?('ca', 'source-b', 'Local 01')
  end

  def test_source_override_replaces_global_pattern_for_that_source_only
    @definitions.find { |r| r['id'] == 'jp' }['source_patterns'] = { 'source-a' => '^Tokyo-[0-9]+$' }
    regions = Regions.new(@definitions, source_ids: %w[source-a source-b])
    assert regions.match?('jp', 'source-a', 'Tokyo-01')
    refute regions.match?('jp', 'source-a', 'JP 01')
    assert regions.match?('jp', 'source-b', 'JP 01')
    refute regions.match?('jp', 'source-b', 'Tokyo-01')
  end

  def test_template_returns_independent_editable_values
    @definitions.first['name'].replace('Custom')
    @definitions.first['source_patterns']['source-a'] = 'custom'
    @definitions.first['pattern'].replace('custom')
    refute_equal 'Custom', Regions.defaults.first['name']
    assert_equal({}, Regions.defaults.first['source_patterns'])
    assert Regions.validate!(Regions.defaults, source_ids: [])
  end

  def test_preview_contains_only_names_and_matches_and_keeps_ambiguity_visible
    names = ['JP 01', '香港 02', 'JP-US relay', 'Unknown 01']
    preview = @regions.preview('source-a', names)
    assert_equal names, preview.map { |r| r['name'] }
    assert_equal ['jp'], preview[0]['regions']
    assert_equal ['hk'], preview[1]['regions']
    assert_equal %w[jp us], preview[2]['regions']
    assert_equal [], preview[3]['regions']
    assert preview.all? { |r| r.keys.sort == %w[name regions] }
    error = assert_raises(Error) { @regions.preview('source-a', [{ 'name' => 'JP', 'password' => 'synthetic-secret' }]) }
    refute_includes error.message, 'synthetic-secret'
  end

  def test_empty_matching_or_malformed_patterns_are_rejected
    [nil, '', '   ', '.*', 'a*', '^', '(?:)', '[invalid', "JP\nUS", 'x' * 513].each do |pattern|
      rows = [{ 'id' => 'jp', 'name' => 'Japan', 'pattern' => pattern }]
      assert_raises(Error) { Regions.new(rows, source_ids: ['source-a']) }
    end
    @definitions.first['source_patterns'] = { 'source-a' => '' }
    assert_raises(Error) { Regions.new(@definitions, source_ids: ['source-a']) }
  end

  def test_unknown_region_source_and_invalid_definition_are_rejected
    assert_raises(Error) { @regions.match?('unknown', 'source-a', 'JP') }
    assert_raises(Error) { @regions.match?('jp', 'unknown', 'JP') }
    assert_raises(Error) { @regions.preview('unknown', ['JP']) }
    @definitions.first['source_patterns'] = { 'missing-source' => 'JP' }
    assert_raises(Error) { Regions.new(@definitions, source_ids: ['source-a']) }
    assert_raises(Error) { Regions.new([Regions.defaults.first] * 2, source_ids: []) }
    assert_raises(Error) { Regions.new([{ 'id' => '../bad', 'name' => 'Bad', 'pattern' => 'JP' }], source_ids: []) }
  end

  def test_custom_region_can_be_added_and_removed
    custom = { 'id' => 'special', 'name' => 'My pool', 'pattern' => '^Pool[0-9]+$', 'source_patterns' => {} }
    regions = Regions.new([custom], source_ids: ['source-a'])
    assert regions.include?('special')
    assert regions.match?('special', 'source-a', 'Pool12')
    refute regions.include?('jp')
    assert_equal [], Regions.new([], source_ids: ['source-a']).preview('source-a', ['JP']).first['regions']
  end
end
