;;;; parallel-client.lisp - High-level parallel API client for eve-gate
;;;;
;;;; Provides a user-facing parallel client that wraps the concurrent engine,
;;;; parallel executor, and worker pools into a single ergonomic interface.
;;;; This is the recommended entry point for applications that need concurrent
;;;; ESI API access.
;;;;
;;;; The parallel-client manages its own lifecycle (engine, kernel, pools)
;;;; and provides simple methods for common parallel patterns:
;;;;   - parallel-api-call: Single request through the parallel pipeline
;;;;   - parallel-fetch-characters: Batch character info retrieval
;;;;   - parallel-fetch-market-data: Bulk market data collection
;;;;   - parallel-universe-scan: Large-scale universe data fetching
;;;;
;;;; All operations respect ESI rate limits and handle errors gracefully.

(in-package #:eve-gate.concurrent)

;;; ---------------------------------------------------------------------------
;;; Parallel client structure
;;; ---------------------------------------------------------------------------

(defstruct (parallel-client (:constructor %make-parallel-client))
  "High-level parallel client combining engine, executor, and pools.

Slots:
  ENGINE: The concurrent engine for rate-limited HTTP
  DEDUP-CACHE: Request deduplication cache
  WORKER-COUNT: Number of parallel workers
  RUNNING-P: Whether the client has been started
  LOCK: Thread synchronization lock"
  (engine nil :type (or null concurrent-engine))
  (dedup-cache nil :type (or null dedup-cache))
  (worker-count 8 :type (integer 1))
  (running-p nil :type boolean)
  (lock (bt:make-lock "parallel-client-lock")))

(defun make-parallel-client (&key (worker-count 8)
                                    (queue-size 2000)
                                    (global-rate 150.0)
                                    (global-burst 150.0)
                                    http-client
                                    rate-limiter
                                    (dedup t))
  "Create a parallel client for concurrent ESI API access.

WORKER-COUNT: Number of engine worker threads (default: 8)
QUEUE-SIZE: Maximum request queue depth (default: 2000)
GLOBAL-RATE: Rate limit in requests/second (default: 150.0)
GLOBAL-BURST: Burst capacity (default: 150.0)
HTTP-CLIENT: Pre-configured HTTP client (default: auto-created)
RATE-LIMITER: Pre-configured rate limiter (default: auto-created)
DEDUP: Enable request deduplication (default: T)

Returns a parallel-client struct. Call START-PARALLEL-CLIENT to activate.

Example:
  (let ((client (make-parallel-client :worker-count 16)))
    (start-parallel-client client)
    (unwind-protect
         ;; Use the client...
         (parallel-api-call client \"/v5/status/\")
      (stop-parallel-client client)))"
  (%make-parallel-client
   :engine (make-concurrent-engine
            :worker-count worker-count
            :queue-size queue-size
            :global-rate global-rate
            :global-burst global-burst
            :http-client http-client
            :rate-limiter rate-limiter)
   :dedup-cache (when dedup (make-dedup-cache))
   :worker-count worker-count))

;;; ---------------------------------------------------------------------------
;;; Lifecycle
;;; ---------------------------------------------------------------------------

(defun start-parallel-client (client)
  "Start the parallel client, initializing the engine and kernel.

CLIENT: A parallel-client struct

Returns the client."
  (bt:with-lock-held ((parallel-client-lock client))
    (when (parallel-client-running-p client)
      (return-from start-parallel-client client))
    ;; Start the concurrent engine
    (start-engine (parallel-client-engine client))
    ;; Ensure parallel kernel is ready
    (ensure-parallel-kernel :worker-count (parallel-client-worker-count client))
    (setf (parallel-client-running-p client) t)
    (log-info "Parallel client started with ~D workers"
              (parallel-client-worker-count client)))
  client)

(defun stop-parallel-client (client &key (wait t))
  "Stop the parallel client, shutting down engine and kernel.

CLIENT: A parallel-client struct
WAIT: If T, wait for pending work (default: T)

Returns the client."
  (bt:with-lock-held ((parallel-client-lock client))
    (unless (parallel-client-running-p client)
      (return-from stop-parallel-client client))
    (setf (parallel-client-running-p client) nil))
  ;; Stop engine
  (stop-engine (parallel-client-engine client) :wait wait)
  ;; Note: parallel kernel is shared, don't shut it down here
  (log-info "Parallel client stopped")
  client)

(defmacro with-parallel-client ((var &rest args) &body body)
  "Execute BODY with an active parallel client bound to VAR.

Automatically starts and stops the client around BODY.

Example:
  (with-parallel-client (client :worker-count 16)
    (parallel-api-call client \"/v5/status/\"))"
  `(let ((,var (make-parallel-client ,@args)))
     (start-parallel-client ,var)
     (unwind-protect
          (progn ,@body)
       (stop-parallel-client ,var))))

;;; ---------------------------------------------------------------------------
;;; API operations
;;; ---------------------------------------------------------------------------

(defun parallel-api-call (client path &key (method :get)
                                             params
                                             character-id
                                             (priority +priority-normal+)
                                             (timeout 60)
                                             (dedup t))
  "Make a single API call through the parallel client.

If DEDUP is T and an identical request is already in flight, shares
the result instead of making a duplicate HTTP call.

CLIENT: A parallel-client struct
PATH: ESI endpoint path
METHOD: HTTP method (default: :get)
PARAMS: Request parameters plist
CHARACTER-ID: Optional character ID
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Timeout in seconds (default: 60)
DEDUP: Deduplicate identical requests (default: T)

Returns the esi-response, or NIL on failure."
  (let ((engine (parallel-client-engine client)))
    (if (and dedup (parallel-client-dedup-cache client)
             (eq method :get))
        (dedup-fetch engine path
                      :method method
                      :params params
                      :character-id character-id
                      :priority priority
                      :timeout timeout
                      :dedup-cache (parallel-client-dedup-cache client))
        (submit-and-wait engine path
                          :method method
                          :params params
                          :character-id character-id
                          :priority priority
                          :timeout timeout))))

(defun parallel-bulk-fetch (client paths &key params
                                               character-id
                                               (priority +priority-normal+)
                                               (timeout 60)
                                               progress-callback)
  "Fetch multiple endpoints through the parallel client.

CLIENT: A parallel-client struct
PATHS: List of ESI endpoint paths
PARAMS: Shared parameters
CHARACTER-ID: Optional character ID
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-request timeout (default: 60)
PROGRESS-CALLBACK: Optional function (completed total)

Returns a list of response bodies (or NIL for failures)."
  (bulk-get (parallel-client-engine client) paths
            :params params
            :character-id character-id
            :priority priority
            :timeout timeout
            :parallel t
            :progress-callback progress-callback))

(defun parallel-fetch-by-ids (client path-template ids &key params
                                                             character-id
                                                             (priority +priority-normal+)
                                                             (timeout 60)
                                                             progress-callback)
  "Fetch records for a list of IDs using a path template.

CLIENT: A parallel-client struct
PATH-TEMPLATE: Format string with ~A for ID (e.g., \"/v5/characters/~A/\")
IDS: List of IDs
PARAMS: Shared parameters
CHARACTER-ID: Optional character ID
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-request timeout (default: 60)
PROGRESS-CALLBACK: Optional function (completed total)

Returns an alist of (id . body-data) pairs."
  (parallel-map-ids (parallel-client-engine client)
                     path-template ids
                     :params params
                     :character-id character-id
                     :priority priority
                     :timeout timeout
                     :progress-callback progress-callback))

(defun parallel-fetch-pages (client path &key params
                                               character-id
                                               (priority +priority-normal+)
                                               (timeout 120)
                                               (max-pages 100))
  "Fetch all pages of a paginated endpoint through the parallel client.

CLIENT: A parallel-client struct
PATH: ESI endpoint path
PARAMS: Base query parameters
CHARACTER-ID: Optional character ID
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-page timeout (default: 120)
MAX-PAGES: Safety limit (default: 100)

Returns a list of all result data concatenated across pages."
  (parallel-fetch-all-pages (parallel-client-engine client)
                             path
                             :params params
                             :character-id character-id
                             :priority priority
                             :timeout timeout
                             :max-pages max-pages))

;;; ---------------------------------------------------------------------------
;;; Status and diagnostics
;;; ---------------------------------------------------------------------------

(defun parallel-client-status (client &optional (stream *standard-output*))
  "Print a comprehensive status report of the parallel client.

CLIENT: A parallel-client struct
STREAM: Output stream (default: *standard-output*)"
  (format stream "~&=== Parallel Client Status ===~%")
  (format stream "  Running:    ~A~%" (parallel-client-running-p client))
  (format stream "  Workers:    ~D~%" (parallel-client-worker-count client))
  ;; Engine status
  (when (parallel-client-engine client)
    (format stream "~%")
    (engine-status (parallel-client-engine client) stream))
  ;; Dedup stats
  (when (parallel-client-dedup-cache client)
    (let ((stats (dedup-statistics (parallel-client-dedup-cache client))))
      (format stream "~%  Deduplication:~%")
      (format stream "    Total requests: ~D~%" (getf stats :total-requests))
      (format stream "    Deduplicated:   ~D~%" (getf stats :total-deduped))
      (format stream "    Dedup rate:     ~,1F%~%"
              (* 100.0 (getf stats :dedup-rate)))
      (format stream "    Pending:        ~D~%" (getf stats :pending))))
  ;; Parallel kernel
  (format stream "~%  Parallel kernel:~%")
  (if *parallel-kernel*
      (let ((lparallel:*kernel* *parallel-kernel*))
        (format stream "    Workers: ~D~%"
                (lparallel:kernel-worker-count)))
      (format stream "    Not initialized~%"))
  (format stream "=== End Parallel Client Status ===~%")
  client)

(defun parallel-client-metrics (client)
  "Return parallel client metrics as a plist.

CLIENT: A parallel-client struct

Returns a plist combining engine metrics and dedup stats."
  (let ((engine-m (engine-metrics (parallel-client-engine client)))
        (dedup-m (when (parallel-client-dedup-cache client)
                   (dedup-statistics (parallel-client-dedup-cache client)))))
    (append engine-m
            (when dedup-m
              (list :dedup-total (getf dedup-m :total-requests)
                    :dedup-saved (getf dedup-m :total-deduped)
                    :dedup-rate (getf dedup-m :dedup-rate))))))
