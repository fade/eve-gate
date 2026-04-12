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
   ;; Conditions
   #:api-error
   #:authentication-error  
   #:rate-limit-exceeded
   #:network-timeout
   
   ;; HTTP client
   #:make-http-client
   #:http-request
   #:*default-timeout*
   #:*default-retries*
   
   ;; Middleware
   #:add-middleware
   #:remove-middleware
   #:with-middleware
   
   ;; Rate limiting
   #:make-rate-limiter
   #:rate-limit-acquire
   #:rate-limit-status))

(defpackage #:eve-gate.auth
  (:use #:cl #:alexandria #:eve-gate.utils #:eve-gate.types #:eve-gate.core)
  (:export
   ;; OAuth2 flow
   #:make-oauth-client
   #:get-authorization-url
   #:exchange-code-for-token
   #:refresh-access-token
   
   ;; Token management
   #:access-token
   #:refresh-token
   #:token-expires-at
   #:token-expired-p
   #:store-token
   #:load-token
   
   ;; Scopes
   #:*available-scopes*
   #:validate-scopes
   #:scope-required-p))

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
   ;; OpenAPI processing
   #:load-openapi-spec
   #:process-openapi-spec
   #:generate-api-functions
   
   ;; Code generation
   #:generate-endpoint-function
   #:generate-type-definitions
   #:generate-client-code
   
   ;; API client
   #:api-client
   #:make-api-client
   #:api-call
   #:api-get #:api-post #:api-put #:api-delete
   
   ;; Endpoint registry
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
                #:make-http-client #:*default-timeout*)
  (:import-from #:eve-gate.auth
                #:make-oauth-client #:get-authorization-url
                #:exchange-code-for-token #:refresh-access-token)
  (:import-from #:eve-gate.cache
                #:make-cache-manager #:with-caching)
  (:import-from #:eve-gate.api
                #:make-api-client #:api-call
                #:load-openapi-spec #:generate-api-functions)
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
   #:api-error #:authentication-error #:rate-limit-exceeded))

;; Nickname package for convenience
(defpackage #:eve
  (:use #:eve-gate)
  (:export #:make-eve-client #:authenticate-client #:with-client))