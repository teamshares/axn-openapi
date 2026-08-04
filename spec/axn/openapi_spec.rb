# frozen_string_literal: true

RSpec.describe Axn::OpenAPI do
  it "exposes the acronym-cased namespace and version" do
    expect(Axn::OpenAPI::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end

  describe "Error" do
    # The gem's errors sit inside core's public-error boundary, so a caller wrapping a mount or a
    # render_axn call needs only one rescue for axn's errors and this adapter's.
    it "is rescuable as Axn::Error" do
      expect { raise Axn::OpenAPI::Error, "boom" }.to raise_error(Axn::Error, "boom")
    end

    # Axn::Error is a marker module precisely so tagging costs nothing structurally — anything
    # already rescuing StandardError (Rack middleware, a controller's rescue_from) still catches it.
    it "keeps its StandardError ancestry" do
      expect(Axn::OpenAPI::Error.ancestors).to include(StandardError)
    end

    # The tag is inherited, so a subclass cannot quietly fall outside the boundary its parent declared.
    it "carries the tag onto subclasses" do
      expect(Class.new(Axn::OpenAPI::Error).new).to be_a(Axn::Error)
    end
  end

  it "defaults its config" do
    expect(Axn::OpenAPI.config.path_prefix).to eq("")
    expect(Axn::OpenAPI.config.spec_path).to eq("/openapi.json")
    expect(Axn::OpenAPI.config.reject_undeclared_inputs).to be(false)
    expect(Axn::OpenAPI.config.reject_opaque_exposed_values).to be(true)
    expect(Axn::OpenAPI.config.info_title).to eq("Axn API")
    expect(Axn::OpenAPI.config.info_version).to eq("1.0.0")
  end
end
