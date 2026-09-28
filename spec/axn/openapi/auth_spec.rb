# frozen_string_literal: true

require "pp"

RSpec.describe Axn::OpenAPI::Auth do
  let(:bearer) { Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => "k1" }) }
  let(:api_key) { Axn::Extensions::Auth::Bearer.new(keys: { "svc" => "k2" }, header: "X-API-Key") }
  let(:jwt) { Axn::OpenAPI.documented_auth(->(_req) { true }, security_scheme: { type: "http", scheme: "bearer", bearerFormat: "JWT" }, name: "jwt") }

  describe ".strategies_for" do
    it "requires an explicit auth: — omitting it is refused, not treated as open" do
      expect { described_class.strategies_for(nil) }.to raise_error(Axn::OpenAPI::Error, /auth: is required.*auth: :none/m)
    end

    it "treats :none as the explicit opt-out" do
      expect(described_class.strategies_for(:none)).to eq([])
    end

    it "wraps one strategy, and keeps an Array (any-of) in order" do
      expect(described_class.strategies_for(bearer)).to eq([bearer])
      expect(described_class.strategies_for([api_key, bearer])).to eq([api_key, bearer])
    end

    it "refuses an empty list and anything that isn't callable" do
      expect { described_class.strategies_for([]) }.to raise_error(Axn::OpenAPI::Error, /at least one/)
      expect { described_class.strategies_for("token") }.to raise_error(Axn::OpenAPI::Error, /#call/)
      expect { described_class.strategies_for([bearer, :none]) }.to raise_error(Axn::OpenAPI::Error, /#call/)
    end
  end

  describe ".security_schemes" do
    it "maps a Bearer strategy to an http bearer scheme" do
      expect(described_class.security_schemes([bearer])).to eq("bearerAuth" => { "type" => "http", "scheme" => "bearer" })
    end

    it "maps a custom-header strategy to an apiKey scheme naming the header" do
      expect(described_class.security_schemes([api_key]))
        .to eq("apiKeyAuth" => { "type" => "apiKey", "in" => "header", "name" => "X-API-Key" })
    end

    it "uses a documented strategy's own scheme and name, string-keyed" do
      expect(described_class.security_schemes([jwt])).to eq("jwt" => { "type" => "http", "scheme" => "bearer", "bearerFormat" => "JWT" })
    end

    it "suffixes colliding names" do
      other = Axn::Extensions::Auth::Bearer.new(keys: { "ops" => "k3" })
      expect(described_class.security_schemes([bearer, other]).keys).to eq(%w[bearerAuth bearerAuth2])
    end

    it "refuses a strategy it can't describe, pointing at documented_auth" do
      expect { described_class.security_schemes([->(_req) { true }]) }
        .to raise_error(Axn::OpenAPI::Error, /documented_auth/)
    end

    it "is empty for :none" do
      expect(described_class.security_schemes([])).to eq({})
    end
  end

  describe ".unauthorized_headers" do
    it "merges every strategy's challenge" do
      basicish = Struct.new(:call, :unauthorized_headers).new(nil, { "www-authenticate" => "Basic" })
      expect(described_class.unauthorized_headers([api_key, bearer])).to eq("www-authenticate" => "Bearer")
      expect(described_class.unauthorized_headers([basicish, bearer])).to eq("www-authenticate" => "Basic, Bearer")
    end
  end

  describe ".known_principals" do
    it "unions what every strategy can authenticate as" do
      expect(described_class.known_principals([bearer, api_key])).to eq(%w[data_pipeline svc])
    end

    it "is nil (unknowable) when any strategy doesn't enumerate its principals" do
      expect(described_class.known_principals([bearer, jwt])).to be_nil
    end
  end

  describe ".documented_auth" do
    it "delegates call and optional metadata to the wrapped strategy" do
      wrapped = Axn::OpenAPI.documented_auth(bearer, security_scheme: { "type" => "http", "scheme" => "bearer" })
      request = Axn::OpenAPI::Request.new(http_method: "POST", path: "/", raw_body: "", script_name: "",
                                          headers: { "Authorization" => "Bearer k1" })
      expect(wrapped.call(request).principal).to eq("data_pipeline")
      expect(wrapped.principals).to eq(["data_pipeline"])
      expect(wrapped.unauthorized_headers).to eq("www-authenticate" => "Bearer")
      expect(wrapped.openapi_security_scheme_name).to eq("customAuth")
    end

    it "derives the 401 challenge from an http scheme when the wrapped strategy gives none" do
      expect(jwt.unauthorized_headers).to eq("www-authenticate" => "Bearer")
      basic = Axn::OpenAPI.documented_auth(->(_req) { true }, security_scheme: { type: "http", scheme: "basic" })
      expect(basic.unauthorized_headers).to eq("www-authenticate" => "Basic")
      api_key = Axn::OpenAPI.documented_auth(->(_req) { true }, security_scheme: { type: "apiKey", in: "header", name: "X-Key" })
      expect(api_key.unauthorized_headers).to eq({})
    end

    it "prefers the wrapped strategy's own challenge" do
      custom = Struct.new(:call, :unauthorized_headers).new(nil, { "www-authenticate" => 'Bearer realm="x"' })
      expect(Axn::OpenAPI.documented_auth(custom, security_scheme: { type: "http", scheme: "bearer" }).unauthorized_headers)
        .to eq("www-authenticate" => 'Bearer realm="x"')
    end

    it "refuses a non-callable strategy or a scheme without a type" do
      expect { Axn::OpenAPI.documented_auth("x", security_scheme: { type: "http" }) }.to raise_error(Axn::OpenAPI::Error, /#call/)
      expect { Axn::OpenAPI.documented_auth(bearer, security_scheme: { scheme: "bearer" }) }.to raise_error(Axn::OpenAPI::Error, /type/)
    end

    it "never renders the wrapped strategy's state" do
      secretive = Axn::Extensions::Auth::Bearer.new(keys: { "svc" => "super-secret" })
      wrapped = Axn::OpenAPI.documented_auth(secretive, security_scheme: { type: "http", scheme: "bearer" })
      expect(wrapped.inspect).not_to include("super-secret")
      expect(wrapped.pretty_inspect).not_to include("super-secret")
    end
  end
end
