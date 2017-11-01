require "net/http"
require "securerandom"

require_relative "./api"

class Simulator
  def initialize(port:)
    self.port = port
  end

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

    http = Net::HTTP.new("localhost", port)
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

  #
  # private
  #

  VALID_PARAMS = {
    "origin_lat" => 0.0,
    "origin_lon" => 0.0,
    "target_lat" => 0.0,
    "target_lon" => 0.0,
  }.freeze
  private_constant :VALID_PARAMS

  attr_accessor :port
end

#
# run
#

if __FILE__ == $0
  # so output appears in Forego
  $stderr.sync = true
  $stdout.sync = true

  port = ENV["API_PORT"] || abort("need API_PORT")

  # wait a moment for the API to come up
  sleep(3)

  Simulator.new(port: port).run
end
