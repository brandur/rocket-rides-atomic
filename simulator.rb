require "net/http"
require "securerandom"

require_relative "./api"

class Simulator
  def run
    loop do
      run_once
      sleep(rand(2))
    end
  end

  def run_once
    # created by up.rb
    user = User.first(email: "user@example.com")

    http = Net::HTTP.new("localhost", "5000")
    request = Net::HTTP::Post.new("/rides")
    request.set_form_data({
      "origin_lat" => 0.0,
      "origin_lon" => 0.0,
      "target_lat" => 0.0,
      "target_lon" => 0.0,
    })
    request["Authorization"] = user.email
    request["Idempotency-Key"] = SecureRandom.uuid

    response = http.request(request)
    $stdout.puts "Response: status=#{response.code} body=#{response.body}"
  end
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
