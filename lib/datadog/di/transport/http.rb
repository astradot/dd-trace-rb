# frozen_string_literal: true

require 'uri'

require_relative '../../core/environment/container'
require_relative '../../core/environment/ext'
require_relative '../../core/transport/ext'
require_relative 'diagnostics'
require_relative 'input'
require_relative 'http/api'
require_relative '../../core/transport/http'
require_relative '../../../datadog/version'

module Datadog
  module DI
    module Transport
      # Namespace for HTTP transport components
      module HTTP
        module_function

        # Builds a new Transport::HTTP::Client
        def new(klass, &block)
          Core::Transport::HTTP.build(
            api_instance_class: API::Instance, &block
          ).to_transport(klass)
        end

        # Builds a new Transport::HTTP::Client with default settings
        # Pass a block to override any settings.
        def diagnostics(
          agent_settings:,
          **options
        )
          new(DI::Transport::Diagnostics::Transport) do |transport|
            transport.adapter(agent_settings)
            transport.headers default_headers

            apis = API.defaults

            transport.api API::DIAGNOSTICS, apis[API::DIAGNOSTICS]

            # Apply any settings given by options
            unless options.empty?
              transport.default_api = options[:api_version] if options.key?(:api_version)
              transport.headers options[:headers] if options.key?(:headers)
            end

            # Call block to apply any customization, if provided
            yield(transport) if block_given?
          end
        end

        # Builds a new Transport::HTTP::Client with default settings
        # Pass a block to override any settings.
        def input(
          agent_settings:,
          **options
        )
          new(DI::Transport::Input::Transport) do |transport|
            transport.adapter(agent_settings)
            transport.headers default_headers

            apis = API.defaults

            transport.api API::INPUT, apis[API::INPUT]

            # Apply any settings given by options
            unless options.empty?
              transport.default_api = options[:api_version] if options.key?(:api_version)
              transport.headers options[:headers] if options.key?(:headers)
            end

            # Call block to apply any customization, if provided
            yield(transport) if block_given?
          end
        end

        def default_headers
          {
            Datadog::Core::Transport::Ext::HTTP::HEADER_CLIENT_COMPUTED_TOP_LEVEL => '1',
            Datadog::Core::Transport::Ext::HTTP::HEADER_META_LANG => Datadog::Core::Environment::Ext::LANG,
            Datadog::Core::Transport::Ext::HTTP::HEADER_META_LANG_VERSION => Datadog::Core::Environment::Ext::LANG_VERSION,
            Datadog::Core::Transport::Ext::HTTP::HEADER_META_LANG_INTERPRETER =>
              Datadog::Core::Environment::Ext::LANG_INTERPRETER,
            Datadog::Core::Transport::Ext::HTTP::HEADER_META_LANG_INTERPRETER_VENDOR => Core::Environment::Ext::LANG_ENGINE,
            Datadog::Core::Transport::Ext::HTTP::HEADER_META_TRACER_VERSION =>
              Datadog::Core::Environment::Ext::GEM_DATADOG_VERSION
          }.tap do |headers|
            # Add container ID, if present.
            container_id = Datadog::Core::Environment::Container.container_id
            headers[Datadog::Core::Transport::Ext::HTTP::HEADER_CONTAINER_ID] = container_id unless container_id.nil?
            # Pretend that stats computation are already done by the client
            if Datadog.configuration.appsec.standalone.enabled
              headers[Datadog::Core::Transport::Ext::HTTP::HEADER_CLIENT_COMPUTED_STATS] = 'yes'
            end
          end
        end

        def default_adapter
          Datadog::Core::Configuration::Ext::Agent::HTTP::ADAPTER
        end
      end
    end
  end
end
