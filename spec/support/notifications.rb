# frozen_string_literal: true

# Captures every `axn.call` notification payload emitted while the block runs.
module AxnCallEvents
  def capture_axn_calls(&)
    events = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { events << payload }, "axn.call", &)
    events
  end

  def axn_call_for(klass, events) = events.find { |e| e[:action].is_a?(klass) }
end

RSpec.configure { |config| config.include AxnCallEvents }
