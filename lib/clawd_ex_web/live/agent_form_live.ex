defmodule ClawdExWeb.AgentFormLive do
  @moduledoc """
  Agent 创建/编辑表单
  """
  use ClawdExWeb, :live_view

  import ClawdExWeb.AgentFormComponents

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.AI.Models

  # 默认工作目录基础路径
  @default_workspace_base "~/clawd/agents"

  @impl true
  def mount(params, _session, socket) do
    {agent, title, is_new} =
      case params do
        %{"id" => id} ->
          agent = Repo.get!(Agent, id)
          {agent, "Edit Agent: #{agent.name}", false}

        _ ->
          {%Agent{}, "New Agent", true}
      end

    changeset = Agent.changeset(agent, %{})

    socket =
      socket
      |> assign(:page_title, title)
      |> assign(:agent, agent)
      |> assign(:is_new, is_new)
      |> assign(:form, to_form(changeset))
      |> assign(:available_models, Models.all() |> Map.keys() |> Enum.sort())
      |> assign(:workspace_auto_generated, is_new)
      |> assign(:suggested_workspace, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"agent" => params}, socket) do
    params = parse_config_param(params)

    # 如果是新建且 workspace 还是自动生成状态，根据 name 自动生成 workspace_path
    params =
      if socket.assigns.is_new and socket.assigns.workspace_auto_generated do
        maybe_auto_generate_workspace(params)
      else
        params
      end

    changeset =
      socket.assigns.agent
      |> Agent.changeset(params)
      |> Map.put(:action, :validate)

    # 计算建议的 workspace path
    suggested = generate_workspace_path(params["name"])

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:suggested_workspace, suggested)

    {:noreply, socket}
  end

  @impl true
  def handle_event("workspace_manual_edit", _params, socket) do
    # 用户手动编辑了 workspace，停止自动生成
    {:noreply, assign(socket, :workspace_auto_generated, false)}
  end

  @impl true
  def handle_event("use_suggested_workspace", _params, socket) do
    # 使用建议的 workspace path
    suggested = socket.assigns.suggested_workspace

    if suggested do
      params =
        socket.assigns.form.params
        |> Map.put("workspace_path", suggested)

      changeset =
        socket.assigns.agent
        |> Agent.changeset(params)
        |> Map.put(:action, :validate)

      socket =
        socket
        |> assign(:form, to_form(changeset))
        |> assign(:workspace_auto_generated, true)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"agent" => params}, socket) do
    params = parse_config_param(params)

    result =
      if socket.assigns.agent.id do
        socket.assigns.agent
        |> Agent.changeset(params)
        |> Repo.update()
      else
        %Agent{}
        |> Agent.changeset(params)
        |> Repo.insert()
      end

    case result do
      {:ok, _agent} ->
        socket =
          socket
          |> put_flash(
            :info,
            "Agent #{if socket.assigns.agent.id, do: "updated", else: "created"} successfully"
          )
          |> push_navigate(to: ~p"/agents")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # 根据 agent name 自动生成 workspace path
  defp maybe_auto_generate_workspace(params) do
    name = params["name"] || ""
    current_workspace = params["workspace_path"] || ""

    # 只有当 workspace 为空或者是自动生成的格式时才自动更新
    if current_workspace == "" or String.starts_with?(current_workspace, @default_workspace_base) do
      Map.put(params, "workspace_path", generate_workspace_path(name))
    else
      params
    end
  end

  defp generate_workspace_path(nil), do: nil
  defp generate_workspace_path(""), do: nil

  defp generate_workspace_path(name) do
    # 将名字转换为 slug 格式
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^\w\s-]/, "")
      |> String.replace(~r/[\s_]+/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    if slug != "" do
      "#{@default_workspace_base}/#{slug}"
    else
      nil
    end
  end

  defp parse_config_param(params) do
    case params["config"] do
      nil ->
        params

      "" ->
        Map.put(params, "config", %{})

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, config} -> Map.put(params, "config", config)
          {:error, _} -> Map.put(params, "config", %{})
        end

      _ ->
        params
    end
  end

  defp model_options(models) do
    Enum.map(models, fn model ->
      {model, model}
    end)
  end

  defp get_config_value(nil, _key, default), do: default

  defp get_config_value(config, key, default) when is_map(config) do
    Map.get(config, key, Map.get(config, to_string(key), default))
  end

  defp get_config_value(_config, _key, default), do: default
end
