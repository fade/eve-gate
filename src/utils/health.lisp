;;;; health.lisp - System health monitoring for eve-gate
;;;;
;;;; Comprehensive health checks for all subsystems: ESI API connectivity,
;;;; authentication, caching, rate limiting, storage, and data integrity.
;;;;
;;;; Each health check is a self-contained function returning a structured
;;;; result that can be aggregated into an overall system health status.
;;;; Checks are designed to be non-destructive, fast, and thread-safe.
;;;;
;;;; Health check lifecycle:
;;;;   1. Individual checks probe specific subsystems
;;;;   2. Results are aggregated into a composite health status
;;;;   3. Status changes trigger alerting (via alerting.lisp)
;;;;   4. Historical results enable trend analysis
;;;;
;;;; Design: Pure functional core — each check returns a standardized plist.
;;;; Side effects (HTTP probes, disk checks) are confined to specific
;;;; check implementations. The aggregation layer is entirely pure.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Health check result structure
;;; ---------------------------------------------------------------------------

(defstruct (health-check-result (:constructor %make-health-check-result))
  "Result of a single health check probe.

Slots:
  NAME: Keyword identifying the check (e.g., :esi-connectivity)
  STATUS: Overall status (:healthy, :degraded, :unhealthy, :unknown)
  MESSAGE: Human-readable description of the finding
  DETAILS: Plist of check-specific data
  LATENCY-MS: Time in milliseconds to execute the check
  TIMESTAMP: Universal time when the check was executed
  ERROR: Condition object if the check threw an error"
  (name :unknown :type keyword)
  (status :unknown :type (member :healthy :degraded :unhealthy :unknown))
  (message "" :type string)
  (details nil :type list)
  (latency-ms 0.0d0 :type double-float)
  (timestamp (get-universal-time) :type integer)
  (error nil))

(defun make-health-check-result (name status message &key details latency-ms error)
  "Create a health check result.

NAME: Keyword identifying the check
STATUS: One of :healthy :degraded :unhealthy :unknown
MESSAGE: Human-readable summary
DETAILS: Plist of additional data
LATENCY-MS: Check execution time
ERROR: Condition if check errored"
  (%make-health-check-result
   :name name
   :status status
   :message message
   :details (or details '())
   :latency-ms (or latency-ms 0.0d0)
   :error error))

;;; ---------------------------------------------------------------------------
;;; Health status severity ordering
;;; ---------------------------------------------------------------------------

(defun health-status-severity (status)
  "Return numeric severity for a health STATUS keyword.
Higher values indicate worse health."
  (ecase status
    (:healthy   0)
    (:degraded  1)
    (:unhealthy 2)
    (:unknown   3)))

(defun worst-health-status (statuses)
  "Return the worst health status from a list of STATUS keywords.
An empty list returns :unknown."
  (if (null statuses)
      :unknown
      (reduce (lambda (a b)
                (if (> (health-status-severity a)
                       (health-status-severity b))
                    a b))
              statuses)))

;;; ---------------------------------------------------------------------------
;;; Health check registry
;;; ---------------------------------------------------------------------------

(defvar *health-checks* (make-hash-table :test 'eq)
  "Registry of named health check functions.
Each entry maps a keyword to a function of zero arguments returning
a HEALTH-CHECK-RESULT.")

(defvar *health-checks-lock* (bt:make-lock "health-checks-lock")
  "Lock protecting the health check registry.")

(defun register-health-check (name check-fn &key (description ""))
  "Register a health check function under NAME.

NAME: Keyword identifying the check
CHECK-FN: Function of zero arguments returning a HEALTH-CHECK-RESULT
DESCRIPTION: Optional documentation string

The function will be called during health check sweeps."
  (declare (ignore description))
  (bt:with-lock-held (*health-checks-lock*)
    (setf (gethash name *health-checks*) check-fn))
  name)

(defun unregister-health-check (name)
  "Remove a registered health check."
  (bt:with-lock-held (*health-checks-lock*)
    (remhash name *health-checks*))
  name)

(defun list-health-checks ()
  "Return a list of all registered health check names."
  (let ((names '()))
    (bt:with-lock-held (*health-checks-lock*)
      (maphash (lambda (k v) (declare (ignore v)) (push k names))
               *health-checks*))
    (sort names #'string< :key #'symbol-name)))

;;; ---------------------------------------------------------------------------
;;; Health check execution
;;; ---------------------------------------------------------------------------

(defun run-health-check (name)
  "Execute a single named health check, wrapping errors and timing.

NAME: Keyword identifying the registered check

Returns a HEALTH-CHECK-RESULT. If the check throws, returns an :unhealthy
result with the error captured."
  (let ((check-fn (bt:with-lock-held (*health-checks-lock*)
                    (gethash name *health-checks*))))
    (unless check-fn
      (return-from run-health-check
        (make-health-check-result name :unknown
                                  (format nil "Health check ~A not registered" name))))
    (let ((start (get-precise-time)))
      (handler-case
          (let ((result (funcall check-fn)))
            ;; Inject latency if not already set
            (when (and result (zerop (health-check-result-latency-ms result)))
              (setf (health-check-result-latency-ms result)
                    (elapsed-milliseconds start)))
            result)
        (error (e)
          (make-health-check-result
           name :unhealthy
           (format nil "Health check ~A threw error: ~A" name e)
           :latency-ms (elapsed-milliseconds start)
           :error e))))))

(defun run-all-health-checks ()
  "Execute all registered health checks.

Returns a list of HEALTH-CHECK-RESULT structs, one per check."
  (mapcar #'run-health-check (list-health-checks)))

;;; ---------------------------------------------------------------------------
;;; Composite health status
;;; ---------------------------------------------------------------------------

(defstruct (system-health (:constructor %make-system-health))
  "Composite health status aggregating all subsystem checks.

Slots:
  STATUS: Overall system status (worst of all checks)
  CHECKS: List of individual HEALTH-CHECK-RESULT structs
  TIMESTAMP: When this composite status was computed
  UPTIME-SECONDS: Seconds since system initialization
  SUMMARY: Human-readable one-line summary"
  (status :unknown :type keyword)
  (checks nil :type list)
  (timestamp (get-universal-time) :type integer)
  (uptime-seconds 0 :type integer)
  (summary "" :type string))

(defvar *system-start-time* (get-universal-time)
  "Universal time when the system was initialized.
Used for uptime calculation.")

(defun compute-system-health (&optional (checks (run-all-health-checks)))
  "Aggregate individual health check results into a composite system health.

CHECKS: List of HEALTH-CHECK-RESULT structs (default: run all checks)

Returns a SYSTEM-HEALTH struct."
  (let* ((statuses (mapcar #'health-check-result-status checks))
         (overall (worst-health-status statuses))
         (now (get-universal-time))
         (healthy-count (count :healthy statuses))
         (total (length statuses))
         (degraded (count :degraded statuses))
         (unhealthy (count :unhealthy statuses)))
    (%make-system-health
     :status overall
     :checks checks
     :timestamp now
     :uptime-seconds (- now *system-start-time*)
     :summary (format nil "~A: ~D/~D healthy~@[, ~D degraded~]~@[, ~D unhealthy~]"
                      (string-upcase (symbol-name overall))
                      healthy-count total
                      (when (plusp degraded) degraded)
                      (when (plusp unhealthy) unhealthy)))))

;;; ---------------------------------------------------------------------------
;;; Health check history
;;; ---------------------------------------------------------------------------

(defvar *health-history* nil
  "Circular buffer of recent SYSTEM-HEALTH snapshots for trending.")

(defvar *health-history-lock* (bt:make-lock "health-history-lock")
  "Lock protecting the health history buffer.")

(defvar *health-history-max* 100
  "Maximum number of health snapshots to retain.")

(defun record-health-snapshot (health)
  "Record a SYSTEM-HEALTH snapshot in the history buffer.

HEALTH: A system-health struct"
  (bt:with-lock-held (*health-history-lock*)
    (push health *health-history*)
    (when (> (length *health-history*) *health-history-max*)
      (setf *health-history* (subseq *health-history* 0 *health-history-max*))))
  health)

(defun health-history (&optional (n 10))
  "Return the N most recent health snapshots.

N: Number of snapshots to return (default: 10)

Returns a list of SYSTEM-HEALTH structs, newest first."
  (bt:with-lock-held (*health-history-lock*)
    (subseq *health-history* 0 (min n (length *health-history*)))))

(defun health-trend (&optional (n 10))
  "Return the health status trend over the last N snapshots.

Returns a list of (timestamp . status) pairs, newest first."
  (mapcar (lambda (h)
            (cons (system-health-timestamp h)
                  (system-health-status h)))
          (health-history n)))

;;; ---------------------------------------------------------------------------
;;; Built-in health checks — Performance Metrics
;;; ---------------------------------------------------------------------------

(defun check-performance-metrics-health ()
  "Health check for the performance metrics subsystem.

Verifies the metrics registry is initialized and collecting data."
  (handler-case
      (if *perf-metrics*
          (let* ((metric-count (hash-table-count (perf-metrics-metrics *perf-metrics*)))
                 (counter-count (hash-table-count (perf-metrics-counters *perf-metrics*)))
                 (uptime (- (get-universal-time) (perf-metrics-created-at *perf-metrics*))))
            (make-health-check-result
             :performance-metrics
             (if (plusp metric-count) :healthy :degraded)
             (format nil "~D metrics, ~D counters, uptime ~Ds"
                     metric-count counter-count uptime)
             :details (list :metric-count metric-count
                            :counter-count counter-count
                            :uptime-seconds uptime)))
          (make-health-check-result
           :performance-metrics :degraded
           "Performance metrics not initialized"))
    (error (e)
      (make-health-check-result
       :performance-metrics :unhealthy
       (format nil "Performance metrics error: ~A" e)
       :error e))))

;;; ---------------------------------------------------------------------------
;;; Built-in health checks — Logging
;;; ---------------------------------------------------------------------------

(defun check-logging-health ()
  "Health check for the logging subsystem.

Verifies logging is enabled and destinations are configured."
  (let ((destinations (list-log-destinations))
        (enabled *log-enabled-p*)
        (level *log-level*))
    (make-health-check-result
     :logging
     (cond
       ((not enabled) :unhealthy)
       ((null destinations) :degraded)
       (t :healthy))
     (format nil "Logging ~A at level ~A, ~D destinations"
             (if enabled "enabled" "disabled")
             level (length destinations))
     :details (list :enabled enabled
                    :level level
                    :destinations destinations
                    :sequence-counter *log-sequence-counter*))))

;;; ---------------------------------------------------------------------------
;;; Built-in health checks — Configuration
;;; ---------------------------------------------------------------------------

(defun check-configuration-health ()
  "Health check for the configuration subsystem.

Verifies the config manager is initialized and configuration is valid."
  (handler-case
      (if *config-manager*
          (let* ((mgr *config-manager*)
                 (config (config-manager-active-config mgr))
                 (env (config-manager-environment mgr))
                 (initialized (config-manager-initialized-p mgr)))
            (multiple-value-bind (valid-p errors)
                (validate-config config :collect-errors t)
              (make-health-check-result
               :configuration
               (cond
                 ((not initialized) :unhealthy)
                 ((not valid-p) :degraded)
                 (t :healthy))
               (format nil "Config ~A, env=~A, ~D keys~@[, ~D validation errors~]"
                       (if initialized "initialized" "not initialized")
                       (or env "unset")
                       (length (config-keys config))
                       (when errors (length errors)))
               :details (list :initialized initialized
                              :environment env
                              :key-count (length (config-keys config))
                              :valid-p valid-p
                              :validation-errors (when errors (length errors))
                              :last-reload (config-manager-last-reload-time mgr)))))
          (make-health-check-result
           :configuration :degraded
           "Configuration manager not initialized"))
    (error (e)
      (make-health-check-result
       :configuration :unhealthy
       (format nil "Configuration error: ~A" e)
       :error e))))

;;; ---------------------------------------------------------------------------
;;; Built-in health checks — Memory
;;; ---------------------------------------------------------------------------

(defun check-memory-health ()
  "Health check for memory usage.

Reports current memory usage and checks against thresholds."
  (handler-case
      (let* ((usage (get-memory-usage))
             (heap-used (getf usage :heap-used 0))
             (heap-total (getf usage :heap-total 0))
             (usage-pct (if (plusp heap-total)
                            (* 100.0 (/ heap-used (float heap-total)))
                            0.0)))
        (make-health-check-result
         :memory
         (cond
           ((> usage-pct 90.0) :unhealthy)
           ((> usage-pct 75.0) :degraded)
           (t :healthy))
         (format nil "Heap: ~,1F% used (~,1F MB / ~,1F MB)"
                 usage-pct
                 (/ heap-used 1048576.0)
                 (/ heap-total 1048576.0))
         :details (list :heap-used heap-used
                        :heap-total heap-total
                        :usage-percent usage-pct)))
    (error (e)
      (make-health-check-result
       :memory :unknown
       (format nil "Memory check error: ~A" e)
       :error e))))

;;; ---------------------------------------------------------------------------
;;; Built-in health checks — Data Operations
;;; ---------------------------------------------------------------------------

(defun check-data-ops-health ()
  "Health check for the data export/import subsystem."
  (handler-case
      (if *data-ops-manager*
          (let ((status (data-ops-status)))
            (make-health-check-result
             :data-operations :healthy
             "Data operations manager active"
             :details status))
          (make-health-check-result
           :data-operations :degraded
           "Data operations manager not initialized"))
    (error (e)
      (make-health-check-result
       :data-operations :unknown
       (format nil "Data ops check error: ~A" e)
       :error e))))

;;; ---------------------------------------------------------------------------
;;; Initialization — register built-in checks
;;; ---------------------------------------------------------------------------

(defvar *health-system-initialized-p* nil
  "Whether the health monitoring system has been initialized.")

(defun initialize-health-monitoring ()
  "Initialize the health monitoring system and register built-in checks.

Registers health checks for all core subsystems. Additional checks
can be registered by other modules after initialization.

Returns T."
  (setf *system-start-time* (get-universal-time))
  ;; Register built-in checks
  (register-health-check :performance-metrics #'check-performance-metrics-health
                          :description "Performance metrics subsystem")
  (register-health-check :logging #'check-logging-health
                          :description "Logging subsystem")
  (register-health-check :configuration #'check-configuration-health
                          :description "Configuration management")
  (register-health-check :memory #'check-memory-health
                          :description "Memory usage")
  (register-health-check :data-operations #'check-data-ops-health
                          :description "Data export/import operations")
  (setf *health-system-initialized-p* t)
  (log-info "Health monitoring initialized with ~D checks" 
            (hash-table-count *health-checks*))
  t)

(defun ensure-health-monitoring ()
  "Ensure health monitoring is initialized."
  (unless *health-system-initialized-p*
    (initialize-health-monitoring)))

;;; ---------------------------------------------------------------------------
;;; Periodic health check sweep
;;; ---------------------------------------------------------------------------

(defvar *health-check-interval* 60
  "Default interval in seconds between automatic health check sweeps.")

(defvar *health-check-thread* nil
  "Thread running periodic health check sweeps, or NIL if not running.")

(defvar *health-check-running-p* nil
  "Flag controlling the periodic health check loop.")

(defun start-health-check-sweep (&key (interval *health-check-interval*))
  "Start a background thread that periodically runs all health checks.

INTERVAL: Seconds between sweeps (default: *health-check-interval*)

The thread records health snapshots and triggers alerts on status changes."
  (ensure-health-monitoring)
  (when *health-check-thread*
    (stop-health-check-sweep))
  (setf *health-check-running-p* t)
  (setf *health-check-thread*
        (bt:make-thread
         (lambda ()
           (loop while *health-check-running-p*
                 do (handler-case
                        (let ((health (compute-system-health)))
                          (record-health-snapshot health)
                          (log-trace "Health sweep: ~A" (system-health-summary health)))
                      (error (e)
                        (log-error "Health check sweep error: ~A" e)))
                    (sleep interval)))
         :name "eve-gate-health-sweep"))
  (log-info "Health check sweep started (interval: ~Ds)" interval)
  *health-check-thread*)

(defun stop-health-check-sweep ()
  "Stop the periodic health check sweep thread."
  (setf *health-check-running-p* nil)
  (when (and *health-check-thread*
             (bt:thread-alive-p *health-check-thread*))
    ;; Give thread time to exit gracefully
    (sleep 0.1))
  (setf *health-check-thread* nil)
  (log-info "Health check sweep stopped"))

;;; ---------------------------------------------------------------------------
;;; REPL inspection utilities
;;; ---------------------------------------------------------------------------

(defun print-system-health (&optional (stream *standard-output*))
  "Print comprehensive system health status to STREAM.
Runs all health checks and displays results.

STREAM: Output stream (default: *standard-output*)"
  (ensure-health-monitoring)
  (let ((health (compute-system-health)))
    (record-health-snapshot health)
    (format stream "~&╔══════════════════════════════════════════════╗~%")
    (format stream   "║         EVE-GATE SYSTEM HEALTH               ║~%")
    (format stream   "╚══════════════════════════════════════════════╝~%~%")
    (format stream "  Overall: ~A~%" (system-health-summary health))
    (format stream "  Uptime:  ~A~%~%" (format-uptime (system-health-uptime-seconds health)))
    (format stream "  Subsystem Checks:~%")
    (dolist (check (system-health-checks health))
      (let ((status-indicator (ecase (health-check-result-status check)
                                (:healthy   "[OK]")
                                (:degraded  "[!!]")
                                (:unhealthy "[XX]")
                                (:unknown   "[??]"))))
        (format stream "    ~A ~A: ~A (~,1Fms)~%"
                status-indicator
                (health-check-result-name check)
                (health-check-result-message check)
                (health-check-result-latency-ms check))))
    (format stream "~%")
    health))

(defun format-uptime (seconds)
  "Format SECONDS as a human-readable uptime string."
  (multiple-value-bind (days remaining) (floor seconds 86400)
    (multiple-value-bind (hours remaining) (floor remaining 3600)
      (multiple-value-bind (minutes secs) (floor remaining 60)
        (cond
          ((plusp days)
           (format nil "~Dd ~Dh ~Dm" days hours minutes))
          ((plusp hours)
           (format nil "~Dh ~Dm ~Ds" hours minutes secs))
          ((plusp minutes)
           (format nil "~Dm ~Ds" minutes secs))
          (t
           (format nil "~Ds" secs)))))))

(defun quick-health ()
  "Return the overall system health status keyword without printing.
Useful for programmatic health checking.

Returns one of :healthy :degraded :unhealthy :unknown."
  (ensure-health-monitoring)
  (system-health-status (compute-system-health)))

;;; quick-health returns the keyword status from the struct accessor
;;; system-health-status, which is auto-generated by defstruct.
