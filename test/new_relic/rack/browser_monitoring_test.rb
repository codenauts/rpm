# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require File.expand_path(File.join(File.dirname(__FILE__),'..', '..',
                                   'test_helper'))
require 'rack/test'
require 'new_relic/agent/instrumentation/rack'
require 'new_relic/rack/browser_monitoring'

ENV['RACK_ENV'] = 'test'

class BrowserMonitoringTest < Minitest::Test
  include Rack::Test::Methods

  class TestApp
    @@doc = nil
    @@next_response = nil

    def self.doc=(other)
      @@doc = other
    end

    def self.next_response=(next_response)
      @@next_response = next_response
    end

    def self.next_response
      @@next_response
    end

    def call(env)
      @@doc ||= <<-EOL
<html>
  <head>
    <title>im a title</title>
    <meta some-crap="1"/>
    <script>
      junk
    </script>
  </head>
  <body>im some body text</body>
</html>
EOL
      response = @@next_response || Rack::Response.new(@@doc)
      @@next_response = nil

      [200, {'Content-Type' => 'text/html'}, response]
    end
    include NewRelic::Agent::Instrumentation::Rack
  end

  def app
    NewRelic::Rack::BrowserMonitoring.new(TestApp.new)
  end

  def setup
    super
    @config = {
      :application_id => 5,
      :beacon => 'beacon',
      :browser_key => 'some browser key',
      :'rum.enabled' => true,
      :license_key => 'a' * 40,
      :js_agent_loader => 'loader',
    }
    NewRelic::Agent.config.apply_config(@config)
  end

  def teardown
    super
    TestApp.doc = nil
    NewRelic::Agent.config.remove_config(@config)
    NewRelic::Agent.agent.transaction_sampler.reset!
  end

  def test_make_sure_header_is_set
    in_transaction do
      assert NewRelic::Agent.browser_timing_header.size > 0
    end
  end

  def test_should_only_instrument_successfull_html_requests
    assert app.should_instrument?({}, 200, {'Content-Type' => 'text/html'})
    assert !app.should_instrument?({}, 500, {'Content-Type' => 'text/html'})
    assert !app.should_instrument?({}, 200, {'Content-Type' => 'text/xhtml'})
  end

  def test_should_not_instrument_when_content_disposition
    assert !app.should_instrument?({}, 200, {'Content-Type' => 'text/html', 'Content-Disposition' => 'attachment; filename=test.html'})
  end

  def test_should_not_instrument_when_already_did
    assert !app.should_instrument?({NewRelic::Rack::BrowserMonitoring::ALREADY_INSTRUMENTED_KEY => true}, 200, {'Content-Type' => 'text/html'})
  end

  def test_insert_header_should_mark_environment
    get '/'
    assert last_request.env.key?(NewRelic::Rack::BrowserMonitoring::ALREADY_INSTRUMENTED_KEY)
  end

  # RUM header auto-insertion testing
  # We read *.source.html files from the test/rum directory, and then
  # compare the results of them to *.result.html files.

  source_files = Dir[File.join(File.dirname(__FILE__), "..", "..", "rum", "*.source.html")]

  RUM_LOADER = "|||I AM THE RUM HEADER|||"
  RUM_CONFIG = "|||I AM THE RUM FOOTER|||"

  source_files.each do |source_file|
    source_filename = File.basename(source_file).gsub(".", "_")
    source_html = File.read(source_file)

    result_file = source_file.gsub(".source.", ".result.")

    define_method("test_#{source_filename}") do
      TestApp.doc = source_html
      NewRelic::Agent.stubs(:browser_timing_header).returns(RUM_CONFIG + RUM_LOADER)

      get '/'

      expected_content = File.read(result_file)
      assert_equal(expected_content, last_response.body)
    end

    define_method("test_dont_touch_#{source_filename}") do
      TestApp.doc = source_html
      NewRelic::Rack::BrowserMonitoring.any_instance.stubs(:should_instrument?).returns(false)

      get '/'

      assert_equal(source_html, last_response.body)
    end
  end

  def test_should_close_response
    TestApp.next_response = Rack::Response.new("<html/>")
    TestApp.next_response.expects(:close)

    get '/'

    assert last_response.ok?
  end

  def test_should_not_close_if_not_responded_to
    TestApp.next_response = Rack::Response.new("<html/>")
    TestApp.next_response.stubs(:respond_to?).with(:close).returns(false)
    TestApp.next_response.expects(:close).never

    get '/'

    assert last_response.ok?
  end

  def test_should_not_throw_exception_on_empty_reponse
    TestApp.doc = ''
    get '/'

    assert last_response.ok?
  end

  def test_token_is_set_in_footer_when_set_by_cookie
    token = '1234567890987654321'
    set_cookie "NRAGENT=tk=#{token}"
    get '/'

    assert(last_response.body.include?(token), last_response.body)
  end

  def test_guid_is_set_in_footer_when_token_is_set
    guid = 'abcdefgfedcba'
    NewRelic::Agent::Transaction.any_instance.stubs(:guid).returns(guid)
    set_cookie "NRAGENT=tk=token"
    with_config(:apdex_t => 0.0001) do
      get '/'
      assert(last_response.body.include?(guid), last_response.body)
    end
  end

  def test_calculate_content_length_accounts_for_multibyte_characters_for_186
    String.stubs(:respond_to?).with(:bytesize).returns(false)
    browser_monitoring = NewRelic::Rack::BrowserMonitoring.new(mock('app'))
    assert_equal 24, browser_monitoring.calculate_content_length("猿も木から落ちる")
  end

  def test_calculate_content_length_accounts_for_multibyte_characters_for_modern_ruby
    browser_monitoring = NewRelic::Rack::BrowserMonitoring.new(mock('app'))
    assert_equal 18, browser_monitoring.calculate_content_length("七転び八起き")
  end
end
