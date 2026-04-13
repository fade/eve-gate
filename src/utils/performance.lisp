;;;; performance.lisp - Performance profiling, metrics, and monitoring for eve-gate
;;;;
;;;; Provides infrastructure for measuring, tracking, and optimizing the
;;;; performance of ESI API operations. This module is the observability
;;;; backbone — without measurement, optimization is guesswork.
;;;;
;;;; Key components:
;;;;   - High-resolution timing utilities (nanosecond precision where available)
;;;;   - Hot path profiling with statistical sampling
;;;;   - Throughput and latency histograms
;;;;   - Performance metrics collection and aggregation
;;;;   - Memory allocation tracking hooks
;;;;   - Benchmark scaffolding for reproducible measurements
;;;;
;;;; Design: Pure measurement infrastructure with no side effects on the code
;;;; being profiled (beyond timing overhead). All metrics are thread-safe and
;;;; use lock-free atomics where possible. Metrics are accumulated and can be
;;;; queried at any time via the REPL.
;;;;
;;;; The performance module integrates with the rest of eve-gate:
;;;;   - Cache hit/miss latency tracking
;;;;   - HTTP request/response timing
;;;;   - Rate limiter wait time measurement
;;;;   - Concurrent engine throughput monitoring

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; High-resolution timing
;;; ---------------------------------------------------------------------------

(declaim (inline get-precise-time elapsed-microseconds elapsed-milliseconds))

(defun get-precise-time ()
  "Return a high-resolution timestamp suitable for elapsed-time computation.

Uses GET-INTERNAL-REAL-TIME which provides the highest portable resolution.
On SBCL this is typically microsecond precision.

Returns an integer (internal time units)."
  (get-internal-real-time))

(defun elapsed-microseconds (start-time)
  "Return elapsed microseconds since START-TIME.

START-TIME: A value from GET-PRECISE-TIME

Returns a single-float of elapsed microseconds."
  (declare (type integer start-time))
  (let ((elapsed (- (get-internal-real-time) start-time)))
    (* (/ (float elapsed 1.0d0)
          (float internal-time-units-per-second 1.0d0))
       1.0d6)))

(defun elapsed-milliseconds (start-time)
  "Return elapsed milliseconds since START-TIME.

START-TIME: A value from GET-PRECISE-TIME

Returns a single-float of elapsed milliseconds."
  (declare (type integer start-time))
  (let ((elapsed (- (get-internal-real-time) start-time)))
    (* (/ (float elapsed 1.0d0)
          (float internal-time-units-per-second 1.0d0))
       1.0d3)))

(defmacro with-timing ((milliseconds-var) &body body)
  "Execute BODY and bind elapsed wall-clock time in milliseconds to MILLISECONDS-VAR.

MILLISECONDS-VAR is bound as a double-float within BODY and after it.
The binding is only valid after BODY completes — use MULTIPLE-VALUE-PROG1
if you need both the timing and the return value.

Example:
  (let (result)
    (with-timing (ms)
      (setf result (expensive-computation)))
    (format t \"Took ~,2Fms~%\" ms)
    result)"
  (let ((start (gensym "START-")))
    `(let ((,start (get-precise-time)))
       (multiple-value-prog1
           (progn ,@body)
         (let ((,milliseconds-var (elapsed-milliseconds ,start)))
           (declare (ignorable ,milliseconds-var))
           ,milliseconds-var)))))

(defmacro timing (&body body)
  "Execute BODY and return (values primary-result elapsed-ms).

Convenience macro for quick REPL measurements.

Example:
  (timing (sleep 0.1)) => NIL, 100.123"
  (let ((start (gensym "START-"))
        (result (gensym "RESULT-")))
    `(let ((,start (get-precise-time)))
       (let ((,result (multiple-value-list (progn ,@body))))
         (values-list (append ,result
                              (list (elapsed-milliseconds ,start))))))))

;;; ---------------------------------------------------------------------------
;;; Performance metrics collector
;;; ---------------------------------------------------------------------------

(defstruct (metric-bucket (:constructor %make-metric-bucket))
  "A time-series bucket for collecting a single metric.

Stores count, sum, min, max for computing statistics without retaining
all individual data points. Thread-safe via a lock.

Slots:
  NAME: Metric name keyword
  LOCK: Thread synchronization lock
  COUNT: Number of observations
  SUM: Sum of all observed values
  MIN-VAL: Minimum observed value
  MAX-VAL: Maximum observed value
  LAST-VALUE: Most recent observation
  LAST-TIME: Timestamp of most recent observation"
  (name :unknown :type keyword)
  (lock (bt:make-lock "metric-bucket-lock"))
  (count 0 :type fixnum)
  (sum 0.0d0 :type double-float)
  (min-val most-positive-double-float :type double-float)
  (max-val most-negative-double-float :type double-float)
  (last-value 0.0d0 :type double-float)
  (last-time 0 :type integer))

(defun make-metric-bucket (name)
  "Create a new metric bucket with NAME."
  (%make-metric-bucket :name name))

(defun metric-bucket-record (bucket value)
  "Record a VALUE observation in BUCKET. Thread-safe.

BUCKET: A metric-bucket struct
VALUE: A numeric value to record

Returns VALUE."
  (let ((dval (coerce value 'double-float)))
    (bt:with-lock-held ((metric-bucket-lock bucket))
      (incf (metric-bucket-count bucket))
      (incf (metric-bucket-sum bucket) dval)
      (when (< dval (metric-bucket-min-val bucket))
        (setf (metric-bucket-min-val bucket) dval))
      (when (> dval (metric-bucket-max-val bucket))
        (setf (metric-bucket-max-val bucket) dval))
      (setf (metric-bucket-last-value bucket) dval
            (metric-bucket-last-time bucket) (get-universal-time)))
    value))

(defun metric-bucket-stats (bucket)
  "Return statistics for BUCKET as a plist.

Returns:
  :NAME — metric name
  :COUNT — number of observations
  :SUM — total sum
  :MEAN — arithmetic mean
  :MIN — minimum value
  :MAX — maximum value
  :LAST — most recent value

Thread-safe."
  (bt:with-lock-held ((metric-bucket-lock bucket))
    (let ((count (metric-bucket-count bucket)))
      (list :name (metric-bucket-name bucket)
            :count count
            :sum (metric-bucket-sum bucket)
            :mean (if (plusp count)
                      (/ (metric-bucket-sum bucket) count)
                      0.0d0)
            :min (if (plusp count) (metric-bucket-min-val bucket) 0.0d0)
            :max (if (plusp count) (metric-bucket-max-val bucket) 0.0d0)
            :last (metric-bucket-last-value bucket)))))

(defun metric-bucket-reset (bucket)
  "Reset BUCKET to initial state. Thread-safe."
  (bt:with-lock-held ((metric-bucket-lock bucket))
    (setf (metric-bucket-count bucket) 0
          (metric-bucket-sum bucket) 0.0d0
          (metric-bucket-min-val bucket) most-positive-double-float
          (metric-bucket-max-val bucket) most-negative-double-float
          (metric-bucket-last-value bucket) 0.0d0
          (metric-bucket-last-time bucket) 0)))

;;; ---------------------------------------------------------------------------
;;; Performance metrics registry
;;; ---------------------------------------------------------------------------

(defstruct (perf-metrics (:constructor %make-perf-metrics))
  "Central registry for all performance metrics.

Provides named metric buckets organized by subsystem. Metrics are
created lazily on first use.

Slots:
  LOCK: Lock for the registry hash-table
  METRICS: Hash-table of metric-name (keyword) -> metric-bucket
  CREATED-AT: When this registry was initialized
  COUNTERS-LOCK: Lock for simple counters
  COUNTERS: Hash-table of counter-name -> integer"
  (lock (bt:make-lock "perf-metrics-registry-lock"))
  (metrics (make-hash-table :test 'eq) :type hash-table)
  (created-at (get-universal-time) :type integer)
  (counters-lock (bt:make-lock "perf-counters-lock"))
  (counters (make-hash-table :test 'eq) :type hash-table))

(defvar *perf-metrics* nil
  "Global performance metrics registry.
Initialize with (INITIALIZE-PERFORMANCE-METRICS).")

(defun initialize-performance-metrics ()
  "Initialize or reset the global performance metrics registry.

Returns the new registry."
  (setf *perf-metrics* (%make-perf-metrics))
  ;; Pre-create common metric buckets for hot-path efficiency
  (dolist (name '(:http-request-latency
                  :http-connect-time
                  :cache-lookup-time
                  :cache-store-time
                  :cache-hit-latency
                  :cache-miss-latency
                  :json-parse-time
                  :rate-limit-wait-time
                  :queue-wait-time
                  :total-request-time
                  :response-size-bytes))
    (ensure-metric-bucket *perf-metrics* name))
  *perf-metrics*)

(defun ensure-metric-bucket (registry name)
  "Get or create a metric bucket for NAME in REGISTRY.

REGISTRY: A perf-metrics struct
NAME: A keyword naming the metric

Returns the metric-bucket."
  (or (gethash name (perf-metrics-metrics registry))
      (bt:with-lock-held ((perf-metrics-lock registry))
        (or (gethash name (perf-metrics-metrics registry))
            (setf (gethash name (perf-metrics-metrics registry))
                  (make-metric-bucket name))))))

(defun ensure-perf-metrics ()
  "Ensure the global performance metrics registry is initialized.

Returns the global perf-metrics instance."
  (or *perf-metrics*
      (initialize-performance-metrics)))

;;; ---------------------------------------------------------------------------
;;; Metric recording API
;;; ---------------------------------------------------------------------------

(defun record-metric (name value)
  "Record a performance metric observation.

NAME: A keyword identifying the metric (e.g., :http-request-latency)
VALUE: A numeric value to record

The metric bucket is created lazily if it doesn't exist.

Example:
  (record-metric :http-request-latency 23.5)
  (record-metric :cache-hit-latency 0.02)"
  (let ((registry (ensure-perf-metrics)))
    (metric-bucket-record (ensure-metric-bucket registry name) value)))

(defun increment-counter (name &optional (delta 1))
  "Increment a simple counter by DELTA.

NAME: A keyword identifying the counter
DELTA: Amount to increment (default: 1)

Counters are separate from metric buckets — they're simple integers
for counting events like cache hits, errors, retries.

Example:
  (increment-counter :cache-hits)
  (increment-counter :bytes-transferred 4096)"
  (let ((registry (ensure-perf-metrics)))
    (bt:with-lock-held ((perf-metrics-counters-lock registry))
      (incf (gethash name (perf-metrics-counters registry) 0) delta))))

(defun counter-value (name)
  "Return the current value of counter NAME.

Returns 0 if the counter doesn't exist."
  (let ((registry (ensure-perf-metrics)))
    (bt:with-lock-held ((perf-metrics-counters-lock registry))
      (gethash name (perf-metrics-counters registry) 0))))

(defmacro with-metric-timing ((metric-name) &body body)
  "Execute BODY and record the elapsed time in milliseconds under METRIC-NAME.

METRIC-NAME: A keyword identifying the metric

Example:
  (with-metric-timing (:http-request-latency)
    (dex:get \"https://esi.evetech.net/latest/status/\"))"
  (let ((start (gensym "METRIC-START-")))
    `(let ((,start (get-precise-time)))
       (multiple-value-prog1
           (progn ,@body)
         (record-metric ,metric-name (elapsed-milliseconds ,start))))))

;;; ---------------------------------------------------------------------------
;;; Latency histogram (for percentile computation)
;;; ---------------------------------------------------------------------------

(defstruct (latency-histogram (:constructor %make-latency-histogram))
  "Fixed-bucket histogram for latency distribution analysis.

Provides approximate percentile computation (p50, p90, p95, p99) without
retaining individual observations. Uses logarithmic bucket boundaries
covering 0.01ms to 60,000ms (1 minute).

Slots:
  LOCK: Thread synchronization lock
  BUCKETS: Simple vector of fixnum counters
  BUCKET-BOUNDARIES: Sorted vector of upper bounds in milliseconds
  TOTAL-COUNT: Total observations
  TOTAL-SUM: Sum of all observations (for mean)"
  (lock (bt:make-lock "latency-histogram-lock"))
  (buckets nil :type (or null vector))
  (bucket-boundaries nil :type (or null vector))
  (total-count 0 :type fixnum)
  (total-sum 0.0d0 :type double-float))

(defparameter *default-histogram-boundaries*
  #(0.01 0.05 0.1 0.25 0.5 1.0 2.5 5.0 10.0 25.0 50.0 100.0
    250.0 500.0 1000.0 2500.0 5000.0 10000.0 30000.0 60000.0)
  "Default histogram bucket boundaries in milliseconds.
Covers sub-millisecond to 60-second latencies with logarithmic spacing.")

(defun make-latency-histogram (&key (boundaries *default-histogram-boundaries*))
  "Create a new latency histogram.

BOUNDARIES: Sorted vector of bucket upper bounds in milliseconds.

Returns a latency-histogram struct."
  (%make-latency-histogram
   :buckets (make-array (1+ (length boundaries)) :initial-element 0
                                                   :element-type 'fixnum)
   :bucket-boundaries boundaries))

(defun histogram-record (histogram value-ms)
  "Record a latency observation in the histogram.

HISTOGRAM: A latency-histogram struct
VALUE-MS: Latency in milliseconds

Thread-safe."
  (let ((boundaries (latency-histogram-bucket-boundaries histogram))
        (bucket-idx 0))
    ;; Find the correct bucket via linear scan (boundaries vector is small)
    (loop for i from 0 below (length boundaries)
          while (> value-ms (aref boundaries i))
          do (incf bucket-idx))
    (bt:with-lock-held ((latency-histogram-lock histogram))
      (incf (aref (latency-histogram-buckets histogram) bucket-idx))
      (incf (latency-histogram-total-count histogram))
      (incf (latency-histogram-total-sum histogram) (coerce value-ms 'double-float)))))

(defun histogram-percentile (histogram percentile)
  "Compute an approximate percentile from the histogram.

HISTOGRAM: A latency-histogram struct
PERCENTILE: The percentile to compute (0.0 to 1.0, e.g., 0.95 for p95)

Returns the approximate latency value in milliseconds at the given percentile,
or 0.0 if the histogram is empty."
  (bt:with-lock-held ((latency-histogram-lock histogram))
    (let ((total (latency-histogram-total-count histogram)))
      (when (zerop total)
        (return-from histogram-percentile 0.0d0))
      (let* ((target (* total percentile))
             (boundaries (latency-histogram-bucket-boundaries histogram))
             (buckets (latency-histogram-buckets histogram))
             (cumulative 0))
        (loop for i from 0 below (length buckets)
              do (incf cumulative (aref buckets i))
              when (>= cumulative target)
              do (return-from histogram-percentile
                   (if (< i (length boundaries))
                       (coerce (aref boundaries i) 'double-float)
                       (coerce (aref boundaries (1- (length boundaries)))
                               'double-float))))
        ;; Fallback: return the highest boundary
        (coerce (aref boundaries (1- (length boundaries))) 'double-float)))))

(defun histogram-stats (histogram)
  "Return comprehensive statistics from the histogram.

Returns a plist with:
  :COUNT — total observations
  :MEAN — mean latency (ms)
  :P50 — median latency (ms)
  :P90 — 90th percentile (ms)
  :P95 — 95th percentile (ms)
  :P99 — 99th percentile (ms)"
  (let ((total (latency-histogram-total-count histogram))
        (sum (latency-histogram-total-sum histogram)))
    (list :count total
          :mean (if (plusp total) (/ sum total) 0.0d0)
          :p50 (histogram-percentile histogram 0.50)
          :p90 (histogram-percentile histogram 0.90)
          :p95 (histogram-percentile histogram 0.95)
          :p99 (histogram-percentile histogram 0.99))))

;;; ---------------------------------------------------------------------------
;;; Throughput tracker
;;; ---------------------------------------------------------------------------

(defstruct (throughput-tracker (:constructor %make-throughput-tracker))
  "Tracks request throughput over sliding time windows.

Maintains per-second counters in a ring buffer to compute
requests-per-second over various window sizes.

Slots:
  LOCK: Thread synchronization lock
  WINDOW-SIZE: Number of seconds in the ring buffer
  BUCKETS: Ring buffer of per-second request counts
  CURRENT-SECOND: The universal-time second for the current bucket
  TOTAL-REQUESTS: Total requests across all time"
  (lock (bt:make-lock "throughput-tracker-lock"))
  (window-size 60 :type fixnum)
  (buckets nil :type (or null vector))
  (current-second 0 :type integer)
  (total-requests 0 :type integer))

(defun make-throughput-tracker (&key (window-size 60))
  "Create a new throughput tracker.

WINDOW-SIZE: Number of seconds of history to maintain (default: 60)

Returns a throughput-tracker struct."
  (%make-throughput-tracker
   :window-size window-size
   :buckets (make-array window-size :initial-element 0
                                     :element-type 'fixnum)
   :current-second (get-universal-time)))

(defun throughput-record (tracker &optional (count 1))
  "Record COUNT request completions. Thread-safe.

TRACKER: A throughput-tracker struct
COUNT: Number of requests to record (default: 1)"
  (bt:with-lock-held ((throughput-tracker-lock tracker))
    (let* ((now (get-universal-time))
           (current (throughput-tracker-current-second tracker))
           (elapsed (- now current))
           (window (throughput-tracker-window-size tracker))
           (buckets (throughput-tracker-buckets tracker)))
      ;; Advance the ring buffer, clearing stale buckets
      (when (plusp elapsed)
        (loop for i from 1 to (min elapsed window)
              for idx = (mod (+ current i) window)
              do (setf (aref buckets idx) 0))
        (setf (throughput-tracker-current-second tracker) now))
      ;; Record in current bucket
      (let ((idx (mod now window)))
        (incf (aref buckets idx) count))
      (incf (throughput-tracker-total-requests tracker) count))))

(defun throughput-rate (tracker &key (window 10))
  "Compute the average requests-per-second over the last WINDOW seconds.

TRACKER: A throughput-tracker struct
WINDOW: Number of seconds to average over (default: 10)

Returns a double-float requests/second."
  (bt:with-lock-held ((throughput-tracker-lock tracker))
    (let* ((now (get-universal-time))
           (max-window (throughput-tracker-window-size tracker))
           (actual-window (min window max-window))
           (buckets (throughput-tracker-buckets tracker))
           (total 0))
      (loop for i from 1 to actual-window
            for idx = (mod (- now i) max-window)
            do (incf total (aref buckets idx)))
      (if (plusp actual-window)
          (/ (coerce total 'double-float) actual-window)
          0.0d0))))

;;; ---------------------------------------------------------------------------
;;; ESI performance monitor (aggregate view)
;;; ---------------------------------------------------------------------------

(defstruct (esi-perf-monitor (:constructor %make-esi-perf-monitor))
  "High-level performance monitor aggregating all ESI operation metrics.

Provides a unified view of system performance including:
  - Request throughput and latency distributions
  - Cache effectiveness
  - Rate limiter utilization
  - Error rates and patterns

Slots:
  REQUEST-HISTOGRAM: Latency histogram for all ESI requests
  CACHE-HIT-HISTOGRAM: Latency histogram for cache hits
  CACHE-MISS-HISTOGRAM: Latency histogram for cache misses
  THROUGHPUT: Throughput tracker
  ENABLED-P: Whether metric collection is active"
  (request-histogram (make-latency-histogram) :type latency-histogram)
  (cache-hit-histogram (make-latency-histogram) :type latency-histogram)
  (cache-miss-histogram (make-latency-histogram) :type latency-histogram)
  (throughput (make-throughput-tracker) :type throughput-tracker)
  (enabled-p t :type boolean))

(defvar *esi-perf-monitor* nil
  "Global ESI performance monitor.
Initialize with (INITIALIZE-PERFORMANCE-MONITOR).")

(defun initialize-performance-monitor ()
  "Initialize or reset the global ESI performance monitor.

Returns the new monitor."
  (setf *esi-perf-monitor* (%make-esi-perf-monitor))
  (ensure-perf-metrics)
  *esi-perf-monitor*)

(defun ensure-perf-monitor ()
  "Ensure the global performance monitor is initialized.

Returns the global esi-perf-monitor instance."
  (or *esi-perf-monitor*
      (initialize-performance-monitor)))

(defun record-request-completed (latency-ms &key cache-hit-p)
  "Record a completed ESI request for performance monitoring.

LATENCY-MS: Request latency in milliseconds
CACHE-HIT-P: Whether this was served from cache

Records the observation in the appropriate histogram and throughput tracker."
  (let ((monitor (ensure-perf-monitor)))
    (when (esi-perf-monitor-enabled-p monitor)
      (histogram-record (esi-perf-monitor-request-histogram monitor) latency-ms)
      (throughput-record (esi-perf-monitor-throughput monitor))
      (if cache-hit-p
          (histogram-record (esi-perf-monitor-cache-hit-histogram monitor) latency-ms)
          (histogram-record (esi-perf-monitor-cache-miss-histogram monitor) latency-ms)))))

;;; ---------------------------------------------------------------------------
;;; Performance report
;;; ---------------------------------------------------------------------------

(defun performance-report (&key (stream *standard-output*)
                                 (monitor *esi-perf-monitor*)
                                 (metrics *perf-metrics*))
  "Print a comprehensive performance report.

STREAM: Output stream (default: *standard-output*)
MONITOR: ESI performance monitor (default: global)
METRICS: Performance metrics registry (default: global)

Useful for REPL inspection and diagnostics."
  (format stream "~&╔══════════════════════════════════════════════╗~%")
  (format stream   "║        EVE-GATE PERFORMANCE REPORT           ║~%")
  (format stream   "╚══════════════════════════════════════════════╝~%~%")
  ;; Throughput
  (when monitor
    (let ((tp (esi-perf-monitor-throughput monitor)))
      (format stream "  Throughput:~%")
      (format stream "    Last 10s:  ~,1F req/sec~%" (throughput-rate tp :window 10))
      (format stream "    Last 60s:  ~,1F req/sec~%" (throughput-rate tp :window 60))
      (format stream "    Total:     ~D requests~%~%"
              (throughput-tracker-total-requests tp)))
    ;; Request latency
    (let ((req-stats (histogram-stats (esi-perf-monitor-request-histogram monitor))))
      (format stream "  Request Latency:~%")
      (format stream "    Count: ~D  Mean: ~,2Fms~%"
              (getf req-stats :count)
              (getf req-stats :mean))
      (format stream "    p50: ~,2Fms  p90: ~,2Fms  p95: ~,2Fms  p99: ~,2Fms~%~%"
              (getf req-stats :p50)
              (getf req-stats :p90)
              (getf req-stats :p95)
              (getf req-stats :p99)))
    ;; Cache performance
    (let ((hit-stats (histogram-stats (esi-perf-monitor-cache-hit-histogram monitor)))
          (miss-stats (histogram-stats (esi-perf-monitor-cache-miss-histogram monitor))))
      (format stream "  Cache Performance:~%")
      (format stream "    Hits:   ~D (mean ~,2Fms, p95 ~,2Fms)~%"
              (getf hit-stats :count)
              (getf hit-stats :mean)
              (getf hit-stats :p95))
      (format stream "    Misses: ~D (mean ~,2Fms, p95 ~,2Fms)~%"
              (getf miss-stats :count)
              (getf miss-stats :mean)
              (getf miss-stats :p95))
      (let* ((total-reqs (+ (getf hit-stats :count) (getf miss-stats :count)))
             (hit-rate (if (plusp total-reqs)
                           (* 100.0 (/ (getf hit-stats :count) (float total-reqs)))
                           0.0)))
        (format stream "    Hit rate: ~,1F%~%~%" hit-rate))))
  ;; Individual metric buckets
  (when metrics
    (format stream "  Metric Buckets:~%")
    (let ((metric-list nil))
      (maphash (lambda (name bucket)
                 (push (cons name bucket) metric-list))
               (perf-metrics-metrics metrics))
      (setf metric-list (sort metric-list #'string< :key (lambda (c) (symbol-name (car c)))))
      (dolist (entry metric-list)
        (let ((stats (metric-bucket-stats (cdr entry))))
          (when (plusp (getf stats :count))
            (format stream "    ~A: count=~D mean=~,2F min=~,2F max=~,2F~%"
                    (getf stats :name)
                    (getf stats :count)
                    (getf stats :mean)
                    (getf stats :min)
                    (getf stats :max))))))
    ;; Counters
    (format stream "~%  Counters:~%")
    (let ((counter-list nil))
      (maphash (lambda (name value)
                 (push (cons name value) counter-list))
               (perf-metrics-counters metrics))
      (setf counter-list (sort counter-list #'string< :key (lambda (c) (symbol-name (car c)))))
      (dolist (entry counter-list)
        (format stream "    ~A: ~D~%" (car entry) (cdr entry)))))
  (format stream "~%")
  (values))

(defun reset-performance-metrics ()
  "Reset all performance metrics to initial state."
  (initialize-performance-metrics)
  (initialize-performance-monitor)
  (log-info "Performance metrics reset")
  (values))

;;; ---------------------------------------------------------------------------
;;; Benchmark utilities
;;; ---------------------------------------------------------------------------

(defmacro benchmark ((&key (iterations 1000)
                            (warmup 100)
                            (label "benchmark"))
                     &body body)
  "Run BODY for ITERATIONS and report timing statistics.

ITERATIONS: Number of times to execute BODY (default: 1000)
WARMUP: Number of warmup iterations before measurement (default: 100)
LABEL: Descriptive label for the output

Prints min, max, mean, and p95 latency.

Example:
  (benchmark (:iterations 10000 :label \"cache-lookup\")
    (memory-cache-get cache \"test-key\"))"
  (let ((times (gensym "TIMES-"))
        (i (gensym "I-"))
        (start (gensym "START-"))
        (elapsed (gensym "ELAPSED-")))
    `(progn
       ;; Warmup
       (dotimes (,i ,warmup)
         (declare (ignorable ,i))
         ,@body)
       ;; Measurement
       (let ((,times (make-array ,iterations :element-type 'double-float)))
         (dotimes (,i ,iterations)
           (let ((,start (get-precise-time)))
             ,@body
             (let ((,elapsed (elapsed-microseconds ,start)))
               (setf (aref ,times ,i) ,elapsed))))
         ;; Compute statistics
         (sort ,times #'<)
         (let* ((count ,iterations)
                (sum (reduce #'+ ,times))
                (mean (/ sum count))
                (min-val (aref ,times 0))
                (max-val (aref ,times (1- count)))
                (p50 (aref ,times (floor (* count 0.5))))
                (p95 (aref ,times (floor (* count 0.95))))
                (p99 (aref ,times (floor (* count 0.99)))))
           (format t "~&Benchmark: ~A (~D iterations)~%" ,label count)
           (format t "  Mean:  ~,2F us~%" mean)
           (format t "  Min:   ~,2F us  Max: ~,2F us~%" min-val max-val)
           (format t "  p50:   ~,2F us  p95: ~,2F us  p99: ~,2F us~%"
                   p50 p95 p99)
           (values mean min-val max-val p50 p95 p99))))))
