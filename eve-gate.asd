;; -*-lisp-*-
;;;; eve-gate.asd

(asdf:defsystem #:eve-gate
  :description "EVE Online ESI API client library - comprehensive Common Lisp interface"
  :author "Brian O'Reilly <fade@deepsky.com>"
  :license "GNU Affero GPL V.3 or later"
  :version "0.1.0"
  :depends-on (#:dexador          ; HTTP client
               #:com.inuoe.jzon   ; JSON processing
               #:alexandria       ; Common utilities
               #:local-time       ; Time handling
               #:cl-ppcre         ; Regular expressions
               #:bordeaux-threads ; Thread synchronization
               #:ciao)            ; OAuth 2.0 client
  :pathname "src/"
  :serial nil
  :components (;; Core package definitions
               (:file "packages")
               
               ;; Utilities (foundation layer)
               (:module "utils"
                :depends-on ("packages")
                :components
                ((:file "logging")
                 (:file "configuration")
                 (:file "string-utils")
                 (:file "time-utils")))
               
               ;; Type system
               (:module "types" 
                :depends-on ("packages" "utils")
                :components
                ((:file "esi-types")
                 (:file "response-types")
                 (:file "error-types")))
               
               ;; Core HTTP and authentication
                (:module "core"
                 :depends-on ("packages" "utils" "types")
                 :components
                 ((:file "conditions")
                  (:file "http-client")
                  (:file "middleware")
                  (:file "error-handling" :depends-on ("conditions" "middleware"))
                  (:file "rate-limiter")))
               
               ;; Authentication system
               (:module "auth"
                :depends-on ("packages" "utils" "types" "core")
                :serial t
                :components
                ((:file "scopes")
                 (:file "oauth2")
                 (:file "token-manager")))
               
               ;; Caching layer
               (:module "cache"
                :depends-on ("packages" "utils" "types" "core")
                :components
                ((:file "etag-cache")
                 (:file "memory-cache")
                 (:file "database-cache")
                 (:file "cache-manager")))
               
                ;; API generation and endpoints
                (:module "api"
                 :depends-on ("packages" "utils" "types" "core" "auth" "cache")
                 :components
                 ((:file "schema-parser")
                  (:file "spec-processor" :depends-on ("schema-parser"))
                  (:file "code-generator" :depends-on ("schema-parser" "spec-processor"))
                  (:file "endpoint-registry" :depends-on ("spec-processor"))
                  (:file "api-client" :depends-on ("endpoint-registry"))))
               
               ;; Concurrent operations
               (:module "concurrent"
                :depends-on ("packages" "utils" "types" "core" "auth" "cache" "api")
                :components
                ((:file "bulk-operations")
                 (:file "parallel-client")
                 (:file "job-queue")))
               
               ;; Main interface
               (:file "main" 
                :depends-on ("packages" "utils" "types" "core" "auth" "cache" "api" "concurrent")))
  
  :in-order-to ((test-op (test-op "eve-gate/tests"))))

;; Test system
(asdf:defsystem #:eve-gate/tests
  :description "Test suite for eve-gate"
  :author "Brian O'Reilly <fade@deepsky.com>"
  :license "GNU Affero GPL V.3 or later"
  :depends-on (#:eve-gate
               #:parachute      ; Testing framework
               #:mockingbird    ; Mocking library
               #:alexandria)
  :pathname "tests/"
  :serial nil
  :components (;; Unit tests
               (:module "unit"
                :components
                ((:file "test-utils")
                 (:file "test-http-client")
                 (:file "test-oauth2")
                 (:file "test-cache")
                 (:file "test-rate-limiter")
                 (:file "test-api-client")))
               
               ;; Integration tests
               (:module "integration"
                :components
                ((:file "test-esi-endpoints")
                 (:file "test-authentication-flow")
                 (:file "test-caching-workflow")
                 (:file "test-bulk-operations"))))
  :perform (test-op (o c) (symbol-call :parachute :test :eve-gate-tests)))

;; Development system (optional tools)
(asdf:defsystem #:eve-gate/dev
  :description "Development utilities for eve-gate"
  :author "Brian O'Reilly <fade@deepsky.com>"
  :license "GNU Affero GPL V.3 or later"
  :depends-on (#:eve-gate
               #:eve-gate/tests)
  :pathname "dev/"
  :components ((:file "repl-utils")
               (:file "benchmarks")
               (:file "debugging")))