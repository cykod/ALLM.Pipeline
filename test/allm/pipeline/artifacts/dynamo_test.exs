defmodule ALLM.Pipeline.Artifacts.DynamoTest do
  @moduledoc """
  Unit tests for the pure parts of the DynamoDB artifact client. The I/O
  functions are exercised through `ALLM.Pipeline.ArtifactStoreTest`,
  which needs local DynamoDB; nothing here touches the network.
  """
  use ExUnit.Case, async: true

  alias ALLM.Pipeline.Artifacts.Dynamo

  describe "encoded_size/1" do
    # `put_artifact/6` stores the body base64-encoded, so this is the number the
    # size gate in `ArtifactStore.store/4` must compare against DynamoDB's item
    # limit — not `byte_size/1`.
    test "reports the base64 length, which is what put_artifact/6 actually stores" do
      for n <- [0, 1, 2, 3, 4, 100, 1023, 400 * 1024] do
        content = :binary.copy(<<0xAB>>, n)

        assert Dynamo.encoded_size(content) == byte_size(Base.encode64(content)),
               "encoded_size/1 disagreed with Base.encode64/1 at n=#{n}"
      end
    end

    test "is a third larger than the input, so a body under 400KB can still not fit" do
      content = :binary.copy(<<0xAB>>, 320 * 1024)

      assert byte_size(content) < 400 * 1024
      assert Dynamo.encoded_size(content) > 400 * 1024
    end
  end

  describe "fits_item?/1" do
    # Both edges of the metadata allowance. `max_payload_bytes/0` is the ENCODED
    # ceiling, so the largest admissible raw body is the largest `n` with
    # `4 * ceil(n / 3) <= max_payload_bytes` — derived here rather than hard-coded
    # so the pair moves with the constant.
    test "admits a body whose encoded form lands exactly on the ceiling, and rejects one byte more" do
      limit = Dynamo.max_payload_bytes()
      largest_raw = div(limit, 4) * 3

      assert Dynamo.encoded_size(:binary.copy("Z", largest_raw)) == limit
      assert Dynamo.fits_item?(:binary.copy("Z", largest_raw))
      refute Dynamo.fits_item?(:binary.copy("Z", largest_raw + 1))
    end

    test "reserves headroom for the item's non-content attributes" do
      # The reserve is real: a body encoding to exactly 400KB would leave nothing
      # for pk/sk/checksum/created_at and the item would be rejected server-side.
      assert Dynamo.max_payload_bytes() < 400 * 1024

      # ...and it is generous rather than tight — measured metadata is ~280 B.
      assert 400 * 1024 - Dynamo.max_payload_bytes() >= 1024
    end
  end
end
