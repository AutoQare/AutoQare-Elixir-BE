defmodule Core.Notifications.Catalogue do
  @moduledoc """
  AQ-10B §5 as data (QP10b-16): `apps/core/priv/notifications/catalogue.json`,
  one row per event × audience — `{id, event, kind, audience, who,
  channels: {inapp, push, extension, email, digest}, quiet}` — with `true`
  on, `"offered"` off by default and `false` not offered. `kind` is `null`
  for P1's mails and the account's direct ones (no notification row).

  **The promise, held equal to the code** by `Core.Notifications.CatalogueTest`:
  every kind has a row, every row's kind exists, and each row's channels
  and quiet hours are the seed's for its audience. The run helper reads
  the expectations from it, so a run checks what the document promises.
  """

  @path Path.expand("../../../priv/notifications/catalogue.json", __DIR__)
  @external_resource @path
  @rows @path |> File.read!() |> Jason.decode!()

  @doc "Where the file lives in the source tree."
  def path, do: @path

  @doc "Every row, as the JSON has it (string keys)."
  @spec rows() :: [map()]
  def rows, do: @rows
end
