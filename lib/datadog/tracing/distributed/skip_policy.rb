# frozen_string_literal: true

module Datadog
  module Tracing
    module Distributed
      # Helper method to decide when to skip distributed tracing
      module SkipPolicy
        module_function

        # Skips distributed tracing if disabled for this instrumentation
        # or if APM is disabled unless there is an AppSec event (from upstream distributed trace or local)
        #
        # pin_config is a Datadog::Core::Pin object, which gives the configuration of a single instance of an object
        # global_config is the config for all instances of a framework
        def skip?(pin_config: nil, global_config: nil, trace: nil)
          if ::Datadog.configuration.appsec.standalone.enabled &&
              (trace.nil? || trace.get_tag(::Datadog::AppSec::Ext::TAG_DISTRIBUTED_APPSEC_EVENT) != '1')
            return true
          end

          return !pin_config[:distributed_tracing] if pin_config && pin_config.key?(:distributed_tracing)
          return !global_config[:distributed_tracing] if global_config

          false
        end
      end
    end
  end
end
