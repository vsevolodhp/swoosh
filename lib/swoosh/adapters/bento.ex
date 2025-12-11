defmodule Swoosh.Adapters.Bento do
  @moduledoc ~S"""
  An adapter that sends email using the Bento API.

  For reference: [Bento API docs](https://bentonow.com/docs/emails_api)

  **Bento is for transactional emails only** (password resets, welcome emails, etc.).

  ## Example

      # config/config.exs
      config :sample, Sample.Mailer,
        adapter: Swoosh.Adapters.Bento,
        publishable_key: "my-publishable-key",
        secret_key: "my-secret-key",
        site_uuid: "my-site-uuid"

      # lib/sample/mailer.ex
      defmodule Sample.Mailer do
        use Swoosh.Mailer, otp_app: :sample
      end

  ## Example of sending emails with personalizations

      import Swoosh.Email

      new()
      |> from({"App", "app@example.com"})
      |> to("user@example.com")
      |> subject("Welcome!")
      |> html_body("<p>Hello {{name}}</p>")
      |> put_provider_option(:personalizations, %{name: "User"})

  ## Provider Options

    * `:transactional` (boolean) - marks the email as transactional. When `true`,
      the email will be sent even if the user has unsubscribed. Defaults to `true`.

    * `:personalizations` (map) - key/value pairs to be injected into the email
      HTML body using Liquid templating.

  ## Limitations

    * Only a single recipient is supported (no CC/BCC).
    * Attachments are not supported by Bento.
  """

  use Swoosh.Adapter, required_config: [:publishable_key, :secret_key, :site_uuid]

  alias Swoosh.Email

  @base_url "https://app.bentonow.com/api/v1"
  @endpoint "/batch/emails"

  @impl true
  def deliver(%Email{} = email, config \\ []) do
    headers = prepare_headers(config)
    body = email |> prepare_body() |> Swoosh.json_library().encode!()
    url = build_url(config)

    case Swoosh.ApiClient.post(url, headers, body, email) do
      {:ok, code, _headers, body} when code >= 200 and code < 300 ->
        handle_success(body)

      {:ok, code, _headers, body} when code >= 400 ->
        handle_error(code, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def deliver_many([], _config), do: {:ok, []}

  def deliver_many(emails, config) when is_list(emails) do
    headers = prepare_headers(config)
    body = emails |> prepare_body_many() |> Swoosh.json_library().encode!()
    url = build_url(config)

    case Swoosh.ApiClient.post(url, headers, body, List.first(emails)) do
      {:ok, code, _headers, body} when code >= 200 and code < 300 ->
        handle_success_many(body)

      {:ok, code, _headers, body} when code >= 400 ->
        handle_error(code, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp base_url(config), do: config[:base_url] || @base_url

  defp build_url(config) do
    [base_url(config), @endpoint, "?site_uuid=", config[:site_uuid]]
  end

  defp prepare_headers(config) do
    [
      {"User-Agent", "swoosh/#{Swoosh.version()}"},
      {"Authorization", "Basic " <> basic_auth(config)},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]
  end

  defp basic_auth(config) do
    Base.encode64("#{config[:publishable_key]}:#{config[:secret_key]}")
  end

  defp prepare_body(%Email{} = email) do
    %{"emails" => [prepare_email(email)]}
  end

  defp prepare_body_many(emails) do
    %{"emails" => Enum.map(emails, &prepare_email/1)}
  end

  defp prepare_email(%Email{} = email) do
    email
    |> validate_email!()
    |> build_email_params()
  end

  defp validate_email!(%Email{to: to, cc: cc, bcc: bcc, attachments: attachments} = email) do
    cond do
      length(to) > 1 ->
        raise ArgumentError,
              "Bento adapter supports only a single recipient, got: #{inspect(to)}"

      cc != [] ->
        raise ArgumentError, "Bento adapter does not support CC"

      bcc != [] ->
        raise ArgumentError, "Bento adapter does not support BCC"

      attachments != [] ->
        raise ArgumentError, "Bento adapter does not support attachments"

      true ->
        email
    end
  end

  defp build_email_params(%Email{} = email) do
    %{}
    |> prepare_from(email)
    |> prepare_to(email)
    |> prepare_subject(email)
    |> prepare_html_body(email)
    |> prepare_transactional(email)
    |> prepare_personalizations(email)
  end

  defp prepare_from(body, %{from: {_name, address}}), do: Map.put(body, "from", address)
  defp prepare_from(body, %{from: from}) when is_binary(from), do: Map.put(body, "from", from)

  defp prepare_to(body, %{to: [{_name, address}]}), do: Map.put(body, "to", address)

  defp prepare_to(body, %{to: [address]}) when is_binary(address),
    do: Map.put(body, "to", address)

  defp prepare_subject(body, %{subject: nil}), do: body
  defp prepare_subject(body, %{subject: ""}), do: body
  defp prepare_subject(body, %{subject: subject}), do: Map.put(body, "subject", subject)

  defp prepare_html_body(body, %{html_body: nil}), do: body
  defp prepare_html_body(body, %{html_body: html}), do: Map.put(body, "html_body", html)

  defp prepare_transactional(body, %{provider_options: %{transactional: value}}),
    do: Map.put(body, "transactional", value)

  defp prepare_transactional(body, _email), do: Map.put(body, "transactional", true)

  defp prepare_personalizations(body, %{provider_options: %{personalizations: value}}),
    do: Map.put(body, "personalizations", value)

  defp prepare_personalizations(body, _email), do: body

  defp handle_success(body) do
    case Swoosh.json_library().decode(body) do
      {:ok, %{"results" => results}} -> {:ok, %{results: results}}
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, %{}}
    end
  end

  defp handle_success_many(body) do
    case Swoosh.json_library().decode(body) do
      {:ok, %{"results" => results}} -> {:ok, results}
      {:ok, decoded} when is_list(decoded) -> {:ok, decoded}
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, []}
    end
  end

  defp handle_error(code, body) do
    case Swoosh.json_library().decode(body) do
      {:ok, error} -> {:error, {code, error}}
      {:error, _} -> {:error, {code, body}}
    end
  end
end
