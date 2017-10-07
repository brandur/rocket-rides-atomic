require "uri"

require "./api"

class Completer
  def run
    loop do
      res = run_once

      # If we processed a total number of keys equal to our batch size then
      # presumably there are more keys to work on, so keep looping. Otherwise,
      # sleep so that we're not just looping over and over again on an empty
      # dataset.
      if res[:num_succeeded] + res[:num_failed] != BATCH_SIZE
        $stdout.puts "Sleeping for #{SLEEP_DURATION}"
        sleep(SLEEP_DURATION)
      end
    end
  end

  def run_once
    keys = IdempotencyKey.where(Sequel.lit(
      "recovery_point <> ? " \
        "AND created_at < ? " \
        "AND last_run_at < ? " \
        "AND (locked_at IS NULL OR locked_at < ?)",
      "finished",
      Time.now - IDEMPOTENCY_KEY_COMPLETER_TIMEOUT,
      Time.now - IDEMPOTENCY_KEY_COMPLETER_LAST_RUN_THRESHOLD,
      Time.now - IDEMPOTENCY_KEY_LOCK_TIMEOUT
    )).limit(BATCH_SIZE)

    api = API.new
    api.settings.raise_errors = true

    num_succeeded = 0
    num_failed = 0

    keys.each do |key|
      begin
        user = User.first(id: key.user_id)
        raise "bug!" if user.nil?

        status, _headers, _body_lines = api.call({
          "CONTENT_TYPE"         => "application/x-www-form-urlencoded",
          "HTTP_AUTHORIZATION"   => user.email,
          "HTTP_IDEMPOTENCY_KEY" => key.idempotency_key,
          "PATH_INFO"            => key.request_path,
          "REQUEST_METHOD"       => key.request_method,
          "REMOTE_ADDR"          => "127.0.0.1",
          "rack.input"           => StringIO.new(URI.encode_www_form(key.request_params)),
        })
        $stdout.puts "API call completed: status=#{status}"
        num_succeeded += 1
      rescue
        # also send this exception to Rollbar/Sentry for visibility
        $stdout.puts "API call failed: #{$!.message}"
        num_failed += 1
      end
    end

    { num_succeeded: num_succeeded, num_failed: num_failed }
  end

  # Number of keys to try to process in each batch.
  BATCH_SIZE = 1000
  private_constant :BATCH_SIZE

  # Sleep duration in seconds to sleep in case we ran but processed fewer keys
  # than our maximum batch size. Unless the completer isn't keeping up, then
  # back off for a while after each batch.
  SLEEP_DURATION = 5
  private_constant :SLEEP_DURATION
end

#
# run
#

if __FILE__ == $0
  # so output appears in Forego
  $stderr.sync = true
  $stdout.sync = true

  Completer.new.run
end
