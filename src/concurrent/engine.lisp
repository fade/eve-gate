;;;; engine.lisp - Concurrent request engine for eve-gate
;;;;
;;;; High-level orchestration of concurrent ESI API requests with rate limiting,
;;;; connection management, and bulk operation support. This is the primary
;;;; interface for performing multiple API calls efficiently.
;;;;
;;;; The engine combines:
;;;;   - Rate limiter: Enforces ESI rate limits
;;;;   - Request queue: Priority-based request scheduling
;;;;   - Worker pool: Thread pool for concurrent execution
;;;;   - Circuit breakers: Per-endpoint failure protection
;;;;   - Performance monitoring: Throughput and latency metrics
;;;;
;;;; Design:
;;;;   - Functional core: Request specs are pure data, engine manages effects
;;;;   - Thread safety: All shared state protected by appropriate locks
;;;;   - Observable: Comprehensive metrics and status reporting
;;;;   - Resilient: Handles individual request failures without affecting others

(in-package #:eve-gate.concurrent)

;;; ---------------------------------------------------------------------------
;;; Concurrent engine structure
;;; ---------------------------------------------------------------------------

(defstruct (concurrent-engine (:constructor %make-concurrent-engine))
  "High-level concurrent request engine for ESI API operations.

Manages worker threads, rate limiting, and request queuing to maximize
throughput within ESI rate limits.

Slots:
  LOCK: Thread synchronization lock
  HTTP-CLIENT: The underlying throttled HTTP client
  RATE-LIMITER: ESI rate limiter for request throttling
  REQUEST-QUEUE: Priority queue for pending requests
  WORKER-THREADS: List of active worker threads
  WORKER-COUNT: Number of worker threads
  RUNNING-P: Whether the engine is actively processing
  METRICS-LOCK: Lock for metrics
  TOTAL-REQUESTS: Total requests processed
  TOTAL-SUCCESSES: Total successful requests
  TOTAL-FAILURES: Total failed requests
  TOTAL-LATENCY: Cumulative request latency (seconds)
  START-TIME: When the engine was started"
  (lock (bt:make-lock "concurrent-engine-lock"))
  (http-client nil)
  (rate-limiter nil :type (or null esi-rate-limiter))
  (request-queue nil :type (or null request-queue))
  (worker-threads nil :type list)
  (worker-count 4 :type (integer 0))
  (running-p nil :type boolean)
  (metrics-lock (bt:make-lock "engine-metrics-lock"))
  (total-requests 0 :type (integer 0))
  (total-successes 0 :type (integer 0))
  (total-failures 0 :type (integer 0))
  (total-latency 0.0 :type single-float)
  (start-time 0 :type integer))

(defun make-concurrent-engine (&key (worker-count 4)
                                     (queue-size 1000)
                                     (global-rate 150.0)
                                     (global-burst 150.0)
                                     http-client
                                     rate-limiter)
  "Create a new concurrent request engine.

WORKER-COUNT: Number of worker threads (default: 4)
QUEUE-SIZE: Maximum request queue depth (default: 1000)
GLOBAL-RATE: Rate limit in requests/second (default: 150.0)
GLOBAL-BURST: Burst capacity (default: 150.0)
HTTP-CLIENT: Pre-configured HTTP client (default: auto-created)
RATE-LIMITER: Pre-configured rate limiter (default: auto-created)

Returns a concurrent-engine struct. Call START-ENGINE to begin processing.

Example:
  (let ((engine (make-concurrent-engine :worker-count 8)))
    (start-engine engine)
    ;; Submit requests...
    (stop-engine engine))"
  (let* ((limiter (or rate-limiter
                      (make-esi-rate-limiter
                       :global-rate global-rate
                       :global-burst global-burst)))
         (client (or http-client
                     (make-throttled-http-client :rate-limiter limiter))))
    (%make-concurrent-engine
     :http-client client
     :rate-limiter limiter
     :request-queue (make-request-queue :max-size queue-size)
     :worker-count worker-count)))

;;; ---------------------------------------------------------------------------
;;; Engine lifecycle
;;; ---------------------------------------------------------------------------

(defun start-engine (engine)
  "Start the concurrent engine's worker threads.

ENGINE: A concurrent-engine struct

Returns the engine."
  (bt:with-lock-held ((concurrent-engine-lock engine))
    (when (concurrent-engine-running-p engine)
      (log-warn "Engine already running")
      (return-from start-engine engine))
    (setf (concurrent-engine-running-p engine) t
          (concurrent-engine-start-time engine) (get-universal-time))
    (let ((workers '()))
      (dotimes (i (concurrent-engine-worker-count engine))
        (let ((thread-name (format nil "eve-gate-worker-~D" i))
              (eng engine))  ; capture for closure
          (push (bt:make-thread
                 (lambda () (engine-worker-loop eng))
                 :name thread-name)
                workers)))
      (setf (concurrent-engine-worker-threads engine) workers))
    (log-info "Engine started with ~D workers"
              (concurrent-engine-worker-count engine)))
  engine)

(defun stop-engine (engine &key (wait t) (timeout 30))
  "Stop the concurrent engine.

ENGINE: A concurrent-engine struct
WAIT: If T, wait for pending requests to complete (default: T)
TIMEOUT: Maximum seconds to wait for completion (default: 30)

Returns the engine."
  (bt:with-lock-held ((concurrent-engine-lock engine))
    (unless (concurrent-engine-running-p engine)
      (return-from stop-engine engine))
    (setf (concurrent-engine-running-p engine) nil))
  ;; Shut down the request queue (signals shutdown to workers)
  (shutdown-queue (concurrent-engine-request-queue engine))
  ;; Wait for worker threads to finish
  (when wait
    (dolist (thread (concurrent-engine-worker-threads engine))
      (when (bt:thread-alive-p thread)
        (bt:join-thread thread))))
  (setf (concurrent-engine-worker-threads engine) nil)
  (log-info "Engine stopped")
  engine)

;;; ---------------------------------------------------------------------------
;;; Worker loop
;;; ---------------------------------------------------------------------------

(defun engine-worker-loop (engine)
  "Main loop for engine worker threads.
Dequeues requests and processes them, respecting rate limits.

ENGINE: The concurrent-engine this worker belongs to"
  (log-debug "Worker ~A started" (bt:thread-name (bt:current-thread)))
  (unwind-protect
       (loop while (concurrent-engine-running-p engine)
             do (let ((request (dequeue-request
                                 (concurrent-engine-request-queue engine)
                                 :timeout 1.0)))
                  (when request
                    (process-engine-request engine request))))
    (log-debug "Worker ~A exiting" (bt:thread-name (bt:current-thread)))))

(defun process-engine-request (engine request)
  "Process a single request from the queue.

ENGINE: The concurrent-engine
REQUEST: A queued-request to process"
  (let ((start-time (get-internal-real-time)))
    (handler-case
        (let* ((client (concurrent-engine-http-client engine))
               (path (queued-request-path request))
               (method (queued-request-method request))
               (params (queued-request-params request))
               ;; Extract standard HTTP request parameters
               (query-params (getf params :query-params))
               (content (getf params :content))
               (bearer-token (getf params :bearer-token))
               (if-none-match (getf params :if-none-match)))
          (let ((response (http-request client path
                                         :method method
                                         :query-params query-params
                                         :content content
                                         :bearer-token bearer-token
                                         :if-none-match if-none-match)))
            ;; Record success metrics
            (record-engine-metric engine :success
                                   (elapsed-seconds start-time))
            ;; Complete the request
            (complete-request request response)))
      (error (condition)
        ;; Record failure metrics
        (record-engine-metric engine :failure
                                (elapsed-seconds start-time))
        ;; Fail the request
        (fail-request request condition)))))

(defun record-engine-metric (engine type latency)
  "Record an engine processing metric.

ENGINE: The concurrent-engine
TYPE: :SUCCESS or :FAILURE
LATENCY: Request processing time in seconds"
  (bt:with-lock-held ((concurrent-engine-metrics-lock engine))
    (incf (concurrent-engine-total-requests engine))
    (incf (concurrent-engine-total-latency engine) latency)
    (ecase type
      (:success (incf (concurrent-engine-total-successes engine)))
      (:failure (incf (concurrent-engine-total-failures engine))))))

;;; ---------------------------------------------------------------------------
;;; Request submission
;;; ---------------------------------------------------------------------------

(defun submit-request (engine path &key (method :get)
                                         (priority +priority-normal+)
                                         params
                                         character-id
                                         callback
                                         error-callback
                                         (timeout 60))
  "Submit a request to the concurrent engine for processing.

ENGINE: A concurrent-engine
PATH: ESI endpoint path
METHOD: HTTP method keyword (default: :get)
PRIORITY: Request priority 0-4 (default: +priority-normal+)
PARAMS: Plist of HTTP request parameters
CHARACTER-ID: Optional character ID for fair scheduling
CALLBACK: Async completion callback (response) -> void
ERROR-CALLBACK: Async error callback (condition) -> void
TIMEOUT: Request timeout in seconds (default: 60)

Returns the queued-request struct (for tracking or synchronous waiting).

Example:
  ;; Async request
  (submit-request engine \"/v5/characters/95465499/\"
    :callback (lambda (response)
                (format t \"Got: ~A~%\" (esi-response-body response))))

  ;; Sync request
  (let ((req (submit-request engine \"/v5/status/\")))
    (wait-for-request req))"
  (let ((request (make-queued-request
                   :priority priority
                   :path path
                   :method method
                   :params params
                   :character-id character-id
                   :callback callback
                   :error-callback error-callback
                   :timeout timeout)))
    (enqueue-request (concurrent-engine-request-queue engine) request)
    request))

(defun submit-and-wait (engine path &key (method :get)
                                          (priority +priority-normal+)
                                          params
                                          character-id
                                          (timeout 60))
  "Submit a request and block until the result is available.

ENGINE: A concurrent-engine
PATH: ESI endpoint path
METHOD: HTTP method (default: :get)
PRIORITY: Request priority (default: +priority-normal+)
PARAMS: Plist of HTTP request parameters
CHARACTER-ID: Optional character ID
TIMEOUT: Maximum seconds to wait (default: 60)

Returns two values:
  1. The esi-response struct (or NIL on timeout/failure)
  2. T if successful, NIL if failed/timed out

Example:
  (multiple-value-bind (response success-p)
      (submit-and-wait engine \"/v5/status/\")
    (when success-p
      (format t \"Server status: ~A~%\" (esi-response-body response))))"
  (let ((request (submit-request engine path
                                  :method method
                                  :priority priority
                                  :params params
                                  :character-id character-id
                                  :timeout timeout)))
    (wait-for-request request :timeout timeout)))

;;; ---------------------------------------------------------------------------
;;; Bulk operations
;;; ---------------------------------------------------------------------------

(defun bulk-submit (engine requests-spec &key (priority +priority-normal+)
                                               (timeout 120)
                                               progress-callback)
  "Submit multiple requests for concurrent processing.

ENGINE: A concurrent-engine
REQUESTS-SPEC: List of request specifications, each a plist with:
  :PATH — ESI endpoint path (required)
  :METHOD — HTTP method (default: :get)
  :PARAMS — HTTP request parameters plist
  :CHARACTER-ID — Optional character ID
PRIORITY: Priority for all requests (default: +priority-normal+)
TIMEOUT: Per-request timeout in seconds (default: 120)
PROGRESS-CALLBACK: Optional function (completed total) called on each completion

Returns a list of queued-request structs for tracking.

Example:
  ;; Fetch multiple character profiles
  (let* ((char-ids '(95465499 96071137 1234567))
         (specs (mapcar (lambda (id)
                          (list :path (format nil \"/v5/characters/~D/\" id)))
                        char-ids))
         (requests (bulk-submit engine specs)))
    ;; Wait for all to complete
    (mapcar (lambda (req)
              (multiple-value-bind (result ok) (wait-for-request req)
                (when ok (esi-response-body result))))
            requests))"
  (let ((requests '())
        (total (length requests-spec))
        (completed 0)
        (completed-lock (bt:make-lock "bulk-completed-lock")))
    (dolist (spec requests-spec)
      (let ((path (getf spec :path))
            (method (or (getf spec :method) :get))
            (params (getf spec :params))
            (char-id (getf spec :character-id)))
        (unless path
          (error "Each request spec must have a :PATH key"))
        (let ((request (submit-request engine path
                                        :method method
                                        :priority priority
                                        :params params
                                        :character-id char-id
                                        :timeout timeout
                                        :callback
                                        (when progress-callback
                                          (lambda (response)
                                            (declare (ignore response))
                                            (bt:with-lock-held (completed-lock)
                                              (incf completed))
                                            (funcall progress-callback
                                                     completed total))))))
          (push request requests))))
    (nreverse requests)))

(defun bulk-submit-and-wait (engine requests-spec &key (priority +priority-normal+)
                                                        (timeout 120)
                                                        progress-callback)
  "Submit multiple requests and wait for all to complete.

ENGINE: A concurrent-engine
REQUESTS-SPEC: List of request specification plists (see BULK-SUBMIT)
PRIORITY: Priority for all requests (default: +priority-normal+)
TIMEOUT: Per-request timeout (default: 120)
PROGRESS-CALLBACK: Optional progress function (completed total)

Returns a list of results, each being either:
  - An esi-response struct (on success)
  - A condition object (on failure)
  - NIL (on timeout)

Example:
  (let* ((specs (list (list :path \"/v5/status/\")
                      (list :path \"/v5/incursions/\")))
         (results (bulk-submit-and-wait engine specs)))
    (dolist (result results)
      (when (esi-response-p result)
        (format t \"~A: ~A~%\" (esi-response-uri result)
                (esi-response-status result)))))"
  (let ((requests (bulk-submit engine requests-spec
                                :priority priority
                                :timeout timeout
                                :progress-callback progress-callback)))
    (mapcar (lambda (req)
              (multiple-value-bind (result completed-p)
                  (wait-for-request req :timeout timeout)
                (if completed-p
                    result
                    nil)))
            requests)))

;;; ---------------------------------------------------------------------------
;;; Convenience functions for common patterns
;;; ---------------------------------------------------------------------------

(defun fetch-all-pages (engine path &key params character-id
                                          (priority +priority-normal+)
                                          (timeout 120)
                                          (max-pages 100))
  "Fetch all pages of a paginated ESI endpoint.

Sends the first request, reads the X-Pages header, then fetches all
remaining pages concurrently.

ENGINE: A concurrent-engine
PATH: ESI endpoint path
PARAMS: Base query parameters (page will be added)
CHARACTER-ID: Optional character ID
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-page timeout (default: 120)
MAX-PAGES: Safety limit on number of pages (default: 100)

Returns a list of all result data concatenated across pages.

Example:
  ;; Fetch all market orders for a region
  (fetch-all-pages engine \"/v1/markets/10000002/orders/\"
    :params '(:query-params ((\"order_type\" . \"all\"))))"
  ;; First, fetch page 1 to get total pages
  (let* ((page1-params (append-query-param params "page" "1"))
         (page1-response (submit-and-wait engine path
                                           :params page1-params
                                           :character-id character-id
                                           :priority priority
                                           :timeout timeout)))
    (unless page1-response
      (return-from fetch-all-pages nil))
    ;; Extract total pages from headers
    (let* ((headers (esi-response-headers page1-response))
           (total-pages (or (parse-header-integer headers "x-pages") 1))
           (clamped-pages (min total-pages max-pages))
           (page1-data (esi-response-body page1-response)))
      (if (<= clamped-pages 1)
          ;; Single page, just return it
          (if (typep page1-data 'sequence)
              (coerce page1-data 'list)
              (list page1-data))
          ;; Multiple pages — fetch remaining concurrently
          (let* ((remaining-specs
                   (loop for page from 2 to clamped-pages
                         collect (list :path path
                                       :params (append-query-param
                                                 params "page"
                                                 (princ-to-string page))
                                       :character-id character-id)))
                 (remaining-results
                   (bulk-submit-and-wait engine remaining-specs
                                          :priority priority
                                          :timeout timeout)))
            ;; Concatenate all page data
            (let ((all-data (if (typep page1-data 'sequence)
                                (coerce page1-data 'list)
                                (list page1-data))))
              (dolist (result remaining-results)
                (when (esi-response-p result)
                  (let ((data (esi-response-body result)))
                    (when data
                      (if (typep data 'sequence)
                          (setf all-data (nconc all-data (coerce data 'list)))
                          (push data all-data))))))
              all-data))))))

(defun fetch-multiple-ids (engine path-template ids &key params
                                                          character-id
                                                          (priority +priority-normal+)
                                                          (timeout 60)
                                                          progress-callback)
  "Fetch data for multiple IDs using a path template.

ENGINE: A concurrent-engine
PATH-TEMPLATE: Format string with ~A for ID substitution
IDS: List of IDs to fetch
PARAMS: Additional request parameters
CHARACTER-ID: Optional character ID
PRIORITY: Request priority (default: +priority-normal+)
TIMEOUT: Per-request timeout (default: 60)
PROGRESS-CALLBACK: Optional function (completed total)

Returns an alist of (id . response-data) pairs.

Example:
  ;; Fetch multiple character profiles
  (fetch-multiple-ids engine \"/v5/characters/~A/\"
    '(95465499 96071137 1234567)
    :progress-callback (lambda (done total)
                         (format t \"~D/~D~%\" done total)))"
  (let* ((specs (mapcar (lambda (id)
                           (list :path (format nil path-template id)
                                 :params params
                                 :character-id character-id))
                         ids))
         (results (bulk-submit-and-wait engine specs
                                         :priority priority
                                         :timeout timeout
                                         :progress-callback progress-callback)))
    ;; Pair IDs with results
    (mapcar (lambda (id result)
              (cons id (when (esi-response-p result)
                         (esi-response-body result))))
            ids results)))

;;; ---------------------------------------------------------------------------
;;; Query parameter helper
;;; ---------------------------------------------------------------------------

(defun append-query-param (params key value)
  "Append a query parameter to a params plist.

PARAMS: Existing params plist (may contain :QUERY-PARAMS)
KEY: Parameter name string
VALUE: Parameter value string

Returns a new params plist with the parameter added."
  (let ((existing-qp (copy-alist (or (getf params :query-params) nil)))
        (new-params (copy-list params)))
    (let ((entry (assoc key existing-qp :test #'string=)))
      (if entry
          (setf (cdr entry) value)
          (push (cons key value) existing-qp)))
    (setf (getf new-params :query-params) existing-qp)
    new-params))

;;; ---------------------------------------------------------------------------
;;; Engine metrics and status
;;; ---------------------------------------------------------------------------

(defun engine-metrics (engine)
  "Return engine performance metrics as a plist.

ENGINE: A concurrent-engine

Returns a plist with:
  :TOTAL-REQUESTS — total requests processed
  :TOTAL-SUCCESSES — successful requests
  :TOTAL-FAILURES — failed requests
  :SUCCESS-RATE — fraction of successful requests
  :AVG-LATENCY — average request latency (seconds)
  :THROUGHPUT — requests per second (since start)
  :UPTIME — seconds since engine started
  :WORKER-COUNT — number of worker threads
  :QUEUE-DEPTH — current request queue depth"
  (bt:with-lock-held ((concurrent-engine-metrics-lock engine))
    (let* ((total (concurrent-engine-total-requests engine))
           (successes (concurrent-engine-total-successes engine))
           (latency (concurrent-engine-total-latency engine))
           (uptime (max 1 (- (get-universal-time)
                              (concurrent-engine-start-time engine)))))
      (list :total-requests total
            :total-successes successes
            :total-failures (concurrent-engine-total-failures engine)
            :success-rate (if (plusp total)
                              (/ (float successes) total)
                              1.0)
            :avg-latency (if (plusp total)
                             (/ latency total)
                             0.0)
            :throughput (/ (float total) uptime)
            :uptime uptime
            :worker-count (concurrent-engine-worker-count engine)
            :queue-depth (queue-depth
                           (concurrent-engine-request-queue engine))))))

(defun engine-status (engine &optional (stream *standard-output*))
  "Print a comprehensive status report of the concurrent engine.

ENGINE: A concurrent-engine
STREAM: Output stream (default: *standard-output*)"
  (let ((metrics (engine-metrics engine)))
    (format stream "~&=== Concurrent Engine Status ===~%")
    (format stream "  Running:     ~A~%" (concurrent-engine-running-p engine))
    (format stream "  Workers:     ~D~%" (getf metrics :worker-count))
    (format stream "  Queue depth: ~D~%" (getf metrics :queue-depth))
    (format stream "  Uptime:      ~D seconds~%" (getf metrics :uptime))
    (format stream "~%  Performance:~%")
    (format stream "    Total requests:  ~D~%" (getf metrics :total-requests))
    (format stream "    Successes:       ~D~%" (getf metrics :total-successes))
    (format stream "    Failures:        ~D~%" (getf metrics :total-failures))
    (format stream "    Success rate:    ~,1F%~%"
            (* 100.0 (getf metrics :success-rate)))
    (format stream "    Avg latency:     ~,3F sec~%"
            (getf metrics :avg-latency))
    (format stream "    Throughput:      ~,1F req/sec~%"
            (getf metrics :throughput))
    ;; Rate limiter status
    (when (concurrent-engine-rate-limiter engine)
      (format stream "~%")
      (rate-limit-status (concurrent-engine-rate-limiter engine) stream))
    ;; Queue status
    (format stream "~%")
    (queue-status (concurrent-engine-request-queue engine) stream)
    (format stream "=== End Engine Status ===~%"))
  engine)

(defun reset-engine-metrics (engine)
  "Reset all engine performance metrics.

ENGINE: A concurrent-engine"
  (bt:with-lock-held ((concurrent-engine-metrics-lock engine))
    (setf (concurrent-engine-total-requests engine) 0
          (concurrent-engine-total-successes engine) 0
          (concurrent-engine-total-failures engine) 0
          (concurrent-engine-total-latency engine) 0.0
          (concurrent-engine-start-time engine) (get-universal-time)))
  engine)
