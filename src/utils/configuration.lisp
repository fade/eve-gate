;;;; configuration.lisp - Configuration schema, validation, and core access for eve-gate
;;;;
;;;; Provides the configuration foundation: schema definitions with type checking,
;;;; constraint validation, environment-based configuration profiles, and the
;;;; core access/merge functions. This is the "data model" layer of configuration.
;;;;
;;;; The configuration system is layered:
;;;;   1. Schema definitions (this file) - what keys exist, their types, constraints
;;;;   2. Config sources (config-sources.lisp) - where values come from
;;;;   3. Config integration (config-integration.lisp) - how subsystems consume config
;;;;   4. Config manager (config-manager.lisp) - orchestration, hot-reload, registry
;;;;
;;;; Configuration values are stored as plists for simplicity, REPL-friendliness,
;;;; and zero-dependency access. The schema overlay provides type safety and
;;;; validation without changing the storage format.
;;;;
;;;; Thread safety: Configuration reads are lock-free (plist reads are atomic
;;;; for individual keys). Configuration writes go through the config-manager
;;;; which coordinates locking.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Configuration schema definition
;;; ---------------------------------------------------------------------------

(defstruct (config-schema-entry (:constructor make-config-schema-entry))
  "Schema definition for a single configuration key.

Slots:
  KEY: The configuration keyword (e.g., :esi-base-url)
  TYPE: Expected Common Lisp type specifier
  DEFAULT: Default value
  DESCRIPTION: Human-readable description
  CATEGORY: Grouping category keyword (e.g., :http, :auth, :cache)
  VALIDATOR: Optional function (value) -> T/NIL for custom validation
  REQUIRED-P: Whether this key must have a non-NIL value in production
  HOT-RELOAD-P: Whether this key can be safely changed at runtime
  ENV-VAR: Environment variable name to read (e.g., \"EVE_GATE_ESI_BASE_URL\")
  CONSTRAINTS: Plist of constraints (:min :max :one-of :pattern etc.)"
  (key nil :type keyword)
  (type t :type (or symbol cons))
  (default nil)
  (description "" :type string)
  (category :general :type keyword)
  (validator nil :type (or null function))
  (required-p nil :type boolean)
  (hot-reload-p nil :type boolean)
  (env-var nil :type (or null string))
  (constraints nil :type list))

(defparameter *config-schema* (make-hash-table :test 'eq)
  "Hash table mapping configuration keywords to their schema entries.
Populated by DEFINE-CONFIG-KEY forms at load time.")

(defmacro define-config-key (key &key type default description
                                      (category :general)
                                      validator required-p hot-reload-p
                                      env-var constraints)
  "Define a configuration key with its schema metadata.

KEY: Configuration keyword
TYPE: CL type specifier for the value
DEFAULT: Default value
DESCRIPTION: Human-readable documentation string
CATEGORY: Grouping category for this key
VALIDATOR: Optional custom validation function
REQUIRED-P: Whether this must be non-NIL for production
HOT-RELOAD-P: Whether runtime changes are safe
ENV-VAR: Environment variable to read
CONSTRAINTS: Plist of additional constraints (:min :max :one-of :pattern)"
  `(setf (gethash ,key *config-schema*)
         (make-config-schema-entry
          :key ,key
          :type ',type
          :default ,default
          :description ,description
          :category ,category
          :validator ,validator
          :required-p ,required-p
          :hot-reload-p ,hot-reload-p
          :env-var ,env-var
          :constraints ',constraints)))

;;; ---------------------------------------------------------------------------
;;; Configuration schema definitions - ESI API
;;; ---------------------------------------------------------------------------

(define-config-key :esi-base-url
  :type string
  :default "https://esi.evetech.net"
  :description "Base URL for the EVE Swagger Interface"
  :category :esi
  :env-var "EVE_GATE_ESI_BASE_URL"
  :hot-reload-p nil)

(define-config-key :esi-version
  :type string
  :default "latest"
  :description "ESI API version to use (latest, dev, legacy)"
  :category :esi
  :env-var "EVE_GATE_ESI_VERSION"
  :constraints (:one-of ("latest" "dev" "legacy" "v1" "v2" "v3" "v4" "v5" "v6"))
  :hot-reload-p nil)

(define-config-key :user-agent
  :type string
  :default "eve-gate/0.1.0 (Common Lisp; +https://github.com/fade/eve-gate)"
  :description "User-Agent header for ESI requests"
  :category :esi
  :env-var "EVE_GATE_USER_AGENT"
  :required-p t
  :hot-reload-p nil)

;;; ---------------------------------------------------------------------------
;;; Configuration schema definitions - HTTP Client
;;; ---------------------------------------------------------------------------

(define-config-key :default-timeout
  :type (integer 1 300)
  :default 30
  :description "Default HTTP request timeout in seconds"
  :category :http
  :env-var "EVE_GATE_TIMEOUT"
  :constraints (:min 1 :max 300)
  :hot-reload-p t)

(define-config-key :default-retries
  :type (integer 0 10)
  :default 3
  :description "Default number of retry attempts for transient failures"
  :category :http
  :env-var "EVE_GATE_RETRIES"
  :constraints (:min 0 :max 10)
  :hot-reload-p t)

(define-config-key :connect-timeout
  :type (integer 1 120)
  :default 10
  :description "TCP connection timeout in seconds"
  :category :http
  :env-var "EVE_GATE_CONNECT_TIMEOUT"
  :constraints (:min 1 :max 120)
  :hot-reload-p t)

(define-config-key :read-timeout
  :type (integer 1 300)
  :default 30
  :description "HTTP response read timeout in seconds"
  :category :http
  :env-var "EVE_GATE_READ_TIMEOUT"
  :constraints (:min 1 :max 300)
  :hot-reload-p t)

(define-config-key :connection-pool-size
  :type (integer 1 200)
  :default 10
  :description "Maximum connections in the HTTP connection pool"
  :category :http
  :env-var "EVE_GATE_POOL_SIZE"
  :constraints (:min 1 :max 200)
  :hot-reload-p nil)

(define-config-key :keep-alive-timeout
  :type (integer 1 600)
  :default 30
  :description "Keep-alive timeout for pooled connections in seconds"
  :category :http
  :constraints (:min 1 :max 600)
  :hot-reload-p t)

(define-config-key :dns-cache-ttl
  :type (integer 0 3600)
  :default 300
  :description "DNS resolution cache TTL in seconds (0 to disable)"
  :category :http
  :constraints (:min 0 :max 3600)
  :hot-reload-p t)

;;; ---------------------------------------------------------------------------
;;; Configuration schema definitions - Authentication
;;; ---------------------------------------------------------------------------

(define-config-key :oauth-authorize-url
  :type string
  :default "https://login.eveonline.com/v2/oauth/authorize/"
  :description "EVE SSO OAuth2 authorization endpoint"
  :category :auth
  :env-var "EVE_GATE_OAUTH_AUTH_URL"
  :hot-reload-p nil)

(define-config-key :oauth-token-url
  :type string
  :default "https://login.eveonline.com/v2/oauth/token/"
  :description "EVE SSO OAuth2 token endpoint"
  :category :auth
  :env-var "EVE_GATE_OAUTH_TOKEN_URL"
  :hot-reload-p nil)

(define-config-key :oauth-verify-url
  :type string
  :default "https://login.eveonline.com/oauth/verify"
  :description "EVE SSO token verification endpoint"
  :category :auth
  :env-var "EVE_GATE_OAUTH_VERIFY_URL"
  :hot-reload-p nil)

(define-config-key :client-id
  :type (or null string)
  :default nil
  :description "EVE SSO application Client ID"
  :category :auth
  :env-var "EVE_GATE_CLIENT_ID"
  :required-p nil
  :hot-reload-p nil)

(define-config-key :client-secret
  :type (or null string)
  :default nil
  :description "EVE SSO application Client Secret"
  :category :auth
  :env-var "EVE_GATE_CLIENT_SECRET"
  :required-p nil
  :hot-reload-p nil)

(define-config-key :redirect-uri
  :type (or null string)
  :default nil
  :description "OAuth2 redirect URI for callback"
  :category :auth
  :env-var "EVE_GATE_REDIRECT_URI"
  :hot-reload-p nil)

;;; ---------------------------------------------------------------------------
;;; Configuration schema definitions - Rate Limiting
;;; ---------------------------------------------------------------------------

(define-config-key :error-limit-per-window
  :type (integer 1 1000)
  :default 100
  :description "Maximum error responses per window before backoff"
  :category :rate-limiting
  :constraints (:min 1 :max 1000)
  :hot-reload-p t)

(define-config-key :error-limit-window
  :type (integer 1 600)
  :default 60
  :description "Error rate limit window in seconds"
  :category :rate-limiting
  :constraints (:min 1 :max 600)
  :hot-reload-p t)

(define-config-key :burst-size
  :type (integer 1 500)
  :default 150
  :description "Maximum burst request count"
  :category :rate-limiting
  :constraints (:min 1 :max 500)
  :hot-reload-p t)

(define-config-key :sustained-rate
  :type (integer 1 100)
  :default 20
  :description "Sustained requests per second"
  :category :rate-limiting
  :constraints (:min 1 :max 100)
  :hot-reload-p t)

;;; ---------------------------------------------------------------------------
;;; Configuration schema definitions - Caching
;;; ---------------------------------------------------------------------------

(define-config-key :cache-enabled
  :type boolean
  :default t
  :description "Enable/disable the caching subsystem"
  :category :cache
  :env-var "EVE_GATE_CACHE_ENABLED"
  :hot-reload-p t)

(define-config-key :cache-default-ttl
  :type (integer 0 86400)
  :default 300
  :description "Default cache TTL in seconds"
  :category :cache
  :constraints (:min 0 :max 86400)
  :hot-reload-p t)

(define-config-key :etag-cache-size
  :type (integer 100 1000000)
  :default 10000
  :description "Maximum entries in the ETag cache"
  :category :cache
  :constraints (:min 100 :max 1000000)
  :hot-reload-p nil)

(define-config-key :memory-cache-size
  :type (integer 100 1000000)
  :default 1000
  :description "Maximum entries in the memory cache"
  :category :cache
  :env-var "EVE_GATE_MEMORY_CACHE_SIZE"
  :constraints (:min 100 :max 1000000)
  :hot-reload-p nil)

;;; ---------------------------------------------------------------------------
;;; Configuration schema definitions - Database
;;; ---------------------------------------------------------------------------

(define-config-key :database-url
  :type (or null string)
  :default nil
  :description "Database connection URL (postgresql://user:pass@host/db)"
  :category :database
  :env-var "EVE_GATE_DATABASE_URL"
  :hot-reload-p nil)

(define-config-key :database-pool-size
  :type (integer 1 50)
  :default 5
  :description "Database connection pool size"
  :category :database
  :env-var "EVE_GATE_DB_POOL_SIZE"
  :constraints (:min 1 :max 50)
  :hot-reload-p nil)

;;; ---------------------------------------------------------------------------
;;; Configuration schema definitions - Logging
;;; ---------------------------------------------------------------------------

(define-config-key :log-level
  :type keyword
  :default :info
  :description "Minimum log level"
  :category :logging
  :env-var "EVE_GATE_LOG_LEVEL"
  :constraints (:one-of (:trace :debug :info :warn :error :fatal))
  :hot-reload-p t)

(define-config-key :log-format
  :type keyword
  :default :simple
  :description "Log output format"
  :category :logging
  :env-var "EVE_GATE_LOG_FORMAT"
  :constraints (:one-of (:simple :structured :json))
  :hot-reload-p t)

(define-config-key :log-destination
  :type keyword
  :default :stdout
  :description "Log output destination"
  :category :logging
  :env-var "EVE_GATE_LOG_DESTINATION"
  :constraints (:one-of (:stdout :file :syslog))
  :hot-reload-p t)

;;; ---------------------------------------------------------------------------
;;; Configuration schema definitions - Concurrent Processing
;;; ---------------------------------------------------------------------------

(define-config-key :worker-threads
  :type (integer 1 64)
  :default 4
  :description "Number of worker threads for concurrent operations"
  :category :concurrent
  :env-var "EVE_GATE_WORKER_THREADS"
  :constraints (:min 1 :max 64)
  :hot-reload-p nil)

(define-config-key :bulk-batch-size
  :type (integer 1 500)
  :default 50
  :description "Batch size for bulk operations"
  :category :concurrent
  :constraints (:min 1 :max 500)
  :hot-reload-p t)

(define-config-key :queue-max-size
  :type (integer 10 100000)
  :default 1000
  :description "Maximum request queue size"
  :category :concurrent
  :constraints (:min 10 :max 100000)
  :hot-reload-p nil)

;;; ---------------------------------------------------------------------------
;;; Configuration schema definitions - Development/Debug
;;; ---------------------------------------------------------------------------

(define-config-key :debug-mode
  :type boolean
  :default nil
  :description "Enable debug mode with additional diagnostics"
  :category :debug
  :env-var "EVE_GATE_DEBUG"
  :hot-reload-p t)

(define-config-key :mock-responses
  :type boolean
  :default nil
  :description "Return mock responses instead of real ESI calls"
  :category :debug
  :hot-reload-p t)

(define-config-key :request-logging
  :type boolean
  :default nil
  :description "Log all outgoing HTTP requests"
  :category :debug
  :hot-reload-p t)

(define-config-key :response-logging
  :type boolean
  :default nil
  :description "Log all incoming HTTP responses"
  :category :debug
  :hot-reload-p t)

;;; ---------------------------------------------------------------------------
;;; Default configuration values (backward-compatible plist)
;;; ---------------------------------------------------------------------------

(defun build-default-config-from-schema ()
  "Build a default configuration plist from all registered schema entries.
Returns a plist with all keys set to their schema-defined defaults."
  (let ((config '()))
    (maphash (lambda (key entry)
               (declare (ignore key))
               (setf (getf config (config-schema-entry-key entry))
                     (config-schema-entry-default entry)))
             *config-schema*)
    config))

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
    :client-id nil
    :client-secret nil
    :redirect-uri nil

    ;; Rate Limiting (ESI Guidelines)
    :error-limit-per-window 100
    :error-limit-window 60
    :burst-size 150
    :sustained-rate 20

    ;; Caching
    :cache-enabled t
    :cache-default-ttl 300
    :etag-cache-size 10000
    :memory-cache-size 1000

    ;; Database (optional)
    :database-url nil
    :database-pool-size 5

    ;; Logging
    :log-level :info
    :log-format :simple
    :log-destination :stdout

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

;;; ---------------------------------------------------------------------------
;;; Environment profiles
;;; ---------------------------------------------------------------------------

(defparameter *development-config*
  '(:log-level :debug
    :debug-mode t
    :request-logging t
    :response-logging t
    :cache-enabled nil
    :mock-responses t)
  "Development environment configuration overrides.")

(defparameter *staging-config*
  '(:log-level :debug
    :debug-mode nil
    :request-logging t
    :response-logging nil
    :cache-enabled t
    :mock-responses nil
    :worker-threads 2
    :connection-pool-size 5)
  "Staging environment configuration overrides.")

(defparameter *production-config*
  '(:log-level :warn
    :debug-mode nil
    :request-logging nil
    :response-logging nil
    :cache-enabled t
    :mock-responses nil
    :worker-threads 8
    :connection-pool-size 20)
  "Production environment configuration overrides.")

(defparameter *environment-configs*
  (list :development *development-config*
        :staging *staging-config*
        :production *production-config*)
  "Map of environment names to their configuration overlays.")

(defvar *current-environment* nil
  "The currently active environment profile, or NIL for unset.
Set via LOAD-CONFIG or SET-ENVIRONMENT.")

;;; ---------------------------------------------------------------------------
;;; Configuration validation
;;; ---------------------------------------------------------------------------

(define-condition config-validation-error (error)
  ((key :initarg :key :reader config-validation-error-key)
   (value :initarg :value :reader config-validation-error-value)
   (reason :initarg :reason :reader config-validation-error-reason)
   (expected :initarg :expected :reader config-validation-error-expected
             :initform nil))
  (:report (lambda (condition stream)
             (format stream "Configuration error for ~A: ~A~@[ (value: ~S, expected: ~A)~]"
                     (config-validation-error-key condition)
                     (config-validation-error-reason condition)
                     (config-validation-error-value condition)
                     (config-validation-error-expected condition)))))

(define-condition config-missing-error (config-validation-error)
  ()
  (:report (lambda (condition stream)
             (format stream "Required configuration key ~A is missing or NIL"
                     (config-validation-error-key condition)))))

(defun validate-config-value (key value)
  "Validate a single configuration VALUE against its schema for KEY.
Returns T if valid. Signals CONFIG-VALIDATION-ERROR if invalid.
Returns T without error if no schema entry exists for KEY (permissive mode).

KEY: Configuration keyword
VALUE: The value to validate"
  (let ((schema (gethash key *config-schema*)))
    (unless schema
      ;; No schema entry - allow unregistered keys for extensibility
      (return-from validate-config-value t))
    ;; NIL is allowed for optional keys; required-p is checked separately
    (when (null value)
      (return-from validate-config-value t))
    ;; Type check
    (unless (typep value (config-schema-entry-type schema))
      (error 'config-validation-error
             :key key
             :value value
             :reason "Type mismatch"
             :expected (config-schema-entry-type schema)))
    ;; Constraint checks
    (let ((constraints (config-schema-entry-constraints schema)))
      (when constraints
        (validate-config-constraints key value constraints)))
    ;; Custom validator
    (when-let ((validator (config-schema-entry-validator schema)))
      (unless (funcall validator value)
        (error 'config-validation-error
               :key key
               :value value
               :reason "Custom validation failed")))
    t))

(defun validate-config-constraints (key value constraints)
  "Validate VALUE against the CONSTRAINTS plist for configuration KEY.

Supported constraints:
  :MIN - Minimum numeric value
  :MAX - Maximum numeric value
  :ONE-OF - List of allowed values (compared with EQUAL)
  :PATTERN - Regex pattern the string must match"
  ;; :min and :max
  (when-let ((min-val (getf constraints :min)))
    (when (and (numberp value) (< value min-val))
      (error 'config-validation-error
             :key key :value value
             :reason (format nil "Below minimum ~A" min-val)
             :expected (format nil ">= ~A" min-val))))
  (when-let ((max-val (getf constraints :max)))
    (when (and (numberp value) (> value max-val))
      (error 'config-validation-error
             :key key :value value
             :reason (format nil "Above maximum ~A" max-val)
             :expected (format nil "<= ~A" max-val))))
  ;; :one-of
  (when-let ((allowed (getf constraints :one-of)))
    (unless (member value allowed :test #'equal)
      (error 'config-validation-error
             :key key :value value
             :reason "Not an allowed value"
             :expected (format nil "One of ~{~S~^, ~}" allowed))))
  ;; :pattern (string regex)
  (when-let ((pattern (getf constraints :pattern)))
    (when (stringp value)
      (unless (cl-ppcre:scan pattern value)
        (error 'config-validation-error
               :key key :value value
               :reason (format nil "Does not match pattern ~S" pattern)
               :expected pattern))))
  t)

(defun validate-config (config &key required-keys (environment nil) (collect-errors nil))
  "Validate a complete configuration plist against the schema.

CONFIG: Property list to validate
REQUIRED-KEYS: Additional keys that must be non-NIL
ENVIRONMENT: When :production, also checks schema-defined required-p keys
COLLECT-ERRORS: When T, collect all errors instead of signaling on first

Returns T if valid. When COLLECT-ERRORS is T, returns (values T NIL) on success
or (values NIL error-list) on failure."
  (let ((errors '()))
    (flet ((record-error (e)
             (if collect-errors
                 (push e errors)
                 (error e))))
      ;; Validate each key-value pair in config
      (loop for (key value) on config by #'cddr
            do (handler-case
                   (validate-config-value key value)
                 (config-validation-error (e)
                   (record-error e))))
      ;; Check explicit required keys
      (dolist (key required-keys)
        (unless (getf config key)
          (record-error (make-condition 'config-missing-error
                                        :key key :value nil
                                        :reason "Required key is missing or NIL"))))
      ;; In production, check schema-defined required keys
      (when (eq environment :production)
        (maphash (lambda (key schema)
                   (when (and (config-schema-entry-required-p schema)
                              (not (getf config key)))
                     (record-error (make-condition 'config-missing-error
                                                   :key key :value nil
                                                   :reason "Required in production"))))
                 *config-schema*)))
    (if collect-errors
        (values (null errors) (nreverse errors))
        t)))

;;; ---------------------------------------------------------------------------
;;; Configuration access (pure, backward-compatible)
;;; ---------------------------------------------------------------------------

(defun get-config-value (key &optional (config *default-config*))
  "Retrieve a configuration value by KEY from CONFIG.
Returns the value associated with KEY, or the schema default if not found.

KEY: A keyword symbol (e.g., :esi-base-url)
CONFIG: A property list of configuration values (default: *default-config*)

Example:
  (get-config-value :esi-base-url) => \"https://esi.evetech.net\"
  (get-config-value :default-timeout) => 30"
  (multiple-value-bind (value present-p)
      (get-properties config (list key))
    (declare (ignore value))
    (if present-p
        (getf config key)
        ;; Fall back to schema default
        (let ((schema (gethash key *config-schema*)))
          (when schema
            (config-schema-entry-default schema))))))

(defun set-config-value (key value &optional (config *default-config*))
  "Set a configuration value by KEY in CONFIG.
Validates the value against the schema before setting.

KEY: A keyword symbol
VALUE: The new value to store
CONFIG: A property list (default: *default-config*)

Returns VALUE."
  (validate-config-value key value)
  (setf (getf config key) value)
  value)

(defun config-keys (config)
  "Return a list of all configuration keys in CONFIG.

CONFIG: A property list

Example:
  (config-keys '(:a 1 :b 2 :c 3)) => (:A :B :C)"
  (loop for (key) on config by #'cddr
        collect key))

;;; ---------------------------------------------------------------------------
;;; Configuration construction and merging
;;; ---------------------------------------------------------------------------

(defun load-config (&key (base *default-config*) overlay environment)
  "Create a new configuration by merging BASE with OVERLAY and ENVIRONMENT settings.
Does not modify any existing configuration; returns a fresh plist.

BASE: Base configuration plist (default: *default-config*)
OVERLAY: Additional configuration plist to merge on top
ENVIRONMENT: One of :development, :staging, :production, or NIL

Returns a new property list with merged configuration.

Example:
  (load-config :environment :development)
  (load-config :overlay '(:log-level :debug :cache-enabled nil))"
  (let ((config (copy-list base)))
    ;; Apply environment-specific settings
    (when environment
      (let ((env-config (getf *environment-configs* environment)))
        (unless env-config
          (error "Unknown environment: ~A. Valid: ~{~A~^, ~}"
                 environment
                 (loop for (key) on *environment-configs* by #'cddr collect key)))
        (loop for (key value) on env-config by #'cddr
              do (setf (getf config key) value))
        (setf *current-environment* environment)))
    ;; Apply explicit overlay settings last (highest priority)
    (when overlay
      (loop for (key value) on overlay by #'cddr
            do (setf (getf config key) value)))
    config))

(defun merge-configs (&rest configs)
  "Merge multiple configuration plists, later values overriding earlier ones.
Returns a fresh plist.

CONFIGS: One or more property lists to merge, in precedence order (last wins)

Example:
  (merge-configs *default-config* *production-config* user-overrides)"
  (let ((result '()))
    (dolist (config configs result)
      (loop for (key value) on config by #'cddr
            do (setf (getf result key) value)))))

;;; ---------------------------------------------------------------------------
;;; Schema introspection
;;; ---------------------------------------------------------------------------

(defun config-schema-for-key (key)
  "Return the schema entry for a configuration KEY, or NIL.

KEY: A configuration keyword

Returns a CONFIG-SCHEMA-ENTRY struct or NIL."
  (gethash key *config-schema*))

(defun config-keys-for-category (category)
  "Return all configuration keys belonging to CATEGORY.

CATEGORY: A keyword (e.g., :http, :auth, :cache)

Returns a list of keywords."
  (let ((keys '()))
    (maphash (lambda (key entry)
               (when (eq (config-schema-entry-category entry) category)
                 (push key keys)))
             *config-schema*)
    (sort keys #'string< :key #'symbol-name)))

(defun config-categories ()
  "Return a sorted list of all configuration categories."
  (let ((categories '()))
    (maphash (lambda (key entry)
               (declare (ignore key))
               (pushnew (config-schema-entry-category entry) categories))
             *config-schema*)
    (sort categories #'string< :key #'symbol-name)))

(defun hot-reloadable-keys ()
  "Return all configuration keys that can be safely changed at runtime."
  (let ((keys '()))
    (maphash (lambda (key entry)
               (when (config-schema-entry-hot-reload-p entry)
                 (push key keys)))
             *config-schema*)
    (sort keys #'string< :key #'symbol-name)))

(defun describe-config-key (key &optional (stream *standard-output*))
  "Print detailed documentation for a configuration KEY.

KEY: A configuration keyword
STREAM: Output stream (default: *standard-output*)"
  (let ((schema (gethash key *config-schema*)))
    (if schema
        (progn
          (format stream "~&~A~%" key)
          (format stream "  Description: ~A~%" (config-schema-entry-description schema))
          (format stream "  Type:        ~S~%" (config-schema-entry-type schema))
          (format stream "  Default:     ~S~%" (config-schema-entry-default schema))
          (format stream "  Category:    ~A~%" (config-schema-entry-category schema))
          (format stream "  Required:    ~A~%" (config-schema-entry-required-p schema))
          (format stream "  Hot-reload:  ~A~%" (config-schema-entry-hot-reload-p schema))
          (when (config-schema-entry-env-var schema)
            (format stream "  Env var:     ~A~%" (config-schema-entry-env-var schema)))
          (when (config-schema-entry-constraints schema)
            (format stream "  Constraints: ~S~%" (config-schema-entry-constraints schema))))
        (format stream "~&No schema entry for ~A~%" key)))
  (values))

(defun config-schema-summary (&optional (stream *standard-output*))
  "Print a summary of the entire configuration schema organized by category.

STREAM: Output stream (default: *standard-output*)"
  (format stream "~&=== Eve-Gate Configuration Schema ===~%")
  (dolist (category (config-categories))
    (format stream "~%  ~A:~%" category)
    (dolist (key (config-keys-for-category category))
      (let ((schema (gethash key *config-schema*)))
        (format stream "    ~A  (~A, default: ~S)~@[  [HOT]~]~%"
                key
                (config-schema-entry-type schema)
                (config-schema-entry-default schema)
                (config-schema-entry-hot-reload-p schema)))))
  (format stream "~%  Total: ~D keys in ~D categories~%"
          (hash-table-count *config-schema*)
          (length (config-categories)))
  (format stream "=== End Schema ===~%")
  (values))

(defun diff-configs (config-a config-b &optional (stream *standard-output*))
  "Show differences between two configuration plists.

CONFIG-A: First configuration
CONFIG-B: Second configuration
STREAM: Output stream (default: *standard-output*)"
  (let ((all-keys (union (config-keys config-a) (config-keys config-b))))
    (format stream "~&=== Configuration Diff ===~%")
    (dolist (key (sort all-keys #'string< :key #'symbol-name))
      (let ((val-a (getf config-a key))
            (val-b (getf config-b key)))
        (unless (equal val-a val-b)
          (format stream "  ~A: ~S -> ~S~%" key val-a val-b))))
    (format stream "=== End Diff ===~%"))
  (values))
