# frozen_string_literal: true

# One strategy shared by the :credentials mount and the controller that serves the same tool, so both
# paths authenticate identically.
CREDENTIALS_AUTH = Axn::Extensions::Auth::Bearer.new(keys: {
                                                       "data_pipeline" => -> { ENV.fetch("DUMMY_PIPELINE_KEY", "pipeline-key") },
                                                       "ops" => "ops-key",
                                                     })
