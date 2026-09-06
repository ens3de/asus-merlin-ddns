# Strict native IP validation/canonicalization. No DNS or external processes.
def hexnorm: ascii_downcase | sub("^0+"; "") | if . == "" then "0" else . end;
def ipv6_parts:
  ascii_downcase as $s
  | if ($s | test("^[0-9a-f:]+$")) | not then error("Invalid IPv6 characters")
    else ($s | split("::")) as $halves
    | if ($halves | length) == 1 then
        ($s | split(":")) as $p
        | if ($p | length) == 8 then $p else error("IPv6 needs eight groups") end
      elif ($halves | length) == 2 then
        ($halves[0] | if . == "" then [] else split(":") end) as $left
        | ($halves[1] | if . == "" then [] else split(":") end) as $right
        | (8 - ($left|length) - ($right|length)) as $n
        | if $n > 0 then $left + [range($n) | "0"] + $right
          else error("Invalid IPv6 compression") end
      else error("Multiple IPv6 compression markers") end
    | if all(.[]; test("^[0-9a-f]{1,4}$")) then map(hexnorm)
      else error("Invalid IPv6 group") end
    end;
def public_ipv6:
  ipv6_parts
  | if (.[0] | test("^[23][0-9a-f]{3}$")) then join(":")
    else error("IPv6 must be global unicast (2000::/3), not ULA/link-local") end;
def public_ipv4:
  if test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$") then
    split(".") | map(tonumber)
    | if all(.[]; . >= 0 and . <= 255)
        and (.[0] > 0 and .[0] < 224 and .[0] != 10 and .[0] != 127)
        and (.[0] != 169 or .[1] != 254)
        and (.[0] != 172 or .[1] < 16 or .[1] > 31)
        and (.[0] != 192 or .[1] != 168)
        and (.[0] != 100 or .[1] < 64 or .[1] > 127)
      then map(tostring) | join(".") else error("Not a usable public IPv4") end
  else error("Invalid IPv4") end;
