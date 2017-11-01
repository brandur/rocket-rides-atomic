require_relative "./spec_helper"
require_relative "../simulator"

WebMock.disable_net_connect!

RSpec.describe Simulator do
  before do
    clear_database
    suppress_stdout
    WebMock.enable!
  end

  it "initiates a request" do
    stub_request(:post, "http://localhost:5000/rides")
    Simulator.new(port: "5000").run_once
    assert_requested :post, "http://localhost:5000/rides"
  end
end
