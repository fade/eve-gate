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
  (:export
   ;; ESI specific types
   #:character-id
   #:corporation-id
   #:alliance-id
   #:region-id
   #:system-id
   #:station-id
   #:type-id
   
   ;; Response types
   #:api-response
   #:make-api-response
   #:api-response-data
   #:api-response-status
   #:api-response-headers
   #:api-response-etag
   
   ;; Error types
   #:api-error
   #:authentication-error
   #:rate-limit-error
   #:network-error
   #:cache-error))

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
  (:export
   ;; Cache protocols
   #:cache-get
   #:cache-put
   #:cache-delete
   #:cache-exists-p
   #:cache-clear
   
   ;; ETag caching
   #:etag-cache
   #:make-etag-cache
   #:etag-cache-get
   #:etag-cache-put
   
   ;; Memory cache
   #:memory-cache
   #:make-memory-cache
   
   ;; Database cache
   #:database-cache
   #:make-database-cache
   
   ;; Cache manager
   #:cache-manager
   #:make-cache-manager
   #:with-caching))

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
   
   ;; --- API client (Phase 2 Task 3 - stubs) ---
   #:api-client
   #:make-api-client
   #:api-call
   #:api-get #:api-post #:api-put #:api-delete
   
   ;; --- Endpoint registry (Phase 2 Task 3 - stubs) ---
   #:register-endpoint
   #:find-endpoint
   #:list-endpoints))

(defpackage #:eve-gate.concurrent
  (:use #:cl #:alexandria #:eve-gate.utils #:eve-gate.types 
        #:eve-gate.core #:eve-gate.auth #:eve-gate.cache #:eve-gate.api)
  (:export
   ;; Bulk operations
   #:bulk-get
   #:bulk-post
   #:bulk-process
   #:with-bulk-processing
   
   ;; Parallel client
   #:parallel-client
   #:make-parallel-client
   #:parallel-api-call
   
   ;; Job queue
   #:job-queue
   #:make-job-queue
   #:enqueue-job
   #:process-jobs
   #:job-status))

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