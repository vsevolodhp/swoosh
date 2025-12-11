defmodule Swoosh.Adapters.BentoTest do
  use Swoosh.AdapterCase, async: true

  import Swoosh.Email
  alias Swoosh.Adapters.Bento

  @success_response """
  {
    "results": 1
  }
  """

  setup do
    bypass = Bypass.open()

    config = [
      base_url: "http://localhost:#{bypass.port}",
      publishable_key: "pk_test_123",
      secret_key: "sk_test_456",
      site_uuid: "test-site-uuid"
    ]

    valid_email =
      new()
      |> from("sender@example.com")
      |> to("recipient@example.com")
      |> subject("Hello!")
      |> html_body("<h1>Hello</h1>")

    {:ok, bypass: bypass, valid_email: valid_email, config: config}
  end

  test "a sent email results in :ok", %{bypass: bypass, config: config, valid_email: email} do
    Bypass.expect(bypass, fn conn ->
      conn = parse(conn)

      body_params = %{
        "emails" => [
          %{
            "from" => "sender@example.com",
            "to" => "recipient@example.com",
            "subject" => "Hello!",
            "html_body" => "<h1>Hello</h1>",
            "transactional" => true
          }
        ]
      }

      assert body_params == conn.body_params
      assert "/batch/emails" == conn.request_path
      assert "site_uuid=test-site-uuid" == conn.query_string
      assert "POST" == conn.method

      Plug.Conn.resp(conn, 200, @success_response)
    end)

    assert Bento.deliver(email, config) == {:ok, %{results: 1}}
  end

  test "deliver/1 with named from returns :ok", %{bypass: bypass, config: config} do
    email =
      new()
      |> from({"Sender Name", "sender@example.com"})
      |> to("recipient@example.com")
      |> subject("Hello!")
      |> html_body("<h1>Hello</h1>")

    Bypass.expect(bypass, fn conn ->
      conn = parse(conn)

      assert %{"emails" => [%{"from" => "sender@example.com"}]} = conn.body_params

      Plug.Conn.resp(conn, 200, @success_response)
    end)

    assert {:ok, _} = Bento.deliver(email, config)
  end

  test "deliver/1 with named to returns :ok", %{bypass: bypass, config: config} do
    email =
      new()
      |> from("sender@example.com")
      |> to({"Recipient Name", "recipient@example.com"})
      |> subject("Hello!")
      |> html_body("<h1>Hello</h1>")

    Bypass.expect(bypass, fn conn ->
      conn = parse(conn)

      assert %{"emails" => [%{"to" => "recipient@example.com"}]} = conn.body_params

      Plug.Conn.resp(conn, 200, @success_response)
    end)

    assert {:ok, _} = Bento.deliver(email, config)
  end

  test "deliver/1 with transactional provider option returns :ok", %{
    bypass: bypass,
    config: config
  } do
    email =
      new()
      |> from("sender@example.com")
      |> to("recipient@example.com")
      |> subject("Hello!")
      |> html_body("<h1>Hello</h1>")
      |> put_provider_option(:transactional, false)

    Bypass.expect(bypass, fn conn ->
      conn = parse(conn)

      assert %{"emails" => [%{"transactional" => false}]} = conn.body_params

      Plug.Conn.resp(conn, 200, @success_response)
    end)

    assert {:ok, _} = Bento.deliver(email, config)
  end

  test "deliver/1 with personalizations provider option returns :ok", %{
    bypass: bypass,
    config: config
  } do
    email =
      new()
      |> from("sender@example.com")
      |> to("recipient@example.com")
      |> subject("Hello!")
      |> html_body("<h1>Hello {{name}}</h1>")
      |> put_provider_option(:personalizations, %{name: "World"})

    Bypass.expect(bypass, fn conn ->
      conn = parse(conn)

      assert %{
               "emails" => [
                 %{"personalizations" => %{"name" => "World"}}
               ]
             } = conn.body_params

      Plug.Conn.resp(conn, 200, @success_response)
    end)

    assert {:ok, _} = Bento.deliver(email, config)
  end

  test "deliver/1 sends correct authorization header", %{bypass: bypass, config: config} do
    email =
      new()
      |> from("sender@example.com")
      |> to("recipient@example.com")
      |> subject("Hello!")
      |> html_body("<h1>Hello</h1>")

    Bypass.expect(bypass, fn conn ->
      expected_auth = "Basic " <> Base.encode64("pk_test_123:sk_test_456")

      auth_header =
        conn.req_headers
        |> Enum.find(fn {key, _} -> key == "authorization" end)
        |> elem(1)

      assert auth_header == expected_auth

      user_agent =
        conn.req_headers
        |> Enum.find(fn {key, _} -> key == "user-agent" end)
        |> elem(1)

      assert user_agent =~ "swoosh/"

      Plug.Conn.resp(conn, 200, @success_response)
    end)

    assert {:ok, _} = Bento.deliver(email, config)
  end

  test "deliver/1 with 4xx response", %{bypass: bypass, config: config, valid_email: email} do
    error_response = ~s({"error": "Invalid credentials"})

    Bypass.expect(bypass, &Plug.Conn.resp(&1, 401, error_response))

    assert {:error, {401, %{"error" => "Invalid credentials"}}} = Bento.deliver(email, config)
  end

  test "deliver/1 with 5xx response", %{bypass: bypass, config: config, valid_email: email} do
    error_response = ~s({"error": "Internal server error"})

    Bypass.expect(bypass, &Plug.Conn.resp(&1, 500, error_response))

    assert {:error, {500, %{"error" => "Internal server error"}}} = Bento.deliver(email, config)
  end

  test "deliver/1 with multiple to recipients raises ArgumentError", %{config: config} do
    email =
      new()
      |> from("sender@example.com")
      |> to("recipient1@example.com")
      |> to("recipient2@example.com")
      |> subject("Hello!")
      |> html_body("<h1>Hello</h1>")

    assert_raise ArgumentError, ~r/Bento adapter supports only a single recipient/, fn ->
      Bento.deliver(email, config)
    end
  end

  test "deliver/1 with cc raises ArgumentError", %{config: config} do
    email =
      new()
      |> from("sender@example.com")
      |> to("recipient@example.com")
      |> cc("cc@example.com")
      |> subject("Hello!")
      |> html_body("<h1>Hello</h1>")

    assert_raise ArgumentError, ~r/Bento adapter does not support CC/, fn ->
      Bento.deliver(email, config)
    end
  end

  test "deliver/1 with bcc raises ArgumentError", %{config: config} do
    email =
      new()
      |> from("sender@example.com")
      |> to("recipient@example.com")
      |> bcc("bcc@example.com")
      |> subject("Hello!")
      |> html_body("<h1>Hello</h1>")

    assert_raise ArgumentError, ~r/Bento adapter does not support BCC/, fn ->
      Bento.deliver(email, config)
    end
  end

  test "deliver/1 with attachments raises ArgumentError", %{config: config} do
    email =
      new()
      |> from("sender@example.com")
      |> to("recipient@example.com")
      |> subject("Hello!")
      |> html_body("<h1>Hello</h1>")
      |> attachment("test/support/attachment.txt")

    assert_raise ArgumentError, ~r/Bento adapter does not support attachments/, fn ->
      Bento.deliver(email, config)
    end
  end

  test "validate_config/1 with valid config", %{config: config} do
    assert :ok = Bento.validate_config(config)
  end

  test "validate_config/1 with missing publishable_key" do
    assert_raise ArgumentError, ~r/expected \[:publishable_key\] to be set/, fn ->
      Bento.validate_config(secret_key: "sk", site_uuid: "uuid")
    end
  end

  test "validate_config/1 with missing secret_key" do
    assert_raise ArgumentError, ~r/expected \[:secret_key\] to be set/, fn ->
      Bento.validate_config(publishable_key: "pk", site_uuid: "uuid")
    end
  end

  test "validate_config/1 with missing site_uuid" do
    assert_raise ArgumentError, ~r/expected \[:site_uuid\] to be set/, fn ->
      Bento.validate_config(publishable_key: "pk", secret_key: "sk")
    end
  end

  test "deliver_many/2 with empty list returns :ok" do
    assert {:ok, []} = Bento.deliver_many([], [])
  end

  test "deliver_many/2 with multiple emails returns :ok", %{bypass: bypass, config: config} do
    email1 =
      new()
      |> from("sender@example.com")
      |> to("recipient1@example.com")
      |> subject("Hello 1")
      |> html_body("<h1>Hello 1</h1>")

    email2 =
      new()
      |> from("sender@example.com")
      |> to("recipient2@example.com")
      |> subject("Hello 2")
      |> html_body("<h1>Hello 2</h1>")

    Bypass.expect(bypass, fn conn ->
      conn = parse(conn)

      assert %{
               "emails" => [
                 %{
                   "from" => "sender@example.com",
                   "to" => "recipient1@example.com",
                   "subject" => "Hello 1",
                   "html_body" => "<h1>Hello 1</h1>",
                   "transactional" => true
                 },
                 %{
                   "from" => "sender@example.com",
                   "to" => "recipient2@example.com",
                   "subject" => "Hello 2",
                   "html_body" => "<h1>Hello 2</h1>",
                   "transactional" => true
                 }
               ]
             } == conn.body_params

      assert "/batch/emails" == conn.request_path
      assert "POST" == conn.method

      Plug.Conn.resp(conn, 200, ~s({"results": 2}))
    end)

    assert {:ok, 2} = Bento.deliver_many([email1, email2], config)
  end
end
