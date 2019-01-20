# encode_jobs = %{
#   "Poison" => &Poison.encode!/1,
#   "Jason" => &Jason.encode!/1,
#   "JSX" => &JSX.encode!/1,
#   "Tiny" => &Tiny.encode!/1,
#   "jsone" => &:jsone.encode/1,
#   "jiffy" => &:jiffy.encode/1,
#   "JSON" => &JSON.encode!/1
# }

# encode_inputs = [
#   "GitHub",
#   "Giphy",
#   "GovTrack",
#   "Blockchain",
#   "Pokedex",
#   "JSON Generator",
#   "UTF-8 unescaped",
#   "Issue 90"
# ]

# Benchee.run(encode_jobs,
#   parallel: 4,
#   # warmup: 5,
#   # time: 30,
#   inputs:
#     for name <- encode_inputs, into: %{} do
#       name
#       |> read_data.()
#       |> Poison.decode!()
#       |> (&{name, &1}).()
#     end,
#   formatters: [
#     {Benchee.Formatters.Console, extended_statistics: true},
#     {Benchee.Formatters.HTML, extended_statistics: true},
#   ],
#   formatter_options: [
#     html: [
#       file: Path.expand("output/encode.html", __DIR__)
#     ]
#   ]
# )

defmodule Bench do
  alias Benchee.Formatters.{Console, HTML}

  # @compile [:native, {:hipe, [:o3]}]

  def run_decode() do
    Benchee.run(decode_jobs(),
      parallel: 8,
      warmup: 5,
      time: 10,
      memory_time: 5,
      inputs:
        for name <- decode_inputs(), into: %{} do
          name
          |> read_data()
          |> (&{name, &1}).()
        end,
      after_scenario: fn _ -> gc() end,
      formatters: [
        {Console, extended_statistics: true},
        {HTML, extended_statistics: true}
      ],
      formatter_options: [
        html: [
          file: Path.expand("output/decode.html", __DIR__)
        ]
      ]
    )
  end

  def run_encode() do
    Benchee.run(encode_jobs(),
      parallel: 8,
      warmup: 5,
      time: 10,
      memory_time: 5,
      inputs:
        for name <- encode_inputs(), into: %{} do
          name
          |> read_data()
          |> Poison.decode!()
          |> (&{name, &1}).()
        end,
      after_scenario: fn _ -> gc() end,
      formatters: [
        {Console, extended_statistics: true},
        {HTML, extended_statistics: true}
      ],
      formatter_options: [
        html: [
          file: Path.expand("output/encode.html", __DIR__)
        ]
      ]
    )
  end

  defp gc() do
    request_id = System.monotonic_time()
    :erlang.garbage_collect(self(), async: request_id)

    receive do
      {:garbage_collect, ^request_id, _} -> :ok
    end
  end

  defp read_data(name) do
    name
    |> String.downcase()
    |> String.replace(~r/([^\w]|-|_)+/, "-")
    |> String.trim("-")
    |> (&"data/#{&1}.json").()
    |> Path.expand(__DIR__)
    |> File.read!()
  end

  defp decode_jobs() do
    %{
      "Poison" => &Poison.Parser.parse!(&1, %{}),
      "Jason" => &Jason.decode!/1
      # "JSX" => &JSX.decode!(&1, [:strict]),
      # "Tiny" => &Tiny.decode!/1,
      # "jsone" => &:jsone.decode/1,
      # "jiffy" => &:jiffy.decode(&1, [:return_maps]),
      # "JSON" => &JSON.decode!/1
    }
  end

  defp encode_jobs() do
    %{
      "Poison" => &Poison.encode!/1,
      "Jason" => &Jason.encode!/1
      # "JSX" => &JSX.encode!/1,
      # "Tiny" => &Tiny.encode!/1,
      # "jsone" => &:jsone.encode/1,
      # "jiffy" => &:jiffy.encode/1,
      # "JSON" => &JSON.encode!/1
    }
  end

  defp decode_inputs() do
    [
      # "GitHub",
      # "Giphy",
      # "GovTrack",
      "Blockchain"
      # "Pokedex",
      # "JSON Generator",
      # "JSON Generator (Pretty)",
      # "UTF-8 escaped",
      # "UTF-8 unescaped",
      # "Issue 90"
    ]
  end

  defp encode_inputs() do
    decode_inputs() -- ["JSON Generator (Pretty)"]
  end
end

Bench.run_decode()
# Bench.run_encode()
