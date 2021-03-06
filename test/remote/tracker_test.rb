# # encoding: UTF-8
require 'test_helper'
require 'rack/test'

# Tests for universal tracking for all request paths
#
class TrackerRemoteTest < Minitest::Test

  # These tests connect to the Metrics server with an account and verify remote
  # functions. They will only run if the below environment variables are set.
  #
  # BE CAREFUL, running these tests will DELETE ALL metrics currently in the
  # test account.
  #
  if ENV['LIBRATO_RACK_TEST_EMAIL'] && ENV['LIBRATO_RACK_TEST_API_KEY']

    def setup
      config = Librato::Rack::Configuration.new
      config.user = ENV['LIBRATO_RACK_TEST_EMAIL']
      config.token = ENV['LIBRATO_RACK_TEST_API_KEY']
      if ENV['LIBRATO_RACK_TEST_API_ENDPOINT']
        config.api_endpoint = ENV['LIBRATO_RACK_TEST_API_ENDPOINT']
      end
      config.log_target = File.open('/dev/null', 'w') # ignore logs
      @tracker = Librato::Rack::Tracker.new(config)
      delete_all_metrics
    end

    def test_flush_counters
      tracker.increment :foo                        # simple
      tracker.increment :bar, 2                     # specified
      tracker.increment :foo                        # multincrement
      tracker.increment :foo, source: 'baz', by: 3  # custom source
      @queued = tracker.queued
      tracker.flush

      # metrics are SSA, so should exist but won't have measurements yet
      metric_names = client.list.map { |m| m['name'] }
      assert metric_names.include?('foo'), 'foo should be present'
      assert metric_names.include?('bar'), 'bar should be present'

      # interogate queued payload for expected values
      assert_equal source, @queued[:source]
      assert_equal 2, queued('foo')

      # custom source
      assert_equal 3, queued('foo', source: 'baz')

      # different counter
      assert_equal 2, queued('bar')
    end

    def test_counter_persistent_through_flush
      tracker.increment 'knightrider'
      tracker.increment 'badguys', sporadic: true
      assert_equal 1, collector.counters['knightrider']
      assert_equal 1, collector.counters['badguys']

      tracker.flush
      assert_equal 0, collector.counters['knightrider']
      assert_equal nil, collector.counters['badguys']
    end

    def test_flush_should_send_measures_and_timings
      tracker.timing  'request.time.total', 122.1
      tracker.measure 'items_bought', 20
      tracker.timing  'request.time.total', 81.3
      tracker.timing  'jobs.queued', 5, source: 'worker.3'
      @queued = tracker.queued
      tracker.flush

      # metrics are SSA, so should exist but won't have measurements yet
      metric_names = client.list.map { |m| m['name'] }
      assert metric_names.include?('request.time.total'), 'request.time.total should be present'
      assert metric_names.include?('items_bought'), 'request.time.db should be present'

      assert_equal 2, queued('request.time.total')[:count]
      assert_in_delta 203.4, queued('request.time.total')[:sum], 0.1

      assert_equal 1, queued('items_bought')[:count]
      assert_in_delta 20, queued('items_bought')[:sum], 0.1

      assert_equal 1, queued('jobs.queued', source: 'worker.3')[:count]
      assert_in_delta 5, queued('jobs.queued', source: 'worker.3')[:sum], 0.1
    end

    def test_flush_should_purge_measures_and_timings
      tracker.timing  'request.time.total', 122.1
      tracker.measure 'items_bought', 20
      tracker.flush

      assert collector.aggregate.empty?,
        'measures and timings should be cleared with flush'
    end

    def test_flush_respects_prefix
      config.prefix = 'testyprefix'

      tracker.timing 'mytime', 221.1
      tracker.increment 'mycount', 4
      @queued = tracker.queued
      tracker.flush

      metric_names = client.list.map { |m| m['name'] }
      assert metric_names.include?('testyprefix.mytime'),
        'testyprefix.mytime should be present'
      assert metric_names.include?('testyprefix.mycount'), '
        testyprefix.mycount should be present'

      assert_equal 1, queued('testyprefix.mytime')[:count]
      assert_equal 4, queued('testyprefix.mycount')
    end

    def test_flush_recovers_from_failure
      # create a metric foo of counter type
      client.submit foo: {type: :counter, value: 12}

      # failing flush - submit a foo measurement as a gauge (type mismatch)
      tracker.measure :foo, 2.12

      # won't be accepted
      tracker.flush

      tracker.measure :boo, 2.12
      tracker.flush

      metric_names = client.list.map { |m| m['name'] }
      assert metric_names.include?('boo')
    end

    def test_flush_handles_invalid_metric_names
      tracker.increment :foo              # valid
      tracker.increment 'fübar'           # invalid
      tracker.measure 'fu/bar/baz', 12.1  # invalid
      @queued = tracker.queued
      tracker.flush

      metric_names = client.list.map { |m| m['name'] }
      assert metric_names.include?('foo')

      # should be sending value for foo
      assert_equal 1.0, queued('foo')
    end

    def test_flush_handles_invalid_sources_names
      tracker.increment :foo, source: 'atreides'         # valid
      tracker.increment :bar, source: 'glébnöst'         # invalid
      tracker.measure 'baz', 2.25, source: 'b/l/ak/nok'  # invalid
      @queued = tracker.queued
      tracker.flush

      metric_names = client.list.map { |m| m['name'] }
      assert metric_names.include?('foo')

      assert_equal 1.0, queued('foo', source: 'atreides')
    end

    private

    def tracker
      @tracker
    end

    def client
      @tracker.send(:client)
    end

    def collector
      @tracker.collector
    end

    def config
      @tracker.config
    end

    # wrapper to make api format more easy to query
    def queued(name, opts={})
      raise "No queued found" unless @queued
      source = opts[:source]  || nil

      @queued[:gauges].each do |g|
        if g[:name] == name.to_s && g[:source] == source
          if g[:count]
            # complex metric, return the whole hash
            return g
          else
            # return just the value
            return g[:value]
          end
        end
      end
      raise "No queued entry with '#{name}' found."
    end

    def source
      @tracker.qualified_source
    end

    def delete_all_metrics
      metric_names = client.list.map { |metric| metric['name'] }
      client.delete(*metric_names) if !metric_names.empty?
    end

  else
    # ENV vars not set
    puts "Skipping remote tests..."
  end

end
