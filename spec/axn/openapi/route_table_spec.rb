# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::RouteTable do
  it "builds one prefixed entry per version, ordered by tool_name then version" do
    entries = described_class.build(tools: [CalcV2Tool, CalcV1Tool], path_prefix: "")
    expect(entries.map(&:path)).to eq(["/calc/v1", "/calc/v2"])
    expect(entries.map(&:operation_id)).to eq(%w[calc_v1 calc_v2])
    expect(entries.map(&:axn)).to eq([CalcV1Tool, CalcV2Tool])
  end

  it "applies the path_prefix" do
    entries = described_class.build(tools: [CalcV1Tool], path_prefix: "/axns")
    expect(entries.first.path).to eq("/axns/calc/v1")
  end

  it "serves an undeclared-version tool at v1" do
    # `tool_name :solo` would be a no-op (it's a reader, not a setter — see
    # spec/support/versioned_tools.rb); `axn_name "solo"` is the real override DSL. Also, `ok` is a
    # reserved exposure field name (Axn::Core::Contract::RESERVED_FIELD_NAMES_FOR_EXPOSURES), so this
    # exposes `status` instead.
    tool = Class.new do
      include Axn

      axn_name "solo"
      exposes :status, type: Symbol
      def call = expose(status: :yes)
    end
    entries = described_class.build(tools: [tool], path_prefix: "")
    expect(entries.map(&:path)).to eq(["/solo/v1"])
    expect(entries.first.operation_id).to eq("solo_v1")
  end
end
