defmodule Notifire.Emails.Html do
  @moduledoc """
  The small pieces every email template uses (AQ-10B §7.2; MyQuriosity's
  `Core.Emails.Html`, grown): `escape/1`, and the parts — a bulletproof
  `<a>` button, the facts table, a quote, the greeting, the heading, a
  paragraph, the plain link, a list and the hidden preheader.

  **No HTML here** (MyQuriosity's rule): each part is a file under
  `priv/emails/parts/`, compiled at build time with
  `EEx.function_from_file`. **Every value a part shows is escaped here**,
  before the part sees it, so a customer's or a recruiter's words can't
  become markup; a template that shows a value itself calls `escape/1`.
  """

  require EEx

  @parts Path.expand("../../../priv/emails/parts", __DIR__)

  for part <- ~w(button facts quote greeting heading paragraph link preheader list) do
    EEx.function_from_file(:defp, :"#{part}_html", Path.join(@parts, "#{part}.html.eex"), [
      :assigns
    ])
  end

  EEx.function_from_file(:defp, :facts_txt, Path.join(@parts, "facts.text.eex"), [:assigns])

  @doc """
  HTML-escapes a value for an email body; `nil` is `""`.

      iex> Notifire.Emails.Html.escape(~s(<script>alert("x")</script> & 'y'))
      "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;y&#39;"
      iex> Notifire.Emails.Html.escape(nil)
      ""
  """
  @spec escape(term()) :: String.t()
  def escape(nil), do: ""

  def escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  def escape(other), do: other |> to_string() |> escape()

  @doc "A bulletproof button: a padded `<a>` in a coloured cell, which Outlook draws too."
  @spec button(String.t(), String.t() | nil) :: String.t()
  def button(_label, nil), do: ""
  def button(label, url), do: button_html(%{label: escape(label), url: escape(url)})

  @doc "The facts table: `[{label, value}]`, rows with a blank value left out; `\"\"` for none."
  @spec facts([{String.t(), term()}] | nil) :: String.t()
  def facts(rows) do
    case present(rows) do
      [] -> ""
      rows -> facts_html(%{rows: Enum.map(rows, fn {l, v} -> {escape(l), escape(v)} end)})
    end
  end

  @doc "The facts as plain text, a line each."
  @spec facts_text([{String.t(), term()}] | nil) :: String.t()
  def facts_text(rows) do
    case present(rows) do
      [] -> ""
      rows -> facts_txt(%{rows: Enum.map(rows, fn {l, v} -> {l, to_string(v)} end)})
    end
  end

  @doc "A quote of someone's words (a reply, a comment), left-ruled; `\"\"` for none."
  @spec quoted(String.t() | nil) :: String.t()
  def quoted(nil), do: ""
  def quoted(""), do: ""
  def quoted(text), do: quote_html(%{text: escape(text)})

  @doc ~s|"Hi Tanweer,"; "Hi there," for no name.|
  @spec greeting(String.t() | nil) :: String.t()
  def greeting(name), do: greeting_html(%{name: escape(name || "there")})

  @doc "The title, as the email's one heading."
  @spec heading(String.t()) :: String.t()
  def heading(text), do: heading_html(%{text: escape(text)})

  @doc "A paragraph of plain words (line breaks kept); `\"\"` for none."
  @spec paragraph(String.t() | nil) :: String.t()
  def paragraph(nil), do: ""
  def paragraph(""), do: ""
  def paragraph(text), do: paragraph_html(%{text: escape(text)})

  @doc "The plain link under the button, for clients that hide buttons."
  @spec link(String.t() | nil) :: String.t()
  def link(nil), do: ""
  def link(url), do: link_html(%{url: escape(url)})

  @doc "A list of lines (the digest's titles); `\"\"` for none."
  @spec list([String.t()] | nil) :: String.t()
  def list(items) do
    case items || [] do
      [] -> ""
      items -> list_html(%{items: Enum.map(items, &escape/1)})
    end
  end

  @doc "The hidden first line a mail client shows in its list."
  @spec preheader(String.t() | nil) :: String.t()
  def preheader(text), do: preheader_html(%{text: escape(text || "")})

  defp present(nil), do: []

  defp present(rows),
    do: Enum.reject(rows, fn {_label, value} -> value in [nil, ""] end)
end
