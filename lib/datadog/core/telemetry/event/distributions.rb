# frozen_string_literal: true

require_relative 'generate_metrics'

module Datadog
  module Core
    module Telemetry
      class Event
        # Telemetry class for the 'distributions' event
        class Distributions < GenerateMetrics
          def type
            'distributions'
          end
        end
      end
    end
  end
end
