defmodule ApiTeam.ImportControllerTest do
  @moduledoc """
  AQ-12 §11.4 over HTTP: every import route — the `import` and `row`
  shapes' exact keys, 202 for each step, who may (a lead of the team and
  the system admin; staff and another team's lead find nothing), and the
  five codes: 413 `import_too_large`, 422 `import_unreadable`, 409
  `import_not_ready`, `undo_expired`, `import_not_undoable`; the rows'
  `$where` and its 422.
  """

  use ApiTeam.TeamCase, async: true

  alias Core.Clock
  alias Core.Imports
  alias Core.Storage.Content

  @now ~U[2026-11-15 10:00:00.000000Z]

  @import ~w(by can checked_at columns counts date_order error_text fields file_name id imported_at
             inserted_at kind overwrite progress state tabs team undo_until undone_at)
  @counts ~w(created duplicate error kept new removed restored skipped update updated)
  @row ~w(cells id job lead reasons result row_number tab values)

  @csv "Date,Job link,Job Title,Applied By\n" <>
         "09/10/2024,https://www.linkedin.com/jobs/view/91,Go Developer,Fiza\n" <>
         "31/02/2024,https://www.linkedin.com/jobs/view/92,Go Developer,Fiza\n"

  setup do
    on_exit(&Clock.unfreeze/0)
    Clock.freeze(@now)
    c = board_cast_fixture()
    other = team_fixture(c.org, name: "Design")
    stranger = member_fixture(other, :lead, user_fixture(display_name: "Stranger"))
    Map.put(c, :stranger, stranger)
  end

  defp upload(user, bytes, name \\ "applications.csv", type \\ "text/csv") do
    scope = scope_for(user)

    {:ok, media, _target} =
      Core.Media.create(
        scope,
        %{
          "media_kind" => "import",
          "content_type" => type,
          "byte_count" => byte_size(bytes),
          "original_filename" => name
        },
        "/media"
      )

    :ok = Core.Media.store(scope, media.id, bytes)
    {:ok, media} = Core.Media.confirm(scope, media.id, %{}, @now)
    media
  end

  defp start(c, user \\ nil) do
    user = user || c.hira
    media = upload(user, @csv)

    conn =
      call(user, :post, "/v1/imports", %{
        team_id: c.backend.id,
        media_id: media.id,
        kind: "applications"
      })

    assert conn.status == 202
    id = body(conn)["id"]
    :ok = Imports.run_step(scope_for(user), id, "read", @now)
    id
  end

  defp ready(c) do
    id = start(c)
    tabs = [%{name: "applications", profile_id: c.golang.id, applier_user_id: c.fiza.id}]
    conn = call(c.hira, :patch, "/v1/imports/#{id}", %{tabs: tabs, date_order: "day_month"})
    assert conn.status == 202
    assert body(conn)["state"] == "checking"
    :ok = Imports.run_step(scope_for(c.hira), id, "check", @now)
    id
  end

  test "the import's shape, exactly; the list; the rows", c do
    id = ready(c)

    conn = call(c.hira, :get, "/v1/imports/#{id}")
    assert conn.status == 200
    import = body(conn)
    assert import |> Map.keys() |> Enum.sort() == @import
    assert import["counts"] |> Map.keys() |> Enum.sort() == @counts
    assert import["can"] == %{"map" => true, "commit" => true, "undo" => false}
    assert import["team"] == %{"id" => c.backend.id, "name" => "Backend squad"}

    assert [%{"name" => "applications", "rows" => 2, "include" => true} = tab] = import["tabs"]

    assert tab["profile"] == %{
             "id" => c.golang.id,
             "title" => "Golang backend",
             "customer_name" => "Tanweer"
           }

    assert tab["applier"]["user_id"] == c.fiza.id

    assert %{
             "header" => "Job link",
             "sample" => "https://www.linkedin.com/jobs/view/91",
             "field" => "job_url"
           } in import["columns"]

    assert %{"key" => "job_url", "label" => "Job link", "required" => true} in import["fields"]

    assert %{"items" => [listed]} =
             body(call(c.hira, :get, "/v1/imports?team_id=#{c.backend.id}"))

    assert listed["id"] == id

    page =
      body(
        call(c.hira, :get, "/v1/imports/#{id}/rows", %{
          "$where" => %{"result" => %{"$EQUAL" => "error"}}
        })
      )

    assert [row] = page["items"]
    assert row |> Map.keys() |> Enum.sort() == @row
    assert row["row_number"] == 3
    assert [%{"code" => "bad_date", "words" => "31/02/2024 isn't a date."}] = row["reasons"]
    assert page["next_cursor"] == nil

    conn = call(c.hira, :get, "/v1/imports/#{id}/rows", %{"$where" => %{"colour" => "red"}})
    assert conn.status == 422 and code(conn) == "invalid_filter"
  end

  test "a row fixed and a row skipped answer the row; commit and undo answer 202", c do
    id = ready(c)
    [_good, bad] = Data.Imports.rows(id)

    # The console sends the row's full cells, header → text.
    cells = Map.put(bad.cells, "Date", "28/02/2024")
    conn = call(c.hira, :patch, "/v1/imports/#{id}/rows/#{bad.id}", %{cells: cells})

    assert conn.status == 200 and body(conn)["result"] == "new"

    conn = call(c.hira, :post, "/v1/imports/#{id}/rows/#{bad.id}/skip")
    assert conn.status == 200 and body(conn)["result"] == "skipped"

    conn = call(c.hira, :post, "/v1/imports/#{id}/commit")
    assert conn.status == 202 and body(conn)["state"] == "importing"
    :ok = Imports.run_step(scope_for(c.hira), id, "commit", @now)
    assert body(call(c.hira, :get, "/v1/imports/#{id}"))["can"]["undo"]

    conn = call(c.dawud, :post, "/v1/imports/#{id}/undo")
    assert conn.status == 202 and body(conn)["state"] == "undoing"

    conn = call(c.hira, :post, "/v1/imports/#{id}/undo")
    assert conn.status == 409 and code(conn) == "import_not_undoable"
    assert body(conn)["error"]["details"] == %{"state" => "undoing"}
  end

  test "who may: the team's lead and the system admin; staff and another team's lead get 404",
       c do
    id = start(c)

    for user <- [c.hira, c.dawud] do
      assert call(user, :get, "/v1/imports/#{id}").status == 200
      assert call(user, :get, "/v1/imports?team_id=#{c.backend.id}").status == 200
      assert call(user, :get, "/v1/imports/#{id}/rows").status == 200
    end

    for user <- [c.fiza, c.stranger] do
      for {method, path} <- [
            {:get, "/v1/imports/#{id}"},
            {:get, "/v1/imports?team_id=#{c.backend.id}"},
            {:get, "/v1/imports/#{id}/rows"},
            {:patch, "/v1/imports/#{id}"},
            {:post, "/v1/imports/#{id}/commit"},
            {:post, "/v1/imports/#{id}/undo"}
          ] do
        conn = call(user, method, path)
        assert conn.status == 404, "#{method} #{path}"
        assert code(conn) == "not_found"
      end
    end

    media = upload(c.fiza, @csv)

    conn =
      call(c.fiza, :post, "/v1/imports", %{
        team_id: c.backend.id,
        media_id: media.id,
        kind: "applications"
      })

    assert conn.status == 404
  end

  test "the codes: 413, 422 unreadable, 409 not ready, 409 undo expired", c do
    many =
      Enum.map_join(1..70, "", &"01/01/2024,https://www.linkedin.com/jobs/view/#{&1},Job,Fiza\n")

    media = upload(c.hira, "Date,Job link,Job Title,Applied By\n" <> many)

    conn =
      call(c.hira, :post, "/v1/imports", %{
        team_id: c.backend.id,
        media_id: media.id,
        kind: "applications"
      })

    assert conn.status == 413 and code(conn) == "import_too_large"
    assert body(conn)["error"]["details"] == %{"max_rows" => 60, "max_bytes" => 200_000}

    {:ok, {_name, zip}} = :zip.create(~c"x.zip", [{~c"xl/nothing.txt", "no workbook"}], [:memory])
    broken = upload(c.hira, zip, "broken.xlsx", Content.xlsx())

    conn =
      call(c.hira, :post, "/v1/imports", %{
        team_id: c.backend.id,
        media_id: broken.id,
        kind: "applications"
      })

    assert conn.status == 422 and code(conn) == "import_unreadable"

    id = start(c)
    conn = call(c.hira, :post, "/v1/imports/#{id}/commit")
    assert conn.status == 409 and code(conn) == "import_not_ready"
    assert body(conn)["error"]["details"] == %{"state" => "mapping"}

    id = ready(c)
    assert call(c.hira, :post, "/v1/imports/#{id}/commit").status == 202
    :ok = Imports.run_step(scope_for(c.hira), id, "commit", @now)
    Clock.freeze(DateTime.add(@now, 8, :day))

    conn = call(c.hira, :post, "/v1/imports/#{id}/undo")
    assert conn.status == 409 and code(conn) == "undo_expired"
    assert body(conn)["error"]["details"]["undo_until"]

    conn = call(c.hira, :patch, "/v1/imports/#{id}", %{mapping: %{"Date" => "date"}})
    assert conn.status == 409 and code(conn) == "import_not_ready"
  end

  test "field errors: a kind off the list, a mapping to an unknown field", c do
    media = upload(c.hira, @csv)

    conn =
      call(c.hira, :post, "/v1/imports", %{
        team_id: c.backend.id,
        media_id: media.id,
        kind: "companies"
      })

    assert conn.status == 422 and body(conn)["error"]["details"]["kind"]

    id = start(c)
    conn = call(c.hira, :patch, "/v1/imports/#{id}", %{mapping: %{"Date" => "colour"}})
    assert conn.status == 422 and body(conn)["error"]["details"]["mapping"]
  end
end
