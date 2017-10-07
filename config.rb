require "pg"
require "sequel"
require "stripe"

DB = Sequel.connect(ENV["DATABASE_URL"] || abort("need DATABASE_URL"))
DB.extension :pg_json
Stripe.api_key = ENV["STRIPE_API_KEY"] || abort("need STRIPE_API_KEY")

# a verbose mode to help with debugging
if ENV["VERBOSE"] == "true"
  DB.loggers << Logger.new($stdout)
  Stripe.log_level = Stripe::LEVEL_INFO
end
