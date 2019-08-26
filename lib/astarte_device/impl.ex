#
# This file is part of Astarte.
#
# Copyright 2019 Ispirata Srl
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

defmodule Astarte.Device.Impl do
  @moduledoc false

  require Logger

  # Mockable modules
  @connection Application.get_env(
                :astarte_device,
                :connection_mod,
                Astarte.Device.TortoiseConnection
              )
  @pairing_devices Application.get_env(
                     :astarte_device,
                     :pairing_devices_mod,
                     Astarte.API.Pairing.Devices
                   )

  alias Astarte.Core.Mapping
  alias Astarte.Core.Interface
  alias Astarte.Device.Data

  # 7 days
  @nearly_expired_seconds 7 * 24 * 60 * 60
  @key_size 4096

  @type data :: Astarte.Device.Data.t()

  @spec init(opts :: keyword()) ::
          {:ok, data :: data()}
          | {:no_keypair, data :: data()}
          | {:no_certificate, data :: data()}
  def init(opts) do
    data = Data.from_opts!(opts)

    %Data{
      credential_storage_mod: credential_storage_mod,
      credential_storage_state: credential_storage_state
    } = data

    with {:keypair, true} <-
           {:keypair, credential_storage_mod.has_keypair?(credential_storage_state)},
         {:certificate, {:ok, pem_certificate}} <-
           {:certificate, credential_storage_mod.fetch(:certificate, credential_storage_state)},
         {:valid_certificate, true} <-
           {:valid_certificate, valid_certificate?(pem_certificate)} do
      {:ok, data}
    else
      {:keypair, false} ->
        {:no_keypair, data}

      {:certificate, :error} ->
        {:no_certificate, data}

      {:valid_certificate, false} ->
        # If the certificate is invalid, we treat it like it's not there
        {:no_certificate, data}
    end
  end

  defp valid_certificate?(pem_certificate) do
    with {:ok, certificate} <- X509.Certificate.from_pem(pem_certificate) do
      {:Validity, _not_before, not_after} = X509.Certificate.validity(certificate)

      seconds_until_expiry =
        not_after
        |> X509.DateTime.to_datetime()
        |> DateTime.diff(DateTime.utc_now())

      # If the certificate it's near its expiration, we treat it as invalid
      seconds_until_expiry > @nearly_expired_seconds
    else
      {:error, _reason} ->
        false
    end
  end

  @spec generate_keypair(data :: data()) ::
          {:ok, new_data :: data()}
          | {:error, reason :: term()}
  def generate_keypair(data) do
    %Data{
      client_id: client_id,
      credential_storage_mod: credential_storage_mod,
      credential_storage_state: credential_storage_state
    } = data

    _ = Logger.info("#{client_id}: Generating a new keypair")

    # TODO: make crypto configurable (RSA/EC, key size/curve)
    private_key = X509.PrivateKey.new_rsa(@key_size)

    pem_csr =
      private_key
      |> X509.CSR.new("CN=#{client_id}")
      |> X509.CSR.to_pem()

    pem_private_key = X509.PrivateKey.to_pem(private_key)

    with {:ok, with_key_state} <-
           credential_storage_mod.save(:private_key, pem_private_key, credential_storage_state),
         {:ok, with_key_and_csr_state} <-
           credential_storage_mod.save(:csr, pem_csr, with_key_state) do
      {:ok, %{data | credential_storage_state: with_key_and_csr_state}}
    end
  end

  @spec request_certificate(data :: data()) ::
          {:ok, new_data :: data()}
          | {:error, :temporary}
          | {:error, reason :: term()}
  def request_certificate(data) do
    alias Astarte.API.Pairing

    %Data{
      client_id: client_id,
      pairing_url: pairing_url,
      realm: realm,
      credentials_secret: credentials_secret,
      device_id: device_id,
      credential_storage_mod: credential_storage_mod,
      credential_storage_state: credential_storage_state
    } = data

    _ = Logger.info("#{client_id}: Requesting new certificate")

    client = Pairing.client(pairing_url, realm, auth_token: credentials_secret)
    {:ok, csr} = credential_storage_mod.fetch(:csr, credential_storage_state)

    with {:api, {:ok, %{status: 201, body: body}}} <-
           {:api, @pairing_devices.get_mqtt_v1_credentials(client, device_id, csr)},
         %{"data" => %{"client_crt" => pem_cert}} = body,
         {:store, {:ok, new_credential_storage_state}} <-
           {:store, credential_storage_mod.save(:certificate, pem_cert, credential_storage_state)} do
      _ = Logger.info("#{client_id}: Received new certificate")
      {:ok, %{data | credential_storage_state: new_credential_storage_state}}
    else
      error ->
        classify_error(error, client_id)
    end
  end

  @spec request_info(data :: data()) ::
          {:ok, new_data :: data()}
          | {:error, :temporary}
          | {:error, reason :: term()}
  def request_info(data) do
    %Data{
      client_id: client_id,
      credentials_secret: credentials_secret,
      pairing_url: pairing_url,
      realm: realm,
      device_id: device_id
    } = data

    _ = Logger.info("#{client_id}: Requesting info")

    client = Astarte.API.Pairing.client(pairing_url, realm, auth_token: credentials_secret)

    with {:api, {:ok, %{status: 200, body: body}}} <-
           {:api, @pairing_devices.info(client, device_id)} do
      %{"data" => %{"protocols" => %{"astarte_mqtt_v1" => %{"broker_url" => broker_url}}}} = body
      _ = Logger.info("#{client_id}: Broker url is #{broker_url}")
      {:ok, %{data | broker_url: broker_url}}
    else
      error ->
        classify_error(error, client_id)
    end
  end

  @spec connect(data :: data()) ::
          {:ok, new_data :: data()}
          | {:error, reason :: term()}
  def connect(data) do
    %Data{
      client_id: client_id,
      broker_url: broker_url,
      ignore_ssl_errors: ignore_ssl_errors,
      credential_storage_mod: credential_storage_mod,
      credential_storage_state: credential_storage_state,
      interface_provider_mod: interface_provider_mod,
      interface_provider_state: interface_provider_state
    } = data

    with {:ok, pem_private_key} <-
           credential_storage_mod.fetch(:private_key, credential_storage_state),
         {:ok, pem_certificate} <-
           credential_storage_mod.fetch(:certificate, credential_storage_state),
         server_owned_interfaces =
           interface_provider_mod.server_owned_interfaces(interface_provider_state),
         initial_subscriptions = build_subscriptions(client_id, server_owned_interfaces),
         connection_opts = [
           client_id: client_id,
           broker_url: broker_url,
           key_pem: pem_private_key,
           certificate_pem: pem_certificate,
           initial_subscriptions: initial_subscriptions,
           ignore_ssl_errors: ignore_ssl_errors
         ],
         {:ok, pid} <- @connection.start_link(connection_opts) do
      {:ok, %{data | mqtt_connection: pid}}
    end
  end

  @spec publish(publish_params, data :: data()) :: :ok | {:error, reason :: term()}
        when publish_params: [publish_param],
             publish_param:
               {:publish_type, :datastream | :properties}
               | {:interface_name, interface_name :: String.t()}
               | {:path, path :: String.t()}
               | {:value, value :: term()}
               | {:opts, options},
             options: [option],
             option:
               {:qos, qos}
               | {:timestamp, timestamp :: DateTime.t()},
             qos: 0 | 1 | 2
  def publish(publish_params, data) do
    # TODO:
    # - Handle empty payload (check allow_unset)
    # - Enforce timestamps if explicit_timestamp is true

    %Data{
      client_id: client_id
    } = data

    publish_type = Keyword.fetch!(publish_params, :publish_type)
    interface_name = Keyword.fetch!(publish_params, :interface_name)
    path = Keyword.fetch!(publish_params, :path)
    value = Keyword.fetch!(publish_params, :value)
    opts = Keyword.get(publish_params, :opts, [])

    with {:ok, interface} <- fetch_interface(interface_name, data),
         :ok <- validate_publish_type(publish_type, interface),
         :ok <- validate_ownership(:device, interface),
         :ok <- validate_path_and_type(interface, path, value),
         payload_map = build_payload_map(value, opts),
         {:ok, bson_payload} <- Cyanide.encode(payload_map) do
      publish_opts = Keyword.take(opts, [:qos])
      "/" <> bare_path = path

      topic =
        if bare_path == "" do
          # Handle publishing on root interface topic for object aggregations
          Enum.join([client_id, interface_name], "/")
        else
          Enum.join([client_id, interface_name, bare_path], "/")
        end

      @connection.publish_sync(client_id, topic, bson_payload, publish_opts)
    end
  end

  @spec send_introspection(data :: data()) :: :ok | {:error, reason :: term()}
  def send_introspection(data) do
    %Data{
      client_id: client_id,
      interface_provider_mod: interface_provider_mod,
      interface_provider_state: interface_provider_state
    } = data

    interfaces = interface_provider_mod.all_interfaces(interface_provider_state)

    introspection = build_introspection(interfaces)

    _ = Logger.info("#{client_id}: Sending introspection: #{introspection}")

    # Introspection topic is the same as client_id
    topic = client_id
    @connection.publish_sync(client_id, topic, introspection, qos: 2)
  end

  @spec send_empty_cache(data :: data()) :: :ok | {:error, reason :: term()}
  def send_empty_cache(data) do
    %Data{
      client_id: client_id
    } = data

    _ = Logger.info("#{client_id}: Sending empty cache")

    topic = "#{client_id}/control/emptyCache"
    payload = "1"

    @connection.publish_sync(client_id, topic, payload, qos: 2)
  end

  @spec send_producer_properties(data :: data()) :: :ok
  def send_producer_properties(data) do
    %Data{
      client_id: client_id
    } = data

    _ = Logger.info("#{client_id}: Sending producer properties")
    # TODO: build and send producer properties

    :ok
  end

  @spec handle_message(topic_tokens :: [String.t()], payload :: term(), data :: data()) ::
          :ok | {:ok, new_data :: data()} | {:error, reason :: term()}
  def handle_message(topic_tokens, payload, data) do
    %Data{
      client_id: client_id,
      realm: realm,
      device_id: device_id
    } = data

    case topic_tokens do
      [^realm, ^device_id, "control" | control_path_tokens] ->
        handle_control_message(control_path_tokens, payload, data)

      [^realm, ^device_id, interface_name | path_tokens] ->
        handle_data_message(interface_name, path_tokens, payload, data)

      other_topic_tokens ->
        _ =
          Logger.warn(
            "#{client_id}: received message on unhandled topic #{Path.join(other_topic_tokens)}"
          )

        {:error, :invalid_incoming_message}
    end
  end

  defp handle_control_message(["emptyCache"], _payload, _data) do
    # This is sent by us and "mirrored" by the broker, ignore it
    :ok
  end

  defp handle_control_message(control_path_tokens, payload, data) do
    %Data{
      client_id: client_id
    } = data

    # TODO: handle control messages
    _ =
      Logger.info(
        "#{client_id}: received control message, control_path_tokens=#{
          inspect(control_path_tokens)
        }, payload=#{inspect(payload)}"
      )

    :ok
  end

  defp handle_data_message(interface_name, path_tokens, payload, data) do
    %Data{
      handler_pid: handler_pid
    } = data

    path = "/" <> Path.join(path_tokens)

    # TODO: persist the message to avoid losing it in case of a crash

    with {:ok, interface} <- fetch_interface(interface_name, data),
         :ok <- validate_ownership(:server, interface),
         mappings = interface.mappings,
         {:ok, %Mapping{value_type: expected_type}} <- find_mapping(path, mappings),
         {:ok, %{"v" => value} = decoded_map} <- Cyanide.decode(payload),
         timestamp = Map.get(decoded_map, "t"),
         :ok <- Mapping.ValueType.validate_value(expected_type, value) do
      request = {:msg, interface_name, path_tokens, value, timestamp}
      GenServer.cast(handler_pid, request)
    end
  end

  defp build_subscriptions(client_id, server_interfaces) do
    control_topic_subscription = "#{client_id}/control/#"

    interface_topic_subscriptions =
      Enum.flat_map(server_interfaces, fn %Interface{name: interface_name} ->
        ["#{client_id}/#{interface_name}", "#{client_id}/#{interface_name}/#"]
      end)

    [control_topic_subscription | interface_topic_subscriptions]
  end

  defp build_introspection(interfaces) do
    for %Interface{name: interface_name, major_version: major, minor_version: minor} <- interfaces do
      "#{interface_name}:#{major}:#{minor}"
    end
    |> Enum.join(";")
  end

  defp fetch_interface(interface_name, data) do
    %Data{
      interface_provider_mod: interface_provider_mod,
      interface_provider_state: interface_provider_state
    } = data

    case interface_provider_mod.fetch_interface(interface_name, interface_provider_state) do
      {:ok, interface} ->
        {:ok, interface}

      :error ->
        {:error, :interface_not_found}
    end
  end

  defp find_mapping(path, mappings) do
    alias Mapping.EndpointsAutomaton

    with {:ok, endpoint_automaton} <- EndpointsAutomaton.build(mappings),
         {:ok, endpoint} <- EndpointsAutomaton.resolve_path(path, endpoint_automaton),
         %Mapping{} = mapping <-
           Enum.find(mappings, fn %Mapping{} = mapping ->
             mapping.endpoint == endpoint
           end) do
      {:ok, mapping}
    else
      _ ->
        {:error, :cannot_resolve_path}
    end
  end

  defp build_payload_map(value, opts) do
    case Keyword.fetch(opts, :timestamp) do
      {:ok, %DateTime{} = timestamp} ->
        %{v: value, t: timestamp}

      _ ->
        %{v: value}
    end
  end

  defp validate_publish_type(publish_type, %Interface{type: publish_type}) do
    :ok
  end

  defp validate_publish_type(_type, %Interface{type: :properties}) do
    {:error, :properties_interface}
  end

  defp validate_publish_type(_type, %Interface{type: :datastream}) do
    {:error, :datastream_interface}
  end

  defp validate_ownership(ownership, %Interface{ownership: ownership}) do
    :ok
  end

  defp validate_ownership(_ownership, %Interface{ownership: :server}) do
    {:error, :server_owned_interface}
  end

  defp validate_ownership(_ownership, %Interface{ownership: :device}) do
    {:error, :device_owned_interface}
  end

  defp validate_path_and_type(%Interface{aggregation: :individual} = interface, path, value) do
    mappings = interface.mappings

    with {:ok, %Mapping{value_type: expected_type}} <- find_mapping(path, mappings) do
      Mapping.ValueType.validate_value(expected_type, value)
    end
  end

  defp validate_path_and_type(%Interface{aggregation: :object}, "/" <> _bare_path, _value) do
    # TODO: validate object aggregation interfaces, currently it just checks
    # that the path begins with /
    :ok
  end

  defp validate_path_and_type(%Interface{aggregation: :object}, _invalid_path, _value) do
    {:error, :cannot_resolve_path}
  end

  defp classify_error({:api, {:error, reason}}, log_tag)
       when reason in [:econnrefused, :closed] do
    # Temporary errors
    _ = Logger.warn("#{log_tag}: Temporary failure in API request: #{inspect(reason)}.")
    {:error, :temporary}
  end

  defp classify_error({:api, {:error, reason}}, log_tag) do
    # Other errors are assumed to be permanent
    _ = Logger.warn("#{log_tag}: Failure in API request: #{inspect(reason)}.")
    {:error, reason}
  end

  defp classify_error({:api, {:ok, %{status: status, body: body}}}, log_tag)
       when status >= 500 do
    # We assume Server Errors in the 500 range are temporary
    _ = Logger.warn("#{log_tag}: API request failed with status #{status}: #{inspect(body)}.")

    {:error, :temporary}
  end

  defp classify_error({:api, {:ok, %{status: status, body: body}}}, log_tag)
       when status >= 400 and status < 500 do
    # All HTTP errors in the 400 range are assumed to be permanent (authentication, bad request etc)
    _ = Logger.warn("#{log_tag}: API request failed with status #{status}: #{inspect(body)}.")

    {:error, :request_certificate_failed}
  end

  defp classify_error({:store, {:error, reason}}, log_tag) do
    # Storage errors are assumed to be permanent
    _ = Logger.warn("#{log_tag}: failed to store credentials")
    {:error, reason}
  end
end
