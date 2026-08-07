# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

require_relative "config/application"

Greet::Application.initialize!
run Greet::Application
