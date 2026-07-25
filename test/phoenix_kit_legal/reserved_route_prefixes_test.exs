defmodule PhoenixKit.Modules.Legal.ReservedRoutePrefixesTest do
  @moduledoc """
  Pins that Legal reserves NO top-level route prefix, so Publishing's
  group-catch-all dispatch keeps serving the "legal" group it stores its
  generated pages in — at `/legal` and `/legal/:slug`.

  This is a regression guard, not a formality. 0.1.6 reserved "legal" here so
  a host-app LiveView could own the route instead; since no such LiveView
  ships with this module, the only observable effect on hosts that hadn't
  hand-written one was a 404 on every legal page. Re-adding the reservation
  without also shipping a renderer would reintroduce that outage.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Legal

  test "reserves no route prefix, leaving /legal to Publishing's dispatch" do
    assert Legal.reserved_route_prefixes() == []
  end
end
