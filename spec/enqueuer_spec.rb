require_relative "./spec_helper"

require_relative "../enqueuer"

RSpec.describe Enqueuer do
  before do
    clear_database
    suppress_stdout
  end

  it "enqueues and removes a staged job" do
    create_staged_job

    num_enqueued = Enqueuer.new.run_once
    expect(num_enqueued).to eq(1)

    expect(StagedJob.count).to eq(0)
  end

  it "no-ops on an empty database" do
    num_enqueued = Enqueuer.new.run_once
    expect(num_enqueued).to eq(0)
  end

  private def create_staged_job
    StagedJob.insert(
      job_name: "send_ride_receipt",
      job_args: Sequel.pg_jsonb({
        amount:   20_00,
        currency: "usd",
        user_id:  user.id
      })
    )
  end
end
