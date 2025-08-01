require 'spec_helper'

require 'securerandom'

require 'datadog/core/configuration/settings'
require 'datadog/tracing/configuration/ext'
require 'datadog/tracing/flush'
require 'datadog/tracing/sampling/priority_sampler'
require 'datadog/tracing/tracer'
require 'datadog/tracing/writer'
require_relative '../../core/configuration/settings_shared_examples'

RSpec.describe Datadog::Tracing::Configuration::Settings do
  # TODO: Core::Configuration::Settings directly extends Tracing::Configuration::Settings
  #       In the future, have tracing add this behavior itself. For now,
  #       just use the core settings class to drive the tests.
  subject(:settings) { Datadog::Core::Configuration::Settings.new(options) }

  let(:options) { {} }

  describe '#tracing' do
    let(:envs) { { '_test_' => nil } }
    around do |example|
      ClimateControl.modify(envs) do
        example.run
      end
    end
    describe '#analytics' do
      describe '#enabled' do
        subject(:enabled) { settings.tracing.analytics.enabled }

        context "when #{Datadog::Tracing::Configuration::Ext::Analytics::ENV_TRACE_ANALYTICS_ENABLED}" do
          around do |example|
            ClimateControl.modify(
              Datadog::Tracing::Configuration::Ext::Analytics::ENV_TRACE_ANALYTICS_ENABLED => environment
            ) do
              example.run
            end
          end

          context 'is not defined' do
            let(:environment) { nil }

            it { is_expected.to be nil }
          end

          context 'is defined' do
            let(:environment) { 'true' }

            it { is_expected.to be true }
          end
        end
      end

      describe '#enabled=' do
        after { settings.runtime_metrics.reset! }

        it 'changes the #enabled setting' do
          expect { settings.tracing.analytics.enabled = true }
            .to change { settings.tracing.analytics.enabled }
            .from(nil)
            .to(true)
        end
      end
    end

    describe '#propagation_style_extract' do
      subject(:propagation_style_extract) { settings.tracing.propagation_style_extract }

      context 'when DD_TRACE_PROPAGATION_STYLE_EXTRACT' do
        let(:envs) { { 'DD_TRACE_PROPAGATION_STYLE_EXTRACT' => var_value } }

        context 'is not defined' do
          let(:var_value) { nil }

          it do
            is_expected.to contain_exactly(
              Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_DATADOG,
              Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_TRACE_CONTEXT,
              Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_BAGGAGE
            )
          end
        end

        context 'is defined' do
          let(:var_value) { 'b3multi,b3' }

          it do
            is_expected.to eq(
              [
                Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_B3_MULTI_HEADER,
                Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_B3_SINGLE_HEADER
              ]
            )
          end

          context 'with a mixed case value' do
            let(:var_value) { 'B3Multi,B3' }

            it 'parses in a case-insensitive manner' do
              is_expected.to eq(
                [
                  Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_B3_MULTI_HEADER,
                  Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_B3_SINGLE_HEADER
                ]
              )
            end
          end
        end
      end
    end

    describe '#propagation_style_inject' do
      subject(:propagation_style_inject) { settings.tracing.propagation_style_inject }

      context 'with DD_TRACE_PROPAGATION_STYLE_INJECT' do
        let(:envs) { { 'DD_TRACE_PROPAGATION_STYLE_INJECT' => var_value } }

        context 'is not defined' do
          let(:var_value) { nil }

          it do
            is_expected.to contain_exactly(
              Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_DATADOG,
              Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_TRACE_CONTEXT,
              Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_BAGGAGE
            )
          end
        end

        context 'is defined' do
          let(:var_value) { 'datadog,b3' }

          it do
            is_expected.to eq(
              [
                Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_DATADOG,
                Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_B3_SINGLE_HEADER
              ]
            )
          end

          context 'with a mixed case value' do
            let(:var_value) { 'Datadog,B3' }

            it 'parses in a case-insensitive manner' do
              is_expected.to eq(
                [
                  Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_DATADOG,
                  Datadog::Tracing::Configuration::Ext::Distributed::PROPAGATION_STYLE_B3_SINGLE_HEADER
                ]
              )
            end
          end
        end
      end
    end

    describe '#propagation_style' do
      subject(:propagation_style) { settings.tracing.propagation_style }

      def propagation_style_extract
        settings.tracing.propagation_style_extract
      end

      def propagation_style_inject
        settings.tracing.propagation_style_inject
      end

      context 'with DD_TRACE_PROPAGATION_STYLE' do
        let(:envs) { { 'DD_TRACE_PROPAGATION_STYLE' => var_value } }

        context 'is not defined' do
          let(:var_value) { nil }

          it { is_expected.to eq [] }

          it 'does not change propagation_style_extract' do
            expect { propagation_style }.to_not change { propagation_style_extract }.from(%w[datadog tracecontext baggage])
          end

          it 'does not change propagation_style_inject' do
            expect { propagation_style }.to_not change { propagation_style_inject }.from(%w[datadog tracecontext baggage])
          end
        end

        context 'is defined' do
          let(:var_value) { 'b3multi,b3' }

          it { is_expected.to contain_exactly('b3multi', 'b3') }

          it 'sets propagation_style_extract' do
            expect { propagation_style }.to change { propagation_style_extract }.to(%w[b3multi b3])
          end

          it 'sets propagation_style_inject' do
            expect { propagation_style }.to change { propagation_style_inject }.to(%w[b3multi b3])
          end

          context 'with a mixed case value' do
            let(:var_value) { 'b3MULTI' }

            it 'parses in a case-insensitive manner' do
              expect { propagation_style }.to change { propagation_style_extract }.to(%w[b3multi])
            end
          end
        end
      end

      context 'with OTEL_PROPAGATORS' do
        context 'and without DD_TRACE_PROPAGATION_STYLE' do
          let(:envs) { { 'OTEL_PROPAGATORS' => 'tracecontext,jaegar,b3,b3multi' } }
          it 'sets propagation_style_extract' do
            expect { propagation_style }.to change { propagation_style_extract }.to(%w[tracecontext b3 b3multi])
          end

          it 'sets propagation_style_inject' do
            expect { propagation_style }.to change { propagation_style_inject }.to(%w[tracecontext b3 b3multi])
          end
        end

        context 'and with DD_TRACE_PROPAGATION_STYLE' do
          let(:envs) do
            { 'OTEL_PROPAGATORS' => 'tracecontext,jaegar,b3single', 'DD_TRACE_PROPAGATION_STYLE' => 'b3multi,b3' }
          end

          it 'sets propagation_style_extract' do
            expect { propagation_style }.to change { propagation_style_extract }.to(%w[b3multi b3])
          end

          it 'sets propagation_style_inject' do
            expect { propagation_style }.to change { propagation_style_inject }.to(%w[b3multi b3])
          end
        end
      end
    end

    describe '#propagation_extract_first' do
      subject(:propagation_extract_first) { settings.tracing.propagation_extract_first }

      let(:envs) { { 'DD_TRACE_PROPAGATION_EXTRACT_FIRST' => var_value } }
      let(:var_value) { nil }
      it { is_expected.to be false }

      context 'when DD_TRACE_PROPAGATION_EXTRACT_FIRST' do
        context 'is not defined' do
          let(:var_value) { nil }

          it { is_expected.to be false }
        end

        context 'is set to true' do
          let(:var_value) { 'true' }

          it { is_expected.to be true }
        end

        context 'is set to false' do
          let(:var_value) { 'false' }

          it { is_expected.to be false }
        end
      end

      describe '#propagation_extract_first=' do
        it 'updates the #propagation_extract_first setting' do
          expect { settings.tracing.propagation_extract_first = true }
            .to change { settings.tracing.propagation_extract_first }
            .from(false)
            .to(true)
        end
      end
    end

    describe '#enabled' do
      subject(:enabled) { settings.tracing.enabled }

      it { is_expected.to be true }

      context "when #{Datadog::Tracing::Configuration::Ext::ENV_ENABLED}" do
        around do |example|
          ClimateControl.modify(Datadog::Tracing::Configuration::Ext::ENV_ENABLED => enable) do
            example.run
          end
        end

        context 'is not defined' do
          let(:enable) { nil }

          it { is_expected.to be true }
        end

        context 'is set to true' do
          let(:enable) { 'true' }

          it { is_expected.to be true }
        end

        context 'is set to false' do
          let(:enable) { 'false' }

          it { is_expected.to be false }
        end
      end

      context "when #{Datadog::Tracing::Configuration::Ext::ENV_OTEL_TRACES_EXPORTER}" do
        around do |example|
          ClimateControl.modify(
            {
              Datadog::Tracing::Configuration::Ext::ENV_ENABLED => dd_enable,
              Datadog::Tracing::Configuration::Ext::ENV_OTEL_TRACES_EXPORTER => otel_exporter
            }
          ) do
            example.run
          end
        end

        context 'is not defined' do
          let(:dd_enable) { nil }
          let(:otel_exporter) { nil }
          it { is_expected.to be true }
        end

        context 'is set to none' do
          let(:dd_enable) { nil }
          let(:otel_exporter) { 'none' }
          it { is_expected.to be false }
        end

        context 'is set to unsupported value' do
          let(:dd_enable) { nil }
          let(:otel_exporter) { 'otlp' }
          it 'the default value is used' do
            is_expected.to be true
          end
        end

        context 'is set to none AND DD_TRACE_ENABLED is set to True' do
          let(:dd_enable) { 'true' }
          let(:otel_exporter) { 'none' }
          it 'datadog configurations take precedence' do
            is_expected.to be true
          end
        end
      end
    end

    describe '#enabled=' do
      it 'updates the #enabled setting' do
        expect { settings.tracing.enabled = false }
          .to change { settings.tracing.enabled }
          .from(true)
          .to(false)
      end
    end

    describe '#header_tags' do
      subject(:header_tags) { settings.tracing.header_tags }

      context "when #{Datadog::Tracing::Configuration::Ext::ENV_HEADER_TAGS}" do
        around do |example|
          ClimateControl.modify(Datadog::Tracing::Configuration::Ext::ENV_HEADER_TAGS => tags) do
            example.run
          end
        end

        context 'is not defined' do
          let(:tags) { nil }

          it { is_expected.to be_a(Datadog::Tracing::Configuration::HTTP::HeaderTags) }
          it { expect(header_tags.to_s).to eq('') }
        end

        context 'is set to content-type' do
          let(:tags) { 'content-type' }

          it { is_expected.to be_a(Datadog::Tracing::Configuration::HTTP::HeaderTags) }
          it { expect(header_tags.to_s).to eq('content-type') }
        end

        context 'is set to content-type,cookie' do
          let(:tags) { 'content-type,cookie' }

          it { is_expected.to be_a(Datadog::Tracing::Configuration::HTTP::HeaderTags) }
          it { expect(header_tags.to_s).to eq('content-type,cookie') }
        end
      end
    end

    describe '#header_tags=' do
      it 'updates the #header_tags setting' do
        expect { settings.tracing.header_tags = ['content-type'] }
          .to change { settings.tracing.header_tags }
          .from(->(actual) { expect(actual.to_s).to be_empty })
          .to(->(actual) { expect(actual.to_s).to eq('content-type') })
      end
    end

    describe '#baggage_tag_keys' do
      subject(:baggage_tag_keys) { settings.tracing.baggage_tag_keys }

      context "when #{Datadog::Tracing::Configuration::Ext::ENV_BAGGAGE_TAG_KEYS}" do
        around do |example|
          ClimateControl.modify(Datadog::Tracing::Configuration::Ext::ENV_BAGGAGE_TAG_KEYS => env_var) do
            example.run
          end
        end

        context 'is not defined' do
          let(:env_var) { nil }

          it { is_expected.to eq(['user.id', 'session.id', 'account.id']) }
        end

        context 'is set to empty string' do
          let(:env_var) { '' }

          it { is_expected.to eq [] }
        end

        context 'is set to wildcard' do
          let(:env_var) { '*' }

          it { is_expected.to eq(['*']) }
        end

        context 'is set to custom keys' do
          let(:env_var) { 'custom.key1,custom.key2' }

          it { is_expected.to eq(['custom.key1', 'custom.key2']) }
        end
      end
    end

    describe '#baggage_tag_keys=' do
      it 'updates the #baggage_tag_keys setting' do
        expect { settings.tracing.baggage_tag_keys = ['new.key'] }
          .to change { settings.tracing.baggage_tag_keys }
          .from(['user.id', 'session.id', 'account.id'])
          .to(['new.key'])
      end
    end

    describe '#instance' do
      subject(:instance) { settings.tracing.instance }

      it { is_expected.to be nil }
    end

    describe '#instance=' do
      let(:tracer) { instance_double(Datadog::Tracing::Tracer) }

      it 'updates the #instance setting' do
        expect { settings.tracing.instance = tracer }
          .to change { settings.tracing.instance }
          .from(nil)
          .to(tracer)
      end
    end

    describe '#log_injection' do
      subject(:log_injection) { settings.tracing.log_injection }

      context "when #{Datadog::Tracing::Configuration::Ext::Correlation::ENV_LOGS_INJECTION_ENABLED}" do
        around do |example|
          ClimateControl.modify(
            Datadog::Tracing::Configuration::Ext::Correlation::ENV_LOGS_INJECTION_ENABLED => log_injection_env
          ) do
            example.run
          end
        end

        context 'is not defined' do
          let(:log_injection_env) { nil }

          it { is_expected.to be(true) }
        end

        context 'is defined' do
          let(:log_injection_env) { 'false' }

          it { is_expected.to be(false) }
        end
      end
    end

    describe '#partial_flush' do
      describe '#enabled' do
        subject(:enabled) { settings.tracing.partial_flush.enabled }

        it { is_expected.to be false }
      end

      describe '#enabled=' do
        it 'updates the #enabled setting' do
          expect { settings.tracing.partial_flush.enabled = true }
            .to change { settings.tracing.partial_flush.enabled }
            .from(false)
            .to(true)
        end
      end

      describe '#min_spans_threshold' do
        subject(:min_spans_threshold) { settings.tracing.partial_flush.min_spans_threshold }

        it { is_expected.to eq(500) }
      end

      describe '#min_spans_threshold=' do
        let(:value) { 1234 }

        it 'updates the #min_spans_before_partial_flush setting' do
          expect { settings.tracing.partial_flush.min_spans_threshold = value }
            .to change { settings.tracing.partial_flush.min_spans_threshold }
            .from(500)
            .to(value)
        end
      end
    end

    describe '#report_hostname' do
      subject(:report_hostname) { settings.tracing.report_hostname }

      context "when #{Datadog::Tracing::Configuration::Ext::NET::ENV_REPORT_HOSTNAME}" do
        around do |example|
          ClimateControl.modify(Datadog::Tracing::Configuration::Ext::NET::ENV_REPORT_HOSTNAME => environment) do
            example.run
          end
        end

        context 'is not defined' do
          let(:environment) { nil }

          it { is_expected.to be false }
        end

        context 'is defined' do
          let(:environment) { 'true' }

          it { is_expected.to be true }
        end
      end
    end

    describe '#report_hostname=' do
      it 'changes the #report_hostname setting' do
        expect { settings.tracing.report_hostname = true }
          .to change { settings.tracing.report_hostname }
          .from(false)
          .to(true)
      end
    end

    describe '#native_span_events' do
      subject(:native_span_events) { settings.tracing.native_span_events }

      it_behaves_like 'a binary setting with',
        env_variable: 'DD_TRACE_NATIVE_SPAN_EVENTS',
        default: nil
    end

    describe '#native_span_events=' do
      it 'changes the #native_span_events setting' do
        expect { settings.tracing.native_span_events = true }
          .to change { settings.tracing.native_span_events }
          .from(nil)
          .to(true)
      end
    end

    describe '#sampler' do
      subject(:sampler) { settings.tracing.sampler }

      it { is_expected.to be nil }
    end

    describe '#sampler=' do
      let(:sampler) { instance_double(Datadog::Tracing::Sampling::PrioritySampler) }

      it 'updates the #sampler setting' do
        expect { settings.tracing.sampler = sampler }
          .to change { settings.tracing.sampler }
          .from(nil)
          .to(sampler)
      end
    end

    describe '#sampling' do
      describe '#rate_limit' do
        subject(:rate_limit) { settings.tracing.sampling.rate_limit }

        context 'default' do
          it { is_expected.to eq(100) }
        end

        context 'when ENV is provided' do
          around do |example|
            ClimateControl.modify(Datadog::Tracing::Configuration::Ext::Sampling::ENV_RATE_LIMIT => '20') do
              example.run
            end
          end

          it { is_expected.to eq(20) }
        end
      end

      describe '#default_rate' do
        subject(:default_rate) { settings.tracing.sampling.default_rate }

        context 'default' do
          it { is_expected.to be nil }
        end

        context 'when DD_TRACE_SAMPLE_RATE is provided' do
          around do |example|
            ClimateControl.modify(Datadog::Tracing::Configuration::Ext::Sampling::ENV_SAMPLE_RATE => '0.5') do
              example.run
            end
          end

          it { is_expected.to eq(0.5) }
        end

        context 'when OTEL_TRACES_SAMPLER is set to' do
          let(:otel_sampler) { nil }
          let(:otel_sampler_arg) { nil }
          let(:dd_sample_rate) { nil }
          around do |example|
            ClimateControl.modify(
              Datadog::Tracing::Configuration::Ext::Sampling::ENV_OTEL_TRACES_SAMPLER => otel_sampler,
              Datadog::Tracing::Configuration::Ext::Sampling::OTEL_TRACES_SAMPLER_ARG => otel_sampler_arg,
              Datadog::Tracing::Configuration::Ext::Sampling::ENV_SAMPLE_RATE => dd_sample_rate,
            ) do
              example.run
            end
          end

          context 'always_on' do
            let(:otel_sampler) { 'always_on' }
            it { is_expected.to eq(1) }
          end

          context 'always_off' do
            let(:otel_sampler) { 'always_off' }
            it { is_expected.to eq(0) }
          end

          context 'traceidratio' do
            let(:otel_sampler) { 'traceidratio' }
            let(:otel_sampler_arg) { '0.5' }
            it { is_expected.to eq(0.5) }
          end

          context 'parentbased_always_on' do
            let(:otel_sampler) { 'parentbased_always_on' }
            it { is_expected.to eq(1) }
          end

          context 'parentbased_always_off' do
            let(:otel_sampler) { 'parentbased_always_off' }
            it { is_expected.to eq(0) }
          end

          context 'parentbased_traceidratio' do
            let(:otel_sampler) { 'parentbased_traceidratio' }
            let(:otel_sampler_arg) { '0.5' }
            it { is_expected.to eq(0.5) }
          end

          context 'traceidratio and OTEL_TRACES_SAMPLER_ARG is not set' do
            let(:otel_sampler) { 'traceidratio' }
            it { is_expected.to eq(1) }
          end

          context 'and DD_TRACE_SAMPLE_RATE is set' do
            let(:otel_sampler) { 'always_on' }
            let(:dd_sample_rate) { '0.5' }
            it 'datadog configurations take precedence' do
              is_expected.to eq(0.5)
            end
          end
        end
      end

      describe '#rules' do
        subject(:rules) { settings.tracing.sampling.rules }

        context 'default' do
          it { is_expected.to be_nil }
        end

        context 'when ENV is provided' do
          around do |example|
            ClimateControl.modify('DD_TRACE_SAMPLING_RULES' => '[{"sample_rate":0.2}]') do
              example.run
            end
          end

          it { is_expected.to eq('[{"sample_rate":0.2}]') }
        end
      end

      describe '#span_rules' do
        subject(:rules) { settings.tracing.sampling.span_rules }

        context 'default' do
          it { is_expected.to be nil }
        end

        context 'when DD_SPAN_SAMPLING_RULES is provided' do
          around do |example|
            ClimateControl.modify(
              Datadog::Tracing::Configuration::Ext::Sampling::Span::ENV_SPAN_SAMPLING_RULES => '{}'
            ) do
              example.run
            end
          end

          it { is_expected.to eq('{}') }

          context 'and DD_SPAN_SAMPLING_RULES_FILE is also provided' do
            around do |example|
              ClimateControl.modify(
                Datadog::Tracing::Configuration::Ext::Sampling::Span::ENV_SPAN_SAMPLING_RULES_FILE => 'path'
              ) do
                example.run
              end
            end

            it 'emits a conflict warning and returns DD_SPAN_SAMPLING_RULES' do
              expect(Datadog.logger).to receive(:warn).with(include('configuration conflict'))
              is_expected.to eq('{}')
            end
          end
        end

        context 'when DD_SPAN_SAMPLING_RULES_FILE is provided' do
          around do |example|
            Tempfile.open('DD_SPAN_SAMPLING_RULES_FILE') do |f|
              f.write('{from:"file"}')
              f.flush

              ClimateControl.modify(
                Datadog::Tracing::Configuration::Ext::Sampling::Span::ENV_SPAN_SAMPLING_RULES_FILE => f.path
              ) do
                example.run
              end
            end
          end

          it { is_expected.to eq('{from:"file"}') }
        end
      end
    end

    describe '#test_mode' do
      describe '#enabled' do
        subject(:enabled) { settings.tracing.test_mode.enabled }

        it { is_expected.to be false }

        context "when #{Datadog::Tracing::Configuration::Ext::Test::ENV_MODE_ENABLED}" do
          around do |example|
            ClimateControl.modify(Datadog::Tracing::Configuration::Ext::Test::ENV_MODE_ENABLED => enable) do
              example.run
            end
          end

          context 'is not defined' do
            let(:enable) { nil }

            it { is_expected.to be false }
          end

          context 'is set to true' do
            let(:enable) { 'true' }

            it { is_expected.to be true }
          end

          context 'is set to false' do
            let(:enable) { 'false' }

            it { is_expected.to be false }
          end
        end
      end

      describe '#trace_flush' do
        subject(:trace_flush) { settings.tracing.test_mode.trace_flush }

        context 'default' do
          it { is_expected.to be nil }
        end
      end

      describe '#trace_flush=' do
        let(:trace_flush) { instance_double(Datadog::Tracing::Flush::Finished) }

        it 'updates the #trace_flush setting' do
          expect { settings.tracing.test_mode.trace_flush = trace_flush }
            .to change { settings.tracing.test_mode.trace_flush }
            .from(nil)
            .to(trace_flush)
        end
      end

      describe '#enabled=' do
        it 'updates the #enabled setting' do
          expect { settings.tracing.test_mode.enabled = true }
            .to change { settings.tracing.test_mode.enabled }
            .from(false)
            .to(true)
        end
      end

      describe '#async' do
        subject(:enabled) { settings.tracing.test_mode.async }

        it { is_expected.to be false }
      end

      describe '#async=' do
        it 'updates the #async setting' do
          expect { settings.tracing.test_mode.async = true }
            .to change { settings.tracing.test_mode.async }
            .from(false)
            .to(true)
        end
      end

      describe '#writer_options' do
        subject(:writer_options) { settings.tracing.test_mode.writer_options }

        it { is_expected.to eq({}) }

        context 'when modified' do
          it 'does not modify the default by reference' do
            settings.tracing.test_mode.writer_options[:foo] = :bar
            expect(settings.tracing.test_mode.writer_options).to_not be_empty
            expect(settings.tracing.test_mode.options[:writer_options].default_value).to be_empty
          end
        end
      end

      describe '#writer_options=' do
        let(:options) { { anything: double } }

        it 'updates the #writer_options setting' do
          expect { settings.tracing.test_mode.writer_options = options }
            .to change { settings.tracing.test_mode.writer_options }
            .from({})
            .to(options)
        end
      end
    end

    describe '#writer' do
      subject(:writer) { settings.tracing.writer }

      it { is_expected.to be nil }
    end

    describe '#writer=' do
      let(:writer) { instance_double(Datadog::Tracing::Writer) }

      it 'updates the #writer setting' do
        expect { settings.tracing.writer = writer }
          .to change { settings.tracing.writer }
          .from(nil)
          .to(writer)
      end
    end

    describe '#writer_options' do
      subject(:writer_options) { settings.tracing.writer_options }

      it { is_expected.to eq({}) }

      context 'when modified' do
        it 'does not modify the default by reference' do
          settings.tracing.writer_options[:foo] = :bar
          expect(settings.tracing.writer_options).to_not be_empty
          expect(settings.tracing.options[:writer_options].default_value).to be_empty
        end
      end
    end

    describe '#writer_options=' do
      let(:options) { { anything: double } }

      it 'updates the #writer_options setting' do
        expect { settings.tracing.writer_options = options }
          .to change { settings.tracing.writer_options }
          .from({})
          .to(options)
      end
    end

    describe '#x_datadog_tags_max_length' do
      subject { settings.tracing.x_datadog_tags_max_length }

      context "when #{Datadog::Tracing::Configuration::Ext::Distributed::ENV_X_DATADOG_TAGS_MAX_LENGTH}" do
        around do |example|
          ClimateControl.modify(
            Datadog::Tracing::Configuration::Ext::Distributed::ENV_X_DATADOG_TAGS_MAX_LENGTH => env_var
          ) do
            example.run
          end
        end

        context 'is not defined' do
          let(:env_var) { nil }

          it { is_expected.to eq(512) }
        end

        context 'is defined' do
          let(:env_var) { '123' }

          it { is_expected.to eq(123) }
        end
      end
    end

    describe '#x_datadog_tags_max_length=' do
      it 'updates the #x_datadog_tags_max_length setting' do
        expect { settings.tracing.x_datadog_tags_max_length = 123 }
          .to change { settings.tracing.x_datadog_tags_max_length }
          .from(512)
          .to(123)
      end
    end

    describe '#trace_id_128_bit_generation_enabled' do
      subject { settings.tracing.trace_id_128_bit_generation_enabled }

      context 'when given environment variable `DD_TRACE_128_BIT_TRACEID_GENERATION_ENABLED`' do
        around do |example|
          ClimateControl.modify(
            'DD_TRACE_128_BIT_TRACEID_GENERATION_ENABLED' => env_var
          ) do
            example.run
          end
        end

        context 'is not defined' do
          let(:env_var) { nil }

          it { is_expected.to eq(true) }
        end

        context 'is `true`' do
          let(:env_var) { 'true' }

          it { is_expected.to eq(true) }
        end

        context 'is `false`' do
          let(:env_var) { 'false' }

          it { is_expected.to eq(false) }
        end
      end
    end

    describe '#trace_id_128_bit_generation_enabled=' do
      it 'updates the #trace_id_128_bit_generation_enabled setting' do
        expect do
          settings.tracing.trace_id_128_bit_generation_enabled = false
        end.to change { settings.tracing.trace_id_128_bit_generation_enabled }
          .from(true)
          .to(false)
      end
    end

    describe '#trace_id_128_bit_logging_enabled' do
      subject { settings.tracing.trace_id_128_bit_logging_enabled }

      context 'when given environment variable `DD_TRACE_128_BIT_TRACEID_LOGGING_ENABLED ' do
        around do |example|
          ClimateControl.modify(
            'DD_TRACE_128_BIT_TRACEID_LOGGING_ENABLED' => env_var
          ) do
            example.run
          end
        end

        context 'is not defined' do
          let(:env_var) { nil }

          it { is_expected.to eq(true) }
        end

        context 'is `true`' do
          let(:env_var) { 'true' }

          it { is_expected.to eq(true) }
        end

        context 'is `false`' do
          let(:env_var) { 'false' }

          it { is_expected.to eq(false) }
        end
      end
    end

    describe '#trace_id_128_bit_logging_enabled=' do
      it 'updates the #trace_id_128_bit_logging_enabled setting' do
        expect do
          settings.tracing.trace_id_128_bit_logging_enabled = false
        end.to change { settings.tracing.trace_id_128_bit_logging_enabled }
          .from(true)
          .to(false)
      end
    end

    describe '#client_ip.enabled' do
      context 'default' do
        it do
          expect(settings.tracing.client_ip.enabled).to eq(false)
        end
      end

      {
        'true' => true,
        '1' => true,
        'false' => false
      }.each do |env, value|
        context "when ENV['DD_TRACE_CLIENT_IP_ENABLED'] is '#{env}'" do
          around do |example|
            ClimateControl.modify('DD_TRACE_CLIENT_IP_ENABLED' => env) do
              example.run
            end
          end

          it do
            expect(settings.tracing.client_ip.enabled).to eq(value)
          end
        end
      end
    end
  end
end
