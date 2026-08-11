# Meta-validation of catalog schemas against the constrained subset.
# Entry point: pw_meta_validate($schema) -> array of {path, message}
# Rejects unsupported keywords, non-anchored patterns, unsupported formats,
# and malformed oneOfFields / dependentRequired / discriminator structures.

def pw_meta_err($path; $msg): {path: $path, message: $msg};

def pw_meta_allowed($schema):
  ($schema.type // null) as $t |
  if $t == "object" then
    ["type", "const", "enum", "properties", "required", "additionalProperties", "minProperties", "maxProperties", "discriminator", "oneOfFields", "dependentRequired"]
  elif $t == "array" then
    ["type", "const", "enum", "items", "minItems", "maxItems", "uniqueItems"]
  elif $t == "string" then
    ["type", "const", "enum", "minLength", "maxLength", "pattern", "format"]
  elif $t == "integer" or $t == "number" then
    ["type", "const", "enum", "minimum", "maximum"]
  elif $t == "boolean" or $t == "null" then
    ["type", "const", "enum"]
  else [] end;

def pw_meta_check_node($schema; $path):
  if (($schema | type) != "object") then [pw_meta_err($path; "schema node must be an object")]
  else
    ($schema.type // null) as $t |
    (if ($t == null) then [pw_meta_err($path; "schema node requires a type")] else [] end) as $no_type_errors |
    (if (($t // "") != "" and ($t != "object" and $t != "array" and $t != "string" and $t != "number" and $t != "integer" and $t != "boolean" and $t != "null"))
       then [pw_meta_err($path + ".type"; "unsupported type")] else [] end) as $type_errors |
    (($schema | keys) - pw_meta_allowed($schema)) as $unknown |
    ([$unknown[] | pw_meta_err($path + "." + .; "unsupported schema keyword")]) as $unknown_errors |

    (if $t == "object" then
       (if ($schema.additionalProperties != null and $schema.additionalProperties != false)
          then [pw_meta_err($path + ".additionalProperties"; "additionalProperties must be false")] else [] end) as $ap_errors |
       (if ($schema.properties != null and ($schema.properties | type) != "object")
          then [pw_meta_err($path + ".properties"; "properties must be an object")] else [] end) as $props_type_errors |
       ([($schema.properties // {}) | to_entries[] as $p | pw_meta_check_node($p.value; $path + ".properties." + $p.key) | .[]]) as $props_errors |
       (if ($schema.required != null and (($schema.required | type) != "array" or ([$schema.required[] | select(. as $r | (($schema.properties // {}) | has($r)) | not)] | length > 0)))
          then [pw_meta_err($path + ".required"; "required must list declared properties")] else [] end) as $required_errors |
       (if ($schema.minProperties != null and (($schema.minProperties | type) != "number" or $schema.minProperties < 0))
          then [pw_meta_err($path + ".minProperties"; "minProperties must be a non-negative number")] else [] end) as $minp_errors |
       (if ($schema.maxProperties != null and (($schema.maxProperties | type) != "number" or $schema.maxProperties < 0))
          then [pw_meta_err($path + ".maxProperties"; "maxProperties must be a non-negative number")] else [] end) as $maxp_errors |
       (if ($schema.oneOfFields != null and (($schema.oneOfFields | type) != "array" or ([$schema.oneOfFields[] | select(. as $f | (. | type) != "string" or ((($schema.properties // {}) | has($f)) | not))] | length > 0)))
          then [pw_meta_err($path + ".oneOfFields"; "oneOfFields must list declared properties")] else [] end) as $oneof_errors |
       (if ($schema.dependentRequired != null and (($schema.dependentRequired | type) != "object" or ([$schema.dependentRequired | to_entries[] | select(. as $e | (.key | type) != "string" or ((($schema.properties // {}) | has($e.key)) | not) or ($e.value | type) != "array" or ([$e.value[] | select(. as $d | ((($schema.properties // {}) | has($d)) | not))] | length > 0))] | length > 0)))
          then [pw_meta_err($path + ".dependentRequired"; "dependentRequired must map declared properties to declared properties")] else [] end) as $dep_errors |
       (if ($schema.discriminator != null) then
          (if (($schema.discriminator | type) != "object" or (($schema.discriminator.propertyName // "") | type) != "string" or (($schema.discriminator.mapping // null) | type) != "object")
             then [pw_meta_err($path + ".discriminator"; "discriminator needs propertyName and mapping")] else [] end) as $disc_shape_errors |
          (($schema.discriminator.propertyName // "") as $pn |
           [($schema.discriminator.mapping // {}) | to_entries[] as $e |
            (pw_meta_check_node($e.value; $path + ".discriminator.mapping." + $e.key) +
             (if ($e.value.properties[$pn].const != $e.key)
                then [pw_meta_err($path + ".discriminator.mapping." + $e.key; "variant property const must match the mapping key")]
                else [] end)) | .[]
           ]) as $disc_mapping_errors |
          $disc_shape_errors + $disc_mapping_errors
        else [] end) as $disc_errors |
       $ap_errors + $props_type_errors + $props_errors + $required_errors + $minp_errors + $maxp_errors + $oneof_errors + $dep_errors + $disc_errors
     elif $t == "array" then
       (if ($schema.items != null) then pw_meta_check_node($schema.items; $path + ".items") else [] end) as $items_errors |
       (if ($schema.minItems != null and (($schema.minItems | type) != "number" or $schema.minItems < 0))
          then [pw_meta_err($path + ".minItems"; "minItems must be a non-negative number")] else [] end) as $mini_errors |
       (if ($schema.maxItems != null and (($schema.maxItems | type) != "number" or $schema.maxItems < 0))
          then [pw_meta_err($path + ".maxItems"; "maxItems must be a non-negative number")] else [] end) as $maxi_errors |
       (if ($schema.uniqueItems != null and ($schema.uniqueItems | type) != "boolean")
          then [pw_meta_err($path + ".uniqueItems"; "uniqueItems must be a boolean")] else [] end) as $uniq_errors |
       $items_errors + $mini_errors + $maxi_errors + $uniq_errors
     elif $t == "string" then
       (if ($schema.minLength != null and (($schema.minLength | type) != "number" or $schema.minLength < 0))
          then [pw_meta_err($path + ".minLength"; "minLength must be a non-negative number")] else [] end) as $minl_errors |
       (if ($schema.maxLength != null and (($schema.maxLength | type) != "number" or $schema.maxLength < 0))
          then [pw_meta_err($path + ".maxLength"; "maxLength must be a non-negative number")] else [] end) as $maxl_errors |
       (if ($schema.enum != null and (($schema.enum | type) != "array" or ($schema.enum | length) == 0))
          then [pw_meta_err($path + ".enum"; "enum must be a non-empty array")] else [] end) as $enum_errors |
       (if ($schema.pattern != null) then
          if (($schema.pattern | type) != "string") then [pw_meta_err($path + ".pattern"; "pattern must be a string")]
          elif (($schema.pattern | startswith("^")) | not) or (($schema.pattern | endswith("$")) | not)
            then [pw_meta_err($path + ".pattern"; "pattern must be anchored with ^ and $")]
          else [] end
        else [] end) as $pattern_errors |
       (if ($schema.format != null and (([$schema.format] - ["uuid", "session-name", "http-url", "origin", "element-ref", "selector", "sha256"]) | length) > 0)
          then [pw_meta_err($path + ".format"; "unsupported format")] else [] end) as $format_errors |
       $minl_errors + $maxl_errors + $enum_errors + $pattern_errors + $format_errors
     elif $t == "integer" or $t == "number" then
       (if ($schema.minimum != null and ($schema.minimum | type) != "number")
          then [pw_meta_err($path + ".minimum"; "minimum must be a number")] else [] end) as $min_errors |
       (if ($schema.maximum != null and ($schema.maximum | type) != "number")
          then [pw_meta_err($path + ".maximum"; "maximum must be a number")] else [] end) as $max_errors |
       $min_errors + $max_errors
     else [] end) as $type_errors2 |

     $no_type_errors + $type_errors + $unknown_errors + $type_errors2
  end;

def pw_meta_validate($schema):
  [pw_meta_check_node($schema; "$")[]];
