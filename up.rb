#
# Seeds some necessary fixtures.
#

require "sequel"
require "stripe"

DB = Sequel.connect(ENV["DATABASE_URL"] || abort("need DATABASE_URL"))
Stripe.api_key = ENV["STRIPE_API_KEY"] || abort("need STRIPE_API_KEY")

USERS = [
  [1, "user@example.com",            "tok_visa"],
  [2, "user-bad-source@example.com", "tok_chargeCustomerFail"],
]

USERS.each do |(id, email, stripe_source)|
  customer = Stripe::Customer.create(
    description: "Customer for email",
    source:      stripe_source
  )

  # upsert a default user
  DB[:users].
    insert_conflict(target: :id, update: {
      email:              Sequel[:excluded][:email],
      stripe_customer_id: Sequel[:excluded][:stripe_customer_id],
    }).
    insert({
      id:                 id,
      email:              email,
      stripe_customer_id: customer.id,
    })
end
