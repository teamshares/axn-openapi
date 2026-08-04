# frozen_string_literal: true

RSpec.describe "openapi adapter registration" do
  it "registers the :openapi adapter with core" do
    expect(Axn::Tools::Registry.adapters).to include(:openapi)
  end

  it "enumerates explicitly-declared :openapi tools" do
    expect(Axn::Tools.for(:openapi)).to include(EchoTool, RefuseTool)
  end
end
