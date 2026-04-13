;;;; test/integration.lisp - Integration tests for eve-gate
;;;;
;;;; End-to-end tests that verify component interactions without
;;;; requiring network access. Uses mock data and verifies the full
;;;; request/response pipeline.

(uiop:define-package #:eve-gate/test/integration
  (:use #:cl)
  (:import-from #:eve-gate.core
                ;; HTTP client
                #:make-http-client
                #:http-client-base-url
                #:http-client-user-agent
                ;; Middleware
                #:make-middleware
                #:make-middleware-stack
                #:add-middleware
                #:apply-request-middleware
                #:apply-response-middleware
                ;; Conditions
                #:esi-error
                #:esi-client-error
                #:esi-rate-limit-exceeded)
  (:import-from #:eve-gate.cache
                ;; Cache manager
                #:make-cache-manager
                #:cache-get
                #:cache-put
                #:cache-delete
                #:cache-exists-p
                #:cache-statistics
                ;; Memory cache
                #:make-memory-cache
                #:memory-cache-get
                #:memory-cache-put)
  (:import-from #:eve-gate.auth
                ;; OAuth client
                #:make-oauth-client
                #:get-authorization-url
                ;; Scopes
                #:valid-scope-p
                #:validate-scopes)
  (:import-from #:eve-gate.utils
                ;; Configuration
                #:load-config
                #:get-config-value
                ;; Logging
                #:*log-level*
                #:with-log-level)
  (:local-nicknames (#:t #:parachute)))

(in-package #:eve-gate/test/integration)

;;; HTTP Client + Middleware Integration Tests

(t:define-test http-client-initialization
  "Test HTTP client initializes with correct defaults"
  (let ((client (make-http-client)))
    (t:true client)
    (t:true (stringp (http-client-base-url client)))
    (t:true (search "esi.evetech.net" (http-client-base-url client)))
    (t:true (stringp (http-client-user-agent client)))))

(t:define-test middleware-stack-construction
  "Test middleware stack can be built and configured"
  (let* ((mw1 (make-middleware 
               :name :test1
               :priority 50
               :request-fn (lambda (ctx) ctx)))
         (mw2 (make-middleware 
               :name :test2
               :priority 60
               :request-fn (lambda (ctx) ctx)))
         (stack (make-middleware-stack mw1 mw2)))
    (t:true (listp stack))
    (t:is = 2 (length stack))))

(t:define-test middleware-request-processing
  "Test middleware processes requests correctly"
  (let* ((call-order '())
         (mw1 (make-middleware
               :name :first
               :priority 10
               :request-fn (lambda (ctx)
                            (push :first call-order)
                            ctx)))
         (mw2 (make-middleware
               :name :second
               :priority 20
               :request-fn (lambda (ctx)
                            (push :second call-order)
                            ctx)))
         (stack (make-middleware-stack mw1 mw2)))
    (apply-request-middleware stack '(:method :get :path "/test"))
    ;; Lower priority middleware (10) runs first, then higher (20)
    ;; push reverses order, so :second was pushed last (ran last)
    (t:is = 2 (length call-order))
    (t:is eq :second (first call-order))
    (t:is eq :first (second call-order))))

;;; Cache Integration Tests

(t:define-test cache-manager-lifecycle
  "Test cache manager creation and basic operations"
  (let ((manager (make-cache-manager)))
    (t:true manager)
    ;; Put and get
    (cache-put manager "test-key" "test-value")
    (t:is string= "test-value" (cache-get manager "test-key"))
    ;; Exists check
    (t:true (cache-exists-p manager "test-key"))
    (t:false (cache-exists-p manager "nonexistent"))
    ;; Delete
    (cache-delete manager "test-key")
    (t:false (cache-exists-p manager "test-key"))))

(t:define-test cache-statistics-tracking
  "Test that cache tracks statistics"
  (let ((manager (make-cache-manager)))
    ;; Cause some cache activity
    (cache-put manager "key1" "value1")
    (cache-get manager "key1")  ; Hit
    (cache-get manager "key2")  ; Miss
    (let ((stats (cache-statistics manager)))
      (t:true (listp stats)))))

(t:define-test memory-cache-isolation
  "Test memory cache provides isolated storage"
  (let ((cache1 (make-memory-cache :max-entries 100))
        (cache2 (make-memory-cache :max-entries 100)))
    (memory-cache-put cache1 "key" "value1")
    (memory-cache-put cache2 "key" "value2")
    ;; Each cache has its own value
    (t:is string= "value1" (memory-cache-get cache1 "key"))
    (t:is string= "value2" (memory-cache-get cache2 "key"))))

;;; Authentication + Scope Integration Tests

(t:define-test oauth-scope-validation-integration
  "Test OAuth client validates scopes during creation"
  ;; Valid scopes work
  (t:finish 
   (make-oauth-client 
    :client-id "test-id"
    :client-secret "test-secret"
    :scopes '("esi-skills.read_skills.v1")))
  
  ;; Invalid scopes fail
  (t:fail
   (make-oauth-client
    :client-id "test-id"
    :client-secret "test-secret"
    :scopes '("invalid-scope"))
   'error))

(t:define-test authorization-url-contains-scopes
  "Test authorization URL includes requested scopes"
  (let* ((scopes '("esi-skills.read_skills.v1" 
                   "esi-wallet.read_character_wallet.v1"))
         (client (make-oauth-client
                  :client-id "test-id"
                  :client-secret "test-secret"
                  :scopes scopes))
         (url (get-authorization-url client)))
    ;; URL should contain scope parameter
    (t:true (search "scope" url))))

;;; Configuration + Subsystem Integration Tests

(t:define-test config-affects-http-client
  "Test configuration values can configure HTTP client"
  (let ((config (load-config :overlay '(:default-timeout 45))))
    (t:is = 45 (get-config-value :default-timeout config))))

(t:define-test environment-config-propagation
  "Test environment configs provide different settings"
  (let ((dev-config (load-config :environment :development))
        (prod-config (load-config :environment :production)))
    ;; Development has different settings than production
    (t:isnt eq 
            (get-config-value :log-level dev-config)
            (get-config-value :log-level prod-config))
    (t:isnt eq
            (get-config-value :debug-mode dev-config)
            (get-config-value :debug-mode prod-config))))

;;; Logging Integration Tests

(t:define-test logging-level-dynamic-binding
  "Test log level can be dynamically bound"
  (let ((outer-level *log-level*))
    (with-log-level (:debug)
      (t:is eq :debug *log-level*))
    ;; Restored after
    (t:is eq outer-level *log-level*)))

;;; Error Condition Integration Tests

(t:define-test error-hierarchy-integration
  "Test error conditions form proper hierarchy"
  ;; Client errors are ESI errors
  (t:true (subtypep 'esi-client-error 'esi-error))
  ;; Rate limit is a specific client error
  (t:true (subtypep 'esi-rate-limit-exceeded 'esi-client-error)))

(t:define-test error-condition-creation
  "Test error conditions can be created with appropriate data"
  (let ((err (make-condition 'esi-client-error
                             :status-code 400
                             :message "Bad request"
                             :endpoint "/test")))
    (t:true (typep err 'esi-error))
    (t:true (typep err 'esi-client-error))))

;;; Cache + Config Integration Tests

(t:define-test cache-respects-config
  "Test cache behavior respects configuration"
  (let* ((config (load-config :overlay '(:cache-enabled t
                                         :cache-default-ttl 600)))
         (cache-enabled (get-config-value :cache-enabled config))
         (cache-ttl (get-config-value :cache-default-ttl config)))
    (t:true cache-enabled)
    (t:is = 600 cache-ttl)))

;;; Full Pipeline Simulation Tests (without network)

(t:define-test request-context-propagation
  "Test request context flows through middleware"
  (let* ((context-seen nil)
         (mw (make-middleware
              :name :context-capture
              :priority 50
              :request-fn (lambda (ctx)
                           (setf context-seen ctx)
                           ctx)))
         (stack (make-middleware-stack mw)))
    (let ((result (apply-request-middleware 
                   stack 
                   '(:method :get 
                     :path "/characters/12345"
                     :headers (("User-Agent" . "test"))))))
      (t:true result)
      (t:true context-seen)
      (t:is eq :get (getf context-seen :method))
      (t:is string= "/characters/12345" (getf context-seen :path)))))

(t:define-test response-context-propagation
  "Test response flows back through middleware"
  (let* ((response-seen nil)
         (mw (make-middleware
              :name :response-capture
              :priority 50
              :response-fn (lambda (resp ctx)
                            (declare (ignore ctx))
                            (setf response-seen resp)
                            resp)))
         (stack (make-middleware-stack mw)))
    (let ((mock-response '(:status 200 :body "{\"name\": \"Test\"}")))
      (apply-response-middleware stack mock-response '())
      (t:true response-seen)
      (t:is = 200 (getf response-seen :status)))))

;;; Component Initialization Order Tests

(t:define-test subsystem-independence
  "Test subsystems can be created independently"
  ;; Each subsystem should initialize without the others
  (t:finish (make-http-client))
  (t:finish (make-memory-cache))
  (t:finish (make-cache-manager))
  (t:finish (load-config)))

;;; Thread Safety Smoke Tests

(t:define-test cache-thread-safety-basic
  "Basic thread safety test for cache operations"
  (let ((cache (make-memory-cache :max-entries 1000)))
    ;; Simple concurrent-ish operations (single thread but exercises locking)
    (loop for i from 1 to 100
          do (memory-cache-put cache (format nil "key-~D" i) i))
    (loop for i from 1 to 100
          do (t:is = i (memory-cache-get cache (format nil "key-~D" i))))))
