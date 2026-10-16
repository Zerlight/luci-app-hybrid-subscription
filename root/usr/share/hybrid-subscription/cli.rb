#!/usr/bin/ruby
# frozen_string_literal: true
require_relative 'backend'
METHODS = {
 'status'=>{}, 'get_config'=>{}, 'save_config'=>{'config'=>'','version'=>''},
 'refresh'=>{'source'=>''}, 'refresh_quota'=>{'source'=>''}, 'compare_converter'=>{'source'=>''}, 'import_source'=>{'source'=>'','content'=>''},
 'region_defaults'=>{}, 'preview_regions'=>{'config'=>'','sources'=>[]},
 'import_openclash'=>{}, 'validate'=>{'profile'=>''}, 'preview'=>{'profile'=>'','format'=>''},
 'compatibility'=>{'profile'=>'','review'=>false},
 'compatibility_plan'=>{'profile'=>'','format'=>'','id'=>'','name'=>'','resolutions'=>'','operation'=>''},
 'compatibility_create'=>{'profile'=>'','format'=>'','id'=>'','name'=>'','resolutions'=>'','version'=>'','plan_token'=>'','accepted_changes'=>[]},
 'compatibility_update'=>{'profile'=>'','format'=>'','id'=>'','name'=>'','resolutions'=>'','version'=>'','plan_token'=>'','accepted_changes'=>[]},
 'build'=>{'profile'=>''}, 'publish'=>{'release'=>'','accepted_warnings'=>[]},
 'rollback'=>{'release'=>''}, 'download_info'=>{'profile'=>''},
 'rotate_token'=>{'profile'=>''}, 'unpublish'=>{'profile'=>''}, 'apply_openclash'=>{'profile'=>''}, 'job_status'=>{'job'=>''}
}.freeze
begin
 case ARGV[0]
 when 'list'
  puts JSON.generate(METHODS)
 when 'call'
  raise HybridSubscription::Error,'Unknown operation' unless METHODS.key?(ARGV[1])
  input=STDIN.read(HybridSubscription::Backend::MAX_BYTES+65536)
  args=input.empty? ? {} : JSON.parse(input)
  result=HybridSubscription::Backend.new.call(ARGV[1],args)
  puts JSON.generate(result)
 when 'job'
  HybridSubscription::Backend.new(ARGV[2],ARGV[3]).run_job(ARGV[1])
 when 'tick'
  HybridSubscription::Backend.new.tick
 when 'init'
  HybridSubscription::Backend.new
 else
  raise HybridSubscription::Error,'Unknown command'
 end
rescue StandardError
 puts JSON.generate({'ok'=>false,'error'=>'Invalid request payload or backend state; please check the configuration'})
 exit 1
end
