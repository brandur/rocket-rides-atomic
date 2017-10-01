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

  before do
    clear_database
  end

  describe "idempotency keys and recovery" do
    it "passes for a new key" do
      post "/rides", VALID_PARAMS,
        { "HTTP_IDEMPOTENCY_KEY" => key_val }
      expect(last_response.status).to eq(201)
      expect(unwrap_ok(last_response.body)).to eq(Messages.ok)
    end

    it "returns a stored result" do
      body = wrap_ok("hello")
      key = IdempotencyKey.create(
        idempotency_key: key_val,
        locked_at:       nil,
        recovery_point:  RECOVERY_POINT_FINISHED,
        request_params:  Sequel.pg_jsonb(VALID_PARAMS),
        response_code:   201,
        response_body:   body,
        user_id:         user.id,
      )
      post "/rides", VALID_PARAMS,
        { "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key }
      expect(last_response.status).to eq(201)
      expect(unwrap_ok(last_response.body)).to eq("hello")
    end

    it "passes for keys that are unlocked" do
      key = IdempotencyKey.create(
        idempotency_key: key_val,
        locked_at:       nil,
        recovery_point:  RECOVERY_POINT_STARTED,
        request_params:  Sequel.pg_jsonb(VALID_PARAMS),
        user_id:         user.id,
      )
      post "/rides", VALID_PARAMS,
        { "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key }
      expect(last_response.status).to eq(201)
      expect(unwrap_ok(last_response.body)).to eq(Messages.ok)
    end

    it "passes for keys with a stale locked_at" do
      key = IdempotencyKey.create(
        idempotency_key: key_val,
        locked_at:       Time.now - IDEMPOTENCY_KEY_LOCK_TIMEOUT - 1,
        recovery_point:  RECOVERY_POINT_STARTED,
        request_params:  Sequel.pg_jsonb(VALID_PARAMS),
        user_id:         user.id,
      )
      post "/rides", VALID_PARAMS,
        { "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key }
      expect(last_response.status).to eq(201)
      expect(unwrap_ok(last_response.body)).to eq(Messages.ok)
    end

    it "stores results for a permanent failure" do
    end
  end

  describe "atomic phases and recovery points" do
    it "continues from #{RECOVERY_POINT_STARTED}" do
    end

    it "continues from #{RECOVERY_POINT_RIDE_CREATED}" do
    end

    it "continues from #{RECOVERY_POINT_CHARGE_CREATED}" do
    end
  end

  describe "failure" do
    it "denies requests that are missing a key" do
      post "/rides", VALID_PARAMS,
        { "HTTP_IDEMPOTENCY_KEY" => "" }
      expect(last_response.status).to eq(400)
      expect(unwrap_error(last_response.body)).to \
        eq(Messages.error_key_required)
    end

    it "denies requests that have a key that's too short" do
      post "/rides", VALID_PARAMS,
        { "HTTP_IDEMPOTENCY_KEY" => "xxx" }
      expect(last_response.status).to eq(400)
      expect(unwrap_error(last_response.body)).to \
        eq(Messages.error_key_too_short)
    end

    it "denies requests that are missing parameters" do
      post "/rides", {},
        { "HTTP_IDEMPOTENCY_KEY" => key_val }
      expect(last_response.status).to eq(422)
      expect(unwrap_error(last_response.body)).to \
        eq(Messages.error_require_param(key: "origin_lat"))
    end

    it "denies requests where parameters don't match on an existing key" do
      key = IdempotencyKey.create(
        idempotency_key: key_val,
        locked_at:       nil,
        recovery_point:  RECOVERY_POINT_STARTED,
        request_params:  Sequel.pg_jsonb(VALID_PARAMS),
        user_id:         user.id,
      )
      post "/rides", VALID_PARAMS.merge("origin_lat" => 10.0),
        { "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key }
      expect(last_response.status).to eq(409)
      expect(unwrap_error(last_response.body)).to \
        eq(Messages.error_params_mismatch)
    end

    it "denies requests that have an equivalent in flight" do
      key = IdempotencyKey.create(
        idempotency_key: key_val,
        locked_at:       Time.now,
        recovery_point:  RECOVERY_POINT_STARTED,
        request_params:  Sequel.pg_jsonb(VALID_PARAMS),
        user_id:         user.id,
      )
      post "/rides", VALID_PARAMS,
        { "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key }
      expect(last_response.status).to eq(409)
      expect(unwrap_error(last_response.body)).to \
        eq(Messages.error_request_in_progress)
    end
  end

  #
  # helpers
  #

  private def clear_database
    DB.run("TRUNCATE audit_records CASCADE")
    DB.run("TRUNCATE idempotency_keys CASCADE")
    DB.run("TRUNCATE rides CASCADE")
    DB.run("TRUNCATE staged_jobs CASCADE")
  end

  private def key_val
    SecureRandom.uuid
  end

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

  private def user
    User.first(id: 1)
  end
end
