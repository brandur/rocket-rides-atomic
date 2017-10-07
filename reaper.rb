require "uri"

require_relative "./api"

class Reaper
  def run
    loop do
      num_reaped = run_once

      # Sleep for a while if we didn't find anything to reap on the last run.
      if num_reaped == 0
        $stdout.puts "Sleeping for #{SLEEP_DURATION}"
        sleep(SLEEP_DURATION)
      end
    end
  end

  def run_once
    num_reaped = 0

    IdempotencyKey.where(Sequel.lit(
      "id IN (SELECT id FROM idempotency_keys WHERE created_at < ? LIMIT ?)",
      Time.now - IDEMPOTENCY_KEY_REAP_TIMEOUT,
      BATCH_SIZE
    )).delete
  end

  # Number of idempotency keys to try to reap on each batch.
  BATCH_SIZE = 1000
  private_constant :BATCH_SIZE

  # Sleep duration in seconds to sleep in case we ran but didn't find anything
  # to reap.
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

  Reaper.new.run
end
