# frozen_string_literal: true

RSpec.describe Axn::OpenAPI do
  it "exposes the acronym-cased namespace and version" do
    expect(Axn::OpenAPI::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end

  it "defaults its config" do
    expect(Axn::OpenAPI.config.path_prefix).to eq("")
    expect(Axn::OpenAPI.config.spec_path).to eq("/openapi.json")
    expect(Axn::OpenAPI.config.reject_undeclared_inputs).to be(false)
    expect(Axn::OpenAPI.config.strict_serialization).to be(true)
    expect(Axn::OpenAPI.config.info_title).to eq("Axn API")
    expect(Axn::OpenAPI.config.info_version).to eq("1.0.0")
  end
end
