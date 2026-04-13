;;;; dashboard.lisp - Operational dashboard for eve-gate
;;;;
;;;; Provides a real-time system status overview for REPL-driven operations.
;;;; Aggregates data from health checks, performance monitoring, alerting,
;;;; and configuration into a unified operational view.
;;;;
;;;; This is the "single pane of glass" for eve-gate operators:
;;;;   - System health at a glance
;;;;   - Key performance indicators (KPIs)
;;;;   - Active alerts and acknowledgment
;;;;   - Historical trends
;;;;   - Quick operational actions
;;;;
;;;; Design: All dashboard functions are read-only aggregators producing
;;;; formatted text output. No side effects except health check execution.
;;;; Suitable for both REPL interaction and programmatic status queries.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Dashboard data collection
;;; ---------------------------------------------------------------------------

(defstruct (dashboard-snapshot (:constructor %make-dashboard-snapshot))
  "Complete operational snapshot for dashboard display.

Slots:
  TIMESTAMP: When the snapshot was collected
  HEALTH: System-health struct
  METRICS: Dashboard metrics plist (from aggregate-dashboard-metrics)
  ALERTS: List of recent alert events
  UNACKED-ALERTS: Count of unacknowledged alerts
  DRIFT: List of drift-result structs
  SLA: List of sla-status structs
  CONFIG-SUMMARY: Configuration summary plist"
  (timestamp (get-universal-time) :type integer)
  (health nil)
  (metrics nil :type list)
  (alerts nil :type list)
  (unacked-alerts 0 :type integer)
  (drift nil :type list)
  (sla nil :type list)
  (config-summary nil :type list))

(defun collect-dashboard-snapshot ()
  "Collect a complete dashboard snapshot of current system state.

Returns a DASHBOARD-SNAPSHOT struct."
  (ensure-health-monitoring)
  (let* ((health (compute-system-health))
         (metrics (aggregate-dashboard-metrics))
         (recent-alerts (alert-history :n 10))
         (unacked (length (unacknowledged-alerts)))
         (drift (when *active-baseline*
                  (detect-performance-drift)))
         (sla (evaluate-all-sla-targets))
         (config-summary
           (when *config-manager*
             (list :environment (config-manager-environment *config-manager*)
                   :initialized (config-manager-initialized-p *config-manager*)
                   :last-reload (config-manager-last-reload-time *config-manager*)))))
    (record-health-snapshot health)
    (%make-dashboard-snapshot
     :health health
     :metrics metrics
     :alerts recent-alerts
     :unacked-alerts unacked
     :drift drift
     :sla sla
     :config-summary config-summary)))

;;; ---------------------------------------------------------------------------
;;; Dashboard display — main view
;;; ---------------------------------------------------------------------------

(defun dashboard (&optional (stream *standard-output*))
  "Display the complete operational dashboard.

This is the primary operator interface — a single command that shows
everything needed to understand system state at a glance.

STREAM: Output stream (default: *standard-output*)

Returns the dashboard snapshot for programmatic use."
  (let ((snap (collect-dashboard-snapshot)))
    (format-dashboard-header stream)
    (format-health-section stream (dashboard-snapshot-health snap))
    (format-kpi-section stream (dashboard-snapshot-metrics snap))
    (format-alerts-section stream
                           (dashboard-snapshot-alerts snap)
                           (dashboard-snapshot-unacked-alerts snap))
    (format-sla-section stream (dashboard-snapshot-sla snap))
    (format-drift-section stream (dashboard-snapshot-drift snap))
    (format-config-section stream (dashboard-snapshot-config-summary snap))
    (format-dashboard-footer stream)
    snap))

;;; ---------------------------------------------------------------------------
;;; Dashboard display — sections
;;; ---------------------------------------------------------------------------

(defun format-dashboard-header (stream)
  "Print the dashboard header."
  (format stream "~&~%")
  (format stream "╔══════════════════════════════════════════════════════════╗~%")
  (format stream "║              EVE-GATE OPERATIONAL DASHBOARD             ║~%")
  (format stream "╠══════════════════════════════════════════════════════════╣~%")
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format stream "║  ~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D UTC   Uptime: ~21A  ║~%"
            year month day hour min sec
            (format-uptime (- (get-universal-time) *system-start-time*))))
  (format stream "╚══════════════════════════════════════════════════════════╝~%~%"))

(defun format-health-section (stream health)
  "Print the health status section."
  (format stream "  ┌─ SYSTEM HEALTH ──────────────────────────────────────┐~%")
  (when health
    (let* ((status (system-health-status health))
           (indicator (ecase status
                        (:healthy   "HEALTHY  ")
                        (:degraded  "DEGRADED ")
                        (:unhealthy "UNHEALTHY")
                        (:unknown   "UNKNOWN  "))))
      (format stream "  │  Overall: ~A                                       │~%"
              indicator)
      (format stream "  │  ~A~52T│~%"
              (system-health-summary health))
      (format stream "  │                                                      │~%")
      (dolist (check (system-health-checks health))
        (let ((mark (ecase (health-check-result-status check)
                      (:healthy   " OK ")
                      (:degraded  " !! ")
                      (:unhealthy " XX ")
                      (:unknown   " ?? "))))
          (format stream "  │  [~A] ~A~47T~5,1Fms │~%"
                  mark
                  (health-check-result-name check)
                  (health-check-result-latency-ms check))))))
  (format stream "  └────────────────────────────────────────────────────┘~%~%"))

(defun format-kpi-section (stream metrics)
  "Print the key performance indicators section."
  (format stream "  ┌─ KEY PERFORMANCE INDICATORS ──────────────────────────┐~%")
  ;; Throughput
  (when-let ((tp (getf metrics :throughput)))
    (format stream "  │  Throughput:  ~6,1F req/s (avg ~,1F)  Total: ~D~18T│~%"
            (getf tp :current 0.0)
            (getf tp :average 0.0)
            (getf tp :total 0)))
  ;; Latency
  (when-let ((lat (getf metrics :request-latency)))
    (format stream "  │  Latency:    p50=~,1Fms  p95=~,1Fms  p99=~,1Fms~18T│~%"
            (getf lat :p50 0.0d0)
            (getf lat :p95 0.0d0)
            (getf lat :p99 0.0d0)))
  ;; Cache
  (when-let ((cache (getf metrics :cache-performance)))
    (format stream "  │  Cache:      ~,1F%% hit rate (~D/~D)~25T│~%"
            (getf cache :hit-rate 0.0)
            (getf cache :hits 0)
            (+ (getf cache :hits 0) (getf cache :misses 0))))
  ;; Errors
  (when-let ((errs (getf metrics :error-rate)))
    (format stream "  │  Errors:     ~D total  (~D rate-limit, ~D network)~11T│~%"
            (getf errs :total-errors 0)
            (getf errs :rate-limit-errors 0)
            (getf errs :network-errors 0)))
  (format stream "  └────────────────────────────────────────────────────┘~%~%"))

(defun format-alerts-section (stream alerts unacked-count)
  "Print the alerts section."
  (format stream "  ┌─ ALERTS (~D unacknowledged) ──────────────────────────┐~%"
          unacked-count)
  (if (null alerts)
      (format stream "  │  No recent alerts                                    │~%")
      (dolist (alert (subseq alerts 0 (min 5 (length alerts))))
        (let ((severity-mark (ecase (alert-event-severity alert)
                               (:info     "INFO")
                               (:warning  "WARN")
                               (:error    "ERR ")
                               (:critical "CRIT")))
              (ack-mark (if (alert-event-acknowledged-p alert) "*" " ")))
          (format stream "  │ ~A[~A] ~A: ~A~47T│~%"
                  ack-mark severity-mark
                  (alert-event-name alert)
                  (subseq (alert-event-message alert)
                          0 (min 35 (length (alert-event-message alert))))))))
  (format stream "  └────────────────────────────────────────────────────┘~%~%"))

(defun format-sla-section (stream sla-statuses)
  "Print the SLA compliance section."
  (when sla-statuses
    (format stream "  ┌─ SLA COMPLIANCE ────────────────────────────────────┐~%")
    (dolist (status sla-statuses)
      (let* ((target (sla-status-target status))
             (mark (if (sla-status-compliant-p status) " OK " "FAIL")))
        (format stream "  │  [~A] ~A: ~,2F (margin: ~,2F)~30T│~%"
                mark
                (sla-target-name target)
                (sla-status-current-value status)
                (sla-status-margin status))))
    (format stream "  └────────────────────────────────────────────────────┘~%~%")))

(defun format-drift-section (stream drifts)
  "Print the performance drift section."
  (when drifts
    (format stream "  ┌─ PERFORMANCE DRIFT ──────────────────────────────────┐~%")
    (dolist (d drifts)
      (format stream "  │  [~A] ~A: ~@[~A~]~,1F%%~30T│~%"
              (if (eq (drift-result-severity d) :critical) "CRIT" "WARN")
              (drift-result-metric-name d)
              (when (plusp (drift-result-drift-percent d)) "+")
              (drift-result-drift-percent d)))
    (format stream "  └────────────────────────────────────────────────────┘~%~%")))

(defun format-config-section (stream config-summary)
  "Print the configuration section."
  (when config-summary
    (format stream "  ┌─ CONFIGURATION ─────────────────────────────────────┐~%")
    (format stream "  │  Environment: ~A~44T│~%"
            (or (getf config-summary :environment) "unset"))
    (format stream "  │  Initialized: ~A~44T│~%"
            (getf config-summary :initialized))
    (when-let ((reload-time (getf config-summary :last-reload)))
      (when (plusp reload-time)
        (format stream "  │  Last reload: ~A ago~36T│~%"
                (format-uptime (- (get-universal-time) reload-time)))))
    (format stream "  └────────────────────────────────────────────────────┘~%~%")))

(defun format-dashboard-footer (stream)
  "Print the dashboard footer with quick action hints."
  (format stream "  Quick actions:~%")
  (format stream "    (dashboard)                  - Refresh this view~%")
  (format stream "    (print-system-health)        - Detailed health checks~%")
  (format stream "    (monitoring-status)           - Full monitoring report~%")
  (format stream "    (alerting-status)             - Alert management~%")
  (format stream "    (acknowledge-all-alerts)      - Ack all alerts~%")
  (format stream "    (performance-report)          - Performance details~%")
  (format stream "    (sla-compliance-report)       - SLA report~%")
  (format stream "    (capture-performance-baseline)- Set baseline~%")
  (format stream "~%"))

;;; ---------------------------------------------------------------------------
;;; Quick status functions
;;; ---------------------------------------------------------------------------

(defun quick-status ()
  "Return a one-line status string suitable for prompt display or quick checks.

Returns a string like \"HEALTHY | 5.2 req/s | 98.1% cache | 0 alerts\"."
  (ensure-health-monitoring)
  (let* ((health (compute-system-health))
         (status-str (string-upcase (symbol-name (system-health-status health))))
         (throughput (if *esi-perf-monitor*
                         (throughput-rate
                          (esi-perf-monitor-throughput *esi-perf-monitor*)
                          :window 10)
                         0.0))
         (cache-rate (if *esi-perf-monitor*
                         (let* ((hits (latency-histogram-total-count
                                       (esi-perf-monitor-cache-hit-histogram
                                        *esi-perf-monitor*)))
                                (misses (latency-histogram-total-count
                                         (esi-perf-monitor-cache-miss-histogram
                                          *esi-perf-monitor*)))
                                (total (+ hits misses)))
                           (if (plusp total)
                               (* 100.0 (/ hits (float total)))
                               0.0))
                         0.0))
         (unacked (length (unacknowledged-alerts))))
    (format nil "~A | ~,1F req/s | ~,1F% cache | ~D alert~:P"
            status-str throughput cache-rate unacked)))

(defun compact-dashboard (&optional (stream *standard-output*))
  "Display a compact single-section dashboard.

Useful for quick REPL checks without the full dashboard."
  (ensure-health-monitoring)
  (format stream "~&~A~%" (quick-status))
  (let ((health (compute-system-health)))
    (dolist (check (system-health-checks health))
      (format stream "  ~A ~A (~,1Fms)~%"
              (ecase (health-check-result-status check)
                (:healthy   "[OK]")
                (:degraded  "[!!]")
                (:unhealthy "[XX]")
                (:unknown   "[??]"))
              (health-check-result-name check)
              (health-check-result-latency-ms check))))
  (let ((unacked (unacknowledged-alerts)))
    (when unacked
      (format stream "  Alerts: ~D unacknowledged~%" (length unacked))))
  (values))

;;; ---------------------------------------------------------------------------
;;; Combined initialization
;;; ---------------------------------------------------------------------------

(defun initialize-monitoring-subsystem (&key (health-check-interval 60)
                                              (enable-sweep t)
                                              (enable-alerting t)
                                              (register-default-sla t)
                                              webhook-url)
  "Initialize the complete monitoring, health, and alerting subsystem.

This is the single entry point for setting up all production monitoring.

HEALTH-CHECK-INTERVAL: Seconds between health check sweeps (default: 60)
ENABLE-SWEEP: Start the background health check thread (default: T)
ENABLE-ALERTING: Initialize the alerting system (default: T)
REGISTER-DEFAULT-SLA: Define default SLA targets (default: T)
WEBHOOK-URL: Optional webhook for external alert delivery

Returns T."
  ;; Initialize health monitoring
  (initialize-health-monitoring)
  ;; Initialize alerting
  (when enable-alerting
    (initialize-alerting :webhook-url webhook-url))
  ;; Register default SLA targets
  (when register-default-sla
    (define-sla-target :p95-latency :request-latency
                       :max-value 1000.0 :percentile 0.95
                       :window-seconds 300)
    (define-sla-target :p99-latency :request-latency
                       :max-value 5000.0 :percentile 0.99
                       :window-seconds 300)
    (define-sla-target :min-throughput :throughput
                       :min-value 1.0
                       :window-seconds 60))
  ;; Start background health check sweep
  (when enable-sweep
    (start-health-check-sweep :interval health-check-interval))
  ;; Capture initial baseline
  (capture-performance-baseline :name :initial
                                 :description "System initialization baseline")
  (log-info "Monitoring subsystem initialized (sweep=~A, alerting=~A, SLA=~A)"
            enable-sweep enable-alerting register-default-sla)
  t)

(defun shutdown-monitoring-subsystem ()
  "Shut down the monitoring subsystem cleanly.

Stops background threads and cleans up resources."
  (stop-health-check-sweep)
  (setf *health-system-initialized-p* nil
        *alerting-initialized-p* nil)
  (log-info "Monitoring subsystem shut down")
  (values))
