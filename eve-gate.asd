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
               #:lparallel        ; Parallel processing
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
                   (:file "log-output" :depends-on ("logging"))
                   (:file "esi-logger" :depends-on ("logging" "log-output"))
                   (:file "audit-logger" :depends-on ("logging"))
                   (:file "configuration")
                   (:file "config-sources" :depends-on ("configuration" "logging"))
                   (:file "config-integration" :depends-on ("configuration" "logging"))
                   (:file "config-manager" :depends-on ("configuration" "config-sources"
                                                        "config-integration" "logging"))
                   (:file "string-utils")
                   (:file "time-utils")
                   (:file "performance" :depends-on ("logging"))
                   (:file "memory-pool" :depends-on ("logging" "performance"))
                   (:file "debug-logger" :depends-on ("logging" "log-output" "performance"))
                   (:file "formats" :depends-on ("logging"))
                   (:file "data-privacy" :depends-on ("logging" "audit-logger"))
                   (:file "export" :depends-on ("logging" "audit-logger" "formats" "data-privacy"))
                   (:file "import" :depends-on ("logging" "audit-logger" "formats" "data-privacy"))
                   (:file "data-ops" :depends-on ("logging" "audit-logger" "configuration"
                                                  "formats" "data-privacy" "export" "import"))))
               
                ;; Type system
                (:module "types" 
                 :depends-on ("packages" "utils")
                 :components
                 ((:file "esi-types")
                  (:file "validation" :depends-on ("esi-types"))
                  (:file "conversion" :depends-on ("esi-types"))
                  (:file "response-types" :depends-on ("esi-types" "conversion"))
                  (:file "error-types" :depends-on ("esi-types"))))
               
               ;; Core HTTP and authentication
                 (:module "core"
                  :depends-on ("packages" "utils" "types")
                  :components
                  ((:file "conditions")
                   (:file "http-client")
                   (:file "middleware")
                   (:file "error-handling" :depends-on ("conditions" "middleware"))
                   (:file "rate-limiter")
                   (:file "connection-pool" :depends-on ("http-client" "middleware"))))
               
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
                ((:file "memory-cache")
                 (:file "etag-cache")
                 (:file "database-cache")
                 (:file "policies" :depends-on ("memory-cache" "etag-cache" "database-cache"))
                 (:file "cache-manager" :depends-on ("memory-cache" "etag-cache"
                                                     "database-cache" "policies"))))
               
                 ;; API generation and endpoints
                 (:module "api"
                  :depends-on ("packages" "utils" "types" "core" "auth" "cache")
                  :components
                  ((:file "schema-parser")
                   (:file "spec-processor" :depends-on ("schema-parser"))
                   (:file "validation" :depends-on ("schema-parser" "spec-processor"))
                   (:file "templates" :depends-on ("schema-parser" "spec-processor" "validation"))
                   (:file "code-generator" :depends-on ("schema-parser" "spec-processor"
                                                        "validation" "templates"))
                   (:file "endpoint-registry" :depends-on ("spec-processor"))
                   (:file "api-client" :depends-on ("endpoint-registry"))
                   ;; Generated ESI API functions (Phase 2 Task 3)
                   ;; 195 endpoint functions organized by ESI category
                   (:module "generated"
                    :depends-on ("schema-parser" "spec-processor" "validation"
                                 "templates" "code-generator" "endpoint-registry" "api-client")
                    :components
                    (;; Infrastructure files
                     (:file "endpoint-registry-data")
                     (:file "response-types")
                     ;; Category files (alphabetical, 20 ESI categories)
                     (:file "alliances")
                     (:file "characters")
                     (:file "contracts")
                     (:file "corporation")
                     (:file "corporations")
                     (:file "dogma")
                     (:file "fleets")
                     (:file "fw")
                     (:file "incursions")
                     (:file "industry")
                     (:file "insurance")
                     (:file "killmails")
                     (:file "loyalty")
                     (:file "markets")
                     (:file "route")
                     (:file "sovereignty")
                     (:file "status")
                     (:file "ui")
                     (:file "universe")
                     (:file "wars")))))
               
                ;; Concurrent operations
                (:module "concurrent"
                 :depends-on ("packages" "utils" "types" "core" "auth" "cache" "api")
                 :components
                 ((:file "rate-limiter")
                  (:file "request-queue" :depends-on ("rate-limiter"))
                  (:file "throttling" :depends-on ("rate-limiter" "request-queue"))
                  (:file "engine" :depends-on ("rate-limiter" "request-queue" "throttling"))
                  (:file "parallel-executor" :depends-on ("engine"))
                  (:file "worker-pool" :depends-on ("engine"))
                  (:file "bulk-operations" :depends-on ("engine" "parallel-executor"))
                  (:file "parallel-client" :depends-on ("engine" "parallel-executor"
                                                        "bulk-operations"))
                  (:file "job-queue" :depends-on ("engine"))))
               
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
                  (:file "test-characters-api" :depends-on ("test-utils"))
                  (:file "test-generated-api" :depends-on ("test-utils")))))
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
               (:file "benchmarks" :depends-on ("repl-utils"))
               (:file "debugging" :depends-on ("repl-utils"))))