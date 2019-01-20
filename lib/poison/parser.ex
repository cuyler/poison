defmodule Poison.MissingDependencyError do
  @type t :: %__MODULE__{name: String.t()}

  defexception name: nil

  def message(%{name: name}) do
    "missing optional dependency: #{name}"
  end
end

defmodule Poison.ParseError do
  @type t :: %__MODULE__{pos: non_neg_integer, value: String.t()}

  alias Code.Identifier

  defexception pos: 0, value: nil

  def message(%{value: "", pos: pos}) do
    "unexpected end of input at position #{pos}"
  end

  def message(%{value: <<token::utf8>>, pos: pos}) do
    "unexpected token at position #{pos}: #{escape(token)}"
  end

  def message(%{value: value, pos: pos}) when is_binary(value) do
    start = max(0, pos - String.length(value))
    "cannot parse value at position #{start}: #{inspect(value)}"
  end

  def message(%{value: value}) do
    "unsupported value: #{inspect(value)}"
  end

  defp escape(token) do
    {value, _} = Identifier.escape(<<token::utf8>>, ?\\)
    value
  end
end

defmodule Poison.Parser do
  @moduledoc """
  An RFC 7159 and ECMA 404 conforming JSON parser.

  See: https://tools.ietf.org/html/rfc7159
  See: http://www.ecma-international.org/publications/files/ECMA-ST/ECMA-404.pdf
  """

  # @compile :inline
  @compile :inline_list_funcs
  # @compile {:inline_size, 150}
  # @compile {:inline_effort, 500}
  # @compile {:inline_unroll, 3}

  # if Application.get_env(:poison, :native) do
  #   @compile [:native, {:hipe, [:o3]}]
  # end

  use Bitwise

  alias Poison.ParseError

  @type t :: nil | true | false | list | float | integer | String.t() | map

  defmacrop stacktrace do
    if Version.compare(System.version(), "1.7.0") != :lt do
      quote do: __STACKTRACE__
    else
      quote do: System.stacktrace()
    end
  end

  defmacrop syntax_error(value, pos) do
    quote do
      case unquote(value) do
        <<token::utf8>> <> _ ->
          raise ParseError, pos: unquote(pos), value: <<token::utf8>>

        _ ->
          raise ParseError, pos: unquote(pos), value: ""
      end
    end
  end

  @spec parse!(any(), any()) :: any()
  def parse!(value, options \\ %{})

  def parse!(iodata, options) when not is_binary(iodata) do
    iodata |> IO.iodata_to_binary() |> parse!(options)
  end

  def parse!(data, options) do
    keys = Map.get(options, :keys)
    decimal = Map.get(options, :decimal)
    {rest, pos} = skip_bom(data, 0)
    {value, pos, rest} = value(rest, pos, keys, decimal)

    case skip_whitespace(rest, pos) do
      {"", _pos} -> value
      {other, pos} -> syntax_error(other, pos)
    end
  rescue
    ArgumentError ->
      reraise ParseError, [value: data], stacktrace()
  end

  @compile {:inline, value: 4}

  defp value("", pos, _keys, _decimal) do
    syntax_error("", pos)
  end

  defp value("0" <> rest, pos, _keys, decimal) do
    number_frac(rest, pos + 1, decimal, {1, 0, 0})
  end

  for digit <- ?1..?9 do
    coef = digit - ?0

    defp value(<<unquote(digit)>> <> rest, pos, _keys, decimal) do
      number_int(rest, pos + 1, decimal, {1, unquote(coef), 0})
    end
  end

  defp value("\"" <> rest, pos, _keys, _decimal) do
    string_continue(rest, pos + 1)
  end

  defp value("{" <> rest, pos, keys, decimal) do
    {rest, pos} = skip_whitespace(rest, pos + 1)
    object_pairs(rest, pos, keys, decimal, [])
  end

  defp value("[" <> rest, pos, keys, decimal) do
    {rest, pos} = skip_whitespace(rest, pos + 1)
    array_values(rest, pos, keys, decimal, [])
  end

  defp value("null" <> rest, pos, _keys, _decimal) do
    {nil, pos + 4, rest}
  end

  defp value("true" <> rest, pos, _keys, _decimal) do
    {true, pos + 4, rest}
  end

  defp value("false" <> rest, pos, _keys, _decimal) do
    {false, pos + 5, rest}
  end

  defp value("-0" <> rest, pos, _keys, decimal) do
    number_frac(rest, pos + 2, decimal, {-1, 0, 0})
  end

  defp value("-" <> rest, pos, _keys, decimal) do
    number_int(rest, pos + 1, decimal, {-1, 0, 0})
  end

  defp value(other, pos, _keys, _decimal) do
    syntax_error(other, pos)
  end

  ## Objects

  @compile {:inline, object_pairs: 5}

  defp object_pairs("\"" <> rest, pos, keys, decimal, acc) do
    {name, pos, rest} = string_continue(rest, pos + 1)
    {rest, start} = skip_whitespace(rest, pos)

    {value, start, pos, rest} =
      case rest do
        ":" <> rest ->
          {rest, pos} = skip_whitespace(rest, start + 1)
          {value, pos, rest} = value(rest, pos, keys, decimal)
          {value, start, pos, rest}

        other ->
          syntax_error(other, pos)
      end

    acc = [{object_name(name, start, keys), value} | acc]

    {rest, pos} = skip_whitespace(rest, pos)

    case rest do
      "," <> rest ->
        {rest, pos} = skip_whitespace(rest, pos + 1)
        object_pairs(rest, pos, keys, decimal, acc)

      "}" <> rest ->
        {:maps.from_list(acc), pos + 1, rest}

      other ->
        syntax_error(other, pos)
    end
  end

  defp object_pairs("}" <> rest, pos, _keys, _decimal, []) do
    {:maps.new(), pos + 1, rest}
  end

  defp object_pairs(other, pos, _keys, _decimal, _acc) do
    syntax_error(other, pos)
  end

  @compile {:inline, object_name: 3}

  defp object_name(name, pos, :atoms!) do
    String.to_existing_atom(name)
  rescue
    ArgumentError ->
      reraise ParseError, [pos: pos, value: name], stacktrace()
  end

  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp object_name(name, _pos, :atoms), do: String.to_atom(name)
  defp object_name(name, _pos, _keys), do: name

  ## Arrays

  # @compile {:inline, array_values: 5}

  defp array_values("]" <> rest, pos, _keys, _decimal, _acc) do
    {[], pos + 1, rest}
  end

  defp array_values(string, pos, keys, decimal, acc) do
    array_values_continue(string, pos, keys, decimal, acc)
  end

  @compile {:inline, array_values_continue: 5}

  defp array_values_continue(string, pos, keys, decimal, acc) do
    {value, pos, rest} = value(string, pos, keys, decimal)

    acc = [value | acc]

    {rest, pos} = skip_whitespace(rest, pos)

    case rest do
      "," <> rest ->
        {rest, pos} = skip_whitespace(rest, pos + 1)
        array_values_continue(rest, pos, keys, decimal, acc)

      "]" <> rest ->
        {:lists.reverse(acc), pos + 1, rest}

      other ->
        syntax_error(other, pos)
    end
  end

  ## Numbers

  @compile {:inline, number_int: 4}

  for char <- '0123456789' do
    defp number_int(<<unquote(char)>> <> rest, pos, decimal, {sign, coef, exp}) do
      number_int(rest, pos + 1, decimal, {sign, coef * 10 + unquote(char - ?0), exp})
    end
  end

  defp number_int(_rest, pos, _decimal, {-1, 0, _exp}) do
    syntax_error("", pos)
  end

  defp number_int(rest, pos, decimal, {sign, coef, exp}) do
    number_frac(rest, pos, decimal, {sign, coef, exp})
  end

  @compile {:inline, number_frac: 4}

  defp number_frac("." <> rest, pos, decimal, value) do
    number_frac_continue(rest, pos + 1, decimal, value)
  end

  defp number_frac(rest, pos, decimal, acc) do
    number_exp(rest, pos, decimal, acc)
  end

  @compile {:inline, number_frac_continue: 4}

  for char <- '0123456789' do
    defp number_frac_continue(<<unquote(char)>> <> rest, pos, decimal, {sign, coef, exp}) do
      number_frac_continue(rest, pos + 1, decimal, {sign, coef * 10 + unquote(char - ?0), exp - 1})
    end
  end

  defp number_frac_continue(_rest, pos, _decimal, {_sign, _coef, 0}) do
    syntax_error("", pos)
  end

  defp number_frac_continue(rest, pos, decimal, value) do
    number_exp(rest, pos, decimal, value)
  end

  @compile {:inline, number_exp: 4}

  defp number_exp(<<e>> <> rest, pos, decimal, {sign, coef, exp})
       when e in 'eE' do
    {value, pos, rest} = number_exp_continue(rest, pos + 1)
    {number_complete(decimal, sign, coef, exp + value, pos), pos, rest}
  end

  defp number_exp(string, pos, decimal, {sign, coef, exp}) do
    {number_complete(decimal, sign, coef, exp, pos), pos, string}
  end

  @compile {:inline, number_exp_continue: 2}

  defp number_exp_continue("-" <> rest, pos) do
    {exp, pos, rest} = number_exp_digits(rest, pos + 1)
    {-exp, pos, rest}
  end

  defp number_exp_continue("+" <> rest, pos) do
    number_exp_digits(rest, pos + 1)
  end

  defp number_exp_continue(string, pos) do
    number_exp_digits(string, pos)
  end

  @compile {:inline, number_exp_digits: 2}

  defp number_exp_digits("", pos), do: syntax_error("", pos)

  defp number_exp_digits(<<string::binary>>, pos) do
    case number_digits(string, pos, 0) do
      {_exp, ^pos, _rest} ->
        syntax_error("", pos)

      {exp, pos, rest} ->
        {exp, pos, rest}
    end
  end

  @compile {:inline, number_digits: 3}

  for char <- '0123456789' do
    defp number_digits(<<unquote(char)>> <> rest, pos, acc) do
      number_digits(rest, pos + 1, acc * 10 + unquote(char - ?0))
    end
  end

  defp number_digits(rest, pos, acc) do
    {acc, pos, rest}
  end

  @compile {:inline, number_complete: 5}

  if Code.ensure_loaded?(Decimal) do
    defp number_complete(true, sign, coef, exp, _pos) do
      %Decimal{sign: sign, coef: coef, exp: exp}
    end
  else
    defp number_complete(true, _sign, _coef, _exp, _pos) do
      raise Poison.MissingDependencyError, name: "Decimal"
    end
  end

  defp number_complete(_decimal, sign, coef, 0, _pos) do
    sign * coef
  end

  defp number_complete(_decimal, sign, coef, exp, pos) do
    1.0 * sign * coef * pow10(exp)
  rescue
    ArithmeticError ->
      value = "#{sign * coef}e#{exp}"
      reraise ParseError, [pos: pos, value: value], stacktrace()
  end

  @compile {:inline, pow10: 1}

  Enum.reduce(0..16, 1, fn n, acc ->
    defp pow10(unquote(n)), do: unquote(acc)
    acc * 10
  end)

  defp pow10(n) when n > 16, do: pow10(16) * pow10(n - 16)
  defp pow10(n) when n < 0, do: 1 / pow10(-n)

  ## Strings

  @compile {:inline, string_continue: 2}

  defp string_continue(string, pos) do
    {acc, pos, skip} = string_continue(string, pos, 0, [], 0)
    {value, rest} = string_finalize(acc, string, skip, [])
    {value, pos, rest}
  end

  @compile {:inline, string_finalize: 4}

  @part 0
  @char 1

  defp string_finalize([@char, char | tail], string, skip, acc) do
    {chunk, rest} = string_chunk(tail, <<char::utf8>>)
    string_finalize(rest, string, skip, [acc | chunk])
  end

  defp string_finalize([@part, skip, len | tail], string, start, acc) do
    chunk = binary_part(string, skip, len)
    string_finalize(tail, string, start, [acc | chunk])
  end

  defp string_finalize([], <<string::binary>>, skip, acc) do
    <<_::binary-size(skip), rest::binary>> = string
    {IO.iodata_to_binary(acc), rest}
  end

  defp string_chunk([@char, char | tail], acc) do
    string_chunk(tail, <<acc, char::utf8>>)
  end

  defp string_chunk(rest, acc) do
    {acc, rest}
  end

  @compile {:inline, string_continue: 5}

  defp string_continue("\"" <> _rest, pos, skip, acc, len) do
    {[@part, skip, len | acc], pos + 1, skip + len + 1}
  end

  defp string_continue("\\" <> rest, pos, skip, acc, len) do
    string_escape(rest, pos + 1, skip + 1, [@part, skip, len | acc])
  end

  defp string_continue(<<char>> <> rest, pos, skip, acc, len) when char in 0x20..0x7F do
    string_continue(rest, pos + 1, skip, acc, len + 1)
  end

  # defp string_continue(<<codepoint::utf8, rest::binary>>, pos, skip, acc, len) when codepoint > 0x80 do
  #   string_continue(rest, pos + 1, skip, acc, len + string_codepoint_size(codepoint))
  # end

  # @compile {:inline, string_codepoint_size: 1}

  # defp string_codepoint_size(codepoint) when codepoint < 0x800, do: 2
  # defp string_codepoint_size(codepoint) when codepoint < 0x10000, do: 3
  # defp string_codepoint_size(codepoint), do: 4

  # defp string_continue(<<rest::binary>>, pos, skip, acc, len) do
  #   {pos, len} = string_chunk_size(rest, pos, len)
  #   {acc, pos, skip, len}
  # end

  # defp string_continue(other, pos, _skip, _acc, _len) do
  #   syntax_error(other, pos)
  # end

  # @compile {:inline, string_chunk_size: 3}

  # for char <- '"\\' do
  #   defp string_chunk_size(<<unquote(char), _rest::binary>>, pos, acc) do
  #     {pos, acc}
  #   end
  # end

  # defp string_chunk_size(<<char, rest::binary>>, pos, acc) when char in 0x20..0x7F do
  #   string_chunk_size(rest, pos + 1, acc + 1)
  # end

  # defp string_chunk_size(<<codepoint::utf8, rest::binary>>, pos, acc) when codepoint > 0x80 do
  #   string_chunk_size(rest, pos + 1, acc + byte_size(<<codepoint::utf8>>))
  # end

  # defp string_chunk_size(<<other::bits>>, pos, _acc) do
  #   syntax_error(other, pos)
  # end

  # # https://en.wikipedia.org/wiki/Letter_frequency#Relative_frequencies_of_letters_in_the_English_language
  # # http://www.viviancook.uk/Punctuation/PunctFigs.htm
  # letter_chars = 'etaoinshrdlcumwfgypbvkjxqzTAOISWCBPHFMDRELNGUVYJKQXZ'
  # punct_chars = ' _.,\'-?:!;()'
  # digit_chars = ?0..?9
  # misc_chars = 0x23..0x7F

  # ascii_chars = [letter_chars, punct_chars, digit_chars, misc_chars]
  #   |> Stream.concat()
  #   |> Enum.into(MapSet.new())
  #   |> MapSet.difference(terminating_chars)

  # for char <- ascii_chars do
  #   defp string_chunk_size(<<unquote(char), rest::binary>>, pos, acc) do
  #     string_chunk_size(rest, pos + 1, acc + 1)
  #   end
  # end

  # @compile {:inline, string_chunk_size: 3}

  # defp string_chunk_size(<<char, rest::binary>>, pos, acc) when char in 0x20..0x7F do
  #   string_chunk_size(rest, pos + 1, acc + 1)
  # end

  # defp string_chunk_size(<<codepoint::utf8>> <> rest, pos, acc) when codepoint > 0x80 do
  #   string_chunk_size(rest, pos + 1, acc + byte_size(<<codepoint::utf8>>))
  # end

  # defp string_chunk_size("", pos, _acc), do: {:error, pos, 0}

  # defp string_chunk_size(_other, pos, acc), do: {:error, pos, acc}

  # @compile {:inline, is_surrogate: 2}

  # defp is_surrogate(<<a1, a2, _::binary-size(2)>>, <<b1, b2, _::binary-size(2)>>) do
  #   a1 in 'dD' and a2 in 'dD' and b1 in '89abAB' and (b2 in ?c..?f or b2 in ?C..?F)
  # end

  # for a1 <- 'dD', b1 <- '89abAB', a2 <- 'dD', b2 <- 'cCdDeEfF' do
  #   x = <<a1, b1>>
  #   y = <<a2, b2>>

  #   defp is_surrogate(<<unquote(x), _::binary-size(2)>>, <<unquote(y), _::binary-size(2)>>) do
  #     true
  #   end
  # end

  # defp is_surrogate(_, _) do
  #   false
  # end

  hex_digits = [?0..?9, ?a..?f, ?A..?F] |> Enum.concat()

  defguardp is_hex(char) when char in unquote(hex_digits)

  @compile {:inline, string_escape: 4}

  for {seq, char} <- Enum.zip('"\\ntr/fb', '"\\\n\t\r/\f\b') do
    defp string_escape(<<unquote(seq)>> <> rest, pos, skip, acc) do
      string_continue(rest, pos + 1, skip + 1, [@char, unquote(char) | acc], 0)
    end
  end

  for a1 <- 'dD', b1 <- '89abAB', a2 <- 'dD', b2 <- 'cCdDeEfF' do
    v1 = List.to_integer([a1, b1], 16) <<< 8
    v2 = List.to_integer([a2, b2], 16) <<< 8

    defp string_escape(
           <<unquote("u#{a1}{b1}"), c1, d1, unquote("\\u#{a2}{b2}"), c2, d2>> <> rest,
           pos,
           skip,
           acc
         )
         when is_hex(c1) and is_hex(d1) and is_hex(c2) and is_hex(d2) do
      hi = unquote(v1) + (hex(c1) <<< 4) + hex(d1)
      lo = unquote(v2) + (hex(c2) <<< 4) + hex(d2)
      codepoint = 0x10000 + ((hi &&& 0x03FF) <<< 10) + (lo &&& 0x03FF)
      string_continue(rest, pos + 11, skip + 11, [@char, codepoint | acc], 0)
    end
  end

  defp string_escape(<<?u, a, b, c, d>> <> rest, pos, skip, acc)
       when is_hex(a) and is_hex(b) and is_hex(c) and is_hex(d) do
    codepoint = (hex(a) <<< 12) + (hex(b) <<< 8) + (hex(c) <<< 4) + hex(d)
    string_continue(rest, pos + 5, skip + 5, [@char, codepoint | acc], 0)
  end

  defp string_escape(other, pos, _skip, _acc), do: syntax_error(other, pos)

  @compile {:inline, hex: 1}

  for char <- hex_digits do
    value = String.to_integer(<<char>>, 16)

    defp hex(unquote(char)) do
      unquote(value)
    end
  end

  # @compile {:inline, get_codepoint: 2}

  # def get_codepoint(<<a::binary-size(2), b::binary-size(2)>>, pos) do
  #   hex(a) * 0x100 + hex(b)
  # rescue
  #   _ in [CaseClauseError, FunctionClauseError] ->
  #     value = "\\u#{a}#{b}"
  #     reraise ParseError, [pos: pos + 6, value: value], stacktrace()
  # end

  @compile {:inline, get_codepoint: 2}

  defp get_codepoint(seq, pos) do
    String.to_integer(seq, 16)
  rescue
    ArgumentError ->
      value = "\\u#{seq}"
      reraise ParseError, [pos: pos + 6, value: value], stacktrace()
  end

  # defp string_escape_maybe_surrogate(seq1, seq2, rest, pos, left, acc) do
  #   c1 = get_codepoint(seq1, pos)
  #   c2 = get_codepoint(seq2, pos)
  #   string_continue(rest, pos + 5, left - 5, [acc | <<c1::utf8, c2::utf8>>])
  # end

  # hex_digits = '0123456789abcdefABCDEF'
  # for a <- hex_digits, b <- hex_digits, c <- hex_digits, d <- hex_digits do
  #   seq = <<a, b, c, d>>
  #   codepoint = String.to_integer(seq, 16)

  #   defp get_codepoint(<<unquote(seq)>>, _pos) do
  #     unquote(codepoint)
  #   end
  # end

  ## Characters

  # @compile {:inline, get_codepoint: 2}

  # defp get_codepoint(seq, pos) do
  #   String.to_integer(seq, 16)
  # rescue
  #   ArgumentError ->
  #     value = "\\u" <> seq
  #     reraise ParseError, [pos: pos + 6, value: value], stacktrace()
  # end

  @compile {:inline, get_surrogate_pair: 3}

  defp get_surrogate_pair(<<seq1::binary>>, <<seq2::binary>>, pos) do
    hi = get_codepoint(seq1, pos)
    lo = get_codepoint(seq2, pos)
    0x10000 + ((hi &&& 0x03FF) <<< 10) + (lo &&& 0x03FF)
  rescue
    ParseError ->
      value = "\\u#{seq1}\\u#{seq2}"
      reraise ParseError, [pos: pos + 12, value: value], stacktrace()
  end

  ## Whitespace

  @compile {:inline, skip_bom: 2}

  # https://tools.ietf.org/html/rfc7159#section-8.1
  # https://en.wikipedia.org/wiki/Byte_order_mark#UTF-8
  defp skip_bom(<<0xEF, 0xBB, 0xBF>> <> rest, pos) do
    skip_whitespace(rest, pos)
  end

  defp skip_bom(rest, pos) do
    skip_whitespace(rest, pos)
  end

  @compile {:inline, skip_whitespace: 2}

  defp skip_whitespace("    " <> rest, pos) do
    skip_whitespace(rest, pos + 4)
  end

  for char <- '\s\n\t\r' do
    defp skip_whitespace(<<unquote(char)>> <> rest, pos) do
      skip_whitespace(rest, pos + 1)
    end
  end

  defp skip_whitespace(rest, pos) do
    {rest, pos}
  end
end
