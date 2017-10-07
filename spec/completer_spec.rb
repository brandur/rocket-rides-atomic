require "rspec"

require_relative "./spec_helper"

require_relative "../completer"

RSpec.describe Completer do
  before do
    clear_database
    suppress_stdout
  end

  it "pushes through an existing idempotency key" do
    key = create_key(
      created_at: Time.now - IDEMPOTENCY_KEY_COMPLETER_TIMEOUT - 1,
      last_run_at: Time.now - IDEMPOTENCY_KEY_COMPLETER_LAST_RUN_THRESHOLD - 1,
      recovery_point: RECOVERY_POINT_STARTED
    )

    res = Completer.new.run_once
    expect(res[:num_succeeded]).to eq(1)
    expect(res[:num_failed]).to eq(0)

    key.reload
    expect(key.recovery_point).to eq(RECOVERY_POINT_FINISHED)
    expect(key.response_code).to eq(201)
  end

  it "doesn't crash even on internal API exception" do
    expect(Stripe::Charge).to receive(:create) do
      raise Sequel::SerializationFailure, "Serialization failure."
    end

    key = create_key(
      created_at: Time.now - IDEMPOTENCY_KEY_COMPLETER_TIMEOUT - 1,
      last_run_at: Time.now - IDEMPOTENCY_KEY_COMPLETER_LAST_RUN_THRESHOLD - 1,
      recovery_point: RECOVERY_POINT_STARTED
    )

    res = Completer.new.run_once
    expect(res[:num_succeeded]).to eq(0)
    expect(res[:num_failed]).to eq(1)

    key.reload

    # passed one more atomic phase (compared to "started"), but still not
    # "finished"
    expect(key.recovery_point).to eq(RECOVERY_POINT_RIDE_CREATED)
  end

  it "ignores keys not yet within the completer's threshold" do
    key = create_key(
      created_at: Time.now,
      last_run_at: Time.now - IDEMPOTENCY_KEY_COMPLETER_LAST_RUN_THRESHOLD - 1,
      recovery_point: RECOVERY_POINT_STARTED
    )

    res = Completer.new.run_once
    expect(res[:num_succeeded]).to eq(0)
    expect(res[:num_failed]).to eq(0)
  end

  it "ignores keys that have been run recently" do
    key = create_key(
      created_at: Time.now - IDEMPOTENCY_KEY_COMPLETER_TIMEOUT - 1,
      last_run_at: Time.now,
      recovery_point: RECOVERY_POINT_STARTED
    )

    res = Completer.new.run_once
    expect(res[:num_succeeded]).to eq(0)
    expect(res[:num_failed]).to eq(0)
  end

  it "no-ops on an empty database" do
    res = Completer.new.run_once
    expect(res[:num_succeeded]).to eq(0)
    expect(res[:num_failed]).to eq(0)
  end

  it "ignores finished keys" do
    key = create_key(
      created_at: Time.now - IDEMPOTENCY_KEY_COMPLETER_TIMEOUT - 1,
      recovery_point: RECOVERY_POINT_FINISHED
    )

    res = Completer.new.run_once
    expect(res[:num_succeeded]).to eq(0)
    expect(res[:num_failed]).to eq(0)
  end
end
