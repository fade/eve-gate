;;;; config-integration.lisp - Subsystem configuration integration for eve-gate
;;;;
;;;; Bridges the configuration system to each subsystem's runtime parameters.
;;;; Each subsystem (HTTP, auth, cache, rate-limiting, logging, performance)
;;;; has its own special variables and initialization functions. This module
;;;; provides "applicator" functions that take a configuration plist and push
;;;; the relevant values into each subsystem.
;;;;
;;;; The apply-* functions are idempotent: calling them with the same config
;;;; twice produces the same result. They handle NIL values gracefully (skip
;;;; the setting). They only touch hot-reloadable parameters when called for
;;;; a runtime update vs. initial configuration.
;;;;
;;;; This module is the single point of truth for "which config key controls
;;;; which subsystem parameter." Adding a new configurable parameter means
;;;; adding a schema entry in configuration.lisp and an applicator line here.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Logging subsystem configuration
;;; ---------------------------------------------------------------------------

(defun apply-logging-config (config)
  "Apply logging-related configuration values to the logging subsystem.

CONFIG: A configuration plist

Configurable keys:
  :LOG-LEVEL - Sets *log-level* (:trace, :debug, :info, :warn, :error, :fatal)
  :DEBUG-MODE - When T, also sets log level to :debug if not already lower
  :REQUEST-LOGGING - Enable/disable HTTP request logging
  :RESPONSE-LOGGING - Enable/disable HTTP response logging

Returns the applied log level."
  (when-let ((level (getf config :log-level)))
    (setf *log-level* level))
  ;; Debug mode implies at least :debug level
  (when (and (getf config :debug-mode)
             (> (log-level-value *log-level*) (log-level-value :debug)))
    (setf *log-level* :debug))
  *log-level*)

;;; ---------------------------------------------------------------------------
;;; Performance subsystem configuration
;;; ---------------------------------------------------------------------------

(defun apply-performance-config (config)
  "Apply performance-related configuration values.

CONFIG: A configuration plist

Configurable keys:
  :CONNECTION-POOL-SIZE - Connection pool maximum
  :DEBUG-MODE - When T, enables performance tracing

Returns T."
  (declare (ignore config))
  ;; Performance thresholds are set at initialization, not runtime
  ;; The performance subsystem reads from config during initialize-performance-subsystem
  t)

;;; ---------------------------------------------------------------------------
;;; Subsystem configuration bundle
;;; ---------------------------------------------------------------------------

(defstruct (subsystem-config (:constructor make-subsystem-config))
  "Pre-extracted configuration for a specific subsystem, avoiding repeated
plist lookups during hot paths.

Create from a full config plist with EXTRACT-SUBSYSTEM-CONFIG."
  ;; HTTP
  (http-timeout 30 :type integer)
  (http-retries 3 :type integer)
  (http-connect-timeout 10 :type integer)
  (http-read-timeout 30 :type integer)
  (http-pool-size 10 :type integer)
  (http-keep-alive-timeout 30 :type integer)
  ;; Auth
  (oauth-authorize-url "https://login.eveonline.com/v2/oauth/authorize/" :type string)
  (oauth-token-url "https://login.eveonline.com/v2/oauth/token/" :type string)
  (client-id nil :type (or null string))
  (client-secret nil :type (or null string))
  (redirect-uri nil :type (or null string))
  ;; Cache
  (cache-enabled-p t :type boolean)
  (cache-default-ttl 300 :type integer)
  (etag-cache-size 10000 :type integer)
  (memory-cache-size 1000 :type integer)
  ;; Rate limiting
  (error-limit-per-window 100 :type integer)
  (error-limit-window 60 :type integer)
  (burst-size 150 :type integer)
  (sustained-rate 20 :type integer)
  ;; Logging
  (log-level :info :type keyword)
  (log-format :simple :type keyword)
  (log-destination :stdout :type keyword)
  ;; Concurrent
  (worker-threads 4 :type integer)
  (bulk-batch-size 50 :type integer)
  (queue-max-size 1000 :type integer)
  ;; Debug
  (debug-mode-p nil :type boolean)
  (mock-responses-p nil :type boolean))

(defun extract-subsystem-config (config)
  "Extract a SUBSYSTEM-CONFIG from a full configuration plist.
This pre-extracts all values into a typed struct for efficient access
during hot paths (HTTP requests, cache lookups, etc.).

CONFIG: A configuration plist

Returns a SUBSYSTEM-CONFIG struct."
  (flet ((cfg (key default)
           (or (getf config key) default)))
    (make-subsystem-config
     ;; HTTP
     :http-timeout (cfg :default-timeout 30)
     :http-retries (cfg :default-retries 3)
     :http-connect-timeout (cfg :connect-timeout 10)
     :http-read-timeout (cfg :read-timeout 30)
     :http-pool-size (cfg :connection-pool-size 10)
     :http-keep-alive-timeout (cfg :keep-alive-timeout 30)
     ;; Auth
     :oauth-authorize-url (cfg :oauth-authorize-url
                               "https://login.eveonline.com/v2/oauth/authorize/")
     :oauth-token-url (cfg :oauth-token-url
                           "https://login.eveonline.com/v2/oauth/token/")
     :client-id (getf config :client-id)
     :client-secret (getf config :client-secret)
     :redirect-uri (getf config :redirect-uri)
     ;; Cache
     :cache-enabled-p (cfg :cache-enabled t)
     :cache-default-ttl (cfg :cache-default-ttl 300)
     :etag-cache-size (cfg :etag-cache-size 10000)
     :memory-cache-size (cfg :memory-cache-size 1000)
     ;; Rate limiting
     :error-limit-per-window (cfg :error-limit-per-window 100)
     :error-limit-window (cfg :error-limit-window 60)
     :burst-size (cfg :burst-size 150)
     :sustained-rate (cfg :sustained-rate 20)
     ;; Logging
     :log-level (cfg :log-level :info)
     :log-format (cfg :log-format :simple)
     :log-destination (cfg :log-destination :stdout)
     ;; Concurrent
     :worker-threads (cfg :worker-threads 4)
     :bulk-batch-size (cfg :bulk-batch-size 50)
     :queue-max-size (cfg :queue-max-size 1000)
     ;; Debug
     :debug-mode-p (cfg :debug-mode nil)
     :mock-responses-p (cfg :mock-responses nil))))

;;; ---------------------------------------------------------------------------
;;; Unified configuration application
;;; ---------------------------------------------------------------------------

(defun apply-config (config &key (hot-reload nil))
  "Apply a full configuration plist to all subsystems.
This is the primary entry point for pushing configuration into the runtime.

CONFIG: A configuration plist
HOT-RELOAD: When T, only updates hot-reloadable parameters

Returns a SUBSYSTEM-CONFIG struct representing the applied configuration."
  (let ((effective-config (if hot-reload
                              (filter-hot-reloadable config)
                              config)))
    ;; Apply to logging first (so subsequent apply-* logging works)
    (apply-logging-config effective-config)
    ;; Apply performance settings
    (apply-performance-config effective-config)
    ;; Log the configuration event
    (log-event :info "Configuration applied"
               :source :config
               :hot-reload hot-reload
               :environment *current-environment*
               :keys-applied (length (config-keys effective-config)))
    ;; Return the extracted subsystem config for efficient access
    (extract-subsystem-config config)))

(defun filter-hot-reloadable (config)
  "Filter a configuration plist to only include hot-reloadable keys.

CONFIG: A full configuration plist

Returns a new plist with only hot-reloadable keys."
  (let ((result '()))
    (loop for (key value) on config by #'cddr
          do (let ((schema (gethash key *config-schema*)))
               (when (and schema (config-schema-entry-hot-reload-p schema))
                 (setf (getf result key) value))))
    result))

;;; ---------------------------------------------------------------------------
;;; Configuration-to-subsystem parameter mapping
;;; ---------------------------------------------------------------------------

(defparameter *config-parameter-map*
  '(;; Logging parameters
    (:log-level . *log-level*)
    (:log-enabled . *log-enabled-p*))
  "Alist mapping configuration keys to the special variables they control.
Used for documentation and introspection; the actual application is done
by the apply-* functions which may have more complex logic.")

(defun config-parameter-for (config-key)
  "Return the special variable symbol controlled by CONFIG-KEY, or NIL.

CONFIG-KEY: A configuration keyword

Returns a symbol naming a special variable, or NIL."
  (cdr (assoc config-key *config-parameter-map*)))

;;; ---------------------------------------------------------------------------
;;; Configuration change detection
;;; ---------------------------------------------------------------------------

(defun config-changes (old-config new-config)
  "Compute the set of configuration changes between OLD-CONFIG and NEW-CONFIG.
Returns a list of (KEY OLD-VALUE NEW-VALUE) triples for changed keys.

OLD-CONFIG: Previous configuration plist
NEW-CONFIG: New configuration plist

Returns a list of change triples."
  (let ((changes '())
        (all-keys (union (config-keys old-config) (config-keys new-config))))
    (dolist (key all-keys (nreverse changes))
      (let ((old-val (getf old-config key))
            (new-val (getf new-config key)))
        (unless (equal old-val new-val)
          (push (list key old-val new-val) changes))))))

(defun classify-config-changes (changes)
  "Classify a list of configuration changes into hot-reloadable and restart-required.

CHANGES: List of (KEY OLD-VALUE NEW-VALUE) triples from CONFIG-CHANGES

Returns two values:
  1. List of hot-reloadable changes
  2. List of changes that require restart"
  (let ((hot '())
        (cold '()))
    (dolist (change changes)
      (let* ((key (first change))
             (schema (gethash key *config-schema*)))
        (if (and schema (config-schema-entry-hot-reload-p schema))
            (push change hot)
            (push change cold))))
    (values (nreverse hot) (nreverse cold))))

(defun log-config-changes (changes)
  "Log configuration changes with appropriate detail.

CHANGES: List of (KEY OLD-VALUE NEW-VALUE) triples"
  (multiple-value-bind (hot cold)
      (classify-config-changes changes)
    (when hot
      (log-event :info "Hot-reloadable config changes"
                 :source :config
                 :changes (mapcar (lambda (c) (list (first c) (third c))) hot)))
    (when cold
      (log-event :warn "Config changes requiring restart"
                 :source :config
                 :changes (mapcar #'first cold)))))
