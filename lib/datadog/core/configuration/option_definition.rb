# frozen_string_literal: true

require_relative 'option'

module Datadog
  module Core
    module Configuration
      # Represents a definition for an integration configuration option
      class OptionDefinition
        IDENTITY = ->(new_value, _old_value) { new_value }

        attr_reader \
          :default,
          :experimental_default_proc,
          :delegate_to,
          :depends_on,
          :name,
          :on_set,
          :resetter,
          :setter,
          :type

        def initialize(name, meta = {}, &block)
          @default = meta[:default]
          @experimental_default_proc = meta[:experimental_default_proc]
          @delegate_to = meta[:delegate_to]
          @depends_on = meta[:depends_on] || []
          @name = name.to_sym
          @on_set = meta[:on_set]
          @resetter = meta[:resetter]
          @setter = meta[:setter] || block || IDENTITY
          @type = meta[:type]
        end

        # Creates a new Option, bound to the context provided.
        def build(context)
          Option.new(self, context)
        end

        # Acts as DSL for building OptionDefinitions
        # @public_api
        class Builder
          class InvalidOptionError < StandardError; end

          attr_reader \
            :helpers

          def initialize(name, options = {})
            @default = nil
            @experimental_default_proc = nil
            @delegate_to = nil
            @depends_on = []
            @helpers = {}
            @name = name.to_sym
            @on_set = nil
            @resetter = nil
            @setter = OptionDefinition::IDENTITY
            @type = nil

            # If options were supplied, apply them.
            apply_options!(options)

            # Apply block if given.
            yield(self) if block_given?

            validate_options!
          end

          def depends_on(*values)
            @depends_on = values.flatten
          end

          def default(value = nil, &block)
            @default = block || value
          end

          def experimental_default_proc(&block)
            @experimental_default_proc = block
          end

          def delegate_to(&block)
            @delegate_to = block
          end

          def helper(name, *_args, &block)
            @helpers[name] = block
          end

          def lazy(_value = true)
            Datadog::Core.log_deprecation do
              'The `lazy` option is deprecated. You no longer need to specify an option to be lazy '\
              "when the default value is a block.\n"\
              'In the case edge case that you need the default value to be a block, please use the the expriemntal option:'\
              'experimental_default_proc'
            end
          end

          def on_set(&block)
            @on_set = block
          end

          def resetter(&block)
            @resetter = block
          end

          def setter(&block)
            @setter = block
          end

          def type(value = nil)
            @type = value
          end

          # For applying options for OptionDefinition
          def apply_options!(options = {})
            return if options.nil? || options.empty?

            default(options[:default]) if options.key?(:default)
            experimental_default_proc(&options[:experimental_default_proc]) if options.key?(:experimental_default_proc)
            delegate_to(&options[:delegate_to]) if options.key?(:delegate_to)
            depends_on(*options[:depends_on]) if options.key?(:depends_on)
            lazy(options[:lazy]) if options.key?(:lazy)
            on_set(&options[:on_set]) if options.key?(:on_set)
            resetter(&options[:resetter]) if options.key?(:resetter)
            setter(&options[:setter]) if options.key?(:setter)
            type(&options[:type]) if options.key?(:type)
          end

          def to_definition
            OptionDefinition.new(@name, meta)
          end

          def meta
            {
              default: @default,
              experimental_default_proc: @experimental_default_proc,
              delegate_to: @delegate_to,
              depends_on: @depends_on,
              on_set: @on_set,
              resetter: @resetter,
              setter: @setter,
              type: @type
            }
          end

          private

          def validate_options!
            if !@default.nil? && @experimental_default_proc
              raise InvalidOptionError,
                'Using `default` and `experimental_default_proc` is not allowed. Please use one or the other.' \
                                'If you want to store a block as the default value use `experimental_default_proc`'\
                                ' otherwise use `default`'
            end
          end
        end
      end
    end
  end
end
