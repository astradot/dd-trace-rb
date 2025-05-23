require 'spec_helper'

require 'datadog/tracing/contrib/grpc/distributed/propagation'
require_relative '../../../distributed/b3_single_spec'
require_relative '../../../distributed/b3_multi_spec'
require_relative '../../../distributed/datadog_spec'
require_relative '../../../distributed/none_spec'
require_relative '../../../distributed/propagation_spec'
require_relative '../../../distributed/trace_context_spec'
require_relative '../../../distributed/baggage_spec'

RSpec.describe Datadog::Tracing::Contrib::GRPC::Distributed::Propagation do
  subject(:propagation) do
    described_class.new(
      propagation_style_inject: propagation_style_inject,
      propagation_style_extract: propagation_style_extract,
      propagation_extract_first: propagation_extract_first
    )
  end

  let(:propagation_style_inject) { ['datadog', 'tracecontext', 'baggage'] }
  let(:propagation_style_extract) { ['datadog', 'tracecontext', 'baggage'] }
  let(:propagation_extract_first) { false }

  it 'contains default inject propagation styles in its propagation styles list' do
    expect(propagation.instance_variable_get(:@propagation_styles).keys)
      .to include(*Datadog.configuration.tracing.propagation_style_inject)
    Datadog.configuration.tracing.propagation_style_inject.each do |style|
      expect(propagation.instance_variable_get(:@propagation_styles)[style]).to_not be_nil
    end
  end

  it 'contains default extract propagation styles in its propagation styles list' do
    expect(propagation.instance_variable_get(:@propagation_styles).keys)
      .to include(*Datadog.configuration.tracing.propagation_style_extract)
    Datadog.configuration.tracing.propagation_style_extract.each do |style|
      expect(propagation.instance_variable_get(:@propagation_styles)[style]).to_not be_nil
    end
  end

  it_behaves_like 'Distributed tracing propagator' do
    subject(:propagator) { propagation }

    describe '.extract' do
      subject(:extract) { propagation.extract(data) }
      let(:trace_digest) { extract }

      # Metadata values can also be arrays
      # https://github.com/grpc/grpc-go/blob/master/Documentation/grpc-metadata.md
      context 'given populated data in array format' do
        let(:data) do
          { 'x-datadog-trace-id' => %w[12345 67890],
            'x-datadog-parent-id' => %w[98765 43210],
            'x-datadog-sampling-priority' => ['0'],
            'x-datadog-origin' => ['synthetics'] }
        end

        it 'returns a populated TraceDigest with the first data array values' do
          expect(trace_digest.span_id).to eq 98765
          expect(trace_digest.trace_id).to eq 12345
          expect(trace_digest.trace_origin).to eq 'synthetics'
          expect(trace_digest.trace_sampling_priority).to be_zero
        end
      end
    end
  end

  context 'for B3 Multi' do
    it_behaves_like 'B3 Multi distributed format' do
      before { Datadog.configure { |c| c.tracing.propagation_style = ['b3multi'] } }
      let(:b3) { propagation }
    end
  end

  context 'for B3 Single' do
    it_behaves_like 'B3 Single distributed format' do
      before { Datadog.configure { |c| c.tracing.propagation_style = ['b3'] } }
      let(:b3_single) { propagation }
    end
  end

  context 'for Datadog' do
    it_behaves_like 'Datadog distributed format' do
      before { Datadog.configure { |c| c.tracing.propagation_style = ['datadog'] } }
      let(:datadog) { propagation }
    end
  end

  context 'for Trace Context' do
    it_behaves_like 'Trace Context distributed format' do
      before { Datadog.configure { |c| c.tracing.propagation_style = ['tracecontext'] } }
      let(:datadog) { propagation }
    end
  end

  context 'for None' do
    it_behaves_like 'None distributed format' do
      before { Datadog.configure { |c| c.tracing.propagation_style = ['none'] } }
      let(:datadog) { propagation }
    end
  end

  context 'for Baggage' do
    it_behaves_like 'Baggage distributed format' do
      before { Datadog.configure { |c| c.tracing.propagation_style = ['baggage'] } }
      let(:datadog) { propagation }
    end
  end
end
