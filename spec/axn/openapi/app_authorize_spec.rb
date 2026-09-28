# frozen_string_literal: true

require "rack/mock"

RSpec.describe "App authorization (403)" do
  let(:strategy) { Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => "pipeline-key", "ops" => "ops-key" }) }

  def post(app, path, token:, body: '{"company_uuid":"c-1"}')
    Rack::MockRequest.new(app).post(path, input: body, "HTTP_AUTHORIZATION" => "Bearer #{token}")
  end

  it "admits a principal on the tool's allowed_callers" do
    expect(post(Axn::OpenAPI.app(auth: strategy, mount: :credentials), "/credentials_tool/v1", token: "pipeline-key").status).to eq(200)
  end

  it "403s an authenticated principal that isn't on the list, with a generic body" do
    res = post(Axn::OpenAPI.app(auth: strategy, mount: :credentials), "/credentials_tool/v1", token: "ops-key")
    expect(res.status).to eq(403)
    expect(JSON.parse(res.body)).to eq("error" => { "message" => "Forbidden" })
  end

  it "admits any authenticated principal to a tool with no allowlist" do
    expect(post(Axn::OpenAPI.app(auth: strategy, mount: :credentials), "/credentials_ping_tool/v1", token: "ops-key", body: "").status).to eq(200)
  end

  it "answers 403 before 405, so a wrong verb doesn't reveal what a forbidden caller could do" do
    res = Rack::MockRequest.new(Axn::OpenAPI.app(auth: strategy, mount: :credentials))
                           .get("/credentials_tool/v1", "HTTP_AUTHORIZATION" => "Bearer ops-key")
    expect(res.status).to eq(403)
  end

  it "replaces the default check with an authorize: callable" do
    seen = []
    app = Axn::OpenAPI.app(auth: strategy, mount: :credentials, authorize: lambda { |principal, axn|
      seen << [principal, axn]
      principal == "ops"
    })
    expect(post(app, "/credentials_tool/v1", token: "ops-key").status).to eq(200)
    expect(post(app, "/credentials_tool/v1", token: "pipeline-key").status).to eq(403)
    expect(seen.first).to eq(["ops", CredentialsTool])
  end

  it "reads a policy's verdict object by ok?, never truthiness (a denying Result must deny)" do
    denying = Axn::Extensions::Auth::CREDENTIALS_MISMATCH
    result_like = Struct.new(:ok?).new(false)
    [denying, result_like].each do |verdict|
      Axn::OpenAPI.reset_mounts!
      app = Axn::OpenAPI.app(auth: strategy, mount: :credentials, authorize: ->(*) { verdict })
      expect(post(app, "/credentials_tool/v1", token: "pipeline-key").status).to eq(403)
    end
  end

  it "doesn't point a forbidden caller at a tool's latest version from a 404" do
    app = Axn::OpenAPI.app(auth: strategy, mount: :credentials)
    res = post(app, "/credentials_tool/v99", token: "ops-key")
    expect(res.status).to eq(404)
    expect(JSON.parse(res.body)).to eq("error" => { "message" => "Unknown tool: credentials_tool" })
    allowed = post(app, "/credentials_tool/v99", token: "pipeline-key")
    expect(JSON.parse(allowed.body)["error"]["message"]).to include("Latest available")
  end

  it "emits axn.call for a denial, tagged with the principal and operation" do
    events = capture_axn_calls { post(Axn::OpenAPI.app(auth: strategy, mount: :credentials), "/credentials_tool/v1", token: "ops-key") }
    denial = axn_call_for(Axn::OpenAPI::Authorize, events)
    expect(denial[:outcome]).to eq("failure")
    expect(denial[:tags]).to include(principal: "ops", operation_id: "credentials_tool_v1")
    expect(denial[:dimensions]).to include(mount: "credentials", invoked_via: "openapi")
  end

  describe "Axn::OpenAPI.allowed_caller?" do
    it "admits anyone for a tool with no allowlist" do
      expect(Axn::OpenAPI.allowed_caller?("anyone", CredentialsPingTool)).to be(true)
      expect(Axn::OpenAPI.allowed_caller?(nil, CredentialsPingTool)).to be(true)
    end

    it "matches String or Symbol principal ids against the allowlist" do
      expect(Axn::OpenAPI.allowed_caller?("data_pipeline", CredentialsTool)).to be(true)
      expect(Axn::OpenAPI.allowed_caller?(:data_pipeline, CredentialsTool)).to be(true)
      expect(Axn::OpenAPI.allowed_caller?("ops", CredentialsTool)).to be(false)
    end

    it "refuses a principal that isn't an id (it can't be matched against a list)" do
      expect(Axn::OpenAPI.allowed_caller?(nil, CredentialsTool)).to be(false)
      expect(Axn::OpenAPI.allowed_caller?({ "sub" => "data_pipeline" }, CredentialsTool)).to be(false)
    end
  end
end
