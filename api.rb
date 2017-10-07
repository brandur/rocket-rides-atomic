require "json"
require "sinatra"

require_relative "./config"

class API < Sinatra::Base
  set :server, %w[puma]
  set :show_exceptions, false

  post "/rides" do
    user = authenticate_user(request)
    key_val = validate_idempotency_key(request)
    params = validate_params(request)

    # A special parameter that raises an error from within the stack so that we
    # can simulate a failed request. It's parsed outside of #validate_params so
    # that it's not stored to an idempotency key (we don't want it to fail the
    # second time it's tried too).
    raise_error = false
    if request.POST.key?("raise_error")
      raise_error = validate_params_bool(request, "raise_error")
    end

    # may be created on this request or retrieved if it already exists
    key = nil

    # Our first atomic phase to create or update an idempotency key.
    #
    # A key concept here is that if two requests try to insert or update within
    # close proximity, one of the two will be aborted by Postgres because we're
    # using a transaction with SERIALIZABLE isolation level. It may not look
    # it, but this code is safe from races.
    atomic_phase(key) do
      key = IdempotencyKey.first(user_id: user.id, idempotency_key: key_val)

      if key
        # Programs sending multiple requests with different parameters but the
        # same idempotency key is a bug.
        if key.request_params != params
          halt 409, JSON.generate(wrap_error(Messages.error_params_mismatch))
        end

        # Only acquire a lock if the key is unlocked or its lock as expired
        # because it was long enough ago.
        if key.locked_at && key.locked_at > Time.now - IDEMPOTENCY_KEY_LOCK_TIMEOUT
          halt 409, JSON.generate(wrap_error(Messages.error_request_in_progress))
        end

        # Lock the key and update latest run unless the request is already
        # finished.
        if key.recovery_point != RECOVERY_POINT_FINISHED
          key.update(last_run_at: Time.now, locked_at: Time.now)
        end
      else
        key = IdempotencyKey.create(
          idempotency_key: key_val,
          locked_at:       Time.now,
          recovery_point:  RECOVERY_POINT_STARTED,
          request_method:  request.request_method,
          request_params:  Sequel.pg_jsonb(params),
          request_path:    request.path_info,
          user_id:         user.id,
        )
      end

      # no response and no need to set a recovery point
      NoOp.new
    end

    # may be created on this request or retrieved if recovering a partially
    # completed previous request
    ride = nil

    loop do
      case key.recovery_point
      when RECOVERY_POINT_STARTED
        atomic_phase(key) do
          ride = Ride.create(
            idempotency_key_id: key.id,
            origin_lat:         params["origin_lat"],
            origin_lon:         params["origin_lon"],
            target_lat:         params["target_lat"],
            target_lon:         params["target_lon"],
            stripe_charge_id:   nil, # no charge created yet
            user_id:            user.id,
          )

          # in the same transaction insert an audit record for what happened
          AuditRecord.insert(
            action:        AUDIT_RIDE_CREATED,
            data:          Sequel.pg_jsonb(params),
            origin_ip:     request.ip,
            resource_id:   ride.id,
            resource_type: "ride",
            user_id:       user.id,
          )

          RecoveryPoint.new(RECOVERY_POINT_RIDE_CREATED)
        end

      when RECOVERY_POINT_RIDE_CREATED
        atomic_phase(key) do
          # retrieve a ride record if necessary (i.e. we're recovering)
          ride = Ride.first(idempotency_key_id: key.id) if ride.nil?

          # if ride is still nil by this point, we have a bug
          raise "Bug! Should have ride for key at #{RECOVERY_POINT_RIDE_CREATED}." \
            if ride.nil?

          raise "Simulated failed with `raise_error` param." if raise_error

          # Rocket Rides is still a new service, so during our prototype phase
          # we're going to give $20 fixed-cost rides to everyone, regardless of
          # distance. We'll implement a better algorithm later to better
          # represent the cost in time and jetfuel on the part of our pilots.
          begin
            charge = Stripe::Charge.create(
              amount:      20_00,
              currency:    "usd",
              customer:    user.stripe_customer_id,
              description: "Charge for ride #{ride.id}",
            )
          rescue Stripe::CardError
            # Sets the response on the key and short circuits execution by
            # sending execution right to 'finished'.
            Response.new(402, wrap_error(Messages.error_payment(error: $!.message)))
          rescue Stripe::StripeError
            Response.new(503, wrap_error(Messages.error_payment_generic))
          else
            ride.update(stripe_charge_id: charge.id)
            RecoveryPoint.new(RECOVERY_POINT_CHARGE_CREATED)
          end
        end

      when RECOVERY_POINT_CHARGE_CREATED
        atomic_phase(key) do
          # Send a receipt asynchronously by adding an entry to the staged_jobs
          # table. By funneling the job through Postgres, we make this
          # operation transaction-safe.
          StagedJob.insert(
            job_name: "send_ride_receipt",
            job_args: Sequel.pg_jsonb({
              amount:   20_00,
              currency: "usd",
              user_id:  user.id
            })
          )
          Response.new(201, wrap_ok(Messages.ok))
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
end

#
# constants
#

# Names of audit record actions.
AUDIT_RIDE_CREATED = "ride.created"

# Number of seconds passed since the last try on an idempotency key after which
# the completer will pick it up. This exists so that the completer isn't
# continually try to churn through the same requests that are failing over and
# over again.
IDEMPOTENCY_KEY_COMPLETER_LAST_RUN_THRESHOLD = 60

# Number of seconds passed after which we consider an unfinished idempotency
# key to be eligible for working by the completer.
IDEMPOTENCY_KEY_COMPLETER_TIMEOUT = 300

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

# Number of seconds after which we reap idempotency keys. This should be a much
# greater number than whatever a reasonable period is for a client to have
# retried the request a number of times or the completer to have tried it a few
# times.
#
# I've suggested 72 hours because in case of a bad bug that 500s a bunch of
# requests and which was deployed on Friday, 72 hours gives enough time for the
# entire weekend to pass, a developer to fix the problem on Monday, and then
# time for the completer to pass through and push all the failed requests to
# success.
IDEMPOTENCY_KEY_REAP_TIMEOUT = 72 * 3600

# Names of recovery points.
RECOVERY_POINT_STARTED        = "started"
RECOVERY_POINT_RIDE_CREATED   = "ride_created"
RECOVERY_POINT_CHARGE_CREATED = "charge_created"
RECOVERY_POINT_FINISHED       = "finished"

#
# models
#

class AuditRecord < Sequel::Model
end

class IdempotencyKey < Sequel::Model
end

class Ride < Sequel::Model
end

class StagedJob < Sequel::Model
end

class User < Sequel::Model
end

#
# other modules/classes
#

module Messages
  def self.ok
    "Payment accepted. Your pilot is on their way!"
  end

  def self.error_auth_invalid
    "Credentials in Authorization were invalid."
  end

  def self.error_auth_required
    "Please specify credentials in the Authorization header."
  end

  def self.error_internal
    "Internal server error. Please retry the request periodically with the " \
      "same Idempotency-Key until it succeeds."
  end

  def self.error_key_required
    "Please specify an idempotency key with the Idempotency-Key header."
  end

  def self.error_key_too_short
    "Idempotency-Key must be at least %s characters long." %
      [IDEMPOTENCY_KEY_MIN_LENGTH]
  end

  def self.error_params_mismatch
    "There was a mismatch between this request's parameters and the " \
      "parameters of a previously stored request with the same " \
      "Idempotency-Key."
  end

  def self.error_payment(error:)
    "Error from payment processor: #{error}"
  end

  def self.error_payment_generic
    "Error from payment processor. Please contact support."
  end

  def self.error_request_in_progress
    "An API request with the same Idempotency-Key is already in progress."
  end

  def self.error_require_bool(key:)
    "Parameter '#{key}' must be a boolean."
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

  def self.error_retry
    "Conflict detected with a concurrent request. Please retry with the " \
      "same Idmpotency-Key."
  end
end

# Represents an action to perform a no-op. One possible option for a return
# from an #atomic_phase block.
class NoOp
  def call(_key)
    # no-op
  end
end

# Represents an action to set a new recovery point. One possible option for a
# return from an #atomic_phase block.
class RecoveryPoint
  attr_accessor :name

  def initialize(name)
    self.name = name
  end

  def call(key)
    raise ArgumentError, "key must be provided" if key.nil?
    key.update(recovery_point: name)
  end
end

# Represents an action to set a new API response (which will be stored onto an
# idempotency key). One  possible option for a return from an #atomic_phase
# block.
class Response
  attr_accessor :data
  attr_accessor :status

  def initialize(status, data)
    self.status = status
    self.data = data
  end

  def call(key)
    raise ArgumentError, "key must be provided" if key.nil?
    key.update(
      locked_at: nil,
      recovery_point: RECOVERY_POINT_FINISHED,
      response_code: status,
      response_body: data
    )
  end
end

#
# helpers
#

# A simple wrapper for our atomic phases. We're not doing anything special here
# -- just defining some common transaction options and consolidating how we
# recover from various types of transactional failures.
def atomic_phase(key, &block)
  error = false
  begin
    DB.transaction(isolation: :serializable) do
      # A block is allowed to return a response which will short circuit
      # execution and push the key to "finished" state. Useful especially for
      # errors.
      ret = block.call

      if ret.is_a?(NoOp) || ret.is_a?(RecoveryPoint) || ret.is_a?(Response)
        ret.call(key)
      else
        raise "Blocks to #atomic_phase should return one of " \
          "NoOp, RecoveryPoint, or Response"
      end
    end
  rescue Sequel::SerializationFailure
    # you could possibly retry this error instead
    error = true
    raise if settings.raise_errors
    halt 429, JSON.generate(wrap_error(Messages.error_retry))
  rescue
    error = true
    raise if settings.raise_errors
    halt 500, JSON.generate(wrap_error(Messages.error_internal))
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

def authenticate_user(request)
  auth = request.env["HTTP_AUTHORIZATION"]
  if auth.nil? || auth.empty?
    halt 401, JSON.generate(wrap_error(Messages.error_auth_required))
  end

  # This is obviously something you shouldn't do in a real application, but for
  # now we're just going to trust that the user is whoever they said they were
  # from an email in the `Authorization` header.
  user = User.first(email: auth)
  if user.nil?
    halt 401, JSON.generate(wrap_error(Messages.error_auth_invalid))
  end

  user
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
  key = request.env["HTTP_IDEMPOTENCY_KEY"]

  if key.nil? || key.empty?
    halt 400, JSON.generate(wrap_error(Messages.error_key_required))
  end

  if key.length < IDEMPOTENCY_KEY_MIN_LENGTH
    halt 400, JSON.generate(wrap_error(Messages.error_key_too_short))
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

def validate_params_bool(request, key)
  val = validate_params_present(request, key)
  return true if val == "true"
  return false if val == "false"
  halt 422, JSON.generate(wrap_error(Messages.error_require_bool(key: key)))
end

def validate_params_float(request, key)
  val = validate_params_present(request, key)

  # Float as opposed to to_f because it's more strict about what it'll take.
  begin
    Float(val)
  rescue ArgumentError
    halt 422, JSON.generate(wrap_error(Messages.error_require_float(key: key)))
  end
end

def validate_params_lat(request, key)
  val = validate_params_float(request, key)
  return val if val >= -90.0 && val <= 90.0
  halt 422, JSON.generate(wrap_error(Messages.error_require_lat(key: key)))
end

def validate_params_lon(request, key)
  val = validate_params_float(request, key)
  return val if val >= -180.0 && val <= 180.0
  halt 422, JSON.generate(wrap_error(Messages.error_require_lon(key: key)))
end

def validate_params_present(request, key)
  val = request.POST[key]
  return val if !val.nil? && !val.empty?
  halt 422, JSON.generate(wrap_error(Messages.error_require_param(key: key)))
end

#
# run
#

if __FILE__ == $0
  API.run!
end
