defmodule CrucibleWeb.Charts do
  @moduledoc """
  Reusable pure-SVG chart function components for LiveView dashboards.
  NERV tactical HUD aesthetic — no JavaScript dependencies.
  """
  use Phoenix.Component

  # ---------------------------------------------------------------------------
  # sparkline — simple polyline from a list of numbers
  # ---------------------------------------------------------------------------

  attr :data, :list, required: true
  attr :width, :integer, default: 200
  attr :height, :integer, default: 50
  attr :color, :string, default: "#ffa44c"
  attr :fill, :boolean, default: false
  attr :class, :string, default: ""

  def sparkline(assigns) do
    points = points_to_path(assigns.data, assigns.width, assigns.height)
    assigns = assign(assigns, :points, points)

    ~H"""
    <svg
      viewBox={"0 0 #{@width} #{@height}"}
      class={["w-full h-16", @class]}
      preserveAspectRatio="none"
    >
      <polyline
        :if={@points != ""}
        points={@points}
        fill="none"
        stroke={@color}
        stroke-width="1.5"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  # ---------------------------------------------------------------------------
  # area_chart — filled area chart with NERV HUD grid styling
  # ---------------------------------------------------------------------------

  attr :data, :list, required: true
  attr :width, :integer, default: 400
  attr :height, :integer, default: 180
  attr :color, :string, default: "#ffa44c"
  attr :grid_color, :string, default: "rgba(255, 164, 76, 0.08)"
  attr :label_color, :string, default: "rgba(255, 164, 76, 0.5)"
  attr :show_labels, :boolean, default: true
  attr :class, :string, default: ""
  attr :id, :string, default: "area-chart"

  def area_chart(assigns) do
    {points_str, polygon_str, max_val, label_step} =
      build_area_data(assigns.data, assigns.width, assigns.height)

    y_labels =
      if assigns.show_labels and max_val > 0 do
        steps = 4

        Enum.map(0..steps, fn i ->
          val = max_val / steps * i
          y = assigns.height - val / max_val * assigns.height
          %{y: Float.round(y, 1), label: format_axis_value(max_val / steps * i)}
        end)
      else
        []
      end

    x_labels =
      if assigns.show_labels do
        assigns.data
        |> Enum.with_index()
        |> Enum.take_every(label_step)
        |> Enum.map(fn {item, i} ->
          n = length(assigns.data)
          x = if n > 1, do: Float.round(i / (n - 1) * assigns.width, 1), else: 0.0
          %{x: x, label: item.label}
        end)
      else
        []
      end

    assigns =
      assign(assigns,
        points_str: points_str,
        polygon_str: polygon_str,
        y_labels: y_labels,
        x_labels: x_labels
      )

    ~H"""
    <svg viewBox={"0 0 #{@width + 50} #{@height + 30}"} class={["w-full", @class]}>
      <defs>
        <linearGradient id={"#{@id}-grad"} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color={@color} stop-opacity="0.3" />
          <stop offset="100%" stop-color={@color} stop-opacity="0.02" />
        </linearGradient>
      </defs>
      <g transform="translate(45, 0)">
        <!-- Grid lines -->
        <line
          :for={yl <- @y_labels}
          x1="0"
          y1={yl.y}
          x2={@width}
          y2={yl.y}
          stroke={@grid_color}
          stroke-width="1"
        />
        <!-- Y-axis labels -->
        <text
          :for={yl <- @y_labels}
          x="-8"
          y={yl.y + 4}
          text-anchor="end"
          font-size="9"
          font-family="JetBrains Mono, monospace"
          fill={@label_color}
        >
          {yl.label}
        </text>
        <!-- Area fill -->
        <polygon :if={@polygon_str != ""} points={@polygon_str} fill={"url(##{@id}-grad)"} />
        <!-- Line with glow -->
        <polyline
          :if={@points_str != ""}
          points={@points_str}
          fill="none"
          stroke={@color}
          stroke-width="2"
          stroke-linejoin="round"
          filter={"drop-shadow(0 0 4px #{@color})"}
        />
        <!-- X-axis labels -->
        <text
          :for={xl <- @x_labels}
          x={xl.x}
          y={@height + 18}
          text-anchor="middle"
          font-size="8"
          font-family="JetBrains Mono, monospace"
          fill={@label_color}
          text-transform="uppercase"
        >
          {xl.label}
        </text>
      </g>
    </svg>
    """
  end

  # ---------------------------------------------------------------------------
  # bar_chart — horizontal bar chart with NERV tactical styling
  # ---------------------------------------------------------------------------

  attr :data, :list, required: true
  attr :height, :integer, default: 200
  attr :bar_color, :string, default: "#ffa44c"
  attr :show_values, :boolean, default: true
  attr :class, :string, default: ""

  def bar_chart(assigns) do
    max_val = assigns.data |> Enum.map(& &1.value) |> Enum.max(fn -> 1 end)

    bar_h =
      if length(assigns.data) > 0,
        do: min(28, div(assigns.height, length(assigns.data))),
        else: 28

    bars =
      assigns.data
      |> Enum.with_index()
      |> Enum.map(fn {item, i} ->
        pct = if max_val > 0, do: item.value / max_val, else: 0

        %{
          label: item.label,
          value: item.value,
          y: i * bar_h,
          width: Float.round(pct * 280, 1),
          color: Map.get(item, :color, assigns.bar_color)
        }
      end)

    assigns = assign(assigns, bars: bars, bar_h: bar_h)

    ~H"""
    <svg viewBox={"0 0 400 #{length(@bars) * @bar_h + 4}"} class={["w-full", @class]}>
      <g :for={bar <- @bars}>
        <text
          x="0"
          y={bar.y + @bar_h * 0.6}
          font-size="9"
          font-family="JetBrains Mono, monospace"
          fill="rgba(255, 164, 76, 0.6)"
        >
          {bar.label}
        </text>
        <rect
          x="100"
          y={bar.y + 2}
          width={bar.width}
          height={@bar_h - 6}
          rx="0"
          fill={bar.color}
          opacity="0.85"
        />
        <text
          :if={@show_values}
          x={bar.width + 106}
          y={bar.y + @bar_h * 0.6}
          font-size="9"
          font-family="JetBrains Mono, monospace"
          fill="rgba(173, 170, 170, 0.7)"
        >
          {format_axis_value(bar.value)}
        </text>
      </g>
    </svg>
    """
  end

  # ---------------------------------------------------------------------------
  # donut_chart — ring chart with NERV styling
  # ---------------------------------------------------------------------------

  attr :data, :list, required: true
  attr :size, :integer, default: 150
  attr :thickness, :integer, default: 25
  attr :show_legend, :boolean, default: true
  attr :class, :string, default: ""

  def donut_chart(assigns) do
    total = assigns.data |> Enum.map(& &1.value) |> Enum.sum()
    r = (assigns.size - assigns.thickness) / 2
    circ = 2 * :math.pi() * r

    {segments, _} =
      Enum.map_reduce(assigns.data, 0, fn item, offset ->
        pct = if total > 0, do: item.value / total, else: 0
        len = pct * circ

        seg = %{
          dash: "#{Float.round(len, 2)} #{Float.round(circ - len, 2)}",
          offset: Float.round(-offset, 2),
          color: item.color,
          label: item.label,
          pct: Float.round(pct * 100, 1)
        }

        {seg, offset + len}
      end)

    cx = assigns.size / 2
    assigns = assign(assigns, segments: segments, r: r, circ: circ, cx: cx)

    ~H"""
    <div class={["flex items-center gap-4", @class]}>
      <svg width={@size} height={@size} viewBox={"0 0 #{@size} #{@size}"}>
        <circle
          :for={seg <- @segments}
          cx={@cx}
          cy={@cx}
          r={@r}
          fill="none"
          stroke={seg.color}
          stroke-width={@thickness}
          stroke-dasharray={seg.dash}
          stroke-dashoffset={seg.offset}
          transform={"rotate(-90 #{@cx} #{@cx})"}
        />
      </svg>
      <div :if={@show_legend} class="space-y-1">
        <div :for={seg <- @segments} class="flex items-center gap-2">
          <span class="w-2 h-2 inline-block" style={"background:#{seg.color}"} />
          <span class="text-[10px] font-label tracking-widest text-[#adaaaa]">{seg.label}</span>
          <span class="text-[10px] font-label font-bold text-white">{seg.pct}%</span>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @doc false
  def points_to_path(data, max_x, max_y) do
    n = length(data)
    if n < 2, do: "", else: do_points_to_path(data, n, max_x, max_y)
  end

  defp do_points_to_path(data, n, max_x, max_y) do
    max_val = Enum.max(data)
    max_val = if max_val == 0, do: 1, else: max_val

    data
    |> Enum.with_index()
    |> Enum.map(fn {val, i} ->
      x = Float.round(i / (n - 1) * max_x, 1)
      y = Float.round(max_y - val / max_val * max_y, 1)
      "#{x},#{y}"
    end)
    |> Enum.join(" ")
  end

  defp build_area_data(data, width, height) do
    n = length(data)

    if n < 1 do
      {"", "", 0, 1}
    else
      values = Enum.map(data, & &1.value)
      max_data_val = Enum.max(values)
      max_val = if max_data_val <= 0, do: 1.0, else: max_data_val * 1.15

      coords =
        data
        |> Enum.with_index()
        |> Enum.map(fn {item, i} ->
          x = if n > 1, do: Float.round(i / (n - 1) * width, 1), else: 0.0
          y = Float.round(height - item.value / max_val * height, 1)
          {x, y}
        end)

      points_str = Enum.map_join(coords, " ", fn {x, y} -> "#{x},#{y}" end)

      polygon_str =
        case coords do
          [{fx, _} | _] ->
            {lx, _} = List.last(coords)
            points_str <> " #{lx},#{height} #{fx},#{height}"

          _ ->
            ""
        end

      label_step = max(1, div(n, 8))
      {points_str, polygon_str, max_val, label_step}
    end
  end

  defp format_axis_value(val) when val >= 1_000_000, do: "#{Float.round(val / 1_000_000, 1)}M"
  defp format_axis_value(val) when val >= 1_000, do: "#{Float.round(val / 1_000, 1)}K"
  defp format_axis_value(val) when is_float(val), do: Float.round(val, 2) |> to_string()
  defp format_axis_value(val), do: to_string(val)
end
