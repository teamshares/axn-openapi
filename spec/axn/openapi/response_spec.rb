# frozen_string_literal: true

RSpec.describe Axn::OpenAPI::Response do
  it "renders a Rack triple with lower-cased headers" do
    resp = described_class.new(status: 201, body: "hi", headers: { "X-A" => "b" })
    status, headers, body = resp.to_rack
    expect(status).to eq(201)
    expect(headers).to eq("x-a" => "b")
    expect(body).to eq(["hi"])
  end

  it "builds a JSON response with content-type and encoded body" do
    resp = described_class.json({ echoed: "hi" }, status: 200)
    status, headers, body = resp.to_rack
    expect(status).to eq(200)
    expect(headers["content-type"]).to eq("application/json")
    expect(JSON.parse(body.first)).to eq("echoed" => "hi")
  end

  it "compares by value" do
    a = described_class.new(status: 200, body: "x", headers: { "a" => "b" })
    b = described_class.new(status: 200, body: "x", headers: { "a" => "b" })
    expect(a).to eq(b)
  end

  it "defaults a nil body to an empty JSON object" do
    _, _, body = described_class.json(nil).to_rack
    expect(body).to eq(["{}"])
  end
end
