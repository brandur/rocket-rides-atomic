require "rspec"
require 'webmock/rspec'

ENV["DATABASE_URL"] = "postgres://localhost/rocket-rides-atomic-test"
ENV["STRIPE_API_KEY"] = "sk_test_BQokikJOvBiI2HlWgH4olfQ2"
ENV["RACK_ENV"] = "test"

# disabled for up.rb and most test suites
WebMock.disable!

require_relative "../api"
require_relative "../up"

VALID_PARAMS = {
  "origin_lat" => 0.0,
  "origin_lon" => 0.0,
  "target_lat" => 0.0,
  "target_lon" => 0.0,
}.freeze

RSpec.configure do |config|
end

def clear_database
  DB.transaction do
    DB.run("TRUNCATE audit_records CASCADE")
    DB.run("TRUNCATE idempotency_keys CASCADE")
    DB.run("TRUNCATE rides CASCADE")
    DB.run("TRUNCATE staged_jobs CASCADE")
  end
end

def create_key(params = {})
  IdempotencyKey.create({
    idempotency_key: key_val,
    locked_at:       nil,
    recovery_point:  RECOVERY_POINT_STARTED,
    request_method:  "POST",
    request_params:  Sequel.pg_jsonb(VALID_PARAMS),
    request_path:    "/rides",
    user_id:         user.id,
  }.merge(params))
end

def key_val
  SecureRandom.uuid
end

def suppress_stdout
  $stdout = StringIO.new unless verbose?
end

def user
  User.first(id: 1)
end

def verbose?
  ENV["VERBOSE"] == "true"
end
