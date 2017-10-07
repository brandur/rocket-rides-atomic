require "net/http"
require "securerandom"

require_relative "./api"

class Simulator
  def run
    loop do
      run_once
      duration = rand(2)
      $stdout.puts "Sleeping for #{duration}"
      sleep(duration)
    end
  end

  def run_once
    # created by up.rb
    user = User.first(email: "user@example.com")

    http = Net::HTTP.new("localhost", "5000")
    request = Net::HTTP::Post.new("/rides")
    request["Authorization"] = user.email
    request["Idempotency-Key"] = SecureRandom.uuid

    # Alternate randomly between successes and failures.
    res = rand(2)
    case res
    when 0
      request.set_form_data(VALID_PARAMS)
    when 1
      request.set_form_data(VALID_PARAMS.merge("raise_error" => "true"))
    end

    response = http.request(request)
    $stdout.puts "Response: status=#{response.code} body=#{response.body}"
  end

  VALID_PARAMS = {
    "origin_lat" => 0.0,
    "origin_lon" => 0.0,
    "target_lat" => 0.0,
    "target_lon" => 0.0,
  }.freeze
  private_constant :VALID_PARAMS
end

#
# run
#

if __FILE__ == $0
  # so output appears in Forego
  $stderr.sync = true
  $stdout.sync = true

  Simulator.new.run
end
