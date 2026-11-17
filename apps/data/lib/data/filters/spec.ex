defmodule Data.Filters.Spec do
  @moduledoc """
  A filter or sort module's allowlist, built **at compile time** from
  FatEcto's own options (`Data.Filters.__before_compile__/1` calls it):

  - a `filterable` field takes the operators listed for it — a joined
    table's field too (FatEcto itself would take any), with its binding and
    its column (an alias's schema field);
  - an `overrideable` field takes the operators given in `use Data.Filters,
    operators: [...]`, and the compiler refuses a module where the two
    lists name different fields;
  - a `sortable` field takes the directions listed, an `overrideable` sort
    the ones in `operators:`.

  `"*"` stays `:any`.
  """

  alias FatEcto.SharedHelper

  @doc "The `$where` allowlist: `%{fields: %{name => rule}, ignoreable: map}`."
  @spec filter_spec(Macro.Env.t(), keyword(), keyword()) :: map()
  def filter_spec(env, options, operators) do
    filterable = Keyword.get(options, :filterable, [])

    fields =
      Enum.flat_map(filterable, fn {name, value} = entry ->
        if SharedHelper.join_filter?(entry),
          do: Enum.map(value, &column(&1, name)),
          else: [column(entry, nil)]
      end)

    overrides = Enum.map(Keyword.get(options, :overrideable, []), &to_string/1)
    agree!(env, overrides, operators)

    overridden =
      Enum.map(operators, fn {name, ops} ->
        {to_string(name), %{ops: upcase(ops), kind: :override}}
      end)

    %{
      fields: Map.new(fields ++ overridden),
      ignoreable: SharedHelper.keyword_list_to_map(Keyword.get(options, :ignoreable, []))
    }
  end

  @doc "The `$order` allowlist: `%{sort: %{name => directions}}`."
  @spec sort_spec(Macro.Env.t(), keyword(), keyword()) :: map()
  def sort_spec(env, options, operators) do
    sortable = Keyword.get(options, :sortable, [])

    fields =
      Enum.flat_map(sortable, fn {_name, value} = entry ->
        if SharedHelper.join_filter?(entry),
          do: Enum.map(value, &sort_field/1),
          else: [sort_field(entry)]
      end)

    overrides = Enum.map(Keyword.get(options, :overrideable, []), &to_string/1)
    agree!(env, overrides, operators)
    overridden = Enum.map(operators, fn {name, dirs} -> {to_string(name), upcase(dirs)} end)

    %{sort: Map.new(fields ++ overridden)}
  end

  defp column({api, {schema_field, ops}}, binding) when is_atom(schema_field),
    do:
      {to_string(api), %{ops: upcase(ops), kind: :column, column: schema_field, binding: binding}}

  defp column({api, ops}, binding),
    do: {to_string(api), %{ops: upcase(ops), kind: :column, column: api, binding: binding}}

  defp sort_field({api, {_schema_field, dirs}}), do: {to_string(api), upcase(dirs)}
  defp sort_field({api, dirs}), do: {to_string(api), upcase(dirs)}

  defp upcase("*"), do: :any
  defp upcase(ops) when is_binary(ops), do: [String.upcase(ops)]
  defp upcase(ops) when is_list(ops), do: Enum.map(ops, &String.upcase/1)

  defp agree!(env, overrides, operators) do
    named = Enum.map(operators, fn {name, _ops} -> to_string(name) end)

    if Enum.sort(overrides) != Enum.sort(named) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "#{inspect(env.module)}: `overrideable` (#{inspect(overrides)}) and `operators:` " <>
            "(#{inspect(named)}) must name the same fields"
    end
  end
end
