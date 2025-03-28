# frozen_string_literal: true

require 'spec_helper'
require 'datadog/core/remote/component'

RSpec.describe Datadog::Core::Remote::Component, :integration do
  let(:settings) { Datadog::Core::Configuration::Settings.new }
  let(:agent_settings) { Datadog::Core::Configuration::AgentSettingsResolver.call(settings, logger: nil) }
  let(:telemetry) { instance_double(Datadog::Core::Telemetry::Component) }
  let(:capabilities) { Datadog::Core::Remote::Client::Capabilities.new(settings, telemetry) }
  let(:component) { described_class.new(settings, capabilities, agent_settings, logger: logger) }

  let(:logger) { logger_allowing_debug }

  around do |example|
    ClimateControl.modify('DD_REMOTE_CONFIGURATION_ENABLED' => nil) { example.run }
  end

  describe '.build' do
    subject(:build) { described_class.build(settings, agent_settings, logger: logger, telemetry: telemetry) }

    after { build.shutdown! if build }

    context 'remote disabled' do
      let(:remote) do
        mock = double('remote')
        expect(mock).to receive(:enabled).and_return(false)
        mock
      end

      before { expect(settings).to receive(:remote).and_return(remote) }

      it 'returns nil ' do
        is_expected.to be_nil
      end
    end

    context 'enabled' do
      let(:capabilities) { double('capabilities') }
      let(:component) { double('component', shutdown!: nil) }

      it 'initializes component' do
        expect(Datadog::Core::Remote::Client::Capabilities).to receive(:new).with(
          settings,
          telemetry
        ).and_return(capabilities)
        expect(described_class).to receive(:new).with(
          settings,
          capabilities,
          agent_settings,
          logger: logger
        ).and_return(component)

        is_expected.to eq(component)
      end
    end
  end

  describe '#initialize' do
    subject(:component) { described_class.new(settings, capabilities, agent_settings, logger: logger) }

    after do
      component.shutdown!
    end

    context 'worker' do
      let(:worker) { component.instance_eval { @worker } }
      let(:client) { double }
      let(:transport_v7) { double }
      let(:negotiation) { double }

      before do
        expect(Datadog::Core::Remote::Transport::HTTP).to receive(:v7).and_return(transport_v7)
        expect(Datadog::Core::Remote::Client).to receive(:new).and_return(client)
        allow(Datadog::Core::Remote::Negotiation).to receive(:new).and_return(negotiation)

        expect(worker).to receive(:start).and_call_original
        expect(worker).to receive(:stop).and_call_original
      end

      context 'when client sync succeeds' do
        before do
          expect(negotiation).to receive(:endpoint?).and_return(true)
          expect(worker).to receive(:call).and_call_original
          expect(client).to receive(:sync).and_return(nil)
        end

        it 'does not log any error' do
          expect(logger).to_not receive(:error)

          component.barrier(:once)
        end
      end

      context 'when client sync raises' do
        before do
          expect(negotiation).to receive(:endpoint?).and_return(true)
          expect(worker).to receive(:call).and_call_original
          expect(client).to receive(:sync).and_raise(exception, 'test')
          allow(logger).to receive(:error).and_return(nil)
        end

        context 'StandardError' do
          let(:second_client) { double }
          let(:exception) { Class.new(StandardError) }

          it 'logs an error' do
            allow(Datadog::Core::Remote::Client).to receive(:new).and_return(client)

            expect(logger).to receive(:error).and_return(nil)

            component.barrier(:once)
          end

          it 'catches exceptions' do
            allow(Datadog::Core::Remote::Client).to receive(:new).and_return(client)

            # if the error is uncaught it will crash the test, so a mere passing is good

            component.barrier(:once)
          end

          it 'creates a new client' do
            expect(Datadog::Core::Remote::Client).to receive(:new).and_return(second_client)

            expect(component.client.object_id).to eql(client.object_id)

            component.barrier(:once)

            expect(component.client.object_id).to eql(second_client.object_id)
          end

          it 'resets the negotiation object' do
            allow(Datadog::Core::Remote::Client).to receive(:new).and_return(second_client)

            component.barrier(:once)

            expect(Datadog::Core::Remote::Negotiation).to have_received(:new).twice
          end
        end

        context 'Client::SyncError' do
          let(:exception) { Class.new(Datadog::Core::Remote::Client::SyncError) }

          it 'logs an error' do
            allow(Datadog::Core::Remote::Client).to receive(:new).and_return(client)

            expect(logger).to receive(:error).and_return(nil)

            component.barrier(:once)
          end

          it 'catches exceptions' do
            allow(Datadog::Core::Remote::Client).to receive(:new).and_return(client)

            # if the error is uncaught it will crash the test, so a mere passing is good

            component.barrier(:once)
          end

          it 'does not creates a new client' do
            expect(Datadog::Core::Remote::Client).to_not receive(:new)

            expect(component.client.object_id).to eql(client.object_id)

            component.barrier(:once)

            expect(component.client.object_id).to eql(client.object_id)
          end
        end
      end
    end
  end

  describe '#start' do
    subject(:start) { component.start }
    after { component.shutdown! }

    it { expect { start }.to change { component.started? }.from(false).to(true) }

    it 'does not wait for first sync' do
      expect(component.client).to_not receive(:sync)
      start
    end

    context 'when already started' do
      before { component.start }

      it { expect { start }.to_not change { component.started? }.from(true) }
    end
  end

  describe '#started?' do
    subject(:started?) { component.started? }

    context 'before start' do
      it { is_expected.to eq(false) }
    end

    context 'after start' do
      before { component.start }
      after { component.shutdown! }

      it { is_expected.to eq(true) }

      context 'then shutdown' do
        before { component.shutdown! }

        it { is_expected.to eq(false) }
      end
    end
  end
end

RSpec.describe Datadog::Core::Remote::Component::Barrier do
  let(:delay) { 1.0 }
  let(:record) { [] }
  let(:timeout) { nil }
  let(:instance_timeout) { nil }

  subject(:barrier) { described_class.new(instance_timeout) }

  shared_context('lifter thread') do
    let(:thr) do
      Thread.new do
        loop do
          sleep delay
          record << :lift
          barrier.lift
        end
      end
    end

    before do
      record
      thr.run
    end

    after do
      thr.kill
      thr.join
    end
  end

  describe '#initialize' do
    it 'accepts one argument' do
      expect { described_class.new(instance_timeout) }.to_not raise_error
    end

    it 'accepts zero argument' do
      expect { described_class.new }.to_not raise_error
    end
  end

  describe '#lift' do
    context 'without waiters' do
      it 'does not block' do
        record << :one
        barrier.lift
        record << :two

        expect(record).to eq [:one, :two]
      end
    end

    context 'with waiters' do
      it 'unblocks waiters' do
        skip('Known flaky (assertion below sometimes fails with timeout)')

        waiter_thread = Thread.new(record) do |record|
          record << :one
          # Failures:
          #
          #   1) Datadog::Core::Remote::Component::Barrier#lift with waiters unblocks waiters
          #      Failure/Error: expect(barrier.wait_once).to eq :lift
          #
          #        expected: :lift
          #             got: :timeout
          #
          #        (compared using ==)
          #
          #        Diff:
          #        @@ -1 +1 @@
          #        -:lift
          #        +:timeout
          #      # ./spec/datadog/core/remote/component_spec.rb:263:in `block (5 levels) in <top (required)>'
          #      # ./spec/spec_helper.rb:254:in `block in initialize'
          expect(barrier.wait_once).to eq :lift
          record << :two
        end.run

        sleep delay

        record << :lift
        barrier.lift
        waiter_thread.join

        expect(record).to eq [:one, :lift, :two]
      end
    end
  end

  describe '#wait_once' do
    include_context 'lifter thread'

    it 'blocks once' do
      record << :one
      expect(barrier.wait_once).to eq :lift
      record << :two

      expect(record).to eq [:one, :lift, :two]
    end

    it 'blocks only once' do
      record << :one
      expect(barrier.wait_once).to eq :lift
      record << :two
      expect(barrier.wait_once).to eq :pass
      record << :three

      expect(record).to eq [:one, :lift, :two, :three]
    end

    context('with a local timeout') do
      let(:timeout) { delay / 4 }

      context('shorter than lift') do
        it 'unblocks on timeout' do
          record << :one
          expect(barrier.wait_once(timeout)).to eq :timeout
          record << :two
          expect(barrier.wait_once(timeout)).to eq :pass
          record << :three

          expect(record).to eq [:one, :two, :three]
        end
      end

      context('longer than lift') do
        let(:timeout) { delay * 2 }

        it 'unblocks before timeout' do
          record << :one
          expect(barrier.wait_once(timeout)).to eq :lift
          record << :two
          expect(barrier.wait_once(timeout)).to eq :pass
          record << :three

          expect(record).to eq [:one, :lift, :two, :three]
        end
      end

      context('and an instance timeout') do
        let(:instance_timeout) { delay * 2 }

        it 'prefers the local timeout' do
          record << :one
          expect(barrier.wait_once(timeout)).to eq :timeout
          record << :two
          expect(barrier.wait_once(timeout)).to eq :pass
          record << :three

          expect(record).to eq [:one, :two, :three]
        end
      end
    end

    context('with an instance timeout') do
      let(:instance_timeout) { delay / 4 }

      it 'unblocks on timeout' do
        record << :one
        expect(barrier.wait_once).to eq :timeout
        record << :two
        expect(barrier.wait_once).to eq :pass
        record << :three

        expect(record).to eq [:one, :two, :three]
      end
    end
  end
end
