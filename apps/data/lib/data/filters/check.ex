defmodule Data.Filters.Check do
  @moduledoc """
  `Data.Filters.where/4`'s checks, before FatEcto builds anything:

  1. the module's `ignoreable` values are dropped;
  2. every field, inside `$OR` / `$AND` too, must be in the allowlist
     (`Data.Filters.Spec`), and every operator one it takes; a bare value
     is `$EQUAL` (`$NULL` for `nil`), as FatEcto reads it;
  3. a column's value is cast to the column's type in the schema its
     binding names (`"true"` to a boolean, a key to an `Ecto.Enum`, ids to
     UUIDs; each of an `$IN`; both ends of a `$BETWEEN`; a date for
     `$CAST_TO_DATE_*`), so a bad one is a 422 here, not a crash in the
     planner;
  4. an override's value goes through the module's `prepare/4`.

  Answers the checked params, ready for `build/1`, or the refusal
  `{:invalid_filter, %{field => [words]}}`.
  """

  alias FatEcto.Query.Helper
  alias FatEcto.SharedHelper

  @range ~w($BETWEEN $BETWEEN_EQUAL $NOT_BETWEEN $NOT_BETWEEN_EQUAL)
  @lists ~w($IN $NOT_IN)
  @dates ~w($CAST_TO_DATE_EQUAL $CAST_TO_DATE_NOT_EQUAL $CAST_TO_DATE_GT $CAST_TO_DATE_GTE $CAST_TO_DATE_LT $CAST_TO_DATE_LTE)
  @texts ~w($LIKE $NOT_LIKE $ILIKE $NOT_ILIKE)
  @nulls ~w($NULL $NOT_NULL)

  @doc "The params checked against `module`'s allowlist for `query`: `{:ok, params}` or the refusal."
  @spec run(map(), module(), Ecto.Query.t(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, module, query, context) do
    spec = module.__filters__()
    params = Helper.remove_ignoreable_fields(params, spec.ignoreable)
    check_map(params, spec, module, query, context)
  end

  defp check_map(params, spec, module, query, context) do
    Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case check_entry(to_string(key), value, spec, module, query, context) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, checked} -> {:cont, {:ok, Map.put(acc, to_string(key), checked)}}
        error -> {:halt, error}
      end
    end)
  end

  defp check_entry(group, value, spec, module, query, context) when group in ["$OR", "$AND"] do
    conditions =
      cond do
        is_list(value) ->
          value

        is_map(value) and indexed?(value) ->
          value |> Enum.sort_by(&index/1) |> Enum.map(&elem(&1, 1))

        is_map(value) ->
          [value]

        true ->
          :bad
      end

    with true <- conditions != :bad || refuse(group, "is a list of filters"),
         {:ok, checked} <- check_conditions(conditions, group, spec, module, query, context) do
      {:ok, if(checked == [], do: nil, else: checked)}
    end
  end

  defp check_entry(field, value, spec, module, query, context) do
    case Map.fetch(spec.fields, field) do
      {:ok, rule} -> check_field(field, operators(value), rule, module, query, context)
      :error -> refuse(field, "is not a filter of this list")
    end
  end

  defp check_conditions(conditions, group, spec, module, query, context) do
    Enum.reduce_while(conditions, {:ok, []}, fn
      condition, {:ok, acc} when is_map(condition) ->
        case check_map(condition, spec, module, query, context) do
          {:ok, checked} when checked == %{} -> {:cont, {:ok, acc}}
          {:ok, checked} -> {:cont, {:ok, acc ++ [checked]}}
          error -> {:halt, error}
        end

      _other, _acc ->
        {:halt, refuse(group, "is a list of filters")}
    end)
  end

  # Phoenix decodes `$OR[0][state]=…` as `%{"0" => …}`: read it as a list.
  defp indexed?(map), do: map != %{} and Enum.all?(Map.keys(map), &(&1 =~ ~r/^\d+$/))
  defp index({key, _value}), do: String.to_integer(key)

  # A bare value is `$EQUAL`, `nil` is `$NULL`: FatEcto's reading.
  defp operators(value) when is_map(value) and not is_struct(value),
    do: Enum.map(value, fn {op, v} -> {String.upcase(to_string(op)), v} end)

  defp operators(nil), do: [{"$NULL", true}]
  defp operators(value), do: [{"$EQUAL", value}]

  defp check_field(field, pairs, rule, module, query, context) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {op, value}, {:ok, acc} ->
      with true <- allowed?(rule.ops, op) || refuse(field, "can't be filtered with #{op}"),
           {:ok, value} <- value(field, op, value, rule, module, query, context) do
        {:cont, {:ok, Map.put(acc, op, value)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp value(field, op, value, %{kind: :override}, module, _query, context) do
    if function_exported?(Code.ensure_loaded!(module), :prepare, 4) do
      case module.prepare(field, op, value, context) do
        {:ok, prepared} -> {:ok, prepared}
        :error -> refuse(field, "has a value this filter can't take")
      end
    else
      {:ok, value}
    end
  end

  defp value(field, op, value, rule, _module, query, _context) do
    case cast(op, value, type(query, rule)) do
      {:ok, cast} -> {:ok, cast}
      :error -> refuse(field, "has a value this filter can't take")
    end
  end

  defp cast(op, _value, _type) when op in @nulls, do: {:ok, true}

  defp cast(op, value, _type) when op in @dates do
    case SharedHelper.to_date(value) do
      {:ok, date} -> {:ok, date}
      _error -> :error
    end
  end

  defp cast(op, value, _type) when op in @texts and is_binary(value), do: {:ok, value}
  defp cast(op, _value, _type) when op in @texts, do: :error

  defp cast(op, values, type) when op in @lists do
    values
    |> listed()
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case cast_one(type, value) do
        {:ok, cast} -> {:cont, {:ok, acc ++ [cast]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp cast(op, values, type) when op in @range do
    with [low, high] <- listed(values),
         {:ok, low} <- cast_one(type, low),
         {:ok, high} <- cast_one(type, high) do
      {:ok, [low, high]}
    else
      _bad -> :error
    end
  end

  defp cast(_op, value, type), do: cast_one(type, value)

  defp cast_one(_type, value) when is_map(value) or is_list(value), do: :error
  defp cast_one(nil, value), do: {:ok, value}

  # A `:binary_id` casts any binary; the database would refuse it later.
  defp cast_one(:binary_id, value), do: Ecto.UUID.cast(value)

  defp cast_one(type, value) do
    case Ecto.Type.cast(type, value) do
      {:ok, nil} -> :error
      {:ok, cast} -> {:ok, cast}
      _error -> :error
    end
  end

  @doc """
  Values as sent, as a list: `$IN[]=a&$IN[]=b` is one; `%{"0" => a}` from
  `$IN[0]=a` too; a single value is a list of one.
  """
  @spec listed(term()) :: list()
  def listed(values) when is_list(values), do: values

  def listed(values) when is_map(values) and not is_struct(values) do
    if indexed?(values),
      do: values |> Enum.sort_by(&index/1) |> Enum.map(&elem(&1, 1)),
      else: [values]
  end

  def listed(nil), do: []
  def listed(value), do: [value]

  # The column's type in the schema its binding names (the root without one).
  defp type(query, %{column: column, binding: binding}) do
    case schema(query, binding) do
      nil -> nil
      schema -> schema.__schema__(:type, column)
    end
  end

  defp schema(%Ecto.Query{from: %{source: {_table, schema}}}, nil) when is_atom(schema),
    do: schema

  defp schema(_query, nil), do: nil

  defp schema(%Ecto.Query{} = query, binding) do
    case Enum.find_index(query.joins, &(&1.as == binding)) do
      nil -> nil
      index -> join_schema(query, Enum.at(query.joins, index))
    end
  end

  defp join_schema(_query, %{source: {_table, schema}}) when is_atom(schema), do: schema

  defp join_schema(query, %{assoc: {parent, field}}) do
    owner =
      if parent == 0,
        do: schema(query, nil),
        else: join_schema(query, Enum.at(query.joins, parent - 1))

    owner && owner.__schema__(:association, field) |> then(&(&1 && &1.related))
  end

  defp join_schema(_query, _join), do: nil

  @doc false
  def allowed?(:any, _op), do: true
  def allowed?(ops, op), do: op in ops

  defp refuse(field, words), do: {:error, {:invalid_filter, %{field => [words]}}}
end
