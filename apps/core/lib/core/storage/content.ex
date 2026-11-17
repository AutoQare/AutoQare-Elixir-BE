defmodule Core.Storage.Content do
  @moduledoc """
  What a file actually is, read from its bytes (AQ-01 QP1-3: *bytes sniffed*).

  > **The allowlist is checked against the bytes, not the header.** A
  > client-supplied `Content-Type` is a claim.

  Magic numbers for the binary formats; a DOCX is a ZIP whose first entry
  names `[Content_Types].xml` or `word/`; a text file is valid UTF-8 with no
  NUL byte that matches nothing else. SVG is off the list for the reason HTML
  is: it executes.

  AQ-12 §11.4: an XLSX is a ZIP holding `xl/` (an import's spreadsheet), a
  DOCX one holding `word/`, told apart by the archive's own file list; a
  CSV is text, so a row declared `text/csv` accepts what reads as text.
  """

  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @as_text ~w(text/markdown text/csv application/vnd.ms-excel)

  @doc "An XLSX's content type."
  @spec xlsx() :: String.t()
  def xlsx, do: @xlsx

  @doc "What these bytes are, or `nil` for anything not on the allowlist."
  @spec detect(binary()) :: String.t() | nil
  def detect(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: "image/jpeg"
  def detect(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>), do: "image/png"
  def detect(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: "image/webp"
  def detect(<<"%PDF-", _rest::binary>>), do: "application/pdf"

  # A ZIP local file header; the first entry's name follows at offset 30.
  # The archive's file list tells a workbook from a document; an archive
  # that can't be listed is judged by its first entry's name.
  def detect(<<"PK", 3, 4, _fields::binary-size(26), rest::binary>> = bytes) do
    case office_kind(bytes) do
      nil ->
        head = binary_part(rest, 0, min(byte_size(rest), 64))

        if String.contains?(head, ["[Content_Types].xml", "word/", "_rels/"]),
          do: @docx,
          else: nil

      kind ->
        kind
    end
  end

  def detect(bytes) when is_binary(bytes) do
    if String.valid?(bytes) and not String.contains?(bytes, <<0>>), do: "text/plain", else: nil
  end

  @doc """
  Whether the bytes are what the row said they would be. Markdown is text
  to the bytes, so a row declared `text/markdown` accepts what reads as
  `text/plain`.
  """
  @spec matches?(binary(), String.t()) :: boolean()
  def matches?(bytes, "message/rfc822"), do: email?(bytes)

  def matches?(bytes, declared) do
    case detect(bytes) do
      nil -> false
      ^declared -> true
      "text/plain" -> declared in @as_text
      _other -> false
    end
  end

  @doc """
  Whether the bytes are an email (AQ-06 §7.1): no NUL byte, and they open
  with RFC 5322 header fields — a name, a colon — before a blank line, a
  `From:` among them. Text to the sniffer otherwise, so an `eml` row is
  the one kind that accepts them as an email.
  """
  @spec email?(binary()) :: boolean()
  def email?(bytes) do
    head = binary_part(bytes, 0, min(byte_size(bytes), 16_384))

    not String.contains?(bytes, <<0>>) and
      Regex.match?(~r/\A(?:[!-9;-~]+:[^\r\n]*\r?\n(?:[ \t][^\r\n]*\r?\n)*)+/, head) and
      Regex.match?(~r/^from:/im, head)
  end

  defp office_kind(bytes) do
    case :zip.list_dir(bytes) do
      {:ok, entries} ->
        names =
          for {:zip_file, name, _info, _comment, _offset, _size} <- entries, do: to_string(name)

        cond do
          Enum.any?(names, &String.starts_with?(&1, "xl/")) -> @xlsx
          Enum.any?(names, &String.starts_with?(&1, "word/")) -> @docx
          true -> nil
        end

      _not_listable ->
        nil
    end
  end
end
