require "rack/test"
require "rspec"
require "securerandom"

ENV["DATABASE_URL"] = "postgres://localhost/rocket-rides-atomic-test"
ENV["STRIPE_API_KEY"] = "sk_test_BQokikJOvBiI2HlWgH4olfQ2"
ENV["RACK_ENV"] = "test"

require "./api"
require "./up"

VALID_PARAMS = {
  "origin_lat" => 0.0,
  "origin_lon" => 0.0,
  "target_lat" => 0.0,
  "target_lon" => 0.0,
}

RSpec.describe "api.rb" do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  it "passes successfully" do
    post "/rides", VALID_PARAMS, { "HTTP_IDEMPOTENCY_KEY" => SecureRandom.uuid }
    expect(last_response.status).to eq(201)
    expect(unwrap_ok(last_response.body)).to eq(Messages.ok)
  end

  #
  # helpers
  #

  private def unwrap_error(body)
    data = JSON.parse(body, symbolize_names: true)
    expect(data).to have_key(:error)
    data[:error]
  end

  private def unwrap_ok(body)
    data = JSON.parse(body, symbolize_names: true)
    expect(data).to have_key(:message)
    data[:message]
  end
end
