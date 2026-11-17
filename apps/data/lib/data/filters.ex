defmodule Data.Filters do
  @moduledoc """
  Every list's filters and sorts (AQ-11B §11.4), on **FatEcto** as myqampus
  runs it: one module per list in `apps/data/lib/data/filters/`, each
  `use FatEcto.Query.Dynamics.Buildable` with `filterable`, `overrideable`
  and `ignoreable`, every computed filter an `override_buildable/3`
  returning a `dynamic`; where a person picks the order, a
  `Data.Filters.<List>Sort` on `FatEcto.Sort.Sortable`.

  **FatEcto drops what it doesn't know** (an unlisted field or operator
  builds nothing), so a list never calls `build/1` itself: it calls
  `where/4`, which checks every field and operator of `$where` against the
  module's allowlist first and answers **422 `invalid_filter`** naming the
  field — then builds, and puts the dynamic into the list's **scoped base
  query**, which still decides access.

  ## A filter module

      defmodule Data.Filters.Contacts do
        use FatEcto.Query.Dynamics.Buildable,
          filterable: [company_id: ["$EQUAL", "$IN"]],
          overrideable: ["q"],
          ignoreable: [q: ["", "%%", nil]]

        use Data.Filters, operators: [q: ["$ILIKE"]]

        def override_buildable("q", "$ILIKE", text), do: dynamic(...)
        def override_buildable(_field, _operator, _value), do: nil
      end

  `use Data.Filters` reads FatEcto's options at compile time and adds
  `__filters__/0`, the allowlist (`Data.Filters.Spec`): a `filterable`
  field takes the operators listed for it (a joined table's field too,
  though FatEcto would take any); an `overrideable` field takes the
  operators given in `operators:` — the compiler refuses a module where the
  two lists name different fields.

  ## What `where/4` does, in order (steps 2–5 are `Data.Filters.Check`)

  1. `$where` is a map (Phoenix decodes `$where[state][$IN][]=todo` into
     one; a JSON string is read too); `nil` or `%{}` filters nothing.
  2. The module's `ignoreable` values are dropped ("no filter").
  3. Every field, inside `$OR` / `$AND` too, must be listed, and every
     operator one it takes; a bare value is `$EQUAL` (`$NULL` for `nil`),
     as FatEcto reads it.
  4. A listed column's value is cast to the column's type (`"true"` to a
     boolean, a key to an `Ecto.Enum`, ids to UUIDs; each of an `$IN`;
     both ends of a `$BETWEEN`; a date for `$CAST_TO_DATE_*`) so a bad one
     is a 422 here rather than a crash in the planner.
  5. An override's value goes through the module's `prepare/4`, which reads
     the words a person sends (`"me"`, `"30"`, `"today"`) into what the
     override builds with, using the `context/2` map — who is asking, *now*
     and the organisation's zone, since a rule never reads the clock — or
     refuses it (`:error`, a 422).
  6. FatEcto builds; the dynamic goes into the query with `where/3`.

  `order/2` checks `$order` against a `Sortable` module the same way and
  hands back the pairs; the list turns them into its keyset (a direction
  the cursor can't page is simply not listed).

  **Paging stays each list's own** (keyset cursors where they were); the
  in-memory sorts with no SQL form (the Tracker's `next`, `labels`,
  `missing`; the pool's `suggested_for` score) and the per-row access
  rules (approvals' `tab`) stay in Elixir and say so in their modules.
  """

  require Ecto.Query

  alias Data.Filters.{Check, Spec}
  alias Data.Scope

  @typedoc "What an override may need: who is asking, *now*, the zone, the list's own."
  @type context :: %{
          optional(:user_id) => binary() | nil,
          optional(:organisation_id) => binary() | nil,
          optional(:team_id) => binary() | nil,
          optional(:now) => DateTime.t(),
          optional(:zone) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "A refusal: `{:invalid_filter, %{field => [words]}}`, a 422 `invalid_filter`."
  @type refusal :: {:invalid_filter, %{String.t() => [String.t()]}}

  @doc """
  Reads a person's value of an override into what `override_buildable/3`
  builds with — `{:ok, value}` — or refuses it with `:error`. A module
  without it hands values on as sent.
  """
  @callback prepare(field :: String.t(), operator :: String.t(), value :: term(), context()) ::
              {:ok, term()} | :error

  @optional_callbacks prepare: 4

  defmacro __using__(opts) do
    quote do
      @behaviour Data.Filters
      @data_filters_operators unquote(Keyword.get(opts, :operators, []))
      @before_compile Data.Filters
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    options = Module.get_attribute(env.module, :options) || []
    operators = Module.get_attribute(env.module, :data_filters_operators) || []

    spec =
      if Keyword.has_key?(options, :sortable),
        do: Spec.sort_spec(env, options, operators),
        else: Spec.filter_spec(env, options, operators)

    quote do
      @doc false
      def __filters__, do: unquote(Macro.escape(spec))
    end
  end

  # ── The context ─────────────────────────────────────────────────────────────

  @doc """
  The map an override reads: `user_id` and `organisation_id` from the
  scope, the organisation's `zone` (`Etc/UTC` when it names none), `now`
  (the caller's, from `Core.Clock` at the edge) and anything else the list
  passes (`team_id`, `rules`).
  """
  @spec context(Scope.t(), keyword()) :: context()
  def context(%Scope{} = scope, opts) do
    zone =
      case scope.organisation do
        %{timezone: zone} when is_binary(zone) and zone != "" -> zone
        _none -> "Etc/UTC"
      end

    opts
    |> Map.new()
    |> Map.put_new(:zone, zone)
    |> Map.merge(%{user_id: Scope.user_id(scope), organisation_id: Scope.organisation_id(scope)})
  end

  # ── $where ──────────────────────────────────────────────────────────────────

  @doc """
  `query` narrowed by `params` (a list's `$where`) through `module`:
  `{:ok, query}`, or `{:error, {:invalid_filter, %{field => [words]}}}` for
  a field, an operator or a value the list doesn't take.
  """
  @spec where(Ecto.Queryable.t(), module(), term(), context()) ::
          {:ok, Ecto.Query.t()} | {:error, refusal()}
  def where(queryable, module, params, context \\ %{}) do
    query = Ecto.Queryable.to_query(queryable)

    with {:ok, params} <- decode(params),
         {:ok, checked} <- Check.run(params, module, query, context) do
      case checked == %{} || module.build(checked) do
        true -> {:ok, query}
        nil -> {:ok, query}
        dynamic -> {:ok, Ecto.Query.where(query, [], ^dynamic)}
      end
    end
  end

  @doc """
  `params` with `field` set to `value` unless the person sent it: a list's
  default as a filter (`archived {$EQUAL: false}` until somebody asks for
  the archived).
  """
  @spec default(term(), String.t(), term()) :: map()
  def default(params, field, value) do
    case decode(params) do
      {:ok, map} -> Map.put_new(map, field, value)
      {:error, _refusal} -> params
    end
  end

  @doc "The top-level `$where` value of `field`, after decoding: `nil` when not sent."
  @spec value(term(), String.t()) :: term()
  def value(params, field) do
    case decode(params) do
      {:ok, map} -> Map.get(map, field)
      {:error, _refusal} -> nil
    end
  end

  @doc false
  def decode(nil), do: {:ok, %{}}
  def decode(""), do: {:ok, %{}}
  def decode(params) when is_map(params), do: {:ok, params}

  def decode(params) when is_binary(params) do
    case Jason.decode(params) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _not_a_map -> refuse("$where", "is not a filter object")
    end
  end

  def decode(_params), do: refuse("$where", "is not a filter object")

  @doc "Values as sent, as a list (`Data.Filters.Check.listed/1`)."
  @spec listed(term()) :: list()
  defdelegate listed(values), to: Check

  # ── Helpers the filter modules share ────────────────────────────────────────

  @doc """
  A search's words as sent (`q {$ILIKE: "acme"}`; `%` around them, as
  FatEcto's clients send, is trimmed): `{:ok, text}`, `{:ok, nil}` for
  nothing, `:error` for a value that isn't text.
  """
  @spec words(term()) :: {:ok, String.t() | nil} | :error
  def words(value) when is_binary(value) do
    case value |> String.trim() |> String.trim("%") |> String.trim() do
      "" -> {:ok, nil}
      text -> {:ok, text}
    end
  end

  def words(_value), do: :error

  @doc "`true` / `false` as sent (`\"true\"` from a query string): `{:ok, boolean}` or `:error`."
  @spec boolean(term()) :: {:ok, boolean()} | :error
  def boolean(value) when value in [true, "true"], do: {:ok, true}
  def boolean(value) when value in [false, "false"], do: {:ok, false}
  def boolean(_value), do: :error

  @doc "An id as sent: `{:ok, uuid}` or `:error`."
  @spec id(term()) :: {:ok, binary()} | :error
  def id(value) when is_binary(value), do: Ecto.UUID.cast(value)
  def id(_value), do: :error

  @doc "Ids as sent (`$IN[]=…`, or one): `{:ok, [uuid]}` or `:error`."
  @spec ids(term()) :: {:ok, [binary()]} | :error
  def ids(values) do
    values
    |> listed()
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case id(value) do
        {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
        :error -> {:halt, :error}
      end
    end)
  end

  @doc """
  An id, or `"me"` for whoever is asking (`context.user_id`): `{:ok,
  uuid}` or `:error`.
  """
  @spec me_or_id(term(), context()) :: {:ok, binary()} | :error
  def me_or_id("me", %{user_id: me}) when is_binary(me), do: {:ok, me}
  def me_or_id(value, _context), do: id(value)

  @doc "Keys of a vocabulary as sent (one, or a list): `{:ok, [atom]}` or `:error`."
  @spec keys(term(), [String.t()]) :: {:ok, [atom()]} | :error
  def keys(values, allowed) do
    values = Enum.map(listed(values), &to_string/1)

    if values != [] and Enum.all?(values, &(&1 in allowed)),
      do: {:ok, Enum.map(values, &String.to_existing_atom/1)},
      else: :error
  end

  @doc "A whole number as sent, in `allowed` when given: `{:ok, n}` or `:error`."
  @spec integer(term(), [integer()] | nil) :: {:ok, integer()} | :error
  def integer(value, allowed \\ nil)

  def integer(value, allowed) when is_integer(value),
    do: if(is_nil(allowed) or value in allowed, do: {:ok, value}, else: :error)

  def integer(value, allowed) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> integer(n, allowed)
      _other -> :error
    end
  end

  def integer(_value, _allowed), do: :error

  @doc "A calendar day as sent (`YYYY-MM-DD`): `{:ok, date}` or `:error`."
  @spec date(term()) :: {:ok, Date.t()} | :error
  def date(%Date{} = date), do: {:ok, date}

  def date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      _error -> :error
    end
  end

  def date(_value), do: :error

  @doc """
  Local days `[first, last]` (both kept) in `zone` as UTC instants `{from,
  to}`, `to` exclusive: the dashboards' windows (`Utils.Days`, the copy
  `Core.Dashboards.Windows` reads), for a `$BETWEEN` of dates.
  """
  @spec day_range(Date.t(), Date.t(), String.t()) :: {DateTime.t(), DateTime.t()}
  defdelegate day_range(first, last, zone), to: Utils.Days, as: :window

  @doc "*Today* in `zone` at `now` (`Utils.Days`')."
  @spec today(DateTime.t(), String.t()) :: Date.t()
  defdelegate today(now, zone), to: Utils.Days

  # ── $order ──────────────────────────────────────────────────────────────────

  @doc """
  `$order` (`{field => "$ASC" | "$DESC"}`) checked against a `Sortable`
  module: `{:ok, [{field, direction}]}` (empty when nothing was asked), or
  the 422 naming the field. The list builds its order (and its keyset) from
  the pairs, `module.build/1` giving FatEcto's `order_by` expressions.
  """
  @spec order(module(), term()) :: {:ok, [{String.t(), String.t()}]} | {:error, refusal()}
  def order(module, params) do
    with {:ok, params} <- decode_order(params) do
      allowed = module.__filters__().sort
      Enum.reduce_while(params, {:ok, []}, &sort_step(allowed, &1, &2))
    end
  end

  defp sort_step(allowed, {field, dir}, {:ok, acc}) do
    case sort_pair(allowed, to_string(field), dir) do
      {:ok, pair} -> {:cont, {:ok, acc ++ [pair]}}
      error -> {:halt, error}
    end
  end

  defp sort_pair(allowed, field, dir) do
    dir = if is_binary(dir), do: String.upcase(dir), else: dir

    case Map.fetch(allowed, field) do
      {:ok, dirs} ->
        if is_binary(dir) and Check.allowed?(dirs, dir),
          do: {:ok, {field, dir}},
          else: refuse(field, "can't be sorted #{inspect(dir)}")

      :error ->
        refuse(field, "is not a sort of this list")
    end
  end

  defp decode_order(nil), do: {:ok, %{}}
  defp decode_order(""), do: {:ok, %{}}
  defp decode_order(params) when is_map(params), do: {:ok, params}

  defp decode_order(params) when is_binary(params) do
    case Jason.decode(params) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _not_a_map -> refuse("$order", "is not a sort object")
    end
  end

  defp decode_order(_params), do: refuse("$order", "is not a sort object")

  defp refuse(field, words), do: {:error, {:invalid_filter, %{field => [words]}}}
end
