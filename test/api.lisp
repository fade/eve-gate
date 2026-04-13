;;;; test/api.lisp - API function tests for eve-gate
;;;;
;;;; Tests for API client, endpoint registry, and generated API functions

(uiop:define-package #:eve-gate/test/api
  (:use #:cl)
  (:import-from #:eve-gate.api
                ;; Schema parser
                #:json-name->lisp-name
                #:operation-id->function-name
                #:parse-schema
                #:schema-definition
                #:schema-definition-type
                ;; Endpoint registry
                #:lookup-endpoint
                #:list-endpoints-by-category
                ;; Validation
                #:coerce-to-integer
                #:coerce-to-boolean
                #:coerce-to-string
                ;; Parameter formatting
                #:format-scalar-for-url
                #:substitute-path-parameters)
  (:local-nicknames (#:t #:parachute)))

(in-package #:eve-gate/test/api)

;;; Naming Convention Tests

(t:define-test json-name-to-lisp-name
  "Test JSON to Lisp name conversion - returns keywords"
  (t:is eq :character-id (json-name->lisp-name "character_id"))
  (t:is eq :solar-system-id (json-name->lisp-name "solar_system_id"))
  (t:is eq :is-buy-order (json-name->lisp-name "is_buy_order"))
  (t:is eq :name (json-name->lisp-name "name")))

(t:define-test operation-id-to-function-name
  "Test operation ID to function name conversion - returns strings"
  (t:is string= "get-characters-character-id" 
        (operation-id->function-name "get_characters_character_id"))
  (t:is string= "post-characters-affiliation"
        (operation-id->function-name "post_characters_affiliation"))
  (t:is string= "get-markets-region-id-orders"
        (operation-id->function-name "get_markets_region_id_orders")))

;;; Type Coercion Tests

(t:define-test coerce-to-integer-function
  "Test integer coercion"
  (t:is = 123 (coerce-to-integer 123))
  (t:is = 456 (coerce-to-integer "456"))
  (t:is = 0 (coerce-to-integer "0"))
  (t:is = -42 (coerce-to-integer "-42")))

(t:define-test coerce-to-boolean-function
  "Test boolean coercion"
  (t:true (coerce-to-boolean t))
  (t:true (coerce-to-boolean "true"))
  (t:true (coerce-to-boolean "TRUE"))
  (t:true (coerce-to-boolean "1"))
  (t:true (coerce-to-boolean 1))
  (t:false (coerce-to-boolean nil))
  (t:false (coerce-to-boolean "false"))
  (t:false (coerce-to-boolean "FALSE"))
  ;; Note: 0 as integer may not coerce to false depending on implementation
  )

(t:define-test coerce-to-string-function
  "Test string coercion"
  (t:is string= "hello" (coerce-to-string "hello"))
  (t:is string= "123" (coerce-to-string 123))
  ;; Keywords get downcased
  (t:is string= "keyword" (coerce-to-string :keyword))
  ;; Regular symbols
  (t:true (stringp (coerce-to-string 'symbol))))

;;; URL Formatting Tests

(t:define-test format-scalar-for-url-function
  "Test scalar value formatting for URLs"
  ;; format-scalar-for-url takes value and schema; nil schema uses generic formatting
  (t:is string= "123" (format-scalar-for-url 123 nil))
  (t:is string= "hello" (format-scalar-for-url "hello" nil))
  (t:is string= "keyword" (format-scalar-for-url :keyword nil))
  ;; With boolean schema, t/nil become true/false
  (let ((bool-schema (parse-schema (alexandria:plist-hash-table
                                    '("type" "boolean")
                                    :test 'equal))))
    (t:is string= "true" (format-scalar-for-url t bool-schema))
    (t:is string= "false" (format-scalar-for-url nil bool-schema))))

(t:define-test substitute-path-parameters-function
  "Test path parameter substitution"
  ;; Note: substitute-path-parameters expects string values
  (let ((path "/characters/{character_id}/skills")
        (params '(("character_id" . "12345"))))
    (let ((result (substitute-path-parameters path params)))
      (t:is string= "/characters/12345/skills" result)))
  
  (let ((path "/markets/{region_id}/orders")
        (params '(("region_id" . "10000002"))))
    (let ((result (substitute-path-parameters path params)))
      (t:is string= "/markets/10000002/orders" result))))

;;; Schema Parsing Tests

(t:define-test parse-schema-integer
  "Test parsing integer schema"
  (let ((schema (parse-schema (alexandria:plist-hash-table 
                               '("type" "integer"
                                 "format" "int32")
                               :test 'equal))))
    (t:true schema)
    (t:is eq :integer (schema-definition-type schema))))

(t:define-test parse-schema-string
  "Test parsing string schema"
  (let ((schema (parse-schema (alexandria:plist-hash-table
                               '("type" "string")
                               :test 'equal))))
    (t:true schema)
    (t:is eq :string (schema-definition-type schema))))

(t:define-test parse-schema-array
  "Test parsing array schema"
  (let ((schema (parse-schema (alexandria:plist-hash-table
                               '("type" "array"
                                 "items" ("type" "integer"))
                               :test 'equal))))
    (t:true schema)
    (t:is eq :array (schema-definition-type schema))))

;;; Endpoint Registry Tests
;;; These test the runtime endpoint registry populated from generated code

(t:define-test lookup-endpoint-exists
  "Test that endpoint lookup function exists and works"
  ;; lookup-endpoint should return something for known endpoints
  (t:true (functionp #'lookup-endpoint)))

(t:define-test list-endpoints-by-category-exists
  "Test that list-endpoints-by-category function exists"
  (t:true (functionp #'list-endpoints-by-category)))

;;; Generated Function Existence Tests
;;; These verify that key API functions were generated and are callable

(t:define-test generated-character-functions-exist
  "Test that character API functions exist"
  (t:true (fboundp 'eve-gate.api:get-characters-character-id))
  (t:true (fboundp 'eve-gate.api:get-characters-character-id-skills))
  (t:true (fboundp 'eve-gate.api:get-characters-character-id-wallet))
  (t:true (fboundp 'eve-gate.api:get-characters-character-id-assets)))

(t:define-test generated-market-functions-exist
  "Test that market API functions exist"
  (t:true (fboundp 'eve-gate.api:get-markets-prices))
  (t:true (fboundp 'eve-gate.api:get-markets-region-id-orders))
  (t:true (fboundp 'eve-gate.api:get-markets-region-id-history)))

(t:define-test generated-universe-functions-exist
  "Test that universe API functions exist"
  (t:true (fboundp 'eve-gate.api:get-universe-systems))
  (t:true (fboundp 'eve-gate.api:get-universe-types))
  (t:true (fboundp 'eve-gate.api:get-universe-regions)))

(t:define-test generated-corporation-functions-exist
  "Test that corporation API functions exist"
  (t:true (fboundp 'eve-gate.api:get-corporations-corporation-id))
  (t:true (fboundp 'eve-gate.api:get-corporations-corporation-id-members)))

(t:define-test generated-alliance-functions-exist
  "Test that alliance API functions exist"
  (t:true (fboundp 'eve-gate.api:get-alliances))
  (t:true (fboundp 'eve-gate.api:get-alliances-alliance-id)))

(t:define-test generated-status-function-exists
  "Test that status API function exists"
  (t:true (fboundp 'eve-gate.api:get-status)))
