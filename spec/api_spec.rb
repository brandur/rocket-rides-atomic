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
    expect(JSON.parse(last_response.body)["message"]).to eq(Messages.ok)
  end
end
