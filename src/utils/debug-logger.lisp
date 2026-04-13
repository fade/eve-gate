;;;; debug-logger.lisp - Performance and debugging logger for eve-gate
;;;;
;;;; Provides performance timing integration, memory usage snapshots,
;;;; cache effectiveness metrics, connection pool statistics, and
;;;; request tracing/profiling capabilities.
;;;;
;;;; This module bridges the structured logging system (logging.lisp) with
;;;; the performance monitoring system (performance.lisp), producing log
;;;; entries that capture performance data in a structured, searchable format.
;;;;
;;;; Key capabilities:
;;;;   - Timed operation logging with structured latency data
;;;;   - Memory usage snapshots at key points
;;;;   - Cache effectiveness periodic reporting
;;;;   - Connection pool health logging
;;;;   - Request tracing with full timing breakdown
;;;;   - Performance threshold alerting
;;;;
;;;; Design: All functions produce structured log entries via the standard
;;;; logging pipeline. Performance data is recorded both in the metrics
;;;; system (for aggregation) and in log entries (for per-event analysis).
;;;; This dual recording enables both real-time monitoring and historical
;;;; log analysis.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Performance timing integration
;;; ---------------------------------------------------------------------------

(defmacro with-logged-timing ((operation-name &key source (level :debug)
                                                   fields)
                              &body body)
  "Execute BODY, recording and logging the elapsed time.
Produces a structured log entry with timing data and also records
the metric in the performance metrics system.

OPERATION-NAME: String or keyword naming the operation (for log message)
SOURCE: Log source keyword
LEVEL: Log level for the timing entry (default: :debug)
FIELDS: Additional structured fields plist

Returns the result of BODY.

Example:
  (with-logged-timing (\"cache-lookup\" :source :cache
                                        :fields '(:key \"test-key\"))
    (memory-cache-get cache key))"
  (let ((start-var (gensym "START-"))
        (result-var (gensym "RESULT-"))
        (elapsed-var (gensym "ELAPSED-"))
        (op-var (gensym "OP-")))
    `(let ((,start-var (get-precise-time))
           (,op-var ,operation-name))
       (let ((,result-var (multiple-value-list (progn ,@body))))
         (let ((,elapsed-var (elapsed-milliseconds ,start-var)))
           ;; Record in metrics system
           (record-metric (if (keywordp ,op-var)
                              ,op-var
                              (intern (string-upcase
                                       (substitute #\- #\Space
                                                   (princ-to-string ,op-var)))
                                      :keyword))
                          ,elapsed-var)
           ;; Log the timing
           (when (log-level-active-p ,level)
             (apply #'log-event ,level
                    (format nil "~A completed in ~,2Fms" ,op-var ,elapsed-var)
                    :source ,(or source :performance)
                    :operation (princ-to-string ,op-var)
                    :latency-ms (round ,elapsed-var 0.01)
                    ,(or fields '()))))
         (values-list ,result-var)))))

(defun log-slow-operation (operation latency-ms threshold-ms
                           &key source endpoint details)
  "Log a warning when an operation exceeds a performance threshold.

OPERATION: Name of the slow operation
LATENCY-MS: Actual latency in milliseconds
THRESHOLD-MS: Expected maximum latency
SOURCE: Log source keyword
ENDPOINT: Associated ESI endpoint
DETAILS: Additional context plist"
  (when (> latency-ms threshold-ms)
    (apply #'log-event :warn
           (format nil "Slow operation: ~A took ~,1Fms (threshold: ~,1Fms)"
                   operation latency-ms threshold-ms)
           :source (or source :performance)
           :operation operation
           :latency-ms (round latency-ms 0.01)
           :threshold-ms threshold-ms
           :exceeded-by-ms (round (- latency-ms threshold-ms) 0.01)
           :endpoint endpoint
           (or details '()))))

;;; ---------------------------------------------------------------------------
;;; Performance threshold configuration
;;; ---------------------------------------------------------------------------

(defparameter *performance-thresholds*
  '(:http-request 5000.0        ; 5 seconds
    :cache-lookup 10.0          ; 10ms
    :cache-store 50.0           ; 50ms
    :json-parse 100.0           ; 100ms
    :rate-limit-wait 1000.0     ; 1 second
    :queue-wait 5000.0          ; 5 seconds
    :db-query 200.0             ; 200ms
    :token-refresh 10000.0)     ; 10 seconds
  "Performance thresholds in milliseconds for slow operation detection.
Operations exceeding these thresholds generate warning log entries.")

(defun get-performance-threshold (operation)
  "Return the performance threshold for OPERATION in milliseconds.

OPERATION: A keyword from *performance-thresholds*

Returns the threshold value, or NIL if none is configured."
  (getf *performance-thresholds* operation))

(defun check-performance-threshold (operation latency-ms &key source endpoint)
  "Check if a completed operation exceeded its performance threshold.
Logs a warning if the threshold is exceeded.

OPERATION: Operation keyword
LATENCY-MS: Actual latency in milliseconds
SOURCE: Log source keyword
ENDPOINT: Associated ESI endpoint"
  (let ((threshold (get-performance-threshold operation)))
    (when (and threshold (> latency-ms threshold))
      (log-slow-operation operation latency-ms threshold
                          :source source :endpoint endpoint))))

;;; ---------------------------------------------------------------------------
;;; Memory usage snapshots
;;; ---------------------------------------------------------------------------

(defun log-memory-snapshot (&key context)
  "Log a snapshot of current memory usage.
Useful at key points (startup, after bulk operations, periodic health checks).

CONTEXT: String describing why the snapshot was taken

Note: Memory reporting is implementation-dependent. This provides
best-effort values using SBCL-specific extensions when available,
with graceful fallback on other implementations."
  (let ((usage (get-memory-usage)))
    (log-event :info
               (format nil "Memory snapshot~@[: ~A~]" context)
               :source :memory
               :dynamic-space-usage (getf usage :dynamic-space-usage)
               :dynamic-space-size (getf usage :dynamic-space-size)
               :bytes-consed-between-gcs (getf usage :bytes-consed-between-gcs)
               :context context)))

(defun get-memory-usage ()
  "Return a plist of current memory usage statistics.
Implementation-dependent; returns what is available.

On SBCL, reports dynamic space usage and total size.
On other implementations, returns NIL values."
  (list :dynamic-space-usage
        #+sbcl (sb-kernel:dynamic-usage)
        #-sbcl nil
        :dynamic-space-size
        #+sbcl (sb-ext:dynamic-space-size)
        #-sbcl nil
        :bytes-consed-between-gcs
        #+sbcl (sb-ext:bytes-consed-between-gcs)
        #-sbcl nil))

;;; ---------------------------------------------------------------------------
;;; Cache effectiveness reporting
;;; ---------------------------------------------------------------------------

(defun log-cache-effectiveness (&key hit-count miss-count
                                      memory-entries db-entries
                                      etag-entries eviction-count
                                      avg-hit-latency-ms
                                      avg-miss-latency-ms)
  "Log a periodic cache effectiveness report with detailed metrics.

HIT-COUNT: Total cache hits in the reporting period
MISS-COUNT: Total cache misses in the reporting period
MEMORY-ENTRIES: Current memory cache entry count
DB-ENTRIES: Current database cache entry count
ETAG-ENTRIES: Current ETag cache entry count
EVICTION-COUNT: Entries evicted in the reporting period
AVG-HIT-LATENCY-MS: Average latency for cache hits
AVG-MISS-LATENCY-MS: Average latency for cache misses"
  (let* ((total (+ (or hit-count 0) (or miss-count 0)))
         (hit-rate (if (plusp total)
                       (* 100.0 (/ (or hit-count 0) (float total)))
                       0.0)))
    (log-event :info
               (format nil "Cache effectiveness: ~,1F% hit rate (~D/~D)"
                       hit-rate (or hit-count 0) total)
               :source :cache
               :hit-count hit-count
               :miss-count miss-count
               :hit-rate (round hit-rate 0.1)
               :memory-entries memory-entries
               :db-entries db-entries
               :etag-entries etag-entries
               :eviction-count eviction-count
               :avg-hit-latency-ms avg-hit-latency-ms
               :avg-miss-latency-ms avg-miss-latency-ms)))

;;; ---------------------------------------------------------------------------
;;; Connection pool statistics logging
;;; ---------------------------------------------------------------------------

(defun log-connection-pool-stats (&key active-connections idle-connections
                                        total-connections max-connections
                                        requests-served connection-errors
                                        avg-connection-time-ms)
  "Log connection pool statistics for monitoring.

ACTIVE-CONNECTIONS: Currently in-use connections
IDLE-CONNECTIONS: Available idle connections
TOTAL-CONNECTIONS: Total open connections
MAX-CONNECTIONS: Maximum configured connections
REQUESTS-SERVED: Total requests served by the pool
CONNECTION-ERRORS: Total connection errors
AVG-CONNECTION-TIME-MS: Average time to acquire a connection"
  (log-event :debug "Connection pool status"
             :source :connection-pool
             :active-connections active-connections
             :idle-connections idle-connections
             :total-connections total-connections
             :max-connections max-connections
             :requests-served requests-served
             :connection-errors connection-errors
             :avg-connection-time-ms avg-connection-time-ms
             :utilization (when (and active-connections max-connections
                                     (plusp max-connections))
                            (round (* 100.0
                                      (/ active-connections
                                         (float max-connections)))
                                   0.1))))

;;; ---------------------------------------------------------------------------
;;; Request tracing
;;; ---------------------------------------------------------------------------

(defstruct (request-trace (:constructor %make-request-trace))
  "Captures the full timing breakdown for a single ESI request.
Used for detailed performance analysis and bottleneck identification.

Slots:
  REQUEST-ID: Unique request identifier
  ENDPOINT: ESI endpoint path
  METHOD: HTTP method
  CHARACTER-ID: Associated character
  START-TIME: Internal time at request start
  PHASES: Alist of (phase-name . duration-ms) pairs
  TOTAL-MS: Total request duration
  STATUS: HTTP response status code
  CACHE-HIT-P: Whether the request was served from cache"
  (request-id nil :type (or null string))
  (endpoint nil :type (or null string))
  (method nil :type (or null keyword))
  (character-id nil :type (or null integer))
  (start-time (get-internal-real-time) :type integer)
  (phases nil :type list)
  (total-ms 0.0d0 :type double-float)
  (status nil :type (or null integer))
  (cache-hit-p nil :type boolean))

(defvar *current-trace* nil
  "The currently active request trace, if tracing is enabled.
Bound by WITH-REQUEST-TRACING.")

(defparameter *tracing-enabled-p* nil
  "Whether request tracing is active. When NIL, tracing macros are no-ops.")

(defmacro with-request-tracing ((&key endpoint method character-id) &body body)
  "Execute BODY with request tracing enabled, capturing a timing breakdown.
After BODY completes, emits a structured trace log entry.

ENDPOINT: ESI endpoint path
METHOD: HTTP method keyword
CHARACTER-ID: Associated character

Example:
  (with-request-tracing (:endpoint \"/v5/characters/12345/\" :method :get)
    (trace-phase :cache-lookup
      (check-cache key))
    (trace-phase :http-request
      (dex:get url)))"
  (let ((trace-var (gensym "TRACE-"))
        (start-var (gensym "START-")))
    `(if *tracing-enabled-p*
         (let* ((,start-var (get-internal-real-time))
                (,trace-var (%make-request-trace
                             :request-id (or *log-request-id*
                                             (generate-request-id))
                             :endpoint ,endpoint
                             :method ,method
                             :character-id ,character-id
                             :start-time ,start-var))
                (*current-trace* ,trace-var))
           (multiple-value-prog1
               (progn ,@body)
             (setf (request-trace-total-ms ,trace-var)
                   (coerce (elapsed-milliseconds ,start-var) 'double-float))
             (emit-request-trace ,trace-var)))
         (progn ,@body))))

(defmacro trace-phase ((phase-name) &body body)
  "Record the timing of a named phase within a request trace.
If no trace is active, executes BODY normally without overhead.

PHASE-NAME: Keyword naming this phase (e.g., :cache-lookup, :http-request)

Example:
  (trace-phase (:rate-limit-wait)
    (rate-limit-acquire limiter endpoint))"
  (let ((start-var (gensym "PHASE-START-"))
        (result-var (gensym "PHASE-RESULT-")))
    `(if *current-trace*
         (let ((,start-var (get-internal-real-time)))
           (let ((,result-var (multiple-value-list (progn ,@body))))
             (push (cons ,phase-name (elapsed-milliseconds ,start-var))
                   (request-trace-phases *current-trace*))
             (values-list ,result-var)))
         (progn ,@body))))

(defun emit-request-trace (trace)
  "Emit a completed request trace as a structured log entry.

TRACE: A request-trace struct with all phases recorded."
  (let ((phases (nreverse (request-trace-phases trace))))
    (log-event :debug
               (format nil "Request trace: ~A ~A ~,1Fms [~{~A:~,1Fms~^ ~}]"
                       (or (request-trace-method trace) "?")
                       (or (request-trace-endpoint trace) "?")
                       (request-trace-total-ms trace)
                       (loop for (name . ms) in phases
                             collect (string-downcase (symbol-name name))
                             collect ms))
               :source :trace
               :endpoint (request-trace-endpoint trace)
               :method (when (request-trace-method trace)
                         (string-downcase
                          (symbol-name (request-trace-method trace))))
               :total-ms (round (request-trace-total-ms trace) 0.01)
               :character-id (request-trace-character-id trace)
               :status (request-trace-status trace)
               :cache-hit (request-trace-cache-hit-p trace)
               :phases (loop for (name . ms) in phases
                             collect (string-downcase (symbol-name name))
                             collect (round ms 0.01)))))

;;; ---------------------------------------------------------------------------
;;; Performance report logging
;;; ---------------------------------------------------------------------------

(defun log-performance-summary (&key (metrics *perf-metrics*)
                                      (monitor *esi-perf-monitor*))
  "Log a structured performance summary suitable for monitoring systems.
Captures the same data as PERFORMANCE-REPORT but in structured form.

METRICS: Performance metrics registry
MONITOR: ESI performance monitor"
  (when monitor
    (let ((req-stats (histogram-stats
                      (esi-perf-monitor-request-histogram monitor)))
          (throughput (esi-perf-monitor-throughput monitor)))
      (log-event :info "Performance summary"
                 :source :performance
                 :throughput-10s (round (throughput-rate throughput :window 10) 0.01)
                 :throughput-60s (round (throughput-rate throughput :window 60) 0.01)
                 :total-requests (throughput-tracker-total-requests throughput)
                 :latency-mean (round (getf req-stats :mean) 0.01)
                 :latency-p50 (round (getf req-stats :p50) 0.01)
                 :latency-p95 (round (getf req-stats :p95) 0.01)
                 :latency-p99 (round (getf req-stats :p99) 0.01))))
  ;; Log key counters
  (when metrics
    (let ((counters '()))
      (bt:with-lock-held ((perf-metrics-counters-lock metrics))
        (maphash (lambda (k v)
                   (when (plusp v) (push (cons k v) counters)))
                 (perf-metrics-counters metrics)))
      (when counters
        (log-event :info "Performance counters"
                   :source :performance
                   :counters (loop for (k . v) in counters
                                   collect (string-downcase (symbol-name k))
                                   collect v))))))

;;; ---------------------------------------------------------------------------
;;; Debug context helper
;;; ---------------------------------------------------------------------------

(defmacro with-debug-context ((&rest fields) &body body)
  "Execute BODY with additional debug context in all log entries.
Combines WITH-LOG-CONTEXT with performance tracing when tracing is enabled.

FIELDS: Keyword plist of debug context

Example:
  (with-debug-context (:operation :bulk-fetch :batch-size 50)
    (process-batch items))"
  `(with-log-context (,@fields)
     ,@body))

;;; ---------------------------------------------------------------------------
;;; Diagnostic logging
;;; ---------------------------------------------------------------------------

(defun log-system-diagnostics (&optional (stream *standard-output*))
  "Log and display comprehensive system diagnostics.
Useful for troubleshooting and health checks.

STREAM: Output stream for display (default: *standard-output*)"
  ;; Logging system status
  (logging-status stream)
  ;; Memory snapshot
  (log-memory-snapshot :context "diagnostic")
  ;; Performance summary
  (log-performance-summary)
  ;; Audit trail summary
  (when *audit-trail*
    (audit-trail-summary :stream stream))
  (values))
