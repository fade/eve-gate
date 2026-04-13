;;;; configuration.lisp - Configuration management for eve-gate
;;;;
;;;; Provides a simple property-list based configuration system with
;;;; layered defaults, environment overrides, and runtime access.
;;;; Configuration is stored as a plist for simplicity and REPL-friendliness.
;;;;
;;;; Default configuration values are defined here as the canonical source.
;;;; The config/default.lisp file in the project root serves as documentation
;;;; and can be loaded interactively to reset defaults.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Default configuration values
;;; ---------------------------------------------------------------------------

(defparameter *default-config*
  '(;; ESI API Configuration
    :esi-base-url "https://esi.evetech.net"
    :esi-version "latest"
    :user-agent "eve-gate/0.1.0 (Common Lisp; +https://github.com/fade/eve-gate)"
    
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
  "Default configuration parameters for eve-gate.
All values can be overridden by environment-specific configs or user settings.")

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

;;; ---------------------------------------------------------------------------
;;; Configuration access
;;; ---------------------------------------------------------------------------

(defun get-config-value (key &optional (config *default-config*))
  "Retrieve a configuration value by KEY from CONFIG.
Returns the value associated with KEY, or NIL if not found.

KEY: A keyword symbol (e.g., :esi-base-url)
CONFIG: A property list of configuration values (default: *default-config*)

Example:
  (get-config-value :esi-base-url) => \"https://esi.evetech.net\"
  (get-config-value :default-timeout) => 30"
  (getf config key))

(defun set-config-value (key value &optional (config *default-config*))
  "Set a configuration value by KEY in CONFIG.
Modifies CONFIG destructively and returns the new value.

KEY: A keyword symbol  
VALUE: The new value to store
CONFIG: A property list (default: *default-config*)

Returns VALUE."
  (setf (getf config key) value)
  value)

(defun load-config (&key (base *default-config*) overlay environment)
  "Create a new configuration by merging BASE with OVERLAY and ENVIRONMENT settings.
Does not modify any existing configuration; returns a fresh plist.

BASE: Base configuration plist (default: *default-config*)
OVERLAY: Additional configuration plist to merge on top
ENVIRONMENT: One of :development, :production, or NIL

Returns a new property list with merged configuration.

Example:
  (load-config :environment :development)
  (load-config :overlay '(:log-level :debug :cache-enabled nil))"
  (let ((config (copy-list base)))
    ;; Apply environment-specific settings
    (when environment
      (let ((env-config (ecase environment
                          (:development *development-config*)
                          (:production *production-config*))))
        (loop for (key value) on env-config by #'cddr
              do (setf (getf config key) value))))
    ;; Apply explicit overlay settings last (highest priority)
    (when overlay
      (loop for (key value) on overlay by #'cddr
            do (setf (getf config key) value)))
    config))

(defun config-keys (config)
  "Return a list of all configuration keys in CONFIG.

CONFIG: A property list

Example:
  (config-keys '(:a 1 :b 2 :c 3)) => (:A :B :C)"
  (loop for (key) on config by #'cddr
        collect key))

(defun validate-config (config &key required-keys)
  "Validate that CONFIG contains all REQUIRED-KEYS with non-nil values.
Returns T if valid, signals an error otherwise.

CONFIG: A property list to validate
REQUIRED-KEYS: List of keyword symbols that must be present and non-nil

Example:
  (validate-config config :required-keys '(:client-id :client-secret))"
  (let ((missing (remove-if (lambda (key)
                              (getf config key))
                            required-keys)))
    (when missing
      (error "Missing required configuration keys: ~{~A~^, ~}" missing))
    t))
