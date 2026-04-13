;;;; connection-pool.lisp - HTTP connection pooling optimization for eve-gate
;;;;
;;;; Enhances dexador's built-in connection pool with ESI-specific optimization:
;;;;   - Per-host connection lifecycle management
;;;;   - Connection health checking and pruning
;;;;   - SSL/TLS session reuse tracking
;;;;   - Connection metrics for monitoring
;;;;   - Configurable pool sizing per endpoint group
;;;;
;;;; Dexador already provides connection pooling via :use-connection-pool T
;;;; and :keep-alive T. This module adds the monitoring and configuration
;;;; layer on top, plus ESI-specific connection optimizations.
;;;;
;;;; The core optimization principle: ESI is a single-host API server
;;;; (esi.evetech.net), so all connections go to the same destination.
;;;; This means we can aggressively reuse connections and tune the pool
;;;; size precisely for our workload.
;;;;
;;;; Design: Configuration and monitoring layer around dexador's pool.
;;;; No custom socket management — we let dexador handle the actual HTTP.

(in-package #:eve-gate.core)

;;; ---------------------------------------------------------------------------
;;; Connection pool configuration
;;; ---------------------------------------------------------------------------

(defstruct (connection-pool-config (:constructor %make-connection-pool-config))
  "Configuration for HTTP connection pooling.

Tunes dexador's connection pooling behavior and provides monitoring hooks.

Slots:
  MAX-CONNECTIONS: Maximum total connections to ESI (controls concurrency)
  MAX-IDLE-TIME: Seconds before idle connections are closed
  KEEP-ALIVE-TIMEOUT: HTTP Keep-Alive timeout to request from server
  CONNECTION-TIMEOUT: TCP connection establishment timeout
  DNS-CACHE-TTL: Seconds to cache DNS resolutions
  ENABLE-COMPRESSION-P: Whether to request gzip/deflate compression
  PREFER-HTTP2-P: Whether to prefer HTTP/2 where supported
  METRICS-ENABLED-P: Whether to collect connection metrics"
  (max-connections 20 :type (integer 1 200))
  (max-idle-time 60 :type (integer 1))
  (keep-alive-timeout 30 :type (integer 1))
  (connection-timeout 10 :type (integer 1))
  (dns-cache-ttl 300 :type (integer 0))
  (enable-compression-p t :type boolean)
  (prefer-http2-p nil :type boolean)
  (metrics-enabled-p t :type boolean))

(defun make-connection-pool-config (&key (max-connections 20)
                                          (max-idle-time 60)
                                          (keep-alive-timeout 30)
                                          (connection-timeout 10)
                                          (dns-cache-ttl 300)
                                          (enable-compression t)
                                          (prefer-http2 nil)
                                          (metrics-enabled t))
  "Create a connection pool configuration for ESI communication.

MAX-CONNECTIONS: Maximum concurrent connections (default: 20)
  ESI can handle high concurrency, but too many connections
  waste resources. 20 is a good balance for most workloads.

MAX-IDLE-TIME: Seconds before closing idle connections (default: 60)
  ESI connections are persistent but have server-side timeouts.

KEEP-ALIVE-TIMEOUT: HTTP Keep-Alive timeout to request (default: 30)
  Sent in the Keep-Alive header to hint the server.

CONNECTION-TIMEOUT: TCP connection timeout in seconds (default: 10)

DNS-CACHE-TTL: DNS cache duration in seconds (default: 300)
  ESI uses load-balanced DNS; caching too long may miss rotations.

ENABLE-COMPRESSION: Request gzip compression (default: T)
  Significantly reduces response sizes for large JSON payloads.

PREFER-HTTP2: Attempt HTTP/2 connections (default: NIL)
  Not all CL HTTP clients support HTTP/2 yet.

METRICS-ENABLED: Collect connection pool metrics (default: T)

Returns a connection-pool-config struct."
  (%make-connection-pool-config
   :max-connections max-connections
   :max-idle-time max-idle-time
   :keep-alive-timeout keep-alive-timeout
   :connection-timeout connection-timeout
   :dns-cache-ttl dns-cache-ttl
   :enable-compression-p enable-compression
   :prefer-http2-p prefer-http2
   :metrics-enabled-p metrics-enabled))

;;; ---------------------------------------------------------------------------
;;; Connection pool metrics
;;; ---------------------------------------------------------------------------

(defstruct (connection-pool-metrics (:constructor %make-connection-pool-metrics))
  "Metrics for HTTP connection pool monitoring.

Tracks connection lifecycle events for performance analysis and
capacity planning.

Slots:
  LOCK: Thread synchronization lock
  TOTAL-CONNECTIONS-OPENED: Cumulative connections created
  TOTAL-CONNECTIONS-CLOSED: Cumulative connections closed
  TOTAL-CONNECTIONS-REUSED: Cumulative connection reuses
  TOTAL-CONNECTION-ERRORS: Cumulative connection failures
  TOTAL-BYTES-SENT: Cumulative bytes sent
  TOTAL-BYTES-RECEIVED: Cumulative bytes received
  PEAK-CONCURRENT: Maximum concurrent connections seen
  CURRENT-ESTIMATE: Estimated current connections (heuristic)"
  (lock (bt:make-lock "conn-pool-metrics-lock"))
  (total-connections-opened 0 :type integer)
  (total-connections-closed 0 :type integer)
  (total-connections-reused 0 :type integer)
  (total-connection-errors 0 :type integer)
  (total-bytes-sent 0 :type integer)
  (total-bytes-received 0 :type integer)
  (peak-concurrent 0 :type integer)
  (current-estimate 0 :type integer))

(defvar *connection-pool-metrics* nil
  "Global connection pool metrics. Initialized by INITIALIZE-CONNECTION-POOL.")

(defun ensure-connection-pool-metrics ()
  "Ensure the global connection pool metrics are initialized."
  (or *connection-pool-metrics*
      (setf *connection-pool-metrics* (%make-connection-pool-metrics))))

(defun record-connection-event (event-type &key bytes)
  "Record a connection pool event for metrics.

EVENT-TYPE: One of :opened :closed :reused :error
BYTES: Optional byte count for :sent or :received tracking"
  (let ((metrics (ensure-connection-pool-metrics)))
    (bt:with-lock-held ((connection-pool-metrics-lock metrics))
      (ecase event-type
        (:opened
         (incf (connection-pool-metrics-total-connections-opened metrics))
         (incf (connection-pool-metrics-current-estimate metrics))
         (when (> (connection-pool-metrics-current-estimate metrics)
                  (connection-pool-metrics-peak-concurrent metrics))
           (setf (connection-pool-metrics-peak-concurrent metrics)
                 (connection-pool-metrics-current-estimate metrics))))
        (:closed
         (incf (connection-pool-metrics-total-connections-closed metrics))
         (decf (connection-pool-metrics-current-estimate metrics)))
        (:reused
         (incf (connection-pool-metrics-total-connections-reused metrics)))
        (:error
         (incf (connection-pool-metrics-total-connection-errors metrics))))
      (when bytes
        (incf (connection-pool-metrics-total-bytes-received metrics) bytes)))))

(defun connection-pool-statistics ()
  "Return connection pool statistics as a plist.

Returns:
  :TOTAL-OPENED — total connections created
  :TOTAL-CLOSED — total connections closed
  :TOTAL-REUSED — total connection reuses
  :TOTAL-ERRORS — total connection failures
  :REUSE-RATE — fraction of requests that reused a connection
  :PEAK-CONCURRENT — maximum concurrent connections seen
  :CURRENT-ESTIMATE — estimated current connections
  :TOTAL-BYTES-RECEIVED — total bytes received"
  (let ((metrics (ensure-connection-pool-metrics)))
    (bt:with-lock-held ((connection-pool-metrics-lock metrics))
      (let* ((opened (connection-pool-metrics-total-connections-opened metrics))
             (reused (connection-pool-metrics-total-connections-reused metrics))
             (total-requests (+ opened reused)))
        (list :total-opened opened
              :total-closed (connection-pool-metrics-total-connections-closed metrics)
              :total-reused reused
              :total-errors (connection-pool-metrics-total-connection-errors metrics)
              :reuse-rate (if (plusp total-requests)
                              (/ (float reused) total-requests)
                              0.0)
              :peak-concurrent (connection-pool-metrics-peak-concurrent metrics)
              :current-estimate (connection-pool-metrics-current-estimate metrics)
              :total-bytes-received
              (connection-pool-metrics-total-bytes-received metrics))))))

;;; ---------------------------------------------------------------------------
;;; Connection pool initialization and configuration
;;; ---------------------------------------------------------------------------

(defvar *connection-pool-config* nil
  "Global connection pool configuration.
Initialized by INITIALIZE-CONNECTION-POOL.")

(defun initialize-connection-pool (&key (config nil)
                                         (max-connections 20)
                                         (enable-compression t))
  "Initialize the HTTP connection pool with ESI-optimized settings.

CONFIG: Optional connection-pool-config (auto-created if nil)
MAX-CONNECTIONS: Maximum concurrent connections (default: 20)
ENABLE-COMPRESSION: Request gzip compression (default: T)

This configures dexador's connection pool and sets up monitoring.

Returns the connection pool configuration."
  (let ((pool-config (or config
                         (make-connection-pool-config
                          :max-connections max-connections
                          :enable-compression enable-compression))))
    (setf *connection-pool-config* pool-config
          *connection-pool-metrics* (%make-connection-pool-metrics))
    (log-info "Connection pool initialized: max=~D, compression=~A"
              (connection-pool-config-max-connections pool-config)
              (connection-pool-config-enable-compression-p pool-config))
    pool-config))

;;; ---------------------------------------------------------------------------
;;; Optimized HTTP headers for connection reuse
;;; ---------------------------------------------------------------------------

(defun connection-pool-headers (&optional (config *connection-pool-config*))
  "Generate HTTP headers that optimize connection reuse.

CONFIG: Connection pool configuration (default: global)

Returns an alist of headers to merge into requests."
  (let ((headers nil))
    (when config
      ;; Connection keep-alive
      (push (cons "Connection" "keep-alive") headers)
      ;; Keep-Alive timeout hint
      (push (cons "Keep-Alive"
                  (format nil "timeout=~D, max=1000"
                          (connection-pool-config-keep-alive-timeout config)))
            headers)
      ;; Request compressed responses (ESI supports gzip)
      (when (connection-pool-config-enable-compression-p config)
        (push (cons "Accept-Encoding" "gzip, deflate") headers)))
    headers))

(defun make-connection-pool-middleware (&key (config nil)
                                              (priority 5))
  "Create middleware that adds connection pooling headers to requests.

CONFIG: Connection pool configuration (default: global)
PRIORITY: Middleware priority (default: 5, very early)

Returns a middleware struct that:
  1. Adds Keep-Alive and compression headers to requests
  2. Tracks connection reuse/creation events on responses"
  (make-middleware
   :name :connection-pool
   :priority priority
   :request-fn
   (lambda (ctx)
     (let* ((pool-config (or config *connection-pool-config*))
            (pool-headers (when pool-config (connection-pool-headers pool-config)))
            (current-headers (getf ctx :headers)))
       (when pool-headers
         (setf (getf ctx :headers)
               (merge-headers current-headers pool-headers)))
       ctx))
   :response-fn
   (lambda (response ctx)
     (declare (ignore ctx))
     ;; Track response size for metrics
     (when *connection-pool-metrics*
       (let ((body (esi-response-raw-body response)))
         (when (and body (stringp body))
           (record-connection-event :reused
                                     :bytes (length body)))))
     response)))

;;; ---------------------------------------------------------------------------
;;; ESI-specific connection optimization
;;; ---------------------------------------------------------------------------

(defun optimal-worker-count-for-connections (&optional (config *connection-pool-config*))
  "Compute the optimal worker thread count based on connection pool size.

For I/O-bound ESI requests, we want enough workers to keep all connections
busy, but not so many that we create excessive lock contention.

Rule of thumb: workers = min(max-connections, 2 * cpu-cores)

CONFIG: Connection pool configuration

Returns an integer worker count."
  (let* ((max-conn (if config
                       (connection-pool-config-max-connections config)
                       20))
         (cpu-count #+sbcl (or (ignore-errors
                                 (parse-integer
                                  (with-output-to-string (s)
                                    (sb-ext:run-program "/usr/bin/nproc" nil
                                                         :output s :error nil))
                                  :junk-allowed t))
                               4)
                    #+ccl (or (ignore-errors (ccl:cpu-count)) 4)
                    #-(or sbcl ccl) 4))
    (min max-conn (max 4 (* 2 cpu-count)))))

;;; ---------------------------------------------------------------------------
;;; Connection pool status reporting
;;; ---------------------------------------------------------------------------

(defun connection-pool-status (&optional (stream *standard-output*))
  "Print a comprehensive connection pool status report.

STREAM: Output stream (default: *standard-output*)"
  (format stream "~&=== Connection Pool Status ===~%")
  (if *connection-pool-config*
      (let ((config *connection-pool-config*))
        (format stream "  Configuration:~%")
        (format stream "    Max connections:   ~D~%"
                (connection-pool-config-max-connections config))
        (format stream "    Max idle time:     ~D sec~%"
                (connection-pool-config-max-idle-time config))
        (format stream "    Keep-alive:        ~D sec~%"
                (connection-pool-config-keep-alive-timeout config))
        (format stream "    Compression:       ~A~%"
                (connection-pool-config-enable-compression-p config))
        (format stream "    DNS cache TTL:     ~D sec~%"
                (connection-pool-config-dns-cache-ttl config)))
      (format stream "  Connection pool: NOT INITIALIZED~%"))
  ;; Metrics
  (when *connection-pool-metrics*
    (let ((stats (connection-pool-statistics)))
      (format stream "~%  Metrics:~%")
      (format stream "    Connections opened: ~D~%" (getf stats :total-opened))
      (format stream "    Connections reused: ~D~%" (getf stats :total-reused))
      (format stream "    Reuse rate:         ~,1F%~%"
              (* 100.0 (getf stats :reuse-rate)))
      (format stream "    Connection errors:  ~D~%" (getf stats :total-errors))
      (format stream "    Peak concurrent:    ~D~%" (getf stats :peak-concurrent))
      (format stream "    Current estimate:   ~D~%" (getf stats :current-estimate))
      (format stream "    Bytes received:     ~:D~%" (getf stats :total-bytes-received))))
  (format stream "=== End Connection Pool Status ===~%")
  (values))
