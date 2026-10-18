# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Actions.RelatedAuthorizationTemplatesTest do
  @moduledoc """
  A relationship's filter is trusted before its related query has a context, so a calculation it
  refers to that reads the context or the actor keeps its templates, for the related query to fill.
  """
  use ExUnit.Case, async: true

  alias Ash.Actions.Read.RelatedAuthorization
  alias Ash.Query.{Calculation, Ref}
  alias Ash.Query.Parent, as: ParentExpr

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule Child do
    @moduledoc false
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :value, :integer, public?: true
    end

    actions do
      default_accept :*
      defaults [:read, create: :*]
    end
  end

  defmodule Parent do
    @moduledoc false
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :base, :integer, public?: true
    end

    actions do
      default_accept :*
      defaults [:read, create: :*]
    end

    calculations do
      calculate :picked, :integer, expr(base + ^context([:shared, :pick]))
      calculate :doubled, :integer, expr(base * 2)
    end

    relationships do
      has_many :picked_children, Child do
        no_attributes? true
        filter expr(value == parent(picked))
      end

      has_many :doubled_children, Child do
        no_attributes? true
        filter expr(value == parent(doubled))
      end
    end
  end

  defp parent_calculation(relationship) do
    relationship = Ash.Resource.Info.relationship(Parent, relationship)

    Child
    |> RelatedAuthorization.trusted_filter(relationship.filter, [Parent])
    |> Ash.Filter.find(&match?(%ParentExpr{}, &1))
    |> then(fn %ParentExpr{expr: %Ref{attribute: %Calculation{} = calculation}} ->
      calculation
    end)
  end

  test "a parent calculation reading the context keeps its template for the related query" do
    calculation = parent_calculation(:picked_children)

    assert Ash.Expr.template_references_context?(calculation.opts[:expr])
    refute calculation.authorize?
  end

  test "a parent calculation reading only fields is expanded" do
    calculation = parent_calculation(:doubled_children)

    refute Ash.Expr.template_references_context?(calculation.opts[:expr])
    refute calculation.authorize?
  end

  test "loading the relationship reads the context of the load" do
    Ash.create!(Child, %{value: 11})
    Ash.create!(Child, %{value: 12})
    parent = Ash.create!(Parent, %{base: 10})

    loaded = Ash.load!(parent, :picked_children, context: %{shared: %{pick: 1}})
    assert [%{value: 11}] = loaded.picked_children
  end
end
