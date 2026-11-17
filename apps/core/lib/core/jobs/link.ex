defmodule Core.Jobs.Link do
  @moduledoc """
  A new job's identity (AQ-03 §6.1), pure: its link through
  `Utils.JobKey` — the canonical key, the source, the source's id — and the
  link as pasted, trimmed, with its scheme.

  **Fiverr has no job link to key by** (AQ-12 §6, §11.4): a Fiverr job is
  keyed by its conversation (`fiverr:conversation:{id}`, triage's *Create
  job and lead*) or by its own id (`fiverr:job:{id}`, `POST /jobs` with
  `source: fiverr`, an import's Fiverr row), and keeps a brief's link as
  `source_url` when there is one.
  """

  alias Utils.JobKey

  @type t :: %{
          key: String.t(),
          source: atom(),
          source_job_id: String.t() | nil,
          url: String.t() | nil
        }

  @doc """
  A job link's identity, or the 422 a create answers.

      iex> Core.Jobs.Link.parse("linkedin.com/jobs/view/42")
      {:ok, %{key: "linkedin:42", source: :linkedin, source_job_id: "42", url: "https://linkedin.com/jobs/view/42"}}
      iex> Core.Jobs.Link.parse(nil)
      {:error, {:missing, [:url]}}
  """
  @spec parse(term()) :: {:ok, t()} | {:error, term()}
  def parse(url) do
    case JobKey.parse(url) do
      {:ok, parsed} -> {:ok, Map.put(parsed, :url, web_link(url))}
      {:error, :not_a_job} -> {:error, {:invalid, %{"url" => ["is not a job posting"]}}}
      {:error, :not_a_link} when is_nil(url) -> {:error, {:missing, [:url]}}
      {:error, :not_a_link} -> {:error, {:invalid, %{"url" => ["is not a job link"]}}}
    end
  end

  @doc """
  A Fiverr job's identity under `key`, keeping `url` as its `source_url`
  when it is a web link (a blank one is none; anything else a 422).

      iex> Core.Jobs.Link.fiverr("fiverr:conversation:abc", nil)
      {:ok, %{key: "fiverr:conversation:abc", source: :fiverr, source_job_id: nil, url: nil}}
  """
  @spec fiverr(String.t(), term()) :: {:ok, t()} | {:error, term()}
  def fiverr(key, url) when is_binary(key) do
    case Utils.presence(if(is_binary(url), do: url, else: "")) do
      nil ->
        {:ok, %{key: key, source: :fiverr, source_job_id: nil, url: nil}}

      link ->
        if Utils.SafeUrl.safe?(web_link(link)),
          do: {:ok, %{key: key, source: :fiverr, source_job_id: nil, url: web_link(link)}},
          else: {:error, {:invalid, %{"url" => ["is not a web link"]}}}
    end
  end

  @doc "The key of a Fiverr job made by hand or by an import: its own id."
  @spec fiverr_job_key(binary()) :: String.t()
  def fiverr_job_key(job_id), do: "fiverr:job:" <> job_id

  @doc "The key of a Fiverr job made from a conversation in triage."
  @spec fiverr_conversation_key(binary()) :: String.t()
  def fiverr_conversation_key(conversation_id), do: "fiverr:conversation:" <> conversation_id

  @doc """
  Whether a link is Fiverr's (`fiverr.com` or a subdomain): such a link has
  no canonical key of its own.

      iex> Core.Jobs.Link.fiverr_link?("https://www.fiverr.com/briefs/123")
      true
      iex> Core.Jobs.Link.fiverr_link?("https://example.com")
      false
  """
  @spec fiverr_link?(term()) :: boolean()
  def fiverr_link?(url) when is_binary(url) do
    case URI.new(web_link(url)) do
      {:ok, %URI{host: host}} when is_binary(host) ->
        host = String.downcase(host)
        host == "fiverr.com" or String.ends_with?(host, ".fiverr.com")

      _other ->
        false
    end
  end

  def fiverr_link?(_url), do: false

  @doc "The link as pasted, trimmed, with its scheme."
  @spec web_link(String.t()) :: String.t()
  def web_link(url) do
    url = String.trim(url)
    if url =~ ~r{^[a-zA-Z][a-zA-Z0-9+.-]*://}, do: url, else: "https://" <> url
  end
end
