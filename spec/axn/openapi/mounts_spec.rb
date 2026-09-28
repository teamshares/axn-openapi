# frozen_string_literal: true

RSpec.describe "mounts" do
  describe "Axn::OpenAPI.tools(mount:)" do
    it "serves only tools bound to the named mount" do
      expect(Axn::OpenAPI.tools(mount: :credentials)).to contain_exactly(CredentialsTool, CredentialsPingTool)
    end

    it "keeps named-mount tools off the default mount" do
      expect(Axn::OpenAPI.tools).to include(EchoTool)
      expect(Axn::OpenAPI.tools).not_to include(CredentialsTool, CredentialsPingTool)
    end

    it "is empty for a mount nothing declares" do
      expect(Axn::OpenAPI.tools(mount: :nobody)).to eq([])
    end
  end

  describe "building apps" do
    it "refuses an explicit tool that declares a different mount" do
      expect { Axn::OpenAPI.app(auth: :none, tools: [CredentialsTool]) }
        .to raise_error(Axn::OpenAPI::Error, /CredentialsTool.*mount: :credentials.*default mount/)
      expect { Axn::OpenAPI.app(auth: :none, mount: :other, tools: [CredentialsTool]) }
        .to raise_error(Axn::OpenAPI::Error, /mount :other/)
    end

    it "accepts an explicit list of undeclared tools on a named mount (ad-hoc mounts)" do
      expect { Axn::OpenAPI.app(auth: :none, mount: :adhoc, tools: [CalcV1Tool]) }.not_to raise_error
    end

    it "keeps no process-wide registry: rebuilding a mount, or serving one undeclared tool from two mounts, is explicit consumer code" do
      expect do
        2.times { Axn::OpenAPI.app(auth: :none, mount: :adhoc, tools: [EchoTool]) }
        Axn::OpenAPI.app(auth: :none, tools: [EchoTool])
      end.not_to raise_error
    end
  end
end
