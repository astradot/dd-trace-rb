require 'spec_helper'
require 'datadog/tracing/sampling/shared_examples'

require 'logger'

require 'datadog/core'
require 'datadog/tracing/sampling/rate_sampler'
require 'datadog/tracing/trace_operation'

RSpec.describe Datadog::Tracing::Sampling::RateSampler do
  subject(:sampler) { described_class.new(sample_rate) }

  before { Datadog.logger.level = Logger::FATAL }

  after { Datadog.logger.level = Logger::WARN }

  describe '#initialize' do
    context 'given a sample rate' do
      context 'that is negative' do
        let(:sample_rate) { -1.0 }

        it_behaves_like 'sampler with sample rate', 1.0 do
          let(:trace) { nil }
        end

        it do
          expect(Datadog.logger).to receive(:warn).with('sample rate is not between 0 and 1, falling back to 1')

          sampler
        end
      end

      context 'that is 0' do
        let(:sample_rate) { 0.0 }

        it_behaves_like 'sampler with sample rate', 0.0
      end

      context 'that is 1' do
        let(:sample_rate) { 1.0 }

        it_behaves_like 'sampler with sample rate', 1.0
      end

      context 'that is between 0 and 1.0' do
        let(:sample_rate) { 0.5 }

        it_behaves_like 'sampler with sample rate', 0.5
      end

      context 'that is greater than 1.0' do
        let(:sample_rate) { 1.5 }

        it_behaves_like 'sampler with sample rate', 1.0

        it do
          expect(Datadog.logger).to receive(:warn).with('sample rate is not between 0 and 1, falling back to 1')

          sampler
        end
      end
    end
  end

  describe '#sample!' do
    subject(:sample!) { sampler.sample!(trace) }

    let(:traces) { Array.new(3) { |i| Datadog::Tracing::TraceOperation.new(id: i) } }
    let(:trace) { traces[0] }

    shared_examples_for 'rate sampling' do
      let(:trace_count) { 1000 }
      let(:rng) { Random.new(123) }

      let(:traces) { Array.new(trace_count) { |i| Datadog::Tracing::TraceOperation.new(id: i) } }
      let(:expected_num_of_sampled_traces) { trace_count * sample_rate }

      it 'samples an appropriate proportion of span operations' do
        sample = traces.map do |trace|
          sampled = sampler.sample!(trace)
          expect(trace.sample_rate).to eq(sample_rate) if sampled
          sampled
        end

        expect(sample.count(&:itself)).to be_within(expected_num_of_sampled_traces * 0.1)
          .of(expected_num_of_sampled_traces)
      end
    end

    it_behaves_like('rate sampling') { let(:sample_rate) { 0.1 } }
    it_behaves_like('rate sampling') { let(:sample_rate) { 0.25 } }
    it_behaves_like('rate sampling') { let(:sample_rate) { 0.5 } }
    it_behaves_like('rate sampling') { let(:sample_rate) { 0.9 } }

    context 'when a sample rate of 1.0 is set' do
      let(:sample_rate) { 1.0 }

      it 'samples all span operations' do
        traces.each do |trace|
          expect(sampler.sample!(trace)).to be true
          expect(trace.sampled?).to be true
          expect(trace.sample_rate).to eq(sample_rate)
        end
      end

      context 'and decision is set' do
        subject(:sampler) { described_class.new(sample_rate, decision: decision) }
        let(:decision) { 'test decision' }

        it 'sets trace decision' do
          sample!
          expect(trace.get_tag('_dd.p.dm')).to eq(decision)
        end
      end
    end

    context 'when a sample rate of 0.0 is set' do
      let(:sample_rate) { Float::MIN } # Can't set to exactly zero because of safeguard

      it 'does not trace decision' do
        sample!
        expect(trace.get_tag('_dd.p.dm')).to be_nil
      end
    end

    context 'with specific trace IDs and 0.5 sample rate' do
      let(:sample_rate) { 0.5 }
      let(:trace_expectations) do
        {
          12078589664685934330 => false,
          13794769880582338323 => true,
          1882305164521835798 => true,
          5198373796167680436 => false,
          6272545487220484606 => true,
          8696342848850656916 => true,
          18444899399302180860 => false,
          18444899399302180862 => true,
          9223372036854775808 => true, # Lands exactly on the sampling threshold 0.5 * MAX_UINT64
        }
      end

      it 'produces deterministic sampling results' do
        trace_expectations.each do |id, expected|
          trace = Datadog::Tracing::TraceOperation.new(id: id)
          expect(sampler.sample!(trace)).to eq(expected),
            "Expected trace ID #{id} to be #{expected ? 'sampled' : 'not sampled'}"
        end
      end
    end
  end
end
