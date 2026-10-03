# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Actions.Helpers.Identity do
  @moduledoc false

  alias Ash.Changeset
  alias Ash.Resource.Info

  def validate(changesets, []), do: changesets

  def validate(changesets, identities) do
    # Group by the same read context used by single-record identity checks, then restore the
    # caller's ordering from each changeset's position.
    changesets
    |> Enum.with_index()
    |> Enum.group_by(fn {changeset, _index} ->
      {changeset.resource, changeset.tenant, changeset.as_of, changeset.context[:private]}
    end)
    |> Enum.flat_map(fn {_context, indexed} ->
      {group, indices} = Enum.unzip(indexed)

      group
      |> validate_group(identities)
      |> Enum.zip(indices)
    end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp validate_group([first | _] = changesets, identities) do
    # Each identity's facts about each changeset are worked out once: nil where it does not apply,
    # else the key values it is checked on.
    checks =
      Enum.map(identities, fn {identity, domain} ->
        facts = Enum.map(changesets, &facts(&1, identity))

        %{
          identity: identity,
          attributes: Enum.map(identity.keys, &Info.attribute(first.resource, &1)),
          facts: List.to_tuple(facts),
          existing:
            for({changeset, fact} <- Enum.zip(changesets, facts), fact, do: changeset)
            |> conflicts(identity, domain)
        }
      end)

    {changesets, _accepted} =
      changesets
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {changeset, index}, accepted ->
        validated =
          Enum.reduce(checks, changeset, fn check, validated ->
            check_identity(validated, elem(check.facts, index), check, accepted)
          end)

        # An input refused by another identity cannot reserve keys against later inputs.
        {validated, if(validated.valid?, do: [index | accepted], else: accepted)}
      end)

    changesets
  end

  defp check_identity(changeset, nil, _check, _accepted), do: changeset

  defp check_identity(changeset, _fact, %{existing: {:error, error}}, _accepted),
    do: Changeset.add_error(changeset, error)

  defp check_identity(changeset, fact, %{existing: {:ok, records}} = check, accepted) do
    siblings =
      for index <- accepted,
          fact.against_siblings?,
          %{in_where?: true, values: values} <- [elem(check.facts, index)],
          do: values

    if Enum.any?(siblings ++ records, &same_values?(fact.values, &1, check.attributes)) do
      Changeset.add_error(
        changeset,
        Ash.Error.Changes.InvalidChanges.exception(
          fields: check.identity.field_names || check.identity.keys,
          message: check.identity.message || "has already been taken"
        )
      )
    else
      changeset
    end
  end

  defp facts(%{valid?: false}, _identity), do: nil

  defp facts(%{context: %{private: %{upsert?: true, upsert_identity: name}}}, %{name: name}),
    do: nil

  defp facts(changeset, identity) do
    if Enum.any?(identity.keys, &Info.calculation(changeset.resource, &1)) do
      raise ArgumentError, "Cannot pre or eager check an identity based on calculated fields."
    end

    values = Map.new(identity.keys, &{&1, Changeset.get_attribute(changeset, &1)})

    in_where? =
      (changeset.action_type == :create ||
         Enum.any?(identity.keys, &Changeset.changing_attribute?(changeset, &1))) &&
        !(identity.nils_distinct? && Enum.any?(Map.values(values), &is_nil/1)) &&
        matches_where?(changeset, identity.where)

    if in_where? != false do
      %{
        values: values,
        in_where?: in_where?,
        against_siblings?:
          in_where? == true && !Info.temporal_attribute(changeset.resource) &&
            changeset.atomics == [] && changeset.create_atomics == []
      }
    end
  end

  defp matches_where?(_changeset, nil), do: true

  defp matches_where?(changeset, expression) do
    {:ok, record} = Changeset.apply_attributes(changeset, force?: true)

    case Ash.Expr.eval(expression,
           record: record,
           resource: changeset.resource,
           unknown_on_unknown_refs?: true
         ) do
      {:ok, value} when value in [false, nil] -> false
      {:ok, true} -> true
      _unknown -> :unknown
    end
  end

  defp conflicts([], _identity, _domain), do: {:ok, []}

  defp conflicts([first | _] = changesets, identity, domain) do
    tenant =
      if identity.all_tenants? do
        if !Info.multitenancy_global?(first.resource) do
          raise ArgumentError,
                "Cannot pre or eager check an identity that has `all_tenants?: true` unless the resource supports global multitenancy."
        end

        nil
      else
        first.tenant
      end

    filters =
      Enum.map(changesets, fn changeset ->
        Enum.map(identity.keys, fn key ->
          case Changeset.get_attribute(changeset, key) do
            nil -> {key, is_nil: true}
            value -> {key, value}
          end
        end)
      end)
      |> Enum.uniq()

    first.resource
    |> Ash.Query.for_read(Info.primary_action(first.resource, :read).name, %{},
      tenant: tenant,
      actor: first.context[:private][:actor],
      authorize?: first.context[:private][:authorize?],
      tracer: first.context[:private][:tracer],
      as_of: first.as_of,
      domain: domain
    )
    |> Ash.Query.do_filter(or: filters)
    |> Ash.Query.do_filter(identity.where)
    |> Ash.Query.select(identity.keys)
    |> Ash.Query.set_context(%{private: %{internal?: true}})
    |> Ash.read(authorize?: false, page: false)
  end

  # `other` is a sibling's key values or a stored record, both read by key.
  defp same_values?(values, other, attributes) do
    Enum.all?(attributes, fn attribute ->
      case {Map.fetch!(values, attribute.name), Map.get(other, attribute.name)} do
        {nil, right} -> is_nil(right)
        {_left, nil} -> false
        {left, right} -> Ash.Type.equal?(attribute.type, left, right, attribute.constraints)
      end
    end)
  end
end
