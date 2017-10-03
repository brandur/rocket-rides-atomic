--
-- extracted from: https://brandur.org/idempotency-keys
--

BEGIN;

CREATE TABLE idempotency_keys (
    id              BIGSERIAL   PRIMARY KEY,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    idempotency_key TEXT        NOT NULL
        CHECK (char_length(idempotency_key) <= 100),
    locked_at       TIMESTAMPTZ DEFAULT now(),

    -- parameters of the incoming request
    request_method  TEXT        NOT NULL
        CHECK (char_length(request_method) <= 10),
    request_params  JSONB       NOT NULL,
    request_path    TEXT        NOT NULL
        CHECK (char_length(request_path) <= 100),

    -- for finished requests, stored status code and body
    response_code   INT         NULL,
    response_body   JSONB       NULL,

    recovery_point  TEXT        NOT NULL
        CHECK (char_length(recovery_point) <= 50),
    user_id         BIGINT      NOT NULL
);

CREATE UNIQUE INDEX idempotency_keys_user_id_idempotency_key
    ON idempotency_keys (user_id, idempotency_key);

--
-- A relation to hold records for every user of our app.
--
CREATE TABLE users (
    id                 BIGSERIAL       PRIMARY KEY,
    email              TEXT            NOT NULL UNIQUE
        CHECK (char_length(email) <= 255),

    -- Stripe customer record with an active credit card
    stripe_customer_id TEXT            NOT NULL UNIQUE
        CHECK (char_length(stripe_customer_id) <= 50)
);

CREATE INDEX users_email
    ON users (email);

--
-- Now that we have a users table, add a foreign key
-- constraint to idempotency_keys which we created above.
--
ALTER TABLE idempotency_keys
    ADD CONSTRAINT idempotency_keys_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT;

--
-- A relation that hold audit records that can help us piece
-- together exactly what happened in a request if necessary
-- after the fact. It can also, for example, be used to
-- drive internal security programs tasked with looking for
-- suspicious activity.
--
CREATE TABLE audit_records (
    id                 BIGSERIAL       PRIMARY KEY,

    -- action taken, for example "created"
    action             TEXT            NOT NULL
        CHECK (char_length(action) <= 50),

    created_at         TIMESTAMPTZ     NOT NULL DEFAULT now(),
    data               JSONB           NOT NULL,
    origin_ip          CIDR            NOT NULL,

    -- resource ID and type, for example "ride" ID 123
    resource_id        BIGINT          NOT NULL,
    resource_type      TEXT            NOT NULL
        CHECK (char_length(resource_type) <= 50),

    user_id            BIGINT          NOT NULL
        REFERENCES users ON DELETE RESTRICT
);

--
-- A relation representing a single ride by a user.
-- Notably, it holds the ID of a successful charge to
-- Stripe after we have one.
--
CREATE TABLE rides (
    id                 BIGSERIAL       PRIMARY KEY,
    created_at         TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- Store a reference to the idempotency key so that we can recover an
    -- already-created ride. Note that idempotency keys are not stored
    -- permanently, so make sure to SET NULL when a referenced key is being
    -- reaped.
    idempotency_key_id BIGINT          UNIQUE
        REFERENCES idempotency_keys ON DELETE SET NULL,

    -- origin and destination latitudes and longitudes
    origin_lat       NUMERIC(13, 10) NOT NULL,
    origin_lon       NUMERIC(13, 10) NOT NULL,
    target_lat       NUMERIC(13, 10) NOT NULL,
    target_lon       NUMERIC(13, 10) NOT NULL,

    -- ID of Stripe charge like ch_123; NULL until we have one
    stripe_charge_id   TEXT            UNIQUE
        CHECK (char_length(stripe_charge_id) <= 50),

    user_id            BIGINT          NOT NULL
        REFERENCES users ON DELETE RESTRICT
);

CREATE INDEX rides_idempotency_key_id
    ON rides (idempotency_key_id)
    WHERE idempotency_key_id IS NOT NULL;

--
-- A relation that holds our transactionally-staged jobs
-- (see "Background jobs and job staging" above).
--
CREATE TABLE staged_jobs (
    id                 BIGSERIAL       PRIMARY KEY,
    job_name           TEXT            NOT NULL,
    job_args           JSONB           NOT NULL
);

COMMIT;
