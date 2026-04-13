;;;; error-handling.lisp - Error handling infrastructure for eve-gate
;;;;
;;;; Provides comprehensive error handling, logging, reporting, and graceful
;;;; degradation strategies for the ESI API client. Builds on top of the
;;;; condition hierarchy in conditions.lisp and integrates with the HTTP client
;;;; retry logic and middleware pipeline.
;;;;
;;;; Components:
;;;;   - Error logging and reporting: Structured error logging with context
;;;;   - Error statistics: Tracking error frequency and patterns
;;;;   - Circuit breaker: Prevents cascading failures from repeated errors
;;;;   - Graceful degradation: Fallback values and cached responses
;;;;   - Error handling middleware: Integrates with the middleware pipeline
;;;;   - REPL inspection utilities: Interactive error debugging tools
;;;;
;;;; Thread safety: All mutable state is protected by locks where needed.
;;;; The circuit breaker and error statistics use bordeaux-threads for
;;;; synchronization.

(in-package #:eve-gate.core)

;;; ---------------------------------------------------------------------------
;;; Error context — structured information for debugging
;;; ---------------------------------------------------------------------------

(defstruct (error-context (:constructor %make-error-context))
  "Structured context captured when an error occurs, for logging and debugging.

Slots:
  TIMESTAMP: Universal time when the error was captured
  CONDITION: The original condition object
  CONDITION-TYPE: Symbol naming the condition's type
  ENDPOINT: ESI endpoint path (e.g., \"/v5/characters/12345/\")
  STATUS-CODE: HTTP status code (integer or NIL for network errors)
  MESSAGE: Human-readable error description
  RESPONSE-BODY: Raw response body, if available
  REQUEST-METHOD: HTTP method keyword (:get, :post, etc.)
  REQUEST-URI: Full request URI
  RETRY-COUNT: Number of retries attempted before this capture
  EXTRA: Plist of additional context supplied by the caller"
  (timestamp (get-universal-time) :type integer)
  (condition nil)
  (condition-type nil :type (or null symbol))
  (endpoint nil :type (or null string))
  (status-code nil :type (or null integer))
  (message "" :type string)
  (response-body nil)
  (request-method nil :type (or null keyword))
  (request-uri nil :type (or null string))
  (retry-count 0 :type (integer 0))
  (extra nil :type list))

(defun make-error-context (condition &key endpoint status-code message
                                          response-body request-method
                                          request-uri retry-count extra)
  "Create an error-context capturing structured information about a condition.

CONDITION: The condition object (or NIL for synthetic contexts)
ENDPOINT: ESI endpoint path
STATUS-CODE: HTTP status code
MESSAGE: Error description (defaults to condition's report string)
RESPONSE-BODY: Raw response body
REQUEST-METHOD: HTTP method used
REQUEST-URI: Full URI of the request
RETRY-COUNT: How many retries were attempted
EXTRA: Plist of additional context

Returns an error-context struct."
  (%make-error-context
   :condition condition
   :condition-type (when condition (type-of condition))
   :endpoint (or endpoint
                 (when (typep condition 'esi-error)
                   (esi-error-endpoint condition)))
   :status-code (or status-code
                    (when (typep condition 'esi-error)
                      (esi-error-status-code condition)))
   :message (or message
                (when condition
                  (princ-to-string condition))
                "Unknown error")
   :response-body (or response-body
                      (when (typep condition 'esi-error)
                        (esi-error-response-body condition)))
   :request-method request-method
   :request-uri request-uri
   :retry-count (or retry-count 0)
   :extra extra))

(defun format-error-context (ctx &optional (stream *standard-output*))
  "Print a human-readable summary of an error-context CTX to STREAM.
Useful at the REPL for inspecting captured errors.

CTX: An error-context struct
STREAM: Output stream (default: *standard-output*)"
  (format stream "~&--- ESI Error Context ---~%")
  (format stream "  Time:       ~A~%"
          (format-universal-time nil (error-context-timestamp ctx)))
  (format stream "  Type:       ~A~%" (error-context-condition-type ctx))
  (format stream "  Status:     ~A~%" (or (error-context-status-code ctx) "N/A"))
  (format stream "  Endpoint:   ~A~%" (or (error-context-endpoint ctx) "N/A"))
  (format stream "  Method:     ~A~%" (or (error-context-request-method ctx) "N/A"))
  (format stream "  URI:        ~A~%" (or (error-context-request-uri ctx) "N/A"))
  (format stream "  Retries:    ~D~%" (error-context-retry-count ctx))
  (format stream "  Message:    ~A~%" (error-context-message ctx))
  (when (error-context-response-body ctx)
    (let ((body (error-context-response-body ctx)))
      (format stream "  Body:       ~A~%"
              (if (and (stringp body) (> (length body) 200))
                  (concatenate 'string (subseq body 0 200) "...")
                  body))))
  (when (error-context-extra ctx)
    (format stream "  Extra:      ~{~A: ~A~^, ~}~%"
            (error-context-extra ctx)))
  (format stream "--- End Error Context ---~%")
  (values))

(defun format-universal-time (stream universal-time)
  "Format a universal time as a human-readable string.
Returns the string if STREAM is NIL, otherwise writes to STREAM."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time universal-time)
    (let ((result (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
                          year month day hour min sec)))
      (if stream
          (write-string result stream)
          result))))

;;; ---------------------------------------------------------------------------
;;; Error logging — structured logging of error contexts
;;; ---------------------------------------------------------------------------

(defparameter *error-log-hooks* '()
  "List of functions called when an error is logged.
Each hook receives an ERROR-CONTEXT struct. Hooks are called in order and
errors within hooks are caught and logged to *error-output*.

Use ADD-ERROR-LOG-HOOK and REMOVE-ERROR-LOG-HOOK to manage hooks.

Example hook:
  (lambda (ctx)
    (write-error-to-database ctx))")

(defparameter *error-log-lock* (bt:make-lock "error-log-lock")
  "Lock protecting *error-log-hooks* from concurrent modification.")

(defun add-error-log-hook (hook &key (name nil))
  "Add HOOK to the error logging pipeline.
HOOK is a function that receives an error-context struct.
NAME is an optional keyword for identifying the hook later.

If a hook with the same NAME already exists, it is replaced.

Returns the updated list of hooks."
  (bt:with-lock-held (*error-log-lock*)
    (if name
        ;; Replace existing hook with same name, or add new
        (let ((entry (cons name hook)))
          (setf *error-log-hooks*
                (cons entry (remove name *error-log-hooks*
                                    :key (lambda (h)
                                           (when (consp h) (car h)))))))
        (push (cons nil hook) *error-log-hooks*))
    *error-log-hooks*))

(defun remove-error-log-hook (name)
  "Remove the error log hook identified by NAME.
Returns the updated list of hooks."
  (bt:with-lock-held (*error-log-lock*)
    (setf *error-log-hooks*
          (remove name *error-log-hooks*
                  :key (lambda (h) (when (consp h) (car h)))))
    *error-log-hooks*))

(defun clear-error-log-hooks ()
  "Remove all error log hooks."
  (bt:with-lock-held (*error-log-lock*)
    (setf *error-log-hooks* '())))

(defun invoke-error-log-hooks (error-context)
  "Invoke all registered error log hooks with ERROR-CONTEXT.
Hook errors are caught and logged to *error-output* to prevent
cascading failures."
  (let ((hooks (bt:with-lock-held (*error-log-lock*)
                 (copy-list *error-log-hooks*))))
    (dolist (entry hooks)
      (let ((hook (if (consp entry) (cdr entry) entry))
            (name (when (consp entry) (car entry))))
        (handler-case
            (funcall hook error-context)
          (error (e)
            (format *error-output*
                    "~&[ERROR] Error log hook ~A failed: ~A~%"
                    (or name "anonymous") e)))))))

(defun log-esi-error (condition &key endpoint status-code request-method
                                     request-uri retry-count extra)
  "Log an ESI error condition with full context information.
Creates an error-context, logs it through the standard logging system,
and invokes all registered error log hooks.

CONDITION: The error condition to log
ENDPOINT: ESI endpoint path
STATUS-CODE: HTTP status code
REQUEST-METHOD: HTTP method keyword
REQUEST-URI: Full request URI
RETRY-COUNT: Number of retries attempted
EXTRA: Additional context plist

Returns the error-context struct."
  (let ((ctx (make-error-context condition
                                 :endpoint endpoint
                                 :status-code status-code
                                 :request-method request-method
                                 :request-uri request-uri
                                 :retry-count retry-count
                                 :extra extra)))
    ;; Log through standard logging system
    (let ((severity (classify-error-severity condition)))
      (ecase severity
        (:critical
         (log-error "ESI Critical Error [~A] ~@[~A ~]~A: ~A"
                    (error-context-condition-type ctx)
                    (error-context-status-code ctx)
                    (or (error-context-endpoint ctx) "")
                    (error-context-message ctx)))
        (:warning
         (log-warn "ESI Warning [~A] ~@[~A ~]~A: ~A"
                   (error-context-condition-type ctx)
                   (error-context-status-code ctx)
                   (or (error-context-endpoint ctx) "")
                   (error-context-message ctx)))
        (:transient
         (log-info "ESI Transient Error [~A] ~@[~A ~]~A: ~A"
                   (error-context-condition-type ctx)
                   (error-context-status-code ctx)
                   (or (error-context-endpoint ctx) "")
                   (error-context-message ctx)))))
    ;; Invoke registered hooks
    (invoke-error-log-hooks ctx)
    ctx))

(defun classify-error-severity (condition)
  "Classify the severity of a condition for logging purposes.

Returns one of:
  :CRITICAL - Non-recoverable errors (auth failures, bad requests)
  :WARNING - Actionable issues (rate limits, forbidden access)
  :TRANSIENT - Temporary issues likely to resolve (server errors, timeouts)"
  (typecase condition
    (esi-unauthorized :critical)
    (esi-bad-request :critical)
    (esi-unprocessable-entity :critical)
    (esi-forbidden :warning)
    (esi-not-found :warning)
    (esi-rate-limit-exceeded :warning)
    (esi-server-error :transient)
    (esi-network-error :transient)
    (esi-client-error :critical)
    (esi-error :critical)
    (t :critical)))

;;; ---------------------------------------------------------------------------
;;; Error statistics — tracking error frequency and patterns
;;; ---------------------------------------------------------------------------

(defstruct (error-statistics (:constructor %make-error-statistics))
  "Thread-safe error statistics tracker.

Tracks error counts by type, endpoint, and time window.
Useful for monitoring ESI health and detecting persistent problems.

Slots:
  LOCK: Thread synchronization lock
  TOTAL-COUNT: Total number of errors recorded
  TYPE-COUNTS: Hash-table mapping condition-type symbols to counts
  ENDPOINT-COUNTS: Hash-table mapping endpoint strings to counts
  STATUS-COUNTS: Hash-table mapping status-code integers to counts
  RECENT-ERRORS: Bounded list of recent error-context structs
  MAX-RECENT: Maximum number of recent errors to retain
  WINDOW-START: Universal time marking the start of the current window
  WINDOW-COUNT: Errors in the current time window
  WINDOW-SECONDS: Duration of the statistics window in seconds"
  (lock (bt:make-lock "error-stats-lock"))
  (total-count 0 :type (integer 0))
  (type-counts (make-hash-table :test 'eq) :type hash-table)
  (endpoint-counts (make-hash-table :test 'equal) :type hash-table)
  (status-counts (make-hash-table :test 'eql) :type hash-table)
  (recent-errors '() :type list)
  (max-recent 50 :type (integer 1))
  (window-start (get-universal-time) :type integer)
  (window-count 0 :type (integer 0))
  (window-seconds 300 :type (integer 1)))

(defun make-error-statistics (&key (max-recent 50) (window-seconds 300))
  "Create a new error statistics tracker.

MAX-RECENT: Maximum number of recent errors to retain (default: 50)
WINDOW-SECONDS: Duration of the sliding window in seconds (default: 300 = 5 min)

Returns an error-statistics struct."
  (%make-error-statistics
   :max-recent max-recent
   :window-seconds window-seconds))

(defun record-error (stats error-context)
  "Record an error in the statistics tracker.

STATS: An error-statistics struct
ERROR-CONTEXT: An error-context struct to record

Thread-safe."
  (bt:with-lock-held ((error-statistics-lock stats))
    ;; Advance window if needed
    (let ((now (get-universal-time)))
      (when (> (- now (error-statistics-window-start stats))
               (error-statistics-window-seconds stats))
        (setf (error-statistics-window-start stats) now
              (error-statistics-window-count stats) 0)))
    ;; Update counts
    (incf (error-statistics-total-count stats))
    (incf (error-statistics-window-count stats))
    (when-let ((ctype (error-context-condition-type error-context)))
      (incf (gethash ctype (error-statistics-type-counts stats) 0)))
    (when-let ((ep (error-context-endpoint error-context)))
      (incf (gethash ep (error-statistics-endpoint-counts stats) 0)))
    (when-let ((sc (error-context-status-code error-context)))
      (incf (gethash sc (error-statistics-status-counts stats) 0)))
    ;; Prepend to recent errors, trimming to max
    (push error-context (error-statistics-recent-errors stats))
    (when (> (length (error-statistics-recent-errors stats))
             (error-statistics-max-recent stats))
      (setf (error-statistics-recent-errors stats)
            (subseq (error-statistics-recent-errors stats)
                    0 (error-statistics-max-recent stats)))))
  error-context)

(defun error-statistics-summary (stats &optional (stream *standard-output*))
  "Print a summary of error statistics to STREAM.

STATS: An error-statistics struct
STREAM: Output stream (default: *standard-output*)

Returns the stats struct."
  (bt:with-lock-held ((error-statistics-lock stats))
    (format stream "~&=== ESI Error Statistics ===~%")
    (format stream "  Total errors:  ~D~%" (error-statistics-total-count stats))
    (format stream "  Window errors: ~D (last ~D seconds)~%"
            (error-statistics-window-count stats)
            (error-statistics-window-seconds stats))
    (format stream "  Recent count:  ~D~%"
            (length (error-statistics-recent-errors stats)))
    ;; By type
    (format stream "~%  By condition type:~%")
    (maphash (lambda (k v) (format stream "    ~A: ~D~%" k v))
             (error-statistics-type-counts stats))
    ;; By status
    (format stream "~%  By status code:~%")
    (maphash (lambda (k v) (format stream "    ~D: ~D~%" k v))
             (error-statistics-status-counts stats))
    ;; Top endpoints
    (format stream "~%  By endpoint (top 10):~%")
    (let ((pairs '()))
      (maphash (lambda (k v) (push (cons k v) pairs))
               (error-statistics-endpoint-counts stats))
      (setf pairs (sort pairs #'> :key #'cdr))
      (loop for (ep . count) in pairs
            for i from 0 below 10
            do (format stream "    ~A: ~D~%" ep count)))
    (format stream "=== End Statistics ===~%"))
  stats)

(defun reset-error-statistics (stats)
  "Reset all counters and history in the error statistics tracker.

STATS: An error-statistics struct to reset

Thread-safe."
  (bt:with-lock-held ((error-statistics-lock stats))
    (setf (error-statistics-total-count stats) 0
          (error-statistics-window-count stats) 0
          (error-statistics-window-start stats) (get-universal-time)
          (error-statistics-recent-errors stats) '())
    (clrhash (error-statistics-type-counts stats))
    (clrhash (error-statistics-endpoint-counts stats))
    (clrhash (error-statistics-status-counts stats)))
  stats)

;;; ---------------------------------------------------------------------------
;;; Global error statistics instance
;;; ---------------------------------------------------------------------------

(defvar *error-statistics* (make-error-statistics)
  "Global error statistics tracker for the eve-gate client.
Automatically updated by the error handling middleware.
Inspect with (error-statistics-summary *error-statistics*).")

;;; ---------------------------------------------------------------------------
;;; Circuit breaker — prevents cascading failures
;;; ---------------------------------------------------------------------------

(defstruct (circuit-breaker (:constructor %make-circuit-breaker))
  "Circuit breaker pattern implementation for ESI endpoint protection.

States:
  :CLOSED — Normal operation, requests pass through
  :OPEN — Failures exceeded threshold, requests short-circuited
  :HALF-OPEN — Recovery probe period, limited requests allowed

The circuit breaker tracks failures per endpoint. When failures within a
time window exceed the threshold, the circuit opens and subsequent requests
to that endpoint immediately receive a fallback or error without hitting
ESI. After a recovery timeout, the circuit enters half-open state to test
if the endpoint has recovered.

Slots:
  LOCK: Thread synchronization lock
  NAME: Identifier for this circuit breaker
  FAILURE-THRESHOLD: Number of failures in window before opening
  RECOVERY-TIMEOUT: Seconds to wait in open state before half-open
  WINDOW-SECONDS: Size of the failure counting window in seconds
  STATE: Current state (:closed, :open, :half-open)
  FAILURE-COUNT: Failures in the current window
  WINDOW-START: Universal time when the current window started
  LAST-FAILURE-TIME: Universal time of the most recent failure
  LAST-SUCCESS-TIME: Universal time of the most recent success
  HALF-OPEN-ATTEMPTS: Number of probe attempts in half-open state
  MAX-HALF-OPEN-ATTEMPTS: Maximum probes before re-opening"
  (lock (bt:make-lock "circuit-breaker-lock"))
  (name "default" :type string)
  (failure-threshold 5 :type (integer 1))
  (recovery-timeout 60 :type (integer 1))
  (window-seconds 60 :type (integer 1))
  (state :closed :type (member :closed :open :half-open))
  (failure-count 0 :type (integer 0))
  (window-start (get-universal-time) :type integer)
  (last-failure-time 0 :type integer)
  (last-success-time 0 :type integer)
  (half-open-attempts 0 :type (integer 0))
  (max-half-open-attempts 2 :type (integer 1)))

(defun make-circuit-breaker (&key (name "default")
                                   (failure-threshold 5)
                                   (recovery-timeout 60)
                                   (window-seconds 60)
                                   (max-half-open-attempts 2))
  "Create a new circuit breaker for ESI endpoint protection.

NAME: Identifier string (default: \"default\")
FAILURE-THRESHOLD: Failures in window before opening (default: 5)
RECOVERY-TIMEOUT: Seconds in open state before half-open test (default: 60)
WINDOW-SECONDS: Failure counting window in seconds (default: 60)
MAX-HALF-OPEN-ATTEMPTS: Max probes in half-open state (default: 2)

Returns a circuit-breaker struct."
  (%make-circuit-breaker
   :name name
   :failure-threshold failure-threshold
   :recovery-timeout recovery-timeout
   :window-seconds window-seconds
   :max-half-open-attempts max-half-open-attempts))

(defun circuit-breaker-allow-request-p (breaker)
  "Check whether the circuit breaker allows a request to proceed.

Returns T if the request should proceed, NIL if short-circuited.

State transitions:
  :CLOSED -> always allows
  :OPEN -> allows if recovery timeout has elapsed (transitions to :HALF-OPEN)
  :HALF-OPEN -> allows limited probe requests

Thread-safe."
  (bt:with-lock-held ((circuit-breaker-lock breaker))
    (let ((now (get-universal-time)))
      ;; Advance window in closed state
      (when (and (eq (circuit-breaker-state breaker) :closed)
                 (> (- now (circuit-breaker-window-start breaker))
                    (circuit-breaker-window-seconds breaker)))
        (setf (circuit-breaker-window-start breaker) now
              (circuit-breaker-failure-count breaker) 0))
      (ecase (circuit-breaker-state breaker)
        (:closed t)
        (:open
         (if (>= (- now (circuit-breaker-last-failure-time breaker))
                 (circuit-breaker-recovery-timeout breaker))
             ;; Recovery timeout elapsed, transition to half-open
             (progn
               (setf (circuit-breaker-state breaker) :half-open
                     (circuit-breaker-half-open-attempts breaker) 0)
               (log-info "Circuit breaker ~A: OPEN -> HALF-OPEN (recovery probe)"
                         (circuit-breaker-name breaker))
               t)
             nil))
        (:half-open
         (< (circuit-breaker-half-open-attempts breaker)
            (circuit-breaker-max-half-open-attempts breaker)))))))

(defun circuit-breaker-record-success (breaker)
  "Record a successful request in the circuit breaker.
In :HALF-OPEN state, a success transitions back to :CLOSED.

Thread-safe."
  (bt:with-lock-held ((circuit-breaker-lock breaker))
    (setf (circuit-breaker-last-success-time breaker) (get-universal-time))
    (when (eq (circuit-breaker-state breaker) :half-open)
      (setf (circuit-breaker-state breaker) :closed
            (circuit-breaker-failure-count breaker) 0
            (circuit-breaker-window-start breaker) (get-universal-time))
      (log-info "Circuit breaker ~A: HALF-OPEN -> CLOSED (recovered)"
                (circuit-breaker-name breaker))))
  breaker)

(defun circuit-breaker-record-failure (breaker)
  "Record a failed request in the circuit breaker.
Increments failure count. In :CLOSED state, opens if threshold exceeded.
In :HALF-OPEN state, re-opens immediately.

Thread-safe."
  (bt:with-lock-held ((circuit-breaker-lock breaker))
    (let ((now (get-universal-time)))
      (setf (circuit-breaker-last-failure-time breaker) now)
      (ecase (circuit-breaker-state breaker)
        (:closed
         (incf (circuit-breaker-failure-count breaker))
         (when (>= (circuit-breaker-failure-count breaker)
                   (circuit-breaker-failure-threshold breaker))
           (setf (circuit-breaker-state breaker) :open)
           (log-warn "Circuit breaker ~A: CLOSED -> OPEN (~D failures in ~D seconds)"
                     (circuit-breaker-name breaker)
                     (circuit-breaker-failure-count breaker)
                     (circuit-breaker-window-seconds breaker))))
        (:half-open
         (incf (circuit-breaker-half-open-attempts breaker))
         (setf (circuit-breaker-state breaker) :open)
         (log-warn "Circuit breaker ~A: HALF-OPEN -> OPEN (probe failed)"
                   (circuit-breaker-name breaker)))
        (:open
         ;; Already open, nothing to do
         nil))))
  breaker)

(defun circuit-breaker-reset (breaker)
  "Manually reset a circuit breaker to :CLOSED state.
Useful for administrative recovery or testing.

Thread-safe."
  (bt:with-lock-held ((circuit-breaker-lock breaker))
    (setf (circuit-breaker-state breaker) :closed
          (circuit-breaker-failure-count breaker) 0
          (circuit-breaker-half-open-attempts breaker) 0
          (circuit-breaker-window-start breaker) (get-universal-time))
    (log-info "Circuit breaker ~A: manually reset to CLOSED"
              (circuit-breaker-name breaker)))
  breaker)

(defun circuit-breaker-status (breaker &optional (stream *standard-output*))
  "Print the current status of a circuit breaker.

BREAKER: A circuit-breaker struct
STREAM: Output stream (default: *standard-output*)"
  (bt:with-lock-held ((circuit-breaker-lock breaker))
    (format stream "~&Circuit Breaker: ~A~%" (circuit-breaker-name breaker))
    (format stream "  State:          ~A~%" (circuit-breaker-state breaker))
    (format stream "  Failures:       ~D / ~D threshold~%"
            (circuit-breaker-failure-count breaker)
            (circuit-breaker-failure-threshold breaker))
    (format stream "  Window:         ~D seconds~%"
            (circuit-breaker-window-seconds breaker))
    (format stream "  Recovery:       ~D seconds~%"
            (circuit-breaker-recovery-timeout breaker))
    (when (plusp (circuit-breaker-last-failure-time breaker))
      (format stream "  Last failure:   ~A~%"
              (format-universal-time nil (circuit-breaker-last-failure-time breaker))))
    (when (plusp (circuit-breaker-last-success-time breaker))
      (format stream "  Last success:   ~A~%"
              (format-universal-time nil (circuit-breaker-last-success-time breaker)))))
  breaker)

;;; ---------------------------------------------------------------------------
;;; Per-endpoint circuit breaker registry
;;; ---------------------------------------------------------------------------

(defvar *circuit-breaker-registry* (make-hash-table :test 'equal)
  "Registry mapping endpoint path prefixes to circuit breakers.
Managed by GET-CIRCUIT-BREAKER and REGISTER-CIRCUIT-BREAKER.")

(defvar *circuit-breaker-registry-lock* (bt:make-lock "cb-registry-lock")
  "Lock protecting the circuit breaker registry.")

(defvar *default-circuit-breaker* (make-circuit-breaker :name "global")
  "Default circuit breaker used when no endpoint-specific breaker is registered.")

(defun get-circuit-breaker (endpoint)
  "Look up the circuit breaker for ENDPOINT.
Returns the most specific registered breaker, or *default-circuit-breaker*.

ENDPOINT: ESI endpoint path string (e.g., \"/v5/characters/12345/\")"
  (bt:with-lock-held (*circuit-breaker-registry-lock*)
    (or (gethash endpoint *circuit-breaker-registry*)
        ;; Try prefix matching for path-based breakers
        (block find-prefix
          (maphash (lambda (prefix breaker)
                     (when (and (stringp prefix)
                                (>= (length endpoint) (length prefix))
                                (string= endpoint prefix
                                         :end1 (length prefix)))
                       (return-from find-prefix breaker)))
                   *circuit-breaker-registry*)
          nil)
        *default-circuit-breaker*)))

(defun register-circuit-breaker (endpoint-prefix breaker)
  "Register a circuit breaker for endpoints matching ENDPOINT-PREFIX.

ENDPOINT-PREFIX: Path prefix to match (e.g., \"/v5/markets/\")
BREAKER: A circuit-breaker struct

Returns BREAKER."
  (bt:with-lock-held (*circuit-breaker-registry-lock*)
    (setf (gethash endpoint-prefix *circuit-breaker-registry*) breaker))
  breaker)

(defun list-circuit-breakers (&optional (stream *standard-output*))
  "Print the status of all registered circuit breakers.
Returns the number of registered breakers."
  (format stream "~&=== Circuit Breaker Registry ===~%")
  (format stream "~%Default breaker:~%")
  (circuit-breaker-status *default-circuit-breaker* stream)
  (let ((count 0))
    (bt:with-lock-held (*circuit-breaker-registry-lock*)
      (maphash (lambda (prefix breaker)
                 (format stream "~%Endpoint prefix: ~A~%" prefix)
                 (circuit-breaker-status breaker stream)
                 (incf count))
               *circuit-breaker-registry*))
    (format stream "~%Total registered: ~D~%" count)
    count))

;;; ---------------------------------------------------------------------------
;;; Graceful degradation — fallback values and cached responses
;;; ---------------------------------------------------------------------------

(defvar *fallback-registry* (make-hash-table :test 'equal)
  "Registry mapping endpoint patterns to fallback value functions.
Each entry is a function that returns a fallback value when the
endpoint is unavailable.")

(defvar *fallback-registry-lock* (bt:make-lock "fallback-registry-lock")
  "Lock protecting the fallback registry.")

(defun register-fallback (endpoint-pattern fallback-fn)
  "Register a fallback function for endpoints matching ENDPOINT-PATTERN.

ENDPOINT-PATTERN: Endpoint path or prefix to match
FALLBACK-FN: Function () -> value, called when the endpoint fails.
             Should return a reasonable default or cached value.

Example:
  (register-fallback \"/v5/status/\"
    (lambda () (list :players 0 :server-version \"unknown\" :start-time nil)))"
  (bt:with-lock-held (*fallback-registry-lock*)
    (setf (gethash endpoint-pattern *fallback-registry*) fallback-fn))
  endpoint-pattern)

(defun find-fallback (endpoint)
  "Find a registered fallback function for ENDPOINT.
Returns the fallback function, or NIL if none registered.

ENDPOINT: ESI endpoint path string"
  (bt:with-lock-held (*fallback-registry-lock*)
    (or (gethash endpoint *fallback-registry*)
        ;; Try prefix matching
        (block find-prefix
          (maphash (lambda (pattern fn)
                     (when (and (stringp pattern)
                                (>= (length endpoint) (length pattern))
                                (string= endpoint pattern
                                         :end1 (length pattern)))
                       (return-from find-prefix fn)))
                   *fallback-registry*)
          nil))))

(defun invoke-fallback (endpoint &optional default-value)
  "Invoke the registered fallback for ENDPOINT, or return DEFAULT-VALUE.

If a fallback function is registered and succeeds, returns its value.
If the fallback itself errors, returns DEFAULT-VALUE and logs the failure.

Returns two values: the fallback value, and T if a fallback was used."
  (let ((fallback-fn (find-fallback endpoint)))
    (if fallback-fn
        (handler-case
            (values (funcall fallback-fn) t)
          (error (e)
            (log-error "Fallback for ~A failed: ~A" endpoint e)
            (values default-value t)))
        (values default-value (not (null default-value))))))

;;; ---------------------------------------------------------------------------
;;; Graceful degradation macro — with-esi-fallback
;;; ---------------------------------------------------------------------------

(defmacro with-esi-fallback ((&key endpoint fallback on-error) &body body)
  "Execute BODY with graceful degradation on ESI errors.

Establishes handlers for ESI error conditions. When an error occurs:
  1. The error is logged and recorded in statistics
  2. If FALLBACK is provided, it is used as the return value
  3. If ON-ERROR is provided, it is called with the condition
  4. If a registered fallback exists for ENDPOINT, it is invoked
  5. Otherwise, the error propagates normally

ENDPOINT: Endpoint path (used to look up registered fallbacks)
FALLBACK: A form evaluated to produce a fallback value
ON-ERROR: A function (condition) -> value, for custom error handling

Returns the result of BODY, or a fallback value on error.

Example:
  ;; With inline fallback
  (with-esi-fallback (:endpoint \"/v5/status/\"
                      :fallback '(:players 0 :server-version \"unknown\"))
    (http-request client \"/v5/status/\"))

  ;; With error handler
  (with-esi-fallback (:on-error (lambda (e)
                                   (log-warn \"Using cached: ~A\" e)
                                   *cached-status*))
    (http-request client \"/v5/status/\"))"
  (let ((condition-var (gensym "CONDITION"))
        (ctx-var (gensym "CTX"))
        (fallback-val (gensym "FALLBACK")))
    `(handler-case
         (progn ,@body)
       (esi-error (,condition-var)
         ;; Log and record the error
         (let ((,ctx-var (log-esi-error ,condition-var
                                        :endpoint ,endpoint)))
           (record-error *error-statistics* ,ctx-var))
         ;; Try fallback strategies in order
         (cond
           ;; Custom on-error handler
           (,on-error
            (funcall ,on-error ,condition-var))
           ;; Inline fallback value
           (,(not (null fallback))
            (let ((,fallback-val ,fallback))
              (log-info "Using fallback value for ~A" (or ,endpoint "unknown endpoint"))
              ,fallback-val))
           ;; Registered fallback
           (,endpoint
            (multiple-value-bind (val found-p)
                (invoke-fallback ,endpoint)
              (if found-p
                  (progn
                    (log-info "Using registered fallback for ~A" ,endpoint)
                    val)
                  ;; No fallback available, re-signal
                  (error ,condition-var))))
           ;; No fallback, re-signal
           (t (error ,condition-var)))))))

;;; ---------------------------------------------------------------------------
;;; Safe call wrapper — combining circuit breaker + fallback + logging
;;; ---------------------------------------------------------------------------

(defun call-with-error-handling (thunk &key endpoint fallback-value circuit-breaker)
  "Call THUNK with full error handling: circuit breaker, fallback, and logging.

This is the functional equivalent of the WITH-ESI-FALLBACK macro, suitable
for use in generated code or higher-order function contexts.

THUNK: Zero-argument function to call
ENDPOINT: Endpoint path for circuit breaker lookup and fallback
FALLBACK-VALUE: Value to return on failure (or a function to call)
CIRCUIT-BREAKER: Explicit circuit breaker (default: looked up by endpoint)

Returns two values: the result (or fallback), and T if the call succeeded."
  (let ((breaker (or circuit-breaker
                     (when endpoint (get-circuit-breaker endpoint)))))
    ;; Check circuit breaker first
    (when (and breaker (not (circuit-breaker-allow-request-p breaker)))
      (log-warn "Circuit breaker OPEN for ~A, using fallback" endpoint)
      (return-from call-with-error-handling
        (values (if (functionp fallback-value)
                    (funcall fallback-value)
                    fallback-value)
                nil)))
    ;; Execute with error handling
    (handler-case
        (let ((result (funcall thunk)))
          (when breaker
            (circuit-breaker-record-success breaker))
          (values result t))
      (esi-error (condition)
        ;; Record failure in circuit breaker
        (when (and breaker (retryable-error-p condition))
          (circuit-breaker-record-failure breaker))
        ;; Log and record statistics
        (let ((ctx (log-esi-error condition :endpoint endpoint)))
          (record-error *error-statistics* ctx))
        ;; Return fallback
        (values (cond
                  ((functionp fallback-value) (funcall fallback-value))
                  (fallback-value fallback-value)
                  (endpoint (invoke-fallback endpoint))
                  (t nil))
                nil)))))

(defun retryable-error-p (condition)
  "Return T if CONDITION represents a retryable/transient error.
Used by the circuit breaker to decide whether to count a failure."
  (typecase condition
    (esi-server-error t)
    (esi-network-error t)
    (esi-rate-limit-exceeded t)
    (t nil)))

;;; ---------------------------------------------------------------------------
;;; Error handling middleware — integrates with the middleware pipeline
;;; ---------------------------------------------------------------------------

(defun make-error-handling-middleware (&key (record-statistics t)
                                            (circuit-breaker-check t))
  "Create middleware that integrates error handling with the request/response pipeline.

This middleware:
  - Checks the circuit breaker before requests (if enabled)
  - Records successful responses in the circuit breaker
  - Captures error statistics from responses with error status codes
  - Logs errors through the structured logging system

RECORD-STATISTICS: Record errors in *error-statistics* (default: T)
CIRCUIT-BREAKER-CHECK: Check circuit breakers before requests (default: T)

This middleware runs at priority 5 (very early, before most other middleware)."
  (make-middleware
   :name :error-handling
   :priority 5
   :request-fn
   (when circuit-breaker-check
     (lambda (ctx)
       (let* ((path (getf ctx :path))
              (breaker (when path (get-circuit-breaker path))))
         (when (and breaker (not (circuit-breaker-allow-request-p breaker)))
           ;; Store breaker state in context for response middleware
           (setf (getf ctx :circuit-breaker-open) t
                 (getf ctx :circuit-breaker) breaker))
         ctx)))
   :response-fn
   (lambda (response ctx)
     (let* ((path (getf ctx :path))
            (breaker (or (getf ctx :circuit-breaker)
                         (when path (get-circuit-breaker path))))
            (status (esi-response-status response)))
       ;; Record in circuit breaker
       (when breaker
         (if (< status 400)
             (circuit-breaker-record-success breaker)
             (when (retryable-status-p status)
               (circuit-breaker-record-failure breaker))))
       ;; Record error statistics for non-success responses
       (when (and record-statistics (>= status 400))
         (let ((ctx-obj (make-error-context
                         nil
                         :endpoint path
                         :status-code status
                         :request-method (getf ctx :method)
                         :request-uri (getf ctx :uri))))
           (record-error *error-statistics* ctx-obj))))
     response)))

;;; ---------------------------------------------------------------------------
;;; Health check — determine overall ESI connectivity health
;;; ---------------------------------------------------------------------------

(defun esi-health-status (&optional (stats *error-statistics*))
  "Determine the overall health of ESI connectivity based on recent error patterns.

Returns a keyword indicating health status:
  :HEALTHY — Low error rate, normal operation
  :DEGRADED — Elevated error rate, some endpoints may be problematic
  :UNHEALTHY — High error rate, significant ESI issues

STATS: Error statistics to analyze (default: *error-statistics*)"
  (bt:with-lock-held ((error-statistics-lock stats))
    (let* ((window-count (error-statistics-window-count stats))
           (window-secs (error-statistics-window-seconds stats))
           (error-rate (if (plusp window-secs)
                           (/ (float window-count) window-secs)
                           0.0)))
      (cond
        ((< error-rate 0.05) :healthy)       ; < 1 error per 20 seconds
        ((< error-rate 0.2) :degraded)       ; < 1 error per 5 seconds
        (t :unhealthy)))))

(defun esi-health-report (&key (stats *error-statistics*)
                                (stream *standard-output*))
  "Print a comprehensive health report for ESI connectivity.

STATS: Error statistics to analyze (default: *error-statistics*)
STREAM: Output stream (default: *standard-output*)"
  (let ((status (esi-health-status stats)))
    (format stream "~&=== ESI Health Report ===~%")
    (format stream "  Status: ~A~%" status)
    (format stream "~%")
    (error-statistics-summary stats stream)
    (format stream "~%")
    (list-circuit-breakers stream)
    (format stream "~%=== End Health Report ===~%")
    status))

;;; ---------------------------------------------------------------------------
;;; REPL-friendly error inspection utilities
;;; ---------------------------------------------------------------------------

(defun recent-errors (&optional (n 10) (stats *error-statistics*))
  "Return the N most recent error contexts from the statistics tracker.

N: Number of recent errors to return (default: 10)
STATS: Error statistics to query (default: *error-statistics*)

Returns a list of error-context structs."
  (bt:with-lock-held ((error-statistics-lock stats))
    (subseq (error-statistics-recent-errors stats)
            0 (min n (length (error-statistics-recent-errors stats))))))

(defun show-recent-errors (&optional (n 5) (stats *error-statistics*))
  "Display the N most recent errors in a human-readable format at the REPL.

N: Number of recent errors to display (default: 5)
STATS: Error statistics to query (default: *error-statistics*)"
  (let ((errors (recent-errors n stats)))
    (if errors
        (progn
          (format t "~&Showing ~D most recent ESI errors:~%~%" (length errors))
          (dolist (ctx errors)
            (format-error-context ctx)
            (terpri)))
        (format t "~&No recent ESI errors recorded.~%")))
  (values))

(defun errors-by-endpoint (&optional (stats *error-statistics*))
  "Return an alist of (endpoint . count) sorted by count descending.
Useful for identifying problematic endpoints.

STATS: Error statistics to query (default: *error-statistics*)"
  (let ((pairs '()))
    (bt:with-lock-held ((error-statistics-lock stats))
      (maphash (lambda (k v) (push (cons k v) pairs))
               (error-statistics-endpoint-counts stats)))
    (sort pairs #'> :key #'cdr)))

(defun errors-by-type (&optional (stats *error-statistics*))
  "Return an alist of (condition-type . count) sorted by count descending.
Useful for identifying the most common error types.

STATS: Error statistics to query (default: *error-statistics*)"
  (let ((pairs '()))
    (bt:with-lock-held ((error-statistics-lock stats))
      (maphash (lambda (k v) (push (cons k v) pairs))
               (error-statistics-type-counts stats)))
    (sort pairs #'> :key #'cdr)))

(defun errors-by-status (&optional (stats *error-statistics*))
  "Return an alist of (status-code . count) sorted by count descending.
Useful for identifying the most common HTTP error codes.

STATS: Error statistics to query (default: *error-statistics*)"
  (let ((pairs '()))
    (bt:with-lock-held ((error-statistics-lock stats))
      (maphash (lambda (k v) (push (cons k v) pairs))
               (error-statistics-status-counts stats)))
    (sort pairs #'> :key #'cdr)))

;;; ---------------------------------------------------------------------------
;;; Convenience macros for common error handling patterns
;;; ---------------------------------------------------------------------------

(defmacro ignoring-esi-errors ((&key on-error default) &body body)
  "Execute BODY, returning DEFAULT if any ESI error occurs.
Errors are logged but do not propagate.

ON-ERROR: Optional function (condition) called when an error is caught
DEFAULT: Value to return on error (default: NIL)

Example:
  ;; Return NIL on any ESI error
  (ignoring-esi-errors ()
    (http-request client \"/v5/characters/12345/\"))

  ;; Return a default and log custom message
  (ignoring-esi-errors (:default :unavailable
                        :on-error (lambda (e) (log-warn \"Ignoring: ~A\" e)))
    (http-request client \"/v5/status/\"))"
  (let ((condition-var (gensym "CONDITION")))
    `(handler-case
         (progn ,@body)
       (esi-error (,condition-var)
         (log-esi-error ,condition-var)
         ,(when on-error
            `(funcall ,on-error ,condition-var))
         ,default))))

(defmacro with-esi-error-logging ((&key endpoint method) &body body)
  "Execute BODY with ESI error logging. Errors are logged and recorded
in statistics, then re-signaled. Does not suppress errors.

ENDPOINT: Endpoint path for context in log messages
METHOD: HTTP method keyword for context

Example:
  (with-esi-error-logging (:endpoint \"/v5/characters/12345/\" :method :get)
    (http-request client \"/v5/characters/12345/\"))"
  (let ((condition-var (gensym "CONDITION")))
    `(handler-bind
         ((esi-error
            (lambda (,condition-var)
              (let ((ctx (log-esi-error ,condition-var
                                        :endpoint ,endpoint
                                        :request-method ,method)))
                (record-error *error-statistics* ctx)))))
       ,@body)))

;;; ---------------------------------------------------------------------------
;;; Enhanced default middleware stack constructor
;;; ---------------------------------------------------------------------------

(defun make-resilient-middleware-stack (&key (datasource "tranquility")
                                             (logging t)
                                             (log-headers nil)
                                             (log-body nil)
                                             (error-handling t)
                                             (circuit-breakers t)
                                             (error-statistics t)
                                             rate-limit-callback)
  "Create a middleware stack with full error handling and resilience features.

Extends the default middleware stack with:
  - Error handling middleware (circuit breakers, error statistics)
  - All standard middleware (headers, logging, JSON, error decoration, rate limits)

DATASOURCE: ESI datasource (default: \"tranquility\")
LOGGING: Enable request/response logging (default: T)
LOG-HEADERS: Include headers in log output (default: NIL)
LOG-BODY: Include body excerpts in log output (default: NIL)
ERROR-HANDLING: Enable error handling middleware (default: T)
CIRCUIT-BREAKERS: Enable circuit breaker checks (default: T)
ERROR-STATISTICS: Record error statistics (default: T)
RATE-LIMIT-CALLBACK: Function to receive rate limit updates

Returns a sorted middleware stack list.

Example:
  (make-http-client :middleware (make-resilient-middleware-stack))
  (make-http-client :middleware (make-resilient-middleware-stack
                                 :circuit-breakers nil
                                 :logging nil))"
  (let ((stack (make-default-middleware-stack
                :datasource datasource
                :logging logging
                :log-headers log-headers
                :log-body log-body
                :rate-limit-callback rate-limit-callback)))
    (when error-handling
      (setf stack (add-middleware stack
                                 (make-error-handling-middleware
                                  :record-statistics error-statistics
                                  :circuit-breaker-check circuit-breakers))))
    stack))
