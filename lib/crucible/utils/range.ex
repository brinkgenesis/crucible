defmodule Crucible.Utils.Range do
  @moduledoc """
  Reusable range, clamp, and pagination utilities.

  All functions are pure and deterministic — safe to call from LiveView
  callbacks, background jobs, and concurrent request handlers alike.
  """

  @doc """
  Returns an inclusive list of numbers from `start` to `stop` in `step` increments.

  Returns an empty list when `step` is zero, or when the direction implied by
  `step` is inconsistent with the `start`/`stop` relationship.

  ## Examples

      iex> Crucible.Utils.Range.range(1, 5)
      [1, 2, 3, 4, 5]

      iex> Crucible.Utils.Range.range(0, 10, 2)
      [0, 2, 4, 6, 8, 10]

      iex> Crucible.Utils.Range.range(5, 1, -1)
      [5, 4, 3, 2, 1]
  """
  @spec range(number(), number(), number()) :: [number()]
  def range(start, stop, step \\ 1)

  def range(_start, _stop, 0), do: []

  def range(start, stop, step) when is_number(start) and is_number(stop) and is_number(step) do
    cond do
      step > 0 and start > stop -> []
      step < 0 and start < stop -> []
      true -> do_range(start, stop, step, [])
    end
  end

  defp do_range(current, stop, step, acc) when step > 0 and current > stop,
    do: Enum.reverse(acc)

  defp do_range(current, stop, step, acc) when step < 0 and current < stop,
    do: Enum.reverse(acc)

  defp do_range(current, stop, step, acc),
    do: do_range(current + step, stop, step, [current | acc])

  @doc """
  Constrains `value` to the closed interval `[min, max]`.

  ## Examples

      iex> Crucible.Utils.Range.clamp(150.0, 0.0, 100.0)
      100.0

      iex> Crucible.Utils.Range.clamp(-5, 0, 100)
      0
  """
  @spec clamp(number(), number(), number()) :: number()
  def clamp(value, min, _max) when value < min, do: min
  def clamp(value, _min, max) when value > max, do: max
  def clamp(value, _min, _max), do: value

  @doc """
  Splits `total` items into pagination chunks of at most `chunk_size` each.

  Returns a list of `{offset, limit}` tuples suitable for use with database
  queries or in-memory slicing. Returns an empty list when either argument
  is not positive.

  ## Examples

      iex> Crucible.Utils.Range.chunk_range(55, 25)
      [{0, 25}, {25, 25}, {50, 5}]

      iex> Crucible.Utils.Range.chunk_range(0, 25)
      []
  """
  @spec chunk_range(non_neg_integer(), pos_integer()) :: [{non_neg_integer(), pos_integer()}]
  def chunk_range(total, _chunk_size) when total <= 0, do: []
  def chunk_range(_total, chunk_size) when chunk_size <= 0, do: []

  def chunk_range(total, chunk_size) do
    0
    |> Stream.iterate(&(&1 + chunk_size))
    |> Stream.take_while(&(&1 < total))
    |> Enum.map(&{&1, min(chunk_size, total - &1)})
  end
end
