defmodule Igniter.Libs.Phoenix do
  @moduledoc "Codemods & utilities for working with Phoenix"

  @doc """
  Returns the web module name for the current app
  """
  @spec web_module_name() :: module()
  @deprecated "Use `web_module/0` instead."
  def web_module_name do
    web_module(Igniter.new())
  end

  @doc """
  Returns the web module name for the current app
  """
  @spec web_module(Igniter.t()) :: module()
  def web_module(igniter) do
    prefix =
      igniter
      |> Igniter.Project.Module.module_name_prefix()
      |> inspect()

    if String.ends_with?(prefix, "Web") do
      Module.concat([prefix])
    else
      Module.concat([prefix <> "Web"])
    end
  end

  @doc "Returns `true` if the module is a Phoenix HTML module"
  @spec html?(Igniter.t(), module()) :: boolean()
  def html?(igniter, module) do
    zipper = elem(Igniter.Project.Module.find_module!(igniter, module), 2)

    case Igniter.Code.Common.move_to(zipper, fn zipper ->
           if Igniter.Code.Function.function_call?(zipper, :use, 2) do
             using_a_webbish_module?(zipper) &&
               Igniter.Code.Function.argument_equals?(zipper, 1, :html)
           else
             false
           end
         end) do
      {:ok, _} ->
        true

      _ ->
        false
    end
  end

  @doc "Returns `true` if the module is a Phoenix controller"
  @spec controller?(Igniter.t(), module()) :: boolean()
  def controller?(igniter, module) do
    zipper = elem(Igniter.Project.Module.find_module!(igniter, module), 2)

    case Igniter.Code.Common.move_to(zipper, fn zipper ->
           if Igniter.Code.Function.function_call?(zipper, :use, 2) do
             using_a_webbish_module?(zipper) &&
               Igniter.Code.Function.argument_equals?(zipper, 1, :controller)
           else
             false
           end
         end) do
      {:ok, _} ->
        true

      _ ->
        false
    end
  end

  @doc """
  Generates a module name that lives in the Web directory of the current app.
  """
  @spec web_module_name(String.t()) :: module()
  @deprecated "Use `web_module_name/2` instead."
  def web_module_name(suffix) do
    Module.concat(web_module(Igniter.new()), suffix)
  end

  @doc """
  Generates a module name that lives in the Web directory of the current app.
  """
  @spec web_module_name(Igniter.t(), String.t()) :: module()
  def web_module_name(igniter, suffix) do
    Module.concat(web_module(igniter), suffix)
  end

  @doc "Gets the list of endpoints that use a given router"
  @spec endpoints_for_router(igniter :: Igniter.t(), router :: module()) ::
          {Igniter.t(), list(module())}
  def endpoints_for_router(igniter, router) do
    Igniter.Project.Module.find_all_matching_modules(igniter, fn _module, zipper ->
      with {:ok, _} <- Igniter.Code.Module.move_to_use(zipper, Phoenix.Endpoint),
           {:ok, _} <-
             Igniter.Code.Function.move_to_function_call_in_current_scope(
               zipper,
               :plug,
               [1, 2],
               &Igniter.Code.Function.argument_equals?(&1, 0, router)
             ) do
        true
      else
        _ ->
          false
      end
    end)
  end

  @doc """
  Selects an endpoint to be used in a later step. If only one endpoint is found, it will be selected automatically.

  If no endpoints exist, `{igniter, nil}` is returned.

  If multiple endpoints are found, the user is prompted to select one of them.
  """
  @spec select_endpoint(Igniter.t(), module() | nil, String.t()) :: {Igniter.t(), module() | nil}
  def select_endpoint(igniter, router \\ nil, label \\ "Which endpoint should be used") do
    if router do
      case endpoints_for_router(igniter, router) do
        {igniter, []} ->
          {igniter, nil}

        {igniter, [endpoint]} ->
          {igniter, endpoint}

        {igniter, endpoints} ->
          {igniter, Igniter.Util.IO.select(label, endpoints, display: &inspect/1)}
      end
    else
      {igniter, endpoints} =
        Igniter.Project.Module.find_all_matching_modules(igniter, fn _mod, zipper ->
          Igniter.Code.Module.move_to_use(zipper, Phoenix.Endpoint) != :error
        end)

      case endpoints do
        [] ->
          {igniter, nil}

        [endpoint] ->
          {igniter, endpoint}

        endpoints ->
          {igniter, Igniter.Util.IO.select(label, endpoints, display: &inspect/1)}
      end
    end
  end

  @doc """
  Adds a scope to a Phoenix router.

  ## Options

  - `:router` - The router module to append to. Will be looked up if not provided.
  - `:arg2` - The second argument to the scope macro. Must be a value (typically a module).
  - `:placement` - `:before` | `:after`. Determines where the `contents` will be placed:
    - `:before` - place before the first scope in the module if one is found, otherwise tries to place
       after the last pipeline or after the `use MyAppWeb, :router` call.
    - `:after` - place at the end (bottom) of the module, after all scopes and pipelines.
  """
  @spec add_scope(Igniter.t(), String.t(), String.t(), Keyword.t()) :: Igniter.t()
  def add_scope(igniter, route, contents, opts \\ []) do
    {igniter, router} =
      case Keyword.fetch(opts, :router) do
        {:ok, router} ->
          {igniter, router}

        :error ->
          select_router(igniter)
      end

    scope_code =
      case Keyword.fetch(opts, :arg2) do
        {:ok, arg2} ->
          """
          scope "#{route}", #{inspect(arg2)} do
            #{contents}
          end
          """

        _ ->
          """
          scope #{inspect(route)} do
            #{contents}
          end
          """
      end

    if router do
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        case move_to_scope_location(igniter, zipper, placement: opts[:placement] || :before) do
          {:ok, zipper, append_or_prepend} ->
            {:ok, Igniter.Code.Common.add_code(zipper, scope_code, placement: append_or_prepend)}

          :error ->
            {:warning,
             Igniter.Util.Warning.formatted_warning(
               "Could not add a scope for #{inspect(route)} to your router. Please add it manually.",
               scope_code
             )}
        end
      end)
    else
      Igniter.add_warning(
        igniter,
        Igniter.Util.Warning.formatted_warning(
          "Could not add a scope for #{inspect(route)} to your router. Please add it manually.",
          scope_code
        )
      )
    end
  end

  @doc """
  Appends to a phoenix router scope.

  Relatively limited currently only exact matches of a top level route, second argument, and pipelines.

  ## Options

  * `:router` - The router module to append to. Will be looked up if not provided.
  * `:arg2` - The second argument to the scope macro. Must be a value (typically a module).
  * `:with_pipelines` - A list of pipelines that the pipeline must be using to be considered a match.
  - `:placement` - `:before` | `:after`. Determines where the `contents` will be placed. Note that it first tries
    to find a matching scope and place the contents into that scope, otherwise `:placement` is used to determine
    where to place the contents:
    * `:before` - place before the first scope in the module if one is found, otherwise tries to place
       after the last pipeline or after the `use MyAppWeb, :router` call.
    * `:after` - place at the end (bottom) of the module, after all scopes and pipelines.
  """
  @spec append_to_scope(Igniter.t(), String.t(), String.t(), Keyword.t()) :: Igniter.t()
  def append_to_scope(igniter, route, contents, opts \\ []) do
    {igniter, router} =
      case Keyword.fetch(opts, :router) do
        {:ok, router} ->
          {igniter, router}

        :error ->
          select_router(igniter)
      end

    scope_code =
      case Keyword.fetch(opts, :arg2) do
        {:ok, arg2} ->
          if opts[:with_pipelines] do
            """
            scope "#{route}", #{inspect(arg2)} do
              pipe_through #{inspect(opts[:with_pipelines])}
              #{contents}
            end
            """
          else
            """
            scope "#{route}", #{inspect(arg2)} do
              #{contents}
            end
            """
          end

        _ ->
          if opts[:with_pipelines] do
            """
            scope #{inspect(route)} do
              pipe_through #{inspect(opts[:with_pipelines])}
              #{contents}
            end
            """
          else
            """
            scope #{inspect(route)} do
              #{contents}
            end
            """
          end
      end

    if router do
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        case move_to_matching_scope(zipper, route, opts) do
          {:ok, zipper} ->
            {:ok, Igniter.Code.Common.add_code(zipper, contents)}

          :error ->
            case move_to_scope_location(igniter, zipper, placement: opts[:placement] || :before) do
              {:ok, zipper, append_or_prepend} ->
                {:ok,
                 Igniter.Code.Common.add_code(zipper, scope_code, placement: append_or_prepend)}

              :error ->
                {:warning,
                 Igniter.Util.Warning.formatted_warning(
                   "Could not add a scope for #{inspect(route)} to your router. Please add it manually.",
                   scope_code
                 )}
            end
        end
      end)
    else
      Igniter.add_warning(
        igniter,
        Igniter.Util.Warning.formatted_warning(
          "Could not add a scope for #{inspect(route)} to your router. Please add it manually.",
          scope_code
        )
      )
    end
  end

  @doc """
  Appends code to a Phoenix router pipeline.

  ## Options

  * `:router` - The router module to append to. Will be looked up if not provided.
  """
  @spec append_to_pipeline(Igniter.t(), atom, String.t(), Keyword.t()) :: Igniter.t()
  def append_to_pipeline(igniter, name, contents, opts \\ []) do
    {igniter, router} =
      case Keyword.fetch(opts, :router) do
        {:ok, router} ->
          {igniter, router}

        :error ->
          select_router(igniter)
      end

    pipeline_code = """
    pipeline #{inspect(name)} do
      #{contents}
    end
    """

    if router do
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        Igniter.Code.Function.move_to_function_call_in_current_scope(
          zipper,
          :pipeline,
          2,
          fn zipper ->
            Igniter.Code.Function.argument_equals?(
              zipper,
              0,
              name
            )
          end
        )
        |> case do
          {:ok, zipper} ->
            case Igniter.Code.Common.move_to_do_block(zipper) do
              {:ok, zipper} ->
                {:ok, Igniter.Code.Common.add_code(zipper, contents)}

              :error ->
                {:warning,
                 Igniter.Util.Warning.formatted_warning(
                   "Could not add the #{name} pipeline to your router. Please add it manually.",
                   pipeline_code
                 )}
            end

          _ ->
            case move_to_pipeline_location(igniter, zipper) do
              {:ok, zipper, append_or_prepend} ->
                {:ok,
                 Igniter.Code.Common.add_code(zipper, pipeline_code, placement: append_or_prepend)}

              :error ->
                {:warning,
                 Igniter.Util.Warning.formatted_warning(
                   "Could not add the #{name} pipeline to your router. Please add it manually.",
                   pipeline_code
                 )}
            end
        end
      end)
    else
      Igniter.add_warning(
        igniter,
        Igniter.Util.Warning.formatted_warning(
          "Could not append the following contents to the #{name} pipeline to your router. Please add it manually.",
          contents
        )
      )
    end
  end

  @doc """
  Prepends code to a Phoenix router pipeline.

  ## Options

  * `:router` - The router module to append to. Will be looked up if not provided.
  """
  @spec prepend_to_pipeline(Igniter.t(), atom, String.t(), Keyword.t()) :: Igniter.t()
  def prepend_to_pipeline(igniter, name, contents, opts \\ []) do
    {igniter, router} =
      case Keyword.fetch(opts, :router) do
        {:ok, router} ->
          {igniter, router}

        :error ->
          select_router(igniter)
      end

    pipeline_code = """
    pipeline #{inspect(name)} do
      #{contents}
    end
    """

    if router do
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        Igniter.Code.Function.move_to_function_call_in_current_scope(
          zipper,
          :pipeline,
          2,
          fn zipper ->
            Igniter.Code.Function.argument_equals?(
              zipper,
              0,
              name
            )
          end
        )
        |> case do
          {:ok, zipper} ->
            case Igniter.Code.Common.move_to_do_block(zipper) do
              {:ok, zipper} ->
                {:ok, Igniter.Code.Common.add_code(zipper, contents, placement: :before)}

              :error ->
                {:warning,
                 Igniter.Util.Warning.formatted_warning(
                   "Could not add the #{name} pipeline to your router. Please add it manually.",
                   pipeline_code
                 )}
            end

          _ ->
            case move_to_pipeline_location(igniter, zipper) do
              {:ok, zipper, append_or_prepend} ->
                {:ok,
                 Igniter.Code.Common.add_code(zipper, pipeline_code, placement: append_or_prepend)}

              :error ->
                {:warning,
                 Igniter.Util.Warning.formatted_warning(
                   "Could not add the #{name} pipeline to your router. Please add it manually.",
                   pipeline_code
                 )}
            end
        end
      end)
    else
      Igniter.add_warning(
        igniter,
        Igniter.Util.Warning.formatted_warning(
          "Could not append the following contents to the #{name} pipeline to your router. Please add it manually.",
          contents
        )
      )
    end
  end

  @doc """
  Adds a pipeline to a Phoenix router.

  ## Options

  * `:router` - The router module to append to. Will be looked up if not provided.
  * `:arg2` - The second argument to the scope macro. Must be a value (typically a module).
  """
  @spec add_pipeline(Igniter.t(), atom(), String.t(), Keyword.t()) :: Igniter.t()
  def add_pipeline(igniter, name, contents, opts \\ []) do
    {igniter, router} =
      case Keyword.fetch(opts, :router) do
        {:ok, router} ->
          {igniter, router}

        :error ->
          select_router(igniter)
      end

    pipeline_code = """
    pipeline #{inspect(name)} do
      #{contents}
    end
    """

    if router do
      Igniter.Project.Module.find_and_update_module!(igniter, router, fn zipper ->
        Igniter.Code.Function.move_to_function_call(zipper, :pipeline, 2, fn zipper ->
          Igniter.Code.Function.argument_equals?(
            zipper,
            0,
            name
          )
        end)
        |> case do
          {:ok, _} ->
            if Keyword.get(opts, :warn_on_present?, true) do
              {:warning,
               Igniter.Util.Warning.formatted_warning(
                 "The #{name} pipeline already exists in the router. Attempting to add pipeline: ",
                 pipeline_code
               )}
            else
              {:ok, zipper}
            end

          _ ->
            case move_to_pipeline_location(igniter, zipper) do
              {:ok, zipper, append_or_prepend} ->
                {:ok,
                 Igniter.Code.Common.add_code(zipper, pipeline_code, placement: append_or_prepend)}

              :error ->
                {:warning,
                 Igniter.Util.Warning.formatted_warning(
                   "Could not add the #{name} pipeline to your router. Please add it manually.",
                   pipeline_code
                 )}
            end
        end
      end)
    else
      Igniter.add_warning(
        igniter,
        Igniter.Util.Warning.formatted_warning(
          "Could not add the #{name} pipeline to your router. Please add it manually.",
          pipeline_code
        )
      )
    end
  end

  @doc """
  Returns `{igniter, true}` if a pipeline exists in a Phoenix router, and `{igniter, false}` otherwise.

  ## Options

  * `:router` - The router module to append to. Will be looked up if not provided.
  * `:arg2` - The second argument to the scope macro. Must be a value (typically a module).
  """
  @spec has_pipeline(Igniter.t(), router :: module(), name :: atom()) ::
          {Igniter.t(), boolean()}
  def has_pipeline(igniter, router, name) do
    {_igniter, _source, zipper} = Igniter.Project.Module.find_module!(igniter, router)

    Igniter.Code.Function.move_to_function_call(zipper, :pipeline, 2, fn zipper ->
      Igniter.Code.Function.argument_equals?(
        zipper,
        0,
        name
      )
    end)
    |> case do
      {:ok, _} -> {igniter, true}
      _ -> {igniter, false}
    end
  end

  @doc """
  Selects a router to be used in a later step. If only one router is found, it will be selected automatically.

  If no routers exist, `{igniter, nil}` is returned.

  If multiple routes are found, the user is prompted to select one of them.
  """
  @spec select_router(Igniter.t(), String.t()) :: {Igniter.t(), module() | nil}
  def select_router(igniter, label \\ "Which router should be modified?") do
    case list_routers(igniter) do
      {igniter, []} ->
        {igniter, nil}

      {igniter, [router]} ->
        {igniter, router}

      {igniter, routers} ->
        {igniter, Igniter.Util.IO.select(label, routers, display: &inspect/1)}
    end
  end

  @doc "Lists all routers found in the project."
  @spec list_routers(Igniter.t()) :: {Igniter.t(), [module()]}
  def list_routers(igniter) do
    Igniter.Project.Module.find_all_matching_modules(igniter, fn _mod, zipper ->
      # Look for `use <WebModule>, :router` or `use Phoenix.Router`
      case Igniter.Code.Function.move_to_function_call(zipper, :use, 2, fn zipper ->
             with {:ok, arg_zipper} <- Igniter.Code.Function.move_to_nth_argument(zipper, 0),
                  true <- Igniter.Code.Module.module?(arg_zipper) do
               Igniter.Code.Function.argument_equals?(zipper, 1, :router)
             else
               _ -> false
             end
           end) do
        {:ok, _} ->
          true

        :error ->
          # Fallback: check for direct Phoenix.Router usage
          Igniter.Code.Module.move_to_use(zipper, Phoenix.Router) != :error
      end
    end)
  end

  @doc """
  Lists all web modules found in the project.

  A web module is defined as:
  - Only one level of namespace deep (e.g., `FooWeb` not `Foo.BarWeb`)
  - Ends with `Web`
  """
  @spec list_web_modules(Igniter.t()) :: {Igniter.t(), [module()]}
  def list_web_modules(igniter) do
    Igniter.Project.Module.find_all_matching_modules(igniter, fn module, _zipper ->
      web_module?(module)
    end)
  end

  @doc "Moves to the use statement in a module that matches `use <WebModule>, :router`"
  @spec move_to_router_use(Igniter.t(), Sourceror.Zipper.t()) ::
          :error | {:ok, Sourceror.Zipper.t()}
  def move_to_router_use(_igniter, zipper) do
    with :error <-
           Igniter.Code.Function.move_to_function_call(zipper, :use, 2, fn zipper ->
             with {:ok, arg_zipper} <- Igniter.Code.Function.move_to_nth_argument(zipper, 0),
                  true <- Igniter.Code.Module.module?(arg_zipper) do
               Igniter.Code.Function.argument_equals?(zipper, 1, :router)
             else
               _ -> false
             end
           end) do
      Igniter.Code.Module.move_to_use(zipper, Phoenix.Router)
    end
  end

  @doc """
  Checks if a module is a valid web module.

  A web module is defined as:
  - Only one level of namespace deep (e.g., `FooWeb` not `Foo.BarWeb`)
  - Ends with `Web`

  Accepts both atoms and strings.
  """
  @spec web_module?(module() | String.t()) :: boolean()
  def web_module?(module) do
    # Convert string to proper module atom if needed
    module_atom =
      case module do
        binary when is_binary(binary) -> Igniter.Project.Module.parse(binary)
        atom -> atom
      end

    case Module.split(module_atom) do
      [single_part] -> String.ends_with?(single_part, "Web")
      _ -> false
    end
  rescue
    _ -> false
  end

  defp move_to_pipeline_location(igniter, zipper) do
    with {:pipeline, :error} <-
           {:pipeline,
            Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, :pipeline, 2)},
         :error <-
           Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, :scope, [2, 3, 4]) do
      case move_to_router_use(igniter, zipper) do
        {:ok, zipper} -> {:ok, zipper, :after}
        :error -> :error
      end
    else
      {:pipeline, {:ok, zipper}} ->
        {:ok, zipper, :before}

      {:ok, zipper} ->
        {:ok, zipper, :before}
    end
  end

  defp move_to_scope_location(igniter, zipper, opts) do
    with {:placement, :before} <- {:placement, opts[:placement]},
         :error <-
           Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, :scope, [2, 3, 4]),
         {:pipeline, :error} <- {:pipeline, last_pipeline(zipper)} do
      case move_to_router_use(igniter, zipper) do
        {:ok, zipper} -> {:ok, zipper, :after}
        :error -> :error
      end
    else
      {:ok, zipper} ->
        {:ok, zipper, :before}

      {:placement, :after} ->
        {:ok, zipper, :after}

      {:pipeline, {:ok, zipper}} ->
        {:ok, zipper, :after}
    end
  end

  defp last_pipeline(zipper) do
    case Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, :pipeline, 2) do
      {:ok, zipper} ->
        with zipper when not is_nil(zipper) <- Sourceror.Zipper.right(zipper),
             {:ok, zipper} <- last_pipeline(zipper) do
          {:ok, zipper}
        else
          _ ->
            {:ok, zipper}
        end

      :error ->
        :error
    end
  end

  defp using_a_webbish_module?(zipper) do
    case Igniter.Code.Function.move_to_nth_argument(zipper, 0) do
      {:ok, zipper} ->
        Igniter.Code.Module.module_matching?(zipper, &String.ends_with?(to_string(&1), "Web"))

      :error ->
        false
    end
  end

  # We can do all kinds of things better here
  # for example, we can handle nested scopes, etc.
  defp move_to_matching_scope(zipper, route, opts) do
    call =
      if is_nil(opts[:arg2]) do
        zipper
        |> Igniter.Code.Function.move_to_function_call_in_current_scope(:scope, [2], fn call ->
          Igniter.Code.Function.argument_equals?(call, 0, route)
        end)
      else
        Igniter.Code.Function.move_to_function_call_in_current_scope(
          zipper,
          :scope,
          3,
          fn call ->
            Igniter.Code.Function.argument_equals?(call, 0, route) and
              Igniter.Code.Function.argument_equals?(call, 1, opts[:arg2])
          end
        )
      end

    case call do
      {:ok, zipper} ->
        with {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper),
             true <- contains_pipe_through?(zipper, opts) do
          {:ok, zipper}
        else
          _ ->
            :error
        end

      :error ->
        :error
    end
  end

  defp contains_pipe_through?(zipper, opts) do
    case List.wrap(opts[:with_pipelines]) do
      [] ->
        true

      pipelines ->
        Enum.all?(pipelines, fn pipeline ->
          zipper
          |> Igniter.Code.Function.move_to_function_call_in_current_scope(
            :pipe_through,
            1,
            fn zipper ->
              with {:ok, zipper} <- Igniter.Code.Function.move_to_nth_argument(zipper, 0),
                   {:is_list?, _zipper, true} <-
                     {:is_list?, zipper, Igniter.Code.List.list?(zipper)},
                   {:ok, _} <-
                     Igniter.Code.List.move_to_list_item(
                       zipper,
                       &Igniter.Code.Common.nodes_equal?(&1, pipeline)
                     ) do
                true
              else
                {:is_list?, zipper, false} ->
                  Igniter.Code.Common.nodes_equal?(zipper, pipeline)

                _ ->
                  false
              end
            end
          )
          |> case do
            {:ok, _} -> true
            :error -> false
          end
        end)
    end
  end
end
