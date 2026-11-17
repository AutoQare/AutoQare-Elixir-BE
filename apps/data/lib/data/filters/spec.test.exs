defmodule Data.Filters.SpecTest do
  @moduledoc """
  The allowlists built from FatEcto's options: a column, a joined table's
  aliased field with its binding, an override's operators, a sort's
  directions, `"*"`.
  """

  use ExUnit.Case, async: true

  alias Data.Filters.Spec

  test "a filterable column, a joined field (aliased) and an override" do
    spec =
      Spec.filter_spec(
        __ENV__,
        [
          filterable: [
            state: ["$equal", "$in"],
            profile: {:profile_id, ["$EQUAL"]},
            job: [source: ["$IN"], title: "*"],
            stage: [stage: {:key, ["$EQUAL"]}]
          ],
          overrideable: ["q"],
          ignoreable: [q: ["", nil]]
        ],
        q: ["$ilike"]
      )

    assert spec.fields["state"] == %{
             ops: ["$EQUAL", "$IN"],
             kind: :column,
             column: :state,
             binding: nil
           }

    assert spec.fields["profile"] == %{
             ops: ["$EQUAL"],
             kind: :column,
             column: :profile_id,
             binding: nil
           }

    assert spec.fields["source"] == %{ops: ["$IN"], kind: :column, column: :source, binding: :job}
    assert spec.fields["title"].ops == :any

    assert spec.fields["stage"] == %{
             ops: ["$EQUAL"],
             kind: :column,
             column: :key,
             binding: :stage
           }

    assert spec.fields["q"] == %{ops: ["$ILIKE"], kind: :override}
    assert spec.ignoreable == %{"q" => ["", nil]}
  end

  test "a sort's directions, its overrides' from operators:" do
    spec =
      Spec.sort_spec(
        __ENV__,
        [sortable: [first_seen_at: ["$DESC"], name: "*"], overrideable: ["money"]],
        money: ["$desc"]
      )

    assert spec.sort == %{"first_seen_at" => ["$DESC"], "name" => :any, "money" => ["$DESC"]}
  end

  test "overrideable and operators: naming different fields is a compile error" do
    assert_raise CompileError, ~r/must name the same fields/, fn ->
      Spec.filter_spec(__ENV__, [filterable: [], overrideable: ["q"]], search: ["$ILIKE"])
    end
  end
end
