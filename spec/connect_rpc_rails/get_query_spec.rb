# frozen_string_literal: true

# Copyright 2026 IVRy Inc.
# SPDX-License-Identifier: Apache-2.0

RSpec.describe(ConnectRpcRails::GetQuery) do
  def message_of(query_string)
    described_class.parse(query_string).message
  end

  describe ".parse" do
    it "reads the protocol's parameters in any order, among others" do
      query = described_class.parse("page=2&message=%7B%7D&encoding=json&connect=v1&compression=identity")

      expect([query.connect, query.encoding, query.compression, query.message])
        .to eq(["v1", "json", "identity", "{}"])
    end

    it "takes the first of a repeated parameter" do
      expect(described_class.parse("encoding=json&encoding=proto").encoding).to eq("json")
    end

    it "decodes + as a space, as form encoding does" do
      expect(message_of("message=%7B%22name%22%3A%22a+b%22%7D")).to eq('{"name":"a b"}')
    end

    it "drops a pair with invalid percent-encoding" do
      expect(described_class.parse("encoding=%zz&encoding=json").encoding).to eq("json")
    end
  end

  describe "#message" do
    it "raises InvalidMessage when the parameter is missing" do
      expect { message_of("encoding=json") }.to raise_error(described_class::InvalidMessage, /missing/)
    end

    it "decodes unpadded and padded URL-safe base64 with base64=1" do
      bytes = "\xFB\xFF\xBF".b * 2 + "A".b

      expect(message_of("base64=1&message=-_-_-_-_QQ")).to eq(bytes)
      expect(message_of("base64=1&message=-_-_-_-_QQ%3D%3D")).to eq(bytes)
    end

    it "rejects what is not URL-safe base64" do
      ["%2B%2F%2B%2F", "QQ%3D", "QUJDR", "QUJD%3D"].each do |message|
        expect { message_of("base64=1&message=#{message}") }
          .to raise_error(described_class::InvalidMessage), "accepted #{message}"
      end
    end

    it "takes the message as it is for a base64 value other than 1" do
      expect(message_of("base64=true&message=QQ")).to eq("QQ")
    end
  end
end
