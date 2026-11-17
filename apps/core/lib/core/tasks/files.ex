defmodule Core.Tasks.Files do
  @moduledoc """
  A task's files (AQ-02 §5.1, §7.2, §7.3): a `media` row of kind
  `attachment` that the caller uploaded and confirmed (the three-step
  upload), put on the task. Staff who may change the task add and remove
  them; the customer adds them to any task they see.
  """

  alias Core.Media
  alias Core.Tasks
  alias Core.Tasks.{Histories, Notices, Write}
  alias Data.Scope
  alias Data.TaskParts

  @doc "`POST /tasks/:id/files {media_id}`."
  @spec add(Scope.t(), term(), map(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def add(%Scope{} = scope, id, params, %DateTime{} = now) do
    media_id = Tasks.stringify(params)["media_id"]

    with {:ok, task} <- Tasks.fetch(scope, :files, id),
         {:ok, media} <- Media.own_uploaded(scope, media_id || "", :attachment) do
      change(scope, task, now, fn ->
        task.id
        |> TaskParts.add_media(media.id, Scope.user_id(scope))
        |> added(media)
        |> file_told(scope, task, media)
      end)
    end
  end

  # AQ-10B §5.2 T11: the customer added a file.
  defp file_told({:ok, lines}, scope, task, media) do
    if Scope.customer?(scope),
      do:
        {:ok, lines,
         Notices.customer_changed(scope, task, {:file, name(media)}, "file:#{media.id}")},
      else: {:ok, lines}
  end

  defp file_told(error, _scope, _task, _media), do: error

  @doc "`DELETE /tasks/:id/files/:media_id`: off the task; the bytes stay with their row."
  @spec remove(Scope.t(), term(), term(), DateTime.t()) :: {:ok, map() | :gone} | {:error, term()}
  def remove(%Scope{} = scope, id, media_id, %DateTime{} = now) do
    action = if Scope.customer?(scope), do: :edit, else: :files

    with {:ok, task} <- Tasks.fetch(scope, action, id),
         %{} = link <- TaskParts.get_media(task.id, media_id) || {:error, :not_found} do
      change(scope, task, now, fn ->
        TaskParts.remove_media(link)
        {:ok, [Histories.line(:file, link.media_id, nil, name(link.media), nil)]}
      end)
    end
  end

  defp added({:ok, _link}, media),
    do: {:ok, [Histories.line(:file, nil, media.id, nil, name(media))]}

  defp added(error, _media), do: error

  defp name(media), do: media.original_filename || "A file"

  defp change(scope, task, now, fun) do
    result =
      Write.change(scope, task, now, fn _group ->
        case fun.() do
          {:ok, lines} -> {:ok, lines, []}
          other -> other
        end
      end)

    Tasks.answer(scope, result, now)
  end
end
