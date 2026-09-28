# frozen_string_literal: true

require "rack/mock"

RSpec.describe "App authentication" do
  let(:strategy) { Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => "pipeline-key", "ops" => "ops-key" }) }

  def credentials_app(**opts) = Axn::OpenAPI.app(auth: strategy, mount: :credentials, **opts)

  def post(app, path, token: nil, body: '{"company_uuid":"c-1"}', **env)
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    Rack::MockRequest.new(app).post(path, input: body, **env)
  end

  def json(res) = JSON.parse(res.body)

  describe "build time" do
    it "requires auth: on every app — omitting it is refused" do
      expect { Axn::OpenAPI.app(tools: [EchoTool]) }.to raise_error(Axn::OpenAPI::Error, /auth: is required/)
      expect { Axn::OpenAPI::App.new(tools: [EchoTool]) }.to raise_error(Axn::OpenAPI::Error, /auth: is required/)
    end

    it "refuses auth: :none beside an authorize: callable" do
      expect { Axn::OpenAPI.app(auth: :none, tools: [EchoTool], authorize: ->(*) { true }) }
        .to raise_error(Axn::OpenAPI::Error, /authorize:.*auth: :none/)
    end

    it "refuses auth: :none for a tool that declares allowed_callers" do
      expect { Axn::OpenAPI.app(auth: :none, mount: :credentials) }
        .to raise_error(Axn::OpenAPI::Error, /CredentialsTool.*allowed_callers.*auth: :none/)
    end

    it "refuses an allowed_callers entry no strategy can authenticate as" do
      other = Axn::Extensions::Auth::Bearer.new(keys: { "someone_else" => "k" })
      expect { Axn::OpenAPI.app(auth: other, mount: :credentials) }
        .to raise_error(Axn::OpenAPI::Error, /CredentialsTool.*"data_pipeline"/)
    end

    it "skips that check when a strategy can't enumerate its principals" do
      jwt = Axn::OpenAPI.documented_auth(->(_req) { true }, security_scheme: { type: "http", scheme: "bearer" })
      expect { Axn::OpenAPI.app(auth: jwt, mount: :credentials) }.not_to raise_error
    end
  end

  describe "auth: :none" do
    it "serves exactly as before" do
      res = post(Axn::OpenAPI.app(auth: :none, tools: [EchoTool]), "/echo_tool/v1", body: '{"message":"hi"}')
      expect(res.status).to eq(200)
      expect(json(res)).to eq("echoed" => "hi")
    end
  end

  describe "a Bearer-gated mount" do
    it "401s a request with no token, with the Bearer challenge and a generic body" do
      res = post(credentials_app, "/credentials_tool/v1")
      expect(res.status).to eq(401)
      expect(res.headers["www-authenticate"]).to eq("Bearer")
      expect(json(res)).to eq("error" => { "message" => "Unauthorized" })
    end

    it "401s a wrong token" do
      expect(post(credentials_app, "/credentials_tool/v1", token: "nope").status).to eq(401)
    end

    it "authenticates before routing, so an unknown path can't be probed for existence" do
      app = credentials_app
      expect(post(app, "/nope/v1").status).to eq(401)
      expect(post(app, "/nope/v1", token: "ops-key").status).to eq(404)
    end

    it "gates the served OpenAPI document by default" do
      mock = Rack::MockRequest.new(credentials_app)
      expect(mock.get("/openapi.json").status).to eq(401)
      expect(mock.get("/openapi.json", "HTTP_AUTHORIZATION" => "Bearer ops-key").status).to eq(200)
    end

    it "serves the document without auth when public_spec: true — but still gates the tools" do
      app = credentials_app(public_spec: true)
      expect(Rack::MockRequest.new(app).get("/openapi.json").status).to eq(200)
      expect(post(app, "/credentials_ping_tool/v1").status).to eq(401)
    end

    it "serves a good token, exposing the principal in the env" do
      seen = nil
      app = credentials_app(context: ->(env) { seen = env[Axn::OpenAPI::PRINCIPAL_ENV_KEY] and {} })
      res = post(app, "/credentials_ping_tool/v1", token: "ops-key", body: "")
      expect(res.status).to eq(200)
      expect(seen).to eq("ops")
    end

    it "hands the principal to a two-argument context:" do
      app = credentials_app(context: ->(_env, principal) { { caller_id: principal } })
      res = post(app, "/credentials_tool/v1", token: "pipeline-key")
      expect(json(res)).to eq("company_uuid" => "c-1", "caller_id" => "data_pipeline")
    end

    it "keeps calling a context: that takes at most one (optional) argument with the env alone" do
      optional = ->(env = nil) { { caller_id: env&.fetch(Axn::OpenAPI::PRINCIPAL_ENV_KEY) } }
      callable = Class.new { def call(env = nil) = { caller_id: env&.fetch(Axn::OpenAPI::PRINCIPAL_ENV_KEY) } }.new
      [optional, callable].each do |context|
        res = post(credentials_app(context:), "/credentials_tool/v1", token: "pipeline-key")
        expect(json(res)).to eq("company_uuid" => "c-1", "caller_id" => "data_pipeline")
      end
    end

    it "hands the principal to a context: taking a splat or an optional second argument" do
      [->(*args) { { caller_id: args[1] } }, ->(_env, principal = nil) { { caller_id: principal } }].each do |context|
        res = post(credentials_app(context:), "/credentials_tool/v1", token: "pipeline-key")
        expect(json(res)).to eq("company_uuid" => "c-1", "caller_id" => "data_pipeline")
      end
    end

    it "evaluates context: only when a tool is actually dispatched" do
      calls = 0
      app = credentials_app(context: ->(_env) { calls += 1 and {} })
      post(app, "/nope/v1", token: "ops-key")
      post(app, "/credentials_tool/v1")
      expect(calls).to eq(0)
    end

    it "accepts any of several strategies" do
      api_key = Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => "hdr-key" }, header: "X-API-Key")
      app = Axn::OpenAPI.app(auth: [api_key, strategy], mount: :credentials)
      expect(post(app, "/credentials_tool/v1", "HTTP_X_API_KEY" => "hdr-key").status).to eq(200)
      expect(post(app, "/credentials_tool/v1", token: "pipeline-key").status).to eq(200)
      expect(post(app, "/credentials_tool/v1", token: "nope").status).to eq(401)
    end

    it "maps a raising (misconfigured) strategy to a generic 500, never a 401" do
      broken = Axn::Extensions::Auth::Bearer.new(keys: { "svc" => -> { "" } })
      res = post(Axn::OpenAPI.app(auth: broken, tools: [EchoTool]), "/echo_tool/v1", token: "x", body: '{"message":"hi"}')
      expect(res.status).to eq(500)
      expect(json(res)).to eq(Axn::OpenAPI::Dispatcher::GENERIC_500)
    end
  end

  describe "observability" do
    it "runs authentication as an axn, so a rejection emits axn.call with its reason and mount" do
      events = capture_axn_calls { post(credentials_app, "/credentials_tool/v1", token: "nope") }
      gate = axn_call_for(Axn::OpenAPI::Authenticate, events)
      expect(gate[:outcome]).to eq("failure")
      expect(gate[:dimensions]).to include(reason: "credentials_mismatch", mount: "credentials", invoked_via: "openapi")
    end

    it "tags the authenticated principal on success" do
      events = capture_axn_calls { post(credentials_app, "/credentials_tool/v1", token: "pipeline-key") }
      expect(axn_call_for(Axn::OpenAPI::Authenticate, events)[:tags]).to include(principal: "data_pipeline")
      expect(axn_call_for(CredentialsTool, events)[:dimensions]).to include(invoked_via: "openapi")
    end

    it "never renders the presented token in the gate's log output" do
      output = StringIO.new
      logger = Logger.new(output)
      allow(Axn.config).to receive(:logger).and_return(logger)
      app = credentials_app
      post(app, "/credentials_tool/v1", token: "pipeline-key")
      post(app, "/credentials_tool/v1", token: "wrong-secret-token")
      expect(output.string).not_to include("pipeline-key")
      expect(output.string).not_to include("wrong-secret-token")
    end
  end
end
