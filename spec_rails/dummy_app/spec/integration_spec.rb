# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Axn::OpenAPI inside a Rails application" do
  it "boots the dummy Rails app" do
    expect(Rails.application).to be_a(Rails::Application)
  end

  it "loads the gem" do
    expect(defined?(Axn::OpenAPI)).to eq("constant")
  end
end
