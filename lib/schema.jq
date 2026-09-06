def only($allowed): (keys - $allowed | length) == 0;
def nonempty: type == "string" and length > 0;
def interface_name: type == "string" and test("^[A-Za-z0-9_.:-]{1,15}$");
def identifier: type == "string" and test("^[A-Za-z0-9_-]{1,128}$");
def source_ok($family):
  type == "object" and (
    if .type == "argument" then only(["type"])
    elif .type == "interface" then only(["type","interface"]) and (.interface | interface_name)
    elif .type == "http" then
      only(["type","url","timeout_seconds","json_field"])
      and (.url | type == "string" and test("^https?://[^\\s]+$") and (test("[\\r\\n]")|not))
      and ((has("timeout_seconds")|not) or (.timeout_seconds | type == "number" and . == floor and . >= 1 and . <= 300))
      and ((has("json_field")|not) or (.json_field | nonempty))
    elif .type == "prefix_iid" then
      $family == "AAAA" and only(["type","interface","iid"])
      and (.interface | interface_name)
      and (.iid | type == "string" and test("^([0-9A-Fa-f]{1,4}:){3}[0-9A-Fa-f]{1,4}$") and (test("^(0+:){3}0+$")|not))
    else false end
  );
def entry_ok($family):
  type == "object" and only(["id","source"])
  and (.id | identifier) and (.source | source_ok($family));
def record_ok:
  type == "object" and only(["schema_version","enabled","provider","name","A","AAAA"])
  and .schema_version == 1 and (.enabled | type == "boolean")
  and .provider == "cloudflare"
  and (.name | type == "string" and length <= 253
       and test("^(\\*\\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.?$"))
  and (has("A") or has("AAAA"))
  and ((has("A")|not) or (.A | entry_ok("A")))
  and ((has("AAAA")|not) or (.AAAA | entry_ok("AAAA")));
record_ok
