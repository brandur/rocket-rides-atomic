require "pg"
require "sequel"
require "sinatra"
require "stripe"

DB = Sequel.connect(ENV["DATABASE_URL"] || abort("need DATABASE_URL"))
DB.extension :pg_json
Stripe.api_key = ENV["STRIPE_API_KEY"] || abort("need STRIPE_API_KEY")

# a verbose mode to help with debugging
if ENV["VERBOSE"] == "true"
  DB.loggers << Logger.new($stdout)
  Stripe.log_level = Stripe::LEVEL_INFO
end

set :server, %w[puma]

post "/rides" do
  user = authenticate_user(request)
  key_val = validate_idempotency_key(request)
  params = validate_params(request)

  puts "Idempotency key: #{key_val}"
  puts "Params: #{params}"

  # may be created on this request or retrieved if it already exists
  key = nil

  # Our first atomic phase to create or update an idempotency key.
  #
  # A key concept here is that if two requests try to insert or update within
  # close proximity, one of the two will be aborted by Postgres because we're
  # using a transaction with SERIALIZABLE isolation level. It may not look it,
  # but this code is safe from races.
  atomic_phase(key, new_recovery_point: nil) do
    key = IdempotencyKey.first(user_id: user.id, idempotency_key: key_val)

    if key
      # Programs sending multiple requests with different parameters but the
      # same idempotency key is a bug.
      if key.request_params != params
        halt 409, wrap_error(Messages.error_params_mismatch)
      end

      # Only acquire a lock if the key is unlocked or its lock as expired
      # because it was long enough ago.
      if key.locked_at && key.locked_at > Time.now - IDEMPOTENCY_KEY_LOCK_TIMEOUT
        halt 409, wrap_error(Messages.error_request_in_progress)
      end

      # Lock the key unless the request is already finished.
      if key.recovery_point != RECOVERY_POINT_FINISHED
        key.update(locked_at: Time.now)
      end
    else
      key = IdempotencyKey.create(
        idempotency_key: key_val,
        locked_at:       Time.now,
        recovery_point:  RECOVERY_POINT_STARTED,
        request_params:  Sequel.pg_jsonb(params),
        user_id:         user.id,
      )
      puts "Created idempotency key ID #{key.id}"
    end
  end

  # may be created on this request or retrieved if recovering a partially
  # completed previous request
  ride = nil

  loop do
    case key.recovery_point
    when RECOVERY_POINT_STARTED
      atomic_phase(key, new_recovery_point: RECOVERY_POINT_RIDE_CREATED) do
        ride = Ride.create(
          origin_lat:       params["origin_lat"],
          origin_lon:       params["origin_lon"],
          target_lat:       params["target_lat"],
          target_lon:       params["target_lon"],
          stripe_charge_id: nil, # no charge created yet
          user_id:          user.id,
        )

        # in the same transaction insert an audit record for what happened
        DB[:audit_records].insert(
          action:        AUDIT_RIDE_CREATED,
          data:          Sequel.pg_jsonb(params),
          origin_ip:     request.ip,
          resource_id:   ride.id,
          resource_type: "ride",
          user_id:       user.id,
        )
      end

    when RECOVERY_POINT_RIDE_CREATED
      atomic_phase(key, new_recovery_point: RECOVERY_POINT_CHARGE_CREATED) do
        # retrieve a ride record if necessary (i.e. we're recovering)
        ride = Ride.first(idempotency_key_id: key.id) if ride.nil?

        # if ride is still nil by this point, we have a bug
        raise "Bug! Should have ride for key at #{RECOVERY_POINT_RIDE_CREATED}" \
          if ride.nil?

        # Rocket Rides is still a new service, so during our prototype phase
        # we're going to give $20 fixed-cost rides to everyone, regardless of
        # distance. We'll implement a better algorithm later to better
        # represent the cost in time and jetfuel on the part of our pilots.
        begin
          charge = Stripe::Charge.create(
            amount:      2000,
            currency:    "usd",
            customer:    user.stripe_customer_id,
            description: "Charge for ride #{ride.id}",
          )
        rescue Stripe::InvalidRequestError
          # TODO: handle PERMANENT failure
        end

        # within the transaction, update our ride and key
        ride.update(stripe_charge_id: charge.id)
      end

    when RECOVERY_POINT_CHARGE_CREATED
      atomic_phase(key, new_recovery_point: RECOVERY_POINT_FINISHED) do
        # Send a receipt asynchronously by adding an entry to the staged_jobs
        # table. By funneling the job through Postgres, we make this operation
        # transaction-safe.
        DB[:staged_jobs].insert(
          job_name: "send_ride_receipt",
          job_args: Sequel.pg_jsonb({
            amount:   2000,
            currency: "usd",
            user_id:  user.id
          })
        )

        key.update(
          locked_at: nil,
          response_code: 201,
          response_body: Sequel.pg_jsonb({
            message: Messages.ok
          })
        )
      end

    when RECOVERY_POINT_FINISHED
      break

    else
      raise "Bug! Unhandled recovery point '#{key.recovery_point}'."
    end

    # If we got here, allow the loop to move us onto the next phase of the
    # request. Finished requests will break the loop.
  end

  [key.response_code, JSON.generate(key.response_body)]
end

#
# models
#

class IdempotencyKey < Sequel::Model
end

class Ride < Sequel::Model
end

class User < Sequel::Model
end

#
# helpers
#

# Names of audit record actions.
AUDIT_RIDE_CREATED = "ride.created"

# Number of seconds passed which we consider a held idempotency key lock to be
# defunct and eligible to be locked again by a different API call. We try to
# unlock keys on our various failure conditions, but software is buggy, and
# this might not happen 100% of the time, so this is a hedge against it.
IDEMPOTENCY_KEY_LOCK_TIMEOUT = 90

# To try and enforce some level of required randomness in an idempotency key,
# we require a minimum length. This of course is a poor approximate, and in
# real life you might want to consider trying to measure actual entropy with
# something like the Shannon entropy equation.
IDEMPOTENCY_KEY_MIN_LENGTH = 20

# Names of recovery points.
RECOVERY_POINT_STARTED        = "started"
RECOVERY_POINT_RIDE_CREATED   = "ride_created"
RECOVERY_POINT_CHARGE_CREATED = "charge_created"
RECOVERY_POINT_FINISHED       = "finished"

module Messages
  def self.ok
    "Payment accepted. Your pilot is on their way!"
  end

  def self.error_params_mismatch
    "There was a mismatch between this request's parameters and the " \
      "parameters of a previously stored request with the same " \
      "Idempotency-Key."
  end

  def self.error_request_in_progress
    "An API request with the same Idempotency-Key is already in progress."
  end

  def self.error_require_float(key:)
    "Parameter '#{key}' must be a floating-point number."
  end

  def self.error_require_lat(key:)
    "Parameter '#{key}' must be a valid latitude coordinate."
  end

  def self.error_require_lon(key:)
    "Parameter '#{key}' must be a valid longitude coordinate."
  end

  def self.error_require_param(key:)
    "Please specify parameter '#{key}'."
  end
end

# A simple wrapper for our atomic phases. We're not doing anything special here
# -- just defining some common transaction options and consolidating how we
# recover from various types of transactional failures.
def atomic_phase(key, new_recovery_point:, &block)
  error = false
  begin
    DB.transaction(isolation: :serializable) do
      block.call

      # update to the given recovery point *inside* the transaction
      if !key.nil? && !new_recovery_point.nil?
        key.update(recovery_point: new_recovery_point)
      end
    end
  rescue Sequel::SerializationFailure
    # unlock the key and tell the user to retry
    error = true
  ensure
    # If we're leaving under an error condition, try to unlock the idempotency
    # key right away so that another request can try again.
    if error && !key.nil?
      begin
        key.update(locked_at: nil)
      rescue StandardError
        # We're already inside an error condition, so swallow any additional
        # errors from here and just send them to logs.
        puts "Failed to unlock key #{key.id}."
      end
    end
  end
end

def authenticate_user(_request)
  # This is obviously something you shouldn't do in a real application, but for
  # now we're just going to authenticate all requests as our test user.
  User.first(id: 1)
end

# Wraps a message in the standard structure that we send back for error
# responses from the API. Still needs to be JSON-encoded before transmission.
def wrap_error(message)
  { error: message }
end

# Wraps a message in the standard structure that we send back for success
# responses from the API. Still needs to be JSON-encoded before transmission.
def wrap_ok(message)
  { message: message }
end

def validate_idempotency_key(request)
  # In Rack, headers are accessed from an key named after them and prefixed
  # with `HTTP_`.
  key = request.env["HTTP_IDEMPOTENCY_KEY"]

  if key.nil? || key.empty?
    halt 400, 'Please specify the Idempotency-Key header'
  end

  if key.length < IDEMPOTENCY_KEY_MIN_LENGTH
    halt 400, "Idempotency-Key must be at least %s characters long" %
      [IDEMPOTENCY_KEY_MIN_LENGTH]
  end

  key
end

def validate_params(request)
  {
    "origin_lat" => validate_params_lat(request, "origin_lat"),
    "origin_lon" => validate_params_lon(request, "origin_lon"),
    "target_lat" => validate_params_lat(request, "target_lat"),
    "target_lon" => validate_params_lon(request, "target_lon"),
  }
end

def validate_params_float(request, key)
  val = validate_params_present(request, key)

  # Float as opposed to to_f because it's more strict about what it'll take.
  begin
    Float(val)
  rescue ArgumentError
    halt 422, wrap_error(Messages.error_require_float(key: key))
  end
end

def validate_params_lat(request, key)
  val = validate_params_float(request, key)
  return val if val >= -90.0 && val <= 90.0
  halt 422, wrap_error(Messages.error_require_lat(key: key))
end

def validate_params_lon(request, key)
  val = validate_params_float(request, key)
  return val if val >= -180.0 && val <= 180.0
  halt 422, wrap_error(Messages.error_require_lon(key: key))
end

def validate_params_present(request, key)
  val = request.POST[key]
  return val if !val.nil? && !val.empty?
  halt 422, wrap_error(Messages.error_require_param(key: key))
end
