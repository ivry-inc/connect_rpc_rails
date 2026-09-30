# frozen_string_literal: true
# rbs_inline: enabled

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

# The protovalidate integration, required on its own because protovalidate is not a dependency
# of connect_rpc_rails: a service that declares no buf.validate rules never loads it.
#
#   require "connect_rpc_rails/protovalidate"

require "connect_rpc_rails/message_validatable"
