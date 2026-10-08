# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Policy.AtomicRefValidationTest do
  @moduledoc false
  use ExUnit.Case, async: true

  require Ash.Expr
  require Ash.Query

  defmodule Domain do
    use Ash.Domain

    resources do
      allow_unregistered? true
    end
  end

  defmodule Membership do
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key :id
      attribute :user_id, :uuid, public?: true
      attribute :team_id, :uuid, public?: true
    end

    actions do
      default_accept :*
      defaults [:read, create: :*]
    end
  end

  defmodule Document do
    use Ash.Resource,
      domain: Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key :id
      attribute :team_id, :uuid, public?: true
      attribute :locked?, :boolean, public?: true, default: false
    end

    actions do
      default_accept :*
      defaults [:read, create: :*]

      update :move do
        accept [:team_id]

        validate attribute_does_not_equal(:locked?, true) do
          message "is locked"
        end
      end
    end

    policies do
      policy action_type([:read, :create]) do
        authorize_if always()
      end

      policy action(:move) do
        authorize_if expr(
                       exists(
                         Membership,
                         user_id == ^actor(:id) and team_id == ^atomic_ref(:team_id)
                       )
                     )
      end
    end
  end

  setup do
    actor = %{id: Ash.UUID.generate()}
    team_id = Ash.UUID.generate()

    Membership
    |> Ash.Changeset.for_create(:create, %{user_id: actor.id, team_id: team_id})
    |> Ash.create!()

    %{actor: actor, team_id: team_id}
  end

  defp document(attrs) do
    Document
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!()
  end

  defp move(document, team_id, actor) do
    Document
    |> Ash.Query.filter(id == ^document.id)
    |> Ash.bulk_update(:move, %{},
      atomic_update: %{team_id: Ash.Expr.expr(type(^team_id, :uuid))},
      strategy: :atomic,
      actor: actor,
      authorize?: true,
      return_records?: true,
      return_errors?: true
    )
  end

  test "a policy reads the new value without the atomic validations folded into it",
       %{actor: actor, team_id: team_id} do
    locked = document(%{locked?: true})

    changeset =
      Ash.Changeset.fully_atomic_changeset(Document, :move, %{},
        actor: actor,
        atomic_update: [team_id: Ash.Expr.expr(type(^team_id, :uuid))]
      )

    # The update writes the new team, or raises the validation.
    assert inspect(changeset.atomics[:team_id]) =~ "is locked"

    assert {:ok, true, _changeset, %Ash.Query{filter: filter}} =
             Ash.can(changeset, actor,
               atomic_changeset: changeset,
               base_query: Ash.Query.filter(Document, id == ^locked.id),
               filter_with: :filter,
               alter_source?: true,
               run_queries?: false,
               return_forbidden_error?: true,
               maybe_is: false,
               pre_flight?: false,
               no_check?: true
             )

    # The policy compares only the team: a data layer may evaluate a filter's error branch ahead
    # of time, as Postgres does while planning, and raise it for rows the update would write.
    assert inspect(filter) =~ team_id
    refute inspect(filter) =~ "is locked"
  end

  test "the update still raises the validation for a row the policy lets through",
       %{actor: actor, team_id: team_id} do
    assert %Ash.BulkResult{status: :error, errors: [%Ash.Error.Invalid{} = error]} =
             move(document(%{locked?: true}), team_id, actor)

    assert Exception.message(error) =~ "is locked"
  end

  test "the policy leaves out a row moving to a team the actor doesn't belong to", %{actor: actor} do
    assert %Ash.BulkResult{status: :success, records: []} =
             move(document(%{}), Ash.UUID.generate(), actor)
  end

  test "the update writes a row that passes both", %{actor: actor, team_id: team_id} do
    assert %Ash.BulkResult{status: :success, records: [%{team_id: ^team_id}]} =
             move(document(%{}), team_id, actor)
  end
end
