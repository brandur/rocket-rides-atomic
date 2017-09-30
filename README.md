# rocket-rides-atomic [![Build Status](https://travis-ci.org/brandur/rocket-rides-atomic.svg?branch=master)](https://travis-ci.org/brandur/rocket-rides-atomic)

Requirements:

1. Postgres (`brew install postgres`)
2. Ruby (`brew install ruby`)
3. forego (`brew install forego`)

Setup:

```
bundle install
createdb rocket-rides-atomic
psql rocket-rides-atomic < schema.sql
forego run up.rb
forego start
```

Then try to create a ride:

```
curl -i -X POST http://localhost:5000/rides -H "Idempotency-Key: $(openssl rand -hex 32)" -d "origin_lat=0.0" -d "origin_lon=0.0" -d "target_lat=0.0" -d "target_lon=0.0"
```

Or with a non-random idempotency key:

```
export IDEMPOTENCY_KEY=$(openssl rand -hex 32)
curl -i -X POST http://localhost:5000/rides -H "Idempotency-Key: $IDEMPOTENCY_KEY" -d "origin_lat=0.0" -d "origin_lon=0.0" -d "target_lat=0.0" -d "target_lon=0.0"
```

## Development

Run the tests:

```
bundle install
createdb rocket-rides-atomic-test
psql rocket-rides-atomic-test < schema.sql
bundle exec rspec spec/
```
