# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Calculations.ExpressionLoadTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Ash.Expr

  alias Ash.Resource.Calculation.Expression

  defmodule Author do
    @moduledoc false
    use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id

      for field <- [:a, :b, :c, :d, :e, :f, :g, :h] do
        attribute field, :string, public?: true
      end
    end
  end

  defmodule Post do
    @moduledoc false
    use Ash.Resource, domain: Ash.Test.Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, public?: true
    end

    relationships do
      belongs_to :author, Author, public?: true
      belongs_to :editor, Author, public?: true
    end
  end

  @context %{actor: nil, tenant: nil, arguments: %{}, source_context: %{}}

  test "each field an expression reads through a relationship is loaded once" do
    expression =
      expr(
        author.a == "a" or author.b == "b" or author.c == "c" or author.d == "d" or
          editor.e == "e" or editor.f == "f" or author.g == "g" or editor.h == "h" or
          title == "title"
      )

    loads = Expression.load(Ash.Query.new(Post), [expr: expression], @context)

    assert length(loads) == 3
    assert Enum.sort(loads[:author]) == [:a, :b, :c, :d, :g]
    assert Enum.sort(loads[:editor]) == [:e, :f, :h]
    assert :title in loads
  end
end
