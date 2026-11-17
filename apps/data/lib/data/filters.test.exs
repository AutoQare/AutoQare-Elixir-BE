defmodule Data.FiltersTest do
  @moduledoc """
  `Data.Filters`: the allowlist read from FatEcto's options, the 422 for
  what a list doesn't take, `$OR` / `$AND`, the ignoreable values, a JSON
  `$where`, the casts, `order/2`, and the compiler refusing a module whose
  `overrideable` and `operators:` disagree.
  """

  use Data.DataCase, async: true

  alias Data.Contacts.Contact
  alias Data.Filters

  setup do
    org = organisation_fixture()
    team = team_fixture(org)
    scope = scope_for(member_fixture(team, :lead), organisation: org)
    acme = company_fixture(org, name: "Acme")
    mei = contact_fixture(scope, name: "Mei Chen", company: acme)
    zed = contact_fixture(scope, name: "Zed Nobody")
    %{org: org, scope: scope, acme: acme, mei: mei, zed: zed}
  end

  defp run(c, where) do
    base = from(x in Contact, where: x.organisation_id == ^c.org.id)

    with {:ok, query} <- Filters.where(base, Filters.Contacts, where),
         do: {:ok, query |> Repo.all() |> Enum.map(& &1.name) |> Enum.sort()}
  end

  test "the allowlist is FatEcto's options: each field with its operators" do
    assert %{fields: %{"company_id" => %{ops: ops, kind: :column}, "q" => %{kind: :override}}} =
             Filters.Contacts.__filters__()

    assert "$IN" in ops
    refute "$GT" in ops
  end

  test "nothing, nil or an empty map filters nothing", c do
    for where <- [nil, %{}, "", "{}"] do
      assert run(c, where) == {:ok, ["Mei Chen", "Zed Nobody"]}
    end
  end

  test "an unlisted field, an unlisted operator, a bad value: 422 naming the field", c do
    assert {:error, {:invalid_filter, %{"colour" => ["is not a filter of this list"]}}} =
             run(c, %{"colour" => "red"})

    assert {:error, {:invalid_filter, %{"company_id" => ["can't be filtered with $LT"]}}} =
             run(c, %{"company_id" => %{"$LT" => c.acme.id}})

    assert {:error, {:invalid_filter, %{"company_id" => _}}} =
             run(c, %{"company_id" => %{"$IN" => ["x"]}})

    assert {:error, {:invalid_filter, %{"$where" => _}}} = run(c, "[1, 2]")
    assert {:error, {:invalid_filter, %{"$where" => _}}} = run(c, 7)
  end

  test "inside $OR and $AND too, fields are checked; both build", c do
    assert run(c, %{
             "$OR" => [%{"company_id" => %{"$NULL" => true}}, %{"q" => %{"$ILIKE" => "mei"}}]
           }) ==
             {:ok, ["Mei Chen", "Zed Nobody"]}

    assert run(c, %{
             "$AND" => [%{"company_id" => %{"$NULL" => true}}, %{"q" => %{"$ILIKE" => "mei"}}]
           }) ==
             {:ok, []}

    # Phoenix decodes `$OR[0][…]` as a map keyed by index.
    assert run(c, %{
             "$OR" => %{
               "0" => %{"q" => %{"$ILIKE" => "zed"}},
               "1" => %{"q" => %{"$ILIKE" => "mei"}}
             }
           }) ==
             {:ok, ["Mei Chen", "Zed Nobody"]}

    assert {:error, {:invalid_filter, %{"colour" => _}}} =
             run(c, %{"$OR" => [%{"colour" => "red"}]})
  end

  test "operators in any case; a JSON string is read; the ignoreable values filter nothing", c do
    assert run(c, %{"company_id" => %{"$equal" => c.acme.id}}) == {:ok, ["Mei Chen"]}
    assert run(c, ~s({"company_id": {"$EQUAL": "#{c.acme.id}"}})) == {:ok, ["Mei Chen"]}

    assert run(c, %{"q" => %{"$ILIKE" => ""}, "company_id" => ""}) ==
             {:ok, ["Mei Chen", "Zed Nobody"]}
  end

  test "default/3 sets a value only when the person didn't send one" do
    assert Filters.default(nil, "archived", false) == %{"archived" => false}
    assert Filters.default(%{"archived" => true}, "archived", false) == %{"archived" => true}
    assert Filters.value(%{"archived" => true}, "archived") == true
    assert Filters.value(nil, "archived") == nil
  end

  test "the helpers read a person's words" do
    assert Filters.words(" %acme% ") == {:ok, "acme"}
    assert Filters.words("%%") == {:ok, nil}
    assert Filters.words(3) == :error
    assert Filters.boolean("true") == {:ok, true}
    assert Filters.boolean("yes") == :error
    assert Filters.integer("30", [30, 60]) == {:ok, 30}
    assert Filters.integer("45", [30, 60]) == :error
    assert Filters.me_or_id("me", %{user_id: "u"}) == {:ok, "u"}
    assert Filters.me_or_id("nope", %{user_id: "u"}) == :error
    assert Filters.keys(["todo", "done"], ~w(todo done)) == {:ok, [:todo, :done]}
    assert Filters.keys("nope", ~w(todo done)) == :error
    assert Filters.listed(%{"1" => "b", "0" => "a"}) == ["a", "b"]
    assert Filters.date("2026-11-14") == {:ok, ~D[2026-11-14]}
    assert Filters.date("14/11") == :error
  end

  test "context/2: who is asking and the organisation's zone", c do
    ctx = Filters.context(c.scope, now: ~U[2026-11-14 10:00:00Z], team_id: "t")
    assert ctx.user_id == c.scope.user.id
    assert ctx.organisation_id == c.org.id
    assert ctx.team_id == "t"
    assert is_binary(ctx.zone)
  end

  test "a module whose overrideable and operators disagree does not compile" do
    source = """
    defmodule Data.FiltersTest.Broken do
      use FatEcto.Query.Dynamics.Buildable,
        filterable: [name: ["$EQUAL"]],
        overrideable: ["q"]

      use Data.Filters, operators: [search: ["$ILIKE"]]

      def override_buildable(_field, _operator, _value), do: nil
    end
    """

    assert_raise CompileError, ~r/must name the same fields/, fn ->
      Code.compile_string(source)
    end
  end
end
