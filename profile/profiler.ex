defmodule Profiler do
  import Poison.Parser

  data_dir = Path.expand(Path.join(__DIR__, "../bench/data"))

  data = for path <- Path.wildcard("#{data_dir}/*.json"), into: %{} do
    key = path
      |> Path.basename(".json")
      |> String.replace(~r/-+/, "_")
      |> String.to_atom
    value = File.read!(path)
    {key, value}
  end

  keys = Map.keys(data)

  def run() do
    unquote(Macro.escape(keys)) |> Enum.map(&run/1)
  end

  for key <- keys do
    def run(unquote(key)) do
      get_data(unquote(key)) |> parse!()
    end
  end

  for {key, value} <- data do
    defp get_data(unquote(key)) do
      unquote(value)
    end
  end
end
