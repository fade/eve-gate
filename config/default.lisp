;;;; default.lisp - Default configuration for eve-gate

(in-package #:eve-gate.utils)

(defparameter *default-config*
  '(;; ESI API Configuration
    :esi-base-url "https://esi.evetech.net"
    :esi-version "latest"
    :user-agent "eve-gate/0.1.0 (Common Lisp; https://github.com/fade/eve-gate)"
    
    ;; HTTP Client Settings
    :default-timeout 30
    :default-retries 3
    :connect-timeout 10
    :read-timeout 30
    
    ;; Authentication
    :oauth-authorize-url "https://login.eveonline.com/v2/oauth/authorize/"
    :oauth-token-url "https://login.eveonline.com/v2/oauth/token/"
    :oauth-verify-url "https://login.eveonline.com/oauth/verify"
    :client-id nil              ; Must be set by user
    :client-secret nil          ; Must be set by user
    :redirect-uri nil           ; Must be set by user
    
    ;; Rate Limiting (ESI Guidelines)
    :error-limit-per-window 100
    :error-limit-window 60      ; seconds
    :burst-size 150             ; requests
    :sustained-rate 20          ; requests per second
    
    ;; Caching
    :cache-enabled t
    :cache-default-ttl 300      ; 5 minutes
    :etag-cache-size 10000      ; entries
    :memory-cache-size 1000     ; entries
    
    ;; Database (optional)
    :database-url nil           ; "postgresql://user:pass@host/db"
    :database-pool-size 5
    
    ;; Logging
    :log-level :info            ; :debug :info :warn :error
    :log-format :simple         ; :simple :structured :json
    :log-destination :stdout    ; :stdout :file :syslog
    
    ;; Concurrent Processing
    :worker-threads 4
    :bulk-batch-size 50
    :queue-max-size 1000
    
    ;; Development/Debug
    :debug-mode nil
    :mock-responses nil
    :request-logging nil
    :response-logging nil
    
    ;; Performance
    :connection-pool-size 10
    :keep-alive-timeout 30
    :dns-cache-ttl 300)
  "Default configuration parameters for eve-gate.")

;; Environment-specific overrides
(defparameter *development-config*
  '(:log-level :debug
    :debug-mode t
    :request-logging t
    :response-logging t
    :cache-enabled nil
    :mock-responses t)
  "Development environment configuration overrides.")

(defparameter *production-config*
  '(:log-level :warn
    :debug-mode nil
    :request-logging nil
    :response-logging nil
    :cache-enabled t
    :mock-responses nil)
  "Production environment configuration overrides.")