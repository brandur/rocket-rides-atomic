require_relative "./spec_helper"

require_relative "../reaper"

RSpec.describe Reaper do
  before do
    clear_database
    suppress_stdout
  end

  it "pushes through an existing idempotency key" do
    key = create_key(
      created_at: Time.now - IDEMPOTENCY_KEY_REAP_TIMEOUT - 1,
    )

    num_reaped = Reaper.new.run_once
    expect(num_reaped).to eq(1)

    expect(IdempotencyKey.count).to eq(0)
  end

  it "ignores keys not outside of reap threshold" do
    key = create_key(
      created_at: Time.now,
    )

    num_reaped = Reaper.new.run_once
    expect(num_reaped).to eq(0)
  end

  it "no-ops on an empty database" do
    num_reaped = Reaper.new.run_once
    expect(num_reaped).to eq(0)
  end
end
