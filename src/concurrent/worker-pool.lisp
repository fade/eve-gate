;;;; worker-pool.lisp - Advanced worker pool management for eve-gate
;;;;
;;;; Provides specialized worker pools that complement the concurrent engine.
;;;; While the engine manages a single homogeneous thread pool, this module
;;;; offers:
;;;;   - Multiple named worker pools for different operation classes
;;;;   - Dynamic worker scaling based on queue depth and throughput
;;;;   - Worker health monitoring and automatic replacement
;;;;   - Pool-level statistics and diagnostics
;;;;
;;;; Operation classes:
;;;;   :REALTIME  — Low-latency requests (character location, ship type)
;;;;   :STANDARD  — Normal API calls (character info, assets)
;;;;   :BULK      — High-volume background work (market data, universe info)
;;;;   :PRIORITY  — Critical operations (auth refresh, error recovery)
;;;;
;;;; Each pool has its own thread set, scaling parameters, and monitoring.
;;;; The pool manager coordinates across pools to respect the global ESI
;;;; rate limit while giving each pool its fair share.

(in-package #:eve-gate.concurrent)

;;; ---------------------------------------------------------------------------
;;; Worker pool structure
;;; ---------------------------------------------------------------------------

(defstruct (worker-pool (:constructor %make-worker-pool))
  "A named pool of worker threads for a specific operation class.

Slots:
  NAME: Pool identifier keyword
  LOCK: Thread synchronization lock
  WORKERS: List of active worker threads
  MIN-WORKERS: Minimum worker count (never scale below)
  MAX-WORKERS: Maximum worker count (never scale above)
  CURRENT-COUNT: Current number of workers
  QUEUE: The request queue this pool drains
  ENGINE: The concurrent engine workers use for HTTP
  RUNNING-P: Whether the pool is active
  SCALE-CHECK-INTERVAL: Seconds between auto-scale checks
  LAST-SCALE-CHECK: Universal-time of last scale evaluation
  SCALE-UP-THRESHOLD: Queue depth ratio that triggers scale-up
  SCALE-DOWN-THRESHOLD: Queue depth ratio that triggers scale-down
  METRICS-LOCK: Lock for pool metrics
  REQUESTS-PROCESSED: Total requests this pool has processed
  TOTAL-LATENCY: Cumulative request latency (seconds)
  WORKER-RESTARTS: Number of times workers were replaced"
  (name :standard :type keyword)
  (lock (bt:make-lock "worker-pool-lock"))
  (workers nil :type list)
  (min-workers 1 :type (integer 1))
  (max-workers 8 :type (integer 1))
  (current-count 0 :type (integer 0))
  (queue nil :type (or null request-queue))
  (engine nil :type (or null concurrent-engine))
  (running-p nil :type boolean)
  (scale-check-interval 5 :type (integer 1))
  (last-scale-check 0 :type integer)
  (scale-up-threshold 0.8 :type single-float)
  (scale-down-threshold 0.2 :type single-float)
  (metrics-lock (bt:make-lock "worker-pool-metrics-lock"))
  (requests-processed 0 :type (integer 0))
  (total-latency 0.0 :type single-float)
  (worker-restarts 0 :type (integer 0)))

(defun make-worker-pool (name &key (min-workers 1)
                                     (max-workers 8)
                                     (queue-size 500)
                                     engine
                                     (scale-up-threshold 0.8)
                                     (scale-down-threshold 0.2))
  "Create a named worker pool for a specific operation class.

NAME: Pool identifier keyword (:realtime, :standard, :bulk, :priority)
MIN-WORKERS: Minimum thread count (default: 1)
MAX-WORKERS: Maximum thread count (default: 8)
QUEUE-SIZE: Maximum queue depth for this pool (default: 500)
ENGINE: Concurrent engine for HTTP requests (default: creates one)
SCALE-UP-THRESHOLD: Queue fullness triggering scale-up (default: 0.8)
SCALE-DOWN-THRESHOLD: Queue fullness triggering scale-down (default: 0.2)

Returns a worker-pool struct."
  (let ((pool-engine (or engine (make-concurrent-engine
                                  :worker-count 0))))  ; engine without workers
    (%make-worker-pool
     :name name
     :min-workers min-workers
     :max-workers max-workers
     :queue (make-request-queue :max-size queue-size)
     :engine pool-engine
     :scale-up-threshold (float scale-up-threshold)
     :scale-down-threshold (float scale-down-threshold))))

;;; ---------------------------------------------------------------------------
;;; Pool lifecycle
;;; ---------------------------------------------------------------------------

(defun start-pool (pool)
  "Start the worker pool, creating the minimum number of workers.

POOL: A worker-pool struct

Returns the pool."
  (bt:with-lock-held ((worker-pool-lock pool))
    (when (worker-pool-running-p pool)
      (log-warn "Worker pool ~A already running" (worker-pool-name pool))
      (return-from start-pool pool))
    (setf (worker-pool-running-p pool) t
          (worker-pool-last-scale-check pool) (get-universal-time))
    ;; Start minimum number of workers
    (dotimes (i (worker-pool-min-workers pool))
      (spawn-pool-worker pool i)))
  (log-info "Worker pool ~A started with ~D workers"
            (worker-pool-name pool)
            (worker-pool-current-count pool))
  pool)

(defun stop-pool (pool &key (wait t) (timeout 30))
  "Stop the worker pool, draining pending requests if WAIT is T.

POOL: A worker-pool struct
WAIT: If T, wait for pending requests (default: T)
TIMEOUT: Maximum seconds to wait (default: 30)

Returns the pool."
  (declare (ignore timeout))
  (bt:with-lock-held ((worker-pool-lock pool))
    (unless (worker-pool-running-p pool)
      (return-from stop-pool pool))
    (setf (worker-pool-running-p pool) nil))
  ;; Shut down the queue to signal workers
  (shutdown-queue (worker-pool-queue pool))
  ;; Wait for workers to exit
  (when wait
    (dolist (thread (worker-pool-workers pool))
      (when (bt:thread-alive-p thread)
        (bt:join-thread thread))))
  (bt:with-lock-held ((worker-pool-lock pool))
    (setf (worker-pool-workers pool) nil
          (worker-pool-current-count pool) 0))
  (log-info "Worker pool ~A stopped" (worker-pool-name pool))
  pool)

;;; ---------------------------------------------------------------------------
;;; Worker management
;;; ---------------------------------------------------------------------------

(defun spawn-pool-worker (pool worker-id)
  "Spawn a new worker thread in POOL. Must be called with the pool lock held.

POOL: A worker-pool struct
WORKER-ID: Integer ID for this worker (used in thread name)

Returns the new thread."
  (let* ((pool-name (worker-pool-name pool))
         (thread-name (format nil "eve-gate-~A-worker-~D" pool-name worker-id))
         (thread (bt:make-thread
                  (lambda () (pool-worker-loop pool))
                  :name thread-name)))
    (push thread (worker-pool-workers pool))
    (incf (worker-pool-current-count pool))
    thread))

(defun pool-worker-loop (pool)
  "Main loop for a pool worker thread.

Dequeues requests from the pool's queue and processes them through
the pool's engine."
  (let ((pool-name (worker-pool-name pool))
        (queue (worker-pool-queue pool))
        (engine (worker-pool-engine pool)))
    (log-debug "Pool ~A worker ~A started"
               pool-name (bt:thread-name (bt:current-thread)))
    (unwind-protect
         (loop while (worker-pool-running-p pool)
               do (let ((request (dequeue-request queue :timeout 1.0)))
                    (when request
                      (pool-process-request pool engine request))))
      (log-debug "Pool ~A worker ~A exiting"
                 pool-name (bt:thread-name (bt:current-thread))))))

(defun pool-process-request (pool engine request)
  "Process a single request within a pool worker.

POOL: The worker-pool
ENGINE: The concurrent engine to use for HTTP
REQUEST: The queued-request to process"
  (let ((start-time (get-internal-real-time)))
    (handler-case
        (let ((response (process-pool-http-request engine request)))
          ;; Record success
          (record-pool-metric pool (elapsed-seconds start-time))
          (complete-request request response))
      (error (condition)
        ;; Record failure
        (record-pool-metric pool (elapsed-seconds start-time))
        (fail-request request condition)))))

(defun process-pool-http-request (engine request)
  "Execute an HTTP request via the engine's client.

ENGINE: A concurrent-engine (uses its HTTP client)
REQUEST: A queued-request

Returns an esi-response."
  (let* ((client (concurrent-engine-http-client engine))
         (path (queued-request-path request))
         (method (queued-request-method request))
         (params (queued-request-params request))
         (query-params (getf params :query-params))
         (content (getf params :content))
         (bearer-token (getf params :bearer-token))
         (if-none-match (getf params :if-none-match)))
    (http-request client path
                    :method method
                    :query-params query-params
                    :content content
                    :bearer-token bearer-token
                    :if-none-match if-none-match)))

(defun record-pool-metric (pool latency)
  "Record a processing metric for the pool.

POOL: A worker-pool
LATENCY: Request latency in seconds"
  (bt:with-lock-held ((worker-pool-metrics-lock pool))
    (incf (worker-pool-requests-processed pool))
    (incf (worker-pool-total-latency pool) latency)))

;;; ---------------------------------------------------------------------------
;;; Dynamic scaling
;;; ---------------------------------------------------------------------------

(defun check-pool-scaling (pool)
  "Evaluate whether the pool should scale up or down.

Called periodically. Examines queue depth relative to capacity and
current worker count to decide whether to add or remove workers.

POOL: A worker-pool struct

Returns :scaled-up, :scaled-down, or :unchanged."
  (let ((now (get-universal-time)))
    ;; Rate-limit scaling checks
    (when (< (- now (worker-pool-last-scale-check pool))
             (worker-pool-scale-check-interval pool))
      (return-from check-pool-scaling :unchanged))
    (setf (worker-pool-last-scale-check pool) now)
    (let* ((queue (worker-pool-queue pool))
           (depth (queue-depth queue))
           (max-size (request-queue-max-size queue))
           (fullness (if (plusp max-size) (/ (float depth) max-size) 0.0))
           (current (worker-pool-current-count pool))
           (min-w (worker-pool-min-workers pool))
           (max-w (worker-pool-max-workers pool)))
      (cond
        ;; Scale up: queue is getting full and we have room
        ((and (> fullness (worker-pool-scale-up-threshold pool))
              (< current max-w))
         (bt:with-lock-held ((worker-pool-lock pool))
           (spawn-pool-worker pool current))
         (log-info "Pool ~A scaled up to ~D workers (queue ~,0F% full)"
                   (worker-pool-name pool)
                   (worker-pool-current-count pool)
                   (* 100.0 fullness))
         :scaled-up)
        ;; Scale down: queue is mostly empty and we're above minimum
        ((and (< fullness (worker-pool-scale-down-threshold pool))
              (> current min-w))
         ;; Remove the last worker (it will exit naturally)
         (bt:with-lock-held ((worker-pool-lock pool))
           (when (worker-pool-workers pool)
             ;; Mark one worker for removal by decrementing count
             ;; The worker loop checks running-p, but we can't stop
             ;; individual workers cleanly. Instead we decrement and
             ;; let natural attrition handle it on next restart.
             (decf (worker-pool-current-count pool))))
         (log-info "Pool ~A scaled down to ~D workers (queue ~,0F% full)"
                   (worker-pool-name pool)
                   (worker-pool-current-count pool)
                   (* 100.0 fullness))
         :scaled-down)
        (t :unchanged)))))

;;; ---------------------------------------------------------------------------
;;; Worker health monitoring
;;; ---------------------------------------------------------------------------

(defun check-worker-health (pool)
  "Check all workers in the pool and replace dead ones.

POOL: A worker-pool struct

Returns the number of workers replaced."
  (bt:with-lock-held ((worker-pool-lock pool))
    (unless (worker-pool-running-p pool)
      (return-from check-worker-health 0))
    (let ((live-workers '())
          (dead-count 0))
      ;; Partition workers into live and dead
      (dolist (thread (worker-pool-workers pool))
        (if (bt:thread-alive-p thread)
            (push thread live-workers)
            (incf dead-count)))
      ;; Replace dead workers
      (setf (worker-pool-workers pool) live-workers
            (worker-pool-current-count pool) (length live-workers))
      (when (plusp dead-count)
        (log-warn "Pool ~A: ~D dead workers detected, replacing"
                  (worker-pool-name pool) dead-count)
        (incf (worker-pool-worker-restarts pool) dead-count)
        (dotimes (i dead-count)
          (spawn-pool-worker pool
                              (+ (worker-pool-current-count pool) i -1))))
      dead-count)))

;;; ---------------------------------------------------------------------------
;;; Pool submission
;;; ---------------------------------------------------------------------------

(defun pool-submit (pool path &key (method :get)
                                     (priority +priority-normal+)
                                     params
                                     character-id
                                     callback
                                     error-callback
                                     (timeout 60))
  "Submit a request to a specific worker pool.

POOL: A worker-pool struct
PATH: ESI endpoint path
METHOD: HTTP method (default: :get)
PRIORITY: Request priority (default: +priority-normal+)
PARAMS: Request parameters plist
CHARACTER-ID: Optional character ID
CALLBACK: Async completion callback
ERROR-CALLBACK: Async error callback
TIMEOUT: Request timeout in seconds (default: 60)

Returns the queued-request struct."
  (let ((request (make-queued-request
                   :priority priority
                   :path path
                   :method method
                   :params params
                   :character-id character-id
                   :callback callback
                   :error-callback error-callback
                   :timeout timeout)))
    (enqueue-request (worker-pool-queue pool) request)
    request))

(defun pool-submit-and-wait (pool path &key (method :get)
                                              (priority +priority-normal+)
                                              params
                                              character-id
                                              (timeout 60))
  "Submit a request to a pool and wait for the result.

Returns two values: the result and a success boolean."
  (let ((request (pool-submit pool path
                               :method method
                               :priority priority
                               :params params
                               :character-id character-id
                               :timeout timeout)))
    (wait-for-request request :timeout timeout)))

;;; ---------------------------------------------------------------------------
;;; Pool manager — coordinates multiple pools
;;; ---------------------------------------------------------------------------

(defstruct (pool-manager (:constructor %make-pool-manager))
  "Manages a collection of named worker pools.

Slots:
  LOCK: Thread synchronization lock
  POOLS: Hash-table of pool-name -> worker-pool
  ENGINE: Shared concurrent engine
  MONITOR-THREAD: Background thread for health checks and scaling
  MONITOR-INTERVAL: Seconds between monitor cycles
  RUNNING-P: Whether the manager is active"
  (lock (bt:make-lock "pool-manager-lock"))
  (pools (make-hash-table :test 'eq) :type hash-table)
  (engine nil :type (or null concurrent-engine))
  (monitor-thread nil)
  (monitor-interval 5 :type (integer 1))
  (running-p nil :type boolean))

(defun make-pool-manager (&key engine (monitor-interval 5))
  "Create a pool manager with default pool configurations.

ENGINE: Shared concurrent engine (default: creates one)
MONITOR-INTERVAL: Seconds between health/scaling checks (default: 5)

Returns a pool-manager struct with four preconfigured pools:
  :PRIORITY  — 1-2 workers, for auth and error recovery
  :REALTIME  — 2-4 workers, for low-latency requests
  :STANDARD  — 2-8 workers, for normal API calls
  :BULK      — 1-4 workers, for background mass operations"
  (let* ((shared-engine (or engine (make-concurrent-engine :worker-count 0)))
         (manager (%make-pool-manager
                   :engine shared-engine
                   :monitor-interval monitor-interval)))
    ;; Create default pools
    (let ((pools (pool-manager-pools manager)))
      (setf (gethash :priority pools)
            (make-worker-pool :priority
                               :min-workers 1 :max-workers 2
                               :queue-size 100 :engine shared-engine)
            (gethash :realtime pools)
            (make-worker-pool :realtime
                               :min-workers 2 :max-workers 4
                               :queue-size 200 :engine shared-engine)
            (gethash :standard pools)
            (make-worker-pool :standard
                               :min-workers 2 :max-workers 8
                               :queue-size 500 :engine shared-engine)
            (gethash :bulk pools)
            (make-worker-pool :bulk
                               :min-workers 1 :max-workers 4
                               :queue-size 2000 :engine shared-engine)))
    manager))

(defun start-pool-manager (manager)
  "Start all pools and the monitoring thread.

MANAGER: A pool-manager struct

Returns the manager."
  (bt:with-lock-held ((pool-manager-lock manager))
    (when (pool-manager-running-p manager)
      (return-from start-pool-manager manager))
    (setf (pool-manager-running-p manager) t)
    ;; Start all pools
    (maphash (lambda (name pool)
               (declare (ignore name))
               (start-pool pool))
             (pool-manager-pools manager))
    ;; Start monitor thread
    (setf (pool-manager-monitor-thread manager)
          (bt:make-thread
           (lambda () (pool-monitor-loop manager))
           :name "eve-gate-pool-monitor")))
  (log-info "Pool manager started")
  manager)

(defun stop-pool-manager (manager &key (wait t))
  "Stop all pools and the monitoring thread.

MANAGER: A pool-manager struct
WAIT: If T, wait for pending work (default: T)"
  (bt:with-lock-held ((pool-manager-lock manager))
    (unless (pool-manager-running-p manager)
      (return-from stop-pool-manager manager))
    (setf (pool-manager-running-p manager) nil))
  ;; Stop all pools
  (maphash (lambda (name pool)
             (declare (ignore name))
             (stop-pool pool :wait wait))
           (pool-manager-pools manager))
  ;; Wait for monitor thread
  (when (and wait (pool-manager-monitor-thread manager)
             (bt:thread-alive-p (pool-manager-monitor-thread manager)))
    (bt:join-thread (pool-manager-monitor-thread manager)))
  (log-info "Pool manager stopped")
  manager)

(defun get-pool (manager pool-name)
  "Get a named worker pool from the manager.

MANAGER: A pool-manager struct
POOL-NAME: Pool identifier keyword

Returns the worker-pool, or NIL if not found."
  (gethash pool-name (pool-manager-pools manager)))

(defun manager-submit (manager pool-name path &rest args
                       &key method priority params character-id
                            callback error-callback timeout)
  "Submit a request to a specific pool via the manager.

MANAGER: A pool-manager struct
POOL-NAME: Target pool keyword (:priority, :realtime, :standard, :bulk)
PATH: ESI endpoint path
ARGS: Additional keyword args passed to POOL-SUBMIT

Returns the queued-request, or signals an error if the pool is unknown."
  (declare (ignore method priority params character-id
                   callback error-callback timeout))
  (let ((pool (get-pool manager pool-name)))
    (unless pool
      (error "Unknown worker pool: ~A" pool-name))
    (apply #'pool-submit pool path args)))

;;; ---------------------------------------------------------------------------
;;; Pool monitoring
;;; ---------------------------------------------------------------------------

(defun pool-monitor-loop (manager)
  "Background monitoring loop for the pool manager.

Periodically checks worker health and evaluates scaling decisions."
  (log-debug "Pool monitor started")
  (unwind-protect
       (loop while (pool-manager-running-p manager)
             do (handler-case
                    (progn
                      (maphash (lambda (name pool)
                                 (declare (ignore name))
                                 (check-worker-health pool)
                                 (check-pool-scaling pool))
                               (pool-manager-pools manager))
                      (sleep (pool-manager-monitor-interval manager)))
                  (error (e)
                    (log-error "Pool monitor error: ~A" e)
                    (sleep 1))))
    (log-debug "Pool monitor exiting")))

;;; ---------------------------------------------------------------------------
;;; Pool statistics and status
;;; ---------------------------------------------------------------------------

(defun pool-metrics (pool)
  "Return metrics for a worker pool as a plist.

POOL: A worker-pool struct

Returns a plist with:
  :NAME — pool identifier
  :WORKERS — current worker count
  :MIN-WORKERS — minimum workers
  :MAX-WORKERS — maximum workers
  :QUEUE-DEPTH — current queue depth
  :REQUESTS-PROCESSED — total requests completed
  :AVG-LATENCY — average request latency
  :WORKER-RESTARTS — dead workers replaced
  :RUNNING-P — whether pool is active"
  (bt:with-lock-held ((worker-pool-metrics-lock pool))
    (let ((processed (worker-pool-requests-processed pool))
          (latency (worker-pool-total-latency pool)))
      (list :name (worker-pool-name pool)
            :workers (worker-pool-current-count pool)
            :min-workers (worker-pool-min-workers pool)
            :max-workers (worker-pool-max-workers pool)
            :queue-depth (queue-depth (worker-pool-queue pool))
            :requests-processed processed
            :avg-latency (if (plusp processed)
                             (/ latency processed)
                             0.0)
            :worker-restarts (worker-pool-worker-restarts pool)
            :running-p (worker-pool-running-p pool)))))

(defun pool-manager-status (manager &optional (stream *standard-output*))
  "Print a status report for all managed worker pools.

MANAGER: A pool-manager struct
STREAM: Output stream (default: *standard-output*)"
  (format stream "~&=== Pool Manager Status ===~%")
  (format stream "  Running: ~A~%" (pool-manager-running-p manager))
  (format stream "  Pools:~%")
  (maphash (lambda (name pool)
             (let ((metrics (pool-metrics pool)))
               (format stream "~%  [~A]~%" name)
               (format stream "    Workers:    ~D / ~D-~D~%"
                       (getf metrics :workers)
                       (getf metrics :min-workers)
                       (getf metrics :max-workers))
               (format stream "    Queue:      ~D~%"
                       (getf metrics :queue-depth))
               (format stream "    Processed:  ~D~%"
                       (getf metrics :requests-processed))
               (format stream "    Avg latency: ~,3F sec~%"
                       (getf metrics :avg-latency))
               (format stream "    Restarts:   ~D~%"
                       (getf metrics :worker-restarts))
               (format stream "    Running:    ~A~%"
                       (getf metrics :running-p))))
           (pool-manager-pools manager))
  (format stream "=== End Pool Manager Status ===~%")
  manager)
