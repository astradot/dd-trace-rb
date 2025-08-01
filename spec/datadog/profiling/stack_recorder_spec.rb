require "datadog/profiling/spec_helper"
require "datadog/profiling/stack_recorder"

require "objspace"

RSpec.describe Datadog::Profiling::StackRecorder do
  before { skip_if_profiling_not_supported(self) }

  let(:numeric_labels) { [] }
  let(:cpu_time_enabled) { true }
  let(:alloc_samples_enabled) { true }
  # Disabling these by default since they require some extra setup and produce separate samples.
  # Enabling this is tested in a particular context below.
  let(:heap_samples_enabled) { false }
  let(:heap_size_enabled) { false }
  let(:heap_sample_every) { 1 }
  let(:timeline_enabled) { true }
  let(:heap_clean_after_gc_enabled) { true }

  subject(:stack_recorder) do
    described_class.new(
      cpu_time_enabled: cpu_time_enabled,
      alloc_samples_enabled: alloc_samples_enabled,
      heap_samples_enabled: heap_samples_enabled,
      heap_size_enabled: heap_size_enabled,
      heap_sample_every: heap_sample_every,
      timeline_enabled: timeline_enabled,
      heap_clean_after_gc_enabled: heap_clean_after_gc_enabled,
    )
  end

  # NOTE: A lot of libdatadog integration behaviors are tested in the Collectors::Stack specs, since we need actual
  # samples in order to observe what comes out of libdatadog

  def active_slot
    described_class::Testing._native_active_slot(stack_recorder)
  end

  def slot_one_mutex_locked?
    described_class::Testing._native_slot_one_mutex_locked?(stack_recorder)
  end

  def slot_two_mutex_locked?
    described_class::Testing._native_slot_two_mutex_locked?(stack_recorder)
  end

  def is_object_recorded?(obj_id)
    described_class::Testing._native_is_object_recorded?(stack_recorder, obj_id)
  end

  def recorder_after_gc_step
    described_class::Testing._native_recorder_after_gc_step(stack_recorder)
  end

  describe "#initialize" do
    describe "locking behavior" do
      it "sets slot one as the active slot" do
        expect(active_slot).to be 1
      end

      it "keeps the slot one mutex unlocked" do
        expect(slot_one_mutex_locked?).to be false
      end

      it "keeps the slot two mutex locked" do
        expect(slot_two_mutex_locked?).to be true
      end
    end
  end

  describe "#serialize" do
    subject(:serialize) { stack_recorder.serialize }

    let(:start) { serialize[0] }
    let(:finish) { serialize[1] }
    let(:encoded_pprof) { serialize[2] }
    let(:profile_stats) { serialize[3] }

    let(:decoded_profile) { decode_profile(encoded_pprof) }

    it "debug logs profile information" do
      message = nil

      expect(Datadog.logger).to receive(:debug) do |&message_block|
        message = message_block.call
      end

      serialize

      expect(message).to include start.iso8601
      expect(message).to include finish.iso8601
    end

    describe "locking behavior" do
      context "when slot one was the active slot" do
        it "sets slot two as the active slot" do
          expect { serialize }.to change { active_slot }.from(1).to(2)
        end

        it "locks the slot one mutex" do
          expect { serialize }.to change { slot_one_mutex_locked? }.from(false).to(true)
        end

        it "unlocks the slot two mutex" do
          expect { serialize }.to change { slot_two_mutex_locked? }.from(true).to(false)
        end
      end

      context "when slot two was the active slot" do
        before do
          # Trigger serialization once, so that active slots get flipped
          stack_recorder.serialize
        end

        it "sets slot one as the active slot" do
          expect { serialize }.to change { active_slot }.from(2).to(1)
        end

        it "unlocks the slot one mutex" do
          expect { serialize }.to change { slot_one_mutex_locked? }.from(true).to(false)
        end

        it "locks the slot two mutex" do
          expect { serialize }.to change { slot_two_mutex_locked? }.from(false).to(true)
        end
      end
    end

    context "when the profile is empty" do
      it "uses the current time as the start and finish time" do
        before_serialize = Time.now.utc
        serialize
        after_serialize = Time.now.utc

        expect(start).to be_between(before_serialize, after_serialize)
        expect(finish).to be_between(before_serialize, after_serialize)
        expect(start).to be <= finish
      end

      describe "profile types configuration" do
        let(:cpu_time_enabled) { true }
        let(:alloc_samples_enabled) { true }
        let(:heap_samples_enabled) { true }
        let(:heap_size_enabled) { true }
        let(:timeline_enabled) { true }
        let(:all_profile_types) do
          {
            "cpu-time" => "nanoseconds",
            "cpu-samples" => "count",
            "wall-time" => "nanoseconds",
            "alloc-samples" => "count",
            "alloc-samples-unscaled" => "count",
            "heap-live-samples" => "count",
            "heap-live-size" => "bytes",
            "timeline" => "nanoseconds",
          }
        end

        def profile_types_without(*types)
          result = all_profile_types.dup
          types.each { |type| result.delete(type) { raise "Missing key" } }
          result
        end

        context "when all profile types are enabled" do
          it "returns a pprof with the configured sample types" do
            expect(sample_types_from(decoded_profile)).to eq(all_profile_types)
          end
        end

        context "when cpu-time is disabled" do
          let(:cpu_time_enabled) { false }

          it "returns a pprof without the cpu-type type" do
            expect(sample_types_from(decoded_profile)).to eq(profile_types_without("cpu-time"))
          end
        end

        context "when alloc-samples is disabled" do
          let(:alloc_samples_enabled) { false }

          it "returns a pprof without the alloc-samples type" do
            expect(sample_types_from(decoded_profile))
              .to eq(profile_types_without("alloc-samples", "alloc-samples-unscaled"))
          end
        end

        context "when heap-live-samples is disabled" do
          let(:heap_samples_enabled) { false }

          it "returns a pprof without the heap-live-samples type" do
            expect(sample_types_from(decoded_profile)).to eq(profile_types_without("heap-live-samples"))
          end
        end

        context "when heap-live-size is disabled" do
          let(:heap_size_enabled) { false }

          it "returns a pprof without the heap-live-size type" do
            expect(sample_types_from(decoded_profile)).to eq(profile_types_without("heap-live-size"))
          end
        end

        context "when timeline is disabled" do
          let(:timeline_enabled) { false }

          it "returns a pprof without the timeline type" do
            expect(sample_types_from(decoded_profile)).to eq(profile_types_without("timeline"))
          end
        end

        context "when all optional types are disabled" do
          let(:cpu_time_enabled) { false }
          let(:alloc_samples_enabled) { false }
          let(:heap_samples_enabled) { false }
          let(:heap_size_enabled) { false }
          let(:timeline_enabled) { false }

          it "returns a pprof without the optional types" do
            expect(sample_types_from(decoded_profile)).to eq(
              "cpu-samples" => "count",
              "wall-time" => "nanoseconds",
            )
          end
        end
      end

      it "returns an empty pprof" do
        expect(decoded_profile).to have_attributes(
          sample: [],
          mapping: [],
          location: [],
          function: [],
          drop_frames: 0,
          keep_frames: 0,
          time_nanos: Datadog::Core::Utils::Time.as_utc_epoch_ns(start),
          period_type: nil,
          period: 0,
          comment: [],
        )
      end

      context "when requesting multiple serializations of empty profiles" do
        it "correctly sets the profile start timestamp in libdatadog" do
          # The `start` timestamp returned is tracked locally by us. This test validates that the actual profile
          # matches it, e.g. that we're passing it along correctly to libdatadog.
          start_timestamps = []
          4.times do
            start, _, profile = stack_recorder.serialize
            expect(decode_profile(profile).time_nanos).to eq(Datadog::Core::Utils::Time.as_utc_epoch_ns(start))

            start_timestamps << start
          end
          expect(start_timestamps.sort).to eq(start_timestamps) # No later timestamp should come before an earlier one
        end
      end

      it "returns stats reporting no recorded samples" do
        expect(profile_stats).to match(
          hash_including(
            recorded_samples: 0,
            serialization_time_ns: be > 0,
            heap_iteration_prep_time_ns: be >= 0,
            heap_profile_build_time_ns: be >= 0,
          )
        )
      end

      def sample_types_from(decoded_profile)
        strings = decoded_profile.string_table
        decoded_profile.sample_type.map { |sample_type| [strings[sample_type.type], strings[sample_type.unit]] }.to_h
      end
    end

    context "when profile has a sample" do
      let(:metric_values) do
        {
          "cpu-time" => 123,
          "cpu-samples" => 456,
          "wall-time" => 789,
          "alloc-samples" => 4242,
          "alloc-samples-unscaled" => 2222,
          "timeline" => 1111,
        }
      end
      let(:labels) { {"label_a" => "value_a", "label_b" => "value_b", "state" => "unknown"}.to_a }

      let(:samples) { samples_from_pprof(encoded_pprof) }

      before do
        Datadog::Profiling::Collectors::Stack::Testing
          ._native_sample(Thread.current, stack_recorder, metric_values, labels, numeric_labels)
        expect(samples.size).to be 1
      end

      it "encodes the sample with the metrics provided" do
        expect(samples.first.values)
          .to eq(
            "cpu-time": 123,
            "cpu-samples": 456,
            "wall-time": 789,
            "alloc-samples": 4242,
            "alloc-samples-unscaled": 2222,
            timeline: 1111,
          )
      end

      context "when disabling an optional profile sample type" do
        let(:cpu_time_enabled) { false }

        it "encodes the sample with the metrics provided, ignoring the disabled ones" do
          expect(samples.first.values).to eq(
            "cpu-samples": 456, "wall-time": 789, "alloc-samples": 4242, "alloc-samples-unscaled": 2222, timeline: 1111
          )
        end
      end

      it "encodes the sample with the labels provided" do
        labels = samples.first.labels
        labels.delete(:state) # We test this separately!

        expect(labels).to eq(label_a: "value_a", label_b: "value_b")
      end

      it "does not emit any mappings" do
        expect(decoded_profile.mapping).to be_empty
      end

      it "returns stats reporting one recorded sample" do
        expect(profile_stats).to match(
          hash_including(
            recorded_samples: 1,
            serialization_time_ns: be > 0,
            heap_iteration_prep_time_ns: be >= 0,
            heap_profile_build_time_ns: be >= 0,
          )
        )
      end
    end

    describe "trace endpoint behavior" do
      let(:metric_values) { {"cpu-time" => 101, "cpu-samples" => 1, "wall-time" => 789} }
      let(:samples) { samples_from_pprof(encoded_pprof) }

      it "includes the endpoint for all matching samples taken before and after recording the endpoint" do
        local_root_span_id_with_endpoint = {"local root span id" => 123}
        local_root_span_id_without_endpoint = {"local root span id" => 456}

        sample = proc do |numeric_labels = {}|
          Datadog::Profiling::Collectors::Stack::Testing._native_sample(
            Thread.current, stack_recorder, metric_values, {"state" => "unknown"}.to_a, numeric_labels.to_a
          )
        end

        sample.call
        sample.call(local_root_span_id_without_endpoint)
        sample.call(local_root_span_id_with_endpoint)

        described_class::Testing._native_record_endpoint(stack_recorder, 123, "recorded-endpoint")

        sample.call
        sample.call(local_root_span_id_without_endpoint)
        sample.call(local_root_span_id_with_endpoint)

        expect(samples).to have(6).items # Samples are guaranteed unique since each sample call is on a different line

        labels_without_state = proc { |labels| labels.reject { |key| key == :state } }

        # Other samples have not been changed
        expect(samples.select { |it| labels_without_state.call(it.labels).empty? }).to have(2).items
        expect(
          samples.select do |it|
            labels_without_state.call(it.labels) == {"local root span id": 456}
          end
        ).to have(2).items

        # Matching samples taken before and after recording the endpoint have been changed
        expect(
          samples.select do |it|
            labels_without_state.call(it.labels) ==
              {"local root span id": 123, "trace endpoint": "recorded-endpoint"}
          end
        ).to have(2).items
      end
    end

    describe "heap samples and sizes" do
      let(:sample_rate) { 50 }
      let(:metric_values) do
        {
          "cpu-time" => 101,
          "cpu-samples" => 1,
          "wall-time" => 789,
          "alloc-samples" => sample_rate,
          "timeline" => 42,
          "heap_sample" => true,
        }
      end
      let(:labels) { {"label_a" => "value_a", "label_b" => "value_b", "state" => "unknown"}.to_a }

      let(:a_string) { "a beautiful string" }
      let(:an_array) { (1..100).to_a.compact }
      let(:a_hash) { {"a" => 1, "b" => "2", "c" => true, "d" => Object.new} }

      let(:samples) { samples_from_pprof(encoded_pprof) }

      def sample_allocation(obj)
        # Heap sampling currently requires this 2-step process to first pass data about the allocated object...
        described_class::Testing._native_track_object(stack_recorder, obj, sample_rate, obj.class.name)
        Datadog::Profiling::Collectors::Stack::Testing
          ._native_sample(Thread.current, stack_recorder, metric_values, labels, numeric_labels)
      end

      def introduce_distinct_stacktraces(i, obj)
        if i.even?
          sample_allocation(obj) # standard:disable Style/IdenticalConditionalBranches
        else # rubocop:disable Lint/DuplicateBranch
          sample_allocation(obj) # standard:disable Style/IdenticalConditionalBranches
        end
      end

      before do
        allocations = [a_string, an_array, "a fearsome interpolated string: #{sample_rate}", (-10..-1).to_a, a_hash,
          {"z" => -1, "y" => "-2", "x" => false}, Object.new]
        @num_allocations = 0
        allocations.each_with_index do |obj, i|
          introduce_distinct_stacktraces(i, obj)
          @num_allocations += 1
          GC.start # Force each allocation to be done in its own GC epoch for interesting GC age labels
        end

        allocations.clear # The literals in the previous array are now dangling
        GC.start # And this will clear them, leaving only the non-literals which are still pointed to by the lets

        # NOTE: We've witnessed CI flakiness where some no longer referenced allocations may still be seen as alive
        # after the previous GC.
        # This might be an instance of the issues described in https://bugs.ruby-lang.org/issues/19460
        # and https://bugs.ruby-lang.org/issues/19041. We didn't get to the bottom of the
        # reason but it might be that some machine context/register ends up still pointing to
        # that last entry and thus manages to get it marked in the first GC.
        # To reduce the likelihood of this happening we'll:
        # * Allocate some more stuff and clear again
        # * Do another GC
        allocations = ["another fearsome interpolated string: #{sample_rate}", (-20..-10).to_a,
          {"a" => 1, "b" => "2", "c" => true}, Object.new]
        allocations.clear
        GC.start
      end

      after do |example|
        # This is here to facilitate troubleshooting when this test fails. Otherwise
        # it's very hard to understand what may be happening.
        if example.exception
          puts("Heap recorder debugging info:")
          puts(described_class::Testing._native_debug_heap_recorder(stack_recorder))
        end
      end

      context "when disabled" do
        let(:heap_samples_enabled) { false }
        let(:heap_size_enabled) { false }

        it "are ommitted from the profile" do
          # We sample from 2 distinct locations
          expect(samples.size).to eq(2)
          expect(samples.select { |s| s.values.key?("heap-live-samples") }).to be_empty
          expect(samples.select { |s| s.values.key?("heap-live-size") }).to be_empty
        end
      end

      context "when enabled" do
        let(:heap_samples_enabled) { true }
        let(:heap_size_enabled) { true }

        let(:heap_samples) do
          samples.select { |s| s.value?(:"heap-live-samples") }
        end

        let(:non_heap_samples) do
          samples.reject { |s| s.value?(:"heap-live-samples") }
        end

        before do
          skip "Heap profiling is only supported on Ruby >= 2.7" if RUBY_VERSION < "2.7"
        end

        it "include the stack and sample counts for the objects still left alive" do
          # There should be 3 different allocation class labels so we expect 3 different heap samples
          expect(heap_samples.size).to eq(3)

          expect(heap_samples.map { |s| s.labels[:"allocation class"] }).to include("String", "Array", "Hash")
          expect(heap_samples.map(&:labels)).to all(match(hash_including("gc gen age": be_a(Integer).and(be >= 0))))
        end

        it "include accurate object sizes" do
          string_sample = heap_samples.find { |s| s.labels[:"allocation class"] == "String" }
          expect(string_sample.values[:"heap-live-size"]).to eq(ObjectSpace.memsize_of(a_string) * sample_rate)

          array_sample = heap_samples.find { |s| s.labels[:"allocation class"] == "Array" }
          expect(array_sample.values[:"heap-live-size"]).to eq(ObjectSpace.memsize_of(an_array) * sample_rate)

          hash_sample = heap_samples.find { |s| s.labels[:"allocation class"] == "Hash" }
          expect(hash_sample.values[:"heap-live-size"]).to eq(ObjectSpace.memsize_of(a_hash) * sample_rate)
        end

        it "include accurate object ages" do
          string_sample = heap_samples.find { |s| s.labels[:"allocation class"] == "String" }
          string_age = string_sample.labels[:"gc gen age"]

          array_sample = heap_samples.find { |s| s.labels[:"allocation class"] == "Array" }
          array_age = array_sample.labels[:"gc gen age"]

          hash_sample = heap_samples.find { |s| s.labels[:"allocation class"] == "Hash" }
          hash_age = hash_sample.labels[:"gc gen age"]

          unique_sorted_ages = [string_age, array_age, hash_age].uniq.sort
          # Expect all ages to be different and to be in the reverse order of allocation
          # Last to allocate => Lower age
          expect(unique_sorted_ages).to match([hash_age, array_age, string_age])

          # Validate that the age of the newest object makes sense.
          # * We force a GC after each allocation and the hash sample should correspond to
          #   the 5th allocation in 7 (which means we expect at least 3 GC after all allocations
          #   are done)
          # * We forced 1 extra GC at the end of our before (+1)
          # * This test isn't memory intensive otherwise so lets give us an extra margin of 1 GC to account for any
          #   GC out of our control
          expect(hash_age).to be_between(4, 5)
        end

        it "keeps on reporting accurate samples for other profile types" do
          expect(non_heap_samples.size).to eq(2)

          summed_values = {}
          non_heap_samples.each do |s|
            s.values.each_pair do |k, v|
              summed_values[k] = (summed_values[k] || 0) + v
            end
          end

          # We use the same metric_values in all sample calls in before. So we'd expect
          # the summed values to match `@num_allocations * metric_values[profile-type]`
          # for each profile-type there in.
          expected_summed_values = {"heap-live-samples": 0, "heap-live-size": 0, "alloc-samples-unscaled": 0}
          metric_values.each_pair do |k, v|
            next if k == "heap_sample" # This is not a metric, ignore it

            expected_summed_values[k.to_sym] = v * @num_allocations
          end

          expect(summed_values).to eq(expected_summed_values)
        end

        it "does not include samples with age = 0" do
          test_num_allocated_objects = 123
          test_num_age_bigger_0 = 57
          live_objects = Array.new(test_num_allocated_objects)

          allocator_proc = proc { |i|
            live_objects[i] = "this is string number #{i}"
            sample_allocation(live_objects[i])
          }

          sample_line = __LINE__ - 3

          # First allocate a bunch of objects with age > 0. We expect to
          # see these at the end
          test_num_age_bigger_0.times(&allocator_proc)
          # Force the above allocations to have gc age > 0
          GC.start

          begin
            # Need to disable GC during this entire stretch to ensure rb_gc_count is
            # the same between sample_allocation and pprof serialization.
            GC.disable

            # Allocate another set of objects that will necessarily have age = 0 since
            # we disabled GC immediate before and will only enable it at test's end.
            (test_num_age_bigger_0..test_num_allocated_objects).each(&allocator_proc)

            # Grab all exported heap samples and sum their values
            sum_exported_heap_samples = heap_samples
              .select { |s| s.has_location?(path: __FILE__, line: sample_line) }
              .map { |s| s.values[:"heap-live-samples"] }
              .reduce(:+)

            # Multiply expectation by sample_rate to be able to compare with weighted samples
            # We expect total exported sum to match the weighted samples with age > 0
            expect(sum_exported_heap_samples).to be test_num_age_bigger_0 * sample_rate
          ensure
            # Whatever happens, make sure we reenable GC
            GC.enable
          end
        end

        it "tracks allocations that happen concurrently with a long serialization" do
          described_class::Testing._native_start_fake_slow_heap_serialization(stack_recorder)

          test_num_allocated_object = 123
          live_objects = Array.new(test_num_allocated_object)

          test_num_allocated_object.times do |i|
            live_objects[i] = "this is string number #{i}"
            sample_allocation(live_objects[i])
          end

          sample_line = __LINE__ - 3

          described_class::Testing._native_end_fake_slow_heap_serialization(stack_recorder)

          GC.start # Force a GC so the live_objects above have age > 0 and show up in heap samples

          relevant_sample = heap_samples.find { |s| s.has_location?(path: __FILE__, line: sample_line) }
          expect(relevant_sample).not_to be nil
          expect(relevant_sample.values[:"heap-live-samples"]).to eq test_num_allocated_object * sample_rate
        end

        it "contribute to recorded samples stats" do
          test_num_allocated_object = 123
          live_objects = Array.new(test_num_allocated_object)

          test_num_allocated_object.times do |i|
            live_objects[i] = "this is string number #{i}"
            sample_allocation(live_objects[i])
          end

          GC.start # Force a GC so the live_objects above have age > 0 and show up in heap samples

          # All allocations done in the before + all those done here
          expected_allocation_samples = @num_allocations + test_num_allocated_object
          # a_string, an_array, a_hash plus all the strings in live_objects
          expected_heap_samples = 3 + test_num_allocated_object

          expect(profile_stats).to match(
            hash_including(
              recorded_samples: expected_allocation_samples + expected_heap_samples,
              heap_iteration_prep_time_ns: be > 0,
              heap_profile_build_time_ns: be > 0,
            )
          )
        end

        it "records stack traces that match the allocations' stack traces" do
          expect(samples.map(&:locations).uniq.size).to be 2
        end

        it "records correct stack traces" do
          unique_heap_stacks = heap_samples.map(&:locations).uniq

          expect(unique_heap_stacks.size).to be 2

          stack1, stack2 = unique_heap_stacks
          unique_line1 = stack1.find { |it| it.base_label == 'introduce_distinct_stacktraces' }
          unique_line2 = stack2.find { |it| it.base_label == 'introduce_distinct_stacktraces' }

          expect(stack1.reject { |it| it == unique_line1 }).to eq(stack2.reject { |it| it == unique_line2 })
          expect(unique_line1.lineno).to be_within(2).of(unique_line2.lineno)
        end

        context "with custom heap sample rate configuration" do
          let(:heap_sample_every) { 2 }

          it "only keeps track of some allocations" do
            # By only sampling every 2nd allocation we only track the odd objects which means our array
            # should be the only heap sample captured (string is index 0, array is index 1, hash is 4)
            expect(heap_samples.size)
              .to eq(1), "Expected one heap sample, got #{heap_samples.size}; heap_samples is #{heap_samples}"

            heap_sample = heap_samples.first
            expect(heap_sample.labels[:"allocation class"]).to eq("Array")
            expect(heap_sample.values[:"heap-live-samples"]).to eq(sample_rate * heap_sample_every)
          end
        end

        # NOTE: This is a regression test that exceptions in end_heap_allocation_recording_with_rb_protect are safely
        # handled by the stack_recorder.
        context "when the heap sampler raises an exception during _native_sample" do
          it "propagates the exception" do
            expect do
              Datadog::Profiling::Collectors::Stack::Testing
                ._native_sample(Thread.current, stack_recorder, metric_values, labels, numeric_labels)
            end.to raise_error(RuntimeError, /Ended a heap recording/)
          end

          it "does not keep the active slot mutex locked" do
            expect(active_slot).to be 1
            expect(slot_one_mutex_locked?).to be false
            expect(slot_two_mutex_locked?).to be true

            begin
              Datadog::Profiling::Collectors::Stack::Testing
                ._native_sample(Thread.current, stack_recorder, metric_values, labels, numeric_labels)
            rescue # rubocop:disable Lint/SuppressedException
            end

            expect(active_slot).to be 1
            expect(slot_one_mutex_locked?).to be false
            expect(slot_two_mutex_locked?).to be true
          end
        end

        describe "#recorder_after_gc_step" do
          def sample_and_clear
            test_object = Object.new
            test_object_id = test_object.object_id
            sample_allocation(test_object)
            # Let's replace the test_object reference with another object, so that the original one can be GC'd
            test_object = Object.new # rubocop:disable Lint/UselessAssignment
            GC.start
            test_object_id
          end

          before do
            GC.disable

            @object_ids = Array.new(4) { sample_and_clear }
          end

          after { GC.enable }

          context 'when heap_clean_after_gc_enabled is true' do
            let(:heap_clean_after_gc_enabled) { true }

            it "clears young dead objects with age 1 and 2, but not older objects" do
              # Every object is still being tracked at this point
              expect(@object_ids.map { |it| is_object_recorded?(it) }).to eq [true, true, true, true]

              recorder_after_gc_step

              # Young objects should no longer be tracked, but older objects are still kept
              expect(@object_ids.map { |it| is_object_recorded?(it) }).to eq [true, true, false, false]

              stack_recorder.serialize

              GC.enable
              GC.start

              # Sanity check: All the objects should've been garbage collected
              @object_ids.map do |object_id|
                expect { ObjectSpace._id2ref(object_id) }.to raise_error(RangeError)
              end

              # Older objects are only cleared at serialization time
              expect(@object_ids.map { |it| is_object_recorded?(it) }).to eq [false, false, false, false]
            end

            context "when there's a heap serialization ongoing" do
              it "does nothing" do
                described_class::Testing._native_start_fake_slow_heap_serialization(stack_recorder)

                test_object_id = sample_and_clear

                expect do
                  described_class::Testing._native_heap_recorder_reset_last_update(stack_recorder)
                  recorder_after_gc_step
                end.to_not change { is_object_recorded?(test_object_id) }.from(true)

                described_class::Testing._native_end_fake_slow_heap_serialization(stack_recorder)

                # Sanity: after serialization finishes, we can finally clear it
                expect do
                  described_class::Testing._native_heap_recorder_reset_last_update(stack_recorder)
                  recorder_after_gc_step
                end.to change { is_object_recorded?(test_object_id) }.from(true).to(false)
              end
            end

            it "enforces a minimum time between heap updates" do
              test_object_id_1 = sample_and_clear

              expect { recorder_after_gc_step }.to change { is_object_recorded?(test_object_id_1) }.from(true).to(false)

              test_object_id_2 = sample_and_clear

              expect { recorder_after_gc_step }.to_not change { is_object_recorded?(test_object_id_2) }.from(true)
            end

            it "does not apply the minimum time between heap updates when serializing" do
              test_object_id_1 = sample_and_clear

              expect { recorder_after_gc_step }.to change { is_object_recorded?(test_object_id_1) }.from(true).to(false)

              test_object_id_2 = sample_and_clear

              expect { recorder_after_gc_step }.to_not change { is_object_recorded?(test_object_id_2) }.from(true)

              expect { serialize }.to change { is_object_recorded?(test_object_id_2) }.from(true).to(false)
            end
          end

          context 'when heap_clean_after_gc_enabled is false' do
            let(:heap_clean_after_gc_enabled) { false }

            it "does nothing" do
              # Every object is still being tracked at this point
              expect(@object_ids.map { |it| is_object_recorded?(it) }).to eq [true, true, true, true]

              recorder_after_gc_step

              # No change -- all objects are still being tracked
              expect(@object_ids.map { |it| is_object_recorded?(it) }).to eq [true, true, true, true]

              stack_recorder.serialize

              # All objects are finally cleared
              expect(@object_ids.map { |it| is_object_recorded?(it) }).to eq [false, false, false, false]
            end
          end
        end
      end
    end

    context "when there is a failure during serialization" do
      before do
        allow(Datadog.logger).to receive(:warn)
        allow(Datadog::Core::Telemetry::Logger).to receive(:error)

        # Real failures in serialization are hard to trigger, so we're using a mock failure instead
        expect(described_class).to receive(:_native_serialize).and_return([:error, "test error message"])
      end

      it { is_expected.to be nil }

      it "logs an error message" do
        expect(Datadog.logger).to receive(:warn).with(/test error message/)

        serialize
      end

      it "sends a telemetry log" do
        expect(Datadog::Core::Telemetry::Logger).to receive(:error).with(/Failed to serialize profiling data/)

        serialize
      end
    end

    context "when serializing multiple times in a row" do
      it "sets the start time of a profile to be >= the finish time of the previous profile" do
        start1, finish1, = stack_recorder.serialize
        start2, finish2, = stack_recorder.serialize
        start3, finish3, = stack_recorder.serialize
        start4, finish4, = stack_recorder.serialize

        expect(start1).to be <= finish1
        expect(finish1).to be <= start2
        expect(finish2).to be <= start3
        expect(finish3).to be <= start4
        expect(start4).to be <= finish4
      end

      it "sets the start time of the next profile to be >= the previous serialization call" do
        stack_recorder

        before_serialize = Time.now.utc

        stack_recorder.serialize
        start, = stack_recorder.serialize

        expect(start).to be >= before_serialize
      end
    end
  end

  describe "#serialize!" do
    subject(:serialize!) { stack_recorder.serialize! }

    context "when serialization succeeds" do
      let(:encoded_profile) { instance_double(Datadog::Profiling::EncodedProfile, _native_bytes: "serialized-data") }

      before do
        expect(described_class)
          .to receive(:_native_serialize).and_return([:ok, [:dummy_start, :dummy_finish, encoded_profile]])
      end

      it { is_expected.to be encoded_profile }
    end

    context "when serialization fails" do
      before { expect(described_class).to receive(:_native_serialize).and_return([:error, "test error message"]) }

      it { expect { serialize! }.to raise_error(RuntimeError, /test error message/) }
    end
  end

  describe "#reset_after_fork" do
    subject(:reset_after_fork) { stack_recorder.reset_after_fork }

    context "when slot one was the active slot" do
      it "keeps slot one as the active slot" do
        expect(active_slot).to be 1
      end

      it "keeps the slot one mutex unlocked" do
        expect(slot_one_mutex_locked?).to be false
      end

      it "keeps the slot two mutex locked" do
        expect(slot_two_mutex_locked?).to be true
      end
    end

    context "when slot two was the active slot" do
      before { stack_recorder.serialize }

      it "sets slot one as the active slot" do
        expect { reset_after_fork }.to change { active_slot }.from(2).to(1)
      end

      it "unlocks the slot one mutex" do
        expect { reset_after_fork }.to change { slot_one_mutex_locked? }.from(true).to(false)
      end

      it "locks the slot two mutex" do
        expect { reset_after_fork }.to change { slot_two_mutex_locked? }.from(false).to(true)
      end
    end

    context "when profile has a sample" do
      let(:metric_values) { {"cpu-time" => 123, "cpu-samples" => 456, "wall-time" => 789} }
      let(:labels) { {"label_a" => "value_a", "label_b" => "value_b", "state" => "unknown"}.to_a }

      it "makes the next calls to serialize return no data" do
        # Add some data
        Datadog::Profiling::Collectors::Stack::Testing
          ._native_sample(Thread.current, stack_recorder, metric_values, labels, numeric_labels)

        # Sanity check: validate that data is there, to avoid the test passing because of other issues
        sanity_check_samples = samples_from_pprof(stack_recorder.serialize[2])
        expect(sanity_check_samples.size).to be 1

        # Add some data, again
        Datadog::Profiling::Collectors::Stack::Testing
          ._native_sample(Thread.current, stack_recorder, metric_values, labels, numeric_labels)

        reset_after_fork

        # Test twice in a row to validate that both profile slots are empty
        expect(samples_from_pprof(stack_recorder.serialize[2])).to be_empty
        expect(samples_from_pprof(stack_recorder.serialize[2])).to be_empty
      end
    end

    it "sets the start_time of the active profile to the time of the reset_after_fork" do
      stack_recorder # Initialize instance

      now = Time.now
      reset_after_fork

      expect(stack_recorder.serialize.first).to be >= now
    end
  end

  describe "#stats" do
    it "returns basic lifetime stats of stack recorder" do
      num_serializations = 5

      num_serializations.times do
        stack_recorder.serialize
      end

      stats = stack_recorder.stats

      expect(stats).to match(
        hash_including(
          serialization_successes: num_serializations,
          serialization_failures: 0,

          serialization_time_ns_min: be > 0,
          serialization_time_ns_max: be > 0,
          serialization_time_ns_avg: be > 0,
          serialization_time_ns_total: be > 0,

          heap_recorder_snapshot: nil,
        )
      )

      serialization_time_min, serialization_time_max, serialization_time_avg, serialization_time_total =
        stats.values_at(
          :serialization_time_ns_min,
          :serialization_time_ns_max,
          :serialization_time_ns_avg,
          :serialization_time_ns_total
        )

      expect(serialization_time_min).to be <= serialization_time_avg
      expect(serialization_time_avg).to be <= serialization_time_max
      expect(serialization_time_total).to be_within(1e-4).of(serialization_time_avg * num_serializations)
    end

    context "with heap profiling enabled" do
      let(:heap_samples_enabled) { true }
      let(:heap_size_enabled) { true }

      before do
        skip "Heap profiling is only supported on Ruby >= 2.7" if RUBY_VERSION < "2.7"
      end

      after do |example|
        # This is here to facilitate troubleshooting when this test fails. Otherwise
        # it's very hard to understand what may be happening.
        if example.exception
          puts("Heap recorder debugging info:")
          puts(described_class::Testing._native_debug_heap_recorder(stack_recorder))
        end
      end

      def sample_allocation(obj)
        # Heap sampling currently requires this 2-step process to first pass data about the allocated object...
        described_class::Testing._native_track_object(stack_recorder, obj, 1, obj.class.name)
        Datadog::Profiling::Collectors::Stack::Testing._native_sample(
          Thread.current, stack_recorder, {"alloc-samples" => 1, "heap_sample" => true}, [], [],
        )
      end

      it "includes heap recorder snapshot" do
        live_objects = []

        # NOTE: We've seen some flakiness in this spec on Ruby 3.3 when the `dead_heap_samples` were allocated after
        # the `live_heap_samples`. Our working theory is that this is something like
        # https://bugs.ruby-lang.org/issues/19460 biting us again (e.g. search for this URL on this file and you'll see
        # a similar comment). Specifically, it looks like in some situations Ruby still keeps a reference to the last
        # allocated object _somewhere_, which makes the GC not collect that object, even though there are no actual
        # references to it. Because the GC doesn't clean the object, the heap recorder still keeps its record alive,
        # and so the test causes flakiness.
        # See also the discussion on commit 2fc03d5ae5860d4e9a75ce3825fba95ed288a1 for an earlier attempt at fixing this.
        dead_heap_samples = 10
        dead_heap_samples.times do |_i|
          obj = []
          sample_allocation(obj)
        end

        live_heap_samples = 6
        live_heap_samples.times do |i|
          obj = Object.new
          obj.freeze if i.odd? # Freeze every other object
          sample_allocation(obj)
          live_objects << obj
        end
        GC.start # All dead objects above will be GCed, all living strings will have age = 0

        begin
          # Allocate some extra objects in a block with GC disabled and ask for a serialization
          # to ensure these strings have age=0 by the time we try to serialize the profile
          GC.disable
          age0_heap_samples = 3
          age0_heap_samples.times do |_i|
            obj = Object.new
            sample_allocation(obj)
          end
          stack_recorder.serialize
        ensure
          GC.enable
        end

        expect(stack_recorder.stats).to match(
          hash_including(
            heap_recorder_snapshot: hash_including(
              # Records for dead objects should have gone away
              num_object_records: live_heap_samples + age0_heap_samples,
              # We allocate from 3 different locations in this test but only 2
              # of them are for objects which should be alive at serialization time
              num_heap_records: 2,

              # The update done during serialization should reflect the
              # state of the tracked heap objects at that time
              last_update_objects_alive: live_heap_samples,
              last_update_objects_dead: dead_heap_samples,
              last_update_objects_skipped: age0_heap_samples,
              last_update_objects_frozen: live_heap_samples / 2,
            )
          )
        )
      end
    end
  end

  context "libdatadog managed string storage regression test" do
    context "when reusing managed string ids across multiple profiles" do
      it "produces correct profiles" do
        profile1, profile2 = described_class::Testing._native_test_managed_string_storage_produces_valid_profiles

        decoded_profile1 = decode_profile(profile1)

        expect(decoded_profile1.string_table).to include("key", "hello", "world")
        expect { samples_from_pprof(profile1) }.to_not raise_error

        # Early versions of the managed string storage in datadog mistakenly omitted the strings from the string table,
        # see https://github.com/DataDog/libdatadog/pull/896 for details.

        decoded_profile2 = decode_profile(profile2)

        expect(decoded_profile2.string_table).to include("key", "hello", "world")
        expect { samples_from_pprof(profile2) }.to_not raise_error
      end
    end
  end
end
