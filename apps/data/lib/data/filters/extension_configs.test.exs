defmodule Data.Filters.ExtensionConfigsTest do
  @moduledoc "`Data.Filters.ExtensionConfigs` through `Data.Extension.configs/1`: site, version, the 422."

  use Data.DataCase, async: true

  alias Data.Extension
  alias Data.Extension.Config

  setup do
    upwork = config_fixture(:upwork)
    linkedin = config_fixture(:linkedin)
    %{upwork: upwork, linkedin: linkedin}
  end

  defp ids(where) do
    {:ok, configs} = Extension.configs(where)
    configs |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp direct(query), do: query |> Repo.all() |> Enum.map(& &1.id) |> Enum.sort()

  test "site: $EQUAL and $IN, as a direct query", c do
    assert ids(%{"site" => %{"$EQUAL" => "upwork"}}) ==
             direct(from(x in Config, where: x.site == :upwork))

    assert c.upwork.id in ids(%{"site" => "upwork"})
    refute c.linkedin.id in ids(%{"site" => "upwork"})

    assert ids(%{"site" => %{"$IN" => ["upwork", "linkedin"]}}) ==
             direct(from(x in Config, where: x.site in [:upwork, :linkedin]))
  end

  test "version: $EQUAL, $GTE, $LTE", c do
    v = c.upwork.version

    assert ids(%{"site" => "upwork", "version" => %{"$EQUAL" => to_string(v)}}) == [c.upwork.id]
    assert c.upwork.id in ids(%{"version" => %{"$GTE" => v}})
    refute c.upwork.id in ids(%{"site" => "upwork", "version" => %{"$LTE" => v - 1}})
  end

  test "anything else is refused, naming the field" do
    for {where, field} <- [
          {%{"site" => "monster"}, "site"},
          {%{"sha256" => "x"}, "sha256"},
          {%{"version" => %{"$IN" => [1]}}, "version"}
        ] do
      assert {:error, {:invalid_filter, %{^field => _}}} = Extension.configs(where)
    end
  end
end
