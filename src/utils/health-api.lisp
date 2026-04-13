;;;; health-api.lisp - Health check HTTP API for eve-gate
;;;;
;;;; Provides structured health check endpoints suitable for:
;;;;   - Load balancer health probes
;;;;   - Kubernetes liveness/readiness probes
;;;;   - External monitoring system integration
;;;;   - Operational diagnostic endpoints
;;;;
;;;; The API produces JSON responses conforming to common health check
;;;; conventions (RFC draft health check response format).
;;;;
;;;; This module does NOT start an HTTP server itself. Instead, it provides
;;;; handler functions that can be mounted on any HTTP server (Hunchentoot,
;;;; Clack, etc.) via the integration functions.
;;;;
;;;; Endpoints:
;;;;   /health         - Overall health status (for load balancers)
;;;;   /health/live    - Liveness probe (process alive and responsive)
;;;;   /health/ready   - Readiness probe (ready to serve traffic)
;;;;   /health/detail  - Detailed subsystem health (for diagnostics)
;;;;   /health/metrics - Performance metrics snapshot
;;;;
;;;; Design: All handler functions return (values body status-code headers).
;;;; The caller (HTTP server integration) is responsible for writing the
;;;; response. This keeps the core logic server-agnostic.

(in-package #:eve-gate.utils)

;;; ---------------------------------------------------------------------------
;;; Response formatting helpers
;;; ---------------------------------------------------------------------------

(defun health-status-to-http-code (status)
  "Map a health status keyword to an HTTP status code.

:healthy   -> 200 OK
:degraded  -> 200 OK (service is available but impaired)
:unhealthy -> 503 Service Unavailable
:unknown   -> 503 Service Unavailable"
  (ecase status
    (:healthy   200)
    (:degraded  200)
    (:unhealthy 503)
    (:unknown   503)))

(defun plist-to-json-hash (plist)
  "Convert a plist to a hash-table suitable for JSON serialization via jzon.
Keyword keys are converted to lowercase-hyphenated strings."
  (let ((ht (make-hash-table :test 'equal)))
    (loop for (k v) on plist by #'cddr
          do (setf (gethash (string-downcase (symbol-name k)) ht)
                   (cond
                     ((keywordp v) (string-downcase (symbol-name v)))
                     ((typep v 'boolean) v)  ; T or NIL handled by jzon
                     (t v))))
    ht))

(defun health-result-to-json (result)
  "Convert a HEALTH-CHECK-RESULT to a JSON-serializable hash-table."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "name" ht)
          (string-downcase (symbol-name (health-check-result-name result))))
    (setf (gethash "status" ht)
          (string-downcase (symbol-name (health-check-result-status result))))
    (setf (gethash "message" ht) (health-check-result-message result))
    (setf (gethash "latency_ms" ht)
          (health-check-result-latency-ms result))
    (setf (gethash "timestamp" ht)
          (format-log-timestamp (health-check-result-timestamp result)
                                (get-internal-real-time)))
    (when (health-check-result-details result)
      (setf (gethash "details" ht)
            (plist-to-json-hash (health-check-result-details result))))
    ht))

(defun system-health-to-json (health)
  "Convert a SYSTEM-HEALTH to a JSON-serializable hash-table."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "status" ht)
          (string-downcase (symbol-name (system-health-status health))))
    (setf (gethash "summary" ht) (system-health-summary health))
    (setf (gethash "timestamp" ht)
          (format-log-timestamp (system-health-timestamp health)
                                (get-internal-real-time)))
    (setf (gethash "uptime_seconds" ht) (system-health-uptime-seconds health))
    (setf (gethash "checks" ht)
          (mapcar #'health-result-to-json (system-health-checks health)))
    ht))

;;; ---------------------------------------------------------------------------
;;; Health check endpoint handlers
;;; ---------------------------------------------------------------------------

(defun handle-health-check ()
  "Handler for /health — overall health status.

Returns (values json-body http-status-code content-type).

Response format:
  {
    \"status\": \"healthy\"|\"degraded\"|\"unhealthy\",
    \"summary\": \"HEALTHY: 5/5 healthy\",
    \"timestamp\": \"2026-04-13T12:00:00.000Z\",
    \"uptime_seconds\": 3600
  }"
  (ensure-health-monitoring)
  (let* ((health (compute-system-health))
         (ht (make-hash-table :test 'equal)))
    (record-health-snapshot health)
    (setf (gethash "status" ht)
          (string-downcase (symbol-name (system-health-status health))))
    (setf (gethash "summary" ht) (system-health-summary health))
    (setf (gethash "timestamp" ht)
          (format-log-timestamp (system-health-timestamp health)
                                (get-internal-real-time)))
    (setf (gethash "uptime_seconds" ht) (system-health-uptime-seconds health))
    (values (com.inuoe.jzon:stringify ht :pretty t)
            (health-status-to-http-code (system-health-status health))
            "application/json")))

(defun handle-liveness-probe ()
  "Handler for /health/live — liveness probe.

A liveness probe checks whether the process is alive and responsive.
This is a minimal check: if we can execute this function, we're alive.

Returns (values json-body 200 content-type)."
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "status" ht) "alive")
    (setf (gethash "timestamp" ht)
          (format-log-timestamp (get-universal-time) (get-internal-real-time)))
    (values (com.inuoe.jzon:stringify ht)
            200
            "application/json")))

(defun handle-readiness-probe ()
  "Handler for /health/ready — readiness probe.

A readiness probe checks whether the system is ready to serve traffic.
Checks that critical subsystems are initialized and functional.

Returns (values json-body status-code content-type)."
  (ensure-health-monitoring)
  (let* ((health (compute-system-health))
         (ready-p (member (system-health-status health) '(:healthy :degraded)))
         (ht (make-hash-table :test 'equal)))
    (setf (gethash "ready" ht) (if ready-p t :false))
    (setf (gethash "status" ht)
          (string-downcase (symbol-name (system-health-status health))))
    (setf (gethash "timestamp" ht)
          (format-log-timestamp (get-universal-time) (get-internal-real-time)))
    (values (com.inuoe.jzon:stringify ht)
            (if ready-p 200 503)
            "application/json")))

(defun handle-health-detail ()
  "Handler for /health/detail — detailed subsystem health.

Returns comprehensive health information for all subsystems.

Returns (values json-body status-code content-type)."
  (ensure-health-monitoring)
  (let* ((health (compute-system-health))
         (json (system-health-to-json health)))
    (record-health-snapshot health)
    (values (com.inuoe.jzon:stringify json :pretty t)
            (health-status-to-http-code (system-health-status health))
            "application/json")))

(defun handle-health-metrics ()
  "Handler for /health/metrics — performance metrics snapshot.

Returns current performance metrics in a JSON format suitable for
ingestion by monitoring systems (Prometheus, Grafana, etc.).

Returns (values json-body 200 content-type)."
  (let* ((metrics (aggregate-dashboard-metrics))
         (ht (make-hash-table :test 'equal)))
    ;; Throughput
    (when-let ((tp (getf metrics :throughput)))
      (setf (gethash "throughput" ht) (plist-to-json-hash tp)))
    ;; Latency
    (when-let ((lat (getf metrics :request-latency)))
      (setf (gethash "request_latency" ht) (plist-to-json-hash lat)))
    ;; Cache
    (when-let ((cache (getf metrics :cache-performance)))
      (setf (gethash "cache" ht) (plist-to-json-hash cache)))
    ;; Errors
    (when-let ((errs (getf metrics :error-rate)))
      (setf (gethash "errors" ht) (plist-to-json-hash errs)))
    ;; Counters
    (let ((counter-ht (make-hash-table :test 'equal)))
      (dolist (pair (getf metrics :counters))
        (setf (gethash (string-downcase (symbol-name (car pair))) counter-ht)
              (cdr pair)))
      (when (plusp (hash-table-count counter-ht))
        (setf (gethash "counters" ht) counter-ht)))
    ;; Timestamp and uptime
    (setf (gethash "timestamp" ht)
          (format-log-timestamp (get-universal-time) (get-internal-real-time)))
    (setf (gethash "uptime_seconds" ht) (getf metrics :uptime-seconds 0))
    (values (com.inuoe.jzon:stringify ht :pretty t)
            200
            "application/json")))

(defun handle-health-history (&key (n 20))
  "Handler for /health/history — health check history.

N: Number of historical snapshots to return (default: 20)

Returns (values json-body 200 content-type)."
  (let* ((history (health-history n))
         (entries (mapcar (lambda (h)
                            (let ((ht (make-hash-table :test 'equal)))
                              (setf (gethash "status" ht)
                                    (string-downcase
                                     (symbol-name (system-health-status h))))
                              (setf (gethash "summary" ht) (system-health-summary h))
                              (setf (gethash "timestamp" ht)
                                    (format-log-timestamp
                                     (system-health-timestamp h)
                                     (get-internal-real-time)))
                              ht))
                          history))
         (ht (make-hash-table :test 'equal)))
    (setf (gethash "count" ht) (length entries))
    (setf (gethash "history" ht) entries)
    (values (com.inuoe.jzon:stringify ht :pretty t)
            200
            "application/json")))

(defun handle-alert-status ()
  "Handler for /health/alerts — current alert status.

Returns (values json-body 200 content-type)."
  (let* ((unacked (unacknowledged-alerts))
         (recent (alert-history :n 20))
         (ht (make-hash-table :test 'equal)))
    (setf (gethash "unacknowledged_count" ht) (length unacked))
    (setf (gethash "total_fired" ht) (counter-value :alerts-fired))
    (setf (gethash "recent" ht)
          (mapcar (lambda (a)
                    (let ((aht (make-hash-table :test 'equal)))
                      (setf (gethash "id" aht) (alert-event-id a))
                      (setf (gethash "name" aht)
                            (string-downcase (symbol-name (alert-event-name a))))
                      (setf (gethash "severity" aht)
                            (string-downcase (symbol-name (alert-event-severity a))))
                      (setf (gethash "message" aht) (alert-event-message a))
                      (setf (gethash "acknowledged" aht) (alert-event-acknowledged-p a))
                      (setf (gethash "timestamp" aht)
                            (format-log-timestamp (alert-event-timestamp a)
                                                  (get-internal-real-time)))
                      aht))
                  recent))
    (values (com.inuoe.jzon:stringify ht :pretty t)
            200
            "application/json")))

;;; ---------------------------------------------------------------------------
;;; Route table for HTTP server integration
;;; ---------------------------------------------------------------------------

(defvar *health-api-routes*
  '(("/health"         :get handle-health-check)
    ("/health/live"    :get handle-liveness-probe)
    ("/health/ready"   :get handle-readiness-probe)
    ("/health/detail"  :get handle-health-detail)
    ("/health/metrics" :get handle-health-metrics)
    ("/health/history" :get handle-health-history)
    ("/health/alerts"  :get handle-alert-status))
  "Route table mapping paths to handler functions.

Each entry is (path method handler-function).
Use this to mount health endpoints on an HTTP server.")

(defun dispatch-health-request (path &key (method :get))
  "Dispatch a health API request to the appropriate handler.

PATH: The request path (e.g., \"/health\" or \"/health/ready\")
METHOD: HTTP method keyword (default: :get)

Returns (values body status-code content-type) or NIL if no matching route."
  (let ((route (find-if (lambda (r)
                          (and (string= (first r) path)
                               (eq (second r) method)))
                        *health-api-routes*)))
    (when route
      (funcall (third route)))))

;;; ---------------------------------------------------------------------------
;;; REPL inspection
;;; ---------------------------------------------------------------------------

(defun test-health-endpoints (&optional (stream *standard-output*))
  "Test all health API endpoints and display their responses.

Useful for verifying the health API works before deploying.

STREAM: Output stream (default: *standard-output*)"
  (ensure-health-monitoring)
  (ensure-alerting)
  (dolist (route *health-api-routes*)
    (let ((path (first route)))
      (format stream "~&--- ~A ---~%" path)
      (handler-case
          (multiple-value-bind (body status content-type)
              (funcall (third route))
            (format stream "  Status: ~D  Content-Type: ~A~%" status content-type)
            (format stream "  Body: ~A~%~%" (subseq body 0 (min 200 (length body)))))
        (error (e)
          (format stream "  ERROR: ~A~%~%" e)))))
  (values))
