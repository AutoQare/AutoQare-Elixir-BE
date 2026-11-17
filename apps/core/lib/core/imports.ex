defmodule Core.Imports do
  @moduledoc """
  The import centre (AQ-12 §3, §11.4): a `.csv` or `.xlsx` brought into a
  team as applications, jobs or contacts — read, mapped, checked by a dry
  run, imported one row per transaction, and undone once within seven
  days. The steps run in the background (`Core.Imports.Steps` by
  `Core.Workers.ImportStep`); every verb here answers the import as it
  stands and enqueues what comes next.

  **Who** (QP12-1): a team lead of the import's team, or the system admin.
  Anyone else — staff of the team included — gets `:not_found`, for the
  list, an import, its rows and every verb.

  | Verb | From | Then |
  |---|---|---|
  | `create/3` | — | `reading` → `mapping` (413 `import_too_large`, 422 `import_unreadable` first) |
  | `update/4` (tabs, mapping, date order, overwrite) | `mapping` · `ready` | `checking` → `ready`; else 409 `import_not_ready` |
  | `edit_row/5`, `skip_row/4` | `ready` | the row checked again (or skipped) at once |
  | `commit/3` | `ready` | `importing` → `imported`; else 409 `import_not_ready` |
  | `undo/3` | `imported`, until `undo_until` | `undoing` → `undone`; 409 `undo_expired` after, `import_not_undoable` otherwise |
  """

  alias Core.Audit
  alias Core.Imports.{Check, Fields, Read, Sheet, Steps}
  alias Core.Realtime
  alias Core.Storage
  alias Core.Workers.ImportStep
  alias Data.Imports, as: Store
  alias Data.Imports.Import
  alias Data.Scope
  alias Data.Teams
  alias Data.Vocabulary

  @page 100
  @max_page 500

  # ── Who ─────────────────────────────────────────────────────────────────────

  @doc "Whether `scope` may run imports for `team_id`: a lead of it, or the system admin."
  @spec may?(Scope.t(), binary()) :: boolean()
  def may?(%Scope{} = scope, team_id),
    do: Scope.admin?(scope) or Scope.team_role(scope, team_id) == :lead

  @doc "The import behind `id`, if the caller may run imports for its team."
  @spec fetch(Scope.t(), term()) :: {:ok, Import.t()} | {:error, :not_found}
  def fetch(%Scope{} = scope, id) do
    with %Import{} = import <- Store.get(Scope.organisation_id(scope), id) || {:error, :not_found},
         true <- may?(scope, import.team_id) || {:error, :not_found},
         do: {:ok, import}
  end

  defp team(scope, id) do
    case Utils.presence(to_string(id || "")) do
      nil ->
        {:error, {:missing, [:team_id]}}

      id ->
        with %{archived_at: nil} = team <- Teams.get(Scope.organisation_id(scope), id),
             true <- may?(scope, team.id) do
          {:ok, team}
        else
          _other -> {:error, :not_found}
        end
    end
  end

  # ── Reads ───────────────────────────────────────────────────────────────────

  @doc "`GET /imports?team_id=`: `{items: [import]}`, newest first."
  @spec list(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def list(%Scope{} = scope, params, %DateTime{} = now) do
    with {:ok, team} <- team(scope, params["team_id"]) do
      imports = Store.list(Scope.organisation_id(scope), [team.id])
      {:ok, %{items: Enum.map(imports, &Sheet.view(&1, now))}}
    end
  end

  @doc "`GET /imports/:id`."
  @spec get(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def get(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, import} <- fetch(scope, id), do: {:ok, Sheet.view(import, now)}
  end

  @doc """
  `GET /imports/:id/rows?$where&cursor&limit`: `{items: [row], next_cursor}`,
  by tab and row number; `$where` is `Data.Filters.ImportRows`'.
  """
  @spec rows(Scope.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def rows(%Scope{} = scope, id, params) do
    with {:ok, import} <- fetch(scope, id),
         {:ok, after_key} <- cursor(params["cursor"]),
         {:ok, limit} <- limit(params["limit"]),
         {:ok, rows} <- Store.rows_page(import.id, params["$where"], after_key, limit) do
      {page, more} = Enum.split(rows, limit)
      last = List.last(page)

      {:ok,
       %{
         items: Enum.map(page, &Sheet.row/1),
         next_cursor: if(more != [] and last, do: encode(last), else: nil)
       }}
    end
  end

  defp encode(row),
    do: Base.url_encode64(Jason.encode!([row.tab, row.row_number]), padding: false)

  defp cursor(nil), do: {:ok, nil}
  defp cursor(""), do: {:ok, nil}

  defp cursor(token) when is_binary(token) do
    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, [tab, n]} when is_binary(tab) and is_integer(n) <- Jason.decode(json) do
      {:ok, {tab, n}}
    else
      _bad -> invalid("cursor", "is not a cursor of this list")
    end
  end

  defp cursor(_token), do: invalid("cursor", "is not a cursor of this list")

  defp limit(nil), do: {:ok, @page}

  defp limit(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n in 1..@max_page -> {:ok, n}
      _bad -> invalid("limit", "is a number from 1 to #{@max_page}")
    end
  end

  # ── Create ──────────────────────────────────────────────────────────────────

  @doc """
  `POST /imports {team_id, media_id, kind}`: the uploaded file (an
  `import` media the caller confirmed) checked against the caps and its
  format, then `reading` in the background. Answers the import.
  """
  @spec create(Scope.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def create(%Scope{} = scope, params, %DateTime{} = now) do
    with {:ok, team} <- team(scope, params["team_id"]),
         {:ok, kind} <- kind(params["kind"]),
         {:ok, media} <- media(scope, params["media_id"]),
         {:ok, bytes} <- Storage.fetch(media.storage_key) |> readable(),
         name = media.original_filename || "import.csv",
         :ok <- Read.check(bytes, name, Steps.limits()),
         {:ok, import} <-
           Store.create(%{
             organisation_id: Scope.organisation_id(scope),
             team_id: team.id,
             created_by_user_id: Scope.user_id(scope),
             media_id: media.id,
             file_name: name,
             kind: kind,
             state: :reading
           }) do
      {:ok, _audit} =
        Audit.record(scope, "created", import,
          after: %{"file_name" => name, "kind" => kind},
          now: now
        )

      after_step(scope, import, "read", now)
    end
  end

  defp kind(kind) when is_binary(kind) do
    if kind in Vocabulary.import_kinds(),
      do: {:ok, kind},
      else: invalid("kind", "is applications, jobs or contacts")
  end

  defp kind(_missing), do: {:error, {:missing, [:kind]}}

  defp media(_scope, nil), do: {:error, {:missing, [:media_id]}}

  # The sheet as uploaded: `media_kind: import`, or — as the console sends
  # it — an `attachment` that is a CSV or an `.xlsx`.
  defp media(scope, id) do
    with {:error, :not_found} <- Core.Media.own_uploaded(scope, to_string(id), :import),
         {:ok, %{content_type: type} = media} <-
           Core.Media.own_uploaded(scope, to_string(id), :attachment),
         true <- type in Core.Media.allowed_types(:import) do
      {:ok, media}
    else
      {:ok, media} -> {:ok, media}
      _other -> invalid("media_id", "isn't a file you uploaded for an import")
    end
  end

  defp readable({:ok, bytes}), do: {:ok, bytes}
  defp readable(_missing), do: {:error, :import_unreadable}

  # ── The Map step ────────────────────────────────────────────────────────────

  @doc """
  `PATCH /imports/:id {tabs?, mapping?, date_order?, overwrite?}`: the Map
  step's choices — per tab its profile, who applied and whether it is
  imported; a field per column; the date order; *Overwrite* — then the dry
  run again (`checking`). Only while `mapping` or `ready`.
  """
  @spec update(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def update(%Scope{} = scope, id, params, %DateTime{} = now) do
    with {:ok, import} <- fetch(scope, id),
         :ok <- in_state(import, [:mapping, :ready]),
         {:ok, attrs} <- choices(scope, import, params, now),
         {:ok, import} <- Store.update(import, Map.merge(attrs, %{state: :checking, progress: 0})) do
      after_step(scope, import, "check", now)
    end
  end

  defp choices(scope, import, params, now) do
    with {:ok, tabs} <- tabs(scope, import, params["tabs"], now),
         {:ok, mapping} <- mapping(import, params["mapping"]),
         {:ok, order} <- date_order(params["date_order"], import.date_order),
         {:ok, overwrite} <- overwrite(params["overwrite"], import.overwrite) do
      {:ok, %{tabs: tabs, mapping: mapping, date_order: order, overwrite: overwrite}}
    end
  end

  defp tabs(_scope, import, nil, _now), do: {:ok, import.tabs}

  defp tabs(scope, import, sent, now) when is_list(sent) do
    ctx = Check.context(scope, import, now)
    Enum.reduce_while(sent, {:ok, import.tabs}, &tab_step(ctx, &1, &2))
  end

  defp tabs(_scope, _import, _sent, _now),
    do: invalid("tabs", "is a list of {name, profile_id, applier_user_id, include}")

  defp tab_step(ctx, change, {:ok, tabs}) do
    case tab_change(ctx, tabs, Map.new(change, fn {k, v} -> {to_string(k), v} end)) do
      {:ok, tabs} -> {:cont, {:ok, tabs}}
      error -> {:halt, error}
    end
  end

  defp tab_change(ctx, tabs, change) do
    cond do
      not Enum.any?(tabs, &(&1["name"] == change["name"])) ->
        invalid("tabs", "names a tab the file doesn't have: #{change["name"]}")

      not one_of?(change["profile_id"], ctx.profiles) ->
        invalid("tabs", "has a profile this team doesn't serve")

      not one_of?(change["applier_user_id"], ctx.members) ->
        invalid("tabs", "has someone who applied who isn't in this team")

      true ->
        kept = Map.take(change, ~w(profile_id applier_user_id include))

        {:ok,
         Enum.map(tabs, &if(&1["name"] == change["name"], do: Map.merge(&1, kept), else: &1))}
    end
  end

  # Nothing chosen is fine; a choice must be one of the list.
  defp one_of?(nil, _list), do: true
  defp one_of?(id, list), do: Enum.any?(list, &(&1.id == id))

  defp mapping(import, nil), do: {:ok, import.mapping}

  defp mapping(import, sent) when is_map(sent) do
    headers = import.tabs |> Enum.flat_map(&(&1["headers"] || [])) |> MapSet.new()

    case Enum.find(sent, fn {header, field} ->
           not MapSet.member?(headers, header) or not Fields.known?(import.kind, field)
         end) do
      # Only the headers someone mapped are sent; any other is `ignore`.
      nil ->
        {:ok, sent}

      {header, _field} ->
        invalid("mapping", "maps “#{header}” to a field this import doesn't take")
    end
  end

  defp mapping(_import, _sent), do: invalid("mapping", "is {column: field}")

  defp date_order(nil, current), do: {:ok, current}
  defp date_order(order, _current) when order in ["day_month", "month_day"], do: {:ok, order}
  defp date_order(_order, _current), do: invalid("date_order", "is day_month or month_day")

  defp overwrite(nil, current), do: {:ok, current}
  defp overwrite(value, _current) when value in [true, "true"], do: {:ok, true}
  defp overwrite(value, _current) when value in [false, "false"], do: {:ok, false}
  defp overwrite(_value, _current), do: invalid("overwrite", "is true or false")

  # ── The preview's rows ──────────────────────────────────────────────────────

  @doc """
  `PATCH /imports/:id/rows/:row_id {cells}`: the row's full cells (header →
  text; a blank cell is none), the row checked again.
  """
  @spec edit_row(Scope.t(), term(), term(), map(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def edit_row(%Scope{} = scope, id, row_id, params, %DateTime{} = now) do
    with {:ok, import} <- fetch(scope, id),
         :ok <- in_state(import, [:ready]),
         {:ok, row} <- row(import, row_id),
         {:ok, cells} <- cells(row, params["cells"]) do
      ctx = Check.context(scope, import, now)
      order = Enum.map(import.tabs, & &1["name"])
      earlier = import.id |> Store.rows() |> Enum.filter(&before?(&1, row, order))

      {attrs, _seen} =
        Check.row(scope, ctx, %{row | cells: cells, result: nil}, Check.seen_from(ctx, earlier))

      {:ok, row} = Store.update_row(row, Map.merge(%{cells: cells, values: %{}}, attrs))
      recount(import)
      {:ok, Sheet.row(row)}
    end
  end

  @doc "`POST /imports/:id/rows/:row_id/skip`: the row left out of the import."
  @spec skip_row(Scope.t(), term(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def skip_row(%Scope{} = scope, id, row_id, %DateTime{} = _now) do
    with {:ok, import} <- fetch(scope, id),
         :ok <- in_state(import, [:ready]),
         {:ok, row} <- row(import, row_id) do
      skipped = %{"code" => "skipped", "words" => "Skipped by hand."}
      {:ok, row} = Store.update_row(row, %{result: :skipped, reasons: [skipped | row.reasons]})
      recount(import)
      {:ok, Sheet.row(row)}
    end
  end

  defp row(import, row_id) do
    case Store.get_row(import.id, row_id) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  defp cells(_row, sent) when is_map(sent) do
    if Enum.all?(sent, fn {k, v} -> is_binary(k) and (is_binary(v) or is_nil(v)) end) do
      {:ok,
       for {header, value} <- sent, text = Utils.presence(value || ""), into: %{} do
         {header, String.trim(text)}
       end}
    else
      invalid("cells", "is {column: text}")
    end
  end

  defp cells(_row, nil), do: {:error, {:missing, [:cells]}}
  defp cells(_row, _sent), do: invalid("cells", "is {column: text}")

  defp before?(other, row, order) do
    index = &(Enum.find_index(order, fn name -> name == &1 end) || 0)
    {index.(other.tab), other.row_number} < {index.(row.tab), row.row_number}
  end

  defp recount(import) do
    {:ok, _import} = Store.update(import, %{counts: Steps.counts(import)})
  end

  # ── Import and undo ─────────────────────────────────────────────────────────

  @doc "`POST /imports/:id/commit`: the `new` and `update` rows imported in the background."
  @spec commit(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def commit(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, import} <- fetch(scope, id),
         :ok <- in_state(import, [:ready]),
         {:ok, import} <- Store.update(import, %{state: :importing, progress: 0}) do
      after_step(scope, import, "commit", now)
    end
  end

  @doc "`POST /imports/:id/undo`: once, until `undo_until`."
  @spec undo(Scope.t(), term(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def undo(%Scope{} = scope, id, %DateTime{} = now) do
    with {:ok, import} <- fetch(scope, id),
         :ok <- undoable(import, now),
         {:ok, import} <- Store.update(import, %{state: :undoing, progress: 0}) do
      after_step(scope, import, "undo", now)
    end
  end

  defp undoable(%Import{state: :imported, undo_until: until}, now) do
    if DateTime.after?(now, until), do: {:error, {:undo_expired, %{undo_until: until}}}, else: :ok
  end

  defp undoable(%Import{state: state}, _now),
    do: {:error, {:import_not_undoable, %{state: state}}}

  @doc "Runs a background step now, as `scope` (what the worker does; the tests call it)."
  @spec run_step(Scope.t(), binary(), String.t(), DateTime.t()) :: :ok
  def run_step(%Scope{} = scope, id, step, %DateTime{} = now), do: Steps.run(scope, id, step, now)

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp in_state(%Import{state: state}, states) do
    if state in states, do: :ok, else: {:error, {:import_not_ready, %{state: state}}}
  end

  defp after_step(scope, import, step, now) do
    {:ok, _job} =
      %{import_id: import.id, step: step, user_id: Scope.user_id(scope)}
      |> ImportStep.new()
      |> Oban.insert()

    import = Store.reload(import)
    Realtime.send_all([Realtime.import_progress(import)])
    {:ok, Sheet.view(import, now)}
  end

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
