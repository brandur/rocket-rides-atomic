#
# Seeds some necessary fixtures.
#

require "sequel"
require "stripe"

DB = Sequel.connect(ENV["DATABASE_URL"] || abort("need DATABASE_URL"))
Stripe.api_key = ENV["STRIPE_API_KEY"] || abort("need STRIPE_API_KEY")

EMAIL = "jane@example.com"

# We're going to chat a bit and set up a Stripe customer with an active card
# right away so that it's easier to create new charges from our program.
customer = Stripe::Customer.create(
  description: "Customer for #{EMAIL}",
  source:      "tok_visa"
)

# upsert a default user
DB[:users].
  insert_conflict(target: :id, update: {
    email:              Sequel[:excluded][:email],
    stripe_customer_id: Sequel[:excluded][:stripe_customer_id],
  }).
  insert({
    id:                 1,
    email:              EMAIL,
    stripe_customer_id: customer.id,
  })
