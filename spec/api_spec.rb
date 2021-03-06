require "rack/test"
require "securerandom"

require_relative "./spec_helper"

RSpec.describe API do
  include Rack::Test::Methods

  def app
    API
  end

  before do
    clear_database
    suppress_stdout
  end

  describe "idempotency keys and recovery" do
    it "passes for a new key" do
      post "/rides", VALID_PARAMS,
        headers.merge({ "HTTP_IDEMPOTENCY_KEY" => key_val })
      expect(last_response.status).to eq(201)
      expect(unwrap_ok(last_response.body)).to eq(Messages.ok)
    end

    it "returns a stored result" do
      body = wrap_ok("hello")
      key = create_key(
        recovery_point: RECOVERY_POINT_FINISHED,
        response_code:  201,
        response_body:  body,
      )
      post "/rides", VALID_PARAMS,
        headers.merge({ "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key })
      expect(last_response.status).to eq(201)
      expect(unwrap_ok(last_response.body)).to eq("hello")
    end

    it "passes for keys that are unlocked" do
      key = create_key(locked_at: nil)
      post "/rides", VALID_PARAMS,
        headers.merge({ "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key })
      expect(last_response.status).to eq(201)
      expect(unwrap_ok(last_response.body)).to eq(Messages.ok)
    end

    it "passes for keys with a stale locked_at" do
      key = create_key(locked_at: Time.now - IDEMPOTENCY_KEY_LOCK_TIMEOUT - 1)
      post "/rides", VALID_PARAMS,
        headers.merge({ "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key })
      expect(last_response.status).to eq(201)
      expect(unwrap_ok(last_response.body)).to eq(Messages.ok)
    end

    it "stores results for a permanent failure" do
      key = create_key
      post "/rides", VALID_PARAMS,
        headers.merge({
          # this user is created by up.rb
          "HTTP_AUTHORIZATION"   => "user-bad-source@example.com",
          "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key,
        })
      expect(last_response.status).to eq(402)
      expect(unwrap_error(last_response.body)).to \
        eq(Messages.error_payment(error: "Your card was declined."))
    end
  end

  describe "atomic phases and recovery points" do
    it "continues from #{RECOVERY_POINT_STARTED}" do
      key = create_key(recovery_point: RECOVERY_POINT_STARTED)
      post "/rides", VALID_PARAMS,
        headers.merge({ "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key })
      expect(last_response.status).to eq(201)
      expect(unwrap_ok(last_response.body)).to eq(Messages.ok)
    end

    it "continues from #{RECOVERY_POINT_RIDE_CREATED}" do
      key = create_key(recovery_point: RECOVERY_POINT_RIDE_CREATED)

      # here we're taking advantage of the fact that the names of our API
      # parameters match the names of our database columns perfectly
      Ride.create(VALID_PARAMS.merge(
        idempotency_key_id: key.id,
        user_id: user.id,
      ))

      post "/rides", VALID_PARAMS,
        headers.merge({ "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key })
      expect(last_response.status).to eq(201)
      expect(unwrap_ok(last_response.body)).to eq(Messages.ok)
    end

    it "continues from #{RECOVERY_POINT_CHARGE_CREATED}" do
      key = create_key(recovery_point: RECOVERY_POINT_CHARGE_CREATED)
      post "/rides", VALID_PARAMS,
        headers.merge({ "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key })
      expect(last_response.status).to eq(201)
      expect(unwrap_ok(last_response.body)).to eq(Messages.ok)
    end
  end

  describe "failure" do
    it "denies requests that are missing authentication" do
      post "/rides", VALID_PARAMS,
        headers.merge({ "HTTP_AUTHORIZATION" => "" })
      expect(last_response.status).to eq(401)
      expect(unwrap_error(last_response.body)).to \
        eq(Messages.error_auth_required)
    end

    it "denies requests with invalid authentication" do
      post "/rides", VALID_PARAMS,
        headers.merge({ "HTTP_AUTHORIZATION" => "bad-user@example.com" })
      expect(last_response.status).to eq(401)
      expect(unwrap_error(last_response.body)).to \
        eq(Messages.error_auth_invalid)
    end

    it "denies requests that are missing a key" do
      post "/rides", VALID_PARAMS,
        headers.merge({ "HTTP_IDEMPOTENCY_KEY" => "" })
      expect(last_response.status).to eq(400)
      expect(unwrap_error(last_response.body)).to \
        eq(Messages.error_key_required)
    end

    it "denies requests that have a key that's too short" do
      post "/rides", VALID_PARAMS,
        headers.merge({ "HTTP_IDEMPOTENCY_KEY" => "xxx" })
      expect(last_response.status).to eq(400)
      expect(unwrap_error(last_response.body)).to \
        eq(Messages.error_key_too_short)
    end

    it "denies requests that are missing parameters" do
      post "/rides", {},
        headers.merge({ "HTTP_IDEMPOTENCY_KEY" => key_val })
      expect(last_response.status).to eq(422)
      expect(unwrap_error(last_response.body)).to \
        eq(Messages.error_require_param(key: "origin_lat"))
    end

    it "denies requests where parameters don't match on an existing key" do
      key = create_key
      post "/rides", VALID_PARAMS.merge("origin_lat" => 10.0),
        headers.merge({ "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key })
      expect(last_response.status).to eq(409)
      expect(unwrap_error(last_response.body)).to \
        eq(Messages.error_params_mismatch)
    end

    it "denies requests that have an equivalent in flight" do
      key = create_key(locked_at: Time.now)
      post "/rides", VALID_PARAMS,
        headers.merge({ "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key })
      expect(last_response.status).to eq(409)
      expect(unwrap_error(last_response.body)).to \
        eq(Messages.error_request_in_progress)
    end

    it "unlocks a key and returns 409 on a serialization failure" do
      expect(Stripe::Charge).to receive(:create) do
        raise Sequel::SerializationFailure, "Serialization failure."
      end

      key = create_key

      expect do
        post "/rides", VALID_PARAMS,
          headers.merge({ "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key })
      end.to raise_error(Sequel::SerializationFailure)

      key.reload
      expect(key.locked_at).to be_nil
    end

    it "unlocks a key and returns 500 on an internal error" do
      expect(Stripe::Charge).to receive(:create) do
        raise "Internal server error!"
      end

      key = create_key

      expect do
        post "/rides", VALID_PARAMS,
          headers.merge({ "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key })
      end.to raise_error(StandardError)

      key.reload
      expect(key.locked_at).to be_nil
    end
  end

  #
  # helpers
  #

  private def headers
    # The demo API trusts that we are who we say we are. This user is created
    # by up.rb.
    { "HTTP_AUTHORIZATION" => "user@example.com" }
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
end
