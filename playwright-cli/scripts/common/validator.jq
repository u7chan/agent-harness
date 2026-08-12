# Recursive input schema validator for the constrained schema subset.
# Entry point: pw_validate($instance; $schema) -> array of {path, code, message}
# Note: jq does not allow mutual recursion, so all recursion is inlined in
# pw_check_node; helper functions never call back into it.

def pw_err($path; $code; $msg): {path: $path, code: $code, message: $msg};

def pw_is_int($v): ($v | type) == "number" and ($v | floor) == $v;

def pw_is_ascii($s):
  (($s | explode) | map(select(. > 127)) | length) == 0;

def pw_is_element_ref($s):
  $s | test("^(f[0-9]+)?e[0-9]+$");

def pw_format_violation($v; $format; $path):
  if $format == "uuid" then
    if ($v | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))
      then [] else [pw_err($path; "FORMAT_VIOLATION"; "not a valid uuid")] end
  elif $format == "session-name" then
    if ($v | test("^[a-z0-9][a-z0-9._-]{0,63}$"))
      then [] else [pw_err($path; "FORMAT_VIOLATION"; "invalid session name")] end
  elif $format == "http-url" then
    if pw_is_ascii($v) and ($v | test("^https?://[^[:space:]\\x00-\\x1f]+$"))
      then [] else [pw_err($path; "FORMAT_VIOLATION"; "invalid http url")] end
  elif $format == "origin" then
    if ($v | test("^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$"))
      then [] else [pw_err($path; "FORMAT_VIOLATION"; "invalid origin")] end
  elif $format == "element-ref" then
    if pw_is_element_ref($v)
      then [] else [pw_err($path; "FORMAT_VIOLATION"; "invalid element ref")] end
  elif $format == "selector" then
    if pw_is_ascii($v) and ($v | length) > 0 and ($v | test("^[ -~]*$")) and (pw_is_element_ref($v) | not)
      then [] else [pw_err($path; "FORMAT_VIOLATION"; "invalid selector")] end
  elif $format == "sha256" then
    if ($v | test("^[0-9a-f]{64}$"))
      then [] else [pw_err($path; "FORMAT_VIOLATION"; "invalid sha256")] end
  else [] end;

def pw_check_common($node; $schema; $path):
  (if ($schema | has("const")) then
     if ($node == $schema.const) then [] else [pw_err($path; "CONST_VIOLATION"; "value does not match const")] end
   else [] end) as $const_errors |
  (if ($schema | has("enum")) then
     if (($schema.enum | index($node)) != null) then [] else [pw_err($path; "ENUM_VIOLATION"; "value not in enum")] end
   else [] end) as $enum_errors |
  $const_errors + $enum_errors;

def pw_check_string($node; $schema; $path):
  (if ($node | length) < ($schema.minLength // 0)
     then [pw_err($path; "LENGTH_VIOLATION"; "shorter than minLength")] else [] end) as $min_errors |
  (if ($schema | has("maxLength")) then
     if ($node | length) > $schema.maxLength then [pw_err($path; "LENGTH_VIOLATION"; "longer than maxLength")] else [] end
   else [] end) as $max_errors |
  (if ($schema | has("pattern")) then
     if pw_is_ascii($node) then
       if ($node | test($schema.pattern)) then [] else [pw_err($path; "PATTERN_VIOLATION"; "pattern mismatch")] end
     else [pw_err($path; "PATTERN_VIOLATION"; "pattern requires ascii input")] end
   else [] end) as $pattern_errors |
  (if ($schema | has("format")) then pw_format_violation($node; $schema.format; $path) else [] end) as $format_errors |
  $min_errors + $max_errors + $pattern_errors + $format_errors;

def pw_check_number($node; $schema; $path):
  (if ($schema | has("minimum")) then
     if ($node >= $schema.minimum) then [] else [pw_err($path; "RANGE_VIOLATION"; "below minimum")] end
   else [] end) as $min_errors |
  (if ($schema | has("maximum")) then
     if ($node <= $schema.maximum) then [] else [pw_err($path; "RANGE_VIOLATION"; "above maximum")] end
   else [] end) as $max_errors |
  $min_errors + $max_errors;

def pw_check_node($node; $schema; $path):
  if (($schema | type) != "object") then []
  else
    ($schema.type // null) as $t |
    if $t == "object" then
      if (($node | type) != "object") then [pw_err($path; "TYPE_MISMATCH"; "expected object")]
      else
        (pw_check_common($node; $schema; $path)) as $common_errors |
        (if $schema.additionalProperties != true then
           (($schema.properties // {}) | keys) as $parent_known |
           (if ($schema | has("discriminator")) then
              $parent_known + [$schema.discriminator.mapping | to_entries[] | (.value.properties // {}) | keys[]]
            else $parent_known end) as $known |
           [($node | keys[]) | select(. as $k | ($known | index($k)) == null) as $u
            | pw_err($path + "." + $u; "UNKNOWN_FIELD"; "unknown field")]
         else [] end) as $extra_errors |
        (if ($node | keys | length) < ($schema.minProperties // 0)
           then [pw_err($path; "PROPERTY_COUNT_VIOLATION"; "below minProperties")] else [] end) as $min_prop_errors |
        (if ($schema | has("maxProperties")) then
           if ($node | keys | length) <= $schema.maxProperties then [] else [pw_err($path; "PROPERTY_COUNT_VIOLATION"; "above maxProperties")] end
         else [] end) as $max_prop_errors |
        ([($schema.required // [])[] as $r
          | select(($node | has($r)) | not)
          | pw_err($path + "." + $r; "MISSING_REQUIRED_FIELD"; "required field missing")]) as $required_errors |
        ([($schema.properties // {}) | to_entries[] as $p
          | if ($node | has($p.key)) then pw_check_node($node[$p.key]; $p.value; $path + "." + $p.key) else [] end
          | .[]]) as $property_errors |
        (if ($schema | has("oneOfFields")) then
           (($schema.oneOfFields | map(select(. as $f | $node | has($f))) | length) == 1) as $count_ok |
           if $count_ok then [] else [pw_err($path; "ONE_OF_VIOLATION"; "exactly one of oneOfFields must be present")] end
         else [] end) as $oneof_errors |
        ([($schema.dependentRequired // {}) | to_entries[] as $e
          | if ($node | has($e.key)) then
              [$e.value[] as $d | select(($node | has($d)) | not)
               | pw_err($path + "." + $d; "DEPENDENT_REQUIRED_VIOLATION"; "dependent field missing")]
            else [] end
          | .[]]) as $dep_errors |
        (if ($schema | has("discriminator")) then
           ($schema.discriminator.propertyName) as $pn |
           if ($node | has($pn)) then
             (($node[$pn] | tostring) as $variant |
              if ($schema.discriminator.mapping | has($variant)) then
                pw_check_node($node; $schema.discriminator.mapping[$variant]; $path + "." + $variant)
              else [pw_err($path + "." + $pn; "DISCRIMINATOR_VIOLATION"; "unknown variant")] end)
           else [pw_err($path + "." + $pn; "DISCRIMINATOR_VIOLATION"; "missing discriminator property")] end
         else [] end) as $disc_errors |
        $common_errors + $extra_errors + $min_prop_errors + $max_prop_errors + $required_errors
          + $property_errors + $oneof_errors + $dep_errors + $disc_errors
      end
    elif $t == "array" then
      if (($node | type) != "array") then [pw_err($path; "TYPE_MISMATCH"; "expected array")]
      else
        (pw_check_common($node; $schema; $path)) as $common_errors |
        (if ($node | length) < ($schema.minItems // 0)
           then [pw_err($path; "ARRAY_SIZE_VIOLATION"; "below minItems")] else [] end) as $min_errors |
        (if ($schema | has("maxItems")) then
           if ($node | length) <= $schema.maxItems then [] else [pw_err($path; "ARRAY_SIZE_VIOLATION"; "above maxItems")] end
         else [] end) as $max_errors |
        (if ($schema.uniqueItems == true) then
           if (($node | length) == ($node | unique | length)) then [] else [pw_err($path; "UNIQUE_ITEMS_VIOLATION"; "duplicate items")] end
         else [] end) as $unique_errors |
        (if ($schema | has("items")) then
           [range(0; $node | length) as $i | pw_check_node($node[$i]; $schema.items; $path + "[" + ($i | tostring) + "]")[]]
         else [] end) as $items_errors |
        $common_errors + $min_errors + $max_errors + $unique_errors + $items_errors
      end
    elif $t == "string" then
      if (($node | type) != "string") then [pw_err($path; "TYPE_MISMATCH"; "expected string")]
      else pw_check_common($node; $schema; $path) + pw_check_string($node; $schema; $path) end
    elif $t == "number" then
      if (($node | type) != "number") then [pw_err($path; "TYPE_MISMATCH"; "expected number")]
      else pw_check_common($node; $schema; $path) + pw_check_number($node; $schema; $path) end
    elif $t == "integer" then
      if (pw_is_int($node) | not) then [pw_err($path; "TYPE_MISMATCH"; "expected integer")]
      else pw_check_common($node; $schema; $path) + pw_check_number($node; $schema; $path) end
    elif $t == "boolean" then
      if (($node | type) != "boolean") then [pw_err($path; "TYPE_MISMATCH"; "expected boolean")]
      else pw_check_common($node; $schema; $path) end
    elif $t == "null" then
      if (($node | type) != "null") then [pw_err($path; "TYPE_MISMATCH"; "expected null")]
      else pw_check_common($node; $schema; $path) end
    elif $t == null then []
    else [pw_err($path; "TYPE_MISMATCH"; "unsupported schema type " + $t)] end
  end;

def pw_validate($instance; $schema):
  [pw_check_node($instance; $schema; "$")[]];
