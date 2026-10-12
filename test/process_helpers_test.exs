# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.ProcessHelpersTest do
  @moduledoc false
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> Application.delete_env(:ash, :transfer_process_keys) end)
  end

  test "the processes Ash starts get the process dictionary keys the config lists" do
    Application.put_env(:ash, :transfer_process_keys, [:ash_test_locale])
    Process.put(:ash_test_locale, "es")
    Process.put(:ash_test_unlisted, "kept here")

    task =
      Ash.ProcessHelpers.async(
        fn -> {Process.get(:ash_test_locale), Process.get(:ash_test_unlisted)} end,
        []
      )

    assert Task.await(task) == {"es", nil}
  end

  test "without the config, no process dictionary key is carried" do
    Process.put(:ash_test_locale, "es")

    task = Ash.ProcessHelpers.async(fn -> Process.get(:ash_test_locale) end, [])

    assert Task.await(task) == nil
  end
end
