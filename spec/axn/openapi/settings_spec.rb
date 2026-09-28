# frozen_string_literal: true

RSpec.describe "mount / allowed_callers settings" do
  around do |example|
    mount = Axn::OpenAPI.config.mount
    callers = Axn::OpenAPI.config.allowed_callers
    example.run
  ensure
    Axn::OpenAPI.config.mount = mount
    Axn::OpenAPI.config.allowed_callers = callers
  end

  it "resolves per tool from a `tool openapi: {…}` declaration" do
    expect(Axn::OpenAPI.resolve_override_for(CredentialsTool, :mount)).to eq(:credentials)
    expect(Axn::OpenAPI.resolve_override_for(CredentialsTool, :allowed_callers)).to eq(["data_pipeline"])
  end

  it "defaults to the unnamed mount and no allowlist" do
    expect(Axn::OpenAPI.resolve_override_for(EchoTool, :mount)).to be_nil
    expect(Axn::OpenAPI.resolve_override_for(EchoTool, :allowed_callers)).to be_nil
  end

  it "accepts only a Symbol (or nil) mount" do
    expect { Axn::OpenAPI.config.mount = "credentials" }.to raise_error(ArgumentError, /mount must be a Symbol/)
    expect { Axn::OpenAPI.config.mount = :credentials }.not_to raise_error
    expect { Axn::OpenAPI.config.mount = nil }.not_to raise_error
  end

  it "accepts only a non-empty Array of String/Symbol principal ids (or nil)" do
    expect { Axn::OpenAPI.config.allowed_callers = [] }.to raise_error(ArgumentError, /allowed_callers/)
    expect { Axn::OpenAPI.config.allowed_callers = "data_pipeline" }.to raise_error(ArgumentError, /allowed_callers/)
    expect { Axn::OpenAPI.config.allowed_callers = [1] }.to raise_error(ArgumentError, /allowed_callers/)
    expect { Axn::OpenAPI.config.allowed_callers = ["a", :b] }.not_to raise_error
  end
end
