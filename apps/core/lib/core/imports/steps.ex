defmodule Core.Imports.Steps do
  @moduledoc """
  The four background steps of an import (AQ-12 §11.4, QP12-15), each run
  by `Core.Workers.ImportStep` with the scope of whoever started it:

  | Step | From | To |
  |---|---|---|
  | `read` | `reading` | `mapping` (the rows kept, the columns guessed) or `failed` |
  | `check` | `checking` | `ready` (the dry run, `Core.Imports.Check`) |
  | `commit` | `importing` | `imported` (`Core.Imports.Write`, one transaction per row; the undo open for seven days) |
  | `undo` | `undoing` | `undone` (`Core.Imports.Undo`, the rows in reverse) |

  **Idempotent:** a step finding its import in any other state does
  nothing, and a commit run again skips the rows it imported already.
  Each sets `progress` as it goes and broadcasts `import_progress
  {import_id, state, progress}` on the team's channel after each write.
  """

  require Logger

  alias Core.Audit
  alias Core.Imports.{Check, Fields, Read, Undo, Write}
  alias Core.Realtime
  alias Core.Storage
  alias Data.Imports, as: Store
  alias Data.Imports.Import
  alias Data.Scope

  @steps ~w(read check commit undo)

  @doc "The steps, by name."
  @spec steps() :: [String.t()]
  def steps, do: @steps

  @doc "Runs `step` on the import behind `id` at `now`: `:ok` (nothing to do is `:ok` too)."
  @spec run(Scope.t(), binary(), String.t(), DateTime.t()) :: :ok
  def run(%Scope{} = scope, id, step, %DateTime{} = now) when step in @steps do
    case Store.get_for_system(id) do
      %Import{organisation_id: org} = import when org == scope.organisation.id ->
        step(scope, import, step, now)

      _gone ->
        :ok
    end
  end

  defp step(scope, %Import{state: :reading} = import, "read", now), do: read(scope, import, now)

  defp step(scope, %Import{state: :checking} = import, "check", now),
    do: check(scope, import, now)

  defp step(scope, %Import{state: :importing} = import, "commit", now),
    do: commit(scope, import, now)

  defp step(scope, %Import{state: :undoing} = import, "undo", now), do: undo(scope, import, now)
  defp step(_scope, _import, _step, _now), do: :ok

  @doc "The caps a file is held to: `config :core, :imports`."
  @spec limits() :: %{max_rows: pos_integer(), max_bytes: pos_integer()}
  def limits do
    config = Application.get_env(:core, :imports, [])

    %{
      max_rows: Keyword.get(config, :max_rows, 20_000),
      max_bytes: Keyword.get(config, :max_bytes, 10_000_000)
    }
  end

  # ── Read ────────────────────────────────────────────────────────────────────

  defp read(_scope, import, now) do
    with {:ok, bytes} <- bytes(import),
         {:ok, tabs} <- Read.tabs(bytes, import.file_name, limits()) do
      rows = for tab <- tabs, row <- tab.rows, do: Map.put(row, :tab, tab.name)
      :ok = Store.put_rows(import, rows, now)
      headers = tabs |> Enum.flat_map(& &1.headers) |> Enum.uniq()

      move(import, %{
        state: :mapping,
        progress: 100,
        mapping: Fields.guess_all(import.kind, headers),
        tabs:
          Enum.map(tabs, fn tab ->
            %{
              "name" => tab.name,
              "rows" => length(tab.rows),
              "headers" => tab.headers,
              "samples" => tab.samples,
              "profile_id" => nil,
              "applier_user_id" => nil,
              "include" => true
            }
          end)
      })
    else
      {:error, reason} ->
        move(import, %{state: :failed, progress: 100, error_text: failure(reason)})
    end
  end

  defp bytes(%Import{media: %{storage_key: key}}) do
    case Storage.fetch(key) do
      {:ok, bytes} -> {:ok, bytes}
      _missing -> {:error, {:import_unreadable, "The uploaded file is gone. Upload it again."}}
    end
  end

  defp bytes(_import),
    do: {:error, {:import_unreadable, "The uploaded file is gone. Upload it again."}}

  defp failure({:import_unreadable, words}), do: words

  defp failure({:import_too_large, %{max_rows: rows}}),
    do: "That file is too big to import: at most #{rows} rows."

  # ── Check ───────────────────────────────────────────────────────────────────

  defp check(scope, import, now) do
    ctx = Check.context(scope, import, now)
    rows = Store.rows(import.id)
    every = max(div(length(rows), 20), 1)
    order = Enum.map(import.tabs, & &1["name"])

    scope
    |> Check.rows(ctx, rows, order)
    |> Enum.with_index(1)
    |> Enum.each(fn {{row, attrs}, i} ->
      {:ok, _row} = Store.update_row(row, Map.merge(%{values: row.values}, attrs))
      if rem(i, every) == 0, do: progress(import, i, length(rows))
    end)

    move(import, %{state: :ready, progress: 100, checked_at: now, counts: counts(import)})
  end

  @doc "The import's counts with the dry run's taken fresh from its rows."
  @spec counts(Import.t()) :: map()
  def counts(%Import{} = import) do
    zero = Map.new(~w(new update duplicate error skipped), &{&1, 0})
    Map.merge(import.counts || %{}, Map.merge(zero, Store.result_counts(import.id)))
  end

  # ── Commit ──────────────────────────────────────────────────────────────────

  defp commit(scope, import, now) do
    ctx = commit_context(scope, import, now)
    rows = Store.rows(import.id, results: [:new, :update])
    every = max(div(length(rows), 20), 1)

    tally =
      rows
      |> Enum.with_index(1)
      |> Enum.reduce(%{"created" => 0, "updated" => 0}, fn {row, i}, acc ->
        acc = commit_row(scope, ctx, row, now, acc)
        if rem(i, every) == 0, do: progress(import, i, length(rows))
        acc
      end)

    days = Keyword.get(Application.get_env(:core, :imports, []), :undo_days, 7)
    counts = import |> Store.reload() |> counts() |> Map.merge(tally)

    {:ok, _audit} =
      Audit.record(scope, "imported", import,
        after: Map.put(counts, "file_name", import.file_name),
        now: now
      )

    move(import, %{
      state: :imported,
      progress: 100,
      imported_at: now,
      undo_until: DateTime.add(now, days, :day),
      counts: counts
    })
  end

  defp commit_context(scope, import, now) do
    scope
    |> Check.context(import, now)
    |> Map.merge(%{
      team: import.team,
      file_name: import.file_name,
      importer_name: importer_name(scope)
    })
  end

  defp importer_name(scope) do
    case Data.Accounts.get_user(Scope.user_id(scope)) do
      %{person: %{display_name: name}} -> name
      _nobody -> "the system"
    end
  end

  # A row imported already (a commit run again) is left as it is.
  defp commit_row(_scope, _ctx, %{created: created} = _row, _now, acc) when created != %{},
    do: acc

  defp commit_row(scope, ctx, row, now, acc) do
    case Write.row(scope, ctx, row, now) do
      {:ok, attrs} ->
        {:ok, _row} = Store.update_row(row, attrs)
        key = if row.result == :new, do: "created", else: "updated"
        Map.update!(acc, key, &(&1 + 1))

      {:error, reason} ->
        failed = %{"code" => "import_failed", "words" => refusal(reason)}
        {:ok, _row} = Store.update_row(row, %{result: :error, reasons: row.reasons ++ [failed]})
        acc
    end
  end

  # Why a row could not be written, as the preview says it.
  defp refusal({:duplicate_application, %{message: words}}), do: words
  defp refusal({:job_exists, _job}), do: "That link was added to the pool meanwhile."
  defp refusal({:forbidden, words}) when is_binary(words), do: words
  defp refusal({:invalid, details}) when is_map(details), do: field_words(details)

  defp refusal({:missing, fields}),
    do: field_words(Map.new(List.wrap(fields), &{&1, ["is required"]}))

  defp refusal(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> field_words()
  end

  defp refusal(reason) do
    Logger.error("An import row could not be written: #{inspect(reason)}")
    "This row couldn't be imported."
  end

  defp field_words(details) do
    Enum.map_join(details, " ", fn {field, messages} ->
      "#{String.capitalize(String.replace(to_string(field), "_", " "))} " <>
        "#{messages |> List.flatten() |> Enum.map_join(", ", &to_string/1)}."
    end)
  end

  # ── Undo ────────────────────────────────────────────────────────────────────

  defp undo(scope, import, now) do
    rows =
      import.id
      |> Store.rows()
      |> Enum.filter(&(&1.created != %{}))
      |> Enum.reverse()

    every = max(div(length(rows), 20), 1)

    tally =
      rows
      |> Enum.with_index(1)
      |> Enum.reduce(%{"removed" => 0, "restored" => 0, "kept" => 0}, fn {row, i}, acc ->
        acc = undo_row(scope, row, acc)
        if rem(i, every) == 0, do: progress(import, i, length(rows))
        acc
      end)

    counts = Map.merge(import.counts || %{}, tally)
    {:ok, _audit} = Audit.record(scope, "undone", import, after: counts, now: now)
    move(import, %{state: :undone, progress: 100, undone_at: now, counts: counts})
  end

  defp undo_row(scope, row, acc) do
    case Undo.row(scope, row) do
      {:ok, %{removed: removed, restored: restored, kept: kept}} ->
        if kept > 0 do
          reason = %{"code" => "kept", "words" => "Kept: changed since the import."}
          {:ok, _row} = Store.update_row(row, %{reasons: row.reasons ++ [reason]})
        end

        acc
        |> Map.update!("removed", &(&1 + removed))
        |> Map.update!("restored", &(&1 + restored))
        |> Map.update!("kept", &(&1 + kept))

      {:error, reason} ->
        Logger.error("An import row could not be undone: #{inspect(reason)}")
        acc
    end
  end

  # ── Progress ────────────────────────────────────────────────────────────────

  defp progress(import, done, total) do
    {:ok, moved} = Store.update(import, %{progress: min(div(done * 100, max(total, 1)), 99)})
    Realtime.send_all([Realtime.import_progress(moved)])
  end

  defp move(import, attrs) do
    {:ok, moved} = Store.update(import, attrs)
    Realtime.send_all([Realtime.import_progress(moved)])
    :ok
  end
end
