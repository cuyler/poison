defmodule Poison.ParseError do
  @type t :: %__MODULE__{pos: non_neg_integer, value: String.t()}

  alias Code.Identifier

  defexception pos: 0, value: nil

  def message(%{value: "", pos: pos}) do
    "Unexpected end of input at position #{pos}"
  end

  def message(%{value: <<token::utf8>>, pos: pos}) do
    "Unexpected token at position #{pos}: #{escape(token)}"
  end

  def message(%{value: value, pos: pos}) when is_binary(value) do
    start = max(0, pos - String.length(value))
    "Cannot parse value at position #{start}: #{inspect(value)}"
  end

  def message(%{value: value}) do
    "Unsupported value: #{inspect(value)}"
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

  @compile :inline
  @compile {:inline_size, 150}

  # if Application.get_env(:poison, :native) do
  @compile [:native, {:hipe, [:o3]}]
  # @compile [:native, {:hipe, [{:ls_order, :inorder}, :o3, :bitlevel_binaries, :icode_multret, :icode_ssa_struct_reuse, :rtl_ssapre, :use_callgraph]}]
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

  def parse!(iodata, options) do
    keys = Map.get(options, :keys)
    string = skip_bom(IO.iodata_to_binary(iodata))
    size = byte_size(string)
    {rest, pos} = skip_whitespace(string, 0)
    {value, pos, rest} = value(rest, size, pos, keys)

    case skip_whitespace(rest, pos) do
      {"", _pos} -> value
      {other, pos} -> syntax_error(other, pos)
    end
  rescue
    ArgumentError ->
      reraise ParseError, [value: iodata], stacktrace()
  end

  defp value("", _size, pos, _keys) do
    syntax_error("", pos)
  end

  defp value(string, size, pos, keys) do
    left = size - pos - 1
    case string do
      <<"\"", rest::binary-size(left)>> ->
        string_continue(rest, size, pos + 1, [])
      <<"{", rest::binary-size(left)>> ->
        {rest, pos} = skip_whitespace(rest, pos + 1)
        object_pairs(rest, size, pos, keys, [])
      <<"[", rest::binary-size(left)>> ->
        {rest, pos} = skip_whitespace(rest, pos + 1)
        array_values(rest, size, pos, keys, [])
      <<"n", rest::binary-size(left)>> ->
        left = left - 3
        case rest do
          <<"ull", rest::binary-size(left)>> ->
            {nil, pos + 4, rest}
          other ->
            syntax_error(other, pos + 1)
        end
      <<"t", rest::binary-size(left)>> ->
        left = left - 3
        case rest do
          <<"rue", rest::binary-size(left)>> ->
            {true, pos + 4, rest}
          other ->
            syntax_error(other, pos + 1)
        end
      <<"f", rest::binary-size(left)>> ->
        left = left - 4
        case rest do
          <<"alse", rest::binary-size(left)>> ->
            {false, pos + 5, rest}
          other ->
            syntax_error(other, pos + 1)
        end
      <<"-", rest::binary-size(left)>> ->
        number_int(rest, pos + 1, "-")
      <<"0", rest::binary-size(left)>> ->
        number_frac(rest, pos + 1, "0")
      <<"1", rest::binary-size(left)>> ->
        number_int(rest, pos + 1, "1")
      <<"2", rest::binary-size(left)>> ->
        number_int(rest, pos + 1, "2")
      <<"3", rest::binary-size(left)>> ->
        number_int(rest, pos + 1, "3")
      <<"4", rest::binary-size(left)>> ->
        number_int(rest, pos + 1, "4")
      <<"5", rest::binary-size(left)>> ->
        number_int(rest, pos + 1, "5")
      <<"6", rest::binary-size(left)>> ->
        number_int(rest, pos + 1, "6")
      <<"7", rest::binary-size(left)>> ->
        number_int(rest, pos + 1, "7")
      <<"8", rest::binary-size(left)>> ->
        number_int(rest, pos + 1, "8")
      <<"9", rest::binary-size(left)>> ->
        number_int(rest, pos + 1, "9")
      _ ->
        syntax_error(string, pos)
    end
  end

  ## Objects

  defp object_pairs("\"" <> rest, size, pos, keys, acc) do
    {name, pos, rest} = string_continue(rest, size, pos + 1, [])

    {rest, start} = skip_whitespace(rest, pos)
    left = size - start - 1

    {value, start, pos, rest} =
      case rest do
        <<":", rest::binary-size(left)>> ->
          {rest, pos} = skip_whitespace(rest, start + 1)
          {value, pos, rest} = value(rest, size, pos, keys)
          {value, start, pos, rest}

        other ->
          syntax_error(other, pos)
      end

    acc = [{object_name(name, start, keys), value} | acc]

    {rest, pos} = skip_whitespace(rest, pos)
    left = size - pos - 1

    case rest do
      <<",", rest::binary-size(left)>> ->
        {rest, pos} = skip_whitespace(rest, pos + 1)
        object_pairs(rest, size, pos, keys, acc)

      <<"}", rest::binary-size(left)>> ->
        {:maps.from_list(acc), pos + 1, rest}

      other ->
        syntax_error(other, pos)
    end
  end

  defp object_pairs(string, size, pos, _, []) do
    left = size - pos - 1
    case string do
      <<"}", rest::binary-size(left)>> ->
        {:maps.new(), pos + 1, rest}
      other ->
        syntax_error(other, pos)
    end
  end

  defp object_pairs(other, _size, pos, _, _acc) do
    syntax_error(other, pos)
  end

  defp object_name(name, pos, :atoms!) do
    String.to_existing_atom(name)
  rescue
    ArgumentError ->
      reraise ParseError, [pos: pos, value: name], stacktrace()
  end

  defp object_name(name, _pos, :atoms), do: String.to_atom(name)
  defp object_name(name, _pos, _keys), do: name

  ## Arrays

  defp array_values(string, size, pos, keys, acc) do
    left = size - pos - 1
    case string do
      <<"]", rest::binary-size(left)>> ->
        {[], pos + 1, rest}
      string ->
        array_values_continue(string, size, pos, keys, acc)
    end
  end

  defp array_values_continue(string, size, pos, keys, acc) do
    {value, pos, rest} = value(string, size, pos, keys)

    acc = [value | acc]

    {rest, pos} = skip_whitespace(rest, pos)
    left = size - pos - 1

    case rest do
      <<",", rest::binary-size(left)>> ->
        {rest, pos} = skip_whitespace(rest, pos + 1)
        array_values_continue(rest, size, pos, keys, acc)

      <<"]", rest::binary-size(left)>> ->
        {:lists.reverse(acc), pos + 1, rest}

      other ->
        syntax_error(other, pos)
    end
  end

  ## Numbers

  defp number_int(<<string::binary>>, pos, acc) do
    {acc, pos, rest} = number_digits(string, pos, acc)
    number_frac(rest, pos, acc)
  end

  defp number_frac("." <> rest, pos, acc) do
    {acc, pos, rest} = number_digits(rest, pos + 1, acc <> ".")
    number_exp(rest, true, pos, acc)
  end

  defp number_frac(string, pos, acc) do
    number_exp(string, false, pos, acc)
  end

  defp number_exp(<<e>> <> rest, frac, pos, acc) when e in 'eE' do
    acc = if frac, do: acc, else: "#{acc}.0"
    number_exp_sign(rest, frac, pos + 1, acc <> "e")
  end

  defp number_exp(string, frac, pos, acc) do
    {number_complete(acc, frac, pos), pos, string}
  end

  defp number_exp_sign("-" <> rest, frac, pos, acc) do
    number_exp_continue(rest, frac, pos + 1, acc <> "-")
  end

  defp number_exp_sign("+" <> rest, frac, pos, acc) do
    number_exp_continue(rest, frac, pos + 1, acc)
  end

  defp number_exp_sign(string, frac, pos, acc) do
    number_exp_continue(string, frac, pos, acc)
  end

  defp number_exp_continue(<<string::binary>>, frac, pos, acc) do
    case number_digits(string, pos, acc) do
      {"", pos, rest} ->
        syntax_error(rest, pos)
      {acc, pos, rest} ->
        pos = if frac, do: pos, else: pos + 2
        {number_complete(acc, true, pos), pos, rest}
    end
  end

  defp number_complete("-" <> rest, frac, pos) do
    -number_complete(rest, frac, pos)
  end

  for x <- 0..99 do
    defp number_complete(unquote("#{x}"), _frac, _pos) do
      unquote(x)
    end
  end

  defp number_complete(value, false, _pos) do
    number_complete_int(value, 0, 0)
  end

  defp number_complete(value, true, pos) do
    String.to_float(value)
  rescue
    ArgumentError ->
      reraise ParseError, [pos: pos, value: value], stacktrace()
  end

  defp number_complete_int(<<char>> <> rest, count, acc) do
    number_complete_int(rest, count + 1, acc + (count * (char - ?0)))
  end

  defp number_complete_int("", _count, acc) do
    acc
  end

  defp number_digits(<<char>> <> rest, pos, acc) when char in '0123456789' do
    number_digits(rest, pos + 1, acc <> <<char>>)
  end

  defp number_digits(rest, pos, acc) do
    {acc, pos, rest}
  end

  ## Strings

  defp string_continue("", _size, pos, _acc), do: syntax_error("", pos)

  defp string_continue(<<string::binary>>, size, pos, acc) do
    left = size - pos - 1
    case string do
      <<"\"", rest::binary-size(left)>> ->
        {IO.iodata_to_binary(acc), pos + 1, rest}
      <<"\\", rest::binary-size(left)>> ->
        string_escape(rest, size, pos + 1, acc)
      string ->
        {count, pos} = string_chunk_size(string, pos, 0)
        left = size - pos
        <<chunk::binary-size(count), rest::binary-size(left)>> = string
        string_continue(rest, size, pos, [acc | chunk])
    end
  end

  for {seq, char} <- Enum.zip('"\\ntr/fb', '"\\\n\t\r/\f\b') do
    defp string_escape(<<unquote(seq)>> <> rest, size, pos, acc) do
      string_continue(rest, size, pos + 1, [acc, unquote(char)])
    end
  end

  defguardp is_surrogate(a1, a2, b1, b2)
            when a1 in 'dD' and a2 in 'dD' and b1 in '89abAB' and
                   (b2 in ?c..?f or b2 in ?C..?F)

  # http://www.ietf.org/rfc/rfc2781.txt
  # http://perldoc.perl.org/Encode/Unicode.html#Surrogate-Pairs
  # http://mathiasbynens.be/notes/javascript-encoding#surrogate-pairs
  defp string_escape(
         <<?u, a1, b1, c1, d1, "\\u", a2, b2, c2, d2>> <> rest,
         size,
         pos,
         acc
       )
       when is_surrogate(a1, a2, b1, b2) do
    {hi, lo} = get_surrogate_pair(<<a1, b1, c1, d1>>, <<a2, b2, c2, d2>>, pos)
    codepoint = 0x10000 + ((hi &&& 0x03FF) <<< 10) + (lo &&& 0x03FF)
    string_continue(rest, size, pos + 11, [acc | <<codepoint::utf8>>])
  end

  defp string_escape(<<?u, seq::binary-size(4)>> <> rest, size, pos, acc) do
    code = get_codepoint(seq, pos)
    string_continue(rest, size, pos + 5, [acc | <<code::utf8>>])
  end

  defp string_escape(other, _size, pos, _), do: syntax_error(other, pos)

  defp string_chunk_size("\"" <> _, pos, acc), do: {acc, pos}
  defp string_chunk_size("\\" <> _, pos, acc), do: {acc, pos}

  # Control Characters (http://seriot.ch/parsing_json.php#25)
  defp string_chunk_size(<<char>> <> _rest, pos, _acc) when char <= 0x1F do
    syntax_error(<<char>>, pos)
  end

  defp string_chunk_size(<<char>> <> rest, pos, acc) when char < 0x80 do
    string_chunk_size(rest, pos + 1, acc + 1)
  end

  defp string_chunk_size(<<codepoint::utf8>> <> rest, pos, acc) do
    string_chunk_size(rest, pos + 1, acc + string_codepoint_size(codepoint))
  end

  defp string_chunk_size(other, pos, _acc), do: syntax_error(other, pos)

  defp string_codepoint_size(codepoint) when codepoint < 0x800, do: 2
  defp string_codepoint_size(codepoint) when codepoint < 0x10000, do: 3
  defp string_codepoint_size(_), do: 4

  ## Characters

  defp get_codepoint(seq, pos) do
    String.to_integer(seq, 16)
  rescue
    ArgumentError ->
      value = "\\u" <> seq
      reraise ParseError, [pos: pos + 6, value: value], stacktrace()
  end

  defp get_surrogate_pair(hi, lo, pos) do
    {String.to_integer(hi, 16), String.to_integer(lo, 16)}
  rescue
    ArgumentError ->
      value = "\\u" <> hi <> "\\u" <> lo
      reraise ParseError, [pos: pos + 12, value: value], stacktrace()
  end

  ## Whitespace

  defp skip_whitespace("    " <> rest, pos) do
    skip_whitespace(rest, pos + 4)
  end

  defp skip_whitespace(<<char>> <> rest, pos) when char in '\s\n\t\r' do
    skip_whitespace(rest, pos + 1)
  end

  defp skip_whitespace(string, pos), do: {string, pos}

  # https://tools.ietf.org/html/rfc7159#section-8.1
  # https://en.wikipedia.org/wiki/Byte_order_mark#UTF-8
  defp skip_bom(<<0xEF, 0xBB, 0xBF>> <> rest) do
    rest
  end

  defp skip_bom(string) do
    string
  end
end
