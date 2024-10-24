# frozen_string_literal: true

require_relative '../../../instrumentation/gateway'
require_relative '../../../reactive/operation'
require_relative '../../rack/reactive/request_body'
require_relative '../reactive/routed'
require_relative '../../../event'

module Datadog
  module AppSec
    module Contrib
      module Sinatra
        module Gateway
          # Watcher for Sinatra gateway events
          module Watcher
            class << self
              def watch
                gateway = Instrumentation.gateway

                watch_request_dispatch(gateway)
                watch_request_routed(gateway)
              end

              def watch_request_dispatch(gateway = Instrumentation.gateway)
                gateway.watch('sinatra.request.dispatch', :appsec) do |stack, gateway_request|
                  block = false

                  event = nil
                  scope = gateway_request.env[Datadog::AppSec::Ext::SCOPE_KEY]

                  AppSec::Reactive::Operation.new('sinatra.request.dispatch') do |op|
                    Rack::Reactive::RequestBody.subscribe(op, scope.processor_context) do |result|
                      if result.status == :match
                        # TODO: should this hash be an Event instance instead?
                        event = {
                          waf_result: result,
                          trace: scope.trace,
                          span: scope.service_entry_span,
                          request: gateway_request,
                          actions: result.actions
                        }

                        # We want to keep the trace in case of security event
                        scope.trace.keep! if scope.trace
                        Datadog::AppSec::Event.tag_and_keep!(scope, result)
                        scope.processor_context.events << event
                      end
                    end

                    block = Rack::Reactive::RequestBody.publish(op, gateway_request)
                  end

                  next [nil, [[:block, event]]] if block

                  ret, res = stack.call(gateway_request.request)

                  if event
                    res ||= []
                    res << [:monitor, event]
                  end

                  [ret, res]
                end
              end

              def watch_request_routed(gateway = Instrumentation.gateway)
                gateway.watch('sinatra.request.routed', :appsec) do |stack, (gateway_request, gateway_route_params)|
                  block = false

                  event = nil
                  scope = gateway_request.env[Datadog::AppSec::Ext::SCOPE_KEY]

                  AppSec::Reactive::Operation.new('sinatra.request.routed') do |op|
                    Sinatra::Reactive::Routed.subscribe(op, scope.processor_context) do |result|
                      if result.status == :match
                        # TODO: should this hash be an Event instance instead?
                        event = {
                          waf_result: result,
                          trace: scope.trace,
                          span: scope.service_entry_span,
                          request: gateway_request,
                          actions: result.actions
                        }

                        # We want to keep the trace in case of security event
                        scope.trace.keep! if scope.trace
                        Datadog::AppSec::Event.tag_and_keep!(scope, result)
                        scope.processor_context.events << event
                      end
                    end

                    block = Sinatra::Reactive::Routed.publish(op, [gateway_request, gateway_route_params])
                  end

                  next [nil, [[:block, event]]] if block

                  ret, res = stack.call(gateway_request.request)

                  if event
                    res ||= []
                    res << [:monitor, event]
                  end

                  [ret, res]
                end
              end
            end
          end
        end
      end
    end
  end
end
