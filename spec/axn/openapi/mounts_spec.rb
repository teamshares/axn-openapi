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

    it "refuses serving one tool from two different mounts" do
      Axn::OpenAPI.app(auth: :none, mount: :adhoc, tools: [EchoTool])
      expect { Axn::OpenAPI.app(auth: :none) }
        .to raise_error(Axn::OpenAPI::Error, /EchoTool.*mount :adhoc.*default mount/)
    end

    it "lets a rebuild of the same mount from the same place replace its claim (Rails route reloading)" do
      build = ->(tools) { Axn::OpenAPI.app(auth: :none, mount: :adhoc, tools:) }
      [[EchoTool], [RefuseTool]].each { |tools| build.call(tools) }
      expect { Axn::OpenAPI.app(auth: :none, tools: [EchoTool]) }.not_to raise_error
    end

    it "refuses one mount built twice through a shared helper called from two places" do
      build = ->(auth) { Axn::OpenAPI.app(auth:, mount: :credentials) }
      build.call(Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => "strong" }))
      expect { build.call(Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => "weak" })) }
        .to raise_error(Axn::OpenAPI::Error, /mount :credentials is already built at .*mounts_spec\.rb:\d+/i)
    end

    it "refuses building one mount a second time from somewhere else (two live apps, one name)" do
      bearer = Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => "strong" })
      weak = Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => "weak" })
      Axn::OpenAPI.app(auth: bearer, mount: :credentials)
      expect { Axn::OpenAPI.app(auth: weak, mount: :credentials) }
        .to raise_error(Axn::OpenAPI::Error, /mount :credentials is already built at .*mounts_spec\.rb:\d+/i)
    end

    it "treats the default mount the same way" do
      Axn::OpenAPI.app(auth: :none, tools: [EchoTool])
      expect { Axn::OpenAPI.app(auth: :none, tools: [RefuseTool]) }.to raise_error(Axn::OpenAPI::Error, /the default mount is already built/i)
    end

    it "leaves no claim behind when a build fails" do
      expect { Axn::OpenAPI.app(auth: [->(_r) { true }], mount: :adhoc, tools: [EchoTool]) }.to raise_error(Axn::OpenAPI::Error, /documented_auth/)
      expect { Axn::OpenAPI.app(auth: :none, tools: [EchoTool]) }.not_to raise_error
    end

    it "forgets every claim on reset_mounts!" do
      Axn::OpenAPI.app(auth: :none, mount: :adhoc, tools: [EchoTool])
      Axn::OpenAPI.reset_mounts!
      expect { Axn::OpenAPI.app(auth: :none, tools: [EchoTool]) }.not_to raise_error
    end
  end
end
