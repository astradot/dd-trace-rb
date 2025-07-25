require "datadog/profiling/spec_helper"

require "datadog/profiling/http_transport"
require "datadog/profiling"

require "json"
require "socket"
require "webrick"

# Design note for this class's specs: from the Ruby code side, we're treating the `_native_` methods as an API
# between the Ruby code and the native methods, and thus in this class we have a bunch of tests to make sure the
# native methods are invoked correctly.
#
# We also have "integration" specs, where we exercise the Ruby code together with the C code and libdatadog to ensure
# that things come out of libdatadog as we expected.
RSpec.describe Datadog::Profiling::HttpTransport do
  before { skip_if_profiling_not_supported(self) }

  subject(:http_transport) do
    described_class.new(
      agent_settings: agent_settings,
      site: site,
      api_key: api_key,
      upload_timeout_seconds: upload_timeout_seconds,
    )
  end

  let(:agent_settings) do
    Datadog::Core::Configuration::AgentSettings.new(
      adapter: adapter,
      uds_path: uds_path,
      ssl: ssl,
      hostname: hostname,
      port: port,
      timeout_seconds: nil
    )
  end
  let(:adapter) { Datadog::Core::Configuration::Ext::Agent::HTTP::ADAPTER }
  let(:uds_path) { nil }
  let(:ssl) { false }
  let(:hostname) { "192.168.0.1" }
  let(:port) { "12345" }
  let(:site) { nil }
  let(:api_key) { nil }
  let(:upload_timeout_seconds) { 10 }

  let(:flush) do
    Datadog::Profiling::Flush.new(
      start: start,
      finish: finish,
      encoded_profile: encoded_profile,
      code_provenance_file_name: code_provenance_file_name,
      code_provenance_data: code_provenance_data,
      tags_as_array: tags_as_array,
      internal_metadata: {no_signals_workaround_enabled: true},
      info_json: info_json,
    )
  end
  let(:serialize_result) { Datadog::Profiling::StackRecorder.for_testing.serialize }
  let(:start) { serialize_result[0] }
  let(:finish) { serialize_result[1] }
  let(:encoded_profile) { serialize_result[2] }
  let(:start_timestamp) { start.iso8601(9) }
  let(:end_timestamp) { finish.iso8601(9) }
  let(:pprof_file_name) { "profile.pprof" }
  let(:code_provenance_file_name) { "the_code_provenance_file_name.json" }
  let(:code_provenance_data) { "the_code_provenance_data" }
  let(:tags_as_array) { [%w[tag_a value_a], %w[tag_b value_b]] }
  let(:info_json) do
    JSON.generate(
      {
        application: {
          start_time: "2024-01-24T11:17:22Z"
        },
        runtime: {
          engine: "ruby"
        },
      }
    )
  end
  # Like above but with string keys (JSON parsing unsymbolizes keys by default)
  let(:info_string_keys) do
    {
      "application" => {
        "start_time" => "2024-01-24T11:17:22Z"
      },
      "runtime" => {
        "engine" => "ruby"
      },
    }
  end

  describe "#initialize" do
    context "when agent_settings are provided" do
      it "picks the :agent working mode for the exporter" do
        expect(described_class)
          .to receive(:_native_validate_exporter)
          .with([:agent, "http://192.168.0.1:12345/"])
          .and_return([:ok, nil])

        http_transport
      end

      context "when ssl is enabled" do
        let(:ssl) { true }

        it "picks the :agent working mode with https reporting" do
          expect(described_class)
            .to receive(:_native_validate_exporter)
            .with([:agent, "https://192.168.0.1:12345/"])
            .and_return([:ok, nil])

          http_transport
        end
      end

      context "when agent_settings requests a unix domain socket" do
        let(:adapter) { Datadog::Core::Transport::Ext::UnixSocket::ADAPTER }
        let(:uds_path) { "/var/run/datadog/apm.socket" }

        it "picks the :agent working mode with unix domain stocket reporting" do
          expect(described_class)
            .to receive(:_native_validate_exporter)
            .with([:agent, "unix:///var/run/datadog/apm.socket"])
            .and_return([:ok, nil])

          http_transport
        end
      end

      context "when hostname is an ipv6 address" do
        let(:hostname) { "1234:1234::1" }

        it "provides the correct ipv6 address-safe url to the exporter" do
          expect(described_class)
            .to receive(:_native_validate_exporter)
            .with([:agent, "http://[1234:1234::1]:12345/"])
            .and_return([:ok, nil])

          http_transport
        end
      end
    end

    context "when additionally site and api_key are provided" do
      let(:site) { "test.datadoghq.com" }
      let(:api_key) { SecureRandom.uuid }

      it "ignores them and picks the :agent working mode using the agent_settings" do
        expect(described_class)
          .to receive(:_native_validate_exporter)
          .with([:agent, "http://192.168.0.1:12345/"])
          .and_return([:ok, nil])

        http_transport
      end

      context "when agentless mode is allowed" do
        around do |example|
          ClimateControl.modify("DD_PROFILING_AGENTLESS" => "true") do
            example.run
          end
        end

        it "picks the :agentless working mode with the given site and api key" do
          expect(described_class)
            .to receive(:_native_validate_exporter)
            .with([:agentless, site, api_key])
            .and_return([:ok, nil])

          http_transport
        end
      end
    end

    context "when an invalid configuration is provided" do
      let(:hostname) { "this:is:not:a:valid:hostname!!!!" }

      it do
        expect { http_transport }.to raise_error(ArgumentError, /Failed to initialize transport/)
      end
    end
  end

  describe "#export" do
    subject(:export) { http_transport.export(flush) }

    it "calls the native export method with the data from the flush" do
      upload_timeout_milliseconds = 10_000

      expect(described_class).to receive(:_native_do_export).with(
        kind_of(Array), # exporter_configuration
        upload_timeout_milliseconds,
        flush,
      ).and_return([:ok, 200])

      export
    end

    context "when successful" do
      before do
        expect(described_class).to receive(:_native_do_export).and_return([:ok, 200])
        serialize_result # Trigger the serialization
      end

      it "logs a debug message" do
        expect(Datadog.logger).to receive(:debug).with("Successfully reported profiling data")

        export
      end

      it { is_expected.to be true }
    end

    context "when failed" do
      context "with a http status code" do
        before do
          expect(described_class).to receive(:_native_do_export).and_return([:ok, 500])
          allow(Datadog.logger).to receive(:warn)
          allow(Datadog::Core::Telemetry::Logger).to receive(:error)
        end

        it "logs an error message" do
          expect(Datadog.logger).to receive(:warn).with(
            "Failed to report profiling data (agent: http://192.168.0.1:12345/): " \
            "server returned unexpected HTTP 500 status code"
          )

          export
        end

        it "sends a telemetry log" do
          expect(Datadog::Core::Telemetry::Logger).to receive(:error).with(
            "Failed to report profiling data: unexpected HTTP 500 status code"
          )

          export
        end

        it { is_expected.to be false }
      end

      context "with a failure without an http status code" do
        before do
          expect(described_class).to receive(:_native_do_export).and_return([:error, "Some error message"])
          allow(Datadog.logger).to receive(:warn)
          allow(Datadog::Core::Telemetry::Logger).to receive(:error)
        end

        it "logs an error message" do
          expect(Datadog.logger).to receive(:warn)
            .with("Failed to report profiling data (agent: http://192.168.0.1:12345/): Some error message")

          export
        end

        it "sends a telemetry log" do
          expect(Datadog::Core::Telemetry::Logger).to receive(:error).with(
            "Failed to report profiling data"
          )

          export
        end

        it { is_expected.to be false }
      end
    end
  end

  describe "#exporter_configuration" do
    it "returns the current exporter configuration" do
      expect(http_transport.exporter_configuration).to eq [:agent, "http://192.168.0.1:12345/"]
    end
  end

  context "integration testing" do
    shared_context "HTTP server" do
      http_server do |http_server|
        http_server.mount_proc('/', &server_proc)
      end
      let(:hostname) { "127.0.0.1" }
      let(:server_proc) do
        proc do |req, res|
          messages << req.tap { req.body } # Read body, store message before socket closes.
          res.body = "{}"
        end
      end

      let(:messages) { [] }
    end

    include_context "HTTP server"

    let(:request) { messages.first }

    let(:hostname) { "127.0.0.1" }
    let(:port) { http_server_port }

    let!(:encoded_profile_bytes) { encoded_profile._native_bytes }

    shared_examples "correctly reports profiling data" do
      let(:expected_data_in_payload) {
        {
          "attachments" => contain_exactly(pprof_file_name, code_provenance_file_name),
          "tags_profiler" => start_with("tag_a:value_a,tag_b:value_b,runtime_platform:#{RUBY_PLATFORM.split("-").first}"),
          "start" => start_timestamp,
          "end" => end_timestamp,
          "family" => "ruby",
          "version" => "4",
          "endpoint_counts" => nil,
          "internal" => hash_including("no_signals_workaround_enabled" => true),
          "info" => info_string_keys,
        }
      }

      it "correctly reports profiling data" do
        success = http_transport.export(flush)

        expect(success).to be true

        expect(request.header).to include(
          "content-type" => [%r{^multipart/form-data; boundary=(.+)}],
          "dd-evp-origin" => ["dd-trace-rb"],
          "dd-evp-origin-version" => [Datadog::VERSION::STRING],
        )

        # check body
        boundary = request["content-type"][%r{^multipart/form-data; boundary=(.+)}, 1]
        body = WEBrick::HTTPUtils.parse_form_data(StringIO.new(request.body), boundary)
        event_data = JSON.parse(body.fetch("event"))

        expect(event_data).to match(expected_data_in_payload)
      end

      it "reports the payload as lz4-compressed files, that get automatically compressed by libdatadog" do
        success = http_transport.export(flush)

        expect(success).to be true

        boundary = request["content-type"][%r{^multipart/form-data; boundary=(.+)}, 1]
        body = WEBrick::HTTPUtils.parse_form_data(StringIO.new(request.body), boundary)

        # The pprof data is compressed in the datadog serializer, nothing to do
        expect(body.fetch(pprof_file_name)).to eq encoded_profile_bytes
        # This one needs to be compressed
        expect(LZ4.decode(body.fetch(code_provenance_file_name))).to eq code_provenance_data
      end
    end

    include_examples "correctly reports profiling data"

    it "exports data via http to the agent url" do
      http_transport.export(flush)

      expect(request.request_uri.to_s).to eq "http://127.0.0.1:#{port}/profiling/v1/input"
    end

    context "when code provenance data is not available" do
      let(:code_provenance_data) { nil }

      it "correctly reports profiling data but does not include code provenance" do
        success = http_transport.export(flush)

        expect(success).to be true

        # check body
        boundary = request["content-type"][%r{^multipart/form-data; boundary=(.+)}, 1]
        body = WEBrick::HTTPUtils.parse_form_data(StringIO.new(request.body), boundary)
        event_data = JSON.parse(body.fetch("event"))

        expect(event_data).to match(expected_data_in_payload.merge("attachments" => [pprof_file_name]))

        expect(body[code_provenance_file_name]).to be nil
      end
    end

    context "via unix domain socket" do
      define_http_server_uds do |http_server|
        http_server.mount_proc('/', &server_proc)
      end
      let(:adapter) { Datadog::Core::Transport::Ext::UnixSocket::ADAPTER }
      let(:uds_path) { uds_socket_path }

      include_examples "correctly reports profiling data"
    end

    context "when agent is down" do
      before do
        http_server.shutdown
        @server_thread.join
      end

      it "logs an error" do
        expect(Datadog.logger).to receive(:warn).with(/ddog_prof_Exporter_send failed/)
        expect(Datadog::Core::Telemetry::Logger).to receive(:error).with("Failed to report profiling data")

        http_transport.export(flush)
      end
    end

    context "when request times out" do
      let(:upload_timeout_seconds) { 0.001 }
      let(:server_proc) { proc { sleep 0.05 } }

      it "logs an error" do
        expect(Datadog.logger).to receive(:warn).with(/timed out/)
        expect(Datadog::Core::Telemetry::Logger).to receive(:error).with("Failed to report profiling data")

        http_transport.export(flush)
      end
    end

    context "when server returns a 4xx failure" do
      let(:server_proc) { proc { |_req, res| res.status = 418 } }

      it "logs an error" do
        expect(Datadog.logger).to receive(:warn).with(/unexpected HTTP 418/)
        expect(Datadog::Core::Telemetry::Logger)
          .to receive(:error).with("Failed to report profiling data: unexpected HTTP 418 status code")

        http_transport.export(flush)
      end
    end

    context "when server returns a 5xx failure" do
      let(:server_proc) { proc { |_req, res| res.status = 503 } }

      it "logs an error" do
        expect(Datadog.logger).to receive(:warn).with(/unexpected HTTP 503/)
        expect(Datadog::Core::Telemetry::Logger)
          .to receive(:error).with("Failed to report profiling data: unexpected HTTP 503 status code")

        http_transport.export(flush)
      end
    end

    context "when tags contains invalid tags" do
      let(:tags_as_array) { [%w[:invalid invalid:], %w[valid1 valid1], %w[valid2 valid2]] }

      before do
        allow(Datadog.logger).to receive(:warn)
      end

      it "reports using the valid tags and ignores the invalid tags" do
        success = http_transport.export(flush)

        expect(success).to be true

        boundary = request["content-type"][%r{^multipart/form-data; boundary=(.+)}, 1]
        body = WEBrick::HTTPUtils.parse_form_data(StringIO.new(request.body), boundary)
        event_data = JSON.parse(body.fetch("event"))

        expect(event_data["tags_profiler"]).to start_with("valid1:valid1,valid2:valid2,runtime_platform:")
      end

      it "logs a warning" do
        expect(Datadog.logger).to receive(:warn).with(/Failed to convert tag/)

        http_transport.export(flush)
      end
    end

    describe "cancellation behavior" do
      let!(:request_received_queue) { Queue.new }
      let!(:request_finish_queue) { Queue.new }

      let(:upload_timeout_seconds) { 123_456_789 } # Set on purpose so this test will either pass or hang
      let(:server_proc) do
        proc do
          request_received_queue << true
          request_finish_queue.pop
        end
      end

      after do
        request_finish_queue << true
      end

      # As the describe above says, here we're testing the cancellation behavior. If cancellation is not correctly
      # implemented, then `ddog_ProfileExporter_send` will block until `upload_timeout_seconds` is hit and
      # nothing we could do on the Ruby VM side will interrupt it.
      # If it is correctly implemented, then the `exporter_thread.kill` will cause
      # `ddog_ProfileExporter_send` to return immediately and this test will quickly finish.
      it "can be interrupted" do
        exporter_thread = Thread.new { http_transport.export(flush) }
        request_received_queue.pop

        expect(exporter_thread.status).to eq "sleep"

        exporter_thread.kill
        exporter_thread.join

        expect(exporter_thread.status).to be false
      end
    end
  end
end
