(* Tests for the OpenAI-compatible client's pure layer. *)

module C = Selectarr_core.Config
module Client = Selectarr_llm.Client

let str = Alcotest.(check string)

let cfg =
  {
    C.default_llm with
    C.llm_base_url = "http://llm.example/v1";
    llm_model = "local-model";
    llm_api_key = "secret";
    llm_temperature = 0.1;
    llm_max_tokens = 512;
  }

let test_url_joining () =
  str "with /v1" "http://host:8080/v1/chat/completions"
    (Client.chat_completions_url "http://host:8080/v1");
  str "with trailing slash" "http://host:8080/v1/chat/completions"
    (Client.chat_completions_url "http://host:8080/v1/");
  str "without a version prefix" "http://host:8080/v1/chat/completions"
    (Client.chat_completions_url "http://host:8080");
  str "openai" "https://api.openai.com/v1/chat/completions"
    (Client.chat_completions_url "https://api.openai.com/v1");
  str "other version prefixes are kept" "https://host/openai/v3/chat/completions"
    (Client.chat_completions_url "https://host/openai/v3/");
  str "empty stays empty" "" (Client.chat_completions_url "   ")

let test_request_body () =
  let body = Client.build_request_body cfg ~system:"sys" ~user:"usr" ~json_mode:true in
  let open Yojson.Safe.Util in
  str "model" "local-model" (body |> member "model" |> to_string);
  str "response format" "json_object"
    (body |> member "response_format" |> member "type" |> to_string);
  Alcotest.(check int) "max tokens" 512 (body |> member "max_tokens" |> to_int);
  Alcotest.(check (float 0.001)) "temperature" 0.1 (body |> member "temperature" |> to_number);
  let messages = body |> member "messages" |> to_list in
  Alcotest.(check int) "two messages" 2 (List.length messages);
  str "system role" "system" (List.nth messages 0 |> member "role" |> to_string);
  str "system content" "sys" (List.nth messages 0 |> member "content" |> to_string);
  str "user role" "user" (List.nth messages 1 |> member "role" |> to_string);
  let plain = Client.build_request_body cfg ~system:"s" ~user:"u" ~json_mode:false in
  Alcotest.(check bool)
    "no response_format when json mode is off" true
    (plain |> member "response_format" = `Null)

let test_parse_completion () =
  let response =
    Yojson.Safe.from_string
      {|{"id":"chatcmpl-1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}],"usage":{"total_tokens":5}}|}
  in
  (match Client.parse_completion response with
  | Ok c -> str "content" "hello" c
  | Error m -> Alcotest.failf "should have parsed: %s" m);
  (* Legacy servers that answer with choices[].text *)
  (match
     Client.parse_completion
       (Yojson.Safe.from_string {|{"choices":[{"text":"legacy","index":0}]}|})
   with
  | Ok c -> str "legacy content" "legacy" c
  | Error m -> Alcotest.failf "should have parsed: %s" m);
  (match
     Client.parse_completion
       (Yojson.Safe.from_string
          {|{"choices":[{"index":0,"message":{"content":"{\"a\":1"},"finish_reason":"length"}]}|})
   with
  | Ok _ -> Alcotest.fail "truncated output must fail"
  | Error m ->
      Alcotest.(check bool)
        "mentions truncation" true
        (String.length m > 0 && String.contains m 'c'));
  (match Client.parse_completion (Yojson.Safe.from_string {|{"choices":[]}|}) with
  | Ok _ -> Alcotest.fail "empty choices must fail"
  | Error _ -> ());
  match Client.parse_completion (Yojson.Safe.from_string {|{"nope":true}|}) with
  | Ok _ -> Alcotest.fail "missing choices must fail"
  | Error _ -> ()

let json_string j = Yojson.Safe.to_string j

let test_extract_json () =
  (match Client.extract_json {|{"selected_id":"a","confidence":0.9}|} with
  | Ok j -> str "plain" {|{"selected_id":"a","confidence":0.9}|} (json_string j)
  | Error m -> Alcotest.failf "plain json: %s" m);
  (match Client.extract_json "```json\n{\"selected_id\":\"a\"}\n```" with
  | Ok j -> str "fenced" {|{"selected_id":"a"}|} (json_string j)
  | Error m -> Alcotest.failf "fenced: %s" m);
  (match Client.extract_json "```\n{\"a\":1}\n```" with
  | Ok j -> str "bare fence" {|{"a":1}|} (json_string j)
  | Error m -> Alcotest.failf "bare fence: %s" m);
  (match
     Client.extract_json
       "Sure! Here is my answer:\n{\"selected_id\":\"x\",\"ranking\":[{\"id\":\"x\"}]}\nHope that helps."
   with
  | Ok j -> str "surrounded by prose" {|{"selected_id":"x","ranking":[{"id":"x"}]}|} (json_string j)
  | Error m -> Alcotest.failf "prose: %s" m);
  (* Braces inside strings must not end the object early. *)
  (match Client.extract_json {|prefix {"reason":"a } b","ok":true} suffix|} with
  | Ok j -> str "braces in strings" {|{"reason":"a } b","ok":true}|} (json_string j)
  | Error m -> Alcotest.failf "braces in strings: %s" m);
  (match Client.extract_json {|prefix {"reason":"escaped \" and } brace","ok":1} tail|} with
  | Ok j ->
      str "escaped quotes" {|{"reason":"escaped \" and } brace","ok":1}|} (json_string j)
  | Error m -> Alcotest.failf "escaped quotes: %s" m);
  (match Client.extract_json "I refuse to answer." with
  | Ok _ -> Alcotest.fail "prose without json must fail"
  | Error _ -> ());
  match Client.extract_json "{\"unterminated\": " with
  | Ok _ -> Alcotest.fail "unterminated json must fail"
  | Error _ -> ()

let test_error_bodies () =
  (match
     Client.parse_error_body 401
       {|{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}|}
   with
  | Client.Http_status (401, m) ->
      str "openai error" "Incorrect API key provided (invalid_api_key)" m
  | e -> Alcotest.failf "unexpected: %s" (Client.error_to_string e));
  (match Client.parse_error_body 404 {|{"error":"model not found"}|} with
  | Client.Http_status (404, m) -> str "string error" "model not found" m
  | e -> Alcotest.failf "unexpected: %s" (Client.error_to_string e));
  match Client.parse_error_body 502 "upstream unavailable" with
  | Client.Http_status (502, m) -> str "raw body" "upstream unavailable" m
  | e -> Alcotest.failf "unexpected: %s" (Client.error_to_string e)

let test_disabled_without_config () =
  let unconfigured = { C.default_llm with C.llm_base_url = ""; llm_model = "" } in
  match Lwt_main.run (Client.chat_json unconfigured ~system:"s" ~user:"u") with
  | Error Client.Disabled -> ()
  | Error e -> Alcotest.failf "expected Disabled, got %s" (Client.error_to_string e)
  | Ok _ -> Alcotest.fail "unconfigured client must not perform a request"

let test_error_messages () =
  str "disabled" "LLM is disabled or not configured" (Client.error_to_string Client.Disabled);
  str "timeout" "request timed out" (Client.error_to_string Client.Timeout);
  str "bad response" "invalid response: nope"
    (Client.error_to_string (Client.Bad_response "nope"))

let tests =
  [
    ("url joining", `Quick, test_url_joining);
    ("request body", `Quick, test_request_body);
    ("parse completion", `Quick, test_parse_completion);
    ("extract json", `Quick, test_extract_json);
    ("error bodies", `Quick, test_error_bodies);
    ("disabled without config", `Quick, test_disabled_without_config);
    ("error messages", `Quick, test_error_messages);
  ]

let () = Alcotest.run "selectarr-llm" [ ("llm", tests) ]
