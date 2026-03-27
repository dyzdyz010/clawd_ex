defmodule ClawdEx.Channels.Channel do
  @moduledoc """
  Channel 行为定义 - 所有消息渠道必须实现此接口
  """

  @type message :: %{
          id: String.t(),
          content: String.t(),
          author_id: String.t(),
          author_name: String.t() | nil,
          channel_id: String.t(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  @type send_opts :: [
          reply_to: String.t() | nil,
          buttons: [[map()]] | nil
        ]

  @doc """
  发送消息到渠道
  """
  @callback send_message(channel_id :: String.t(), content :: String.t(), opts :: send_opts()) ::
              {:ok, message()} | {:error, term()}

  @doc """
  处理收到的消息
  """
  @callback handle_message(message()) :: :ok | {:error, term()}

  @doc """
  获取渠道名称
  """
  @callback name() :: String.t()

  @doc """
  检查渠道是否就绪
  """
  @callback ready?() :: boolean()

  @doc """
  Build a deterministic session key for an agent bound to a channel location.
  Used by channel bindings to auto-generate session keys.
  """
  @callback build_session_key(agent_id :: integer, channel_config :: map) :: String.t()

  @doc """
  Deliver a message to a specific channel location.
  Used by SessionWorker heartbeat delivery and binding-based message routing.
  """
  @callback deliver_message(channel_config :: map, content :: String.t(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @optional_callbacks [build_session_key: 2, deliver_message: 3]
end
