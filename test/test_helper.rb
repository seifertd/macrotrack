ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"
require_relative "test_helpers/ai_test_helper"
require_relative "test_helpers/stt_test_helper"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include AiTestHelper
    include SttTestHelper

    # Nothing in the suite may shell out to whisper: it is a four-second subprocess and a
    # binary that only exists on two machines. Same rule as Ai::FakeClient, same reason.
    setup { Stt.provider = Stt::Fake.new }
    teardown { Stt.provider = nil }

    # Add more helper methods to be used by all tests here...
  end
end
