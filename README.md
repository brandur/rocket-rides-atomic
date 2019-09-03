# rocket-rides-atomic [![Build Status](https://travis-ci.org/brandur/rocket-rides-atomic.svg?branch=master)](https://travis-ci.org/brandur/rocket-rides-atomic)

This is a project based on the original [Rocket Rides][rides] repository to
demonstrate what it might look like to implement idempotency keys in the same
vein as Stripe's. See [the associated article][keys] for full details.

The work done API service is separated into _atomic phases_, and as the name
suggests, all the work done during the phase is guaranteed to be atomic. Midway
through each API request a call is made out to Stripe's API which can't be
rolled back if it fails, so if it does we rely on clients re-issuing the API
request with the same `Idempotency-Key` header until its results are
definitive. After any request is considered to be complete, the results are
stored on the idempotency key relation and returned for any future requests
that use the same key.

## Architecture

If you look in `Procfile`, you'll see these processes:

* `api`: The main Rocket Rides API. It responds to requests and makes them
  idempotent using a required `Idempotency-Key` header.
* `completer`: Finds failed API requests and attempts to push them through to
  completion (after a grace period to give the user a chance to do it first).
* `enqueuer`: Moves [transactionally-staged jobs][jobs] out of the database and
  over into a real job queue to be worked.
* `reaper`: Reaps idempotency keys after some extended period wherein failed
  API requests would have been retried by a client or the `completer` a number
  of times already.
* `simulator`: Randomly issues requests that will either succeed or fail to
  simulate traffic against `api` and give `completer` and `enqueuer` a chance
  to do something.

After you run `forego start` you should see the `simulator` issuing jobs
against `api` right away. Some of these will succeed with a `201`, and that
will give the `enqueuer` something to do. Some will fail with a `500` as the
`simulator` simulates some level of failure.

If you leave the programs running long enough, the `completer` will kick in and
start to finish up any of the `simulator`'s failed API requests. It only starts
completing jobs that are at least five minutes old to give the original client
a chance to retry them first.

If you leave the programs running _really_ long, the `reaper` will kick in and
start removing keys that are at least 72 hours old.

## Setup

Requirements:

1. Postgres (`brew install postgres`)
2. Ruby (`brew install ruby`)
3. forego (`brew install forego`)

Install dependencies, create a database and schema, and start running the
processes:

```
bundle install
createdb rocket-rides-atomic
psql rocket-rides-atomic < schema.sql
forego run ruby up.rb
forego start
```

After those are running, from another terminal you should be able to create a
ride:

```
curl -i -X POST http://localhost:5000/rides -H "Authorization: user@example.com" -H "Idempotency-Key: $(openssl rand -hex 32)" -d "origin_lat=0.0" -d "origin_lon=0.0" -d "target_lat=0.0" -d "target_lon=0.0"
```

Or with a non-random idempotency key:

```
export IDEMPOTENCY_KEY=$(openssl rand -hex 32)
curl -i -X POST http://localhost:5000/rides -H "Authorization: user@example.com" -H "Idempotency-Key: $IDEMPOTENCY_KEY" -d "origin_lat=0.0" -d "origin_lon=0.0" -d "target_lat=0.0" -d "target_lon=0.0"
```

## Development & testing

Install dependencies, create a test database and schema, and then run the test
suite:

```
bundle install
createdb rocket-rides-atomic-test
psql rocket-rides-atomic-test < schema.sql
bundle exec rspec spec/
```

[jobs]: https://brandur.org/job-drain
[keys]: https://brandur.org/idempotency-keys
[rides]: https://github.com/stripe/stripe-connect-rocketrides

<!--
# vim: set tw=79:
-->
