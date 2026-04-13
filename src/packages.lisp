;;;; packages.lisp - Package definitions for eve-gate

(defpackage #:eve-gate.utils
  (:use #:cl #:alexandria)
  (:export 
   ;; Logging
   #:*log-level*
   #:log-debug #:log-info #:log-warn #:log-error
   #:with-logging
   
   ;; Configuration  
   #:*default-config*
   #:load-config
   #:get-config-value
   #:set-config-value
   
   ;; String utilities
   #:kebab-case
   #:snake-case
   #:camel-case
   #:trim-whitespace
   
   ;; Time utilities
   #:current-timestamp
   #:format-iso8601
   #:parse-iso8601
   #:time-elapsed-p))

(defpackage #:eve-gate.types
  (:use #:cl #:alexandria)
  (:import-from #:local-time)
  (:import-from #:cl-ppcre)
  (:import-from #:com.inuoe.jzon)
  (:export
   ;; --- ESI entity ID types (esi-types.lisp) ---
   ;; Range constants
   #:+min-esi-id+
   #:+max-int32+
   #:+max-int64+
   
   ;; Core 32-bit entity types
   #:esi-id
   #:character-id
   #:corporation-id
   #:alliance-id
   #:type-id
   #:region-id
   #:constellation-id
   #:solar-system-id
   #:station-id
   #:planet-id
   #:moon-id
   #:stargate-id
   #:asteroid-belt-id
   #:market-group-id
   #:category-id
   #:group-id
   #:graphic-id
   #:dogma-attribute-id
   #:dogma-effect-id
   #:war-id
   #:contract-id
   #:killmail-id
   #:fitting-id
   #:schematic-id
   #:faction-id
   #:race-id
   #:bloodline-id
   #:ancestry-id
   
   ;; Extended 64-bit entity types
   #:structure-id
   #:fleet-id
   #:item-id
   #:order-id
   #:transaction-id
   #:journal-ref-id
   #:mail-id
   #:label-id
   #:event-id
   #:observer-id
   
   ;; Compound value types
   #:killmail-hash
   #:esi-datasource
   #:esi-language
   #:order-type
   #:route-flag
   #:event-response
   #:wallet-division
   #:security-status
   #:standing-value
   #:isk-amount
   
   ;; Predicate functions
   #:esi-id-p
   #:character-id-p
   #:corporation-id-p
   #:alliance-id-p
   #:type-id-p
   #:region-id-p
   #:constellation-id-p
   #:solar-system-id-p
   #:station-id-p
   #:structure-id-p
   #:fleet-id-p
   #:item-id-p
   #:war-id-p
   #:contract-id-p
   #:killmail-id-p
   #:order-id-p
   #:planet-id-p
   #:moon-id-p
   #:stargate-id-p
   #:asteroid-belt-id-p
   #:market-group-id-p
   #:category-id-p
   #:group-id-p
   #:graphic-id-p
   #:dogma-attribute-id-p
   #:dogma-effect-id-p
   #:schematic-id-p
   #:fitting-id-p
   #:faction-id-p
   #:mail-id-p
   #:label-id-p
   #:event-id-p
   #:observer-id-p
   #:non-empty-string-p
   #:killmail-hash-p
   #:esi-datasource-p
   #:esi-language-p
   
   ;; ID type registry
   #:*esi-id-type-map*
   #:esi-id-predicate-for
   
   ;; --- Validation functions (validation.lisp) ---
   #:*strict-id-validation*
   
   ;; ID validators
   #:validate-esi-id
   #:validate-character-id
   #:validate-corporation-id
   #:validate-alliance-id
   #:validate-type-id
   #:validate-region-id
   #:validate-solar-system-id
   #:validate-station-id
   #:validate-structure-id
   #:validate-fleet-id
   #:validate-war-id
   #:validate-contract-id
   #:validate-killmail-id
   #:validate-order-id
   #:validate-id-by-parameter-name
   
   ;; String validators
   #:validate-esi-string
   #:validate-eve-name
   #:validate-killmail-hash
   #:validate-search-string
   
   ;; Timestamp validators
   #:validate-esi-timestamp
   #:validate-esi-date
   
   ;; Enum validators
   #:validate-enum
   #:validate-datasource
   #:validate-language
   #:validate-order-type
   #:validate-route-flag
   
   ;; Numeric validators
   #:validate-page-number
   #:validate-wallet-division
   #:validate-standing-value
   
   ;; List validators
   #:validate-id-list
   
   ;; General-purpose validator
   #:validate-api-input
   
   ;; --- Type conversion (conversion.lisp) ---
   ;; String/number parsing
   #:parse-esi-integer
   #:parse-esi-number
   #:parse-esi-boolean
   
   ;; Timestamp conversion
   #:parse-esi-timestamp
   #:format-esi-timestamp
   #:parse-esi-date
   #:format-esi-date
   #:timestamp-to-universal-time
   #:universal-time-to-timestamp
   
   ;; JSON value conversions
   #:json-null-p
   #:json-value-or-nil
   #:json-to-string
   #:json-to-integer
   #:json-to-number
   #:json-to-boolean
   #:json-to-timestamp
   #:json-to-list
   
   ;; ESI format conversions
   #:datasource-to-string
   #:language-to-string
   #:keyword-to-esi-string
   #:esi-string-to-keyword
   
   ;; Batch conversions
   #:convert-hash-table-timestamps
   #:convert-response-ids
   
   ;; --- Response types (response-types.lisp) ---
   ;; Pagination
   #:pagination-info
   #:make-pagination-info
   #:pagination-info-current-page
   #:pagination-info-total-pages
   #:pagination-info-has-more-p
   #:pagination-info-page-size
   #:extract-pagination-from-headers
   
   ;; Rate limit info
   #:rate-limit-info
   #:make-rate-limit-info
   #:rate-limit-info-error-limit-remain
   #:rate-limit-info-error-limit-reset
   #:rate-limit-info-retry-after
   #:rate-limit-info-rate-limited-p
   #:extract-rate-limit-from-headers
   
   ;; Cache info
   #:cache-info
   #:make-cache-info
   #:cache-info-etag
   #:cache-info-expires
   #:cache-info-last-modified
   #:cache-info-cache-control
   #:cache-info-cached-p
   #:extract-cache-from-headers
   
   ;; API response wrapper
   #:api-response
   #:make-api-response
   #:api-response-data
   #:api-response-status
   #:api-response-headers
   #:api-response-pagination
   #:api-response-rate-limit
   #:api-response-cache
   #:api-response-endpoint
   #:api-response-timestamp
   #:api-response-etag
   #:api-response-expires
   #:api-response-paginated-p
   #:api-response-has-more-pages-p
   #:api-response-total-pages
   #:api-response-rate-limited-p
   #:api-response-error-budget-remaining
   #:api-response-success-p
   
   ;; ESI error response
   #:esi-error-response
   #:make-esi-error-response
   #:esi-error-response-error-message
   #:esi-error-response-sso-status
   #:esi-error-response-timeout
   #:parse-esi-error-body
   
   ;; Header utilities
   #:extract-header-value
   #:parse-http-date
   
   ;; --- Error types (error-types.lisp) ---
   ;; Conditions
   #:eve-type-error
   #:eve-type-error-value
   #:eve-type-error-expected-type
   #:eve-type-error-context
   #:eve-validation-error
   #:eve-validation-error-errors
   #:eve-conversion-error
   #:eve-conversion-error-source-type
   #:eve-conversion-error-target-type
   #:eve-id-error
   #:eve-id-error-id-type
   
   ;; Signaling utilities
   #:signal-validation-error
   #:signal-conversion-error
   #:signal-id-error
   #:default-for-type))

(defpackage #:eve-gate.core
  (:use #:cl #:alexandria #:eve-gate.utils #:eve-gate.types)
  (:import-from #:dexador 
                #:*default-connect-timeout*
                #:*default-read-timeout*)
  (:export
   ;; Conditions - base
   #:esi-condition
   #:esi-condition-message
   #:esi-condition-endpoint
   #:esi-deprecation-warning
   #:esi-deprecation-alternate-route
   
   ;; Conditions - errors
   #:esi-error
   #:esi-error-status-code
   #:esi-error-message
   #:esi-error-endpoint
   #:esi-error-response-body
   #:esi-error-response-headers
   #:esi-client-error
   #:esi-bad-request
   #:esi-unauthorized
   #:esi-forbidden
   #:esi-forbidden-required-scope
   #:esi-not-found
   #:esi-rate-limit-exceeded
   #:esi-rate-limit-retry-after
   #:esi-rate-limit-error-limit-remain
   #:esi-rate-limit-error-limit-reset
   #:esi-unprocessable-entity
   #:esi-server-error
   #:esi-internal-error
   #:esi-bad-gateway
   #:esi-service-unavailable
   #:esi-gateway-timeout
   #:esi-network-error
   #:esi-network-error-original-condition
   #:esi-connection-timeout
   #:esi-read-timeout
   
    ;; Condition utilities
    #:status-code->condition-type
    #:signal-esi-error
    #:retryable-status-p
    #:rate-limited-p
    
    ;; Error context and logging
    #:error-context
    #:make-error-context
    #:error-context-timestamp
    #:error-context-condition
    #:error-context-condition-type
    #:error-context-endpoint
    #:error-context-status-code
    #:error-context-message
    #:error-context-response-body
    #:error-context-request-method
    #:error-context-request-uri
    #:error-context-retry-count
    #:error-context-extra
    #:format-error-context
    #:log-esi-error
    #:classify-error-severity
    #:add-error-log-hook
    #:remove-error-log-hook
    #:clear-error-log-hooks
    
    ;; Error statistics
    #:error-statistics
    #:make-error-statistics
    #:*error-statistics*
    #:record-error
    #:error-statistics-summary
    #:reset-error-statistics
    #:recent-errors
    #:show-recent-errors
    #:errors-by-endpoint
    #:errors-by-type
    #:errors-by-status
    
    ;; Circuit breaker
    #:circuit-breaker
    #:make-circuit-breaker
    #:circuit-breaker-state
    #:circuit-breaker-allow-request-p
    #:circuit-breaker-record-success
    #:circuit-breaker-record-failure
    #:circuit-breaker-reset
    #:circuit-breaker-status
    #:*default-circuit-breaker*
    #:get-circuit-breaker
    #:register-circuit-breaker
    #:list-circuit-breakers
    
    ;; Graceful degradation
    #:register-fallback
    #:find-fallback
    #:invoke-fallback
    #:with-esi-fallback
    #:call-with-error-handling
    #:retryable-error-p
    #:ignoring-esi-errors
    #:with-esi-error-logging
    
    ;; Health monitoring
    #:esi-health-status
    #:esi-health-report
    
    ;; Resilient middleware
    #:make-error-handling-middleware
    #:make-resilient-middleware-stack
    
    ;; HTTP client
   #:http-client
   #:make-http-client
   #:http-request
   #:http-client-base-url
   #:http-client-user-agent
   #:http-client-default-headers
   #:http-client-connect-timeout
   #:http-client-read-timeout
   #:http-client-max-retries
   #:http-client-use-connection-pool-p
   #:http-client-middleware-stack
   #:*default-timeout*
   #:*default-retries*
   #:*esi-base-url*
   #:*esi-default-headers*
   #:*user-agent*
   
   ;; Middleware
   #:middleware
   #:make-middleware
   #:middleware-name
   #:middleware-priority
   #:middleware-enabled-p
   #:middleware-request-fn
   #:middleware-response-fn
   #:make-middleware-stack
   #:add-middleware
   #:remove-middleware
   #:find-middleware
   #:list-middleware
   #:apply-request-middleware
   #:apply-response-middleware
   #:with-middleware
   
   ;; Built-in middleware constructors
   #:make-headers-middleware
   #:make-logging-middleware
   #:make-json-middleware
   #:make-error-middleware
   #:make-rate-limit-tracking-middleware
   #:make-default-middleware-stack
   
   ;; ESI response
   #:esi-response
   #:make-esi-response
   #:esi-response-status
   #:esi-response-headers
   #:esi-response-body
   #:esi-response-raw-body
   #:esi-response-uri
   #:esi-response-etag
   #:esi-response-expires
   #:esi-response-cached-p
   #:extract-esi-metadata
   
   ;; URI construction
   #:build-esi-uri
   
   ;; Rate limiting (stubs for future)
   #:make-rate-limiter
   #:rate-limit-acquire
   #:rate-limit-status))

(defpackage #:eve-gate.auth
  (:use #:cl #:alexandria #:eve-gate.utils #:eve-gate.types #:eve-gate.core)
  (:export
   ;; EVE SSO configuration
   #:*eve-sso-auth-url*
   #:*eve-sso-token-url*
   #:*eve-sso-verify-url*
   #:*eve-sso-auth-server*
   #:*default-callback-port*
   #:*default-redirect-uri*

   ;; OAuth2 client
   #:oauth-client
   #:make-oauth-client
   #:oauth-client-client-id
   #:oauth-client-scopes
   #:oauth-client-redirect-uri

   ;; OAuth2 flow
   #:get-authorization-url
   #:exchange-code-for-token
   #:refresh-access-token
   #:verify-access-token
   #:authenticate-via-browser

   ;; Auth conditions
   #:eve-sso-error
   #:eve-sso-error-type
   #:eve-sso-token-expired
   #:eve-sso-insufficient-scopes
   #:eve-sso-required-scopes
   #:eve-sso-granted-scopes
   #:eve-sso-token-refresh-failed

   ;; Auth middleware
   #:make-auth-middleware
   #:make-scope-checking-middleware

   ;; Token info
   #:token-info
   #:token-info-access-token
   #:token-info-refresh-token
   #:token-info-expires-at
   #:token-info-scopes
   #:token-info-character-id
   #:token-info-character-name
   #:token-expired-p
   #:token-needs-refresh-p
   #:token-valid-p
   #:token-time-remaining

   ;; Token manager
   #:token-manager
   #:make-token-manager
   #:get-valid-access-token
   #:store-token
   #:load-token
   #:revoke-token
   #:token-manager-authenticated-p
   #:token-manager-character-id
   #:token-manager-character-name
   #:token-manager-scopes
   #:token-manager-expires-at
   #:token-manager-status
   #:authenticate-and-store
   #:restore-or-authenticate

   ;; Token persistence
   #:*token-storage-directory*
   #:*refresh-threshold*
   #:save-token-state
   #:list-persisted-tokens

   ;; Scopes - registry
   #:*available-scopes*
   #:*esi-scope-registry*
   #:*scope-categories*
   #:*scope-count*

   ;; Scopes - validation
   #:valid-scope-p
   #:validate-scopes
   #:scope-required-p
   #:sufficient-scopes-p
   #:missing-scopes

   ;; Scopes - queries
   #:scope-info
   #:scope-category
   #:scope-description
   #:scopes-by-category
   #:all-read-scopes
   #:all-write-scopes
   #:character-scopes
   #:corporation-scopes

   ;; Scopes - operations
   #:merge-scopes
   #:subtract-scopes
   #:format-scopes-for-oauth
   #:parse-scope-string
   #:scope-summary))

(defpackage #:eve-gate.cache  
  (:use #:cl #:alexandria #:eve-gate.utils #:eve-gate.types #:eve-gate.core)
  (:import-from #:bordeaux-threads)
  (:import-from #:com.inuoe.jzon)
  (:import-from #:local-time)
  (:export
   ;; --- Cache entry (memory-cache.lisp) ---
   #:cache-entry
   #:make-cache-entry
   #:cache-entry-key
   #:cache-entry-value
   #:cache-entry-etag
   #:cache-entry-expires-at
   #:cache-entry-created-at
   #:cache-entry-accessed-at
   #:cache-entry-access-count
   #:cache-entry-expired-p
   #:cache-entry-ttl-remaining

   ;; --- Memory cache (memory-cache.lisp) ---
   #:memory-cache
   #:make-memory-cache
   #:memory-cache-get
   #:memory-cache-put
   #:memory-cache-delete
   #:memory-cache-exists-p
   #:memory-cache-clear
   #:memory-cache-count
   #:memory-cache-statistics
   #:memory-cache-purge-expired
   #:memory-cache-get-multi
   #:memory-cache-keys
   #:memory-cache-summary

   ;; --- ETag cache (etag-cache.lisp) ---
   #:etag-cache
   #:make-etag-cache
   #:etag-cache-get
   #:etag-cache-put
   #:etag-cache-record-result
   #:etag-cache-delete
   #:etag-cache-clear
   #:etag-cache-count
   #:etag-cache-statistics
   #:etag-cache-summary

   ;; --- Database cache (database-cache.lisp) ---
   #:database-cache
   #:make-database-cache
   #:database-cache-get
   #:database-cache-put
   #:database-cache-delete
   #:database-cache-exists-p
   #:database-cache-clear
   #:database-cache-statistics
   #:database-cache-purge-expired
   #:database-cache-summary
   #:*database-cache-directory*

   ;; --- Cache policies (policies.lisp) ---
   ;; Policy struct
   #:cache-policy
   #:make-cache-policy
   #:cache-policy-name
   #:cache-policy-ttl
   #:cache-policy-use-etag-p
   #:cache-policy-cache-in-memory-p
   #:cache-policy-cache-in-db-p
   #:cache-policy-priority
   #:cache-policy-invalidate-on-write-p
   #:cache-policy-stale-while-revalidate

   ;; Pre-defined policies
   #:*policy-volatile*
   #:*policy-short*
   #:*policy-standard*
   #:*policy-long*
   #:*policy-static*
   #:*policy-no-cache*

   ;; Policy configuration
   #:*category-policy-map*
   #:*endpoint-policy-overrides*
   #:get-cache-policy
   #:set-endpoint-policy
   #:set-category-policy
   #:cacheable-request-p

   ;; TTL computation
   #:compute-ttl-from-headers
   #:parse-cache-control-max-age

   ;; Cache key generation
   #:make-cache-key
   #:extract-auth-context-from-params

   ;; Write invalidation
   #:*write-invalidation-rules*
   #:get-invalidation-targets

   ;; Policy introspection
   #:list-all-policies
   #:policy-summary
   #:endpoint-policy-summary

   ;; --- Cache manager (cache-manager.lisp) ---
   #:cache-manager
   #:make-cache-manager
   #:cache-manager-memory-cache
   #:cache-manager-database-cache
   #:cache-manager-etag-cache
   #:cache-manager-enabled-p

   ;; Core operations
   #:cache-get
   #:cache-put
   #:cache-delete
   #:cache-exists-p
   #:cache-clear

   ;; High-level interface
   #:cache-lookup
   #:cache-store
   #:invalidate-for-write
   #:invalidate-by-operation

   ;; Middleware
   #:make-cache-middleware

   ;; WITH-CACHING macro
   #:with-caching

   ;; Statistics and monitoring
   #:cache-statistics
   #:cache-hit-rate
   #:cache-purge-expired
   #:cache-summary))

(defpackage #:eve-gate.api
  (:use #:cl #:alexandria #:eve-gate.utils #:eve-gate.types #:eve-gate.core 
        #:eve-gate.auth #:eve-gate.cache)
  (:export
   ;; --- Schema parser ---
   ;; Schema definition structure
   #:schema-definition
   #:make-schema-definition
   #:schema-definition-name
   #:schema-definition-type
   #:schema-definition-format
   #:schema-definition-description
   #:schema-definition-properties
   #:schema-definition-required-fields
   #:schema-definition-items-schema
   #:schema-definition-enum-values
   #:schema-definition-min-value
   #:schema-definition-max-value
   #:schema-definition-min-items
   #:schema-definition-max-items
   #:schema-definition-unique-items-p
   #:schema-definition-ref
   #:schema-definition-cl-type

   ;; Property definition structure
   #:property-definition
   #:make-property-definition
   #:property-definition-name
   #:property-definition-cl-name
   #:property-definition-schema
   #:property-definition-required-p
   #:property-definition-description

   ;; Schema parsing functions
   #:parse-schema
   #:validate-schema
   #:schema-summary
   #:json-name->lisp-name
   #:operation-id->function-name
   #:resolve-ref
   #:resolve-schema-ref

   ;; Hash-table access utilities
   #:ht-get
   #:ht-get-list

   ;; --- Spec processor ---
   ;; Configuration
   #:*esi-spec-url*
   #:*esi-spec-versions*
   #:*spec-cache-directory*
   #:*spec-cache-ttl*

   ;; ESI spec structure
   #:esi-spec
   #:esi-spec-title
   #:esi-spec-version
   #:esi-spec-base-path
   #:esi-spec-host
   #:esi-spec-schemes
   #:esi-spec-endpoints
   #:esi-spec-global-parameters
   #:esi-spec-security-definitions
   #:esi-spec-categories
   #:esi-spec-raw-spec
   #:esi-spec-fetched-at
   #:esi-spec-source-url

   ;; Endpoint definition structure
   #:endpoint-definition
   #:make-endpoint-definition
   #:endpoint-definition-operation-id
   #:endpoint-definition-function-name
   #:endpoint-definition-path
   #:endpoint-definition-method
   #:endpoint-definition-description
   #:endpoint-definition-summary
   #:endpoint-definition-category
   #:endpoint-definition-parameters
   #:endpoint-definition-path-parameters
   #:endpoint-definition-query-parameters
   #:endpoint-definition-header-parameters
   #:endpoint-definition-body-parameter
   #:endpoint-definition-response-schema
   #:endpoint-definition-response-description
   #:endpoint-definition-requires-auth-p
   #:endpoint-definition-required-scopes
   #:endpoint-definition-cache-duration
   #:endpoint-definition-paginated-p
   #:endpoint-definition-alternate-routes
   #:endpoint-definition-deprecated-p
   #:endpoint-definition-tags

   ;; Parameter definition structure
   #:parameter-definition
   #:make-parameter-definition
   #:parameter-definition-name
   #:parameter-definition-cl-name
   #:parameter-definition-location
   #:parameter-definition-required-p
   #:parameter-definition-description
   #:parameter-definition-schema
   #:parameter-definition-default-value
   #:parameter-definition-enum-values

   ;; Main processing entry points
   #:fetch-and-process-esi-spec
   #:process-raw-spec
   #:download-esi-spec
   #:load-cached-spec

   ;; Spec querying
   #:find-endpoint-by-id
   #:find-endpoints-by-category
   #:find-endpoints-by-method
   #:find-authenticated-endpoints
   #:find-public-endpoints
   #:find-paginated-endpoints
   
   ;; Type generation
   #:generate-cl-type-definitions
   #:generate-response-type-map

   ;; Spec reporting
   #:spec-summary
   #:validate-esi-spec
   #:compare-spec-versions
   #:spec-version-summary

   ;; --- Validation (Phase 2 Task 2) ---
   ;; Configuration
   #:*validate-parameters-p*
   #:*coerce-parameters-p*
   
   ;; Validation result
   #:validation-result
   #:make-validation-result
   #:validation-result-valid-p
   #:validation-result-errors
   #:validation-result-coerced-values
   
   ;; Validation functions
   #:validate-api-parameters
   #:validate-parameter-value
   #:validate-value-against-schema
   #:validate-required-parameters
   
   ;; Type coercion
   #:coerce-parameter-value
   #:coerce-to-integer
   #:coerce-to-number
   #:coerce-to-string
   #:coerce-to-boolean
   
   ;; Parameter formatting
   #:format-parameter-for-request
   #:format-scalar-for-url
   #:extract-path-parameter-values
   #:extract-query-parameter-values
   #:substitute-path-parameters
   
   ;; Validation form generation
   #:generate-validation-form
   
   ;; --- Templates (Phase 2 Task 2) ---
   ;; Configuration
   #:*generated-function-package*
   #:*include-deprecation-warnings*
   #:*include-inline-validation*
   #:*default-page-limit*
   
   ;; Function form generation
   #:generate-endpoint-function-form
   #:generate-lambda-list
   #:generate-docstring
   #:generate-function-body
   
   ;; Batch generation
   #:generate-category-forms
   #:generate-all-function-forms
   #:generate-category-file-form
   
   ;; File writing
   #:write-generated-form
   #:write-generated-file
   
   ;; Change detection
   #:endpoint-signature
   #:category-signature
   
   ;; Naming utilities
   #:endpoint-to-symbol
   #:category-package-name
   
   ;; --- Code generator (Phase 2 Task 2) ---
   ;; Configuration
   #:*generated-code-directory*
   
   ;; Main entry points
   #:generate-api-functions
   #:generate-category-api
   #:generate-endpoint-function
   #:generate-type-definitions
   #:generate-client-code
   
   ;; Endpoint registry generation
   #:generate-endpoint-registry-file
   
   ;; Response types generation
   #:generate-response-types-file
   #:parse-endpoint-response
   
   ;; Generation report
   #:generation-report
   #:make-generation-report
   #:generation-report-total-endpoints
   #:generation-report-total-categories
   #:generation-report-functions-generated
   #:generation-report-categories-generated
   #:generation-report-files-written
   #:generation-report-spec-version
   #:generation-report-generated-at
   #:print-generation-report
   
   ;; REPL utilities
   #:show-generated-function
   #:show-category-functions
   #:generation-statistics
   
    ;; --- API client ---
    #:api-client
    #:make-api-client
    #:api-call
    #:api-get #:api-post #:api-put #:api-delete
    
    ;; --- Endpoint registry ---
    #:register-endpoint
    #:find-endpoint
    #:list-endpoints
    
    ;; --- Generated endpoint registry data (Phase 2 Task 3) ---
    #:*endpoint-registry*
    #:populate-endpoint-registry
    #:lookup-endpoint
    #:list-endpoints-by-category
    
    ;; --- Generated response types (Phase 2 Task 3) ---
    #:*response-type-map*
    #:populate-response-types
    #:parse-endpoint-response
    #:coerce-response-data
    
    ;; --- Generated ESI API functions (Phase 2 Task 3) ---
    ;; 195 endpoint functions across 20 ESI categories
    
    ;; Alliances (6 functions)
    #:get-alliances
    #:get-alliances-alliance-id
    #:get-alliances-alliance-id-contacts
    #:get-alliances-alliance-id-contacts-labels
    #:get-alliances-alliance-id-corporations
    #:get-alliances-alliance-id-icons
    
    ;; Characters (63 functions)
    #:delete-characters-character-id-contacts
    #:delete-characters-character-id-fittings-fitting-id
    #:delete-characters-character-id-mail-labels-label-id
    #:delete-characters-character-id-mail-mail-id
    #:get-characters-character-id
    #:get-characters-character-id-agents-research
    #:get-characters-character-id-assets
    #:get-characters-character-id-attributes
    #:get-characters-character-id-blueprints
    #:get-characters-character-id-calendar
    #:get-characters-character-id-calendar-event-id
    #:get-characters-character-id-calendar-event-id-attendees
    #:get-characters-character-id-clones
    #:get-characters-character-id-contacts
    #:get-characters-character-id-contacts-labels
    #:get-characters-character-id-contracts
    #:get-characters-character-id-contracts-contract-id-bids
    #:get-characters-character-id-contracts-contract-id-items
    #:get-characters-character-id-corporationhistory
    #:get-characters-character-id-fatigue
    #:get-characters-character-id-fittings
    #:get-characters-character-id-fleet
    #:get-characters-character-id-fw-stats
    #:get-characters-character-id-implants
    #:get-characters-character-id-industry-jobs
    #:get-characters-character-id-killmails-recent
    #:get-characters-character-id-location
    #:get-characters-character-id-loyalty-points
    #:get-characters-character-id-mail
    #:get-characters-character-id-mail-labels
    #:get-characters-character-id-mail-lists
    #:get-characters-character-id-mail-mail-id
    #:get-characters-character-id-medals
    #:get-characters-character-id-mining
    #:get-characters-character-id-notifications
    #:get-characters-character-id-notifications-contacts
    #:get-characters-character-id-online
    #:get-characters-character-id-orders
    #:get-characters-character-id-orders-history
    #:get-characters-character-id-planets
    #:get-characters-character-id-planets-planet-id
    #:get-characters-character-id-portrait
    #:get-characters-character-id-roles
    #:get-characters-character-id-search
    #:get-characters-character-id-ship
    #:get-characters-character-id-skillqueue
    #:get-characters-character-id-skills
    #:get-characters-character-id-standings
    #:get-characters-character-id-titles
    #:get-characters-character-id-wallet
    #:get-characters-character-id-wallet-journal
    #:get-characters-character-id-wallet-transactions
    #:post-characters-affiliation
    #:post-characters-character-id-assets-locations
    #:post-characters-character-id-assets-names
    #:post-characters-character-id-contacts
    #:post-characters-character-id-cspa
    #:post-characters-character-id-fittings
    #:post-characters-character-id-mail
    #:post-characters-character-id-mail-labels
    #:put-characters-character-id-calendar-event-id
    #:put-characters-character-id-contacts
    #:put-characters-character-id-mail-mail-id
    
    ;; Contracts (3 functions)
    #:get-contracts-public-bids-contract-id
    #:get-contracts-public-items-contract-id
    #:get-contracts-public-region-id
    
    ;; Corporation - mining (3 functions)
    #:get-corporation-corporation-id-mining-extractions
    #:get-corporation-corporation-id-mining-observers
    #:get-corporation-corporation-id-mining-observers-observer-id
    
    ;; Corporations (39 functions)
    #:get-corporations-corporation-id
    #:get-corporations-corporation-id-alliancehistory
    #:get-corporations-corporation-id-assets
    #:get-corporations-corporation-id-blueprints
    #:get-corporations-corporation-id-contacts
    #:get-corporations-corporation-id-contacts-labels
    #:get-corporations-corporation-id-containers-logs
    #:get-corporations-corporation-id-contracts
    #:get-corporations-corporation-id-contracts-contract-id-bids
    #:get-corporations-corporation-id-contracts-contract-id-items
    #:get-corporations-corporation-id-customs-offices
    #:get-corporations-corporation-id-divisions
    #:get-corporations-corporation-id-facilities
    #:get-corporations-corporation-id-fw-stats
    #:get-corporations-corporation-id-icons
    #:get-corporations-corporation-id-industry-jobs
    #:get-corporations-corporation-id-killmails-recent
    #:get-corporations-corporation-id-medals
    #:get-corporations-corporation-id-medals-issued
    #:get-corporations-corporation-id-members
    #:get-corporations-corporation-id-members-limit
    #:get-corporations-corporation-id-members-titles
    #:get-corporations-corporation-id-membertracking
    #:get-corporations-corporation-id-orders
    #:get-corporations-corporation-id-orders-history
    #:get-corporations-corporation-id-roles
    #:get-corporations-corporation-id-roles-history
    #:get-corporations-corporation-id-shareholders
    #:get-corporations-corporation-id-standings
    #:get-corporations-corporation-id-starbases
    #:get-corporations-corporation-id-starbases-starbase-id
    #:get-corporations-corporation-id-structures
    #:get-corporations-corporation-id-titles
    #:get-corporations-corporation-id-wallets
    #:get-corporations-corporation-id-wallets-division-journal
    #:get-corporations-corporation-id-wallets-division-transactions
    #:get-corporations-npccorps
    #:post-corporations-corporation-id-assets-locations
    #:post-corporations-corporation-id-assets-names
    
    ;; Dogma (5 functions)
    #:get-dogma-attributes
    #:get-dogma-attributes-attribute-id
    #:get-dogma-dynamic-items-type-id-item-id
    #:get-dogma-effects
    #:get-dogma-effects-effect-id
    
    ;; Fleets (13 functions)
    #:delete-fleets-fleet-id-members-member-id
    #:delete-fleets-fleet-id-squads-squad-id
    #:delete-fleets-fleet-id-wings-wing-id
    #:get-fleets-fleet-id
    #:get-fleets-fleet-id-members
    #:get-fleets-fleet-id-wings
    #:post-fleets-fleet-id-members
    #:post-fleets-fleet-id-wings
    #:post-fleets-fleet-id-wings-wing-id-squads
    #:put-fleets-fleet-id
    #:put-fleets-fleet-id-members-member-id
    #:put-fleets-fleet-id-squads-squad-id
    #:put-fleets-fleet-id-wings-wing-id
    
    ;; Faction Warfare (6 functions)
    #:get-fw-leaderboards
    #:get-fw-leaderboards-characters
    #:get-fw-leaderboards-corporations
    #:get-fw-stats
    #:get-fw-systems
    #:get-fw-wars
    
    ;; Incursions (1 function)
    #:get-incursions
    
    ;; Industry (2 functions)
    #:get-industry-facilities
    #:get-industry-systems
    
    ;; Insurance (1 function)
    #:get-insurance-prices
    
    ;; Killmails (1 function)
    #:get-killmails-killmail-id-killmail-hash
    
    ;; Loyalty (1 function)
    #:get-loyalty-stores-corporation-id-offers
    
    ;; Markets (7 functions)
    #:get-markets-groups
    #:get-markets-groups-market-group-id
    #:get-markets-prices
    #:get-markets-region-id-history
    #:get-markets-region-id-orders
    #:get-markets-region-id-types
    #:get-markets-structures-structure-id
    
    ;; Route (1 function)
    #:get-route-origin-destination
    
    ;; Sovereignty (3 functions)
    #:get-sovereignty-campaigns
    #:get-sovereignty-map
    #:get-sovereignty-structures
    
    ;; Status (1 function)
    #:get-status
    
    ;; UI (5 functions)
    #:post-ui-autopilot-waypoint
    #:post-ui-openwindow-contract
    #:post-ui-openwindow-information
    #:post-ui-openwindow-marketdetails
    #:post-ui-openwindow-newmail
    
    ;; Universe (31 functions)
    #:get-universe-ancestries
    #:get-universe-asteroid-belts-asteroid-belt-id
    #:get-universe-bloodlines
    #:get-universe-categories
    #:get-universe-categories-category-id
    #:get-universe-constellations
    #:get-universe-constellations-constellation-id
    #:get-universe-factions
    #:get-universe-graphics
    #:get-universe-graphics-graphic-id
    #:get-universe-groups
    #:get-universe-groups-group-id
    #:get-universe-moons-moon-id
    #:get-universe-planets-planet-id
    #:get-universe-races
    #:get-universe-regions
    #:get-universe-regions-region-id
    #:get-universe-schematics-schematic-id
    #:get-universe-stargates-stargate-id
    #:get-universe-stars-star-id
    #:get-universe-stations-station-id
    #:get-universe-structures
    #:get-universe-structures-structure-id
    #:get-universe-system-jumps
    #:get-universe-system-kills
    #:get-universe-systems
    #:get-universe-systems-system-id
    #:get-universe-types
    #:get-universe-types-type-id
    #:post-universe-ids
    #:post-universe-names
    
    ;; Wars (3 functions)
    #:get-wars
    #:get-wars-war-id
    #:get-wars-war-id-killmails))

(defpackage #:eve-gate.concurrent
  (:use #:cl #:alexandria #:eve-gate.utils #:eve-gate.types 
        #:eve-gate.core #:eve-gate.auth #:eve-gate.cache #:eve-gate.api)
  (:import-from #:bordeaux-threads)
  (:import-from #:cl-ppcre)
  (:import-from #:lparallel)
  (:export
   ;; --- Token bucket (rate-limiter.lisp) ---
   #:token-bucket
   #:make-token-bucket
   #:bucket-try-acquire
   #:bucket-acquire
   #:bucket-tokens-available
   #:bucket-status
   
   ;; --- ESI rate limiter (rate-limiter.lisp) ---
   #:esi-rate-limiter
   #:make-esi-rate-limiter
   #:configure-endpoint-rate
   #:rate-limit-acquire
   #:rate-limit-status
   #:rate-limiter-record-response
   #:rate-limiter-statistics
   #:reset-rate-limiter-stats
   #:error-backoff-remaining
   #:*default-esi-rate-configs*
   #:*default-character-rate-limit*
   #:*default-character-burst*
   
   ;; --- Request queue (request-queue.lisp) ---
   ;; Priority constants
   #:+priority-critical+
   #:+priority-high+
   #:+priority-normal+
   #:+priority-low+
   #:+priority-bulk+
   
   ;; Queued request
   #:queued-request
   #:make-queued-request
   #:queued-request-id
   #:queued-request-priority
   #:queued-request-path
   #:queued-request-method
   #:queued-request-params
   #:queued-request-character-id
   #:queued-request-complete-p
   #:queued-request-expired-p
   #:request-expired-p
   #:request-wait-time
   #:complete-request
   #:fail-request
   #:wait-for-request
   
   ;; Request queue
   #:request-queue
   #:make-request-queue
   #:enqueue-request
   #:dequeue-request
   #:pause-queue
   #:resume-queue
   #:shutdown-queue
   #:clear-queue
   #:queue-depth
   #:queue-statistics
   #:queue-status
   
   ;; --- Throttling (throttling.lisp) ---
   ;; Global instances
   #:*esi-rate-limiter*
   #:*esi-request-queue*
   #:ensure-rate-limiter
   #:ensure-request-queue
   
   ;; Initialization
   #:initialize-throttling
   #:shutdown-throttling
   
   ;; Middleware constructors
   #:make-throttling-middleware
   #:make-response-tracking-middleware
   #:make-420-retry-middleware
   #:make-throttling-middleware-stack
   
   ;; Throttled client
   #:make-throttled-http-client
   
   ;; Status
   #:throttling-status
   #:throttling-healthy-p
   
   ;; --- Concurrent engine (engine.lisp) ---
   #:concurrent-engine
   #:make-concurrent-engine
   #:start-engine
   #:stop-engine
   
   ;; Request submission
   #:submit-request
   #:submit-and-wait
   #:bulk-submit
   #:bulk-submit-and-wait
   
   ;; Convenience functions
   #:fetch-all-pages
   #:fetch-multiple-ids
   
   ;; Metrics
   #:engine-metrics
   #:engine-status
   #:reset-engine-metrics
   
   ;; --- Parallel executor (parallel-executor.lisp) ---
   ;; Kernel management
   #:*parallel-kernel*
   #:ensure-parallel-kernel
   #:shutdown-parallel-kernel
   #:with-parallel-kernel
   
   ;; Parallel operations
   #:parallel-fetch
   #:parallel-map-ids
   #:parallel-fetch-all-pages
   
   ;; Request deduplication
   #:dedup-cache
   #:make-dedup-cache
   #:initialize-dedup-cache
   #:dedup-fetch
   #:dedup-statistics
   #:*dedup-cache*
   
   ;; Utilities
   #:compute-chunk-size
   #:partition-list
   #:atomic-counter
   #:make-atomic-counter
   #:atomic-counter-increment
   #:atomic-counter-value-of
   
   ;; --- Worker pool (worker-pool.lisp) ---
   ;; Worker pool
   #:worker-pool
   #:make-worker-pool
   #:start-pool
   #:stop-pool
   #:pool-submit
   #:pool-submit-and-wait
   #:check-pool-scaling
   #:check-worker-health
   #:pool-metrics
   
   ;; Pool manager
   #:pool-manager
   #:make-pool-manager
   #:start-pool-manager
   #:stop-pool-manager
   #:get-pool
   #:manager-submit
   #:pool-manager-status
   
   ;; --- Bulk operations (bulk-operations.lisp) ---
   #:bulk-get
   #:bulk-post
   #:bulk-process
   #:with-bulk-processing
   #:bulk-expand-ids
   #:bulk-fetch-paginated
   
   ;; --- Parallel client (parallel-client.lisp) ---
   #:parallel-client
   #:make-parallel-client
   #:start-parallel-client
   #:stop-parallel-client
   #:with-parallel-client
   #:parallel-api-call
   #:parallel-bulk-fetch
   #:parallel-fetch-by-ids
   #:parallel-fetch-pages
   #:parallel-client-status
   #:parallel-client-metrics
   
   ;; --- Job queue (job-queue.lisp) ---
   ;; Job
   #:job
   #:make-job
   #:job-id
   #:job-name
   #:job-status
   #:job-result
   #:job-error
   #:job-complete-p
   #:job-runnable-p
   #:complete-job
   #:fail-job
   #:cancel-job
   #:wait-for-job
   #:job-elapsed-time
   
   ;; Job queue
   #:job-queue
   #:make-job-queue
   #:enqueue-job
   #:process-jobs
   #:stop-job-processing
   #:job-status-query
   #:job-queue-status))

(defpackage #:eve-gate
  (:use #:cl #:alexandria)
  (:import-from #:eve-gate.utils
                #:*log-level* #:log-info #:log-error
                #:load-config #:get-config-value)
  (:import-from #:eve-gate.types
                #:character-id #:corporation-id #:alliance-id
                #:api-response #:make-api-response)
  (:import-from #:eve-gate.core
                #:make-http-client #:http-request
                #:*default-timeout* #:*esi-base-url*)
  (:import-from #:eve-gate.auth
                #:make-oauth-client #:get-authorization-url
                #:exchange-code-for-token #:refresh-access-token)
  (:import-from #:eve-gate.cache
                #:make-cache-manager #:with-caching)
  (:import-from #:eve-gate.api
                #:make-api-client #:api-call
                #:fetch-and-process-esi-spec #:generate-api-functions)
  (:import-from #:eve-gate.concurrent
                #:make-parallel-client #:bulk-get #:bulk-process)
  (:export
   ;; Main client interface
   #:eve-client
   #:make-eve-client
   #:authenticate-client
   #:configure-client
   
   ;; High-level API functions (will be generated)
   #:get-character-public-info
   #:get-character-portrait
   #:get-corporation-info
   #:get-alliance-info
   #:get-system-info
   #:get-station-info
   
   ;; Bulk operations
   #:get-multiple-characters
   #:get-multiple-corporations
   
   ;; Configuration and utilities
   #:*default-user-agent*
   #:*esi-base-url*
   #:with-client
   #:client-authenticated-p
   
   ;; Re-exported important types
   #:character-id #:corporation-id #:alliance-id
   #:api-response
   
   ;; Re-exported conditions
   #:esi-error #:esi-unauthorized #:esi-rate-limit-exceeded))

;; Nickname package for convenience
(defpackage #:eve
  (:use #:eve-gate)
  (:export #:make-eve-client #:authenticate-client #:with-client))