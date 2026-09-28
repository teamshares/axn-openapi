# frozen_string_literal: true

RSpec.describe "invoked_via stamp" do
  it "stamps every tool call dispatched over HTTP as invoked_via=openapi" do
    events = capture_axn_calls do
      Axn::OpenAPI::Dispatcher.call(axn_class: EchoTool, params: { "message" => "hi" })
    end
    expect(axn_call_for(EchoTool, events)[:dimensions]).to include(invoked_via: "openapi")
  end
end
