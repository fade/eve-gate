;;;; monitoring.lisp - Performance monitoring and metrics aggregation for eve-gate
;;;;
;;;; Extends the core performance.lisp infrastructure with:
;;;;   - Real-time dashboard data aggregation
;;;;   - Trend analysis and anomaly detection
;;;;   - Performance baseline establishment and drift detection
;;;;   - Resource utilization tracking
;;;;   - SLA monitoring and reporting
;;;;
;;;; This module consumes data from the existing metric-bucket, latency-histogram,
;;;; and throughput-tracker structures, providing higher-level analysis and
;;;; operational insights.
;;;;
;;;; Design: Read-only analysis layer on top of existing metrics. All functions
;;;; are pure aggregators that query the metrics registry without modifying it.
;;;; Thread-safe by virtue of the underlying metrics' locking.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Performance baselines
;;; ---------------------------------------------------------------------------

(defstruct (performance-baseline (:constructor %make-performance-baseline))
  "Captured performance baseline for drift detection.

A baseline is a snapshot of key performance metrics at a known-good point.
Subsequent measurements are compared against the baseline to detect
performance regressions.

Slots:
  NAME: Identifier for this baseline
  CAPTURED-AT: Universal time when baseline was captured
  METRICS: Plist of metric-name -> stats-plist
  THRESHOLDS: Plist of metric-name -> max-acceptable-value
  DESCRIPTION: Human-readable description of when/why captured"
  (name :default :type keyword)
  (captured-at (get-universal-time) :type integer)
  (metrics nil :type list)
  (thresholds nil :type list)
  (description "" :type string))

(defvar *performance-baselines* (make-hash-table :test 'eq)
  "Registry of named performance baselines.")

(defvar *baselines-lock* (bt:make-lock "baselines-lock")
  "Lock for baseline registry.")

(defvar *active-baseline* nil
  "Currently active baseline for comparison.")

(defun capture-performance-baseline (&key (name :current) description)
  "Capture the current performance metrics as a named baseline.

NAME: Keyword identifier for the baseline (default: :current)
DESCRIPTION: Human-readable note

Returns the baseline struct."
  (let* ((registry (ensure-perf-metrics))
         (metrics-snapshot '()))
    ;; Capture stats from all metric buckets
    (bt:with-lock-held ((perf-metrics-lock registry))
      (maphash (lambda (name bucket)
                 (setf (getf metrics-snapshot name)
                       (metric-bucket-stats bucket)))
               (perf-metrics-metrics registry)))
    ;; Capture histogram stats if monitor exists
    (when *esi-perf-monitor*
      (setf (getf metrics-snapshot :request-latency)
            (histogram-stats (esi-perf-monitor-request-histogram *esi-perf-monitor*)))
      (setf (getf metrics-snapshot :throughput-10s)
            (throughput-rate (esi-perf-monitor-throughput *esi-perf-monitor*)
                            :window 10)))
    (let ((baseline (%make-performance-baseline
                     :name name
                     :metrics metrics-snapshot
                     :description (or description
                                      (format nil "Baseline captured at ~A"
                                              (format-log-timestamp
                                               (get-universal-time)
                                               (get-internal-real-time)))))))
      (bt:with-lock-held (*baselines-lock*)
        (setf (gethash name *performance-baselines*) baseline))
      (when (eq name :current)
        (setf *active-baseline* baseline))
      (log-info "Performance baseline ~A captured: ~D metrics"
                name (length metrics-snapshot))
      baseline)))

(defun get-baseline (name)
  "Retrieve a named performance baseline."
  (bt:with-lock-held (*baselines-lock*)
    (gethash name *performance-baselines*)))

;;; ---------------------------------------------------------------------------
;;; Performance drift detection
;;; ---------------------------------------------------------------------------

(defstruct (drift-result (:constructor make-drift-result))
  "Result of comparing current metrics against a baseline.

Slots:
  METRIC-NAME: The metric being compared
  BASELINE-VALUE: Value from the baseline
  CURRENT-VALUE: Current measured value
  DRIFT-PERCENT: Percentage change from baseline
  THRESHOLD-EXCEEDED-P: Whether drift exceeds configured threshold
  SEVERITY: :normal :warning :critical based on drift magnitude"
  (metric-name :unknown :type keyword)
  (baseline-value 0.0d0 :type double-float)
  (current-value 0.0d0 :type double-float)
  (drift-percent 0.0d0 :type double-float)
  (threshold-exceeded-p nil :type boolean)
  (severity :normal :type keyword))

(defparameter *drift-warning-threshold* 25.0d0
  "Percentage drift from baseline before warning. Default: 25%")

(defparameter *drift-critical-threshold* 50.0d0
  "Percentage drift from baseline before critical alert. Default: 50%")

(defun compute-drift (baseline-value current-value)
  "Compute percentage drift between baseline and current value.
Returns zero for zero baselines to avoid division errors."
  (if (zerop baseline-value)
      0.0d0
      (* 100.0d0 (/ (- current-value baseline-value)
                     (abs baseline-value)))))

(defun detect-performance-drift (&key (baseline *active-baseline*)
                                       (warning-threshold *drift-warning-threshold*)
                                       (critical-threshold *drift-critical-threshold*))
  "Compare current performance against the active baseline.

BASELINE: Baseline to compare against (default: *active-baseline*)
WARNING-THRESHOLD: Percent drift for warning (default: 25%)
CRITICAL-THRESHOLD: Percent drift for critical (default: 50%)

Returns a list of DRIFT-RESULT structs for metrics that have drifted.
Only metrics present in both the baseline and current registry are compared."
  (unless baseline
    (return-from detect-performance-drift nil))
  (let ((results '())
        (registry (ensure-perf-metrics)))
    ;; Compare each baselined metric
    (loop for (name baseline-stats) on (performance-baseline-metrics baseline) by #'cddr
          when (and (keywordp name) (listp baseline-stats))
          do (let* ((current-bucket (gethash name (perf-metrics-metrics registry)))
                    (baseline-mean (getf baseline-stats :mean 0.0d0)))
               (when (and current-bucket (not (zerop baseline-mean)))
                 (let* ((current-stats (metric-bucket-stats current-bucket))
                        (current-mean (getf current-stats :mean 0.0d0))
                        (drift (compute-drift baseline-mean current-mean))
                        (abs-drift (abs drift))
                        (severity (cond
                                    ((>= abs-drift critical-threshold) :critical)
                                    ((>= abs-drift warning-threshold) :warning)
                                    (t :normal))))
                   (when (not (eq severity :normal))
                     (push (make-drift-result
                            :metric-name name
                            :baseline-value (coerce baseline-mean 'double-float)
                            :current-value (coerce current-mean 'double-float)
                            :drift-percent (coerce drift 'double-float)
                            :threshold-exceeded-p t
                            :severity severity)
                           results))))))
    (sort results #'> :key (lambda (r) (abs (drift-result-drift-percent r))))))

;;; ---------------------------------------------------------------------------
;;; SLA monitoring
;;; ---------------------------------------------------------------------------

(defstruct (sla-target (:constructor make-sla-target))
  "Service Level Agreement target definition.

Slots:
  NAME: Identifier for this SLA target
  METRIC: The metric keyword to monitor
  MAX-VALUE: Maximum acceptable value (for latency)
  MIN-VALUE: Minimum acceptable value (for throughput)
  PERCENTILE: Which percentile to check (e.g., 0.95 for p95)
  WINDOW-SECONDS: Evaluation window"
  (name :unknown :type keyword)
  (metric :unknown :type keyword)
  (max-value nil :type (or null number))
  (min-value nil :type (or null number))
  (percentile nil :type (or null number))
  (window-seconds 300 :type integer))

(defstruct (sla-status (:constructor make-sla-status))
  "Current SLA compliance status.

Slots:
  TARGET: The SLA target being evaluated
  CURRENT-VALUE: Current measured value
  COMPLIANT-P: Whether the SLA is currently met
  MARGIN: How far from the threshold (positive = compliant)
  EVALUATED-AT: When this status was computed"
  (target nil :type (or null sla-target))
  (current-value 0.0d0 :type double-float)
  (compliant-p t :type boolean)
  (margin 0.0d0 :type double-float)
  (evaluated-at (get-universal-time) :type integer))

(defvar *sla-targets* nil
  "List of active SLA targets to monitor.")

(defun define-sla-target (name metric &key max-value min-value percentile
                                           (window-seconds 300))
  "Define an SLA target for monitoring.

NAME: Keyword identifier
METRIC: The metric keyword to monitor
MAX-VALUE: Maximum acceptable value (e.g., latency in ms)
MIN-VALUE: Minimum acceptable value (e.g., throughput in req/s)
PERCENTILE: Percentile to check (0.0-1.0)
WINDOW-SECONDS: Evaluation window (default: 300s)

Example:
  (define-sla-target :p95-latency :request-latency
                     :max-value 500.0 :percentile 0.95)
  (define-sla-target :min-throughput :throughput
                     :min-value 10.0)"
  (let ((target (make-sla-target
                 :name name
                 :metric metric
                 :max-value max-value
                 :min-value min-value
                 :percentile percentile
                 :window-seconds window-seconds)))
    ;; Replace existing target with same name
    (setf *sla-targets*
          (cons target (remove name *sla-targets*
                               :key #'sla-target-name)))
    target))

(defun evaluate-sla-target (target)
  "Evaluate a single SLA target against current metrics.

TARGET: An SLA-TARGET struct

Returns an SLA-STATUS struct."
  (let* ((metric-name (sla-target-metric target))
         (current-value
           (cond
             ;; Percentile check against histogram
             ((and (sla-target-percentile target)
                   *esi-perf-monitor*
                   (eq metric-name :request-latency))
              (histogram-percentile
               (esi-perf-monitor-request-histogram *esi-perf-monitor*)
               (sla-target-percentile target)))
             ;; Throughput check
             ((eq metric-name :throughput)
              (if *esi-perf-monitor*
                  (throughput-rate (esi-perf-monitor-throughput *esi-perf-monitor*)
                                  :window (min 60 (sla-target-window-seconds target)))
                  0.0d0))
             ;; Generic metric bucket check
             (t
              (let ((registry (ensure-perf-metrics)))
                (let ((bucket (gethash metric-name (perf-metrics-metrics registry))))
                  (if bucket
                      (getf (metric-bucket-stats bucket) :mean 0.0d0)
                      0.0d0))))))
         (current-dbl (coerce current-value 'double-float))
         (compliant-p t)
         (margin 0.0d0))
    ;; Check max-value constraint (e.g., latency must be under X)
    (when (sla-target-max-value target)
      (let ((max-dbl (coerce (sla-target-max-value target) 'double-float)))
        (setf compliant-p (and compliant-p (<= current-dbl max-dbl)))
        (setf margin (- max-dbl current-dbl))))
    ;; Check min-value constraint (e.g., throughput must be above X)
    (when (sla-target-min-value target)
      (let ((min-dbl (coerce (sla-target-min-value target) 'double-float)))
        (setf compliant-p (and compliant-p (>= current-dbl min-dbl)))
        (setf margin (- current-dbl min-dbl))))
    (make-sla-status
     :target target
     :current-value current-dbl
     :compliant-p compliant-p
     :margin (coerce margin 'double-float))))

(defun evaluate-all-sla-targets ()
  "Evaluate all defined SLA targets.

Returns a list of SLA-STATUS structs."
  (mapcar #'evaluate-sla-target *sla-targets*))

(defun sla-compliance-report (&optional (stream *standard-output*))
  "Print SLA compliance status for all targets.

STREAM: Output stream (default: *standard-output*)"
  (let ((statuses (evaluate-all-sla-targets)))
    (format stream "~&=== SLA Compliance Report ===~%")
    (if (null statuses)
        (format stream "  No SLA targets defined.~%")
        (dolist (status statuses)
          (let* ((target (sla-status-target status))
                 (indicator (if (sla-status-compliant-p status) "[OK]" "[!!]")))
            (format stream "  ~A ~A: ~,2F ~@[(max ~,2F)~]~@[(min ~,2F)~] margin=~,2F~%"
                    indicator
                    (sla-target-name target)
                    (sla-status-current-value status)
                    (sla-target-max-value target)
                    (sla-target-min-value target)
                    (sla-status-margin status)))))
    (format stream "=== End SLA Report ===~%")
    statuses))

;;; ---------------------------------------------------------------------------
;;; Anomaly detection (simple statistical)
;;; ---------------------------------------------------------------------------

(defstruct (anomaly (:constructor make-anomaly))
  "A detected performance anomaly.

Slots:
  METRIC-NAME: Which metric exhibited anomalous behavior
  CURRENT-VALUE: The anomalous value
  EXPECTED-RANGE: Plist with :min and :max of expected range
  DEVIATION: How many standard deviations from mean
  SEVERITY: :warning or :critical
  DETECTED-AT: When the anomaly was detected
  MESSAGE: Human-readable description"
  (metric-name :unknown :type keyword)
  (current-value 0.0d0 :type double-float)
  (expected-range nil :type list)
  (deviation 0.0d0 :type double-float)
  (severity :warning :type keyword)
  (detected-at (get-universal-time) :type integer)
  (message "" :type string))

(defparameter *anomaly-warning-sigma* 2.0d0
  "Standard deviations from mean before warning anomaly.")

(defparameter *anomaly-critical-sigma* 3.0d0
  "Standard deviations from mean before critical anomaly.")

(defun detect-anomalies (&key (metrics-to-check '(:http-request-latency
                                                   :total-request-time
                                                   :cache-lookup-time)))
  "Scan specified metrics for statistical anomalies.

Uses the metric bucket's min/max/mean to detect values that deviate
significantly from the established range.

METRICS-TO-CHECK: List of metric keywords to scan

Returns a list of ANOMALY structs for any detected anomalies."
  (let ((anomalies '())
        (registry (ensure-perf-metrics)))
    (dolist (name metrics-to-check)
      (let ((bucket (gethash name (perf-metrics-metrics registry))))
        (when (and bucket (> (metric-bucket-count bucket) 10))
          (let* ((stats (metric-bucket-stats bucket))
                 (mean (getf stats :mean 0.0d0))
                 (min-val (getf stats :min 0.0d0))
                 (max-val (getf stats :max 0.0d0))
                 (last-val (getf stats :last 0.0d0)))
            ;; Estimate stddev from range (rough approximation)
            (let* ((range (- max-val min-val))
                   (estimated-stddev (if (plusp range) (/ range 4.0d0) 1.0d0))
                   (deviation (if (plusp estimated-stddev)
                                  (/ (abs (- last-val mean)) estimated-stddev)
                                  0.0d0)))
              (when (> deviation *anomaly-warning-sigma*)
                (push (make-anomaly
                       :metric-name name
                       :current-value (coerce last-val 'double-float)
                       :expected-range (list :min min-val :max max-val)
                       :deviation (coerce deviation 'double-float)
                       :severity (if (> deviation *anomaly-critical-sigma*)
                                     :critical :warning)
                       :message (format nil "~A: last=~,2F, mean=~,2F, ~,1Fσ deviation"
                                        name last-val mean deviation))
                      anomalies)))))))
    anomalies))

;;; ---------------------------------------------------------------------------
;;; Real-time metrics aggregation (for dashboard)
;;; ---------------------------------------------------------------------------

(defun aggregate-dashboard-metrics ()
  "Collect and aggregate all metrics into a single plist for dashboard display.

Returns a plist with keys:
  :TIMESTAMP — current universal time
  :UPTIME-SECONDS — seconds since system start
  :THROUGHPUT — current requests/second
  :REQUEST-LATENCY — latency histogram stats
  :CACHE-PERFORMANCE — cache hit/miss stats and hit rate
  :ERROR-RATE — recent error counts
  :METRIC-BUCKETS — list of (name . stats) for all metrics
  :COUNTERS — list of (name . value) for all counters
  :ANOMALIES — any currently detected anomalies
  :SLA-STATUS — current SLA compliance"
  (let ((now (get-universal-time))
        (result '()))
    (setf (getf result :timestamp) now)
    (setf (getf result :uptime-seconds) (- now *system-start-time*))
    ;; Throughput
    (when *esi-perf-monitor*
      (let ((tp (esi-perf-monitor-throughput *esi-perf-monitor*)))
        (setf (getf result :throughput)
              (list :current (throughput-rate tp :window 10)
                    :average (throughput-rate tp :window 60)
                    :total (throughput-tracker-total-requests tp)))))
    ;; Request latency
    (when *esi-perf-monitor*
      (setf (getf result :request-latency)
            (histogram-stats (esi-perf-monitor-request-histogram *esi-perf-monitor*))))
    ;; Cache performance
    (when *esi-perf-monitor*
      (let ((hit-stats (histogram-stats (esi-perf-monitor-cache-hit-histogram *esi-perf-monitor*)))
            (miss-stats (histogram-stats (esi-perf-monitor-cache-miss-histogram *esi-perf-monitor*))))
        (let* ((total-reqs (+ (getf hit-stats :count 0) (getf miss-stats :count 0)))
               (hit-rate (if (plusp total-reqs)
                             (* 100.0 (/ (getf hit-stats :count 0) (float total-reqs)))
                             0.0)))
          (setf (getf result :cache-performance)
                (list :hits (getf hit-stats :count 0)
                      :misses (getf miss-stats :count 0)
                      :hit-rate hit-rate
                      :hit-latency-mean (getf hit-stats :mean 0.0d0)
                      :miss-latency-mean (getf miss-stats :mean 0.0d0))))))
    ;; Error counters
    (let ((registry (ensure-perf-metrics)))
      (setf (getf result :error-rate)
            (list :total-errors (counter-value :errors)
                  :rate-limit-errors (counter-value :rate-limit-errors)
                  :network-errors (counter-value :network-errors)
                  :auth-errors (counter-value :auth-errors)))
      ;; Metric buckets summary
      (let ((bucket-list '()))
        (bt:with-lock-held ((perf-metrics-lock registry))
          (maphash (lambda (name bucket)
                     (let ((stats (metric-bucket-stats bucket)))
                       (when (plusp (getf stats :count))
                         (push (cons name stats) bucket-list))))
                   (perf-metrics-metrics registry)))
        (setf (getf result :metric-buckets)
              (sort bucket-list #'string< :key (lambda (c) (symbol-name (car c))))))
      ;; Counters summary
      (let ((counter-list '()))
        (bt:with-lock-held ((perf-metrics-counters-lock registry))
          (maphash (lambda (name value)
                     (push (cons name value) counter-list))
                   (perf-metrics-counters registry)))
        (setf (getf result :counters)
              (sort counter-list #'string< :key (lambda (c) (symbol-name (car c)))))))
    ;; Anomalies
    (setf (getf result :anomalies) (detect-anomalies))
    ;; SLA status
    (setf (getf result :sla-status) (evaluate-all-sla-targets))
    result))

;;; ---------------------------------------------------------------------------
;;; Monitoring REPL utilities
;;; ---------------------------------------------------------------------------

(defun monitoring-status (&optional (stream *standard-output*))
  "Print comprehensive monitoring status to STREAM.

Combines performance metrics, anomalies, drift detection, and SLA status
into a single operational overview."
  (let ((metrics (aggregate-dashboard-metrics)))
    (format stream "~&╔══════════════════════════════════════════════╗~%")
    (format stream   "║        EVE-GATE MONITORING STATUS             ║~%")
    (format stream   "╚══════════════════════════════════════════════╝~%~%")
    ;; Uptime
    (format stream "  Uptime: ~A~%~%" (format-uptime (getf metrics :uptime-seconds 0)))
    ;; Throughput
    (when-let ((tp (getf metrics :throughput)))
      (format stream "  Throughput:~%")
      (format stream "    Current:  ~,1F req/s~%" (getf tp :current 0.0))
      (format stream "    Average:  ~,1F req/s~%" (getf tp :average 0.0))
      (format stream "    Total:    ~D requests~%~%" (getf tp :total 0)))
    ;; Latency
    (when-let ((lat (getf metrics :request-latency)))
      (format stream "  Request Latency:~%")
      (format stream "    Mean: ~,2Fms  p50: ~,2Fms  p95: ~,2Fms  p99: ~,2Fms~%~%"
              (getf lat :mean 0.0d0)
              (getf lat :p50 0.0d0)
              (getf lat :p95 0.0d0)
              (getf lat :p99 0.0d0)))
    ;; Cache
    (when-let ((cache (getf metrics :cache-performance)))
      (format stream "  Cache:~%")
      (format stream "    Hit rate:  ~,1F%  (~D hits / ~D misses)~%~%"
              (getf cache :hit-rate 0.0)
              (getf cache :hits 0)
              (getf cache :misses 0)))
    ;; Errors
    (when-let ((errs (getf metrics :error-rate)))
      (format stream "  Errors:~%")
      (format stream "    Total: ~D  Rate-limit: ~D  Network: ~D  Auth: ~D~%~%"
              (getf errs :total-errors 0)
              (getf errs :rate-limit-errors 0)
              (getf errs :network-errors 0)
              (getf errs :auth-errors 0)))
    ;; Anomalies
    (let ((anomalies (getf metrics :anomalies)))
      (when anomalies
        (format stream "  Anomalies Detected:~%")
        (dolist (a anomalies)
          (format stream "    [~A] ~A~%"
                  (string-upcase (symbol-name (anomaly-severity a)))
                  (anomaly-message a)))
        (format stream "~%")))
    ;; Drift
    (when *active-baseline*
      (let ((drifts (detect-performance-drift)))
        (when drifts
          (format stream "  Performance Drift:~%")
          (dolist (d drifts)
            (format stream "    [~A] ~A: ~,1F% (baseline=~,2F, current=~,2F)~%"
                    (string-upcase (symbol-name (drift-result-severity d)))
                    (drift-result-metric-name d)
                    (drift-result-drift-percent d)
                    (drift-result-baseline-value d)
                    (drift-result-current-value d)))
          (format stream "~%"))))
    ;; SLA
    (let ((sla (getf metrics :sla-status)))
      (when sla
        (format stream "  SLA Status:~%")
        (dolist (s sla)
          (format stream "    ~A ~A: ~,2F (margin: ~,2F)~%"
                  (if (sla-status-compliant-p s) "[OK]" "[!!]")
                  (sla-target-name (sla-status-target s))
                  (sla-status-current-value s)
                  (sla-status-margin s)))
        (format stream "~%")))
    (format stream "~%")
    metrics))
