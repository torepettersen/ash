defmodule Mix.Tasks.Ash.Patch.Extend do
  @moduledoc """
  Adds an extension or extensions to the domain/resource

  For example: `mix ash.patch.extend My.Domain.Resource Ash.Policy.Authorizer`
  """
  @shortdoc "Adds an extension or extensions to the given domain/resource"
  require Igniter.Code.Common
  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def igniter(igniter, [subject, extensions | argv]) do
    opts =
      [
        subjects: subject,
        extensions: extensions
      ]
      |> Ash.Igniter.csv_option(:extensions)
      |> Ash.Igniter.csv_option(:subjects)

    extensions = opts[:extensions]

    Enum.reduce(opts[:subjects], igniter, fn subject, igniter ->
      subject = Igniter.Code.Module.parse(subject)

      case Igniter.Code.Module.find_module(igniter, subject) do
        {:error, igniter} ->
          Igniter.add_issue(igniter, "Could not find module to extend: #{subject}")

        {:ok, {igniter, source, zipper}} ->
          case kind_of_thing(zipper) do
            {:ok, kind_of_thing} ->
              {igniter, patchers, _install} =
                Enum.reduce(extensions, {igniter, [], []}, fn extension,
                                                              {igniter, patchers, install} ->
                  case patcher(kind_of_thing, subject, extension, source.path, argv) do
                    {fun, new_install} when is_function(fun, 1) ->
                      {igniter, [fun | patchers], install ++ new_install}

                    {:error, error} ->
                      {Igniter.add_issue(igniter, error), patchers, install}
                  end
                end)

              Enum.reduce(patchers, igniter, fn patcher, igniter ->
                patcher.(igniter)
              end)

            :error ->
              Igniter.add_issue(
                igniter,
                "Could not determine whether #{subject} is an `Ash.Resource` or an `Ash.Domain`."
              )
          end
      end
    end)
  end

  defp kind_of_thing(zipper) do
    case Igniter.Code.Common.move_to_do_block(zipper) do
      {:ok, zipper} ->
        with {_, :error} <-
               {Ash.Resource, Igniter.Code.Module.move_to_using(zipper, Ash.Resource)},
             {_, :error} <-
               {Ash.Domain, Igniter.Code.Module.move_to_using(zipper, Ash.Domain)} do
          :error
        else
          {kind_of_thing, {:ok, _}} ->
            {:ok, kind_of_thing}
        end

      _ ->
        :error
    end
  end

  defp patcher(kind_of_thing, module, extension, path, argv) do
    original_request = extension

    {install, extension} =
      case {kind_of_thing, String.trim_leading(String.downcase(extension), "ash_"), extension} do
        {Ash.Resource, "postgres", _} ->
          {[:ash_postgres], AshPostgres.DataLayer}

        {Ash.Resource, "sqlite", _} ->
          {[:ash_sqlite], AshMysql.DataLayer}

        {Ash.Resource, "mysql", _} ->
          {[:mysql], AshPostgres.DataLayer}

        {Ash.Resource, "ets", _} ->
          {[], Ash.DataLayer.Ets}

        {Ash.Resource, "mnesia", _} ->
          {[], Ash.DataLayer.Mnesia}

        {Ash.Resource, "embedded", _} ->
          {[], &embedded_patcher(&1, module)}

        {Ash.Resource, "json_api", _} ->
          {[:ash_json_api], AshJsonApi.Resource}

        {Ash.Resource, "graphql", _} ->
          {[:ash_graphql], AshGraphql.Resource}

        {Ash.Domain, "json_api", _} ->
          {[:ash_json_api], AshJsonApi.Domain}

        {Ash.Domain, "graphql", _} ->
          {[:ash_graphql], AshGraphql.Domain}

        {_kind_of_thing, _, extension} ->
          {[], extension}
      end

    if is_function(extension) do
      {extension, install}
    else
      Module.concat([extension])

      if Code.ensure_loaded?(extension) do
        fun =
          if function_exported?(extension, :install, 5) do
            fn igniter ->
              extension.install(igniter, module, kind_of_thing, path, argv)
              |> simple_add_extension(kind_of_thing, module, extension)
            end
          else
            &simple_add_extension(&1, kind_of_thing, module, extension)
          end

        {fun, install}
      else
        extensions = Enum.map(Ash.Mix.Tasks.Helpers.extensions!([]), &inspect/1)

        short_codes = [
          "json_api",
          "postgres",
          "graphql",
          "mysql",
          "sqlite",
          "ets",
          "mnesia",
          "embedded"
        ]

        installable =
          short_codes
          |> Enum.concat(extensions)
          |> Enum.map_join("\n", &" * #{&1}")

        {:error,
         """
         Could not find extension #{original_request}.

         Possible values for extensions

         #{installable}
         """}
      end
    end
  end

  defp embedded_patcher(igniter, resource) do
    domain =
      resource
      |> Module.split()
      |> :lists.droplast()
      |> Module.concat()

    igniter
    |> remove_domain_option(resource)
    |> Spark.Igniter.add_extension(resource, Ash.Resource, :data_layer, :embedded, true)
    |> Ash.Domain.Igniter.remove_resource_reference(domain, resource)
    |> Spark.Igniter.update_dsl(
      resource,
      [{:section, :actions}, {:option, :defaults}],
      [:read, :destroy, create: :*, update: :*],
      fn x -> {:ok, x} end
    )
  end

  defp remove_domain_option(igniter, module) do
    Igniter.Code.Module.find_and_update_module!(igniter, module, fn zipper ->
      with {:ok, zipper} <- Igniter.Code.Module.move_to_use(zipper, Ash.Resource),
           {:ok, zipper} <-
             Igniter.Code.Function.update_nth_argument(zipper, 1, fn values_zipper ->
               Igniter.Code.Keyword.remove_keyword_key(values_zipper, :domain)
             end) do
        Igniter.Util.Debug.puts_code_at_node(zipper)
        {:ok, zipper}
      else
        _ ->
          {:ok, zipper}
      end
    end)
  end

  defp simple_add_extension(igniter, Ash.Resource, module, extension) do
    cond do
      Spark.implements_behaviour?(extension, Ash.DataLayer) ->
        Spark.Igniter.add_extension(igniter, module, Ash.Resource, :data_layer, extension, true)

      Spark.implements_behaviour?(extension, Ash.Notifier) ->
        Spark.Igniter.add_extension(igniter, module, Ash.Resource, :notifiers, extension)

      Spark.implements_behaviour?(extension, Ash.Authorizer) ->
        Spark.Igniter.add_extension(igniter, module, Ash.Resource, :authorizers, extension)

      true ->
        igniter
    end
  end

  defp simple_add_extension(igniter, type, module, extension) do
    Spark.Igniter.add_extension(igniter, module, type, :extensions, extension)
  end
end
